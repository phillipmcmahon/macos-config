#!/usr/bin/env bash
#
# cloudns-backup.sh
#
# Version: 1.0.1
#
# v1.0.1:
#   - Fixed handling of the ClouDNS records-export API response.
#   - ClouDNS returns the BIND zone inside the "zone" property of a successful
#     JSON response:
#
#         {
#             "status": "Success",
#             "zone": "..."
#         }
#
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
# Usage:
#   cloudns-backup.sh
#   cloudns-backup.sh --output FILE
#   cloudns-backup.sh --backup-dir DIRECTORY
#   cloudns-backup.sh --restore FILE [--dry-run]
#   cloudns-backup.sh --restore FILE --replace-existing [--dry-run]
#
# Examples:
#
#   Create a timestamped backup:
#
#       cloudns-backup.sh
#
#   Create a backup in an alternative directory:
#
#       cloudns-backup.sh \
#           --backup-dir /path/to/backups
#
#   Create a backup using a specific filename:
#
#       cloudns-backup.sh \
#           --output ~/dns-backup.bind
#
#   Preview restoring a backup:
#
#       cloudns-backup.sh \
#           --restore ~/.config/cloudns/backups/phillipmcmahon.com-20260918-220000.bind \
#           --dry-run
#
#   Restore records without deleting existing records:
#
#       cloudns-backup.sh \
#           --restore ~/.config/cloudns/backups/phillipmcmahon.com-20260918-220000.bind
#
#   Preview an exact zone replacement:
#
#       cloudns-backup.sh \
#           --restore ~/.config/cloudns/backups/phillipmcmahon.com-20260918-220000.bind \
#           --replace-existing \
#           --dry-run
#
#   Replace all existing records with the contents of a backup:
#
#       cloudns-backup.sh \
#           --restore ~/.config/cloudns/backups/phillipmcmahon.com-20260918-220000.bind \
#           --replace-existing
#
# Authentication:
#   Credentials are loaded automatically from:
#
#       ~/.config/cloudns/credentials
#
#   The file may define:
#
#       CLOUDNS_AUTH_ID='YOUR_AUTH_ID'
#       CLOUDNS_AUTH_PASSWORD='YOUR_API_PASSWORD'
#
#   Existing environment variables take precedence over values in the file.
#   If the credentials file does not exist, the script falls back to the
#   environment.
#
# Backup:
#   By default backups are stored in:
#
#       ~/.config/cloudns/backups
#
#   Files are named:
#
#       phillipmcmahon.com-YYYYMMDD-HHMMSS.bind
#
#   A SHA-256 checksum is written alongside each backup:
#
#       phillipmcmahon.com-YYYYMMDD-HHMMSS.bind.sha256
#
# Restore:
#   Restore requires the DNS zone to already exist in ClouDNS.
#
#   By default restore imports the records without deleting existing records.
#   This is safer but may create duplicates if matching records already exist.
#
#   --replace-existing causes ClouDNS to delete the existing DNS records before
#   importing the backup and should only be used when performing an intentional
#   full-zone recovery.
#

set -euo pipefail
IFS=$'\n\t'

# ----
# Configuration
# ----

readonly SCRIPT_VERSION="1.0.1"

readonly API_BASE="https://api.cloudns.net"
readonly DOMAIN="phillipmcmahon.com"

readonly CREDENTIALS_FILE="${HOME}/.config/cloudns/credentials"
readonly DEFAULT_BACKUP_DIR="${HOME}/.config/cloudns/backups"

MODE="backup"

BACKUP_DIR="$DEFAULT_BACKUP_DIR"
OUTPUT_FILE=""
RESTORE_FILE=""

DRY_RUN=false
REPLACE_EXISTING=false

# ----
# Helpers
# ----

log() {
    printf '[cloudns-backup] %s\n' "$*"
}

die() {
    printf '[cloudns-backup] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
    $(basename "$0") [OPTIONS]

Backup options:
    --backup-dir DIRECTORY
                        Directory used for timestamped backups
                        Default: $DEFAULT_BACKUP_DIR

    --output FILE       Write the backup to a specific file instead of using
                        the timestamped default filename

Restore options:
    --restore FILE      Restore DNS records from a BIND-format backup

    --replace-existing  Delete existing records before importing the backup

    --dry-run           Preview the restore operation without modifying DNS

General:
    -h, --help          Show this help

    --version           Display script version

Authentication:
    Credentials are loaded automatically from:

        $CREDENTIALS_FILE

    Existing CLOUDNS_AUTH_ID and CLOUDNS_AUTH_PASSWORD environment
    variables take precedence over values in the credentials file.

Examples:
    $(basename "$0")

    $(basename "$0") \
        --backup-dir /path/to/backups

    $(basename "$0") \
        --output ~/dns-backup.bind

    $(basename "$0") \
        --restore /path/to/backup.bind \
        --dry-run

    $(basename "$0") \
        --restore /path/to/backup.bind

    $(basename "$0") \
        --restore /path/to/backup.bind \
        --replace-existing \
        --dry-run

    $(basename "$0") \
        --restore /path/to/backup.bind \
        --replace-existing
EOF
}

load_credentials() {
    local existing_auth_id="${CLOUDNS_AUTH_ID:-}"
    local existing_auth_password="${CLOUDNS_AUTH_PASSWORD:-}"

    if [[ -f "$CREDENTIALS_FILE" ]]; then
        log "Loading credentials from: $CREDENTIALS_FILE"

        # shellcheck disable=SC1090
        source "$CREDENTIALS_FILE"

        # Explicit environment variables supplied by the caller take
        # precedence over values loaded from the credentials file.

        if [[ -n "$existing_auth_id" ]]; then
            CLOUDNS_AUTH_ID="$existing_auth_id"
        fi

        if [[ -n "$existing_auth_password" ]]; then
            CLOUDNS_AUTH_PASSWORD="$existing_auth_password"
        fi
    else
        log "Credentials file not found. Using environment variables."
    fi

    [[ -n "${CLOUDNS_AUTH_ID:-}" ]] ||
        die "CLOUDNS_AUTH_ID is not configured."

    [[ -n "${CLOUDNS_AUTH_PASSWORD:-}" ]] ||
        die "CLOUDNS_AUTH_PASSWORD is not configured."

    export CLOUDNS_AUTH_ID
    export CLOUDNS_AUTH_PASSWORD
}

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

        printf '[cloudns-backup] ERROR: ClouDNS API request failed:\n' >&2
        jq . <<<"$response" >&2
        exit 1
    fi
}

extract_zone() {
    local response="$1"
    local status
    local zone

    # The records-export API returns:
    #
    #   {
    #       "status": "Success",
    #       "zone": "<BIND zone>"
    #   }

    if ! jq -e . <<<"$response" >/dev/null 2>&1; then
        die "ClouDNS returned an invalid JSON response."
    fi

    if [[ "$(jq -r 'type' <<<"$response")" != "object" ]]; then
        die "Unexpected response type returned by the ClouDNS export API."
    fi

    status="$(jq -r '.status // empty' <<<"$response")"

    if [[ "$status" == "Failed" ]]; then
        printf '[cloudns-backup] ERROR: ClouDNS API request failed:\n' >&2
        jq . <<<"$response" >&2
        exit 1
    fi

    if [[ "$status" != "Success" ]]; then
        printf '[cloudns-backup] ERROR: Unexpected ClouDNS API response:\n' >&2
        jq . <<<"$response" >&2
        exit 1
    fi

    if ! jq -e '
        .zone?
        and (.zone | type == "string")
        and (.zone | length > 0)
    ' <<<"$response" >/dev/null 2>&1; then

        printf '[cloudns-backup] ERROR: Successful response did not contain a valid zone:\n' >&2
        jq . <<<"$response" >&2
        exit 1
    fi

    zone="$(jq -r '.zone' <<<"$response")"

    [[ -n "$zone" ]] ||
        die "ClouDNS returned an empty zone export."

    printf '%s\n' "$zone"
}

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
        log "Checksum file not found. Skipping checksum verification."
        return
    fi

    filename="$(basename "$file")"

    log "Verifying checksum: $checksum_file"

    if (
        cd "$(dirname "$file")"
        shasum -a 256 -c "$(basename "$checksum_file")"
    ); then
        log "Checksum verified: $filename"
    else
        die "Backup checksum verification failed: $file"
    fi
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

    timestamp="$(date '+%Y%m%d-%H%M%S')"

    if [[ -n "$OUTPUT_FILE" ]]; then
        backup_file="$OUTPUT_FILE"
    else
        backup_file="${BACKUP_DIR}/${DOMAIN}-${timestamp}.bind"
    fi

    mkdir -p "$(dirname "$backup_file")"
    chmod 700 "$(dirname "$backup_file")" 2>/dev/null || true

    [[ ! -e "$backup_file" ]] ||
        die "Backup file already exists: $backup_file"

    log "ClouDNS DNS zone backup"
    log "Zone:        $DOMAIN"
    log "Destination: $backup_file"

    printf '\n'

    log "Requesting BIND zone export from ClouDNS..."

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

    # Basic validation.
    #
    # The exported zone should contain $ORIGIN and at least one IN record.

    if ! grep -Eq '^[[:space:]]*\$ORIGIN[[:space:]]+' "$temp_file"; then
        die "Export does not contain a BIND \$ORIGIN directive."
    fi

    if ! grep -Eq '[[:space:]]IN[[:space:]]' "$temp_file"; then
        die "Export does not appear to contain DNS records."
    fi

    mv "$temp_file" "$backup_file"
    chmod 600 "$backup_file"

    trap - EXIT

    create_checksum "$backup_file"

    record_count="$(
        grep -Ec \
            '[[:space:]]IN[[:space:]]' \
            "$backup_file" ||
        true
    )"

    printf '\n'

    log "Backup complete."
    log "Backup:      $backup_file"
    log "Checksum:    ${backup_file}.sha256"
    log "DNS records: $record_count"

    printf '\n'

    shasum -a 256 "$backup_file"
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

    verify_checksum_if_present "$RESTORE_FILE"

    log "ClouDNS DNS zone restore"
    log "Zone:             $DOMAIN"
    log "Backup:           $RESTORE_FILE"
    log "Replace existing: $REPLACE_EXISTING"
    log "Dry run:          $DRY_RUN"

    printf '\n'

    if "$REPLACE_EXISTING"; then
        printf 'WARNING: Existing DNS records for %s will be deleted before import.\n' \
            "$DOMAIN"
    else
        printf 'Existing DNS records will be retained.\n'
        printf 'Records from the backup will be imported in addition to them.\n'
    fi

    printf '\n'

    if "$DRY_RUN"; then
        log "DRY RUN: no DNS records will be changed."

        printf '\n'

        log "Backup contents:"
        printf '\n'

        cat "$RESTORE_FILE"

        printf '\n'
        log "Dry run complete."

        return
    fi

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

    printf '\n'

    log "ClouDNS response:"

    if jq -e . <<<"$response" >/dev/null 2>&1; then
        jq . <<<"$response"
    else
        printf '%s\n' "$response"
    fi

    printf '\n'

    log "Restore request completed."
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
            printf '[cloudns-backup] ERROR: Unknown argument: %s\n\n' "$1" >&2
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

for command in curl jq shasum grep mktemp; do
    command -v "$command" >/dev/null 2>&1 ||
        die "Required command not found: $command"
done

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
fi

umask 077

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
