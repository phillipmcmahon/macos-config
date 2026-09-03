#!/usr/bin/env bash
#
# bootstrap.sh
#
# Version: 1.3.0
#
# v1.3.0:
#   - Replaced PAT-in-URL authentication with GIT_ASKPASS: the token is no
#     longer embedded in the clone URL (which leaks into the process table
#     and would persist in .git/config if the remote-set-url step ever
#     failed).  A mode-700 temp script supplies the token to git via
#     GIT_ASKPASS and is deleted immediately after the clone.
#
# v1.2.0:
#   - Brewfile is now machine-specific: brew bundle reads from
#     machines/<machine-name>/home/Brewfile (matching macos-config-sync.sh
#     v2.0.0), where <machine-name> comes from 'scutil --get LocalHostName'
#     (override with the MACHINE_NAME environment variable)
#   - Falls back to the legacy shared home/Brewfile if no machine-specific
#     Brewfile exists; if other machines' Brewfiles are present instead,
#     offers to install from one of those (useful when bootstrapping a
#     replacement machine with a new name)
#   - Skipping the Brewfile step is non-fatal — configuration restore
#     still runs so the machine is usable
#
# v1.1.0:
#   - brew bundle failures no longer abort the bootstrap — packages that
#     failed to install are logged and the script continues with config
#     restoration so the machine is usable even if some apps are missing
#   - Uses 'macos-config-sync.sh restore' instead of 'pull' to avoid the
#     chicken-and-egg problem where pull contacts the SSH remote before
#     SSH keys have been restored from the repository
#
# v1.0.2:
#   - PAT prompt now reads from /dev/tty so it works when piped via curl
#
# v1.0.1:
#   - Removed --no-lock from brew bundle (flag unavailable on fresh installs)
#
# Sets up a fresh Mac from scratch:
#   1. Installs Homebrew (which installs Xcode Command Line Tools)
#   2. Clones the private macos-config repository via HTTPS
#   3. Runs brew bundle to install all packages
#   4. Runs macos-config-sync.sh restore to restore configuration files
#
# Usage:
#   curl -fsSL <raw-url> | bash
#   — or —
#   bash bootstrap.sh
#
# A GitHub Personal Access Token (PAT) with 'repo' scope is required for the
# initial clone (SSH keys are not yet available on a fresh machine). Create
# one at: https://github.com/settings/tokens
#
# After the first pull restores your SSH keys and Git configuration, the
# sync script uses the SSH remote for all subsequent operations.
#

set -euo pipefail
IFS=$'\n\t'

# ----
# Configuration
# ----

GITHUB_USER="phillipmcmahon"
GITHUB_REPO="macos-config"
GIT_BRANCH="main"
REPO_DIR="$HOME/.local/share/macos-config"
SYNC_SCRIPT="$REPO_DIR/home/scripts/macos-config-sync.sh"

# ----
# Helpers
# ----

log() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

# ----
# Pre-flight
# ----

[[ "$(uname)" == "Darwin" ]] || die "This script is intended for macOS."

[[ ! -d "$REPO_DIR/.git" ]] ||
    die "Repository already exists at $REPO_DIR — use macos-config-sync.sh instead."

# ----
# 1. Homebrew (installs Xcode Command Line Tools automatically)
# ----

if ! command -v brew &>/dev/null; then
    log "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    log "Homebrew installed"
else
    log "Homebrew already installed"
fi

# ----
# 2. Clone the configuration repository
# ----

if [[ -z "${GITHUB_PAT:-}" ]]; then
    log "A GitHub Personal Access Token is required for the initial clone."
    log "Create one at: https://github.com/settings/tokens (repo scope)"
    printf '[bootstrap] GitHub PAT: '
    read -rs GITHUB_PAT </dev/tty
    printf '\n'
fi

[[ -n "$GITHUB_PAT" ]] || die "No GitHub PAT provided."

log "Cloning repository"
mkdir -p "$(dirname "$REPO_DIR")"

# Use GIT_ASKPASS to supply the PAT without embedding it in the URL.
# The helper is a mode-700 temp script that echoes the token once and is
# deleted immediately after the clone finishes (or fails).
_GIT_ASKPASS="$(mktemp)"
chmod 700 "$_GIT_ASKPASS"
printf '#!/bin/sh\necho "%s"\n' "$GITHUB_PAT" > "$_GIT_ASKPASS"
trap 'rm -f "$_GIT_ASKPASS"' EXIT

GIT_ASKPASS="$_GIT_ASKPASS" git clone --branch "$GIT_BRANCH" \
    "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" \
    "$REPO_DIR"

rm -f "$_GIT_ASKPASS"
trap - EXIT

# Switch to the SSH remote for all future operations.
git -C "$REPO_DIR" remote set-url origin "git@github.com:${GITHUB_USER}/${GITHUB_REPO}.git"
log "Repository cloned to $REPO_DIR"

# ----
# 3. Install Homebrew packages
# ----
#
# The Brewfile is machine-specific (macos-config-sync.sh v2.0.0 layout):
#   machines/<machine-name>/home/Brewfile
# Resolution order:
#   1. This machine's Brewfile (by LocalHostName, or MACHINE_NAME override)
#   2. Legacy shared home/Brewfile (pre-v2.0.0 repositories)
#   3. Another machine's Brewfile, chosen interactively (or skip)

# Determine the machine name the same way macos-config-sync.sh does.
MACHINE="${MACHINE_NAME:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
MACHINE="$(printf '%s' "$MACHINE" | tr -c 'A-Za-z0-9._-' '-')"
log "Machine name: $MACHINE"

BREWFILE=""
if [[ -f "$REPO_DIR/machines/$MACHINE/home/Brewfile" ]]; then
    BREWFILE="$REPO_DIR/machines/$MACHINE/home/Brewfile"
    log "Using this machine's Brewfile: machines/$MACHINE/home/Brewfile"
elif [[ -f "$REPO_DIR/home/Brewfile" ]]; then
    BREWFILE="$REPO_DIR/home/Brewfile"
    log "Using legacy shared Brewfile: home/Brewfile"
else
    # Offer Brewfiles recorded for other machines, if any exist.
    candidates=()
    while IFS= read -r candidate; do
        candidates+=("$candidate")
    done < <(find "$REPO_DIR/machines" -mindepth 3 -maxdepth 3 \
        -path '*/home/Brewfile' -type f 2>/dev/null | sort)

    if (( ${#candidates[@]} > 0 )); then
        log "No Brewfile found for this machine ($MACHINE)."
        log "Brewfiles are available from other machines:"
        i=1
        for candidate in "${candidates[@]}"; do
            name="${candidate#"$REPO_DIR"/machines/}"
            name="${name%%/*}"
            log "  $i) $name"
            i=$((i + 1))
        done
        printf '[bootstrap] Choose a number to install from, or press Enter to skip: '
        read -r choice </dev/tty || choice=""
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
            BREWFILE="${candidates[$((choice - 1))]}"
            log "Using Brewfile: ${BREWFILE#"$REPO_DIR"/}"
        else
            log "Skipping Homebrew package installation."
        fi
    else
        log "No Brewfile found in the repository — skipping package installation."
        log "The first push from this machine will record one at machines/$MACHINE/home/Brewfile."
    fi
fi

if [[ -n "$BREWFILE" ]]; then
    log "Installing Homebrew packages from Brewfile"
    if brew bundle --file="$BREWFILE"; then
        log "Homebrew packages installed"
    else
        log "WARNING: Some Homebrew packages failed to install."
        log "Re-run after bootstrap completes: brew bundle --file=~/Brewfile"
    fi
fi

# ----
# 4. Restore configuration files
# ----

log "Restoring configuration files"
bash "$SYNC_SCRIPT" restore

# ----
# Done
# ----

log "Bootstrap complete"
log ""
log "Next steps:"
log "  1. Open a new terminal session (or run: exec zsh)"
log "  2. Verify your configuration with: macos-config-sync.sh status"
log "  3. Revoke the PAT — SSH is now configured: https://github.com/settings/tokens"
