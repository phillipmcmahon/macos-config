#!/usr/bin/env bash
#
# inflate-zips.sh
#
# Version: 1.0.2
#
# v1.0.2:
#   - Changed shebang from #!/bin/bash to #!/usr/bin/env bash for
#     consistency with the rest of the repository and to ensure
#     Homebrew's bash is used on macOS.
#
# v1.0.1:
#   - Removed unused counter variables (count, success, failed). The
#     pipe-to-while subshell means increments inside the loop body would
#     never propagate to the parent shell, so the variables served no
#     purpose.
#
# Recursively extracts ZIP files into their existing directories.
# Internal archive directory paths are discarded (-j flattens).
#
# Usage:
#   inflate-zips.sh [--dry-run] [directory]
#

set -u

DRY_RUN=0
ROOT="."

usage() {
    echo "Usage: $0 [--dry-run] [directory]"
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            ;;
        *)
            ROOT="$1"
            ;;
    esac
    shift
done

if ! command -v unzip >/dev/null 2>&1; then
    echo "ERROR: unzip is not installed or not in PATH." >&2
    exit 1
fi

if [ ! -d "$ROOT" ]; then
    echo "ERROR: directory does not exist: $ROOT" >&2
    exit 1
fi

find "$ROOT" -type f -iname '*.zip' -print0 |
while IFS= read -r -d '' archive; do
    dir=$(dirname "$archive")

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[DRY-RUN] %s -> %s/\n' "$archive" "$dir"
        continue
    fi

    printf 'Extracting: %s\n' "$archive"

    if unzip -j -n "$archive" -d "$dir"; then
        printf 'OK:         %s\n\n' "$archive"
    else
        printf 'FAILED:     %s\n\n' "$archive" >&2
    fi
done
