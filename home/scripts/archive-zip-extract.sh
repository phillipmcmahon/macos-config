#!/usr/bin/env bash
#
# Script: archive-zip-extract.sh
# Purpose: Extract ZIP archives without overwriting existing files.
# Version: 1.0.0
# Requires: Bash 5+, unzip and adjacent lib/.
# Documentation: docs/USER-MANUAL.md
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION='1.0.0'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
DRY_RUN=0
ROOT='.'
STAGING=''

# Command interface
usage() {
    cat << EOF
${0##*/} $SCRIPT_VERSION
Usage: ${0##*/} [--dry-run] [DIRECTORY]

Recursively extract ZIPs beside each archive. Internal directories are flattened.
Existing destination files and duplicate flattened names reject that archive.
Archives are retained. New files are published individually without overwriting.

Options:
  --dry-run     Inspect archives and report intended extraction without extracting
  --version     Show version
  -h, --help    Show help
EOF
}

# Helpers
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n $STAGING ]]; then rm -rf -- "$STAGING" || rc=1; fi
    lock_release || rc=1
    exit "$rc"
}

extract_archive() {
    local archive=$1 directory=${1%/*} listing entry name target
    local -a entries=()
    local -A names=()
    # ZIP member listing is line-oriented. Reject control characters rather
    # than claim support for ambiguous member names. Extraction stays staged.
    listing=$(unzip -Z1 "$archive") || {
        err "Cannot list: $archive"
        return 1
    }
    [[ -n $listing ]] || {
        warn "Empty archive: $archive"
        return 0
    }
    mapfile -t entries <<< "$listing"
    for entry in "${entries[@]}"; do
        [[ $entry == */ ]] && continue
        name=${entry##*/}
        [[ -n $name && $name != . && $name != .. && $name != *[[:cntrl:]]* ]] || {
            err "Unsupported member in $archive"
            return 1
        }
        # Case-insensitive comparison is conservative on normal macOS volumes.
        [[ ! ${names[${name,,}]+x} ]] || {
            err "Flattened-name collision in $archive: $name"
            return 1
        }
        names[${name,,}]=1
        target=$directory/$name
        [[ ! -e $target && ! -L $target ]] || {
            err "Destination already exists: $target"
            return 1
        }
    done
    if ((DRY_RUN)); then
        log "Would extract ${#names[@]} file(s): $archive -> $directory"
        return 0
    fi
    STAGING=$(mktemp -d "$directory/.zip-extract.XXXXXXXX") || return 1
    if ! unzip -j -n "$archive" -d "$STAGING" > /dev/null; then
        err "Extraction failed: $archive"
        rm -rf -- "$STAGING"
        STAGING=''
        return 1
    fi
    local count=0 file
    shopt -s nullglob dotglob
    for file in "$STAGING"/*; do
        [[ -f $file && ! -L $file ]] || {
            err 'Archive contains a non-regular file.'
            return 1
        }
        ((count += 1))
    done
    ((count == ${#names[@]})) || {
        err 'Extracted inventory differs from the member list.'
        return 1
    }
    for file in "$STAGING"/*; do
        move_no_replace "$file" "$directory/${file##*/}" || {
            err "Publication stopped. Some files may already be extracted: $archive"
            return 1
        }
    done
    rmdir "$STAGING"
    STAGING=''
    ok "Extracted $count file(s): $archive"
}

# Operations
main() {
    local positional=0 archive rc=0 count=0 failed=0 list_file
    while (($#)); do
        case $1 in
            --dry-run) DRY_RUN=1 ;;
            --version)
                printf '%s\n' "$SCRIPT_VERSION"
                return
                ;;
            -h | --help)
                usage
                return
                ;;
            --)
                shift
                (($# == 1 && positional == 0)) || die 'Expected one directory.'
                ROOT=$1
                positional=1
                break
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                ((positional == 0)) || die 'Only one directory is supported.'
                ROOT=$1
                positional=1
                ;;
        esac
        shift
    done
    require_cmds unzip find mktemp
    [[ -d $ROOT ]] || die "Directory not found: $ROOT"
    ROOT=$(cd -- "$ROOT" && pwd -P)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ((!DRY_RUN)); then lock_acquire "$ROOT/.zip-extract.lock" || exit 1; fi
    # Capture traversal status before processing, including permission failures.
    list_file=$(mktemp)
    if ! find "$ROOT" -type f -iname '*.zip' -print0 > "$list_file"; then
        rm "$list_file"
        die 'Archive discovery failed.'
    fi
    while IFS= read -r -d '' archive; do
        ((count += 1))
        if ! extract_archive "$archive"; then
            ((failed += 1))
            rc=1
            if [[ -n $STAGING ]]; then
                rm -rf -- "$STAGING" || die 'Cannot remove extraction staging.'
                STAGING=''
            fi
        fi
    done < "$list_file"
    rm "$list_file"
    log "Archives inspected: $count. Failed: $failed."
    return "$rc"
}

# Entry point
main "$@"
