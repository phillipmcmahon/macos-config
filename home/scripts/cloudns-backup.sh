#!/usr/bin/env bash
#
# cloudns-backup.sh
#
# Version: 1.3.0
#
# v1.3.0:
#   - Added colourised terminal output matching the style used by the existing
#     macOS management scripts.
#   - Success messages are green.
#   - Warnings are yellow.
#   - Errors are red.
#   - Section and operation headings are blue.
#   - Colours are disabled automatically when stdout is not a terminal.
#   - Improved --help layout with clearly separated sections for backup,
#     restore, NAS replication, authentication, environment overrides and
#     examples.
#   - Added script version and default configuration summary to help output.
#
# v1.2.0:
#   - Added automatic NAS replication after each successful local backup.
#   - NAS replication prefers rsync over SSH to host "homestorage".
#   - SSH uses key-only authentication with BatchMode=yes and a 3-second
#     connection timeout.
#   - Falls back automatically to the mounted home share over SMB when SSH
#     is unavailable.
#   - Default NAS location:
#
#         ~/backups/dns/cloudns/phillipmcmahon.com
#
#     which maps to:
#
#         /Volumes/home/backups/dns/cloudns/phillipmcmahon.com
#
#     when using the SMB fallback.
#   - Uses /opt/bin/rsync on the Synology for SSH transfers.
#   - NAS replication mirrors the retained local backup set, including
#     deletion of backups removed locally by retention.
#   - Uses rsync --checksum to verify content during NAS synchronisation.
#   - NAS failure does not invalidate a successful local backup.
#   - Added --no-nas to skip NAS replication for an individual run.
#
# v1.1.0:
#   - Added automatic backup retention.
#   - Keeps the 30 most recent timestamped backups by default.
#   - Added --retention-count N to override the default retention count.
#   - A retention count of 0 disables automatic pruning.
#   - Retention runs only after a successful backup.
#   - Only timestamped backups matching this script's naming convention are
#     considered for removal.
#   - Associated .sha256 files are removed with expired backups.
#
# v1.0.1:
#   - Fixed handling of the ClouDNS records-export API response.
#   - ClouDNS returns the BIND zone inside the "zone" property of a successful
#     JSON response.
#   - The script now extracts and validates the "zone" value before creating
#     the backup.
#   - Improved validation of successful and failed API responses.
#
# v1.0.0:
#   - Initial release.
#   - Backs up the complete phillipmcmahon.com DNS zone from ClouDNS.
#   - Uses the ClouDNS BIND zone export API.
#   - Creates timestamped BIND-format backup files.
#   - Creates a SHA-256 checksum alongside each backup.
#   - Supports restoring a previously created backup.
#   - Restore is additive by default.
#   - --replace-existing performs an exact replacement of existing DNS records.
#   - --dry-run previews restore operations without modifying DNS.
#   - Credentials are loaded automatically from
#     ~/.config/cloudns/credentials.
#   - Existing CLOUDNS_AUTH_ID and CLOUDNS_AUTH_PASSWORD environment
#     variables take precedence over values in the credentials file.
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# Prefer Homebrew binaries over older macOS-supplied tools.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly SCRIPT_VERSION="1.3.0"
readonly SCRIPT_NAME="${0##*/}"

# ----
# Configuration
# ----

readonly API_BASE="https://api.cloudns.net"
readonly DOMAIN="phillipmcmahon.com"

readonly CREDENTIALS_FILE="${HOME}/.config/cloudns/credentials"
readonly DEFAULT_BACKUP_DIR="${HOME}/.config/cloudns/backups"
readonly DEFAULT_RETENTION_COUNT="30"

NAS_SSH_HOST="${NAS_SSH_HOST:-homestorage}"
NAS_SSH_DIR="${NAS_SSH_DIR:-backups/dns/cloudns/phillipmcmahon.com}"
NAS_RSYNC_PATH="${NAS_RSYNC_PATH:-/opt/bin/rsync}"

NAS_ROOT="${NAS_ROOT:-/Volumes/home}"
NAS_BACKUP_DIR="${NAS_BACKUP_DIR:-${NAS_ROOT}/backups/dns/cloudns/phillipmcmahon.com}"

MODE="backup"

BACKUP_DIR="$DEFAULT_BACKUP_DIR"
OUTPUT_FILE=""
RESTORE_FILE=""

RETENTION_COUNT="$DEFAULT_RETENTION_COUNT"

DRY_RUN=false
REPLACE_EXISTING=false
NAS_ENABLED=true

# ----
# NAS transport
# ----

NAS_SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=3
)

NAS_SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=3"

# ----
# Colours
# ----

if [[ -t 1 ]]; then
    C_GREEN=$'\033[0;32m'
    C_RED=$'\033[0;31m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_GREEN=""
    C_RED=""
    C_YELLOW=""
    C_BLUE=""
    C_BOLD=""
    C_RESET=""
fi

# ----
# Logging
# ----

log() {
    printf '%s[%s]%s %s\n' \
        "$C_GREEN" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$C_RESET" \
        "$*"
}

ok() {
    printf '%s[%s] ✔ %s%s\n' \
        "$C_GREEN" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" \
        "$C_RESET"
}

step() {
    printf '%s[%s] ▸ %s%s\n' \
        "$C_BLUE" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" \
        "$C_RESET"
}

warn() {
    printf '%s[%s] WARNING: %s%s\n' \
        "$C_YELLOW" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" \
        "$C_RESET" >&2
}

die() {
    printf '%s[%s] ERROR: %s%s\n' \
        "$C_RED" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" \
        "$C_RESET" >&2

    exit 1
}

# ----
# Error handling
# ----

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
# Usage
# ----

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} version ${SCRIPT_VERSION}

Back up and restore the complete ClouDNS DNS zone for:

    ${C_BOLD}${DOMAIN}${C_RESET}


${C_BLUE}${C_BOLD}USAGE${C_RESET}

    ${SCRIPT_NAME} [backup options]

    ${SCRIPT_NAME} --restore FILE [restore options]


${C_BLUE}${C_BOLD}BACKUP OPTIONS${C_RESET}

    --backup-dir DIRECTORY
        Store timestamped backups in DIRECTORY.

        Default:
            ${DEFAULT_BACKUP_DIR}

    --output FILE
        Write the backup to a specific file instead of creating a
        timestamped backup.

        Retention and NAS mirroring are not applied when --output is used.

    --retention-count N
        Keep the N most recent timestamped backups.

        Default:
            ${DEFAULT_RETENTION_COUNT}

        Use 0 to disable automatic retention.

    --no-nas
        Create and retain the local backup without copying it to the NAS.


${C_BLUE}${C_BOLD}RESTORE OPTIONS${C_RESET}

    --restore FILE
        Restore DNS records from a BIND-format backup.

    --replace-existing
        Remove the existing DNS records before importing the backup.

        Without this option the import is additive and existing DNS
        records are retained.

    --dry-run
        Validate the backup and show what would be restored without
        changing DNS.


${C_BLUE}${C_BOLD}GENERAL OPTIONS${C_RESET}

    -h, --help
        Display this help.

    --version
        Display the script version.


${C_BLUE}${C_BOLD}LOCAL BACKUPS${C_RESET}

    Default directory:
        ${DEFAULT_BACKUP_DIR}

    Filename format:
        ${DOMAIN}-YYYYMMDD-HHMMSS.bind

    Checksum:
        ${DOMAIN}-YYYYMMDD-HHMMSS.bind.sha256

    Default retention:
        ${DEFAULT_RETENTION_COUNT} backups


${C_BLUE}${C_BOLD}NAS REPLICATION${C_RESET}

    NAS replication runs after:

        1. A successful ClouDNS export
        2. Local backup validation
        3. SHA-256 checksum creation
        4. Local retention

    Preferred transport:
        rsync over SSH

    SSH host:
        ${NAS_SSH_HOST}

    SSH destination:
        ~/${NAS_SSH_DIR}

    Remote rsync:
        ${NAS_RSYNC_PATH}

    SMB fallback root:
        ${NAS_ROOT}

    SMB destination:
        ${NAS_BACKUP_DIR}

    SSH is attempted first. If SSH is unavailable or the SSH transfer
    fails, the script attempts the mounted SMB share.

    Failure to reach the NAS does not invalidate a successful local backup.


${C_BLUE}${C_BOLD}AUTHENTICATION${C_RESET}

    ClouDNS credentials are loaded from:

        ${CREDENTIALS_FILE}

    The credentials file may contain:

        CLOUDNS_AUTH_ID='YOUR_AUTH_ID'
        CLOUDNS_AUTH_PASSWORD='YOUR_API_PASSWORD'

    Existing environment variables take precedence over values loaded
    from the credentials file.


${C_BLUE}${C_BOLD}ENVIRONMENT OVERRIDES${C_RESET}

    NAS_SSH_HOST
        NAS hostname used for SSH.

        Default:
            homestorage

    NAS_SSH_DIR
        Backup directory relative to the remote user's home directory.

        Default:
            backups/dns/cloudns/phillipmcmahon.com

    NAS_RSYNC_PATH
        Path to rsync on the NAS.

        Default:
            /opt/bin/rsync

    NAS_ROOT
        Mounted SMB home share.

        Default:
            /Volumes/home

    NAS_BACKUP_DIR
        Backup destination when SMB is used.

        Default:
            /Volumes/home/backups/dns/cloudns/phillipmcmahon.com


${C_BLUE}${C_BOLD}EXAMPLES${C_RESET}

    Create a normal backup:

        ${SCRIPT_NAME}

    Keep the 60 most recent backups:

        ${SCRIPT_NAME} --retention-count 60

    Disable automatic retention:

        ${SCRIPT_NAME} --retention-count 0

    Create a local backup without NAS replication:

        ${SCRIPT_NAME} --no-nas

    Use an alternative local backup directory:

        ${SCRIPT_NAME} \\
            --backup-dir /path/to/backups

    Write a one-off backup to a specific file:

        ${SCRIPT_NAME} \\
            --output ~/dns-backup.bind

    Validate a restore without changing DNS:

        ${SCRIPT_NAME} \\
            --restore /path/to/backup.bind \\
            --dry-run

    Import a backup while retaining existing records:

        ${SCRIPT_NAME} \\
            --restore /path/to/backup.bind

    Preview a complete replacement:

        ${SCRIPT_NAME} \\
            --restore /path/to/backup.bind \\
            --replace-existing \\
            --dry-run

    Replace the existing zone records from a backup:

        ${SCRIPT_NAME} \\
            --restore /path/to/backup.bind \\
            --replace-existing
EOF
}

# ----
# Credentials
# ----

load_credentials() {
    local existing_auth_id="${CLOUDNS_AUTH_ID:-}"
    local existing_auth_password="${CLOUDNS_AUTH_PASSWORD:-}"

    if [[ -f "$CREDENTIALS_FILE" ]]; then
        log "Loading credentials from: $CREDENTIALS_FILE"

        # shellcheck disable=SC1090
        source "$CREDENTIALS_FILE"

        if [[ -n "$existing_auth_id" ]]; then
            CLOUDNS_AUTH_ID="$existing_auth_id"
        fi

        if [[ -n "$existing_auth_password" ]]; then
            CLOUDNS_AUTH_PASSWORD="$existing_auth_password"
        fi
    else
        warn "Credentials file not found. Using environment variables."
    fi

    [[ -n "${CLOUDNS_AUTH_ID:-}" ]] ||
        die "CLOUDNS_AUTH_ID is not configured."

    [[ -n "${CLOUDNS_AUTH_PASSWORD:-}" ]] ||
        die "CLOUDNS_AUTH_PASSWORD is not configured."

    export CLOUDNS_AUTH_ID
    export CLOUDNS_AUTH_PASSWORD
}

# ----
# ClouDNS API
# ----

api_request() {
    local endpoint="$1"
    shift

    curl \
        --fail \
        --silent \
        --show-error \
        --request POST \
        --data-urlencode "auth-id=${CLOUDNS_AUTH_ID}" \
        --data-urlencode "auth-password=${CLOUDNS_AUTH_PASSWORD}" \
        "$@" \
        "${API_BASE}${endpoint}"
}

check_api_response() {
    local response="$1"

    if ! jq -e . <<<"$response" >/dev/null 2>&1; then
        return
    fi

    if jq -e '
        type == "object"
        and .status? == "Failed"
    ' <<<"$response" >/dev/null 2>&1; then

        printf '%s[%s] ERROR: ClouDNS API request failed:%s\n' \
            "$C_RED" \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$C_RESET" >&2

        jq . <<<"$response" >&2
        exit 1
    fi
}

extract_zone() {
    local response="$1"
    local status
    local zone

    if ! jq -e . <<<"$response" >/dev/null 2>&1; then
        die "ClouDNS returned an invalid JSON response."
    fi

    if [[ "$(jq -r 'type' <<<"$response")" != "object" ]]; then
        die "Unexpected response type returned by the ClouDNS export API."
    fi

    status="$(jq -r '.status // empty' <<<"$response")"

    if [[ "$status" == "Failed" ]]; then
        printf '%s[%s] ERROR: ClouDNS API request failed:%s\n' \
            "$C_RED" \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$C_RESET" >&2

        jq . <<<"$response" >&2
        exit 1
    fi

    if [[ "$status" != "Success" ]]; then
        printf '%s[%s] ERROR: Unexpected ClouDNS API response:%s\n' \
            "$C_RED" \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$C_RESET" >&2

        jq . <<<"$response" >&2
        exit 1
    fi

    if ! jq -e '
        .zone?
        and (.zone | type == "string")
        and (.zone | length > 0)
    ' <<<"$response" >/dev/null 2>&1; then

        printf '%s[%s] ERROR: Successful response did not contain a valid zone:%s\n' \
            "$C_RED" \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$C_RESET" >&2

        jq . <<<"$response" >&2
        exit 1
    fi

    zone="$(jq -r '.zone' <<<"$response")"

    [[ -n "$zone" ]] ||
        die "ClouDNS returned an empty zone export."

    printf '%s\n' "$zone"
}

# ----
# Checksums
# ----

create_checksum() {
    local file="$1"
    local checksum_file="${file}.sha256"
    local filename

    filename="$(basename "$file")"

    (
        cd "$(dirname "$file")"
        shasum -a 256 "$filename"
    ) >"$checksum_file"

    chmod 600 "$checksum_file"
}

verify_checksum_if_present() {
    local file="$1"
    local checksum_file="${file}.sha256"
    local filename

    if [[ ! -f "$checksum_file" ]]; then
        warn "Checksum file not found. Skipping checksum verification."
        return
    fi

    filename="$(basename "$file")"

    step "Verifying backup checksum"

    if (
        cd "$(dirname "$file")"
        shasum -a 256 -c "$(basename "$checksum_file")"
    ); then
        ok "Checksum verified: $filename"
    else
        die "Backup checksum verification failed: $file"
    fi
}

# ----
# Configuration validation
# ----

validate_nas_configuration() {
    if [[ -z "$NAS_SSH_HOST" ]]; then
        die "NAS_SSH_HOST must not be empty."
    fi

    if [[ "$NAS_SSH_HOST" =~ [[:space:]] ]]; then
        die "NAS_SSH_HOST must not contain whitespace: $NAS_SSH_HOST"
    fi

    if [[ -z "$NAS_SSH_DIR" ]]; then
        die "NAS_SSH_DIR must not be empty."
    fi

    if [[ "$NAS_SSH_DIR" == /* || "$NAS_SSH_DIR" == "~"* ]]; then
        die "NAS_SSH_DIR must be relative to the remote home directory: $NAS_SSH_DIR"
    fi

    if [[ "$NAS_SSH_DIR" == ".." ||
          "$NAS_SSH_DIR" == ../* ||
          "$NAS_SSH_DIR" == */../* ||
          "$NAS_SSH_DIR" == */.. ]]; then
        die "NAS_SSH_DIR must not contain path traversal: $NAS_SSH_DIR"
    fi

    if [[ "$NAS_SSH_DIR" =~ [^a-zA-Z0-9_./-] ]]; then
        die "NAS_SSH_DIR contains unsafe characters: $NAS_SSH_DIR"
    fi

    if [[ -z "$NAS_RSYNC_PATH" || "$NAS_RSYNC_PATH" != /* ]]; then
        die "NAS_RSYNC_PATH must be a non-empty absolute path."
    fi

    if [[ "$NAS_RSYNC_PATH" =~ [^a-zA-Z0-9_./-] ]]; then
        die "NAS_RSYNC_PATH contains unsafe characters: $NAS_RSYNC_PATH"
    fi

    if [[ -z "$NAS_ROOT" || "$NAS_ROOT" != /* ]]; then
        die "NAS_ROOT must be a non-empty absolute path."
    fi

    if [[ -z "$NAS_BACKUP_DIR" || "$NAS_BACKUP_DIR" != /* ]]; then
        die "NAS_BACKUP_DIR must be a non-empty absolute path."
    fi
}

# ----
# Retention
# ----

apply_retention() {
    local backup_dir="$1"
    local retention_count="$2"

    local -a backups=()
    local backup
    local checksum
    local total
    local remove_count
    local i

    step "Applying local backup retention"

    if (( retention_count == 0 )); then
        log "Retention is disabled."
        return
    fi

    mapfile -t backups < <(
        find "$backup_dir" \
            -maxdepth 1 \
            -type f \
            -name "${DOMAIN}-????????-??????.bind" \
            -print |
        sort
    )

    total="${#backups[@]}"

    log "Backups present: $total"
    log "Backups retained: $retention_count"

    if (( total <= retention_count )); then
        ok "No backups require removal."
        return
    fi

    remove_count=$(( total - retention_count ))

    log "Removing $remove_count expired backup(s)."

    for (( i = 0; i < remove_count; i++ )); do
        backup="${backups[$i]}"
        checksum="${backup}.sha256"

        log "Removing: $(basename "$backup")"
        rm -f -- "$backup"

        if [[ -f "$checksum" ]]; then
            rm -f -- "$checksum"
        fi
    done

    ok "Retention complete."
}

# ----
# NAS availability
# ----

nas_ssh_available() {
    ssh -n "${NAS_SSH_OPTS[@]}" "$NAS_SSH_HOST" true 2>/dev/null
}

nas_smb_available() {
    [[ -d "$NAS_ROOT" ]]
}

# ----
# NAS replication
# ----

replicate_backups_to_nas() {
    local source_dir="$1"

    if ! "$NAS_ENABLED"; then
        log "NAS replication skipped."
        return
    fi

    step "Replicating backups to NAS"

    if nas_ssh_available; then
        log "Transport:   SSH"
        log "Host:        $NAS_SSH_HOST"
        log "Destination: ~/$NAS_SSH_DIR"

        if rsync \
            --archive \
            --checksum \
            --delete \
            --human-readable \
            --itemize-changes \
            --protect-args \
            -e "$NAS_SSH_CMD" \
            --rsync-path="mkdir -p $NAS_SSH_DIR && $NAS_RSYNC_PATH" \
            "$source_dir/" \
            "$NAS_SSH_HOST:$NAS_SSH_DIR/"; then

            ok "NAS replication completed using SSH."
            return
        fi

        warn "SSH replication failed."
        warn "Attempting SMB fallback."
    else
        warn "SSH transport unavailable."
        log "Attempting SMB fallback."
    fi

    if nas_smb_available; then
        log "Transport:   SMB"
        log "Destination: $NAS_BACKUP_DIR"

        if ! mkdir -p "$NAS_BACKUP_DIR"; then
            warn "Unable to create NAS backup directory: $NAS_BACKUP_DIR"
            warn "Local backup remains valid."
            return
        fi

        if rsync \
            --archive \
            --checksum \
            --delete \
            --human-readable \
            --itemize-changes \
            --protect-args \
            --no-perms \
            "$source_dir/" \
            "$NAS_BACKUP_DIR/"; then

            ok "NAS replication completed using SMB."
            return
        fi

        warn "SMB replication failed."
        warn "Local backup remains valid."
        return
    fi

    warn "NAS is unavailable using both SSH and SMB."
    warn "SSH host: $NAS_SSH_HOST"
    warn "SMB mount: $NAS_ROOT"
    warn "Local backup remains valid."
}

# ----
# Backup
# ----

backup_zone() {
    local timestamp
    local backup_file
    local response
    local zone
    local temp_file
    local record_count
    local automatic_filename=false

    timestamp="$(date '+%Y%m%d-%H%M%S')"

    if [[ -n "$OUTPUT_FILE" ]]; then
        backup_file="$OUTPUT_FILE"
    else
        backup_file="${BACKUP_DIR}/${DOMAIN}-${timestamp}.bind"
        automatic_filename=true
    fi

    mkdir -p "$(dirname "$backup_file")"
    chmod 700 "$(dirname "$backup_file")" 2>/dev/null || true

    [[ ! -e "$backup_file" ]] ||
        die "Backup file already exists: $backup_file"

    step "ClouDNS DNS zone backup"

    log "Zone:        $DOMAIN"
    log "Destination: $backup_file"

    if "$automatic_filename"; then
        log "Retention:   $RETENTION_COUNT backup(s)"
    else
        log "Retention:   not managed for custom --output file"
    fi

    if "$NAS_ENABLED"; then
        log "NAS mirror:  enabled"
    else
        log "NAS mirror:  disabled"
    fi

    printf '\n'

    step "Exporting DNS zone from ClouDNS"

    response="$(
        api_request \
            "/dns/records-export.json" \
            --data-urlencode "domain-name=${DOMAIN}"
    )"

    zone="$(extract_zone "$response")"

    [[ -n "$zone" ]] ||
        die "ClouDNS returned an empty zone export."

    temp_file="$(mktemp "${TMPDIR:-/tmp}/cloudns-backup.XXXXXX")"

    trap 'rm -f "${temp_file:-}"' EXIT

    {
        printf '; -----------------------------------------------------------------------------\n'
        printf '; ClouDNS DNS zone backup\n'
        printf '; -----------------------------------------------------------------------------\n'
        printf '; Domain:      %s\n' "$DOMAIN"
        printf '; Created:     %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf '; Created UTC: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '; Script:      cloudns-backup.sh %s\n' "$SCRIPT_VERSION"
        printf '; Source:      ClouDNS BIND zone export API\n'
        printf '; -----------------------------------------------------------------------------\n'
        printf '\n'
        printf '%s\n' "$zone"
    } >"$temp_file"

    if ! grep -Eq '^[[:space:]]*\$ORIGIN[[:space:]]+' "$temp_file"; then
        die "Export does not contain a BIND \$ORIGIN directive."
    fi

    if ! grep -Eq '[[:space:]]IN[[:space:]]' "$temp_file"; then
        die "Export does not appear to contain DNS records."
    fi

    record_count="$(
        grep -Ec \
            '[[:space:]]IN[[:space:]]' \
            "$temp_file" ||
        true
    )"

    mv "$temp_file" "$backup_file"
    chmod 600 "$backup_file"

    trap - EXIT

    create_checksum "$backup_file"

    ok "DNS zone export completed."

    log "Records:     $record_count"
    log "Backup:      $backup_file"
    log "Checksum:    ${backup_file}.sha256"

    printf '\n'

    if "$automatic_filename"; then
        apply_retention "$BACKUP_DIR" "$RETENTION_COUNT"

        printf '\n'

        replicate_backups_to_nas "$BACKUP_DIR"
    else
        log "Retention and NAS replication skipped for custom --output backup."
    fi

    printf '\n'

    ok "CloudNS backup completed successfully."
}

# ----
# Restore
# ----

restore_zone() {
    local response

    [[ -f "$RESTORE_FILE" ]] ||
        die "Restore file not found: $RESTORE_FILE"

    [[ -r "$RESTORE_FILE" ]] ||
        die "Restore file is not readable: $RESTORE_FILE"

    [[ -s "$RESTORE_FILE" ]] ||
        die "Restore file is empty: $RESTORE_FILE"

    if ! grep -Eq '^[[:space:]]*\$ORIGIN[[:space:]]+' "$RESTORE_FILE"; then
        die "Restore file does not contain a BIND \$ORIGIN directive."
    fi

    if ! grep -Eq '[[:space:]]IN[[:space:]]' "$RESTORE_FILE"; then
        die "Restore file does not appear to contain DNS records."
    fi

    step "ClouDNS DNS zone restore"

    log "Zone:             $DOMAIN"
    log "Backup:           $RESTORE_FILE"
    log "Replace existing: $REPLACE_EXISTING"
    log "Dry run:          $DRY_RUN"

    printf '\n'

    verify_checksum_if_present "$RESTORE_FILE"

    printf '\n'

    if "$REPLACE_EXISTING"; then
        warn "Existing DNS records for $DOMAIN will be deleted before import."
    else
        log "Existing DNS records will be retained."
        log "Backup records will be imported in addition to existing records."
    fi

    printf '\n'

    if "$DRY_RUN"; then
        step "Restore dry run"

        log "No DNS records will be changed."
        log "Backup contents follow."

        printf '\n'

        cat "$RESTORE_FILE"

        printf '\n'

        ok "Restore dry run completed."
        return
    fi

    step "Importing DNS zone into ClouDNS"

    if "$REPLACE_EXISTING"; then
        response="$(
            api_request \
                "/dns/records-import.json" \
                --data-urlencode "domain-name=${DOMAIN}" \
                --data-urlencode "format=bind" \
                --data-urlencode "content@${RESTORE_FILE}" \
                --data-urlencode "delete-existing-records=1"
        )"
    else
        response="$(
            api_request \
                "/dns/records-import.json" \
                --data-urlencode "domain-name=${DOMAIN}" \
                --data-urlencode "format=bind" \
                --data-urlencode "content@${RESTORE_FILE}"
        )"
    fi

    check_api_response "$response"

    log "ClouDNS response:"

    if jq -e . <<<"$response" >/dev/null 2>&1; then
        jq . <<<"$response"
    else
        printf '%s\n' "$response"
    fi

    printf '\n'

    ok "Restore request completed."
}

# ----
# Arguments
# ----

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup-dir)
            [[ $# -ge 2 ]] ||
                die "--backup-dir requires a directory."

            BACKUP_DIR="$2"
            shift 2
            ;;

        --output)
            [[ $# -ge 2 ]] ||
                die "--output requires a filename."

            OUTPUT_FILE="$2"
            shift 2
            ;;

        --retention-count)
            [[ $# -ge 2 ]] ||
                die "--retention-count requires a number."

            RETENTION_COUNT="$2"
            shift 2
            ;;

        --no-nas)
            NAS_ENABLED=false
            shift
            ;;

        --restore)
            [[ $# -ge 2 ]] ||
                die "--restore requires a filename."

            MODE="restore"
            RESTORE_FILE="$2"
            shift 2
            ;;

        --replace-existing)
            REPLACE_EXISTING=true
            shift
            ;;

        --dry-run)
            DRY_RUN=true
            shift
            ;;

        --version)
            printf '%s\n' "$SCRIPT_VERSION"
            exit 0
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            printf '%s[%s] ERROR: Unknown argument: %s%s\n\n' \
                "$C_RED" \
                "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$1" \
                "$C_RESET" >&2

            usage
            exit 1
            ;;
    esac
done

# ----
# Pre-flight
# ----

[[ "$(uname)" == "Darwin" ]] ||
    die "This script is intended for macOS."

(( BASH_VERSINFO[0] >= 4 )) ||
    die "Bash 4 or later is required. Current version: $BASH_VERSION"

for command in curl jq shasum grep mktemp find sort rsync ssh; do
    command -v "$command" >/dev/null 2>&1 ||
        die "Required command not found: $command"
done

[[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] ||
    die "--retention-count must be a non-negative integer."

validate_nas_configuration

if [[ "$MODE" == "backup" ]]; then
    "$DRY_RUN" &&
        die "--dry-run is only valid with --restore."

    "$REPLACE_EXISTING" &&
        die "--replace-existing is only valid with --restore."

    [[ -z "$RESTORE_FILE" ]] ||
        die "--restore cannot be combined with backup mode."
fi

if [[ "$MODE" == "restore" ]]; then
    [[ -z "$OUTPUT_FILE" ]] ||
        die "--output cannot be combined with --restore."

    [[ "$BACKUP_DIR" == "$DEFAULT_BACKUP_DIR" ]] ||
        die "--backup-dir cannot be combined with --restore."

    [[ "$RETENTION_COUNT" == "$DEFAULT_RETENTION_COUNT" ]] ||
        die "--retention-count cannot be combined with --restore."

    "$NAS_ENABLED" ||
        die "--no-nas is only valid in backup mode."
fi

load_credentials

# ----
# Execute
# ----

case "$MODE" in
    backup)
        backup_zone
        ;;

    restore)
        restore_zone
        ;;

    *)
        die "Unknown operating mode: $MODE"
        ;;
esac
