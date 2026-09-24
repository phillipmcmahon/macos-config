#!/usr/bin/env bash
#
# Script: network-cache-flush.sh
# Purpose: Flush macOS DNS caches and clear the IPv4 ARP cache.
# Version: 1.0.0
# Requires: macOS, Bash 5+ and adjacent lib/common.sh.
# Documentation: Run with --help.
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION='1.0.0'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ! -r $SCRIPT_DIR/lib/common.sh ]]; then
    printf 'ERROR: Required helper not found: %s/lib/common.sh\n' "$SCRIPT_DIR" >&2
    exit 1
fi
source "$SCRIPT_DIR/lib/common.sh"
DRY_RUN=0

# Command interface
usage() {
    cat << EOF
${0##*/} $SCRIPT_VERSION
Usage: ${0##*/} [--dry-run]

Flush the directory service cache, send HUP to mDNSResponder, then clear ARP.
Commands run in order and stop if any command fails.
Run as your normal user. sudo requests authentication when needed.

Options:
  --dry-run     Show commands without changing caches or requesting sudo access
  --version     Show version
  -h, --help    Show help
EOF
}

# Operations
main() {
    while (($#)); do
        case $1 in
            --dry-run) DRY_RUN=1 ;;
            --version)
                printf '%s\n' "$SCRIPT_VERSION"
                return
                ;;
            -h | --help)
                usage
                return
                ;;
            *) die "Unexpected argument: $1. Use --help for usage." ;;
        esac
        shift
    done

    [[ $OSTYPE == darwin* ]] || die 'This script requires macOS.'
    require_cmds sudo dscacheutil killall arp

    if ((DRY_RUN)); then
        log 'Would run: sudo dscacheutil -flushcache'
        log 'Would run: sudo killall -HUP mDNSResponder'
        log 'Would run: sudo arp -a -d'
        return
    fi

    # Preserve the original command order and stop at the first failure.
    log 'Flushing the directory service cache...'
    sudo dscacheutil -flushcache
    log 'Sending HUP to mDNSResponder...'
    sudo killall -HUP mDNSResponder
    log 'Clearing the IPv4 ARP cache...'
    sudo arp -a -d
    ok 'All cache refresh commands completed.'
}

# Entry point
main "$@"
