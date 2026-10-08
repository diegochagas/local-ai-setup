#!/usr/bin/env bash
#
# Local AI Setup
#
# Installs the local AI models this machine's applications
# use: ComfyUI with its image models (GIMPhoto, gimp-setup,
# comic-skills, photo-restore) and Ollama (Goose, comic-skills,
# tvshow-skills, Digivice). The shared helpers live in lib/,
# each step in its own file under steps/, and
# run_setup_steps below lists them in execution order.
#

set -Eeuo pipefail

readonly VERSION="0.1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

if [[ ! -d "$SCRIPT_DIR/lib" || ! -d "$SCRIPT_DIR/steps" ]]; then
    cat >&2 << EOF
❌ setup.sh needs the lib/ and steps/ directories next to it.

Download the whole repository and run the setup from there:

    curl -fsSL https://github.com/diegochagas/local-ai-setup/archive/refs/heads/main.tar.gz | tar -xz
    cd local-ai-setup-main
    ./setup.sh
EOF
    exit 1
fi

########################################
# Configuration
########################################

if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    # shellcheck source=config.sh.example
    source "$SCRIPT_DIR/config.sh"
fi

########################################
# Libraries and steps
########################################

# shellcheck source-path=SCRIPTDIR

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/exec.sh"
source "$SCRIPT_DIR/lib/step.sh"
source "$SCRIPT_DIR/lib/system.sh"
source "$SCRIPT_DIR/lib/preflight.sh"

source "$SCRIPT_DIR/steps/comfyui/comfyui.sh"
source "$SCRIPT_DIR/steps/ollama.sh"


trap 'handle_error $? "${BASH_SOURCE[0]}" $LINENO "$BASH_COMMAND"' ERR
trap 'cleanup_workspace' EXIT

########################################
# Command line
########################################

print_help() {
    cat << EOF
Local AI Setup v$VERSION

Usage:
    ./setup.sh [options]

Options:
    --dry-run           Simulate the setup.
    --help              Show help.
    --version           Show version.

Examples:
    ./setup.sh

    ./setup.sh --dry-run
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;

            --help)
                print_help
                exit 0
                ;;

            --version)
                echo "$VERSION"
                exit 0
                ;;

            *)
                echo "❌ Unknown argument: $1" >&2
                echo >&2
                echo "Run './setup.sh --help' for usage information." >&2
                exit 1
                ;;
        esac
    done
}

########################################
# Steps, in execution order
########################################

run_setup_steps() {
    run_step install   "ComfyUI"             install_comfyui
    run_step install   "ComfyUI Nodes"       install_comfyui_nodes
    run_step configure "ComfyUI Models"      configure_comfyui_models
    run_step configure "ComfyUI Service"     configure_comfyui_service
    run_step install   "Ollama"              install_ollama
    run_step configure "Ollama Models Dir"   configure_ollama
}

########################################
# Main
########################################

main() {
    parse_arguments "$@"

    initialize_log
    initialize_workspace

    write_log_header
    print_banner

    run_preflight_checks
    run_setup_steps

    print_section "Setup complete!"
    print_summary

    write_log_footer
}

main "$@"
