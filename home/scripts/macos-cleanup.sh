#!/usr/bin/env bash
#
# Script: macos-cleanup.sh
# Purpose: Clean selected macOS caches and optional maintenance targets.
# Version: 1.0.0
# Requires: Bash 5+, macOS, sudo and adjacent lib/.
# Documentation: docs/USER-MANUAL.md
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION='1.0.0'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
DRY_RUN=0 ASSUME_YES=0 SKIP_BROWSERS=0
DO_TRASH=0 DO_SNAPSHOTS=0 DO_DOCKER=0 DO_STATE=0 DO_LOGS=0 DO_DEVELOPER=0
DO_IOS=0 DO_ARCHIVES=0 DO_REPAIR=0 DO_SPOTLIGHT=0 DO_ROUTES=0
ESTIMATED=0 REMOVED_ESTIMATE=0 FAILURES=0 FREE_BEFORE='' STARTED=0
USER_HOME='' REAL_USER=''

# Command interface
usage() {
    cat << EOF
${0##*/} $SCRIPT_VERSION
Usage: sudo /opt/homebrew/bin/bash ${0##*/} [OPTIONS]

Default: user application caches, system caches and Quick Look cache.
Quit affected applications before cleanup. Dry-run needs no confirmation.

Options:
  --dry-run          Inspect targets without deletion or repair
  --yes              Skip confirmation
  --skip-browsers     Preserve the entire general user-cache tree and browser caches
  --trash            Empty this user's home Trash (no other volumes)
  --logs             Remove user logs and diagnostic reports
  --developer        Remove listed rebuildable developer caches
  --time-machine     Delete local Time Machine snapshots
  --docker           Prune stopped containers, unused networks and build cache
  --app-state        Remove saved application window state
  --ios-backups      Remove all local iOS backups
  --xcode-archives   Remove all Xcode archives
  --repair           Flush DNS and rebuild Quick Look / Launch Services
  --spotlight        Rebuild Spotlight index
  --flush-routes     Flush routing table
  --version          Show version
  -h, --help         Show help
EOF
}

# Helpers
human_bytes() { awk -v n="$1" 'BEGIN {printf "%.1f MiB", n/1048576}'; }

summary() {
    local rc=$? after=''
    trap - EXIT
    if ((STARTED)); then
        after=$(df -k "$USER_HOME" | awk 'NR==2 {print $4}') || after=''
        log "Estimated selected size: $(human_bytes "$ESTIMATED")"
        if ((!DRY_RUN)); then log "Estimated size of successfully removed targets: $(human_bytes "$REMOVED_ESTIMATE")"; fi
        if [[ $FREE_BEFORE =~ ^[0-9]+$ && $after =~ ^[0-9]+$ ]]; then
            log "Observed free-space change: $(((after - FREE_BEFORE) * 1024)) bytes (includes other system activity)."
        fi
        log "Failed operations: $FAILURES"
        [[ -z ${LOG_FILE:-} ]] || log "Log: $LOG_FILE"
    fi
    lock_release || rc=1
    ((FAILURES == 0)) || rc=1
    exit "$rc"
}

remove_target() {
    local path=$1 size
    [[ -e $path || -L $path ]] || return 0
    # Never follow user-controlled symlink components while running as root.
    reject_symlinks "$path" || {
        warn "Skipped symbolic-link target: $path"
        ((FAILURES += 1))
        return 0
    }
    size=$(du -sk "$path" 2> /dev/null | awk '{printf "%.0f\n", $1*1024}') || {
        warn "Cannot size: $path"
        ((FAILURES += 1))
        return 0
    }
    [[ $size =~ ^[0-9]+$ ]] || {
        ((FAILURES += 1))
        return 0
    }
    ESTIMATED=$((ESTIMATED + size))
    if ((DRY_RUN)); then
        log "Would remove $(human_bytes "$size"): $path"
        return 0
    fi
    if rm -rf -- "$path" && [[ ! -e $path && ! -L $path ]]; then
        REMOVED_ESTIMATE=$((REMOVED_ESTIMATE + size))
        ok "Removed: $path"
    else
        err "Removal incomplete: $path"
        ((FAILURES += 1))
    fi
}

remove_children() {
    local directory=$1 path
    [[ -d $directory ]] || return 0
    reject_symlinks "$directory" || {
        ((FAILURES += 1))
        return 0
    }
    for path in "$directory"/*; do remove_target "$path"; done
}

operation() {
    local description=$1
    shift
    if ((DRY_RUN)); then
        log "Would run: $description"
        return 0
    fi
    if "$@"; then ok "$description"; else
        err "Failed: $description"
        ((FAILURES += 1))
    fi
}

# Operations
main() {
    local argument path snapshots snapshot
    for argument in "$@"; do
        case $argument in
            --dry-run) DRY_RUN=1 ;; --yes | -y) ASSUME_YES=1 ;;
            --skip-browsers) SKIP_BROWSERS=1 ;; --trash) DO_TRASH=1 ;;
            --logs) DO_LOGS=1 ;; --developer) DO_DEVELOPER=1 ;;
            --time-machine) DO_SNAPSHOTS=1 ;; --docker) DO_DOCKER=1 ;;
            --app-state) DO_STATE=1 ;; --ios-backups) DO_IOS=1 ;;
            --xcode-archives) DO_ARCHIVES=1 ;; --repair) DO_REPAIR=1 ;;
            --spotlight) DO_SPOTLIGHT=1 ;; --flush-routes) DO_ROUTES=1 ;;
            --version)
                printf '%s\n' "$SCRIPT_VERSION"
                return
                ;;
            --help | -h)
                usage
                return
                ;;
            *) die "Unknown option: $argument" ;;
        esac
    done
    require_macos
    ((EUID == 0)) || die 'Run with sudo and the explicit Homebrew Bash path.'
    REAL_USER=${SUDO_USER:-}
    [[ -n $REAL_USER && $REAL_USER != root ]] || die 'Run using sudo from your normal account.'
    USER_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
    [[ $USER_HOME == /Users/* && -d $USER_HOME ]] || die 'Cannot identify a normal macOS user home.'
    reject_symlinks "$USER_HOME" || exit 1
    trap summary EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ((!DRY_RUN)); then
        confirm "Clean selected data for $REAL_USER?" || return 0
        umask 077
        lock_acquire /private/var/run/macos-cleanup.lock || exit 1
        LOG_FILE=$(mktemp /private/var/log/macos-cleanup.XXXXXXXX.log)
    fi
    shopt -s nullglob dotglob
    FREE_BEFORE=$(df -k "$USER_HOME" | awk 'NR==2 {print $4}')
    STARTED=1
    step 'Application caches'
    if ((!SKIP_BROWSERS)); then
        remove_children "$USER_HOME/Library/Caches"
    else log 'Preserving general user caches so browser caches are untouched.'; fi
    remove_children /Library/Caches
    if ((DO_LOGS)); then remove_children "$USER_HOME/Library/Logs"; fi
    if ((DO_TRASH)); then remove_children "$USER_HOME/.Trash"; fi
    if ((DO_STATE)); then remove_children "$USER_HOME/Library/Saved Application State"; fi
    if ((DO_IOS)); then remove_children "$USER_HOME/Library/Application Support/MobileSync/Backup"; fi
    if ((DO_ARCHIVES)); then remove_children "$USER_HOME/Library/Developer/Xcode/Archives"; fi
    if ((DO_DEVELOPER)); then
        for path in 'Library/Developer/Xcode/DerivedData' 'Library/Developer/CoreSimulator/Caches' '.npm/_cacache' '.npm/_logs' '.cache/pip' '.cache/pipenv' '.cargo/registry/cache' '.gradle/caches'; do
            remove_children "$USER_HOME/$path"
        done
    fi
    if ((DO_SNAPSHOTS)); then
        snapshots=$(tmutil listlocalsnapshots /) || die 'Cannot list Time Machine snapshots.'
        while IFS= read -r snapshot; do
            [[ $snapshot =~ ^com\.apple\.TimeMachine\.([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})\.local$ ]] || continue
            operation "Delete snapshot ${BASH_REMATCH[1]}" tmutil deletelocalsnapshots "${BASH_REMATCH[1]}"
        done <<< "$snapshots"
    fi
    if ((DO_DOCKER)); then
        require_cmds docker
        operation 'Docker prune for the invoking user' sudo -H -u "$REAL_USER" "$(command -v docker)" system prune -f
    fi
    if ((DO_REPAIR)); then
        operation 'Flush DNS' dscacheutil -flushcache
        operation 'Reload mDNSResponder' killall -HUP mDNSResponder
        operation 'Rebuild Quick Look' sudo -H -u "$REAL_USER" qlmanage -r cache
        operation 'Rebuild Launch Services' sudo -H -u "$REAL_USER" /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user
    fi
    if ((DO_SPOTLIGHT)); then operation 'Rebuild Spotlight' mdutil -E /; fi
    if ((DO_ROUTES)); then operation 'Flush routing table' route -n flush; fi
    ((FAILURES == 0))
}

# Entry point
main "$@"
