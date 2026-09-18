#!/usr/bin/env bash

set -euo pipefail

readonly API_BASE="https://api.cloudns.net"
readonly DOMAIN="phillipmcmahon.com"
readonly TARGET="phillipmcmahon.com"
readonly TTL="300"

DRY_RUN=false

readonly HOSTS=(
    "*.s3"
    "emby"
    "jellyfin"
    "moodist"
    "music"
    "ntfy"
    "romm"
    "s3"
    "vault"
    "vpn"
)

usage() {
    cat <<EOF
Usage:
    $(basename "$0") [--dry-run]

Environment variables required:
    CLOUDNS_AUTH_ID
    CLOUDNS_AUTH_PASSWORD

Examples:
    $(basename "$0") --dry-run
    $(basename "$0")
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

: "${CLOUDNS_AUTH_ID:?CLOUDNS_AUTH_ID is required}"
: "${CLOUDNS_AUTH_PASSWORD:?CLOUDNS_AUTH_PASSWORD is required}"

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done

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
        echo "ERROR: ClouDNS API request failed:" >&2
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

echo
echo "ClouDNS CNAME reconciliation"
echo "Zone:   $DOMAIN"
echo "Target: $TARGET"
echo "TTL:    $TTL seconds"
echo "Dry run: $DRY_RUN"
echo

for host in "${HOSTS[@]}"; do

    records="$(get_record "$host")"

    #
    # ClouDNS returns the record ID as the JSON object's key.
    # Convert the matching CNAME into:
    #
    #   record-id<TAB>record<TAB>ttl
    #
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

    case "${#matches[@]}" in
        0)
            create_record "$host"
            ;;

        1)
            IFS=$'\t' read -r record_id current_target current_ttl \
                <<<"${matches[0]}"

            #
            # Be tolerant of an optional trailing dot returned by DNS APIs.
            #
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
            echo "ERROR   ${host}.${DOMAIN}"
            echo "        Multiple CNAME records found. No change made."
            printf '        %s\n' "${matches[@]}"
            ;;
    esac
done

echo
echo "Finished."
