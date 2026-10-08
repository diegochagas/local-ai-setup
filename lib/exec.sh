#!/usr/bin/env bash
#
# Command execution, dry-run mode, temporary files and
# error handling.
#
# Every action that changes the system goes through run,
# download_file, run_remote_script, write_file,
# write_root_file or append_to_file, so that --dry-run can
# print the action instead of executing it.
#

DRY_RUN=false

# Root of the temporary directories created by make_work_dir.
WORK_ROOT=""

is_dry_run() {
    [[ "$DRY_RUN" == true ]]
}

run_mode_label() {
    if is_dry_run; then
        echo "Simulation"
    else
        echo "Installation"
    fi
}

# Prints a command and executes it, unless in dry-run mode.
run() {
    local command

    printf -v command '%q ' "$@"
    print_info "➜ ${command% }"

    if is_dry_run; then
        return 0
    fi

    "$@"
}

download_file() {
    local url="$1"
    local target="$2"

    run curl -fL --progress-bar "$url" -o "$target"
}

# Downloads a script and pipes it to an interpreter (sh, bash, ...).
run_remote_script() {
    local url="$1"
    local interpreter="$2"

    print_info "➜ curl -fsSL $url | $interpreter"

    if is_dry_run; then
        return 0
    fi

    curl -fsSL "$url" | "$interpreter"
}

# Writes standard input to a file owned by the current
# user, creating the parent directory if needed.
write_file() {
    local target="$1"

    print_info "➜ Write $target"

    if is_dry_run; then
        cat > /dev/null
        return 0
    fi

    mkdir -p "$(dirname "$target")"
    cat > "$target"
}

# Writes standard input to a file as root.
write_root_file() {
    local target="$1"

    print_info "➜ Write $target (as root)"

    if is_dry_run; then
        cat > /dev/null
        return 0
    fi

    sudo tee "$target" > /dev/null
}

# Appends standard input to a file owned by the current user.
append_to_file() {
    local target="$1"

    print_info "➜ Append to $target"

    if is_dry_run; then
        cat > /dev/null
        return 0
    fi

    cat >> "$target"
}

initialize_workspace() {
    WORK_ROOT="$(mktemp -d -t local-ai-setup.XXXXXX)"
}

cleanup_workspace() {
    if [[ -n "$WORK_ROOT" && -d "$WORK_ROOT" ]]; then
        rm -rf "$WORK_ROOT"
    fi
}

# Prints the path of a new temporary directory. It is
# removed, with everything in it, when the setup exits.
make_work_dir() {
    mktemp -d "$WORK_ROOT/$1.XXXXXX"
}

# Prints the first file under a directory whose name
# matches the pattern. In dry-run mode nothing was really
# downloaded or extracted, so a placeholder path is printed.
find_extracted_file() {
    local directory="$1"
    local pattern="$2"

    if is_dry_run; then
        printf '%s\n' "$directory/$pattern"
        return 0
    fi

    find "$directory" -type f -iname "$pattern" -print -quit
}

# Prints an error message and exits.
abort() {
    print_info "❌ $*"
    exit 1
}

# ERR trap handler.
#
# Arguments:
#   $1 - Exit code
#   $2 - Source file of the failing command
#   $3 - Line number
#   $4 - Command
handle_error() {
    local exit_code="$1"
    local source_file="$2"
    local line="$3"
    local command="$4"

    print_info
    print_info "❌ Setup failed!"
    print_info

    print_field "Exit code:" "$exit_code"
    print_field "Location:" "${source_file#"$SCRIPT_DIR/"}:$line"
    print_field "Command:" "$command"

    print_info
    print_info "See log:"
    print_info "  $LOG_FILE"

    exit "$exit_code"
}
