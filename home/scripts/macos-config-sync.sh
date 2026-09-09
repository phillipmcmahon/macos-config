#!/usr/bin/env bash
#
# macos-config-sync.sh
#
# Version: 2.7.1
#
# v2.7.1:
#   - Improved: NAS synchronisation now prefers rsync-over-SSH when the NAS
#     host is reachable, preserving Unix permissions correctly. Falls back
#     to the SMB mount path automatically when SSH is unavailable.
#   - Added: NAS_SSH_HOST environment variable (default: homestorage) to
#     configure the NAS hostname for SSH transport. NAS_SSH_DIR (default:
#     ~/macos-config) sets the remote repository path.
#   - Added: All NAS SSH connections use a shared NAS_SSH_OPTS array
#     (-o BatchMode=yes -o ConnectTimeout=3). BatchMode enforces key-only
#     auth so a failed key exchange fails immediately instead of falling
#     through to password prompting. rsync receives the same options via
#     -e "$NAS_SSH_CMD". A separate NAS_SSH_CMD string is used for rsync's
#     -e flag because it performs its own word splitting.
#   - Improved: The remote directory is created via --rsync-path rather than
#     a separate ssh mkdir call, reducing the number of SSH connections per
#     push from three to two (probe + rsync) to avoid tripping brute-force
#     protections on the NAS.
#   - Added: NAS_RSYNC_PATH environment variable (default: /opt/bin/rsync)
#     pins the remote rsync binary. Non-interactive SSH sessions on the
#     Synology NAS use a minimal PATH that resolves to the stock 3.1.x
#     rsync instead of the Entware 3.4.x+ build, causing protocol
#     mismatches and connection failures.
#   - Fixed (Medium): Remote shell commands (--rsync-path mkdir, ssh test -d)
#     passed NAS_SSH_DIR inside double quotes, preventing tilde expansion on
#     the remote shell and creating a literal ~/macos-config directory. The
#     value is now unquoted in remote commands so the remote sh expands ~ to
#     the user's home directory.
#   - Fixed (Low): SMB fallback uses --no-perms to suppress the spurious
#     permission changes reported on every file because SMB mounts cannot
#     preserve Unix permission bits.
#
# v2.7.0:
#   - Improved: Colourised terminal output following the style used in
#     configure-yubikey.sh. Success messages print in green, warnings in
#     yellow, errors in red, and section headers in blue. Colours are
#     disabled automatically when stdout is not a terminal (piped or
#     redirected). No operational logic was changed.
#
# v2.6.2:
#   - Fixed (Medium): The ~/.ssh/sockets/ directory documented in v2.5.0
#     was missing from restore_local_files — a fresh bootstrap left SSH
#     multiplexing broken and git operations fell back to direct
#     connections on port 22, which timed out. The directory is now
#     created (mode 700) alongside the existing ~/.ssh permissions block.
#
# v2.6.1:
#   - Fixed (Low): Removed deprecated --describe flag from brew bundle
#     dump. Descriptions are now included by default in current Homebrew
#     versions; the explicit flag produced a deprecation warning on every
#     push.
#
# v2.6.0:
#   - New: generate_brewfile() regenerates ~/Brewfile from the currently
#     installed Homebrew packages on every push, using 'brew bundle dump
#     --force'. The Brewfile is now always an accurate snapshot of the
#     machine's installed taps, formulae, casks and Mac App Store apps —
#     matching the existing installed-apps.txt behaviour. Skipped with a
#     warning if Homebrew is not installed.
#
# v2.5.0:
#   - New: ~/.ssh/config is now a shared managed file, synced across all
#     machines. Enables consistent SSH connection policy (multiplexing,
#     port overrides) without per-machine setup.
#   - restore_local_files now sets restrictive permissions on ~/.ssh (700
#     for the directory, 600 for its files) after restoring, matching the
#     existing ~/.gnupg treatment. SSH refuses to use a config file that
#     is group- or world-readable.
#   - restore_local_files creates ~/.ssh/sockets/ (mode 700) if it does
#     not already exist. The managed ~/.ssh/config sets ControlPath to
#     this directory for SSH connection multiplexing; without it, SSH
#     silently falls back to individual connections per invocation.
#
# v2.4.1:
#   - Fixed (High): Staleness guard A handler now applies the same three-
#     way model as M. A remote-added file with a different local file is a
#     conflict (local != new), not a silent allow.
#   - Fixed (High): Staleness guard D handler now treats a remote deletion
#     combined with independent local edits (local != old blob) as a
#     conflict, rather than silently allowing the push to resurrect the
#     file.
#   - Fixed (Low): Staleness guard documentation block rewritten to
#     describe the current three-way (local / old / new) conflict model
#     and all five status outcomes.
#   - Fixed (Low): Staleness guard error messages no longer assume local
#     copies are "older" — the wording now reflects the general conflict
#     case.
#
# v2.4.0:
#   - Fixed (High): Staleness guard now detects concurrent-edit conflicts.
#     When a file was modified both locally and by the remote (local != old
#     AND local != new), the v2.3.0 guard allowed the push — silently
#     overwriting the remote version. Both local edits and remote edits are
#     now treated as a conflict requiring explicit resolution.
#   - Fixed (High): Staleness guard now detects local-deletion / remote-
#     modification conflicts. If a file was deleted locally but modified on
#     the remote, the push would delete the remote version. This is now
#     treated as a conflict.
#   - Fixed (Medium): Secret scanner no longer stores Git blobs in Bash
#     variables. Bash variables cannot represent NUL bytes, so binary blobs
#     were silently truncated. The scanner now streams git show directly
#     into grep without an intermediate variable.
#   - Fixed (Low): Corrected the dependency list — removed xargs (no longer
#     used after the v2.3.0 installed-apps fix) and added grep and basename
#     which are used but were not checked.
#   - Fixed (Low): Added --no-renames to the staleness guard's git diff so
#     rename status lines (Rxx) cannot reach the M/A/D case handler.
#
# v2.3.0:
#   - Fixed (Critical): Staleness guard redesigned. The v2.2.0 guard
#     compared $HOME files directly against the post-rebase repository,
#     which meant normal local edits (the whole point of push) were
#     flagged as unrestored remote changes. The guard now captures the
#     pre-rebase HEAD, diffs it against the post-rebase HEAD to identify
#     files actually changed by the remote, and for each such file
#     compares the local $HOME copy against the OLD (pre-rebase) blob.
#     A file is only flagged stale when the local copy is byte-identical
#     to the pre-rebase version — meaning the user never incorporated
#     the remote change. Independent local edits are left alone.
#   - Fixed (Critical): The secret scanner's combined grep pattern
#     begins with '-----BEGIN' and grep interpreted the leading dashes
#     as option flags, silently skipping the content scan. All grep
#     invocations that accept a variable pattern now use -e to force
#     pattern interpretation (grep -qE -e "$pattern").
#   - Fixed (High): Remote deletions are now detected by the staleness
#     guard. If Machine A deletes a managed file and pushes, Machine B's
#     staleness guard will flag the local copy that still matches the
#     pre-deletion blob — preventing silent resurrection.
#   - Fixed (Medium): validate_dependencies() now checks for cmp, sed,
#     xargs, wc, paste, cut and tr — all used later but previously
#     unvalidated.
#   - Fixed (Medium): The secret scanner now reads staged Git blobs
#     (git show :path) instead of working-tree files. The previous
#     approach could miss staged content that differed from the working
#     tree, or scan working-tree changes that were not actually staged.
#   - Fixed (Low): generate_installed_apps_list() replaced the
#     find | xargs -0 -n1 basename pipeline with a while-read loop.
#     The xargs pipeline ran basename with no arguments when /Applications
#     contained no .app bundles, which fails under set -e on macOS.
#
# v2.2.0:
#   - New staleness guard: check_for_unrestored_remote_changes() runs after
#     rebase and before collect. Compares managed files against the
#     repository to detect unrestored remote changes.
#   - Escape hatch: set FORCE_PUSH=1 to push anyway when the staleness
#     guard fires (for cases where you intentionally want to overwrite).
#   - FORCE_PUSH is validated alongside DRY_RUN in validate_configuration.
#   - Documented FORCE_PUSH in usage() and the environment overrides block.
#
# v2.1.0:
#   - New: generate_installed_apps_list() scans /Applications for .app
#     bundles and writes a sorted, newline-delimited inventory (application
#     name without the .app suffix) to ~/installed-apps.txt. The file is
#     generated automatically on every push, before files are collected.
#   - installed-apps.txt is tracked as a machine-specific file (stored
#     under machines/<machine-name>/home/ in the repository), so each Mac
#     maintains its own independent application inventory.
#   - Respects DRY_RUN: when DRY_RUN=1 the file is not written.
#
# v2.0.4:
#   - Secret scanner now stages all changes (git add --all) before scanning,
#     then inspects the staged index via git diff --cached.  The v2.0.3 scan
#     used git ls-files which only returns already-tracked files — a newly
#     added config file could be committed without ever being scanned.
#   - Replaced MIME-based binary detection (file --mime-type | grep '^text/')
#     with content-based detection (grep -Iq).  The MIME approach classified
#     application/json (and similar structured-text types) as non-text,
#     silently skipping files that may contain credentials.
#   - Added github_pat_ to SECRET_CONTENT_PATTERNS — GitHub fine-grained
#     personal access tokens use this prefix and were not previously detected.
#   - If the secret scan finds issues, the staged changes are unstaged
#     (git reset) so the push is cleanly aborted without leaving a dirty index.
#
# v2.0.3:
#   - Secret scanner now scans tracked files (git ls-files) instead of walking
#     the working tree with find.  The previous approach scanned .gitignore'd
#     files, editor swap files, and other untracked artefacts — producing false
#     positives and missing the fact that only committed content matters.
#   - Clarified binary-file detection: rewrote the double-negative
#     `grep -qv '^text/'` as `! grep -q '^text/'` for readability.
#
# v2.0.2:
#   - Fixed: commits could be stranded locally and never reach GitHub. When
#     a previous push failed after committing (or the remote branch had not
#     been created yet), the next push found "no configuration changes to
#     commit" and returned WITHOUT pushing — so the local commits (e.g. the
#     machine-specific Brewfile) appeared on the NAS mirror (an rsync of the
#     working tree) but never on GitHub. commit_and_push now detects
#     unpushed local commits (missing remote branch, or local branch ahead
#     of origin) and pushes them even when there is nothing new to commit.
#
# v2.0.1:
#   - Fixed: when a machine-specific file (e.g. Brewfile) does not exist
#     locally, the empty machines/<name>/home/ directory was left in the
#     repository and mirrored to NAS. Empty machine directories are now
#     removed after pruning; the machines/ tree is only kept while it
#     contains actual files.
#   - ensure_repository_structure no longer pre-creates machine directories;
#     they are created on demand during collect only when source files exist.
#
# v2.0.0 (BREAKING — repository layout change):
#   - Shared ~/.config syncing narrowed to an explicit allowlist: only
#     .config/.zsh_functions, .config/topgrade.toml and .config/git/ are
#     shared between machines. The previous whole-directory blocklist model
#     (sync all of ~/.config minus EXCLUDE_PATTERNS) is gone.
#   - New per-machine configuration: MACHINE_FILES (and MACHINE_DIRECTORIES,
#     currently empty) are collected into machines/<machine-name>/home/ in
#     the repository and restored ONLY on the machine whose name matches.
#     The Brewfile is now machine-specific.
#   - Machine name comes from 'scutil --get LocalHostName' (fallback:
#     hostname -s), sanitised to [A-Za-z0-9._-]; override with MACHINE_NAME.
#   - Migration is automatic on the first push from each machine: the prune
#     step removes the now-unmanaged shared copy (home/Brewfile) and the
#     collect step re-adds it under machines/<machine-name>/home/. Run push
#     from the machine that owns the current shared copy FIRST so its
#     version is preserved before another machine's push prunes it.
#   - Pruning inside machines/ touches only the current machine's directory;
#     other machines' trees are never modified.
#   - Secret scan now covers the machines/ tree as well as home/.
#   - status shows the current machine name and all machines present in
#     the repository; backups include the machine-specific paths.
#
# v1.9.1:
#   - Fixed SECRET_FILENAME_PATTERNS regex: 'service.account\.json$' had an
#     unescaped '.' which the bash =~ operator treats as "any character";
#     now escaped as 'service\.account\.json$'. Also added the
#     'service_account\.json$' variant to match the EXCLUDE_PATTERNS list.
#
# v1.9.0:
#   - New 'restore' command: copies repository files to $HOME without
#     contacting the remote — designed for bootstrap.sh where SSH keys
#     have not yet been restored and the repository was just cloned
#
# v1.8.0:
#   - restore_local_files now sets restrictive permissions on .gnupg (700 for
#     the directory, 600 for its files) and marks scripts executable — a fresh
#     pull no longer leaves sensitive GPG configuration world-readable
#
# v1.7.0:
#   - Auto-stash before remote update: update_from_remote_before_push() now
#     stashes any uncommitted changes (e.g. from a previously interrupted push)
#     before fetch/rebase, then pops the stash afterward — eliminates the
#     "Repository contains uncommitted changes before remote update" error
#   - .gitignore is now regenerated from EXCLUDE_PATTERNS on every push
#     (previously only created if the file did not already exist)
#
# v1.6.0:
#   - Pre-push secret scan: scan_for_secrets() checks staged files for
#     common secret material (private key headers, cloud provider tokens,
#     credential filenames) and aborts the push if any are found — defence
#     against the .config blocklist model silently committing new secrets
#   - NAS mirror rsync now uses --checksum to verify file integrity,
#     guarding against silent data corruption on network mounts (SMB/NFS)
#
# Synchronises selected macOS files between:
#   1. Their normal locations under the user's home directory
#   2. A local Git working repository
#   3. A private GitHub repository
#   4. A repository mirror on a mounted NAS
#
# Add or remove managed files and directories only in the MANAGED_FILES and
# MANAGED_DIRECTORIES arrays below. Exclusion patterns are maintained once in
# EXCLUDE_PATTERNS and used for both rsync filtering and .gitignore generation.
#
# Commands:
#   init        Clone or initialise the local repository
#   push        Copy local files into the repository and push to GitHub
#   pull        Pull from GitHub and restore files to their normal locations
#   restore     Restore files from the local repository without contacting
#               the remote (used by bootstrap.sh before SSH keys exist)
#   status      Show local, GitHub and NAS status
#   nas-push    Mirror the local repository to the NAS
#   nas-pull    Restore the local repository from the NAS
#   version     Display the script version
#   help        Display usage information
#
# Important:
#   push treats the Mac as the source of truth.
#   pull treats GitHub as the source of truth.
#
#   If a managed file is deleted locally and push is run, that deletion is
#   committed to Git. Run pull before push to recover an accidental deletion.
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_VERSION="2.7.1"
readonly SCRIPT_NAME="${0##*/}"

# Prefer Homebrew binaries over the older macOS-supplied tools.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ----
# Configuration
# ----

GITHUB_REPO="${GITHUB_REPO:-git@github.com:phillipmcmahon/macos-config.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"

REPO_DIR="${REPO_DIR:-$HOME/.local/share/macos-config}"

NAS_ROOT="${NAS_ROOT:-/Volumes/home}"
NAS_REPO_DIR="${NAS_REPO_DIR:-$NAS_ROOT/macos-config}"

# SSH transport for NAS synchronisation (preferred over SMB).
# The remote user is not specified — it mirrors the local account name,
# so rsync connects as the current user by default.
NAS_SSH_HOST="${NAS_SSH_HOST:-homestorage}"

# The default uses a literal tilde — it is NOT expanded locally. rsync
# expands ~ in host:~/path destinations, and remote shell commands leave
# the value UNQUOTED so the remote sh expands the tilde at execution time.
NAS_SSH_DIR="${NAS_SSH_DIR:-~/macos-config}"

# Path to the rsync binary on the NAS. Non-interactive SSH sessions use a
# minimal PATH that resolves to the stock Synology rsync (/usr/bin/rsync,
# 3.1.x) instead of the Entware build (/opt/bin/rsync, 3.4.x+). Pinning
# the path ensures the correct version is used regardless of the remote
# shell's PATH.
NAS_RSYNC_PATH="${NAS_RSYNC_PATH:-/opt/bin/rsync}"

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.local/state/macos-config/backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-10}"

LOCK_DIR="${LOCK_DIR:-$HOME/.local/state/macos-config/run.lock}"

DRY_RUN="${DRY_RUN:-0}"

# When set to 1, the staleness guard (check_for_unrestored_remote_changes)
# is bypassed — the push proceeds even when the remote contains changes
# that have not been restored locally. Use with care: this can overwrite
# configuration pushed from another machine.
FORCE_PUSH="${FORCE_PUSH:-0}"

# ----
# Managed paths
# ----
#
# Add or remove entries only in these four arrays.
#
# Paths are relative to $HOME.
# Do not use a leading or trailing slash.
#
# Examples:
#   MANAGED_DIRECTORIES+=(".ssh/config.d")
#   MANAGED_FILES+=(".vimrc")
#   MACHINE_FILES+=(".config/some-tool/machine-local.toml")
#

# Shared paths — identical on every machine. Stored under home/ in the
# repository and restored to every machine that pulls.
#
# ~/.config is now an explicit allowlist: only the entries listed here are
# shared. Everything else under ~/.config is ignored unless added to the
# machine-specific arrays below.
MANAGED_DIRECTORIES=(
    ".config/git"
    "scripts"
)

MANAGED_FILES=(
    ".config/.zsh_functions"
    ".config/topgrade.toml"
    ".gitconfig"
    ".gnupg/gpg-agent.conf"
    ".gnupg/gpg.conf"
    ".gnupg/scdaemon.conf"
    ".gnupg/sshcontrol"
    ".ssh/config"
    ".zprofile"
    ".zshenv"
    ".zshrc"
)

# Machine-specific paths — differ between machines. Stored under
# machines/<machine-name>/home/ in the repository and restored ONLY on the
# machine whose name matches (see MACHINE_NAME below). Other machines'
# trees are never modified or restored.
MACHINE_DIRECTORIES=(
    # Add machine-specific directories here as needed, e.g.:
    #   ".config/herdr"
    #   ".config/openlogi"
)

MACHINE_FILES=(
    "Brewfile"
    "installed-apps.txt"
)

# Patterns excluded from every managed directory sync.
# Also used to generate the repository .gitignore (see create_repository_files).
EXCLUDE_PATTERNS=(
    '.DS_Store'
    '*.swp'
    '*.swo'
    '*.tmp'
    '*.log'
    '*.sock'
    '*.pid'
    '*.token'
    '.env'
    '.env.*'
    '*.secret'
    'Cache/'
    'Caches/'
    'cache/'
    'logs/'
    'node_modules/'
    '.terraform/'
    'terraform.tfstate'
    'terraform.tfstate.*'
    'credentials'
    'credentials.json'
    'secrets'
    'secrets.json'
    'hosts.yml'
    'rclone.conf'
    'id_rsa'
    'id_ecdsa'
    'id_ed25519'
    'id_dsa'
    'service-account.json'
    'service_account.json'
    '*.key'
    '*.pem'
    '*.p12'
    '*.pfx'
)

# Build rsync --exclude flags from the single source of truth above.
DIRECTORY_EXCLUDES=()
for _pat in "${EXCLUDE_PATTERNS[@]}"; do
    DIRECTORY_EXCLUDES+=(--exclude="$_pat")
done
unset _pat

COMMON_RSYNC_OPTIONS=(
    --archive
    --human-readable
    --itemize-changes
    --protect-args
)

# ----
# Machine identity
# ----
#
# Machine-specific paths are keyed on this name. It defaults to the macOS
# LocalHostName (stable, no spaces, survives reboots — unlike ComputerName,
# which may contain spaces and punctuation) with 'hostname -s' as a
# fallback. Override with the MACHINE_NAME environment variable.
# Any character outside [A-Za-z0-9._-] is replaced with '-' so the name is
# always safe to use as a directory name.

detect_machine_name() {
    local name=""

    if [[ -n "${MACHINE_NAME:-}" ]]; then
        name="$MACHINE_NAME"
    elif command -v scutil >/dev/null 2>&1; then
        name="$(scutil --get LocalHostName 2>/dev/null || true)"
    fi

    if [[ -z "$name" ]]; then
        name="$(hostname -s 2>/dev/null || true)"
    fi

    # Sanitise: keep only [A-Za-z0-9._-]; everything else becomes '-'.
    name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')"

    # Reject names that are empty or only dots/dashes after sanitising.
    [[ -n "$name" && "$name" != "." && "$name" != ".." ]] ||
        die "Could not determine a usable machine name. Set MACHINE_NAME explicitly."

    printf '%s\n' "$name"
}

# ----
# Colours (disabled if stdout is not a terminal)
# ----

if [[ -t 1 ]]; then
    C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

# ----
# Logging and errors
# ----

log() {
    printf '%s[%s]%s %s\n' "$C_GREEN" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET" "$*"
}

ok() {
    printf '%s[%s] ✔ %s%s\n' "$C_GREEN" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET"
}

step() {
    printf '%s[%s] ▸ %s%s\n' "$C_BLUE" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET"
}

warn() {
    printf '%s[%s] WARNING: %s%s\n' "$C_YELLOW" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET" >&2
}

die() {
    printf '%s[%s] ERROR: %s%s\n' "$C_RED" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET" >&2
    exit 1
}

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%sDRY-RUN:%s' "$C_YELLOW" "$C_RESET"
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

on_error() {
    local exit_code=$?
    local line_number="${1:-unknown}"

    printf '%s[%s] ERROR: Command failed at line %s with exit code %s%s\n' \
        "$C_RED" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$line_number" \
        "$exit_code" \
        "$C_RESET" >&2

    exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

# ----
# Path helpers
# ----

local_path() {
    printf '%s/%s\n' "$HOME" "$1"
}

repository_path() {
    printf '%s/home/%s\n' "$REPO_DIR" "$1"
}

# Resolved once by ensure_machine_name(); used for all machine-specific paths.
MACHINE=""

# Set by update_from_remote_before_push() to the commit hash before the
# rebase. Used by check_for_unrestored_remote_changes() to identify which
# files were actually changed by the remote — so that only genuinely
# unrestored changes are flagged, not normal local edits.
PRE_REBASE_HEAD=""

ensure_machine_name() {
    [[ -n "$MACHINE" ]] || MACHINE="$(detect_machine_name)"
}

machine_repository_root() {
    printf '%s/machines/%s\n' "$REPO_DIR" "$MACHINE"
}

machine_repository_path() {
    printf '%s/machines/%s/home/%s\n' "$REPO_DIR" "$MACHINE" "$1"
}

backup_path() {
    printf '%s/%s\n' "$1" "$2"
}

# ----
# Usage
# ----

sorted_managed_paths() {
    local path
    local sort_key

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        sort_key="${path#.}"
        printf '%s\t%s\n' "$sort_key" "$path"
    done |
        LC_ALL=C sort -f -k1,1 -k2,2 |
        cut -f2-
}

print_managed_paths() {
    local path

    printf '%s\n' "${MANAGED_DIRECTORIES[@]}" |
        sorted_managed_paths |
        while IFS= read -r path; do
            printf '  ~/%s/\n' "$path"
        done

    printf '%s\n' "${MANAGED_FILES[@]}" |
        sorted_managed_paths |
        while IFS= read -r path; do
            printf '  ~/%s\n' "$path"
        done
}

print_machine_paths() {
    local path

    if (( ${#MACHINE_DIRECTORIES[@]} > 0 )); then
        printf '%s\n' "${MACHINE_DIRECTORIES[@]}" |
            sorted_managed_paths |
            while IFS= read -r path; do
                printf '  ~/%s/\n' "$path"
            done
    fi

    printf '%s\n' "${MACHINE_FILES[@]}" |
        sorted_managed_paths |
        while IFS= read -r path; do
            printf '  ~/%s\n' "$path"
        done
}

usage() {
    cat <<EOF
$SCRIPT_NAME version $SCRIPT_VERSION

Usage:
  $SCRIPT_NAME <command>

Commands:
  init        Clone or initialise the local repository
  push        Copy local configuration into Git and push to GitHub
  pull        Pull from GitHub and restore configuration to the Mac
  restore     Restore files from the local repository (no remote contact)
  status      Show local repository, GitHub and NAS status
  nas-push    Mirror the local repository to the NAS
  nas-pull    Restore the local repository from the NAS
  version     Display the script version
  help        Display this help

Shared managed paths (stored under home/, restored on every machine):
EOF

    print_managed_paths

    cat <<EOF

Machine-specific paths (stored under machines/<machine-name>/home/,
collected from and restored ONLY to the machine whose name matches):
EOF

    print_machine_paths

    cat <<EOF

The machine name defaults to 'scutil --get LocalHostName' (fallback:
hostname -s), sanitised to [A-Za-z0-9._-]. Override with MACHINE_NAME.

Environment overrides:
  GITHUB_REPO
  GIT_BRANCH
  REPO_DIR
  NAS_SSH_HOST    NAS hostname for SSH transport (default: homestorage)
  NAS_SSH_DIR     Remote repository path over SSH (default: ~/macos-config)
  NAS_RSYNC_PATH  Remote rsync binary (default: /opt/bin/rsync)
  NAS_ROOT        SMB mount point fallback (default: /Volumes/home)
  NAS_REPO_DIR    SMB repository path fallback (default: \$NAS_ROOT/macos-config)
  BACKUP_ROOT
  BACKUP_RETENTION
  LOCK_DIR
  MACHINE_NAME
  DRY_RUN=1
  FORCE_PUSH=1    Skip the staleness guard and push even when the
                  remote has unrestored changes
EOF
}

# ----
# Validation
# ----

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

validate_dependencies() {
    require_command git
    require_command rsync
    require_command ssh
    require_command find
    require_command sort
    require_command head
    require_command cmp
    require_command sed
    require_command grep
    require_command basename
    require_command wc
    require_command paste
    require_command cut
    require_command tr
}

validate_managed_path() {
    local path="$1"

    [[ -n "$path" ]] ||
        die "Managed paths must not be empty."

    [[ "$path" != /* ]] ||
        die "Managed paths must be relative to HOME: $path"

    [[ "$path" != "." ]] ||
        die "Managing the entire home directory is not supported."

    [[ "$path" != */ ]] ||
        die "Managed directory entries must not end with '/': $path"

    [[ "$path" != ".." && "$path" != ../* && "$path" != */../* && "$path" != */.. ]] ||
        die "Managed paths must not traverse outside HOME: $path"
}

validate_configuration() {
    local path

    [[ "$BACKUP_RETENTION" =~ ^[0-9]+$ ]] ||
        die "BACKUP_RETENTION must be a non-negative integer."

    [[ "$DRY_RUN" == "0" || "$DRY_RUN" == "1" ]] ||
        die "DRY_RUN must be either 0 or 1."

    [[ "$FORCE_PUSH" == "0" || "$FORCE_PUSH" == "1" ]] ||
        die "FORCE_PUSH must be either 0 or 1."

    for path in "${MANAGED_DIRECTORIES[@]}"; do
        validate_managed_path "$path"
    done

    for path in "${MANAGED_FILES[@]}"; do
        validate_managed_path "$path"
    done

    for path in "${MACHINE_DIRECTORIES[@]+"${MACHINE_DIRECTORIES[@]}"}"; do
        validate_managed_path "$path"
    done

    for path in "${MACHINE_FILES[@]}"; do
        validate_managed_path "$path"
    done

    ensure_machine_name
}

show_tool_versions() {
    local rsync_version_output
    local rsync_version_first_line

    rsync_version_output="$(rsync --version)"
    rsync_version_first_line="${rsync_version_output%%$'\n'*}"

    step "Script version: ${C_BOLD}${SCRIPT_VERSION}${C_RESET}${C_BLUE}"
    log "Machine name: ${MACHINE:-<not yet resolved>}"
    log "Using rsync: $(command -v rsync)"
    log "$rsync_version_first_line"
}

# ----
# Lock handling
# ----

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_DIR")"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: Would acquire lock: $LOCK_DIR"
        return 0
    fi

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        return 0
    fi

    local existing_pid="unknown"

    if [[ -r "$LOCK_DIR/pid" ]]; then
        existing_pid="$(cat "$LOCK_DIR/pid")"
    fi

    # If the owning process is dead, remove the stale lock and retry once
    if [[ "$existing_pid" != "unknown" ]] && ! kill -0 "$existing_pid" 2>/dev/null; then
        warn "Removing stale lock (PID $existing_pid is no longer running)"
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" >"$LOCK_DIR/pid"
            return 0
        fi
    fi

    die "Another instance may be running. Lock: $LOCK_DIR, PID: $existing_pid"
}

release_lock() {
    [[ "$DRY_RUN" == "1" ]] || rm -rf "$LOCK_DIR"
}

# ----
# Repository helpers
# ----

repository_exists() {
    [[ -d "$REPO_DIR/.git" ]]
}

require_repository() {
    repository_exists ||
        die "Repository is not initialised. Run: $SCRIPT_NAME init"
}

repository_has_commits() {
    git -C "$REPO_DIR" rev-parse --verify HEAD >/dev/null 2>&1
}

repository_is_clean() {
    [[ -z "$(git -C "$REPO_DIR" status --porcelain)" ]]
}

remote_branch_exists() {
    git -C "$REPO_DIR" ls-remote \
        --exit-code \
        --heads \
        origin \
        "$GIT_BRANCH" >/dev/null 2>&1
}

ensure_repository_structure() {
    local path

    ensure_machine_name

    run mkdir -p "$REPO_DIR/home"

    for path in "${MANAGED_DIRECTORIES[@]}"; do
        run mkdir -p "$(repository_path "$path")"
    done

    # Machine directories are NOT pre-created here. They are created on
    # demand during collect_local_files only when the source file/directory
    # actually exists — otherwise empty machine trees linger in the
    # repository and get mirrored to NAS (fixed in v2.0.1).
}

# ----
# NAS helpers
# ----

# Common SSH options for all NAS connections. BatchMode prevents password
# prompts — if key authentication fails, the connection fails immediately
# instead of hanging or triggering brute-force protections on the NAS.
NAS_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=3)

# The same options as a single string for rsync's -e flag, which performs
# its own word splitting (array expansion inside -e is not reliable).
NAS_SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=3"

nas_ssh_available() {
    ssh -n "${NAS_SSH_OPTS[@]}" "$NAS_SSH_HOST" true 2>/dev/null
}

nas_smb_available() {
    [[ -d "$NAS_ROOT" ]]
}

nas_available() {
    nas_ssh_available || nas_smb_available
}

require_nas() {
    nas_available ||
        die "NAS is unreachable (SSH host: $NAS_SSH_HOST, SMB mount: $NAS_ROOT)"
}

# ----
# File synchronisation
# ----

sync_directory() {
    local source_dir="$1"
    local destination_dir="$2"

    shift 2

    if [[ ! -d "$source_dir" ]]; then
        warn "Source directory does not exist: $source_dir"
        return 0
    fi

    run mkdir -p "$destination_dir"

    run rsync \
        "${COMMON_RSYNC_OPTIONS[@]}" \
        --delete \
        "$@" \
        "$source_dir/" \
        "$destination_dir/"
}

sync_file() {
    local source_file="$1"
    local destination_file="$2"

    if [[ ! -e "$source_file" && ! -L "$source_file" ]]; then
        warn "Source file does not exist: $source_file"
        return 0
    fi

    run mkdir -p "$(dirname "$destination_file")"

    run rsync \
        "${COMMON_RSYNC_OPTIONS[@]}" \
        "$source_file" \
        "$destination_file"
}

collect_managed_file() {
    local source_file="$1"
    local repository_file="$2"

    if [[ -e "$source_file" || -L "$source_file" ]]; then
        sync_file "$source_file" "$repository_file"
        return 0
    fi

    if [[ -e "$repository_file" || -L "$repository_file" ]]; then
        log "Local file was removed. Removing repository copy: $repository_file"
        run rm -f "$repository_file"
    else
        warn "Managed file does not exist: $source_file"
    fi
}

# ----
# Repository pruning
# ----
#
# Removing a path from MANAGED_FILES or MANAGED_DIRECTORIES must also remove
# its old copy from the repository. Otherwise, stale files remain tracked and
# may be restored by a later pull.
#
# A repository path is retained when it is:
#   - an exact managed file
#   - an exact managed directory
#   - inside a managed directory
#   - a parent directory required by a nested managed path
#

is_managed_repository_path() {
    local candidate="$1"
    local managed_path

    for managed_path in "${MANAGED_DIRECTORIES[@]}"; do
        if [[ "$candidate" == "$managed_path" ||
              "$candidate" == "$managed_path/"* ||
              "$managed_path" == "$candidate/"* ]]; then
            return 0
        fi
    done

    for managed_path in "${MANAGED_FILES[@]}"; do
        if [[ "$candidate" == "$managed_path" ||
              "$managed_path" == "$candidate/"* ]]; then
            return 0
        fi
    done

    return 1
}

prune_unmanaged_repository_paths() {
    local repository_home="$REPO_DIR/home"
    local item
    local relative_path

    [[ -d "$repository_home" ]] || return 0

    step "Removing repository paths that are no longer managed"

    while IFS= read -r -d '' item; do
        relative_path="${item#"$repository_home"/}"

        if ! is_managed_repository_path "$relative_path"; then
            log "Removing unmanaged repository path: home/$relative_path"
            run rm -rf "$item"
        fi
    done < <(
        find "$repository_home" \
            -mindepth 1 \
            -depth \
            -print0
    )
}

# Machine-tree retention mirrors is_managed_repository_path, but against the
# MACHINE_* arrays. Only the CURRENT machine's tree is ever pruned — other
# machines' directories under machines/ are never touched, because this
# machine cannot know what is stale for them.

is_machine_repository_path() {
    local candidate="$1"
    local managed_path

    for managed_path in "${MACHINE_DIRECTORIES[@]+"${MACHINE_DIRECTORIES[@]}"}"; do
        if [[ "$candidate" == "$managed_path" ||
              "$candidate" == "$managed_path/"* ||
              "$managed_path" == "$candidate/"* ]]; then
            return 0
        fi
    done

    for managed_path in "${MACHINE_FILES[@]}"; do
        if [[ "$candidate" == "$managed_path" ||
              "$managed_path" == "$candidate/"* ]]; then
            return 0
        fi
    done

    return 1
}

prune_unmanaged_machine_paths() {
    local machine_home
    machine_home="$(machine_repository_root)/home"

    local item
    local relative_path

    [[ -d "$machine_home" ]] || return 0

    step "Removing machine paths that are no longer managed (machine: $MACHINE)"

    while IFS= read -r -d '' item; do
        relative_path="${item#"$machine_home"/}"

        if ! is_machine_repository_path "$relative_path"; then
            log "Removing unmanaged machine path: machines/$MACHINE/home/$relative_path"
            run rm -rf "$item"
        fi
    done < <(
        find "$machine_home" \
            -mindepth 1 \
            -depth \
            -print0
    )

    # Clean up empty directories left behind after pruning (or after
    # collect_managed_file removed a stale file). Without this, empty
    # machine trees linger in the repository and get mirrored to NAS.
    find "$(machine_repository_root)" \
        -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true

    # If the machine root itself is now empty, remove it.
    rmdir "$(machine_repository_root)" 2>/dev/null || true

    # If no machine trees remain at all, remove the top-level machines/
    # directory so it does not clutter the repository or NAS mirror.
    rmdir "$REPO_DIR/machines" 2>/dev/null || true
}

# ----
# Repository support files
# ----


create_repository_files() {
    local gitignore="$REPO_DIR/.gitignore"
    local readme="$REPO_DIR/README.md"
    local path

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: Would regenerate $gitignore"
    else
        # Regenerate .gitignore from EXCLUDE_PATTERNS every run
        # (single source of truth — always reflects the current array)
        {
            local pat
            for pat in "${EXCLUDE_PATTERNS[@]}"; do
                # Directory patterns (trailing /) get a **/ prefix for recursive matching
                if [[ "$pat" == */ ]]; then
                    printf '**/%s\n' "$pat"
                else
                    printf '%s\n' "$pat"
                fi
            done
        } >"$gitignore"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: Would regenerate $readme"
        return 0
    fi

    {
        cat <<'EOF'
# macOS configuration

Private repository containing selected macOS configuration, scripts and Homebrew package definitions.

## Shared managed files

Stored beneath the repository's `home` directory and restored on every machine.

EOF
        printf '%s\n' "${MANAGED_FILES[@]}" |
            sorted_managed_paths |
            while IFS= read -r path; do
                printf -- '- `~/%s`\n' "$path"
            done

        cat <<'EOF'

## Shared managed paths

EOF
        printf '%s\n' "${MANAGED_DIRECTORIES[@]}" |
            sorted_managed_paths |
            while IFS= read -r path; do
                printf -- '- `~/%s/`\n' "$path"
            done
        cat <<'EOF'

## Machine-specific files and paths

Stored beneath `machines/<machine-name>/home` and restored only on the machine whose name matches (from `scutil --get LocalHostName`, overridable via `MACHINE_NAME`).

EOF
        printf '%s\n' "${MACHINE_FILES[@]}" |
            sorted_managed_paths |
            while IFS= read -r path; do
                printf -- '- `~/%s`\n' "$path"
            done
        if (( ${#MACHINE_DIRECTORIES[@]} > 0 )); then
            printf '%s\n' "${MACHINE_DIRECTORIES[@]}" |
                sorted_managed_paths |
                while IFS= read -r path; do
                    printf -- '- `~/%s/`\n' "$path"
                done
        fi
        cat <<'EOF'

Caches, logs and known credential files (for example `hosts.yml`, `rclone.conf`, `*.token`, `*.key`) are excluded from directory syncs via `EXCLUDE_PATTERNS` in `macos-config-sync.sh`.

## Restore

Use `macos-config-sync.sh pull` to retrieve the current GitHub version and restore files to their normal locations. Shared files are restored everywhere; machine-specific files are restored only on the matching machine.

## Homebrew

The Brewfile is machine-specific (`machines/<machine-name>/home/Brewfile`). After restoring on the matching machine, install its contents with:

```bash
brew bundle --file="$HOME/Brewfile"
```

## SSH

`~/.ssh/config` is a shared managed file containing the SSH connection policy for `github.com` (port 443 tunnel and connection multiplexing). On restore, the sync script also:

- Sets `~/.ssh` to mode 700 and all files within it to mode 600 (SSH refuses to use a config or key file that is group- or world-readable).
- Creates `~/.ssh/sockets/` (mode 700) if it does not already exist. The `ControlPath` directive in `~/.ssh/config` points to this directory — without it, SSH silently falls back to opening a new connection for every git command, which is slower and prone to intermittent timeouts.

The sockets directory is not tracked in Git (it only holds transient Unix domain sockets created by SSH at runtime). It is created automatically by `pull`, `restore`, and `bootstrap.sh`.
EOF
} >"$readme"
}

# ----
# Initialisation
# ----
initialise_repository() {
validate_dependencies
validate_configuration
show_tool_versions

if repository_exists; then
    log "Repository is already initialised: $REPO_DIR"
    ensure_repository_structure
    create_repository_files
    return 0
fi

step "Checking access to GitHub repository"

git ls-remote "$GITHUB_REPO" >/dev/null 2>&1 ||
    die "Unable to access GitHub repository: $GITHUB_REPO"

run mkdir -p "$(dirname "$REPO_DIR")"

step "Cloning GitHub repository"
run git clone "$GITHUB_REPO" "$REPO_DIR"

if [[ "$DRY_RUN" == "1" ]]; then
    return 0
fi

if repository_has_commits; then
    if git -C "$REPO_DIR" show-ref \
        --verify \
        --quiet \
        "refs/remotes/origin/$GIT_BRANCH"; then
        git -C "$REPO_DIR" checkout "$GIT_BRANCH"
    else
        git -C "$REPO_DIR" checkout -b "$GIT_BRANCH"
    fi
else
    git -C "$REPO_DIR" checkout -B "$GIT_BRANCH"
fi

ensure_repository_structure
create_repository_files

ok "Repository initialised: $REPO_DIR"
}

# ----
# Installed applications inventory
# ----
#
# Generates a sorted list of all .app bundles found directly inside
# /Applications (depth 1 only — nested helper apps are excluded). The
# .app suffix is stripped so the output is a clean, human-readable
# application name per line. The file is written to ~/installed-apps.txt
# and tracked as a machine-specific managed file, giving each Mac its
# own inventory in the repository.

generate_brewfile() {
    local output_file
    output_file="$(local_path "Brewfile")"

    if ! command -v brew >/dev/null 2>&1; then
        warn "Homebrew is not installed — skipping Brewfile generation"
        return 0
    fi

    step "Generating Brewfile: $output_file"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: Would write Brewfile to $output_file"
        return 0
    fi

    brew bundle dump --force --file="$output_file"

    ok "Brewfile generated ($(wc -l < "$output_file" | tr -d ' ') lines)"
}

generate_installed_apps_list() {
    local output_file
    output_file="$(local_path "installed-apps.txt")"

    step "Generating installed applications list: $output_file"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: Would write installed apps list to $output_file"
        return 0
    fi

    # Use a while-read loop instead of xargs to handle the case where
    # /Applications contains no .app bundles.  macOS xargs lacks GNU
    # --no-run-if-empty, so the previous pipeline ran basename with no
    # arguments — which fails under set -e.
    local app
    (
        while IFS= read -r -d '' app; do
            basename "$app" .app
        done < <(find /Applications -maxdepth 1 -name '*.app' -print0)
    ) | LC_ALL=C sort -f >"$output_file"

    ok "Listed $(wc -l < "$output_file" | tr -d ' ') applications"
}

# ----
# Mac to repository
# ----
collect_local_files() {
local path

require_repository
ensure_repository_structure

for path in "${MANAGED_DIRECTORIES[@]}"; do
    log "Copying ~/$path into the repository"

    sync_directory \
        "$(local_path "$path")" \
        "$(repository_path "$path")" \
        "${DIRECTORY_EXCLUDES[@]}" \
        --exclude='.git/'
done

for path in "${MANAGED_FILES[@]}"; do
    log "Copying ~/$path into the repository"

    collect_managed_file \
        "$(local_path "$path")" \
        "$(repository_path "$path")"
done

for path in "${MACHINE_DIRECTORIES[@]+"${MACHINE_DIRECTORIES[@]}"}"; do
    if [[ -d "$(local_path "$path")" ]]; then
        log "Copying ~/$path into the repository (machine: $MACHINE)"

        run mkdir -p "$(machine_repository_path "$path")"
        sync_directory \
            "$(local_path "$path")" \
            "$(machine_repository_path "$path")" \
            "${DIRECTORY_EXCLUDES[@]}" \
            --exclude='.git/'
    elif [[ -d "$(machine_repository_path "$path")" ]]; then
        log "Local directory was removed. Removing repository copy: machines/$MACHINE/home/$path"
        run rm -rf "$(machine_repository_path "$path")"
    else
        warn "Managed directory does not exist: $(local_path "$path")"
    fi
done

for path in "${MACHINE_FILES[@]}"; do
    log "Copying ~/$path into the repository (machine: $MACHINE)"

    # Create parent directory on demand — only when the source file exists.
    if [[ -e "$(local_path "$path")" || -L "$(local_path "$path")" ]]; then
        run mkdir -p "$(dirname "$(machine_repository_path "$path")")"
    fi

    collect_managed_file \
        "$(local_path "$path")" \
        "$(machine_repository_path "$path")"
done
}

update_from_remote_before_push() {
require_repository

if ! remote_branch_exists; then
    log "Remote branch does not yet exist: $GIT_BRANCH"
    return 0
fi

# Auto-stash any uncommitted changes (e.g. manual edits or file copies
# made directly in the repo dir) so the fetch/rebase has a clean tree.
# The stash is popped after rebase, letting commit_and_push pick them up.
local stashed=0
if ! repository_is_clean; then
    step "Stashing uncommitted changes before remote update"
    run git -C "$REPO_DIR" stash push -m "macos-config-sync: auto-stash before rebase"
    stashed=1
fi

step "Fetching current remote branch"

run git -C "$REPO_DIR" fetch origin "$GIT_BRANCH"

if [[ "$DRY_RUN" == "1" ]]; then
    (( stashed )) && run git -C "$REPO_DIR" stash pop
    return 0
fi

# Record the current HEAD before the rebase so the staleness guard can
# diff against it later to identify files actually changed by the remote.
if repository_has_commits; then
    PRE_REBASE_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
    git -C "$REPO_DIR" rebase "origin/$GIT_BRANCH"
else
    git -C "$REPO_DIR" checkout \
        -B "$GIT_BRANCH" \
        "origin/$GIT_BRANCH"
fi

if (( stashed )); then
    step "Restoring stashed changes"
    git -C "$REPO_DIR" stash pop || die "Stash pop failed — resolve conflicts in $REPO_DIR"
fi
}

# True when local commits exist that the remote branch does not have —
# either the remote branch is missing entirely, or the local branch is
# ahead of origin/$GIT_BRANCH.
has_unpushed_commits() {
    repository_has_commits || return 1

    # Remote branch missing → everything local is unpushed.
    if ! git -C "$REPO_DIR" show-ref \
        --verify \
        --quiet \
        "refs/remotes/origin/$GIT_BRANCH"; then
        return 0
    fi

    [[ -n "$(git -C "$REPO_DIR" rev-list "origin/$GIT_BRANCH..$GIT_BRANCH" 2>/dev/null)" ]]
}

commit_and_push() {
require_repository

# Files are already staged by scan_for_secrets (git add --all runs there
# so the scan covers newly added files).  No need to re-stage here.

if [[ "$DRY_RUN" == "1" ]]; then
    run git -C "$REPO_DIR" status --short
    return 0
fi

if git -C "$REPO_DIR" diff --cached --quiet; then
    log "No configuration changes to commit"

    # No new changes, but earlier commits may never have reached GitHub
    # (e.g. a previous push failed after committing, or the remote branch
    # has not been created yet). Push them now rather than stranding them.
    if has_unpushed_commits; then
        log "Local commits have not been pushed yet — pushing now"
        git -C "$REPO_DIR" push -u origin "$GIT_BRANCH"
        ok "Changes pushed to GitHub"
    fi

    return 0
fi

local computer_name
local timestamp

computer_name="$(scutil --get ComputerName 2>/dev/null || hostname)"
timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"

git -C "$REPO_DIR" commit \
    -m "Update configuration from ${computer_name} at ${timestamp}"

git -C "$REPO_DIR" push -u origin "$GIT_BRANCH"

log "Changes pushed to GitHub"
}

# ----
# Pre-push secret scan
# ----
#
# Defence-in-depth for all managed files — shared paths, machine-specific
# configuration, and any newly added managed paths.  The scan stages all
# pending changes (git add --all), then inspects the staged index
# (git diff --cached) for common secret material patterns and aborts the
# push if any are found.  If the scan fails, staged changes are unstaged
# (git reset) so the push is cleanly aborted without leaving a dirty index.
#

# Patterns that strongly indicate secret material when found in file content.
# Each entry is a grep -E extended regex matched against every staged file.
SECRET_CONTENT_PATTERNS=(
    '-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----'
    '-----BEGIN ENCRYPTED PRIVATE KEY-----'
    '"(access_token|refresh_token|client_secret|api_key|apikey|secret_key|private_key)"[[:space:]]*:'
    'AKIA[0-9A-Z]{16}'
    'ghp_[0-9a-zA-Z]{36}'
    'gho_[0-9a-zA-Z]{36}'
    'ghs_[0-9a-zA-Z]{36}'
    'github_pat_[0-9a-zA-Z_]{22,}'
    'glpat-[0-9a-zA-Z_\-]{20}'
    'sk-[0-9a-zA-Z]{20,}'
    'xox[bpars]-[0-9a-zA-Z\-]+'
)

# Filename patterns that typically indicate secret/credential files,
# beyond what EXCLUDE_PATTERNS already covers.
SECRET_FILENAME_PATTERNS=(
    '\.env$'
    '\.env\.'
    'id_rsa$'
    'id_ecdsa$'
    'id_ed25519$'
    '\.secret$'
    '_secret\.json$'
    # Escaped '.' — the previous unescaped '.' matched ANY character
    # (e.g. 'serviceXaccount.json'), widening the pattern beyond intent.
    'service\.account\.json$'
    'service-account\.json$'
    'service_account\.json$'
)

scan_for_secrets() {
    require_repository

    # Stage everything first so that newly added files are included in the
    # scan.  Without this, git diff --cached would miss files that have
    # never been tracked before.
    run git -C "$REPO_DIR" add --all

    step "Scanning staged files for secret material"

    local -i findings=0
    local pattern relative_path

    local combined_pattern
    combined_pattern=$(printf '%s\n' "${SECRET_CONTENT_PATTERNS[@]}" | paste -sd'|' -)

    # Enumerate staged files (added, copied, modified, renamed) restricted
    # to the home/ and machines/ trees so repository-internal files (e.g.
    # .git/, README.md) are excluded.  NUL-delimited for safe handling of
    # paths with spaces or special characters.
    local -a staged_files=()
    while IFS= read -r -d '' file; do
        case "$file" in
            home/*|machines/*) staged_files+=("$file") ;;
        esac
    done < <(git -C "$REPO_DIR" diff --cached --name-only --diff-filter=ACMR -z)

    if (( ${#staged_files[@]} == 0 )); then
        ok "Secret scan passed (no staged files to scan)"
        return 0
    fi

    for relative_path in "${staged_files[@]}"; do
        # Check filename against suspicious patterns
        for pattern in "${SECRET_FILENAME_PATTERNS[@]}"; do
            if [[ "$relative_path" =~ $pattern ]]; then
                warn "Suspicious filename: $relative_path (matches: $pattern)"
                findings=$((findings + 1))
                break
            fi
        done

        # Stream the staged blob directly from the Git index into grep
        # rather than capturing it into a Bash variable.  Bash variables
        # cannot safely represent NUL bytes, so binary blobs would be
        # silently truncated — corrupting the content scan.

        # Skip binary files.  grep -Iq reads the first buffer and exits
        # quietly if it finds a NUL byte — unlike the previous MIME-based
        # check, this correctly treats application/json (and other
        # structured-text MIME types) as scannable text.
        if ! git -C "$REPO_DIR" show ":$relative_path" 2>/dev/null |
            grep -Iq '' 2>/dev/null; then
            continue
        fi

        # Use -e to force pattern interpretation — several patterns begin
        # with '-----BEGIN' whose leading dashes grep otherwise parses as
        # option flags.
        if git -C "$REPO_DIR" show ":$relative_path" 2>/dev/null |
            grep -qE -e "$combined_pattern" 2>/dev/null; then
            warn "Possible secret content in: $relative_path"
            # Show which pattern matched (without revealing the secret value)
            for pattern in "${SECRET_CONTENT_PATTERNS[@]}"; do
                if git -C "$REPO_DIR" show ":$relative_path" 2>/dev/null |
                    grep -qE -e "$pattern" 2>/dev/null; then
                    warn "  matched pattern: $pattern"
                fi
            done
            findings=$((findings + 1))
        fi
    done

    if (( findings > 0 )); then
        echo "" >&2
        warn "Secret scan found $findings suspicious file(s) in the repository."
        warn "Review the warnings above. If these are false positives, add"
        warn "appropriate patterns to EXCLUDE_PATTERNS and re-run push."
        # Unstage everything so the push is cleanly aborted without leaving
        # a dirty index that a subsequent push would skip over.
        git -C "$REPO_DIR" reset --quiet HEAD -- . 2>/dev/null || true
        die "Aborting push — resolve secret scan findings first."
    fi

    ok "Secret scan passed (no findings)"
}

# ----
# Staleness guard
# ----
#
# Prevents a push from silently overwriting or discarding remote changes
# that the user has not yet incorporated locally.
#
# After rebase, the guard diffs PRE_REBASE_HEAD (old) against the current
# HEAD (new) to find files the remote changed. For each such file it
# performs a three-way comparison — local copy vs old blob vs new blob —
# and classifies the result:
#
#   M (modified on remote):
#     local == old          → stale (user never pulled the update)
#     local == new          → safe  (user already has the remote version)
#     local != old != new   → conflict (both sides edited independently)
#     local missing         → conflict (deleted locally, modified on remote)
#
#   A (added on remote):
#     local missing         → stale (remote addition not yet restored)
#     local == new          → safe  (user already has the same content)
#     local != new          → conflict (local file differs from remote add)
#
#   D (deleted on remote):
#     local == old          → stale (pushing would resurrect deleted file)
#     local != old          → conflict (local edits vs remote deletion)
#     local missing         → safe  (both sides agree)
#
# Any stale or conflicting file aborts the push. The FORCE_PUSH=1 escape
# hatch bypasses the guard when the user intentionally wants to overwrite.

check_for_unrestored_remote_changes() {
    require_repository

    if [[ "${FORCE_PUSH:-0}" == "1" ]]; then
        log "FORCE_PUSH is set — skipping staleness guard"
        return 0
    fi

    # PRE_REBASE_HEAD is set by update_from_remote_before_push() just
    # before the rebase. If it is empty the rebase was skipped (no
    # remote branch, no commits, or DRY_RUN) — nothing to check.
    [[ -n "$PRE_REBASE_HEAD" ]] || return 0

    local post_rebase_head
    post_rebase_head="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)" || return 0

    # If HEAD did not move, the rebase introduced no remote changes.
    if [[ "$PRE_REBASE_HEAD" == "$post_rebase_head" ]]; then
        ok "Staleness guard passed — no remote changes in rebase"
        return 0
    fi

    ensure_machine_name

    local -a stale_files=()
    local status repo_path

    # Enumerate files changed between the old and new HEAD. Only paths
    # under home/ or this machine's tree are relevant — everything else
    # (README.md, .gitignore, other machines' trees) is skipped.
    while IFS=$'\t' read -r status repo_path; do
        [[ -n "$repo_path" ]] || continue

        local home_relative=""
        case "$repo_path" in
            home/*)
                home_relative="${repo_path#home/}"
                ;;
            machines/"$MACHINE"/home/*)
                home_relative="${repo_path#machines/"$MACHINE"/home/}"
                ;;
            *)
                continue
                ;;
        esac

        local local_file
        local_file="$(local_path "$home_relative")"

        case "$status" in
            M)
                # Modified by the remote.
                if [[ ! -e "$local_file" ]]; then
                    # File was deleted locally but modified on the remote.
                    # Pushing would delete the remote version — conflict.
                    stale_files+=("~/$home_relative (deleted locally, modified on remote)")
                elif [[ -f "$local_file" ]]; then
                    # Compare local against the OLD (pre-rebase) blob.
                    if git -C "$REPO_DIR" show "$PRE_REBASE_HEAD:$repo_path" 2>/dev/null |
                        cmp -s - "$local_file"; then
                        # Local == old: user never incorporated the remote
                        # change — stale.
                        stale_files+=("~/$home_relative")
                    elif ! git -C "$REPO_DIR" show "$post_rebase_head:$repo_path" 2>/dev/null |
                        cmp -s - "$local_file"; then
                        # Local != old AND local != new: both sides
                        # changed the file independently — conflict.
                        stale_files+=("~/$home_relative (conflicting local and remote edits)")
                    fi
                    # Local == new: user already has the remote version
                    # (or made identical edits) — safe to push.
                fi
                ;;
            A)
                # Added by the remote.
                if [[ ! -e "$local_file" ]]; then
                    # File does not exist locally — the remote addition
                    # has not been restored.
                    stale_files+=("~/$home_relative (new from remote)")
                elif [[ -f "$local_file" ]]; then
                    if ! git -C "$REPO_DIR" show "$post_rebase_head:$repo_path" 2>/dev/null |
                        cmp -s - "$local_file"; then
                        # Local file exists but differs from the remote
                        # addition — conflict.
                        stale_files+=("~/$home_relative (conflicts with remote addition)")
                    fi
                    # Local == new: user already has the same content —
                    # safe to push.
                fi
                ;;
            D)
                # Deleted by the remote.
                if [[ -f "$local_file" ]]; then
                    if git -C "$REPO_DIR" show "$PRE_REBASE_HEAD:$repo_path" 2>/dev/null |
                        cmp -s - "$local_file"; then
                        # Local == old: user never touched the file —
                        # pushing would silently resurrect it.
                        stale_files+=("~/$home_relative (deleted on remote)")
                    else
                        # Local != old: user edited the file, but the
                        # remote deleted it — conflict.
                        stale_files+=("~/$home_relative (edited locally, deleted on remote)")
                    fi
                fi
                # Local file missing: both sides agree on deletion — safe.
                ;;
        esac
    done < <(git -C "$REPO_DIR" diff --no-renames --name-status "$PRE_REBASE_HEAD" "$post_rebase_head" --)

    if (( ${#stale_files[@]} > 0 )); then
        echo "" >&2
        warn "The remote contains changes that conflict with the local state."
        warn "Pushing now would overwrite or discard these remote changes:"
        local stale_path
        for stale_path in "${stale_files[@]}"; do
            warn "  $stale_path"
        done
        echo "" >&2
        warn "Run '$SCRIPT_NAME pull' first to restore the latest versions,"
        warn "then re-run push. To force this push anyway, set FORCE_PUSH=1."
        die "Aborting push — unrestored remote changes detected."
    fi

    ok "Staleness guard passed — local files are up to date with remote changes"
}

push_configuration() {
validate_dependencies
validate_configuration
require_repository
show_tool_versions

update_from_remote_before_push
check_for_unrestored_remote_changes
generate_brewfile
generate_installed_apps_list
collect_local_files
prune_unmanaged_repository_paths
prune_unmanaged_machine_paths
create_repository_files
scan_for_secrets
commit_and_push
mirror_repository_to_nas
}

# ----
# Backup handling
# ----
create_local_backup() {
local backup_dir
local path

backup_dir="$BACKUP_ROOT/$(date '+%Y%m%d_%H%M%S')"

step "Creating local backup: $backup_dir"

run mkdir -p "$backup_dir"

for path in "${MANAGED_DIRECTORIES[@]}"; do
    if [[ -d "$(local_path "$path")" ]]; then
        run mkdir -p "$(backup_path "$backup_dir" "$path")"

        run rsync \
            "${COMMON_RSYNC_OPTIONS[@]}" \
            "$(local_path "$path")/" \
            "$(backup_path "$backup_dir" "$path")/"
    else
        warn "Source directory does not exist: $(local_path "$path")"
    fi
done

for path in "${MANAGED_FILES[@]}"; do
    sync_file \
        "$(local_path "$path")" \
        "$(backup_path "$backup_dir" "$path")"
done

# Machine-specific paths are backed up too — a pull/restore may overwrite
# them, so they need the same safety net as the shared paths.
for path in "${MACHINE_DIRECTORIES[@]+"${MACHINE_DIRECTORIES[@]}"}"; do
    if [[ -d "$(local_path "$path")" ]]; then
        run mkdir -p "$(backup_path "$backup_dir" "$path")"

        run rsync \
            "${COMMON_RSYNC_OPTIONS[@]}" \
            "$(local_path "$path")/" \
            "$(backup_path "$backup_dir" "$path")/"
    else
        warn "Source directory does not exist: $(local_path "$path")"
    fi
done

for path in "${MACHINE_FILES[@]}"; do
    sync_file \
        "$(local_path "$path")" \
        "$(backup_path "$backup_dir" "$path")"
done

ok "Local backup completed"
}

prune_local_backups() {
if (( BACKUP_RETENTION == 0 )); then
return 0
fi

[[ -d "$BACKUP_ROOT" ]] || return 0

local backup_count
local remove_count

backup_count="$(
    find "$BACKUP_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d |
        wc -l |
        tr -d ' '
)"

if (( backup_count <= BACKUP_RETENTION )); then
    return 0
fi

remove_count=$((backup_count - BACKUP_RETENTION))

step "Removing $remove_count old local backup(s)"

while IFS= read -r old_backup; do
    [[ -n "$old_backup" ]] || continue
    run rm -rf "$old_backup"
done < <(
    find "$BACKUP_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -print |
        sort |
        head -n "$remove_count"
)
}

# ----
# Repository to Mac
# ----
restore_local_files() {
local path

require_repository

[[ -d "$REPO_DIR/home" ]] ||
    die "Repository does not contain the expected home directory."

create_local_backup

for path in "${MANAGED_DIRECTORIES[@]}"; do
    log "Restoring ~/$path"

    sync_directory \
        "$(repository_path "$path")" \
        "$(local_path "$path")" \
        "${DIRECTORY_EXCLUDES[@]}" \
        --exclude='.git/'
done

for path in "${MANAGED_FILES[@]}"; do
    log "Restoring ~/$path"

    sync_file \
        "$(repository_path "$path")" \
        "$(local_path "$path")"
done

# Machine-specific paths are restored only when the repository contains a
# tree for this machine. Other machines' trees are never touched.
ensure_machine_name

if [[ -d "$(machine_repository_root)/home" ]]; then
    for path in "${MACHINE_DIRECTORIES[@]+"${MACHINE_DIRECTORIES[@]}"}"; do
        if [[ -d "$(machine_repository_path "$path")" ]]; then
            log "Restoring ~/$path (machine: $MACHINE)"

            sync_directory \
                "$(machine_repository_path "$path")" \
                "$(local_path "$path")" \
                "${DIRECTORY_EXCLUDES[@]}" \
                --exclude='.git/'
        else
            log "Skipping ~/$path (not present for machine: $MACHINE)"
        fi
    done

    for path in "${MACHINE_FILES[@]}"; do
        if [[ -f "$(machine_repository_path "$path")" ]]; then
            log "Restoring ~/$path (machine: $MACHINE)"

            sync_file \
                "$(machine_repository_path "$path")" \
                "$(local_path "$path")"
        else
            log "Skipping ~/$path (not present for machine: $MACHINE)"
        fi
    done
else
    log "No machine-specific configuration for this machine ($MACHINE); skipping machine restore"
    log "Run push on this machine to record its machine-specific files"
fi

if [[ -d "$HOME/scripts" ]]; then
    run find "$HOME/scripts" \
        -type f \
        -name '*.sh' \
        -exec chmod u+x {} +
fi

# GPG expects its home directory and configuration files to be accessible
# only by the owner. Without this, gpg may refuse to use the key ring and
# gpg-agent may reject its own configuration.
if [[ -d "$HOME/.gnupg" ]]; then
    run chmod 700 "$HOME/.gnupg"
    run find "$HOME/.gnupg" \
        -type f \
        -exec chmod 600 {} +
fi

# SSH refuses to use a config file (or key files) that are group- or
# world-readable. Apply the same restrictive permissions as ~/.gnupg.
# Also ensure the ControlPath sockets directory exists — the sync script
# manages ~/.ssh/config (which may reference it) but not the directory
# itself, so a fresh restore would leave multiplexing broken.
if [[ -d "$HOME/.ssh" ]]; then
    run chmod 700 "$HOME/.ssh"
    run mkdir -p "$HOME/.ssh/sockets"
    run chmod 700 "$HOME/.ssh/sockets"
    run find "$HOME/.ssh" \
        -type f \
        -exec chmod 600 {} +
fi

prune_local_backups

ok "Configuration restored"
log "Open a new terminal session or run: ${C_BOLD}exec zsh${C_RESET}"
}

pull_configuration() {
validate_dependencies
validate_configuration
require_repository
show_tool_versions

repository_is_clean ||
    die "The local repository contains uncommitted changes. Run push or inspect the repository first."

remote_branch_exists ||
    die "Remote branch does not exist: $GIT_BRANCH"

step "Fetching the latest configuration from GitHub"

run git -C "$REPO_DIR" fetch origin "$GIT_BRANCH"
run git -C "$REPO_DIR" checkout "$GIT_BRANCH"
run git -C "$REPO_DIR" pull --ff-only origin "$GIT_BRANCH"

restore_local_files
mirror_repository_to_nas
}

# ----
# Local-only restore (no remote contact)
# ----
#
# Restores files from the local repository to $HOME without fetching from
# the remote. Designed for bootstrap.sh, where the repository has just been
# cloned via HTTPS but the remote has already been switched to SSH — and the
# SSH keys needed for that remote are inside the repository waiting to be
# restored.
#
restore_configuration() {
validate_dependencies
validate_configuration
require_repository
show_tool_versions

step "Restoring configuration from local repository (no remote contact)"
restore_local_files
}

# ----
# NAS synchronisation
# ----
mirror_repository_to_nas() {
require_repository

# --delete-excluded removes excluded paths (such as a pre-existing .git
# directory) from the NAS mirror. --delete alone protects excluded paths.
# --checksum verifies file integrity by comparing checksums rather than
# relying solely on mtime/size, which guards against silent data corruption
# on network mounts (SMB/NFS). The performance cost is negligible for a
# small configuration repository.
local -a nas_mirror_options=(
    --checksum
    --delete
    --delete-excluded
    --exclude='.git/'
    --exclude='.DS_Store'
)

if nas_ssh_available; then
    step "Mirroring repository files to NAS via SSH: $NAS_SSH_HOST:$NAS_SSH_DIR"

    # SSH preserves Unix permissions natively — no --no-perms needed.
    # --rsync-path serves two purposes: it creates the remote directory
    # on the first run (avoiding a separate SSH connection) and it pins
    # the NAS rsync binary so the correct version is used regardless of
    # the remote shell's PATH.
    run rsync \
        -e "$NAS_SSH_CMD" \
        --rsync-path="mkdir -p $NAS_SSH_DIR && $NAS_RSYNC_PATH" \
        "${COMMON_RSYNC_OPTIONS[@]}" \
        "${nas_mirror_options[@]}" \
        "$REPO_DIR/" \
        "$NAS_SSH_HOST:$NAS_SSH_DIR/"

    ok "NAS mirror updated (SSH)"
elif nas_smb_available; then
    step "Mirroring repository files to NAS via SMB: $NAS_REPO_DIR"

    run mkdir -p "$NAS_REPO_DIR"

    # --no-perms: SMB mounts cannot preserve Unix permission bits — without
    # it, every file is reported as changed on every run.
    run rsync \
        "${COMMON_RSYNC_OPTIONS[@]}" \
        --no-perms \
        "${nas_mirror_options[@]}" \
        "$REPO_DIR/" \
        "$NAS_REPO_DIR/"

    ok "NAS mirror updated (SMB)"
else
    warn "NAS is unreachable (SSH host: $NAS_SSH_HOST, SMB mount: $NAS_ROOT)"
    warn "The GitHub operation completed, but the NAS mirror was not updated."
fi
}

restore_repository_from_nas() {
validate_dependencies
validate_configuration
require_nas
show_tool_versions

if [[ -e "$REPO_DIR" ]]; then
    die "Local repository already exists: $REPO_DIR"
fi

run mkdir -p "$(dirname "$REPO_DIR")"

if nas_ssh_available; then
    # Verify the remote mirror exists before pulling.
    ssh -n "${NAS_SSH_OPTS[@]}" "$NAS_SSH_HOST" \
        "test -d $NAS_SSH_DIR/home" ||
        die "No repository mirror was found at: $NAS_SSH_HOST:$NAS_SSH_DIR"

    step "Restoring local repository files from NAS via SSH: $NAS_SSH_HOST:$NAS_SSH_DIR"

    run rsync \
        -e "$NAS_SSH_CMD" \
        --rsync-path="$NAS_RSYNC_PATH" \
        "${COMMON_RSYNC_OPTIONS[@]}" \
        "$NAS_SSH_HOST:$NAS_SSH_DIR/" \
        "$REPO_DIR/"

    ok "Repository files restored (SSH)"
elif nas_smb_available; then
    [[ -d "$NAS_REPO_DIR/home" ]] ||
        die "No repository mirror was found at: $NAS_REPO_DIR"

    step "Restoring local repository files from NAS via SMB: $NAS_REPO_DIR"

    # --no-perms: the SMB mount cannot store Unix permission bits, so the
    # values it reports are meaningless mount-level defaults. Omitting them
    # lets the restored files inherit permissions from the local umask.
    run rsync \
        "${COMMON_RSYNC_OPTIONS[@]}" \
        --no-perms \
        "$NAS_REPO_DIR/" \
        "$REPO_DIR/"

    ok "Repository files restored (SMB)"
else
    die "NAS is unreachable (SSH host: $NAS_SSH_HOST, SMB mount: $NAS_ROOT)"
fi

step "Re-attaching Git history from GitHub"

if git ls-remote "$GITHUB_REPO" >/dev/null 2>&1; then
    run git -C "$REPO_DIR" init
    run git -C "$REPO_DIR" remote add origin "$GITHUB_REPO"
    run git -C "$REPO_DIR" fetch origin "$GIT_BRANCH"

    if [[ "$DRY_RUN" != "1" ]]; then
        git -C "$REPO_DIR" symbolic-ref HEAD "refs/heads/$GIT_BRANCH"

        # Mixed reset keeps the NAS-restored working tree intact while
        # pointing the branch and index at the fetched GitHub history.
        git -C "$REPO_DIR" reset "origin/$GIT_BRANCH"
        git -C "$REPO_DIR" branch --set-upstream-to "origin/$GIT_BRANCH"
    fi

    ok "Repository restored from NAS and reconnected to GitHub"
    log "Run '$SCRIPT_NAME pull' to deploy the restored files."
else
    warn "Unable to access GitHub repository: $GITHUB_REPO"
    warn "Files were restored, but the Git history was not re-attached."
    warn "Remove $REPO_DIR and run '$SCRIPT_NAME init' once GitHub is reachable, or re-run nas-pull."
fi
}

# ----
# Status
# ----
show_status() {
validate_dependencies
validate_configuration
show_tool_versions

printf '\n'
printf '%sGitHub repository:%s %s\n' "$C_BLUE" "$C_RESET" "$GITHUB_REPO"
printf '%sGit branch:%s        %s\n' "$C_BLUE" "$C_RESET" "$GIT_BRANCH"
printf '%sLocal repository:%s  %s\n' "$C_BLUE" "$C_RESET" "$REPO_DIR"
printf '%sNAS SSH host:%s       %s\n' "$C_BLUE" "$C_RESET" "$NAS_SSH_HOST"
printf '%sNAS SSH directory:%s  %s\n' "$C_BLUE" "$C_RESET" "$NAS_SSH_DIR"
printf '%sNAS SMB root:%s       %s\n' "$C_BLUE" "$C_RESET" "$NAS_ROOT"
printf '%sNAS SMB repository:%s %s\n' "$C_BLUE" "$C_RESET" "$NAS_REPO_DIR"
printf '%sBackup directory:%s  %s\n' "$C_BLUE" "$C_RESET" "$BACKUP_ROOT"
printf '%sBackup retention:%s  %s\n' "$C_BLUE" "$C_RESET" "$BACKUP_RETENTION"
printf '%sMachine name:%s      %s\n' "$C_BLUE" "$C_RESET" "$MACHINE"
printf '\n%sShared managed paths:%s\n' "$C_BOLD" "$C_RESET"
print_managed_paths
printf '\n%sMachine-specific paths (machines/%s/home):%s\n' "$C_BOLD" "$MACHINE" "$C_RESET"
print_machine_paths

if [[ -d "$REPO_DIR/machines" ]]; then
    printf '\n%sMachines recorded in the repository:%s\n' "$C_BOLD" "$C_RESET"
    local machine_dir
    while IFS= read -r machine_dir; do
        if [[ "${machine_dir##*/}" == "$MACHINE" ]]; then
            printf '  %s%s (this machine)%s\n' "$C_GREEN" "${machine_dir##*/}" "$C_RESET"
        else
            printf '  %s\n' "${machine_dir##*/}"
        fi
    done < <(find "$REPO_DIR/machines" -mindepth 1 -maxdepth 1 -type d | sort)
fi
printf '\n'

if repository_exists; then
    printf '\n%sLocal Git status:%s\n' "$C_BOLD" "$C_RESET"
    git -C "$REPO_DIR" status --short --branch
    printf '\n'

    printf '%sConfigured remotes:%s\n' "$C_BOLD" "$C_RESET"
    git -C "$REPO_DIR" remote -v
    printf '\n'

    if repository_has_commits; then
        printf '%sLatest local commit:%s\n' "$C_BOLD" "$C_RESET"
        git -C "$REPO_DIR" log \
            -1 \
            --date=iso \
            --format='  %h %ad %an%n  %s'
        printf '\n\n'
    else
        printf '%sThe local repository does not yet contain a commit.%s\n\n' "$C_YELLOW" "$C_RESET"
    fi

    if remote_branch_exists; then
        printf '%s✔ Remote branch is available:%s origin/%s\n' "$C_GREEN" "$C_RESET" "$GIT_BRANCH"
    else
        printf '%s✘ Remote branch is not available:%s origin/%s\n' "$C_RED" "$C_RESET" "$GIT_BRANCH"
    fi
else
    printf '%s✘ Local repository is not initialised.%s\n' "$C_RED" "$C_RESET"
fi

printf '\n'

if nas_ssh_available; then
    printf '%s✔ NAS SSH is reachable:%s %s\n' "$C_GREEN" "$C_RESET" "$NAS_SSH_HOST"

    if ssh -n "${NAS_SSH_OPTS[@]}" "$NAS_SSH_HOST" "test -d $NAS_SSH_DIR/home" 2>/dev/null; then
        printf '%s✔ NAS repository mirror is present (SSH).%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '%s✘ NAS repository mirror is not present (SSH).%s\n' "$C_YELLOW" "$C_RESET"
    fi
else
    printf '%s✘ NAS SSH is not reachable:%s %s\n' "$C_RED" "$C_RESET" "$NAS_SSH_HOST"
fi

if nas_smb_available; then
    printf '%s✔ NAS SMB is mounted:%s %s\n' "$C_GREEN" "$C_RESET" "$NAS_ROOT"

    if [[ -d "$NAS_REPO_DIR/home" ]]; then
        printf '%s✔ NAS repository mirror is present (SMB).%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '%s✘ NAS repository mirror is not present (SMB).%s\n' "$C_YELLOW" "$C_RESET"
    fi
else
    printf '%s✘ NAS SMB is not mounted:%s %s\n' "$C_RED" "$C_RESET" "$NAS_ROOT"
fi
}

# ----
# Main
# ----
main() {
local command="${1:-help}"
local requires_lock=0

case "$command" in
    init | push | pull | restore | nas-push | nas-pull)
        requires_lock=1
        ;;
esac

if (( requires_lock == 1 )); then
    acquire_lock
    trap release_lock EXIT
fi

case "$command" in
    init)
        initialise_repository
        ;;
    push)
        push_configuration
        ;;
    pull)
        pull_configuration
        ;;
    restore)
        restore_configuration
        ;;
    status)
        show_status
        ;;
    nas-push)
        validate_dependencies
        validate_configuration
        require_repository
        show_tool_versions
        mirror_repository_to_nas
        ;;
    nas-pull)
        restore_repository_from_nas
        ;;
    version | --version | -V)
        printf '%s version %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        ;;
    help | --help | -h)
        usage
        ;;
    *)
        usage >&2
        die "Unknown command: $command"
        ;;
esac
}

main "$@"
