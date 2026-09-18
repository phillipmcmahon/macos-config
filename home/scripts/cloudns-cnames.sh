#!/usr/bin/env bash
#
# cloudns-cnames.sh
#
# Version: 1.3.0
#
# v1.3.0:
#   - Added --delete mode.
#   - --delete removes the CNAME records specified in the default hosts file
#     or a hosts file supplied with --hosts-file.
#   - Delete mode only removes CNAME records and does not affect other DNS
#     record types at the same hostname.
#   - --dry-run can be combined with --delete to preview removals.
#   - Missing CNAME records are reported as ABSENT and require no action.
#   - If multiple CNAME records exist for a hostname, delete mode removes
#     each matching CNAME record returned by ClouDNS.
#
# v1.2.0:
#   - Added ~/.config/cloudns/hosts.txt as the default hosts file.
#   - --hosts-file remains available to override the default location.
#
# v1.1.0:
#   - Added automatic loading of ClouDNS credentials from
#     ~/.config/cloudns/credentials.
#   - Existing CLOUDNS_AUTH_ID and CLOUDNS_AUTH_PASSWORD environment
#     variables take precedence over values in the credentials file.
#   - Falls back to environment variables when the credentials file does
#     not exist.
#
# v1.0.0:
#   - Initial release.
#   - Reconciles a defined set of CNAME records in a ClouDNS zone.
#   - Creates missing records.
#   - Updates records where the target or TTL differs.
#   - Leaves correctly configured records unchanged.
#   - Supports --dry-run to preview changes without modifying DNS.
#   - Hostnames are read from an external text file so the script does not
#     need to be modified when records are added or removed.
#   - Blank lines and lines beginning with # are ignored in the hosts file.
#   - Refuses to modify a hostname if multiple CNAME records are returned.
#
# Usage:
#   cloudns-cnames.sh [--hosts-file FILE] [--dry-run] [--delete]
#
# Examples:
#
#   Preview normal reconciliation:
#
#       cloudns-cnames.sh --dry-run
#
#   Apply normal reconciliation:
#
#       cloudns-cnames.sh
#
#   Preview deletion of records in the default hosts file:
#
#       cloudns-cnames.sh --delete --dry-run
#
#   Delete records in the default hosts file:
#
#       cloudns-cnames.sh --delete
#
#   Preview deletion using an alternative hosts file:
#
#       cloudns-cnames.sh \
#           --hosts-file /path/to/alternate-hosts.txt \
#           --delete \
#           --dry-run
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
#   At least CLOUDNS_AUTH_ID and CLOUDNS_AUTH_PASSWORD must be available from
#   one of these sources.
#
# Hosts file:
#   The default hosts file is:
#
#       ~/.config/cloudns/hosts.txt
#
#   Use --hosts-file FILE to override the default location.
#
# Hosts file format:
#   One relative DNS hostname per line.
#
#   Blank lines and lines beginning with # are ignored.
#
#   Example:
#
#       # S3
#       *.s3
#       s3
#
#       # Media
#       emby
#       jellyfin
#       music
#
#       # Services
#       moodist
#       ntfy
#       romm
#       vault
#       vpn
#
# Normal mode:
#   Ensures each listed hostname has a CNAME pointing to TARGET with the
#   configured TTL.
#
# Delete mode:
#   Removes CNAME records for each hostname listed in the hosts file.
#   Other DNS record types are not removed.
#
# The configured TARGET is the zone apex expressed as its fully qualified
# hostname. For example, TARGET="phillipmcmahon.com" is equivalent to using
# @ as the target in the ClouDNS web interface.
#

set -euo pipefail
IFS=$'\n\t'

# ----
# Configuration
# ----

readonly API_BASE="https://api.cloudns.net"
readonly DOMAIN="phillipmcmahon.com"
readonly TARGET="phillipmcmahon.com"
readonly TTL="300"

readonly CREDENTIALS_FILE="${HOME}/.config/cloudns/credentials"
readonly DEFAULT_HOSTS_FILE="${HOME}/.config/cloudns/hosts.txt"

DRY_RUN=false
DELETE_MODE=false
HOSTS_FILE="$DEFAULT_HOSTS_FILE"

# ----
# Helpers
# ----

log() {
    printf '[cloudns-cnames] %s\n' "$*"
}

die() {
    printf '[cloudns-cnames] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
    $(basename "$0") [--hosts-file FILE] [--dry-run] [--delete]

Options:
    --hosts-file FILE   Override the default hosts file
                        Default: $DEFAULT_HOSTS_FILE

    --dry-run           Show changes without applying them

    --delete            Delete CNAME records listed in the hosts file
                        instead of reconciling them

    -h, --help          Show this help

Authentication:
    Credentials are loaded automatically from:

        $CREDENTIALS_FILE

    Existing CLOUDNS_AUTH_ID and CLOUDNS_AUTH_PASSWORD environment
    variables take precedence over values in the credentials file.

Examples:
    $(basename "$0") --dry-run
    $(basename "$0")

    $(basename "$0") --delete --dry-run
    $(basename "$0") --delete

    $(basename "$0") \
        --hosts-file /path/to/alternate-hosts.txt \
        --delete \
        --dry-run
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

    if jq -e '
        type == "object"
        and .status? == "Failed"
    ' <<<"$response" >/dev/null 2>&1; then
        printf '[cloudns-cnames] ERROR: ClouDNS API request failed:\n' >&2
        jq . <<<"$response" >&2
        exit 1
    fi
}

get_record() {
    local host="$1"
    local response

    response="$(
        api_request \
            "/dns/records.json" \
            --data-urlencode "domain-name=${DOMAIN}" \
            --data-urlencode "host=${host}" \
            --data-urlencode "type=CNAME" \
            --data-urlencode "rows-per-page=100" \
            --data-urlencode "page=1"
    )"

    check_api_response "$response"

    printf '%s\n' "$response"
}

create_record() {
    local host="$1"
    local response

    if "$DRY_RUN"; then
        printf 'CREATE  %-16s -> %s  TTL=%s\n' \
            "$host" "$TARGET" "$TTL"
        return
    fi

    response="$(
        api_request \
            "/dns/add-record.json" \
            --data-urlencode "domain-name=${DOMAIN}" \
            --data-urlencode "record-type=CNAME" \
            --data-urlencode "host=${host}" \
            --data-urlencode "record=${TARGET}" \
            --data-urlencode "ttl=${TTL}"
    )"

    check_api_response "$response"

    printf 'CREATE  %-16s -> %s  TTL=%s\n' \
        "$host" "$TARGET" "$TTL"
}

update_record() {
    local record_id="$1"
    local host="$2"
    local old_target="$3"
    local old_ttl="$4"
    local response

    if "$DRY_RUN"; then
        printf 'UPDATE  %-16s %s TTL=%s -> %s TTL=%s\n' \
            "$host" "$old_target" "$old_ttl" "$TARGET" "$TTL"
        return
    fi

    response="$(
        api_request \
            "/dns/mod-record.json" \
            --data-urlencode "domain-name=${DOMAIN}" \
            --data-urlencode "record-id=${record_id}" \
            --data-urlencode "host=${host}" \
            --data-urlencode "record=${TARGET}" \
            --data-urlencode "ttl=${TTL}"
    )"

    check_api_response "$response"

    printf 'UPDATE  %-16s %s TTL=%s -> %s TTL=%s\n' \
        "$host" "$old_target" "$old_ttl" "$TARGET" "$TTL"
}

delete_record() {
    local record_id="$1"
    local host="$2"
    local current_target="$3"
    local current_ttl="$4"
    local response

    if "$DRY_RUN"; then
        printf 'DELETE  %-16s -> %s  TTL=%s  ID=%s\n' \
            "$host" "$current_target" "$current_ttl" "$record_id"
        return
    fi

    response="$(
        api_request \
            "/dns/delete-record.json" \
            --data-urlencode "domain-name=${DOMAIN}" \
            --data-urlencode "record-id=${record_id}"
    )"

    check_api_response "$response"

    printf 'DELETE  %-16s -> %s  TTL=%s  ID=%s\n' \
        "$host" "$current_target" "$current_ttl" "$record_id"
}

# ----
# Arguments
# ----

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hosts-file)
            [[ $# -ge 2 ]] ||
                die "--hosts-file requires a filename."

            HOSTS_FILE="$2"
            shift 2
            ;;

        --dry-run)
            DRY_RUN=true
            shift
            ;;

        --delete)
            DELETE_MODE=true
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            printf '[cloudns-cnames] ERROR: Unknown argument: %s\n\n' "$1" >&2
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

[[ -f "$HOSTS_FILE" ]] ||
    die "Hosts file not found: $HOSTS_FILE"

[[ -r "$HOSTS_FILE" ]] ||
    die "Hosts file is not readable: $HOSTS_FILE"

for command in curl jq awk; do
    command -v "$command" >/dev/null 2>&1 ||
        die "Required command not found: $command"
done

load_credentials

# ----
# Load host definitions
# ----
#
# Normalise the input file before loading it:
#   - remove CR characters from Windows-style line endings
#   - trim leading and trailing whitespace
#   - ignore comments
#   - ignore blank lines

mapfile -t HOSTS < <(
    awk '
        {
            sub(/\r$/, "")
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
        }

        /^#/ {
            next
        }

        /^$/ {
            next
        }

        {
            print
        }
    ' "$HOSTS_FILE"
)

(( ${#HOSTS[@]} > 0 )) ||
    die "No hosts found in: $HOSTS_FILE"

# ----
# Start
# ----

if "$DELETE_MODE"; then
    log "ClouDNS CNAME deletion"
else
    log "ClouDNS CNAME reconciliation"
fi

log "Zone:       $DOMAIN"

if ! "$DELETE_MODE"; then
    log "Target:     $TARGET"
    log "TTL:        $TTL seconds"
fi

log "Hosts file: $HOSTS_FILE"
log "Hosts:      ${#HOSTS[@]}"
log "Delete:     $DELETE_MODE"
log "Dry run:    $DRY_RUN"

printf '\n'

# ----
# Process DNS records
# ----

for host in "${HOSTS[@]}"; do
    records="$(get_record "$host")"

    # ClouDNS returns the record ID as the JSON object's key.
    #
    # Convert each matching CNAME to:
    #
    #   record-id<TAB>record<TAB>ttl

    mapfile -t matches < <(
        jq -r '
            to_entries[]
            | select(.value.type == "CNAME")
            | [
                .key,
                .value.record,
                (.value.ttl | tostring)
              ]
            | @tsv
        ' <<<"$records"
    )

    # ----
    # Delete mode
    # ----

    if "$DELETE_MODE"; then
        if (( ${#matches[@]} == 0 )); then
            printf 'ABSENT  %-16s no CNAME record found\n' "$host"
            continue
        fi

        for match in "${matches[@]}"; do
            IFS=$'\t' read -r \
                record_id \
                current_target \
                current_ttl \
                <<<"$match"

            delete_record \
                "$record_id" \
                "$host" \
                "$current_target" \
                "$current_ttl"
        done

        continue
    fi

    # ----
    # Reconciliation mode
    # ----

    case "${#matches[@]}" in
        0)
            create_record "$host"
            ;;

        1)
            IFS=$'\t' read -r \
                record_id \
                current_target \
                current_ttl \
                <<<"${matches[0]}"

            # DNS APIs may return canonical names with a trailing dot.
            # Remove it before comparing the current and desired targets.

            normalised_target="${current_target%.}"
            desired_target="${TARGET%.}"

            if [[ "$normalised_target" == "$desired_target" &&
                  "$current_ttl" == "$TTL" ]]; then

                printf 'OK      %-16s -> %s  TTL=%s\n' \
                    "$host" "$current_target" "$current_ttl"
            else
                update_record \
                    "$record_id" \
                    "$host" \
                    "$current_target" \
                    "$current_ttl"
            fi
            ;;

        *)
            printf 'ERROR   %s.%s\n' "$host" "$DOMAIN"
            printf '        Multiple CNAME records found. No change made.\n'
            printf '        %s\n' "${matches[@]}"
            ;;
    esac
done

printf '\n'
log "Finished."
