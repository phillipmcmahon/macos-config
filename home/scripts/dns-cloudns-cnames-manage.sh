#!/usr/bin/env bash
#
# Script: dns-cloudns-cnames-manage.sh
# Purpose: Reconcile or delete explicit ClouDNS CNAME records.
# Version: 1.0.0
# Requires: Bash 5+, curl, jq and adjacent lib/.
# Documentation: docs/USER-MANUAL.md
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION='1.0.0'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/cloudns.sh"
HOSTS_FILE="$HOME/.config/cloudns/hosts.txt"
DRY_RUN=0 DELETE_MODE=0 ASSUME_YES=0

# Command interface
usage() {
    cat << EOF
${0##*/} $SCRIPT_VERSION
Usage: ${0##*/} [--hosts-file FILE] [--delete] [--dry-run] [--yes]

Default: create missing CNAMEs and reconcile their target and TTL.
Delete mode requires confirmation or --yes. Other record types are untouched.

Options:
  --hosts-file FILE  Relative hostnames, one per line (default: ~/.config/cloudns/hosts.txt)
  --delete           Delete matching CNAMEs
  --dry-run          Read DNS and report changes without modifying it
  --yes              Skip deletion confirmation
  --version          Show version
  -h, --help         Show help

Settings: ~/.config/cloudns/config. Credentials: ~/.config/cloudns/credentials.
Existing CLOUDNS_AUTH_ID and CLOUDNS_AUTH_PASSWORD environment values take precedence.
EOF
}

# Helpers
process_host() {
    local host=$1 records matches id current ttl response count
    records=$(api_request /dns/records.json domain-name "$DOMAIN" host "$host" type CNAME rows-per-page 100 page 1) || {
        err "Lookup failed: $host"
        return 1
    }
    # An empty array or empty object means absent. Anything else must be a
    # record-ID object with complete records. Never turn parse failure into absence.
    jq -e '(. == []) or (type == "object" and all(to_entries[];
        (.key | test("^[0-9]+$")) and (.value | type == "object") and
        (.value.type | type == "string") and (.value.host | type == "string") and
        (.value.record | type == "string") and (.value.ttl | tostring | test("^[0-9]+$"))))' <<< "$records" > /dev/null || {
        err "Invalid record lookup response: $host"
        return 1
    }
    count=$(jq 'length' <<< "$records") || return 1
    ((count < 100)) || {
        err "Lookup reached the page limit for $host. Refusing an incomplete result."
        return 1
    }
    matches=$(jq -c --arg host "$host" '[to_entries[] | select(.value.type == "CNAME" and (.value.host | ascii_downcase) == $host) | {id:.key, record:.value.record, ttl:.value.ttl}]' <<< "$records") || return 1
    count=$(jq 'length' <<< "$matches") || return 1
    if ((DELETE_MODE)); then
        ((count > 0)) || {
            log "ABSENT: $host"
            return 0
        }
        while IFS= read -r id; do
            if ((DRY_RUN)); then
                log "Would DELETE: $host (ID $id)"
            else
                response=$(api_request /dns/delete-record.json domain-name "$DOMAIN" record-id "$id") || return 1
                api_success "$response" || return 1
                ok "DELETE: $host (ID $id)"
            fi
        done <<< "$(jq -r '.[].id' <<< "$matches")"
    elif ((count > 1)); then
        err "Multiple CNAMEs found for $host. No changes made to this host."
        return 1
    elif ((count == 0)); then
        if ((DRY_RUN)); then
            log "Would CREATE: $host -> $TARGET TTL=$TTL"
        else
            response=$(api_request /dns/add-record.json domain-name "$DOMAIN" record-type CNAME host "$host" record "$TARGET" ttl "$TTL") || return 1
            api_success "$response" || return 1
            ok "CREATE: $host -> $TARGET TTL=$TTL"
        fi
    else
        id=$(jq -r '.[0].id' <<< "$matches")
        current=$(jq -r '.[0].record' <<< "$matches")
        ttl=$(jq -r '.[0].ttl' <<< "$matches")
        if [[ ${current,,} == "${TARGET,,}" || ${current,,} == "${TARGET,,}." ]]; then
            [[ $ttl != "$TTL" ]] || {
                ok "UNCHANGED: $host -> $current TTL=$ttl"
                return 0
            }
        fi
        if ((DRY_RUN)); then
            log "Would UPDATE: $host -> $TARGET TTL=$TTL"
        else
            response=$(api_request /dns/mod-record.json domain-name "$DOMAIN" record-id "$id" host "$host" record "$TARGET" ttl "$TTL") || return 1
            api_success "$response" || return 1
            ok "UPDATE: $host -> $TARGET TTL=$TTL"
        fi
    fi
}

# Operations
main() {
    local host failures=0 line
    local -a hosts=()
    local -A seen=()
    while (($#)); do
        case $1 in
            --hosts-file)
                (($# >= 2)) || die '--hosts-file needs a file.'
                HOSTS_FILE=$2
                shift
                ;;
            --delete) DELETE_MODE=1 ;; --dry-run) DRY_RUN=1 ;; --yes | -y) ASSUME_YES=1 ;;
            --version)
                printf '%s\n' "$SCRIPT_VERSION"
                return
                ;;
            --help | -h)
                usage
                return
                ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    [[ -r $HOSTS_FILE && -f $HOSTS_FILE ]] || die "Hosts file not readable: $HOSTS_FILE"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n $line && $line != \#* ]] || continue
        host=${line,,}
        [[ $host =~ ^(\*\.)?[a-z0-9_]([a-z0-9_.-]*[a-z0-9_])?$ && $host != *..* && ${#host} -le 253 ]] || die "Invalid relative hostname: $host"
        if [[ ! ${seen[$host]+x} ]]; then
            hosts+=("$host")
            seen[$host]=1
        fi
    done < "$HOSTS_FILE"
    ((${#hosts[@]} > 0)) || die 'No hostnames found.'
    cloudns_preflight
    TARGET=${TARGET%.}
    if ((DELETE_MODE && !DRY_RUN)); then confirm "Delete CNAMEs for ${#hosts[@]} host(s) in $DOMAIN?" || return 0; fi
    trap 'lock_release' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ((!DRY_RUN)); then lock_acquire "$HOME/.local/state/cloudns/$DOMAIN.lock" || exit 1; fi
    for host in "${hosts[@]}"; do
        if ! process_host "$host"; then
            ((failures += 1))
            err "Host failed: $host"
        fi
    done
    log "Hosts processed: ${#hosts[@]}. Failed: $failures."
    ((failures == 0))
}

# Entry point
main "$@"
