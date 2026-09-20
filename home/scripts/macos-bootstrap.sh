#!/usr/bin/env bash
#
# Script: macos-bootstrap.sh
# Purpose: Prepare Homebrew and restore macOS configuration.
# Version: 1.0.0
# Requires: macOS, network access and a terminal. Starts with Apple Bash.
# Documentation: docs/USER-MANUAL.md
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION='1.0.0'
GITHUB_USER=${GITHUB_USER:-phillipmcmahon}
GITHUB_REPO=${GITHUB_REPO:-macos-config}
GIT_BRANCH=${GIT_BRANCH:-main}
REPO_DIR=${REPO_DIR:-$HOME/.local/share/macos-config}
ASKPASS_FILE='' PACKAGE_FAILURE=0

# Command interface
usage() {
    cat << EOF
${0##*/} $SCRIPT_VERSION
Usage: /bin/bash ${0##*/} [--dry-run]

Install Homebrew if necessary, prepare Bash/rsync/jq, clone via HTTPS,
install the recorded Brewfile and restore configuration with Homebrew Bash.
SSH private keys are not restored. Configure your SSH agent separately.

Options:
  --dry-run     Explain steps without installing, cloning or restoring
  --version     Show version
  -h, --help    Show help

Environment: GITHUB_USER, GITHUB_REPO, GIT_BRANCH, REPO_DIR, MACHINE_NAME.
GITHUB_PAT is optional. Otherwise existing Git authentication is tried first.
EOF
}

# Helpers
emit() {
    local level=$1 fd=$2 colour='' reset=''
    shift 2
    if [[ -t $fd && -z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; then
        case $level in OK) colour=$'\033[32m' ;; WARN) colour=$'\033[33m' ;; ERROR) colour=$'\033[31m' ;; STEP) colour=$'\033[36m' ;; esac
        reset=$'\033[0m'
    fi
    printf '%s[%s] %s%s\n' "$colour" "$level" "$*" "$reset" >&"$fd"
}

log() { emit INFO 1 "$*"; }

ok() { emit OK 1 "$*"; }

step() { emit STEP 1 "$*"; }

warn() { emit WARN 2 "$*"; }

die() {
    emit ERROR 2 "$*"
    exit 1
}

cleanup() {
    local rc=$?
    trap - EXIT
    [[ -z $ASKPASS_FILE ]] || rm -f -- "$ASKPASS_FILE" || rc=1
    unset GITHUB_PAT
    exit "$rc"
}

# Operations
main() {
    local brew_bin bash_bin sync_script clone_url machine brewfile='' candidate choice i=0 dry_run=0 installer
    local candidates=()
    while (($#)); do
        case $1 in
            --dry-run) dry_run=1 ;;
            --version)
                printf '%s\n' "$SCRIPT_VERSION"
                return
                ;;
            --help | -h)
                usage
                return
                ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    if ((dry_run)); then
        log "Would install Homebrew and prerequisites, clone $GITHUB_USER/$GITHUB_REPO to $REPO_DIR, install a Brewfile and restore configuration."
        log 'This is an operation explanation. No network or filesystem changes performed.'
        return 0
    fi
    [[ $(uname -s) == Darwin ]] || die 'This operation requires macOS.'
    [[ -t 0 || -r /dev/tty ]] || die 'Bootstrap requires an interactive terminal.'
    [[ ! -e $REPO_DIR && ! -L $REPO_DIR ]] || die "Destination already exists: $REPO_DIR"
    [[ $GITHUB_USER =~ ^[A-Za-z0-9-]+$ && $GITHUB_REPO =~ ^[A-Za-z0-9_.-]+$ ]] || die 'Invalid GitHub repository name.'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    brew_bin=$(command -v brew || true)
    if [[ -z $brew_bin ]]; then
        step 'Installing Homebrew'
        installer=$(curl --fail --silent --show-error --location --connect-timeout 15 --max-time 120 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)
        /bin/bash -c "$installer"
        if [[ -x /opt/homebrew/bin/brew ]]; then brew_bin=/opt/homebrew/bin/brew; else brew_bin=/usr/local/bin/brew; fi
    fi
    eval "$("$brew_bin" shellenv)"
    step 'Preparing Homebrew Bash, rsync and jq'
    "$brew_bin" install bash rsync jq
    bash_bin="$("$brew_bin" --prefix)/bin/bash"
    [[ -x $bash_bin ]] || die 'Homebrew Bash is unavailable.'
    clone_url="https://github.com/$GITHUB_USER/$GITHUB_REPO.git"
    if [[ -z ${GITHUB_PAT:-} ]] && GIT_TERMINAL_PROMPT=0 git ls-remote "$clone_url" HEAD > /dev/null 2>&1; then
        log 'Git can access the repository using its current authentication configuration.'
        GIT_TERMINAL_PROMPT=0 git clone --branch "$GIT_BRANCH" "$clone_url" "$REPO_DIR"
    else
        if [[ -z ${GITHUB_PAT:-} ]]; then
            printf 'GitHub PAT (Contents: read-only for this repository): ' >&2
            IFS= read -rs GITHUB_PAT < /dev/tty
            printf '\n' >&2
        fi
        [[ -n ${GITHUB_PAT:-} ]] || die 'No token supplied.'
        ASKPASS_FILE=$(mktemp)
        chmod 700 "$ASKPASS_FILE"
        cat > "$ASKPASS_FILE" << 'HELPER'
#!/bin/bash
case $1 in
    *[Uu]sername*) printf '%s\n' "$GITHUB_USER" ;;
    *) printf '%s\n' "$GITHUB_PAT" ;;
esac
HELPER
        export GITHUB_USER GITHUB_PAT
        GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$ASKPASS_FILE" git -c credential.helper= clone --branch "$GIT_BRANCH" "$clone_url" "$REPO_DIR"
        rm "$ASKPASS_FILE"
        ASKPASS_FILE=''
        warn 'Revoke the bootstrap token when it is no longer needed.'
    fi
    unset GITHUB_PAT
    git -C "$REPO_DIR" remote set-url origin "git@github.com:$GITHUB_USER/$GITHUB_REPO.git"
    machine=${MACHINE_NAME:-$(scutil --get LocalHostName 2> /dev/null || hostname -s)}
    machine=$(printf '%s' "$machine" | tr -c 'A-Za-z0-9._-' '-')
    [[ -n $machine && $machine != . && $machine != .. ]] || die 'Invalid machine name.'
    if [[ -f $REPO_DIR/machines/$machine/home/Brewfile ]]; then
        brewfile=$REPO_DIR/machines/$machine/home/Brewfile
    elif [[ -f $REPO_DIR/home/Brewfile ]]; then
        brewfile=$REPO_DIR/home/Brewfile
    else
        shopt -s nullglob
        for candidate in "$REPO_DIR"/machines/*/home/Brewfile; do
            candidates+=("$candidate")
            i=$((i + 1))
            log "$i) $candidate"
        done
        if ((i > 0)); then
            printf 'Choose a Brewfile number, or Enter to skip: ' >&2
            IFS= read -r choice < /dev/tty || choice=''
            if [[ $choice =~ ^[1-9][0-9]*$ ]] && ((choice <= i)); then brewfile=${candidates[choice - 1]}; fi
        fi
    fi
    if [[ -n $brewfile ]]; then
        if ! "$brew_bin" bundle --file="$brewfile"; then
            PACKAGE_FAILURE=1
            warn "Some packages failed. Retry brew bundle with: $brewfile"
        fi
    else warn 'No Brewfile selected. Only bootstrap prerequisites were installed.'; fi
    sync_script=$REPO_DIR/home/scripts/macos-config-sync.sh
    [[ -f $sync_script && -f ${sync_script%/*}/lib/common.sh ]] || die "Sync script or adjacent lib missing: $sync_script"
    REPO_DIR="$REPO_DIR" GIT_BRANCH="$GIT_BRANCH" MACHINE_NAME="$machine" "$bash_bin" "$sync_script" restore --yes
    ok 'Configuration restored. Open a new shell and configure your SSH agent.'
    ((PACKAGE_FAILURE == 0))
}

# Entry point
main "$@"
