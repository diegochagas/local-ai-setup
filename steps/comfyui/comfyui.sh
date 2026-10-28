#!/usr/bin/env bash
#
# ComfyUI, the local AI image models behind the AI tools of
# GIMP (gimp-setup) and GIMPhoto, and of comic-skills: a
# ComfyUI server serving open-weight image models on this
# machine, with no accounts, credits or limits.
#
# - ComfyUI itself in COMFYUI_DIR, with its own Python
#   virtual environment and PyTorch built for CUDA.
# - Custom nodes: ComfyUI-GGUF, which loads quantized (GGUF)
#   models, so a 20B editing model fits in a 6 GB GPU by
#   keeping the rest of its weights in RAM; the SAM 2 nodes
#   (pinned), behind GIMP's and GIMPhoto's AI selections; the
#   BiRefNet nodes (pinned), behind GIMPhoto's Select Subject;
#   the inpaint nodes (pinned), which run LaMa for GIMPhoto's
#   Remove tool; and
#   this setup's own BBoxFromJSON (custom_nodes/), which lets
#   apps give SAM 2 box prompts through the HTTP API.
# - The model sets listed in COMFYUI_MODEL_SETS (see
#   models.tsv next to this file), each file verified
#   against the SHA-256 Hugging Face publishes for it.
# - A systemd user service, `comfyui`, NOT enabled at boot:
#   it holds GPU memory while it runs. GIMP and GIMPhoto
#   start it when they open and stop it when they close;
#   scripts can start it themselves (systemctl --user start
#   comfyui).
#
# The applications that use ComfyUI find it through that
# service (its working directory and port), so they need no
# setting of their own. gimp-setup also adds its own node
# to this ComfyUI: run this setup before it.
#
# Opt-in: without COMFYUI_DIR nothing is installed, because
# the models are tens of GB. Needs an NVIDIA GPU with its
# driver (a 6 GB card is enough).
#

: "${COMFYUI_DIR:=}"
: "${COMFYUI_REPO:=https://github.com/comfyanonymous/ComfyUI.git}"
: "${COMFYUI_GGUF_NODE_REPO:=https://github.com/city96/ComfyUI-GGUF.git}"
: "${COMFYUI_SAM2_NODE_REPO:=https://github.com/kijai/ComfyUI-segment-anything-2.git}"
: "${COMFYUI_BIREFNET_NODE_REPO:=https://github.com/lldacing/ComfyUI_BiRefNet_ll.git}"
: "${COMFYUI_INPAINT_NODE_REPO:=https://github.com/Acly/comfyui-inpaint-nodes.git}"
: "${COMFYUI_TORCH_INDEX_URL:=https://download.pytorch.org/whl/cu128}"
: "${COMFYUI_MODEL_SETS=qwen,klein,sam,birefnet,lama}"
: "${COMFYUI_PORT:=8188}"

readonly COMFYUI_MODELS_FILE="${BASH_SOURCE[0]%/*}/models.tsv"
# This setup's own small nodes (BBoxFromJSON), copied into custom_nodes/.
readonly COMFYUI_OWN_NODES_DIR="${BASH_SOURCE[0]%/*}/custom_nodes/local_ai_setup_nodes"
readonly COMFYUI_SERVICE_UNIT="$HOME/.config/systemd/user/comfyui.service"

# Pinned commit of ComfyUI-segment-anything-2 (SAM 2 nodes);
# bump it to update.
readonly COMFYUI_SAM2_NODE_COMMIT="0c35fff5f382803e2310103357b5e985f5437f32"
# Pinned commit of ComfyUI_BiRefNet_ll (BiRefNet nodes, MIT; it loads
# models/BiRefNet/General.safetensors, model set "birefnet"); bump it to
# update.
readonly COMFYUI_BIREFNET_NODE_COMMIT="5443a2aa16cfbd98bb2f7dcc8bdcb70439e08529"
# Pinned commit of comfyui-inpaint-nodes (GPL-3.0; it loads LaMa from
# models/inpaint/big-lama.pt, model set "lama", through spandrel, which
# ComfyUI already has); bump it to update.
readonly COMFYUI_INPAINT_NODE_COMMIT="5b7681746fe19e563113d27366ba85236bc1ba5b"

# The models are downloaded into a checkout that also holds
# PyTorch and CUDA libraries (~8 GB) on top of them.
readonly COMFYUI_MIN_FREE_GB=45

comfyui_python() {
    echo "$COMFYUI_DIR/.venv/bin/python"
}

# Installs Python packages into ComfyUI's environment: with its
# pip, or with uv when the environment was made by uv (no pip in
# it). Arguments: what pip install takes.
comfyui_pip_install() {
    if "$(comfyui_python)" -m pip --version > /dev/null 2>&1; then
        run "$(comfyui_python)" -m pip install "$@"
    elif binary_exists uv; then
        run uv pip install --python "$(comfyui_python)" "$@"
    else
        run "$(comfyui_python)" -m pip install "$@"
    fi
}

comfyui_is_installed() {
    file_exists "$COMFYUI_DIR/main.py" && file_exists "$(comfyui_python)"
}

comfyui_free_space_gb() {
    df -BG --output=avail "$1" 2> /dev/null | tail -1 | tr -dc '0-9'
}

# Skips the current step when COMFYUI_DIR is not set, the
# machine is not amd64 or (outside a dry run) ComfyUI is not
# installed yet. Use as:
#
#   comfyui_step_applies || return 0
comfyui_step_applies() {
    if [[ -z "$COMFYUI_DIR" ]]; then
        skip_step "COMFYUI_DIR not set"
        return 1
    fi

    require_architecture amd64 || return 1

    if ! comfyui_is_installed && ! is_dry_run; then
        skip_step "ComfyUI not installed"
        return 1
    fi
}

# Installs ComfyUI and its Python environment (PyTorch built
# for CUDA).
install_comfyui() {
    local parent

    if [[ -z "$COMFYUI_DIR" ]]; then
        skip_step "COMFYUI_DIR not set"
        return 0
    fi

    require_architecture amd64 || return 0

    if comfyui_is_installed; then
        skip_step "Already installed"
        return 0
    fi

    parent="$(dirname "$COMFYUI_DIR")"
    run mkdir -p "$parent"

    if ! is_dry_run && (( $(comfyui_free_space_gb "$parent") < COMFYUI_MIN_FREE_GB )); then
        print_info "   Point COMFYUI_DIR at a disk with more room in config.sh."
        warn_step "Less than ${COMFYUI_MIN_FREE_GB} GB free in $parent"
        return 0
    fi

    # python3-venv is not always installed with python3.
    if ! is_dry_run && ! python3 -c 'import ensurepip, venv' 2> /dev/null; then
        warn_step "python3 cannot create virtual environments (install python3-venv)"
        return 0
    fi

    if ! directory_exists "$COMFYUI_DIR/.git"; then
        run git clone "$COMFYUI_REPO" "$COMFYUI_DIR"
    fi

    run python3 -m venv "$COMFYUI_DIR/.venv"
    # PyTorch first: its CUDA build comes from PyTorch's own
    # index, not from PyPI, and ComfyUI's requirements would
    # otherwise pull the CPU-only wheel.
    run "$(comfyui_python)" -m pip install --upgrade pip
    run "$(comfyui_python)" -m pip install torch torchvision torchaudio --index-url "$COMFYUI_TORCH_INDEX_URL"
    run "$(comfyui_python)" -m pip install -r "$COMFYUI_DIR/requirements.txt"
}

# Installs the ComfyUI-GGUF node, the SAM 2 nodes (pinned; they
# need no extra Python packages), the BiRefNet nodes (pinned), the
# inpaint nodes (pinned; no extra packages either) and this setup's
# own nodes (BBoxFromJSON, which lets API clients give
# SAM 2 box prompts).
install_comfyui_nodes() {
    local gguf_dir="$COMFYUI_DIR/custom_nodes/ComfyUI-GGUF"
    local sam2_dir="$COMFYUI_DIR/custom_nodes/ComfyUI-segment-anything-2"
    local birefnet_dir="$COMFYUI_DIR/custom_nodes/ComfyUI_BiRefNet_ll"
    local birefnet_changed=false
    local inpaint_dir="$COMFYUI_DIR/custom_nodes/comfyui-inpaint-nodes"
    local own_dir="$COMFYUI_DIR/custom_nodes/local_ai_setup_nodes"
    # the same nodes, from when linux-mint-setup installed ComfyUI: two
    # copies would register BBoxFromJSON twice
    local old_own_dir="$COMFYUI_DIR/custom_nodes/linux_mint_setup_nodes"
    local changed=false

    comfyui_step_applies || return 0

    if directory_exists "$old_own_dir"; then
        run rm -rf "$old_own_dir"
        changed=true
    fi

    if ! directory_exists "$gguf_dir"; then
        run git clone "$COMFYUI_GGUF_NODE_REPO" "$gguf_dir"
        comfyui_pip_install -r "$gguf_dir/requirements.txt"
        changed=true
    fi

    if ! directory_exists "$sam2_dir/.git"; then
        run git clone "$COMFYUI_SAM2_NODE_REPO" "$sam2_dir"
        changed=true
    fi

    if [[ "$(git -C "$sam2_dir" rev-parse HEAD 2> /dev/null)" != "$COMFYUI_SAM2_NODE_COMMIT" ]]; then
        run git -C "$sam2_dir" fetch --quiet origin
        run git -C "$sam2_dir" checkout --quiet "$COMFYUI_SAM2_NODE_COMMIT"
        changed=true
    fi

    if ! directory_exists "$birefnet_dir/.git"; then
        run git clone "$COMFYUI_BIREFNET_NODE_REPO" "$birefnet_dir"
        birefnet_changed=true
    fi

    if [[ "$(git -C "$birefnet_dir" rev-parse HEAD 2> /dev/null)" != "$COMFYUI_BIREFNET_NODE_COMMIT" ]]; then
        run git -C "$birefnet_dir" fetch --quiet origin
        run git -C "$birefnet_dir" checkout --quiet "$COMFYUI_BIREFNET_NODE_COMMIT"
        birefnet_changed=true
    fi

    # Its Python packages (timm, opencv), whenever the node is new or
    # changed, and when one is missing (an earlier run stopped half-way).
    if [[ "$birefnet_changed" == true ]] ||
        ! "$(comfyui_python)" -c 'import timm, cv2' 2> /dev/null; then
        comfyui_pip_install -r "$birefnet_dir/requirements.txt"
        changed=true
    fi

    if ! directory_exists "$inpaint_dir/.git"; then
        run git clone "$COMFYUI_INPAINT_NODE_REPO" "$inpaint_dir"
        changed=true
    fi

    if [[ "$(git -C "$inpaint_dir" rev-parse HEAD 2> /dev/null)" != "$COMFYUI_INPAINT_NODE_COMMIT" ]]; then
        run git -C "$inpaint_dir" fetch --quiet origin
        run git -C "$inpaint_dir" checkout --quiet "$COMFYUI_INPAINT_NODE_COMMIT"
        changed=true
    fi

    if ! diff -rq "$COMFYUI_OWN_NODES_DIR" "$own_dir" -x __pycache__ > /dev/null 2>&1; then
        run mkdir -p "$own_dir"
        run cp -r "$COMFYUI_OWN_NODES_DIR/." "$own_dir/"
        changed=true
    fi

    if [[ "$changed" == false ]]; then
        skip_step "Already installed"
        return 0
    fi

    # A running ComfyUI only loads nodes when it starts.
    if systemctl --user is-active --quiet comfyui 2> /dev/null; then
        run systemctl --user restart comfyui
    fi
}

# Prints "directory<tab>sha256<tab>url<tab>file name" for every
# model of the sets in COMFYUI_MODEL_SETS (comma or space
# separated); the file name is the URL's unless models.tsv names
# one. A file two sets share (the Qwen-Image VAE of qwen and
# anima) is printed once.
comfyui_selected_models() {
    local sets="${COMFYUI_MODEL_SETS//,/ }"
    local set

    for set in $sets; do
        awk -F'\t' -v set="$set" '$1 == set { n = split($4, parts, "/"); print $2 "\t" $3 "\t" $4 "\t" ($5 != "" ? $5 : parts[n]) }' "$COMFYUI_MODELS_FILE"
    done | awk -F'\t' '!seen[$1 "/" $4]++'
}

# Checks a model file against its SHA-256. A verified file
# keeps a marker next to it holding its checksum, so later
# runs do not re-hash tens of GB.
#
# Arguments:
#   $1 - File
#   $2 - Expected SHA-256
comfyui_file_has_checksum() {
    local file="$1"
    local checksum="$2"
    local marker="$file.sha256"

    if file_exists "$marker" && [[ "$(< "$marker")" == "$checksum" ]]; then
        return 0
    fi

    print_info "   Verifying ${file##*/} ..."

    if [[ "$(sha256sum "$file" | awk '{ print $1 }')" != "$checksum" ]]; then
        return 1
    fi

    if ! is_dry_run; then
        printf '%s\n' "$checksum" > "$marker"
    fi
}

# Downloads one model file, resuming a partial download,
# and keeps it only when its checksum matches.
#
# Arguments:
#   $1 - Directory under ComfyUI's models/
#   $2 - Expected SHA-256
#   $3 - URL
#   $4 - File name
#
# Returns:
#   0 - downloaded now
#   1 - failed
#   2 - already there and verified
comfyui_download_model() {
    local directory="$1"
    local checksum="$2"
    local url="$3"
    local file_name="$4"
    local target="$COMFYUI_DIR/models/$directory/$file_name"

    if file_exists "$target" && comfyui_file_has_checksum "$target" "$checksum"; then
        return 2
    fi

    print_info "➜ Download $file_name ($directory)"

    if is_dry_run; then
        return 0
    fi

    mkdir -p "${target%/*}"

    # </dev/null keeps curl from ever reading the model list
    # off stdin.
    if ! curl -fSL --progress-bar -C - -o "$target" "$url" < /dev/null; then
        print_info "   ⚠️ Download failed: $url"
        return 1
    fi

    if ! comfyui_file_has_checksum "$target" "$checksum"; then
        print_info "   ⚠️ Checksum mismatch, removing $file_name"
        rm -f "$target"
        return 1
    fi
}

# Downloads the models of the selected sets.
configure_comfyui_models() {
    local failed=0
    local wanted=0
    local present=0
    local status
    local directory checksum url file_name

    comfyui_step_applies || return 0

    if [[ -z "$COMFYUI_MODEL_SETS" ]]; then
        skip_step "COMFYUI_MODEL_SETS empty"
        return 0
    fi

    while IFS=$'\t' read -r directory checksum url file_name; do
        [[ -n "$url" ]] || continue
        wanted=$((wanted + 1))
        status=0
        comfyui_download_model "$directory" "$checksum" "$url" "$file_name" || status=$?
        case "$status" in
            0) ;;
            2) present=$((present + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done < <(comfyui_selected_models)

    if (( wanted == 0 )); then
        print_info "   Known sets: $(awk -F'\t' '!/^#/ && NF { print $1 }' "$COMFYUI_MODELS_FILE" | sort -u | tr '\n' ' ')"
        warn_step "No models match COMFYUI_MODEL_SETS=$COMFYUI_MODEL_SETS"
        return 0
    fi

    if (( failed > 0 )); then
        print_info "   Re-run the setup to resume the downloads."
        warn_step "$failed of $wanted model file(s) failed"
        return 0
    fi

    if (( present == wanted )); then
        skip_step "All $wanted model file(s) already present"
    fi
}

# --disable-dynamic-vram: dynamic VRAM loading (ComfyUI's default since
# late 2026) reserves nearly all of a 6 GB GPU for FLUX.2 klein's 7.6 GB
# text encoder, leaving it no room to run: CUDA out of memory on every
# klein edit (2026-10-28).
comfyui_service_unit() {
    cat << EOF
[Unit]
Description=ComfyUI (local image generation and editing) on 127.0.0.1:$COMFYUI_PORT

[Service]
WorkingDirectory=$COMFYUI_DIR
ExecStart=$(comfyui_python) main.py --listen 127.0.0.1 --port $COMFYUI_PORT --disable-dynamic-vram
Restart=on-failure

[Install]
WantedBy=default.target
EOF
}

# Writes the `comfyui` systemd user service. Deliberately not
# enabled: it holds GPU memory while it runs.
configure_comfyui_service() {
    comfyui_step_applies || return 0

    if comfyui_service_unit | cmp -s - "$COMFYUI_SERVICE_UNIT" 2> /dev/null; then
        skip_step "Already configured"
        return 0
    fi

    comfyui_service_unit | write_file "$COMFYUI_SERVICE_UNIT"
    run systemctl --user daemon-reload

    print_info "   GIMP and GIMPhoto start it when they open; by hand:"
    print_info "   systemctl --user start comfyui, then open http://127.0.0.1:$COMFYUI_PORT"
}
