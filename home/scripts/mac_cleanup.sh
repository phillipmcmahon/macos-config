#!/usr/bin/env bash
#
# mac_cleanup.sh — Comprehensive macOS cleanup (Sequoia 15 / Tahoe 26+)
# Run: sudo ./mac_cleanup.sh [-y] [--dry-run] [--spotlight]
#
# v2.1.0 — 2026-09-03
#   • iOS device-backup deletion is now opt-in (--ios-backups). Previously
#     section 8 unconditionally wiped ~/Library/Application Support/
#     MobileSync/Backup/ — backups that can be tens of gigabytes and are
#     irreplaceable if the device is lost and iCloud backup is off.
#   • Xcode Archive deletion is now opt-in (--xcode-archives). Archives
#     contain signed, notarised release builds; DerivedData (build cache)
#     is still always cleared.
#
# v2.0.1 — 2026-09-01
#   • Fixed Time Machine snapshot deletion: the date string is now correctly
#     extracted from the snapshot name (previously passed the literal suffix
#     "local" to tmutil deletelocalsnapshots, so no snapshot was ever deleted)
#
# v2.0 — 2026-08-19
#   • Fixed nullglob / nounset interaction that could abort on empty dirs
#   • Temp-file cleanup now skips files < 1 day old to avoid killing
#     in-flight work by other processes
#   • .DS_Store removal limited to -xdev (won't cross into mounted volumes)
#   • Route-table flush moved behind --flush-routes (disruptive on VPNs)
#   • Expanded scope: browser caches, Docker, iOS backups, dev tool caches,
#     Time Machine local snapshots, old system updates, crash reports, etc.
#   • Per-section byte accounting and coloured summary
#

set -Euo pipefail
# nullglob: globs that match nothing expand to nothing (prevents errors
# when a cache directory is already empty).  failglob is intentionally OFF.
shopt -s nullglob

readonly VERSION="2.1.0"

# ──────────── Colours (disabled when stdout is not a terminal) ────────────
if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m'  C_GREEN=$'\033[32m'  C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m' C_RED=$'\033[31m'     C_RESET=$'\033[0m'
else
    C_BOLD="" C_GREEN="" C_YELLOW="" C_CYAN="" C_RED="" C_RESET=""
fi

# ──────────── Usage ────────────
usage() {
    cat <<EOF
${C_BOLD}mac_cleanup.sh v${VERSION}${C_RESET} — Comprehensive macOS cleanup

${C_BOLD}Usage:${C_RESET} sudo $0 [OPTIONS]

${C_BOLD}Options:${C_RESET}
  -y, --yes           Skip confirmation prompt
  --dry-run           Show what would be done without deleting anything
  --spotlight         Rebuild the Spotlight index (slow — hours of CPU)
  --flush-routes      Flush the routing table (can disrupt VPN / active connections)
  --ios-backups       Delete local iOS device backups (opt-in — backups are irreplaceable)
  --xcode-archives    Delete Xcode Archives (opt-in — contains signed release builds)
  --skip-browsers     Do not touch browser caches (Safari, Chrome, Firefox, etc.)
  -h, --help          Show this help
  -v, --version       Print version and exit
EOF
}

# ──────────── Argument parsing ────────────
ASSUME_YES=0
DRY_RUN=0
DO_SPOTLIGHT=0
FLUSH_ROUTES=0
DO_IOS_BACKUPS=0
DO_XCODE_ARCHIVES=0
SKIP_BROWSERS=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes)           ASSUME_YES=1 ;;
        --dry-run)          DRY_RUN=1 ;;
        --spotlight)        DO_SPOTLIGHT=1 ;;
        --flush-routes)     FLUSH_ROUTES=1 ;;
        --ios-backups)      DO_IOS_BACKUPS=1 ;;
        --xcode-archives)   DO_XCODE_ARCHIVES=1 ;;
        --skip-browsers)    SKIP_BROWSERS=1 ;;
        -h|--help)          usage; exit 0 ;;
        -v|--version)       echo "mac_cleanup.sh v${VERSION}"; exit 0 ;;
        *)                  echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

# ──────────── Root check ────────────
if [[ $EUID -ne 0 ]]; then
    echo "${C_RED}Error:${C_RESET} Please run with sudo: sudo $0 $*" >&2
    exit 1
fi

# ──────────── Resolve the real (non-root) user ────────────
REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null \
            | sed 's/^NFSHomeDirectory: //')

if [[ -z "$USER_HOME" || ! -d "$USER_HOME" || "$USER_HOME" == "/" ]]; then
    echo "${C_RED}Error:${C_RESET} Could not resolve a valid home directory for" \
         "'$REAL_USER' (got: '${USER_HOME:-}')" >&2
    exit 1
fi

# ──────────── Logging ────────────
# Log lives in /var/log — outside /tmp and ~/Library/Logs, both of which we clean.
LOG="/var/log/mac_cleanup_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG" 2>/dev/null || {
    # Fallback if /var/log is not writable (shouldn't happen under sudo)
    LOG="$USER_HOME/mac_cleanup_$(date +%Y%m%d_%H%M%S).log"
    touch "$LOG"
}

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
step() { printf '\n' | tee -a "$LOG"; log "${C_CYAN}==> $*${C_RESET}"; }

# ──────────── Byte accounting ────────────
BYTES_FREED=0

# Portable "size of arguments" — works whether targets are files or dirs.
# Returns size in bytes via stdout; returns 0 for non-existent paths.
_sizeof() {
    local total=0
    for p in "$@"; do
        if [[ -e "$p" ]]; then
            # du -sk gives KiB; multiply by 1024
            local kb
            kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}') || continue
            total=$(( total + kb * 1024 ))
        fi
    done
    echo "$total"
}

human_bytes() {
    local b=$1
    if   (( b >= 1073741824 )); then printf '%.1f GB' "$(echo "scale=1; $b/1073741824" | bc)"
    elif (( b >= 1048576 ));    then printf '%.1f MB' "$(echo "scale=1; $b/1048576" | bc)"
    elif (( b >= 1024 ));       then printf '%.1f KB' "$(echo "scale=1; $b/1024" | bc)"
    else                             printf '%d B' "$b"
    fi
}

# ──────────── safe_rm — respects --dry-run, tracks bytes freed ────────────
safe_rm() {
    local sz
    sz=$(_sizeof "$@")
    if [[ "$DRY_RUN" -eq 1 ]]; then
        (( sz > 0 )) && log "  ${C_YELLOW}[dry-run]${C_RESET} would remove ($(human_bytes "$sz")): $*"
    else
        BYTES_FREED=$(( BYTES_FREED + sz ))
        rm -rf "$@" 2>/dev/null || true
    fi
}

# safe_find_rm — wraps find-based deletion with dry-run awareness and accounting.
# Usage: safe_find_rm <path> [find-predicates...]
safe_find_rm() {
    local base="$1"; shift
    if [[ ! -d "$base" ]]; then return 0; fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        local sz
        sz=$(find "$base" -mindepth 1 "$@" -exec du -sk {} + 2>/dev/null \
             | awk '{s+=$1} END{print s+0}')
        sz=$(( sz * 1024 ))
        (( sz > 0 )) && log "  ${C_YELLOW}[dry-run]${C_RESET} would remove ($(human_bytes "$sz")) matching files under $base"
    else
        local sz
        sz=$(find "$base" -mindepth 1 "$@" -exec du -sk {} + 2>/dev/null \
             | awk '{s+=$1} END{print s+0}')
        BYTES_FREED=$(( BYTES_FREED + sz * 1024 ))
        find "$base" -mindepth 1 "$@" -delete 2>/dev/null || true
    fi
}

# ──────────── Trap: always print summary even on error ────────────
cleanup_trap() {
    local rc=$?
    if (( rc != 0 )); then
        log "${C_RED}Script exited with error (code $rc). Partial cleanup may have occurred.${C_RESET}"
    fi
    _print_summary
    exit "$rc"
}
trap cleanup_trap EXIT

# ──────────── Confirmation ────────────
if [[ "$ASSUME_YES" -eq 0 ]]; then
    echo "${C_BOLD}mac_cleanup.sh v${VERSION}${C_RESET}"
    echo "This will clear caches, logs, temp files, Trash, and more for user '${C_GREEN}$REAL_USER${C_RESET}'."
    [[ "$DRY_RUN" -eq 1 ]] && echo "${C_YELLOW}(Running in --dry-run mode — nothing will be deleted.)${C_RESET}"
    read -rp "Type 'yes' to continue: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

# Use df -k (POSIX, works on both BSD and GNU coreutils) for a numeric baseline,
# and df -h for the human-readable display value.
FREE_BEFORE_K=$(df -k / | awk 'NR==2 {print $4}')
FREE_BEFORE_H=$(df -h / | awk 'NR==2 {print $4}')
log "mac_cleanup.sh v${VERSION}"
log "Starting cleanup for user: $REAL_USER (home: $USER_HOME)"
log "Free space before: $FREE_BEFORE_H"
[[ "$DRY_RUN" -eq 1 ]] && log "${C_YELLOW}*** DRY-RUN MODE — no files will be deleted ***${C_RESET}"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  1. USER & SYSTEM CACHES                                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Clearing user caches"
safe_rm "$USER_HOME"/Library/Caches/*

step "Clearing system caches"
safe_rm /Library/Caches/*

step "Clearing Quick Look caches"
if [[ "$DRY_RUN" -eq 0 ]]; then
    sudo -u "$REAL_USER" qlmanage -r cache >/dev/null 2>&1 || true
fi
# Quick Look thumbnail/preview data (com.apple.QuickLook.thumbnailcache)
safe_rm "$USER_HOME"/Library/Caches/com.apple.QuickLook.thumbnailcache

step "Clearing CUPS printer job cache"
safe_rm /var/spool/cups/cache/*
safe_rm /var/spool/cups/tmp/*

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  2. LOGS & DIAGNOSTIC REPORTS                                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Clearing user logs"
safe_rm "$USER_HOME"/Library/Logs/*

step "Clearing system logs"
safe_rm /Library/Logs/*
safe_rm /private/var/log/asl/*.asl

step "Clearing diagnostic / crash reports"
safe_rm /Library/Logs/DiagnosticReports/*
safe_rm "$USER_HOME"/Library/Logs/DiagnosticReports/*
safe_rm /Library/Logs/CrashReporter/*
safe_rm "$USER_HOME"/Library/Logs/CrashReporter/*

step "Clearing CoreDuet knowledge-base logs (usage data)"
safe_rm "$USER_HOME"/Library/CoreDuet/Knowledge/knowledgeC.db-wal
safe_rm "$USER_HOME"/Library/CoreDuet/Knowledge/knowledgeC.db-shm

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  3. TEMPORARY FILES (age-gated to avoid killing in-flight work)         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Clearing temporary files (older than 1 day)"
# Only remove files/dirs older than 1 day to avoid disrupting running processes.
safe_find_rm /private/var/tmp  -mtime +0
safe_find_rm /private/tmp      -mtime +0
safe_find_rm /tmp              -mtime +0

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  4. TRASH, .DS_Store, ._ resource forks                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Emptying Trash"
safe_rm "$USER_HOME"/.Trash/*
# Also clear the volume-level Trashes for the boot volume
safe_rm /Volumes/*/.Trashes/"$(id -u "$REAL_USER")"/* 2>/dev/null

step "Removing .DS_Store files (home folder, same filesystem only)"
if [[ "$DRY_RUN" -eq 0 ]]; then
    # -xdev prevents crossing into mounted volumes / Time Machine snapshots
    find "$USER_HOME" -xdev -name ".DS_Store" -delete 2>/dev/null || true
else
    local_count=$(find "$USER_HOME" -xdev -name ".DS_Store" 2>/dev/null | wc -l | tr -d ' ')
    log "  ${C_YELLOW}[dry-run]${C_RESET} would remove $local_count .DS_Store files"
fi

step "Removing macOS resource-fork files (._*) from home"
if [[ "$DRY_RUN" -eq 0 ]]; then
    find "$USER_HOME" -xdev -name "._*" -not -path "$USER_HOME/Library/*" -delete 2>/dev/null || true
else
    local_count=$(find "$USER_HOME" -xdev -name "._*" -not -path "$USER_HOME/Library/*" 2>/dev/null | wc -l | tr -d ' ')
    log "  ${C_YELLOW}[dry-run]${C_RESET} would remove $local_count ._ resource-fork files"
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  5. BROWSER CACHES (opt-out via --skip-browsers)                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
if [[ "$SKIP_BROWSERS" -eq 0 ]]; then
    step "Clearing Safari caches"
    safe_rm "$USER_HOME"/Library/Caches/com.apple.Safari
    safe_rm "$USER_HOME"/Library/Caches/com.apple.Safari.SearchHelper
    safe_rm "$USER_HOME"/Library/Caches/com.apple.WebKit.PluginProcess
    safe_rm "$USER_HOME"/Library/Caches/Metadata/Safari

    step "Clearing Google Chrome caches"
    safe_rm "$USER_HOME"/Library/Caches/Google/Chrome
    # Per-profile GPU / shader / code caches (leaves bookmarks, history, etc. intact)
    for profile_dir in "$USER_HOME"/Library/Application\ Support/Google/Chrome/*/; do
        [[ -d "$profile_dir" ]] || continue
        safe_rm "${profile_dir}Cache"
        safe_rm "${profile_dir}Code Cache"
        safe_rm "${profile_dir}GPUCache"
        safe_rm "${profile_dir}Service Worker/CacheStorage"
    done

    step "Clearing Firefox caches"
    safe_rm "$USER_HOME"/Library/Caches/Firefox
    # Per-profile cache2 directories
    for cache2 in "$USER_HOME"/Library/Caches/Firefox/Profiles/*/cache2; do
        [[ -d "$cache2" ]] && safe_rm "$cache2"/*
    done

    step "Clearing Microsoft Edge caches"
    safe_rm "$USER_HOME"/Library/Caches/com.microsoft.edgemac
    for profile_dir in "$USER_HOME"/Library/Application\ Support/Microsoft\ Edge/*/; do
        [[ -d "$profile_dir" ]] || continue
        safe_rm "${profile_dir}Cache"
        safe_rm "${profile_dir}Code Cache"
        safe_rm "${profile_dir}GPUCache"
    done

    step "Clearing Brave Browser caches"
    safe_rm "$USER_HOME"/Library/Caches/BraveSoftware
    for profile_dir in "$USER_HOME"/Library/Application\ Support/BraveSoftware/Brave-Browser/*/; do
        [[ -d "$profile_dir" ]] || continue
        safe_rm "${profile_dir}Cache"
        safe_rm "${profile_dir}Code Cache"
        safe_rm "${profile_dir}GPUCache"
    done

    step "Clearing Arc Browser caches"
    safe_rm "$USER_HOME"/Library/Caches/company.thebrowser.Browser
else
    step "Browser cache cleanup skipped (--skip-browsers)"
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  6. APP-SPECIFIC CACHES & JUNK                                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Clearing Xcode derived data (if present)"
safe_rm "$USER_HOME"/Library/Developer/Xcode/DerivedData/*
if (( DO_XCODE_ARCHIVES )); then
    step "Clearing Xcode Archives (--xcode-archives)"
    safe_rm "$USER_HOME"/Library/Developer/Xcode/Archives/*
else
    step "Xcode Archives skipped (pass --xcode-archives to include)"
fi
safe_rm "$USER_HOME"/Library/Developer/Xcode/iOS\ Device\ Logs/*
safe_rm "$USER_HOME"/Library/Developer/CoreSimulator/Caches/*

step "Clearing Homebrew cache (if present)"
if [[ "$DRY_RUN" -eq 0 ]] && command -v brew >/dev/null 2>&1; then
    sudo -u "$REAL_USER" brew cleanup --prune=all -s >/dev/null 2>&1 || true
fi
safe_rm "$USER_HOME"/Library/Caches/Homebrew/*

step "Clearing developer tool caches"
# npm
safe_rm "$USER_HOME"/.npm/_cacache
safe_rm "$USER_HOME"/.npm/_logs
# Yarn (v1 + Berry)
safe_rm "$USER_HOME"/Library/Caches/Yarn
safe_rm "$USER_HOME"/.yarn/cache
# pnpm
safe_rm "$USER_HOME"/Library/pnpm/store
# pip / pipenv
safe_rm "$USER_HOME"/Library/Caches/pip
safe_rm "$USER_HOME"/.cache/pip
safe_rm "$USER_HOME"/.cache/pipenv
# Composer (PHP)
safe_rm "$USER_HOME"/.composer/cache
# Go module cache
if command -v go >/dev/null 2>&1 && [[ "$DRY_RUN" -eq 0 ]]; then
    sudo -u "$REAL_USER" go clean -cache 2>/dev/null || true
fi
safe_rm "$USER_HOME"/Library/Caches/go-build
# Cargo (Rust)
safe_rm "$USER_HOME"/.cargo/registry/cache
# CocoaPods
safe_rm "$USER_HOME"/Library/Caches/CocoaPods
# Gradle
safe_rm "$USER_HOME"/.gradle/caches
# Maven
safe_rm "$USER_HOME"/.m2/repository
# Ruby gems / Bundler
safe_rm "$USER_HOME"/.gem/cache
safe_rm "$USER_HOME"/.bundle/cache
# NuGet (.NET)
safe_rm "$USER_HOME"/.nuget/packages

step "Clearing Saved Application State (window restore data)"
safe_rm "$USER_HOME"/Library/Saved\ Application\ State/*

step "Clearing application-specific caches"
# Spotify
safe_rm "$USER_HOME"/Library/Caches/com.spotify.client
safe_rm "$USER_HOME"/Library/Application\ Support/Spotify/PersistentCache
# Slack
safe_rm "$USER_HOME"/Library/Application\ Support/Slack/Cache
safe_rm "$USER_HOME"/Library/Application\ Support/Slack/Code\ Cache
safe_rm "$USER_HOME"/Library/Application\ Support/Slack/GPUCache
safe_rm "$USER_HOME"/Library/Application\ Support/Slack/Service\ Worker/CacheStorage
# Discord
safe_rm "$USER_HOME"/Library/Application\ Support/discord/Cache
safe_rm "$USER_HOME"/Library/Application\ Support/discord/Code\ Cache
safe_rm "$USER_HOME"/Library/Application\ Support/discord/GPUCache
# VS Code
safe_rm "$USER_HOME"/Library/Application\ Support/Code/Cache
safe_rm "$USER_HOME"/Library/Application\ Support/Code/CachedData
safe_rm "$USER_HOME"/Library/Application\ Support/Code/CachedExtensions
safe_rm "$USER_HOME"/Library/Application\ Support/Code/CachedExtensionVSIXs
safe_rm "$USER_HOME"/Library/Application\ Support/Code/Code\ Cache
# Adobe Creative Cloud common caches
safe_rm "$USER_HOME"/Library/Caches/Adobe
safe_rm /Library/Caches/Adobe
# Zoom
safe_rm "$USER_HOME"/Library/Application\ Support/zoom.us/data
# Microsoft Teams
safe_rm "$USER_HOME"/Library/Application\ Support/Microsoft/Teams/Cache
safe_rm "$USER_HOME"/Library/Application\ Support/Microsoft/Teams/GPUCache
# Electron / generic Electron app caches
safe_rm "$USER_HOME"/Library/Application\ Support/CrashPlan/cache
# Mail downloads
safe_rm "$USER_HOME"/Library/Containers/com.apple.mail/Data/Library/Mail\ Downloads/*

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  7. DOCKER (if installed)                                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Cleaning Docker (if present)"
if command -v docker >/dev/null 2>&1 && [[ "$DRY_RUN" -eq 0 ]]; then
    # Only prune if the Docker daemon is actually running
    if docker info >/dev/null 2>&1; then
        log "  Pruning dangling images, stopped containers, build cache, unused networks"
        docker system prune -f >/dev/null 2>&1 || true
    else
        log "  Docker installed but daemon not running — skipping"
    fi
elif command -v docker >/dev/null 2>&1 && [[ "$DRY_RUN" -eq 1 ]]; then
    log "  ${C_YELLOW}[dry-run]${C_RESET} would run: docker system prune -f"
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  8. OLD iOS DEVICE BACKUPS (opt-in: --ios-backups)                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
if (( DO_IOS_BACKUPS )); then
    step "Clearing old iOS device backups (--ios-backups)"
    BACKUP_DIR="$USER_HOME/Library/Application Support/MobileSync/Backup"
    if [[ -d "$BACKUP_DIR" ]]; then
        backup_sz=$(_sizeof "$BACKUP_DIR")
        if (( backup_sz > 0 )); then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "  ${C_YELLOW}[dry-run]${C_RESET} would remove iOS backups ($(human_bytes "$backup_sz")): $BACKUP_DIR"
            else
                log "  ${C_YELLOW}Warning:${C_RESET} Removing ALL local iOS backups ($(human_bytes "$backup_sz"))"
                log "  (iCloud backups are not affected)"
                BYTES_FREED=$(( BYTES_FREED + backup_sz ))
                rm -rf "${BACKUP_DIR:?}"/* 2>/dev/null || true
            fi
        fi
    fi
else
    step "iOS device backups skipped (pass --ios-backups to include)"
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  9. TIME MACHINE LOCAL SNAPSHOTS                                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Removing Time Machine local snapshots"
if [[ "$DRY_RUN" -eq 0 ]]; then
    # tmutil listlocalsnapshots returns lines like
    #   com.apple.TimeMachine.2026-08-19-091500.local
    while IFS= read -r snap; do
        [[ -z "$snap" ]] && continue
        # tmutil deletelocalsnapshots expects only the date portion
        # (e.g. 2026-08-19-091500), so strip the reverse-DNS prefix and
        # the trailing ".local" from the snapshot name.
        snap_date="${snap#com.apple.TimeMachine.}"
        snap_date="${snap_date%.local}"
        tmutil deletelocalsnapshots "$snap_date" 2>/dev/null || true
    done < <(tmutil listlocalsnapshots / 2>/dev/null | grep 'com.apple.TimeMachine')
else
    snap_count=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)
    log "  ${C_YELLOW}[dry-run]${C_RESET} would remove $snap_count local Time Machine snapshot(s)"
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  10. SYSTEM UPDATE DOWNLOADS                                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Clearing downloaded macOS software updates"
safe_rm /Library/Updates/*
safe_rm /macOS\ Install\ Data 2>/dev/null

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  11. DNS & NETWORK                                                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Flushing DNS cache"
if [[ "$DRY_RUN" -eq 0 ]]; then
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
fi

if [[ "$FLUSH_ROUTES" -eq 1 ]]; then
    step "Flushing routing table (--flush-routes)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        route -n flush >/dev/null 2>&1 || true
    fi
else
    step "Route-table flush skipped (pass --flush-routes to enable)"
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  12. FONT CACHES                                                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Rebuilding font caches (skipped if atsutil is absent)"
if command -v atsutil >/dev/null 2>&1 && [[ "$DRY_RUN" -eq 0 ]]; then
    atsutil databases -remove >/dev/null 2>&1 || true
    atsutil server -shutdown  >/dev/null 2>&1 || true
    atsutil server -ping      >/dev/null 2>&1 || true
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  13. LAUNCH SERVICES & ICON CACHES                                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Rebuilding Launch Services database"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]] && [[ "$DRY_RUN" -eq 0 ]]; then
    "$LSREGISTER" -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
fi

step "Clearing icon services cache"
safe_rm /Library/Caches/com.apple.iconservices.store
safe_rm "$USER_HOME"/Library/Caches/com.apple.iconservices.store

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  14. PERIODIC MAINTENANCE SCRIPTS                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Running periodic maintenance scripts (skipped if periodic is absent)"
if command -v periodic >/dev/null 2>&1 && [[ "$DRY_RUN" -eq 0 ]]; then
    periodic daily weekly monthly 2>/dev/null || true
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  15. MEMORY PURGE                                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Purging inactive memory"
if command -v purge >/dev/null 2>&1 && [[ "$DRY_RUN" -eq 0 ]]; then
    purge 2>/dev/null || true
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  16. SPOTLIGHT (opt-in via --spotlight)                                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
if [[ "$DO_SPOTLIGHT" -eq 1 ]]; then
    step "Rebuilding Spotlight index (this will take a while)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        mdutil -E / >/dev/null 2>&1 || true
    fi
else
    step "Spotlight rebuild skipped (pass --spotlight to enable)"
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  17. RESTART UI SERVICES                                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
step "Restarting Dock and Finder"
if [[ "$DRY_RUN" -eq 0 ]]; then
    killall Dock   2>/dev/null || true
    killall Finder 2>/dev/null || true
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  SUMMARY                                                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
_print_summary() {
    local free_after_h
    free_after_h=$(df -h / | awk 'NR==2 {print $4}')
    echo "" | tee -a "$LOG"
    log "${C_GREEN}════════════════════════════════════════${C_RESET}"
    log "${C_GREEN}  Cleanup complete.${C_RESET}"
    log "  Free space before : $FREE_BEFORE_H"
    log "  Free space after  : $free_after_h"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  Estimated reclaimable : ${C_YELLOW}$(human_bytes $BYTES_FREED)${C_RESET}"
    else
        log "  Bytes freed (tracked): ${C_GREEN}$(human_bytes $BYTES_FREED)${C_RESET}"
    fi
    log "  Log saved to: $LOG"
    log "${C_GREEN}════════════════════════════════════════${C_RESET}"
    log "A reboot is recommended to fully reclaim memory and rebuild system caches."
}
# _print_summary is called by the EXIT trap — no explicit call needed here.
