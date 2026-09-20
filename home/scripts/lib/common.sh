#!/usr/bin/env bash
#
# Script: common.sh
# Purpose: Provide shared output, literal configuration and filesystem helpers.
# Version: 1.0.0
# Requires: Bash 5+. Source from a public entrypoint.
# Documentation: docs/USER-MANUAL.md
#

require_bash() {
    ((BASH_VERSINFO[0] >= 5)) || {
        printf 'ERROR: Bash 5+ required. Run with /opt/homebrew/bin/bash.\n' >&2
        exit 1
    }
}
require_bash

# Preserve the caller's PATH so configured Homebrew tools and test doubles work.
# The interpreter has already been selected by the incoming PATH or invocation.
setup_colours() {
    C_GREEN='' C_RED='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_RESET=''
    if [[ -t 1 && ! ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; then
        C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[36m' C_CYAN=$'\033[36m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
    fi
}
setup_colours
emit() {
    local level=$1 fd=$2 colour='' reset='' message
    shift 2
    message=$*
    if [[ -t $fd && ! ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; then
        case $level in
            OK) colour=$'\033[32m' ;;
            WARN) colour=$'\033[33m' ;;
            ERROR) colour=$'\033[31m' ;;
            STEP) colour=$'\033[36m' ;;
        esac
        reset=$'\033[0m'
    fi
    printf '%s[%s] %s%s\n' "$colour" "$level" "$message" "$reset" >&"$fd"
    if [[ -n ${LOG_FILE:-} ]]; then
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG_FILE"
    fi
}
log() { emit INFO 1 "$*"; }
step() { emit STEP 1 "$*"; }
ok() { emit OK 1 "$*"; }
warn() { emit WARN 2 "$*"; }
err() { emit ERROR 2 "$*"; }
die() {
    err "$*"
    exit 1
}
require_cmds() {
    local cmd
    for cmd in "$@"; do command -v "$cmd" > /dev/null 2>&1 || die "Required command not found: $cmd"; done
}
require_macos() { [[ $(uname -s) == Darwin ]] || die 'This operation requires macOS.'; }
confirm() {
    local reply
    [[ ${ASSUME_YES:-0} == 1 ]] && return 0
    [[ -t 0 ]] || {
        err 'Confirmation requires a terminal or --yes.'
        return 1
    }
    printf '%s [y/N] ' "$*" >&2
    IFS= read -r reply || return 1
    [[ $reply == y || $reply == Y || $reply == yes ]]
}
sha256_of() {
    local result digest
    if command -v shasum > /dev/null 2>&1; then
        result=$(shasum -a 256 -- "$1") || return 1
    else
        result=$(sha256sum -- "$1") || return 1
    fi
    digest=${result%% *}
    [[ $digest =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s\n' "${digest,,}"
}
reject_symlinks() {
    local path=$1 current='' component
    [[ $path == /* ]] || {
        err "Absolute path required: $path"
        return 1
    }
    local -a parts
    IFS=/ read -r -a parts <<< "$path"
    for component in "${parts[@]}"; do
        [[ -n $component ]] || continue
        [[ $component != .. && $component != . ]] || {
            err "Non-canonical path: $path"
            return 1
        }
        current+=/$component
        [[ ! -L $current ]] || {
            err "Symbolic link not supported: $current"
            return 1
        }
    done
}
private_config() {
    local metadata owner mode
    reject_symlinks "$1" || return 1
    [[ -f $1 && -r $1 ]] || {
        err "Configuration is not a readable regular file: $1"
        return 1
    }
    metadata=$(stat -f '%u %Lp' "$1" 2> /dev/null) || metadata=$(stat -c '%u %a' "$1") || return 1
    IFS=" " read -r owner mode <<< "$metadata"
    [[ $owner == "$EUID" && $mode =~ ^[0-7]+$ ]] || return 1
    (((8#$mode & 8#022) == 0)) || {
        err "Configuration is writable by others: $1"
        return 1
    }
}
# Supports KEY=value and KEY=(literal values), comments and single/double quotes.
# No expansions, escapes, substitutions, source commands or shell operators.
# Allowed variable names are supplied by the caller. Arrays replace defaults.
load_config() {
    local file=$1 allowed=" $2 " input char token='' quote='' started=0 comment=0 i key value
    [[ -e $file || -L $file ]] || return 0
    private_config "$file" || return 1
    input=$(cat -- "$file") || return 1
    local -a tokens=() values=()
    local -A seen=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if ((comment)); then
            [[ $char != $'\n' ]] && continue
            comment=0
        fi
        if [[ -n $quote ]]; then
            if [[ $char == "$quote" ]]; then
                quote=''
            else
                [[ $char != '$' && $char != '`' && $char != '\' && $char != $'\n' && $char != $'\r' ]] || {
                    err 'Unsupported character in configuration value.'
                    return 1
                }
                token+=$char
            fi
            continue
        fi
        case $char in
            "'" | '"')
                quote=$char
                started=1
                ;;
            '#')
                ((started == 0)) || {
                    err 'Separate comments from values with whitespace.'
                    return 1
                }
                comment=1
                ;;
            ' ' | $'\t' | $'\r' | $'\n' | '=' | '(' | ')')
                if ((started)); then
                    tokens+=("$token")
                    token=''
                    started=0
                fi
                case $char in '=' | '(' | ')') tokens+=("$char") ;; esac
                ;;
            '$' | '`' | '\' | ';' | '&' | '|' | '<' | '>')
                err 'Shell expressions are not permitted in configuration.'
                return 1
                ;;
            *)
                token+=$char
                started=1
                ;;
        esac
    done
    [[ -z $quote ]] || {
        err 'Unclosed quote in configuration.'
        return 1
    }
    ((started == 0)) || tokens+=("$token")
    i=0
    while ((i < ${#tokens[@]})); do
        key=${tokens[i++]}
        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $allowed == *" $key "* && ! ${seen[$key]+x} ]] || {
            err "Unknown or repeated setting: $key"
            return 1
        }
        seen[$key]=1
        [[ ${tokens[i++]:-} == = ]] || {
            err "Expected assignment for $key"
            return 1
        }
        if [[ ${tokens[i]:-} == '(' ]]; then
            ((i += 1))
            values=()
            while ((i < ${#tokens[@]})) && [[ ${tokens[i]} != ')' ]]; do values+=("${tokens[i++]}"); done
            [[ ${tokens[i++]:-} == ')' ]] || {
                err "Unclosed array: $key"
                return 1
            }
            local -n config_target_ref=$key
            config_target_ref=("${values[@]}")
            unset -n config_target_ref
        else
            ((i < ${#tokens[@]})) || return 1
            value=${tokens[i++]}
            [[ $value != '=' && $value != ')' ]] || return 1
            printf -v "$key" '%s' "$value"
        fi
    done
}
# Lock directories are never automatically removed on PID evidence alone.
# Only this process's token authorises release. Stale locks need manual review.
COMMON_LOCK='' COMMON_LOCK_TOKEN=''
lock_acquire() {
    local path=$1
    [[ -z $COMMON_LOCK ]] || {
        err 'A lock is already held.'
        return 1
    }
    reject_symlinks "$path" || return 1
    mkdir -p -- "${path%/*}" || return 1
    if ! mkdir -- "$path" 2> /dev/null; then
        err "Lock exists: $path. Inspect its owner and confirm no process is active before removing it."
        return 1
    fi
    COMMON_LOCK=$path COMMON_LOCK_TOKEN="$$-$RANDOM-$RANDOM"
    printf '%s\n' "$COMMON_LOCK_TOKEN" > "$path/owner" || return 1
}
lock_release() {
    if [[ -n $COMMON_LOCK && -f $COMMON_LOCK/owner && $(cat "$COMMON_LOCK/owner") == "$COMMON_LOCK_TOKEN" ]]; then
        rm -- "$COMMON_LOCK/owner" && rmdir -- "$COMMON_LOCK" || return 1
    fi
    COMMON_LOCK='' COMMON_LOCK_TOKEN=''
}
# Check both the mount point and filesystem type, not merely its directory.
nas_mount_available() {
    local root=$1 result
    [[ -d $root && ! -L $root && $root != / ]] || return 1
    result=$(LC_ALL=C mount) || return 1
    [[ $result == *" on $root (smbfs,"* || $result == *" on $root (smbfs)"* ]]
}
validate_remote_dir() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*$ && $1 != . && $1 != .. && $1 != */ && $1 != *'//'* &&
        /$1/ != */../* && /$1/ != */./* ]] || {
        err "Dedicated relative NAS directory required: $1"
        return 1
    }
}
validate_child_dir() {
    [[ $2 == "$1/"* && $2 != "$1/" ]] || {
        err "Destination must be beneath $1: $2"
        return 1
    }
    reject_symlinks "$2"
}
move_no_replace() {
    [[ ! -e $2 && ! -L $2 ]] || return 1
    mv -n -- "$1" "$2" || return 1
    [[ ! -e $1 && ! -L $1 ]]
}
