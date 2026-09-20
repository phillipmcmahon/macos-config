#!/usr/bin/env bash
#
# Script: cloudns.sh
# Purpose: Submit and validate ClouDNS requests with credentials through stdin.
# Version: 1.0.0
# Requires: Bash 5+, curl, jq and common.sh.
# Documentation: docs/USER-MANUAL.md
#

API_BASE='https://api.cloudns.net'
DOMAIN='phillipmcmahon.com'
TARGET='phillipmcmahon.com'
TTL=300
CREDENTIALS_FILE="$HOME/.config/cloudns/credentials"
CLOUDNS_CONFIG="$HOME/.config/cloudns/config"
CONNECT_TIMEOUT=15 REQUEST_TIMEOUT=90

cloudns_configuration() {
    load_config "$CLOUDNS_CONFIG" 'DOMAIN TARGET TTL CONNECT_TIMEOUT REQUEST_TIMEOUT' || die 'Invalid ClouDNS configuration.'
    [[ $DOMAIN =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]+$ && $DOMAIN != *..* ]] || die 'Invalid DNS zone.'
    [[ $TARGET =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.?$ ]] || die 'Invalid CNAME target.'
    [[ $TTL =~ ^[1-9][0-9]*$ && $CONNECT_TIMEOUT =~ ^[1-9][0-9]*$ && $REQUEST_TIMEOUT =~ ^[1-9][0-9]*$ ]] || die 'TTL and timeouts must be positive integers.'
}
cloudns_credentials() {
    local previous_id=${CLOUDNS_AUTH_ID:-} previous_password=${CLOUDNS_AUTH_PASSWORD:-}
    if [[ -f $CREDENTIALS_FILE ]]; then
        local metadata owner mode
        metadata=$(stat -f '%u %Lp' "$CREDENTIALS_FILE" 2> /dev/null) || metadata=$(stat -c '%u %a' "$CREDENTIALS_FILE") || return 1
        IFS=' ' read -r owner mode <<< "$metadata"
        (((8#$mode & 8#077) == 0)) || die 'Credentials file must be private: chmod 600 ~/.config/cloudns/credentials'
    fi
    load_config "$CREDENTIALS_FILE" 'CLOUDNS_AUTH_ID CLOUDNS_AUTH_PASSWORD' || die 'Invalid credentials file.'
    [[ -z $previous_id ]] || CLOUDNS_AUTH_ID=$previous_id
    [[ -z $previous_password ]] || CLOUDNS_AUTH_PASSWORD=$previous_password
    [[ -n ${CLOUDNS_AUTH_ID:-} && -n ${CLOUDNS_AUTH_PASSWORD:-} ]] || die 'ClouDNS API credentials are required.'
    # Explicitly remove export attributes inherited from the caller.
    export -n CLOUDNS_AUTH_ID CLOUDNS_AUTH_PASSWORD
}
api_request() {
    local endpoint=$1 key value body='' encoded
    shift
    # Arguments are alternating field names and literal values.
    set -- auth-id "$CLOUDNS_AUTH_ID" auth-password "$CLOUDNS_AUTH_PASSWORD" "$@"
    (($# % 2 == 0)) || return 1
    while (($#)); do
        key=$1 value=$2
        shift 2
        encoded=$(printf '%s' "$value" | jq -sRr @uri) || return 1
        body+="${body:+&}$key=$encoded"
    done
    printf '%s' "$body" | curl --fail --silent --show-error \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$REQUEST_TIMEOUT" \
        --proto '=https' --request POST --data-binary @- "$API_BASE$endpoint"
}
api_success() {
    jq -e 'type == "object" and .status == "Success"' <<< "$1" > /dev/null 2>&1 || {
        err 'ClouDNS did not return an explicit successful response. No automatic retry was attempted.'
        return 1
    }
}
cloudns_preflight() {
    require_cmds curl jq
    cloudns_configuration
    cloudns_credentials
}
