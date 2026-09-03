#!/usr/bin/env bash
#
# macos-config-sync.sh
#
# Version: 2.0.3
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

readonly SCRIPT_VERSION="2.0.2"
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

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.local/state/macos-config/backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-10}"

LOCK_DIR="${LOCK_DIR:-$HOME/.local/state/macos-config/run.lock}"

DRY_RUN="${DRY_RUN:-0}"

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
# Logging and errors
# ----

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'DRY-RUN:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

on_error() {
    local exit_code=$?
    local line_number="${1:-unknown}"

    printf '[%s] ERROR: Command failed at line %s with exit code %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$line_number" \
        "$exit_code" >&2

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
  NAS_ROOT
  NAS_REPO_DIR
  BACKUP_ROOT
  BACKUP_RETENTION
  LOCK_DIR
  MACHINE_NAME
  DRY_RUN=1
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

    log "Script version: $SCRIPT_VERSION"
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

nas_available() {
    [[ -d "$NAS_ROOT" ]]
}

require_nas() {
    nas_available ||
        die "NAS root is unavailable: $NAS_ROOT"
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

    log "Removing repository paths that are no longer managed"

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

    log "Removing machine paths that are no longer managed (machine: $MACHINE)"

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

log "Checking access to GitHub repository"

git ls-remote "$GITHUB_REPO" >/dev/null 2>&1 ||
    die "Unable to access GitHub repository: $GITHUB_REPO"

run mkdir -p "$(dirname "$REPO_DIR")"

log "Cloning GitHub repository"
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

log "Repository initialised: $REPO_DIR"
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
    log "Stashing uncommitted changes before remote update"
    run git -C "$REPO_DIR" stash push -m "macos-config-sync: auto-stash before rebase"
    stashed=1
fi

log "Fetching current remote branch"

run git -C "$REPO_DIR" fetch origin "$GIT_BRANCH"

if [[ "$DRY_RUN" == "1" ]]; then
    (( stashed )) && run git -C "$REPO_DIR" stash pop
    return 0
fi

if repository_has_commits; then
    git -C "$REPO_DIR" rebase "origin/$GIT_BRANCH"
else
    git -C "$REPO_DIR" checkout \
        -B "$GIT_BRANCH" \
        "origin/$GIT_BRANCH"
fi

if (( stashed )); then
    log "Restoring stashed changes"
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

run git -C "$REPO_DIR" add --all

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
        log "Changes pushed to GitHub"
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
# The .config directory is synced with a blocklist (EXCLUDE_PATTERNS), which
# means any new tool that stores secrets under ~/.config with an unlisted
# filename will be committed silently. This scan checks staged files for
# common secret material patterns and aborts the push if any are found.
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

    log "Scanning tracked files for secret material"

    local -i findings=0
    local pattern file relative_path

    local combined_pattern
    combined_pattern=$(printf '%s\n' "${SECRET_CONTENT_PATTERNS[@]}" | paste -sd'|' -)

    # Scan only files tracked by git (not the working-tree walk that find
    # would do).  This avoids false positives from .gitignore'd files,
    # editor swap files, and other untracked artefacts.  Restrict to the
    # home/ and machines/ trees — the same scope the old find-based scanner
    # covered — so repository-internal files (e.g. .git/) are excluded.
    local -a tracked_files=()
    while IFS= read -r file; do
        case "$file" in
            home/*|machines/*) tracked_files+=("$file") ;;
        esac
    done < <(git -C "$REPO_DIR" ls-files)

    (( ${#tracked_files[@]} > 0 )) || { log "Secret scan passed (no tracked files to scan)"; return 0; }

    for relative_path in "${tracked_files[@]}"; do
        file="$REPO_DIR/$relative_path"
        [[ -f "$file" ]] || continue

        # Check filename against suspicious patterns
        for pattern in "${SECRET_FILENAME_PATTERNS[@]}"; do
            if [[ "$relative_path" =~ $pattern ]]; then
                warn "Suspicious filename: $relative_path (matches: $pattern)"
                findings=$((findings + 1))
                break
            fi
        done

        # Check file contents (text files only — skip binary)
        if ! file --brief --mime-type "$file" 2>/dev/null | grep -q '^text/'; then
            continue
        fi

        if grep -qE "$combined_pattern" "$file" 2>/dev/null; then
            warn "Possible secret content in: $relative_path"
            # Show which pattern matched (without revealing the secret value)
            for pattern in "${SECRET_CONTENT_PATTERNS[@]}"; do
                if grep -qE "$pattern" "$file" 2>/dev/null; then
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
        die "Aborting push — resolve secret scan findings first."
    fi

    log "Secret scan passed (no findings)"
}

push_configuration() {
validate_dependencies
validate_configuration
require_repository
show_tool_versions

update_from_remote_before_push
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

log "Creating local backup: $backup_dir"

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

log "Local backup completed"
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

log "Removing $remove_count old local backup(s)"

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

prune_local_backups

log "Configuration restored"
log "Open a new terminal session or run: exec zsh"
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

log "Fetching the latest configuration from GitHub"

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

log "Restoring configuration from local repository (no remote contact)"
restore_local_files
}

# ----
# NAS synchronisation
# ----
mirror_repository_to_nas() {
require_repository

if ! nas_available; then
    warn "NAS is not mounted at: $NAS_ROOT"
    warn "The GitHub operation completed, but the NAS mirror was not updated."
    return 0
fi

log "Mirroring repository files to NAS: $NAS_REPO_DIR"

run mkdir -p "$NAS_REPO_DIR"

# --delete-excluded removes excluded paths (such as a pre-existing .git
# directory) from the NAS mirror. --delete alone protects excluded paths.
# --checksum verifies file integrity by comparing checksums rather than
# relying solely on mtime/size, which guards against silent data corruption
# on network mounts (SMB/NFS). The performance cost is negligible for a
# small configuration repository.
run rsync \
    "${COMMON_RSYNC_OPTIONS[@]}" \
    --checksum \
    --delete \
    --delete-excluded \
    --exclude='.git/' \
    --exclude='.DS_Store' \
    "$REPO_DIR/" \
    "$NAS_REPO_DIR/"

log "NAS mirror updated"
}

restore_repository_from_nas() {
validate_dependencies
validate_configuration
require_nas
show_tool_versions

[[ -d "$NAS_REPO_DIR/home" ]] ||
    die "No repository mirror was found at: $NAS_REPO_DIR"

if [[ -e "$REPO_DIR" ]]; then
    die "Local repository already exists: $REPO_DIR"
fi

log "Restoring local repository files from NAS"

run mkdir -p "$(dirname "$REPO_DIR")"

run rsync \
    "${COMMON_RSYNC_OPTIONS[@]}" \
    "$NAS_REPO_DIR/" \
    "$REPO_DIR/"

log "Re-attaching Git history from GitHub"

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

    log "Repository restored from NAS and reconnected to GitHub"
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
printf 'GitHub repository: %s\n' "$GITHUB_REPO"
printf 'Git branch:        %s\n' "$GIT_BRANCH"
printf 'Local repository:  %s\n' "$REPO_DIR"
printf 'NAS root:          %s\n' "$NAS_ROOT"
printf 'NAS repository:    %s\n' "$NAS_REPO_DIR"
printf 'Backup directory:  %s\n' "$BACKUP_ROOT"
printf 'Backup retention:  %s\n' "$BACKUP_RETENTION"
printf 'Machine name:      %s\n' "$MACHINE"
printf '\nShared managed paths:\n'
print_managed_paths
printf '\nMachine-specific paths (machines/%s/home):\n' "$MACHINE"
print_machine_paths

if [[ -d "$REPO_DIR/machines" ]]; then
    printf '\nMachines recorded in the repository:\n'
    local machine_dir
    while IFS= read -r machine_dir; do
        if [[ "${machine_dir##*/}" == "$MACHINE" ]]; then
            printf '  %s (this machine)\n' "${machine_dir##*/}"
        else
            printf '  %s\n' "${machine_dir##*/}"
        fi
    done < <(find "$REPO_DIR/machines" -mindepth 1 -maxdepth 1 -type d | sort)
fi
printf '\n'

if repository_exists; then
    printf 'Local Git status:\n'
    git -C "$REPO_DIR" status --short --branch
    printf '\n'

    printf 'Configured remotes:\n'
    git -C "$REPO_DIR" remote -v
    printf '\n'

    if repository_has_commits; then
        printf 'Latest local commit:\n'
        git -C "$REPO_DIR" log \
            -1 \
            --date=iso \
            --format='  %h %ad %an%n  %s'
        printf '\n\n'
    else
        printf 'The local repository does not yet contain a commit.\n\n'
    fi

    if remote_branch_exists; then
        printf 'Remote branch is available: origin/%s\n' "$GIT_BRANCH"
    else
        printf 'Remote branch is not available: origin/%s\n' "$GIT_BRANCH"
    fi
else
    printf 'Local repository is not initialised.\n'
fi

printf '\n'

if nas_available; then
    printf 'NAS root is mounted: %s\n' "$NAS_ROOT"

    if [[ -d "$NAS_REPO_DIR/home" ]]; then
        printf 'NAS repository mirror is present.\n'
    else
        printf 'NAS repository mirror is not present.\n'
    fi
else
    printf 'NAS root is not mounted: %s\n' "$NAS_ROOT"
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
