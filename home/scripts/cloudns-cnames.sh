#!/usr/bin/env bash
#
# cloudns-cnames.sh
#
# Version: 1.4.0
#
# v1.4.0:
#   - Added colourised terminal output matching the style used by the existing
#     macOS management scripts.
#   - Section headings are displayed in blue.
#   - Successful operations are displayed in green.
#   - Dry-run operations and informational warnings are displayed in yellow.
#   - Delete operations and errors are displayed in red.
#   - Colours are disabled automatically when stdout is not a terminal.
#   - Added timestamped logging.
#   - Improved help layout for easier scanning.
#   - No DNS reconciliation or deletion behaviour was changed.
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

set -Eeuo pipefail
IFS=$'\n\t'

# Prefer Homebrew binaries over older macOS-supplied tools.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly SCRIPT_VERSION="1.4.0"
readonly SCRIPT_NAME="${0##*/}"

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
# Record output
# ----

print_ok_record() {
    local host="$1"
    local target="$2"
    local ttl="$3"

    printf '%sOK      %-16s -> %s  TTL=%s%s\n' \
        "$C_GREEN" \
        "$host" \
        "$target" \
        "$ttl" \
        "$C_RESET"
}

print_create_record() {
    local host="$1"
    local target="$2"
    local ttl="$3"

    if "$DRY_RUN"; then
        printf '%sCREATE  %-16s -> %s  TTL=%s  [DRY RUN]%s\n' \
            "$C_YELLOW" \
            "$host" \
            "$target" \
            "$ttl" \
            "$C_RESET"
    else
        printf '%sCREATE  %-16s -> %s  TTL=%s%s\n' \
            "$C_GREEN" \
            "$host" \
            "$target" \
            "$ttl" \
            "$C_RESET"
    fi
}

print_update_record() {
    local host="$1"
    local old_target="$2"
    local old_ttl="$3"
    local new_target="$4"
    local new_ttl="$5"

    if "$DRY_RUN"; then
        printf '%sUPDATE  %-16s %s TTL=%s -> %s TTL=%s  [DRY RUN]%s\n' \
            "$C_YELLOW" \
            "$host" \
            "$old_target" \
            "$old_ttl" \
            "$new_target" \
            "$new_ttl" \
            "$C_RESET"
    else
        printf '%sUPDATE  %-16s %s TTL=%s -> %s TTL=%s%s\n' \
            "$C_GREEN" \
            "$host" \
            "$old_target" \
            "$old_ttl" \
            "$new_target" \
            "$new_ttl" \
            "$C_RESET"
    fi
}

print_delete_record() {
    local host="$1"
    local target="$2"
    local ttl="$3"
    local record_id="$4"

    if "$DRY_RUN"; then
        printf '%sDELETE  %-16s -> %s  TTL=%s  ID=%s  [DRY RUN]%s\n' \
            "$C_YELLOW" \
            "$host" \
            "$target" \
            "$ttl" \
            "$record_id" \
            "$C_RESET"
    else
        printf '%sDELETE  %-16s -> %s  TTL=%s  ID=%s%s\n' \
            "$C_RED" \
            "$host" \
            "$target" \
            "$ttl" \
            "$record_id" \
            "$C_RESET"
    fi
}

print_absent_record() {
    local host="$1"

    printf '%sABSENT  %-16s no CNAME record found%s\n' \
        "$C_YELLOW" \
        "$host" \
        "$C_RESET"
}

print_record_error() {
    local host="$1"

    printf '%sERROR   %s.%s%s\n' \
        "$C_RED" \
        "$host" \
        "$DOMAIN" \
        "$C_RESET"
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

Manage the defined CNAME records for:

    ${C_BOLD}${DOMAIN}${C_RESET}


${C_BLUE}${C_BOLD}USAGE${C_RESET}

    ${SCRIPT_NAME} [OPTIONS]


${C_BLUE}${C_BOLD}MODES${C_RESET}

    Default
        Reconcile the configured CNAME records.

        Missing records are created.
        Incorrect targets or TTL values are updated.
        Correct records are left unchanged.

    --delete
        Delete the configured CNAME records instead of reconciling them.

        Other DNS record types at the same hostname are not affected.


${C_BLUE}${C_BOLD}OPTIONS${C_RESET}

    --hosts-file FILE
        Read hostnames from FILE instead of the default hosts file.

        Default:
            ${DEFAULT_HOSTS_FILE}

    --dry-run
        Show the changes that would be made without modifying DNS.

        May be used with either reconciliation or --delete mode.

    --delete
        Delete the CNAME records listed in the hosts file.

    --version
        Display the script version.

    -h, --help
        Display this help.


${C_BLUE}${C_BOLD}DNS CONFIGURATION${C_RESET}

    Zone:
        ${DOMAIN}

    CNAME target:
        ${TARGET}

    TTL:
        ${TTL} seconds


${C_BLUE}${C_BOLD}HOSTS FILE${C_RESET}

    Default:
        ${DEFAULT_HOSTS_FILE}

    Format:
        One relative DNS hostname per line.

    Blank lines and lines beginning with # are ignored.

    Example:

        # S3
        *.s3
        s3

        # Media
        emby
        jellyfin
        music

        # Services
        moodist
        ntfy
        romm
        vault
        vpn


${C_BLUE}${C_BOLD}AUTHENTICATION${C_RESET}

    ClouDNS credentials are loaded automatically from:

        ${CREDENTIALS_FILE}

    The file may contain:

        CLOUDNS_AUTH_ID='YOUR_AUTH_ID'
        CLOUDNS_AUTH_PASSWORD='YOUR_API_PASSWORD'

    Existing CLOUDNS_AUTH_ID and CLOUDNS_AUTH_PASSWORD environment
    variables take precedence over values loaded from the credentials file.


${C_BLUE}${C_BOLD}EXAMPLES${C_RESET}

    Preview CNAME reconciliation:

        ${SCRIPT_NAME} --dry-run

    Apply CNAME reconciliation:

        ${SCRIPT_NAME}

    Preview deletion:

        ${SCRIPT_NAME} --delete --dry-run

    Delete the configured CNAME records:

        ${SCRIPT_NAME} --delete

    Use an alternative hosts file:

        ${SCRIPT_NAME} \\
            --hosts-file /path/to/alternate-hosts.txt \\
            --dry-run

    Preview deletion using an alternative hosts file:

        ${SCRIPT_NAME} \\
            --hosts-file /path/to/alternate-hosts.txt \\
            --delete \\
            --dry-run
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

        # Explicit environment variables supplied by the caller take
        # precedence over values loaded from the credentials file.

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

# ----
# Record retrieval
# ----

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

# ----
# Create
# ----

create_record() {
    local host="$1"
    local response

    if "$DRY_RUN"; then
        print_create_record \
            "$host" \
            "$TARGET" \
            "$TTL"

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

    print_create_record \
        "$host" \
        "$TARGET" \
        "$TTL"
}

# ----
# Update
# ----

update_record() {
    local record_id="$1"
    local host="$2"
    local old_target="$3"
    local old_ttl="$4"
    local response

    if "$DRY_RUN"; then
        print_update_record \
            "$host" \
            "$old_target" \
            "$old_ttl" \
            "$TARGET" \
            "$TTL"

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

    print_update_record \
        "$host" \
        "$old_target" \
        "$old_ttl" \
        "$TARGET" \
        "$TTL"
}

# ----
# Delete
# ----

delete_record() {
    local record_id="$1"
    local host="$2"
    local current_target="$3"
    local current_ttl="$4"
    local response

    if "$DRY_RUN"; then
        print_delete_record \
            "$host" \
            "$current_target" \
            "$current_ttl" \
            "$record_id"

        return
    fi

    response="$(
        api_request \
            "/dns/delete-record.json" \
            --data-urlencode "domain-name=${DOMAIN}" \
            --data-urlencode "record-id=${record_id}"
    )"

    check_api_response "$response"

    print_delete_record \
        "$host" \
        "$current_target" \
        "$current_ttl" \
        "$record_id"
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
#
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
    step "ClouDNS CNAME deletion"
else
    step "ClouDNS CNAME reconciliation"
fi

log "Zone:       $DOMAIN"

if ! "$DELETE_MODE"; then
    log "Target:     $TARGET"
    log "TTL:        $TTL seconds"
fi

log "Hosts file: $HOSTS_FILE"
log "Hosts:      ${#HOSTS[@]}"

if "$DELETE_MODE"; then
    log "Mode:       delete"
else
    log "Mode:       reconcile"
fi

if "$DRY_RUN"; then
    warn "Dry run enabled. No DNS changes will be made."
fi

printf '\n'

# ----
# Process DNS records
# ----

if "$DELETE_MODE"; then
    step "Processing CNAME deletions"
else
    step "Processing CNAME records"
fi

printf '\n'

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
            print_absent_record "$host"
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

                print_ok_record \
                    "$host" \
                    "$current_target" \
                    "$current_ttl"
            else
                update_record \
                    "$record_id" \
                    "$host" \
                    "$current_target" \
                    "$current_ttl"
            fi
            ;;

        *)
            print_record_error "$host"

            printf '%s        Multiple CNAME records found. No change made.%s\n' \
                "$C_RED" \
                "$C_RESET"

            for match in "${matches[@]}"; do
                printf '%s        %s%s\n' \
                    "$C_RED" \
                    "$match" \
                    "$C_RESET"
            done
            ;;
    esac
done

printf '\n'

if "$DRY_RUN"; then
    ok "Dry run completed."
elif "$DELETE_MODE"; then
    ok "CNAME deletion completed."
else
    ok "CNAME reconciliation completed."
fi
