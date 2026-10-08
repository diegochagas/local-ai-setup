#!/usr/bin/env bash
#
# Ollama, the local language-model server (used by Goose,
# comic-skills' page descriptions, tvshow-skills' subtitle
# translation and Digivice), from its official installation
# script. The script detects an
# NVIDIA GPU and uses it when the driver is installed;
# models larger than the GPU memory are split between the
# GPU and the CPU/RAM automatically.
#
# OLLAMA_MODELS_DIR in config.sh moves the model storage
# (tens of GB) to another disk. It is applied through its
# own systemd drop-in so other drop-ins, such as the one
# written by mini-ai, are left untouched; when the service
# already uses the directory (also through linux-mint-setup's
# old drop-in, from when it installed Ollama), nothing is
# changed.
#

: "${OLLAMA_INSTALL_URL:=https://ollama.com/install.sh}"
: "${OLLAMA_MODELS_DIR:=}"

readonly OLLAMA_DROP_IN="/etc/systemd/system/ollama.service.d/local-ai-setup.conf"

# The ollama service user's home. The installer sometimes
# creates the user without it, and Ollama then fails with
# "mkdir /usr/share/ollama: permission denied".
readonly OLLAMA_HOME="/usr/share/ollama"

# Checks whether the ollama service already stores its
# models in the given directory, owned by the service user.
ollama_uses_models_dir() {
    local models_dir="$1"

    systemctl show ollama -p Environment 2> /dev/null | grep -Fq "OLLAMA_MODELS=$models_dir" &&
        [[ "$(stat -c %U "$models_dir" 2> /dev/null)" == ollama ]]
}

ollama_drop_in() {
    cat << EOF
[Service]
Environment="OLLAMA_MODELS=$1"
EOF
}

install_ollama() {
    if binary_exists ollama; then
        skip_step "Already installed"
        return 0
    fi

    require_architecture amd64 arm64 || return 0

    run_remote_script "$OLLAMA_INSTALL_URL" sh

    run sudo mkdir -p "$OLLAMA_HOME"
    run sudo chown ollama:ollama "$OLLAMA_HOME"
}

configure_ollama() {
    local models_dir

    if [[ -z "$OLLAMA_MODELS_DIR" ]]; then
        skip_step "OLLAMA_MODELS_DIR not set, using Ollama's default"
        return 0
    fi

    if ! binary_exists ollama && ! is_dry_run; then
        skip_step "Ollama not installed"
        return 0
    fi

    models_dir="$(realpath -m "$OLLAMA_MODELS_DIR")"

    if ollama_uses_models_dir "$models_dir"; then
        skip_step "Already configured"
        return 0
    fi

    run sudo mkdir -p "$models_dir"
    run sudo chown ollama:ollama "$models_dir"
    run sudo mkdir -p "${OLLAMA_DROP_IN%/*}"
    ollama_drop_in "$models_dir" | write_root_file "$OLLAMA_DROP_IN"
    run sudo systemctl daemon-reload
    run sudo systemctl restart ollama
}
