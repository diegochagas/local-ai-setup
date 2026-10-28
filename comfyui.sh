#!/usr/bin/env bash
#
# ComfyUI session: starts the `comfyui` user service written by
# setup.sh, lets you edit pictures with the installed models, and
# stops the service again when you leave (or the terminal closes),
# freeing the GPU memory.
#
#   ./comfyui.sh [picture] [--model klein]
#       chat in the terminal: type what to change, the model edits
#       the picture, the next instruction edits that result
#       (image-chat/); results in ~/Downloads/<picture name> edits/
#   ./comfyui.sh --web [--no-browser]
#       ComfyUI's web UI in the browser, its log here; Ctrl+C stops
#
# The port and ComfyUI's directory come from the service itself
# (setup.sh's COMFYUI_PORT and COMFYUI_DIR), so this script needs no
# configuration of its own.
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SERVICE="comfyui"
readonly SERVICE_UNIT="$HOME/.config/systemd/user/$SERVICE.service"
# Loading the Python environment and the custom nodes takes ~10 s;
# give a slow disk plenty of room before giving up.
readonly STARTUP_TIMEOUT_SECONDS=180

# Prints the value after `pattern` in the service unit.
# Arguments: a grep -P pattern ending in \K, a description for errors.
unit_value() {
    local value

    value="$(grep -oP -- "$1" "$SERVICE_UNIT" | head -n 1)"
    if [[ -z "$value" ]]; then
        echo "❌ No $2 in $SERVICE_UNIT" >&2
        return 1
    fi
    echo "$value"
}

require_service() {
    if [[ -f "$SERVICE_UNIT" ]]; then
        return 0
    fi
    echo "❌ $SERVICE_UNIT not found: run ./setup.sh with COMFYUI_DIR set first." >&2
    exit 1
}

stop_comfyui() {
    trap - EXIT INT TERM HUP
    [[ -n "${LOG_PID:-}" ]] && kill "$LOG_PID" 2> /dev/null
    echo
    echo "⏹  Stopping ComfyUI..."
    systemctl --user stop "$SERVICE"
    echo "✅ ComfyUI stopped, GPU memory freed."
}

# Waits until ComfyUI answers on its port. Argument: the URL.
wait_until_ready() {
    local url="$1" waited=0

    until curl -fs -o /dev/null "$url"; do
        if ! systemctl --user is-active --quiet "$SERVICE"; then
            echo "❌ The $SERVICE service exited while starting; its log:" >&2
            journalctl --user -u "$SERVICE" -n 30 --no-pager --output=cat >&2
            exit 1
        fi
        if (( waited >= STARTUP_TIMEOUT_SECONDS )); then
            echo "❌ ComfyUI did not answer on $url within ${STARTUP_TIMEOUT_SECONDS}s" >&2
            exit 1
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done
}

# Starts the service and waits for it; it is stopped when this script
# exits, however it exits. Argument: the URL.
start_comfyui() {
    trap stop_comfyui EXIT
    trap 'exit 0' INT TERM HUP
    echo "▶  Starting ComfyUI..."
    systemctl --user start "$SERVICE"
    wait_until_ready "$1"
    echo "✅ ComfyUI is ready at $1"
}

# Web UI mode. Arguments: the URL, then --no-browser or nothing.
run_web() {
    local url="$1"

    echo "   Edit pictures with a saved workflow (Workflow > Open) or a template"
    echo "   (Workflow > Browse Templates). Press Ctrl+C to stop ComfyUI."
    echo
    if [[ "${2:-}" != "--no-browser" ]] && command -v xdg-open > /dev/null; then
        xdg-open "$url" > /dev/null 2>&1 &
    fi
    journalctl --user -u "$SERVICE" -f -n 0 --output=cat &
    LOG_PID=$!
    wait "$LOG_PID"
}

# Chat mode, with ComfyUI's own Python (it has Pillow).
# Arguments: the URL, then what image-chat/chat.py takes.
run_chat() {
    local url="$1" comfyui_dir

    shift
    comfyui_dir="$(unit_value '^WorkingDirectory=\K.+' "WorkingDirectory")"
    echo
    "$comfyui_dir/.venv/bin/python" "$SCRIPT_DIR/image-chat/chat.py" --url "$url" "$@"
}

main() {
    local url

    require_service
    url="http://127.0.0.1:$(unit_value '--port \K[0-9]+' "--port in ExecStart")"
    start_comfyui "$url"
    if [[ "${1:-}" == "--web" ]]; then
        run_web "$url" "${2:-}"
    else
        run_chat "$url" "$@"
    fi
}

main "$@"
