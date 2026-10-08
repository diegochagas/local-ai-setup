#!/usr/bin/env bash
#
# Queries about the local system: architecture, files and
# binaries.
#

ARCHITECTURE="$(dpkg --print-architecture)"
readonly ARCHITECTURE

binary_exists() {
    command -v "$1" > /dev/null 2>&1
}

file_exists() {
    [[ -f "$1" ]]
}

directory_exists() {
    [[ -d "$1" ]]
}
