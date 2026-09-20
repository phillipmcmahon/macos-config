#!/usr/bin/env bash
#
# Script: macos-config-sync.sh
# Purpose: Reconcile managed macOS files with GitHub and NAS.
# Version: 1.0.0
# Requires: Bash 5+, Git, jq, modern rsync and adjacent lib/.
# Documentation: docs/USER-MANUAL.md
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION='1.0.0'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
IFS=$'\n\t'
readonly SCRIPT_NAME="${0##*/}"
GITHUB_REPO="${GITHUB_REPO:-git@github.com:phillipmcmahon/macos-config.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-$HOME/.local/share/macos-config}"
NAS_ROOT="${NAS_ROOT:-/Volumes/home}"
NAS_REPO_DIR="${NAS_REPO_DIR:-$NAS_ROOT/macos-config}"
NAS_SSH_HOST="${NAS_SSH_HOST:-homestorage}"
NAS_SSH_DIR="${NAS_SSH_DIR:-macos-config}"
NAS_RSYNC_PATH="${NAS_RSYNC_PATH:-/opt/bin/rsync}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.local/state/macos-config/backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-10}"
LOCK_DIR="${LOCK_DIR:-$HOME/.local/state/macos-config/run.lock}"
DRY_RUN="${DRY_RUN:-0}"
ACCEPT_DELETIONS="${ACCEPT_DELETIONS:-0}"
AUTO_ADD_ENV_SET="${AUTO_ADD+x}"
AUTO_ADD="${AUTO_ADD:-1}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/macos-config-sync/config}"
EXPLICIT_DIRECTORIES=()
EXTRA_EXCLUDE_PATTERNS=()
GENERATED_ROOT=""
SYNC_STATE=""
SCAN_TEMP_DIR=""
MANAGED_DIRECTORIES=(
    ".config/git"
    "docs"
    "scripts"
)
MANAGED_FILES=(
    ".config/.zsh_functions"
    ".config/cloudns/hosts.txt"
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
MACHINE_DIRECTORIES=(
)
MACHINE_FILES=(
    "Brewfile"
    "installed-apps.txt"
    "Moom.plist"
)
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
DIRECTORY_EXCLUDES=()
for _pat in "${EXCLUDE_PATTERNS[@]}"; do
    DIRECTORY_EXCLUDES+=(--exclude="$_pat")
done
unset _pat
COMMON_RSYNC_OPTIONS=(
    --archive
    --checksum
    --human-readable
    --itemize-changes
    --protect-args
)
trap 'on_error "$LINENO"' ERR
MACHINE=""
NAS_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=3)
NAS_SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=3"
SECRET_CONTENT_PATTERNS=(
    '^-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----'
    '^-----BEGIN ENCRYPTED PRIVATE KEY-----'
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
SECRET_FILENAME_PATTERNS=(
    '\.env$'
    '\.env\.'
    'id_rsa$'
    'id_ecdsa$'
    'id_ed25519$'
    '\.secret$'
    '_secret\.json$'
    'service\.account\.json$'
    'service-account\.json$'
    'service_account\.json$'
)

# Command interface
usage() {
    cat << EOF
${0##*/} $SCRIPT_VERSION
Usage: ${0##*/} COMMAND [PATH] [--dry-run] [--yes]

Commands:
  sync        Reconcile HOME and GitHub, deploy and mirror to NAS
  init        Clone the configured repository
  adopt       Trust the current checkout as the already-deployed baseline
  add PATH    Enrol one file within a configured scope
  forget PATH Keep this Mac's file but remove its repository copy on next sync
  cancel      Preserve a pending proposal and reset the private checkout
  pull        Fetch GitHub then replace managed HOME files (confirmation required)
  restore     Replace HOME from the committed checkout (confirmation required)
  status      Show configuration, Git and NAS status
  nas-push    Mirror a clean committed checkout to NAS
  nas-pull    Recover NAS files, with offline restore and later reconnection
  push        Alias for sync

Options:
  --dry-run   Explain the operation without writes (not a computed remote diff)
  --yes       Skip restore/deletion confirmation, never validation
  --version   Show version
  -h, --help  Show help

Settings: ~/.config/macos-config-sync/config, using literal arrays.
Overrides: CONFIG_FILE, REPO_DIR, GITHUB_REPO, GIT_BRANCH, MACHINE_NAME,
BACKUP_ROOT, BACKUP_RETENTION, NAS_SSH_HOST, NAS_SSH_DIR, NAS_RSYNC_PATH,
NAS_ROOT, NAS_REPO_DIR, LOCK_DIR, AUTO_ADD, ACCEPT_DELETIONS, DRY_RUN.
Finish pending transactions with the original bundle before upgrading.
Bash 5+, Git, jq and modern rsync are required. See docs/USER-MANUAL.md.
EOF
}

# Helpers
read_path_configuration() {
    local previous_auto=$AUTO_ADD
    load_config "$CONFIG_FILE" 'MANAGED_DIRECTORIES MANAGED_FILES MACHINE_DIRECTORIES MACHINE_FILES EXPLICIT_DIRECTORIES EXTRA_EXCLUDE_PATTERNS AUTO_ADD' || die 'Invalid managed-path configuration.'
    [[ -z $AUTO_ADD_ENV_SET ]] || AUTO_ADD=$previous_auto
}

load_effective_configuration() {
    if [[ -e $CONFIG_FILE || -L $CONFIG_FILE ]]; then
        read_path_configuration
    elif [[ $CONFIG_FILE != "$HOME/.config/macos-config-sync/config" ]]; then die "Configuration file not found: $CONFIG_FILE"; fi
    EXCLUDE_PATTERNS+=("${EXTRA_EXCLUDE_PATTERNS[@]}")
    DIRECTORY_EXCLUDES=()
    local pattern
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do DIRECTORY_EXCLUDES+=(--exclude="$pattern"); done
}

detect_machine_name() {
    local name=""

    if [[ -n "${MACHINE_NAME:-}" ]]; then
        name="$MACHINE_NAME"
    elif command -v scutil > /dev/null 2>&1; then
        name="$(scutil --get LocalHostName 2> /dev/null || true)"
    fi

    if [[ -z "$name" ]]; then
        name="$(hostname -s 2> /dev/null || true)"
    fi

    name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')"

    [[ -n "$name" && "$name" != "." && "$name" != ".." ]] ||
        die "Could not determine a usable machine name. Set MACHINE_NAME explicitly."

    printf '%s\n' "$name"
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

local_path() {
    case "$1" in
        Brewfile | installed-apps.txt | Moom.plist)
            if [[ -n "$GENERATED_ROOT" ]]; then
                printf '%s/%s\n' "$GENERATED_ROOT" "$1"
                return 0
            fi
            ;;
    esac
    printf '%s/%s\n' "$HOME" "$1"
}

repository_path() {
    printf '%s/home/%s\n' "$REPO_DIR" "$1"
}

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

    if ((${#MACHINE_DIRECTORIES[@]} > 0)); then
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

require_command() {
    command -v "$1" > /dev/null 2>&1 ||
        die "Required command not found: $1"
}

validate_dependencies() {
    require_command jq
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
    require_command comm
    require_command mktemp
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
    validate_remote_dir "$NAS_SSH_DIR" || exit 1
    validate_child_dir "$NAS_ROOT" "$NAS_REPO_DIR" || exit 1
    [[ $NAS_SSH_HOST =~ ^[A-Za-z0-9][A-Za-z0-9@._-]*$ ]] || die 'Invalid NAS SSH host.'
    reject_symlinks "$REPO_DIR" || exit 1
    reject_symlinks "$BACKUP_ROOT" || exit 1
    [[ $REPO_DIR != "$HOME" && $REPO_DIR != / && $BACKUP_ROOT != "$HOME" && $BACKUP_ROOT != / ]] || die 'Dedicated repository and backup directories are required.'
    [[ $BACKUP_RETENTION =~ ^(0|[1-9][0-9]{0,5})$ ]] || die 'Invalid decimal backup retention.'
    local path

    [[ "$BACKUP_RETENTION" =~ ^[0-9]+$ ]] ||
        die "BACKUP_RETENTION must be a non-negative integer."

    [[ "$DRY_RUN" == "0" || "$DRY_RUN" == "1" ]] ||
        die "DRY_RUN must be either 0 or 1."

    [[ "$ACCEPT_DELETIONS" == "0" || "$ACCEPT_DELETIONS" == "1" ]] ||
        die "ACCEPT_DELETIONS must be either 0 or 1."
    [[ "$AUTO_ADD" == "0" || "$AUTO_ADD" == "1" ]] || die "AUTO_ADD must be 0 or 1."

    [[ "${FORCE_PUSH:-0}" == "0" ]] || die "FORCE_PUSH is retired. Resolve conflicts explicitly."

    if [[ -z "$NAS_SSH_DIR" ]]; then
        die "NAS_SSH_DIR must not be empty."
    fi
    if [[ "$NAS_SSH_DIR" == /* || "$NAS_SSH_DIR" == "~"* ]]; then
        die "NAS_SSH_DIR must be a relative path (no leading / or ~): $NAS_SSH_DIR"
    fi
    if [[ "$NAS_SSH_DIR" == ".." || "$NAS_SSH_DIR" == ../* ||
        "$NAS_SSH_DIR" == */../* || "$NAS_SSH_DIR" == */.. ]]; then
        die "NAS_SSH_DIR must not contain path traversal (..): $NAS_SSH_DIR"
    fi
    if [[ "$NAS_SSH_DIR" =~ [^a-zA-Z0-9_./-] ]]; then
        die "NAS_SSH_DIR contains unsafe characters (only alphanumerics, hyphens, underscores, dots, and / are allowed): $NAS_SSH_DIR"
    fi

    if [[ -z "$NAS_RSYNC_PATH" ]]; then
        die "NAS_RSYNC_PATH must not be empty."
    fi
    if [[ "$NAS_RSYNC_PATH" != /* ]]; then
        die "NAS_RSYNC_PATH must be an absolute path: $NAS_RSYNC_PATH"
    fi
    if [[ "$NAS_RSYNC_PATH" =~ [^a-zA-Z0-9_./-] ]]; then
        die "NAS_RSYNC_PATH contains unsafe characters (only alphanumerics, hyphens, underscores, dots, and / are allowed): $NAS_RSYNC_PATH"
    fi

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

    for path in "${EXPLICIT_DIRECTORIES[@]+"${EXPLICIT_DIRECTORIES[@]}"}"; do
        validate_managed_path "$path"
        local found=0 directory
        for directory in "${MANAGED_DIRECTORIES[@]}" "${MACHINE_DIRECTORIES[@]+"${MACHINE_DIRECTORIES[@]}"}"; do
            [[ "$directory" != "$path" ]] || found=1
        done
        [[ "$found" == 1 ]] || die "EXPLICIT_DIRECTORIES must name configured managed directories: $path"
    done

    ensure_machine_name
}

show_tool_versions() {
    local rsync_version_output
    local rsync_version_first_line

    rsync_version_output="$(rsync --version)"
    rsync_version_first_line="${rsync_version_output%%$'\n'*}"

    step "Script version: ${SCRIPT_VERSION}"
    log "Machine name: ${MACHINE:-<not yet resolved>}"
    log "Using rsync: $(command -v rsync)"
    log "$rsync_version_first_line"
}

acquire_lock() {
    lock_acquire "$LOCK_DIR" || exit 1
}

release_lock() {
    local rc=$?
    trap - EXIT
    if [[ -n $SCAN_TEMP_DIR ]]; then rm -rf -- "$SCAN_TEMP_DIR" || rc=1; fi
    lock_release || rc=1
    exit "$rc"
}

repository_exists() {
    [[ ! -L "$REPO_DIR" && -d "$REPO_DIR/.git" ]]
}

require_repository() {
    if [[ -L "$REPO_DIR" ]]; then
        die "Repository directory must not be a symbolic link: $REPO_DIR"
    fi

    repository_exists ||
        die "Repository is not initialised. Run: $SCRIPT_NAME init"
}

repository_has_commits() {
    git -C "$REPO_DIR" rev-parse --verify HEAD > /dev/null 2>&1
}

repository_is_clean() {
    local status
    status="$(git -C "$REPO_DIR" status --porcelain)" || die "Cannot inspect repository status."
    [[ -z "$status" ]]
}

configure_repository_for_sync() {
    run git -C "$REPO_DIR" config core.fileMode false
}

remote_branch_exists() {
    git -C "$REPO_DIR" ls-remote \
        --exit-code \
        --heads \
        origin \
        "$GIT_BRANCH" > /dev/null 2>&1
}

ensure_repository_structure() {
    local path

    ensure_machine_name

    run mkdir -p "$REPO_DIR/home"

    for path in "${MANAGED_DIRECTORIES[@]}"; do
        run mkdir -p "$(repository_path "$path")"
    done

}

nas_ssh_available() {
    ssh -n "${NAS_SSH_OPTS[@]}" "$NAS_SSH_HOST" true 2> /dev/null
}

nas_smb_available() {
    nas_mount_available "$NAS_ROOT"
}

nas_available() {
    nas_ssh_available || nas_smb_available
}

require_nas() {
    nas_available ||
        die "NAS is unreachable (SSH host: $NAS_SSH_HOST, SMB mount: $NAS_ROOT)"
}

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

reject_symlink_components() {
    local root="$1"
    local relative_path="$2"
    local label="${3:-$relative_path}"
    local current="$root"
    local component

    while IFS= read -r component; do
        [[ -n "$component" ]] || continue

        current="$current/$component"

        if [[ -L "$current" ]]; then
            die "Managed path traverses a symbolic link (not supported): $current ($label)"
        fi
    done < <(printf '%s\n' "$relative_path" | tr '/' '\n')
}

reject_symlinks_in_directory() {
    local dir_path="$1"
    local label="${2:-$dir_path}"

    [[ -d "$dir_path" ]] || return 0

    local first_symlink
    first_symlink="$(find "$dir_path" -type l -print -quit 2> /dev/null)" || true

    if [[ -n "$first_symlink" ]]; then
        die "Managed directory contains a symbolic link (not supported): $first_symlink (in $label)"
    fi
}

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

create_repository_files() {
    reject_symlink_components "$REPO_DIR" .gitignore
    reject_symlink_components "$REPO_DIR" README.md
    printf '%s\n' "${EXCLUDE_PATTERNS[@]}" > "$REPO_DIR/.gitignore"
    {
        printf '# macOS configuration\n\nManaged by macos-config-sync.sh %s.\n\n' "$SCRIPT_VERSION"
        printf 'Use `sync` for normal reconciliation. `pull` and `restore` replace managed local files.\n\n'
        printf '## Shared files\n\n'
        printf -- '- `%s`\n' "${MANAGED_FILES[@]}"
        printf '\n## Shared directories\n\n'
        printf -- '- `%s/`\n' "${MANAGED_DIRECTORIES[@]}"
        printf '\n## Machine files\n\n'
        printf -- '- `%s`\n' "${MACHINE_FILES[@]}"
        printf '\n## Machine directories\n\n'
        if ((${#MACHINE_DIRECTORIES[@]})); then printf -- '- `%s/`\n' "${MACHINE_DIRECTORIES[@]}"; else printf 'None configured.\n'; fi
        printf '\nPrivate keys and credentials are excluded. SSH authentication must be restored separately.\n'
        printf '\nSee `home/scripts/docs/USER-MANUAL.md` for recovery, ownership and configuration rules.\n'
    } > "$REPO_DIR/README.md"
}

initialise_repository() {
    validate_dependencies
    validate_configuration
    show_tool_versions

    if [[ -L "$REPO_DIR" ]]; then
        die "Repository directory must not be a symbolic link: $REPO_DIR"
    fi

    if repository_exists; then
        log "Repository is already initialised: $REPO_DIR"
        configure_repository_for_sync
        return 0
    fi

    step "Checking access to GitHub repository"

    git ls-remote "$GITHUB_REPO" > /dev/null 2>&1 ||
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

    configure_repository_for_sync

    ok "Repository initialised: $REPO_DIR"
}

generate_brewfile() {
    local output_file
    output_file="$(local_path "Brewfile")"

    if ! command -v brew > /dev/null 2>&1; then
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

    [[ -d /Applications ]] || {
        warn "No /Applications directory. Inventory generation skipped."
        return 0
    }

    step "Generating installed applications list: $output_file"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: Would write installed apps list to $output_file"
        return 0
    fi

    local app
    (
        while IFS= read -r -d '' app; do
            basename "$app" .app
        done < <(find /Applications -maxdepth 1 -name '*.app' -print0)
    ) | LC_ALL=C sort -f > "$output_file"

    ok "Listed $(wc -l < "$output_file" | tr -d ' ') applications"
}

export_moom_preferences() {
    local output_file
    output_file="$(local_path "Moom.plist")"

    if ! defaults read com.manytricks.Moom > /dev/null 2>&1; then
        warn "Moom is not installed or has no saved preferences — skipping Moom export"
        return 0
    fi

    if pgrep -x "Moom" > /dev/null 2> /dev/null; then
        warn "Moom is running — quit Moom before push for a consistent export"
    fi

    step "Exporting Moom preferences: $output_file"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: Would export Moom preferences to $output_file"
        return 0
    fi

    defaults export com.manytricks.Moom "$output_file"

    ok "Moom preferences exported"
}

restore_moom_preferences() {
    local input_file
    input_file="$(local_path "Moom.plist")"

    if [[ ! -f "$input_file" ]]; then
        log "No Moom.plist found — skipping Moom import"
        return 0
    fi

    if pgrep -x "Moom" > /dev/null 2> /dev/null; then
        warn "Moom is running — quit Moom before pull for settings to take effect"
    fi

    step "Importing Moom preferences: $input_file"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: Would import Moom preferences from $input_file"
        return 0
    fi

    defaults import com.manytricks.Moom "$input_file"

    ok "Moom preferences imported — launch Moom to apply"
}

has_unpushed_commits() {
    repository_has_commits || return 1

    if ! git -C "$REPO_DIR" show-ref \
        --verify \
        --quiet \
        "refs/remotes/origin/$GIT_BRANCH"; then
        return 0
    fi

    local commits
    commits="$(git -C "$REPO_DIR" rev-list "origin/$GIT_BRANCH..$GIT_BRANCH")" || die "Cannot inspect unpushed history."
    [[ -n "$commits" ]]
}

scan_blob() {
    local spec="$1" path="$2" blob="$3" pattern rc combined
    git -C "$REPO_DIR" show "$spec" > "$blob" || die "Cannot extract blob for scanning: $path"
    for pattern in "${SECRET_FILENAME_PATTERNS[@]}"; do
        [[ ! "$path" =~ $pattern ]] || die "Suspicious secret filename: $path"
    done
    combined="$(printf '%s\n' "${SECRET_CONTENT_PATTERNS[@]}" | paste -sd'|' -)"
    if grep -aEq -e "$combined" "$blob"; then
        die "Possible secret in $path. No secret value is printed. Inspect before retrying."
    else
        rc=$?
        [[ "$rc" == 1 ]] || die "Secret scan failed for $path (status $rc)."
    fi
}

scan_for_secrets() {
    git -C "$REPO_DIR" add --all || die "Staging failed."
    local path dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/macos-secret-scan.XXXXXX")"
    SCAN_TEMP_DIR="$dir"
    git -C "$REPO_DIR" diff --cached --name-only --diff-filter=ACMR -z > "$dir/paths" || die "Cannot enumerate staged files."
    while IFS= read -r -d '' path; do
        case "$path" in home/* | machines/*) scan_blob ":$path" "$path" "$dir/blob" ;; esac
    done < "$dir/paths"
    rm -f "$dir/paths" "$dir/blob"
    rmdir "$dir"
    SCAN_TEMP_DIR=""
    ok "Staged secret scan passed"
}

scan_outgoing_commits() {
    local dir commit path
    dir="$(mktemp -d "${TMPDIR:-/tmp}/macos-secret-history.XXXXXX")"
    SCAN_TEMP_DIR="$dir"
    git -C "$REPO_DIR" rev-list "origin/$GIT_BRANCH..HEAD" > "$dir/commits" || die "Cannot enumerate outgoing history."
    while IFS= read -r commit; do
        git -C "$REPO_DIR" ls-tree -rz --name-only "$commit" > "$dir/paths" || die "Cannot read outgoing tree."
        while IFS= read -r -d '' path; do
            case "$path" in home/* | machines/*) scan_blob "$commit:$path" "$path" "$dir/blob" ;; esac
        done < "$dir/paths"
    done < "$dir/commits"
    rm -f "$dir/commits" "$dir/paths" "$dir/blob"
    rmdir "$dir"
    SCAN_TEMP_DIR=""
    ok "Outgoing history secret scan passed"
}

sync_nas_if_needed() {
    local receipt="$SYNC_STATE/nas-receipt" expected actual=""
    expected="$(git -C "$REPO_DIR" rev-parse HEAD)
$NAS_SSH_HOST
$NAS_SSH_DIR
$NAS_RSYNC_PATH
$NAS_ROOT
$NAS_REPO_DIR"
    [[ ! -f "$receipt" ]] || actual="$(< "$receipt")"
    if [[ "$actual" == "$expected" ]]; then
        log "NAS mirror already recorded for this commit and destination"
        return 0
    fi
    mirror_repository_to_nas
    if [[ "$NAS_MIRROR_COMPLETE" == 1 ]]; then
        mkdir -p "$SYNC_STATE"
        printf '%s\n' "$expected" > "$receipt.tmp"
        mv "$receipt.tmp" "$receipt"
    else
        warn "NAS mirror is pending and will be retried on the next sync."
    fi
}

sync_files() {
    "$BASH" "$SCRIPT_DIR/lib/sync-engine.sh" "$1" "$HOME" "$REPO_DIR" "$MACHINE" "$AUTO_ADD" "${2:-}" \
        --shared-files "${MANAGED_FILES[@]}" --shared-dirs "${MANAGED_DIRECTORIES[@]}" \
        --machine-files "${MACHINE_FILES[@]}" --machine-dirs "${MACHINE_DIRECTORIES[@]}" \
        --explicit-dirs "${EXPLICIT_DIRECTORIES[@]}" --excludes "${EXCLUDE_PATTERNS[@]}"
}

setup_sync_state() {
    SYNC_STATE="$REPO_DIR/.git/macos-config-sync-v31-$MACHINE"
    [[ ! -L "$REPO_DIR/.git" && ! -L "$SYNC_STATE" ]] || die "Symlink sync state is not supported."
}

deployed_ref() { printf 'refs/macos-config-sync/%s/deployed\n' "$MACHINE"; }

record_deployed_baseline() {
    run git -C "$REPO_DIR" update-ref "$(deployed_ref)" HEAD
}

adopt_baseline() {
    validate_dependencies
    validate_configuration
    require_repository
    setup_sync_state
    [[ ! -f "$SYNC_STATE/pending.json" ]] || die "A sync is pending. Finish it before adoption."
    [[ ! -f "$REPO_DIR/.git/macos-config-sync-pending-base" ]] || die "Finish or explicitly abandon the v3.0 pending operation first."
    repository_is_clean || die "Inspect and commit or preserve repository changes before adoption."
    repository_has_commits || die "Empty repository: initialise its first commit before adoption."
    [[ "$(git -C "$REPO_DIR" symbolic-ref --short HEAD)" == "$GIT_BRANCH" ]] || die "Wrong branch."
    record_deployed_baseline
    log "Adopted the current checkout as the last deployed baseline for $MACHINE."
    log "No HOME files were changed. Subsequent sync will compare local edits against this baseline."
}

fetch_sync_remote() {
    local refs
    refs="$(git -C "$REPO_DIR" ls-remote --heads origin "refs/heads/$GIT_BRANCH")" || die "Unable to inspect remote branch."
    [[ -n "$refs" ]] || die "Remote branch is missing. Initialise it explicitly before sync."
    git -C "$REPO_DIR" fetch origin "refs/heads/$GIT_BRANCH:refs/remotes/origin/$GIT_BRANCH" || die "Fetch failed."
}

cancel_sync() {
    validate_dependencies
    validate_configuration
    require_repository
    setup_sync_state
    [[ -f "$SYNC_STATE/pending.json" ]] || die "No current transaction to cancel."
    local base stamp rescue
    base="$(sync_files base)" || die "Cannot read transaction baseline."
    stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    rescue="refs/macos-config-sync/$MACHINE/cancelled-$stamp"
    git -C "$REPO_DIR" update-ref "$rescue" HEAD || die "Cannot preserve pending commit."
    if [[ -d "$REPO_DIR/.git/rebase-merge" || -d "$REPO_DIR/.git/rebase-apply" ]]; then
        [[ -z "$(git -C "$REPO_DIR" diff --name-only --diff-filter=U)" ]] || die "Unresolved rebase: preserve your conflict edits and abort or finish it manually before cancel."
        die "Finish or abort the active rebase manually before cancel."
    fi
    git -C "$REPO_DIR" stash push --include-untracked -m "macos-config-sync cancelled $stamp" || die "Cannot preserve uncommitted proposal."
    git -C "$REPO_DIR" reset --hard "$base" || die "Cannot restore checkout baseline."
    mv "$SYNC_STATE/pending.json" "$SYNC_STATE/cancelled-$stamp.json"
    warn "Cancelled checkout changes are recoverable in $rescue and Git stash (if changes existed)."
    log "HOME was not changed. Run sync to capture its current state again."
}

repository_path_to_home_path() {
    local repo_path="$1"
    local home_relative=""

    ensure_machine_name

    case "$repo_path" in
        home/*)
            home_relative="${repo_path#home/}"
            is_managed_repository_path "$home_relative" || return 1
            ;;
        machines/"$MACHINE"/home/*)
            home_relative="${repo_path#machines/"$MACHINE"/home/}"
            is_machine_repository_path "$home_relative" || return 1
            ;;
        *)
            return 1
            ;;
    esac

    printf '%s\n' "$home_relative"
}

list_managed_deletions() {
    local comparison="$1"
    shift

    local repo_path
    local home_relative
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/macos-deletions.XXXXXX")"

    if [[ "$comparison" == "cached" ]]; then
        git -C "$REPO_DIR" diff --cached --no-renames --diff-filter=D --name-only -z -- > "$dir/paths" || die "Cannot enumerate local deletions."
    else
        git -C "$REPO_DIR" diff --no-renames --diff-filter=D --name-only -z "$@" -- > "$dir/paths" || die "Cannot enumerate reconciled deletions."
    fi
    while IFS= read -r -d '' repo_path; do
        home_relative="$(repository_path_to_home_path "$repo_path")" || continue
        printf '%s\n' "$home_relative"
    done < "$dir/paths"
    rm -f "$dir/paths"
    rmdir "$dir"
}

confirm_deletions() {
    local deletion_file="$1"
    local description="$2"
    local sorted_file="${deletion_file}.sorted"
    local answer=""
    local count

    LC_ALL=C sort -u "$deletion_file" > "$sorted_file"
    mv "$sorted_file" "$deletion_file"

    [[ -s "$deletion_file" ]] || return 0

    count="$(wc -l < "$deletion_file" | tr -d ' ')"
    printf '\n%s%s (%s):%s\n' "$C_YELLOW" "$description" "$count" "$C_RESET" >&2
    while IFS= read -r home_relative; do
        printf '  - ~/%s\n' "$home_relative" >&2
    done < "$deletion_file"
    printf '\n' >&2

    if [[ "$ACCEPT_DELETIONS" == "1" ]]; then
        warn "ACCEPT_DELETIONS=1 set — allowing the displayed deletions"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        warn "DRY-RUN: Deletions would require confirmation"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        warn "Deletion confirmation requires a terminal. Re-run with ACCEPT_DELETIONS=1 after reviewing the list."
        return 1
    fi

    printf 'Continue with these deletions? [y/N] ' >&2
    IFS= read -r answer

    case "$answer" in
        y | Y | yes | YES | Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

commit_local_snapshot() {
    if [[ "$DRY_RUN" == "1" ]]; then
        git -C "$REPO_DIR" status --short
        return 0
    fi

    if git -C "$REPO_DIR" diff --cached --quiet; then
        log "No local configuration changes to commit"
        return 0
    fi

    local computer_name
    local timestamp

    computer_name="$(scutil --get ComputerName 2> /dev/null || hostname)"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"

    git -C "$REPO_DIR" commit \
        -m "Update configuration from ${computer_name} at ${timestamp}"

    ok "Local configuration snapshot committed"
}

apply_local_permissions() {
    local path
    for path in "${MANAGED_FILES[@]}" "${MACHINE_FILES[@]}"; do
        case $path in
            .ssh/* | .gnupg/*)
                if [[ -f $HOME/$path ]]; then
                    reject_symlinks "$HOME/$path" || exit 1
                    run chmod 600 "$HOME/$path"
                fi
                ;;
        esac
    done
    if [[ -d $HOME/.ssh ]]; then
        reject_symlinks "$HOME/.ssh/sockets" || exit 1
        run chmod 700 "$HOME/.ssh"
        run mkdir -p "$HOME/.ssh/sockets"
        run chmod 700 "$HOME/.ssh/sockets"
    fi
    if [[ -d $HOME/.gnupg ]]; then run chmod 700 "$HOME/.gnupg"; fi
}

show_rebase_conflicts() {
    local repo_path
    local home_relative

    printf '\n%sConflicts require manual resolution:%s\n' "$C_RED" "$C_RESET" >&2
    while IFS= read -r repo_path; do
        [[ -n "$repo_path" ]] || continue
        if home_relative="$(repository_path_to_home_path "$repo_path")"; then
            printf '  ~/%s\n' "$home_relative" >&2
        else
            printf '  %s\n' "$repo_path" >&2
        fi
    done < <(git -C "$REPO_DIR" diff --name-only --diff-filter=U)

    cat >&2 << EOF

HOME has not been changed.

Resolve the files in:
  $REPO_DIR

Then run:
  git -C "$REPO_DIR" add <resolved-files>
  git -C "$REPO_DIR" rebase --continue
  $SCRIPT_NAME sync

To abandon the reconciliation:
  git -C "$REPO_DIR" rebase --abort
  $SCRIPT_NAME cancel

Do not edit managed HOME files while resolving the repository conflict.
If you already have, sync will stop and preserve those edits.
EOF
}

finish_reconciled_sync() {
    local base_commit="$1"
    local temp_dir="$2"
    local final_deletions="$temp_dir/final-deletions"
    local pending_deletions="$temp_dir/pending-deletions"
    local accepted_deletions="$SYNC_STATE/accepted-deletions"
    local final_commit=""

    sync_files check || die "HOME verification failed. Transaction retained."
    sync_files plan || die "Deployment preflight failed. Nothing pushed."
    scan_outgoing_commits

    if [[ "$DRY_RUN" != "1" && -n "$base_commit" ]]; then
        final_commit="$(git -C "$REPO_DIR" rev-parse HEAD)"

        if [[ "$final_commit" == "$base_commit" && "$(sync_files needs-deploy)" == no ]] && ! has_unpushed_commits; then
            sync_files clear
            ok "No configuration changes detected"
            log "Skipping local backup, deployment and Moom import"
            sync_nas_if_needed
            return 0
        fi
    fi

    : > "$final_deletions"
    [[ -n "$base_commit" ]] &&
        list_managed_deletions range "$base_commit" HEAD > "$final_deletions"

    LC_ALL=C sort -u "$final_deletions" -o "$final_deletions"
    if [[ -s "$accepted_deletions" ]]; then
        LC_ALL=C sort -u "$accepted_deletions" -o "$accepted_deletions"
        comm -23 "$final_deletions" "$accepted_deletions" > "$pending_deletions"
    else
        cp "$final_deletions" "$pending_deletions"
    fi

    if ! confirm_deletions "$pending_deletions" "Additional deletions in the reconciled result"; then
        die "Sync stopped. No reconciled files were applied to HOME or pushed."
    fi

    sync_files check || die "HOME changed before push. Transaction retained."
    git -C "$REPO_DIR" push -u origin "HEAD:refs/heads/$GIT_BRANCH" || die "Push failed. Deployment has not started."
    sync_files check || die "HOME changed during push. Deployment stopped."
    create_local_backup
    sync_files check || die "HOME changed during backup. Deployment stopped."
    sync_files deploy || die "Deployment stopped. Snapshot and backup retained for recovery."
    apply_local_permissions
    restore_moom_preferences
    sync_files check || die "HOME changed before completion. Transaction retained."
    record_deployed_baseline
    sync_files clear
    prune_local_backups
    sync_nas_if_needed

    ok "Synchronisation complete"
}

resume_reconciled_sync() {
    local base_commit
    local temp_dir="$1"
    local phase
    [[ ! -d "$REPO_DIR/.git/rebase-merge" && ! -d "$REPO_DIR/.git/rebase-apply" ]] || die "Rebase is still active. Resolve it and run git rebase --continue first."
    [[ "$(git -C "$REPO_DIR" symbolic-ref --short HEAD)" == "$GIT_BRANCH" ]] || die "Cannot resume from another branch."
    sync_files check || die "HOME no longer matches the captured transaction. No deployment performed."
    if ! repository_is_clean; then
        die "Pending proposal has uncommitted changes. Inspect/resolve and commit it, or use '$SCRIPT_NAME cancel' to preserve it and start again."
    fi

    base_commit="$(sync_files base)" || die "Cannot read pending baseline."
    git -C "$REPO_DIR" cat-file -e "${base_commit}^{commit}" 2> /dev/null ||
        die "Pending sync base commit is unavailable: $base_commit"

    step "Resuming the previously reconciled sync"

    phase="$(sync_files phase)" || die "Cannot read pending phase."
    fetch_sync_remote
    if [[ "$phase" == "captured" ]]; then
        if ! git -C "$REPO_DIR" merge-base --is-ancestor "origin/$GIT_BRANCH" HEAD; then
            if ! git -C "$REPO_DIR" rebase "origin/$GIT_BRANCH"; then
                show_rebase_conflicts
                exit 1
            fi
        fi
    fi

    finish_reconciled_sync "$base_commit" "$temp_dir"
    return 0
}

sync_configuration() {
    validate_dependencies
    validate_configuration
    require_repository
    show_tool_versions
    configure_repository_for_sync

    local temp_dir
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/macos-config-sync.XXXXXX")"

    setup_sync_state
    [[ ! -f "$REPO_DIR/.git/macos-config-sync-pending-base" ]] || die "Legacy recovery state found. Preserve both HOME and repository and finish that operation before upgrading."
    if [[ -f "$SYNC_STATE/pending.json" ]]; then
        resume_reconciled_sync "$temp_dir"
        rm -rf "$temp_dir"
        return 0
    fi

    repository_is_clean ||
        die "The local repository contains uncommitted changes. Inspect $REPO_DIR before syncing."

    local base_commit
    base_commit="$(git -C "$REPO_DIR" rev-parse --verify "$(deployed_ref)")" || die "No deployed baseline. For an existing installation inspect the checkout then run '$SCRIPT_NAME adopt'. For a new Mac use an explicit restore."
    [[ "$(git -C "$REPO_DIR" symbolic-ref --short HEAD)" == "$GIT_BRANCH" ]] || die "Wrong branch or detached HEAD."
    [[ "$(git -C "$REPO_DIR" rev-parse HEAD)" == "$base_commit" ]] || die "Checkout differs from the last deployed baseline. Preserve and inspect those changes. Do not adopt them unless they really were applied to HOME."

    step "Capturing local configuration before contacting GitHub"
    sync_files snapshot "$base_commit"
    mkdir -p "$SYNC_STATE/generated"
    rm -f "$SYNC_STATE/generated/Brewfile" "$SYNC_STATE/generated/installed-apps.txt" "$SYNC_STATE/generated/Moom.plist"
    GENERATED_ROOT="$SYNC_STATE/generated"
    generate_brewfile
    generate_installed_apps_list
    export_moom_preferences
    GENERATED_ROOT=""
    sync_files collect
    create_repository_files
    scan_for_secrets

    local local_deletions="$temp_dir/local-deletions"
    list_managed_deletions cached > "$local_deletions"
    if ! confirm_deletions "$local_deletions" "Local deletions to propagate"; then
        die "Deletion not accepted. HOME is unchanged. The staged proposal and snapshot are retained for inspection."
    fi
    cp "$local_deletions" "$SYNC_STATE/accepted-deletions"

    commit_local_snapshot
    sync_files local
    if [[ "$DRY_RUN" != "1" ]]; then
        step "Fetching current remote branch"
        fetch_sync_remote

        if [[ "$DRY_RUN" != "1" ]]; then
            step "Reconciling local and remote commits"
            if ! git -C "$REPO_DIR" rebase "origin/$GIT_BRANCH"; then
                rm -rf "$temp_dir"
                show_rebase_conflicts
                exit 1
            fi
        fi
    fi

    finish_reconciled_sync "$base_commit" "$temp_dir"
    rm -rf "$temp_dir"
}

push_configuration() {
    warn "The push command is now an alias for sync. Use '$SCRIPT_NAME sync' for normal operation."
    sync_configuration
}

create_local_backup() {
    local backup_dir
    local path

    backup_dir="$BACKUP_ROOT/$(date '+%Y%m%d_%H%M%S')_$$"

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
    local path name remove i
    local -a backups=()
    ((BACKUP_RETENTION > 0)) || return 0
    shopt -s nullglob
    for path in "$BACKUP_ROOT"/*; do
        name=${path##*/}
        [[ $name =~ ^[0-9]{8}_[0-9]{6}_[0-9]+$ && -d $path && ! -L $path ]] || continue
        backups+=("$path")
    done
    remove=$((${#backups[@]} - BACKUP_RETENTION))
    for ((i = 0; i < remove; i++)); do run rm -rf -- "${backups[i]}"; done
}

restore_local_files() {
    local path

    require_repository

    [[ -d "$REPO_DIR/home" ]] ||
        die "Repository does not contain the expected home directory."

    for path in "${MANAGED_DIRECTORIES[@]}"; do
        reject_symlink_components "$HOME" "$path" "$HOME/$path"
    done

    for path in "${MANAGED_FILES[@]}"; do
        reject_symlink_components "$HOME" "$path" "$HOME/$path"
    done

    for path in "${MACHINE_DIRECTORIES[@]+"${MACHINE_DIRECTORIES[@]}"}"; do
        reject_symlink_components "$HOME" "$path" "$HOME/$path"
    done

    for path in "${MACHINE_FILES[@]}"; do
        reject_symlink_components "$HOME" "$path" "$HOME/$path"
    done

    create_local_backup

    for path in "${MANAGED_DIRECTORIES[@]}"; do
        reject_symlink_components "$REPO_DIR" "home/$path" "repo:home/$path"
        reject_symlinks_in_directory "$(repository_path "$path")" "repo:home/$path"
        log "Restoring ~/$path"

        sync_directory \
            "$(repository_path "$path")" \
            "$(local_path "$path")" \
            "${DIRECTORY_EXCLUDES[@]}" \
            --exclude='.git/'
    done

    for path in "${MANAGED_FILES[@]}"; do
        reject_symlink_components "$REPO_DIR" "home/$path" "repo:home/$path"
        log "Restoring ~/$path"

        sync_file \
            "$(repository_path "$path")" \
            "$(local_path "$path")"
    done

    ensure_machine_name

    if [[ -d "$(machine_repository_root)/home" ]]; then
        for path in "${MACHINE_DIRECTORIES[@]+"${MACHINE_DIRECTORIES[@]}"}"; do
            if [[ -d "$(machine_repository_path "$path")" ]]; then
                reject_symlink_components "$REPO_DIR" "machines/$MACHINE/home/$path" "repo:machines/$MACHINE/home/$path"
                reject_symlinks_in_directory "$(machine_repository_path "$path")" "repo:machines/$MACHINE/home/$path"
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
                reject_symlink_components "$REPO_DIR" "machines/$MACHINE/home/$path" "repo:machines/$MACHINE/home/$path"
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

    apply_local_permissions
    restore_moom_preferences

    prune_local_backups

    ok "Configuration restored"
    log "Open a new terminal session or run: exec zsh"
}

pull_configuration() {
    validate_dependencies
    validate_configuration
    require_repository
    show_tool_versions
    setup_sync_state
    [[ ! -f "$SYNC_STATE/pending.json" ]] || die "Finish or cancel the pending sync before a destructive pull."

    repository_is_clean ||
        die "The local repository contains uncommitted changes. Run push or inspect the repository first."

    remote_branch_exists ||
        die "Remote branch does not exist: $GIT_BRANCH"

    step "Fetching the latest configuration from GitHub"

    run git -C "$REPO_DIR" fetch origin "$GIT_BRANCH"
    run git -C "$REPO_DIR" checkout "$GIT_BRANCH"
    run git -C "$REPO_DIR" pull --ff-only origin "$GIT_BRANCH"

    restore_local_files
    record_deployed_baseline
    run rm -f "$REPO_DIR/.git/macos-config-sync-pending-base"
    run rm -f "$REPO_DIR/.git/macos-config-sync-accepted-local-deletions"
    sync_nas_if_needed
}

restore_configuration() {
    validate_dependencies
    validate_configuration
    require_repository
    show_tool_versions
    setup_sync_state
    [[ ! -f "$SYNC_STATE/pending.json" ]] || die "Finish or cancel the pending sync before restore."
    repository_is_clean || die "Restore requires a clean committed checkout."
    [[ "$(git -C "$REPO_DIR" symbolic-ref --short HEAD)" == "$GIT_BRANCH" ]] || die "Wrong restore branch."

    step "Restoring configuration from local repository (no remote contact)"
    restore_local_files
    record_deployed_baseline
    run rm -f "$REPO_DIR/.git/macos-config-sync-pending-base"
    run rm -f "$REPO_DIR/.git/macos-config-sync-accepted-local-deletions"
}

mirror_repository_to_nas() {
    repository_is_clean || die "NAS mirroring requires a clean committed checkout."
    require_repository
    NAS_MIRROR_COMPLETE=0

    local -a nas_mirror_options=(
        --checksum
        --delete
        --delete-excluded
        --exclude='.git/'
        --exclude='.DS_Store'
    )

    local nas_transport=""
    if nas_ssh_available; then
        nas_transport=ssh
    elif nas_smb_available; then
        nas_transport=smb
    fi

    if [[ "$nas_transport" == "ssh" ]]; then
        step "Mirroring repository files to NAS via SSH: $NAS_SSH_HOST:$NAS_SSH_DIR"

        run rsync \
            -e "$NAS_SSH_CMD" \
            --rsync-path="mkdir -p $NAS_SSH_DIR && $NAS_RSYNC_PATH" \
            "${COMMON_RSYNC_OPTIONS[@]}" \
            "${nas_mirror_options[@]}" \
            "$REPO_DIR/" \
            "$NAS_SSH_HOST:$NAS_SSH_DIR/"

        ok "NAS mirror updated (SSH)"
        NAS_MIRROR_COMPLETE=1
    elif [[ "$nas_transport" == "smb" ]]; then
        step "Mirroring repository files to NAS via SMB: $NAS_REPO_DIR"

        run mkdir -p "$NAS_REPO_DIR"

        run rsync \
            "${COMMON_RSYNC_OPTIONS[@]}" \
            --no-perms \
            "${nas_mirror_options[@]}" \
            "$REPO_DIR/" \
            "$NAS_REPO_DIR/"

        ok "NAS mirror updated (SMB)"
        NAS_MIRROR_COMPLETE=1
    else
        warn "NAS is unreachable (SSH host: $NAS_SSH_HOST, SMB mount: $NAS_ROOT)"
        warn "The GitHub operation completed, but the NAS mirror was not updated."
        return 1
    fi
}

restore_repository_from_nas() {
    validate_dependencies
    validate_configuration
    local marker="$REPO_DIR/.git/macos-nas-offline" stage parent
    if [[ -e $REPO_DIR ]]; then
        [[ -f $marker && -d $REPO_DIR/.git ]] || die 'Destination exists and is not an offline NAS recovery checkout.'
        repository_is_clean || die 'Commit or preserve recovery-checkout edits before reconnecting.'
    else
        parent=${REPO_DIR%/*}
        run mkdir -p "$parent"
        stage=$(mktemp -d "$parent/.nas-recovery.XXXXXXXX")
        if nas_ssh_available; then
            if ! rsync -e "$NAS_SSH_CMD" --rsync-path="$NAS_RSYNC_PATH" "${COMMON_RSYNC_OPTIONS[@]}" --exclude='.git/' "$NAS_SSH_HOST:$NAS_SSH_DIR/" "$stage/"; then
                rm -rf -- "$stage"
                die 'NAS transfer failed. No final checkout published.'
            fi
        elif nas_smb_available; then
            if ! rsync "${COMMON_RSYNC_OPTIONS[@]}" --no-perms --exclude='.git/' "$NAS_REPO_DIR/" "$stage/"; then
                rm -rf -- "$stage"
                die 'NAS transfer failed. No final checkout published.'
            fi
        else
            rm -rf -- "$stage"
            die 'NAS is unavailable.'
        fi
        [[ -d $stage/home ]] || {
            rm -rf -- "$stage"
            die 'NAS mirror has no home directory.'
        }
        git -C "$stage" init -b "$GIT_BRANCH"
        git -C "$stage" add --all
        git -C "$stage" -c user.name='NAS recovery' -c user.email='nas-recovery@localhost' -c commit.gpgsign=false commit -m 'Preserve NAS recovery snapshot'
        git -C "$stage" remote add origin "$GITHUB_REPO"
        git -C "$stage" update-ref refs/macos-config-sync/nas-recovery HEAD
        touch "$stage/.git/macos-nas-offline"
        move_no_replace "$stage" "$REPO_DIR" || die "Cannot publish recovery checkout. Staging retained: $stage"
    fi
    if git -C "$REPO_DIR" fetch origin "$GIT_BRANCH"; then
        git -C "$REPO_DIR" reset --mixed "origin/$GIT_BRANCH"
        git -C "$REPO_DIR" branch --set-upstream-to "origin/$GIT_BRANCH"
        git -C "$REPO_DIR" update-ref -d "$(deployed_ref)"
        rm -- "$marker"
        ok 'Git history reconnected. NAS files remain in the working tree.'
        log 'Inspect git diff before choosing which version to restore. The NAS snapshot is retained at refs/macos-config-sync/nas-recovery.'
        log 'If the checkout is clean, run restore. If it differs, preserve/commit your intended files before restore. Do not adopt a baseline that was not deployed.'
    else
        warn 'GitHub unavailable. The committed NAS snapshot can be deployed with restore.'
        log 'Repeat nas-pull to reconnect this checkout once GitHub is available.'
    fi
}

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
    printf '%sConfiguration:%s     %s\n' "$C_BLUE" "$C_RESET" "$CONFIG_FILE"
    printf '%sAutomatic enrolment:%s %s (0=manual, 1=recursive)\n' "$C_BLUE" "$C_RESET" "$AUTO_ADD"
    if ((${#EXPLICIT_DIRECTORIES[@]} > 0)); then
        printf 'Manual-only directory: %s\n' "${EXPLICIT_DIRECTORIES[@]}"
    fi
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

        if ssh -n "${NAS_SSH_OPTS[@]}" "$NAS_SSH_HOST" "test -d $NAS_SSH_DIR/home" 2> /dev/null; then
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

# Operations
main() {
    local command=${1:-help} requires_lock=0 argument
    if (($#)); then shift; fi
    ASSUME_YES=0
    local -a operands=()
    for argument in "$@"; do
        case $argument in
            --yes | -y)
                ASSUME_YES=1
                ACCEPT_DELETIONS=1
                ;;
            --dry-run) DRY_RUN=1 ;;
            *) operands+=("$argument") ;;
        esac
    done
    case $command in
        version | --version | -V)
            printf '%s\n' "$SCRIPT_VERSION"
            return
            ;;
        help | --help | -h)
            usage
            return
            ;;
        init | sync | push | pull | restore | status | nas-push | nas-pull | adopt | add | forget | cancel) ;;
        *) die "Unknown command: $command" ;;
    esac
    if [[ $command == add || $command == forget ]]; then
        ((${#operands[@]} == 1)) || die "Usage: ${0##*/} $command HOME-relative-file"
    else ((${#operands[@]} == 0)) || die 'Unexpected argument.'; fi
    set -- "$command" "${operands[@]}"
    load_effective_configuration
    if [[ $command == pull || $command == restore ]]; then
        if [[ $DRY_RUN != 1 ]]; then confirm "Replace managed HOME files using $command?" || return 0; fi
    fi

    if [[ "$DRY_RUN" == 1 ]]; then
        case "$command" in
            help | --help | -h | version | --version | -V | status) ;;
            *)
                validate_dependencies
                validate_configuration
                log "DRY-RUN: $command would inspect local files and the remote, then propose changes."
                log "No generation, fetch, staging, pruning, backup, deployment or state writes performed."
                log "This is not a computed remote diff. Run normally for the actual reconciliation and deletion prompts."
                return 0
                ;;
        esac
    fi

    case "$command" in
        init | sync | push | pull | restore | nas-push | nas-pull | adopt | add | forget | cancel)
            requires_lock=1
            ;;
    esac

    if ((requires_lock == 1)); then
        acquire_lock
        trap release_lock EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
    fi

    case "$command" in
        adopt)
            adopt_baseline
            ;;
        add | forget)
            validate_dependencies
            validate_configuration
            require_repository
            setup_sync_state
            [[ $# == 2 ]] || die "Usage: $SCRIPT_NAME $command HOME-relative-file"
            sync_files "$command" "$2"
            ;;
        cancel)
            cancel_sync
            ;;
        init)
            initialise_repository
            ;;
        sync)
            sync_configuration
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

# Entry point
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
