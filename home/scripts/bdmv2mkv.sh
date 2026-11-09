#!/usr/bin/env bash
#
# bdmv2mkv.sh - Batch-remux Blu-ray BDMV folders into MKV (main feature only)
#               using MakeMKV's command-line tool (makemkvcon). No re-encoding.
#
# VERSION: 1.2.1
#
# CHANGELOG
#   1.2.1 (2026-11-09)
#     - Logs the MakeMKV version once per run, read from makemkvcon's own start-up
#       message (MSG 1005) - makemkvcon is not run an extra time.
#     - When the title scan fails and the version is 2.0.0, says this is MakeMKV
#       2.0.0's known crash on unencrypted BDMV folders/ISOs and how to go back to
#       1.18.4. (Downgrading to 1.18.4 fixed it on the user's Mac.)
#     - Evaluation-prompt (MSG 5053) message reworded: it no longer suggests the
#       prompt caused the failure.
#   1.2.0 (2026-11-09)
#     - Java check: when no JDK is registered with macOS (/usr/libexec/java_home)
#       and app_Java is not set, look for a Homebrew JDK (keg-only, so not on PATH:
#       /opt/homebrew/opt/openjdk@17, then any openjdk*, also under /usr/local)
#       or a non-stub java on PATH. If one exists, say so and print the exact
#       app_Java line / MakeMKV preference to point MakeMKV at it, instead of the
#       misleading "No Java runtime found".
#     - Failed title scan: when makemkvcon is killed by a signal (exit > 128, e.g.
#       139 = segmentation fault), say it crashed and name the signal. If its
#       output contains MSG 5053 (MakeMKV asking to start its 30-day evaluation,
#       which makemkvcon cannot answer), explain how to accept it or register in
#       MakeMKV.app first.
#   1.1.0 (2026-11-09)
#     - Main-feature selection now prefers MakeMKV's BD-Java playlist detection:
#       a title flagged FPL_MainFeature (TINFO attribute 49, or "(FPL_MainFeature)"
#       in attribute 30) is chosen over the longest title. MakeMKV only sets this
#       flag when it can run the disc's Java code, i.e. a Java runtime is
#       installed and found by MakeMKV (auto-detected, or the app_Java setting in
#       ~/.MakeMKV/settings.conf / MakeMKV Preferences > Protection > Custom Java
#       executable location). Without Java the script falls back to longest title.
#     - New pre-flight Java report (never fatal): shows the Java MakeMKV is likely
#       to use and warns when none is found or the JDK is >= 25 (reported failing
#       on macOS; JDK 17 reported working). Requirement: Java runtime (e.g.
#       `brew install openjdk@17`) for discs with fake-playlist protection.
#     - Per disc, logs the selection method, the Java runtime MakeMKV reported
#       (MSG 3344), and warns on suspected fake-playlist discs (>= N titles within
#       a few seconds of the longest) that MakeMKV did not flag, including a
#       missing BDMV/JAR folder in the backup.
#     - New -s/--strict option: fail (not guess) such suspected discs.
#     - New tunables BDMV2MKV_OBFUSCATION_THRESHOLD (default 5) and
#       BDMV2MKV_OBFUSCATION_WINDOW (seconds, default 5).
#     - Added optional use of /usr/libexec/java_home and java (if present).
#   1.0.0 (2026-11-09)
#     - Initial release.
#     - Recursively discovers BDMV disc folders (BDMV/ with index.bdmv + STREAM/)
#       under <source_dir>; prunes Synology @eaDir, recycle bins and macOS
#       metadata folders; never follows symlinks; NUL-safe for odd file names.
#     - Picks the longest title per disc (tie-break: largest size, then lowest id)
#       via `makemkvcon -r info file:<disc root>` and remuxes only that title via
#       `makemkvcon -r mkv file:<disc root> <id> <dir>`.
#     - One output subfolder per disc under <dest_dir>, named after the disc root
#       folder; same-name collisions (case-insensitive) get " (2)", " (3)", ...
#       assigned in sorted path order, so the mapping is deterministic.
#     - Skips discs whose output folder already contains an .mkv; -f/--force
#       replaces them. Output is written to a mktemp dir inside <dest_dir> and
#       moved into place only after success (no partial output left behind).
#     - -n/--dry-run lists discs, chosen titles and actions without writing.
#     - Pre-flight checks, per-disc free-space check, lock against concurrent
#       runs (stale locks are reported, never auto-removed), log file in
#       <dest_dir>, summary and non-zero exit if any disc failed.
#     Requirements: macOS (Apple Silicon or Intel) with Homebrew, Bash >= 4
#       (`brew install bash`), GNU coreutils (`brew install coreutils`, provides
#       gsort), MakeMKV with a valid licence or current beta key. Also uses the
#       system find, awk, df, mktemp, mv, rm, mkdir, rmdir, date.
#
# Usage: bdmv2mkv.sh [-f|--force] [-n|--dry-run] [-s|--strict] [-h|--help] [-V|--version] <source_dir> <dest_dir>

# ---- Bash version guard (kept Bash 3.2-compatible so macOS /bin/bash can print it)
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERROR: Bash >= 4 is required (found ${BASH_VERSION:-unknown})." >&2
    echo "       Install with 'brew install bash' and run via '#!/usr/bin/env bash' with Homebrew's bin first in PATH." >&2
    exit 2
fi

set -euo pipefail
shopt -s nullglob

readonly VERSION="1.2.1"
readonly PROG="${0##*/}"

# ---- Tunables (environment overrides)
# Minimum title length in seconds passed to BOTH `info` and `mkv`, so title ids match.
MIN_LENGTH="${BDMV2MKV_MINLENGTH:-120}"
# MakeMKV read cache in MB (1024 is MakeMKV's recommendation for Blu-ray).
CACHE_MB="${BDMV2MKV_CACHE_MB:-1024}"
# Minimum free space (GB) required on dest before starting at all.
MIN_FREE_GB="${BDMV2MKV_MIN_FREE_GB:-5}"
# Extra headroom (%) on top of the title size for the per-disc space check.
SPACE_HEADROOM_PCT="${BDMV2MKV_SPACE_HEADROOM_PCT:-5}"
# Suspected fake-playlist disc: at least THRESHOLD titles within WINDOW seconds
# of the longest title, and MakeMKV flagged none as FPL_MainFeature.
OBFUSCATION_THRESHOLD="${BDMV2MKV_OBFUSCATION_THRESHOLD:-5}"
OBFUSCATION_WINDOW="${BDMV2MKV_OBFUSCATION_WINDOW:-5}"

# Folder names pruned during discovery (NAS/OS metadata, recycle bins, our temp dirs).
# shellcheck disable=SC2016  # literal '$RECYCLE.BIN' is intended
readonly PRUNE_NAMES=(
    '@eaDir' '#recycle' '#snapshot' '@Recycle' '@Recently-Snapshot' '.@__thumb'
    '.Trashes' '.Spotlight-V100' '.fseventsd' '.TemporaryItems' '.DocumentRevisions-V100'
    '.AppleDouble' '$RECYCLE.BIN' 'System Volume Information' 'lost+found'
    '.bdmv2mkv-tmp.*' '.bdmv2mkv-old.*' '.bdmv2mkv.lock'
)

# ---- State
FORCE=0
DRY_RUN=0
STRICT=0
SRC=""
DEST=""
LOG_FILE=""
LOCK_DIR=""
LOCK_HELD=0
SORT_BIN=""
MAKEMKVCON_BIN=""
MKV_VERSION_LOGGED=0   # MakeMKV version (MSG 1005) is logged once per run
TEMP_DIRS=()
CONVERTED=()
SKIPPED=()
FAILED=()
INTERRUPTED=0

# ---- Logging
log() {
    local level="$1"; shift
    local line
    printf -v line '%s [%-5s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
    printf '%s\n' "$line" >&2
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    fi
}
info()  { log INFO "$@"; }
warn()  { log WARN "$@"; }
error() { log ERROR "$@"; }
die()   { error "$@"; exit 1; }

usage() {
    cat <<EOF
$PROG $VERSION - batch-remux BDMV folders to MKV (main feature only) with makemkvcon

Usage: $PROG [-f|--force] [-n|--dry-run] [-s|--strict] [-h|--help] [-V|--version] <source_dir> <dest_dir>

  <source_dir>   Directory searched recursively for Blu-ray BDMV folders
                 (may itself be a disc root or a BDMV folder).
  <dest_dir>     Output directory; one subfolder per disc is created here.

Options:
  -f, --force    Replace existing MKVs in a disc's output folder (default: skip).
  -n, --dry-run  Show what would be done (runs read-only 'makemkvcon info').
  -s, --strict   Fail discs that look like fake-playlist discs when MakeMKV's
                 Java detection did not flag a main feature (default: warn and
                 use the longest title).
  -h, --help     Show this help.
  -V, --version  Show version.

Environment:
  MAKEMKVCON                    Path to makemkvcon (default: PATH, then
                                /Applications/MakeMKV.app/Contents/MacOS/makemkvcon)
  BDMV2MKV_MINLENGTH            Minimum title length in seconds (default 120)
  BDMV2MKV_CACHE_MB             makemkvcon --cache size in MB (default 1024)
  BDMV2MKV_MIN_FREE_GB          Required free space on dest to start (default 5)
  BDMV2MKV_SPACE_HEADROOM_PCT   Headroom over title size for space check (default 5)
  BDMV2MKV_OBFUSCATION_THRESHOLD  Titles near the longest that flag a suspected
                                  fake-playlist disc (default 5)
  BDMV2MKV_OBFUSCATION_WINDOW     "Near" means within this many seconds (default 5)

Main feature = title MakeMKV flags FPL_MainFeature (needs Java, see README),
otherwise the longest title.
EOF
}

# ---- Cleanup / signals
cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    local d
    for d in "${TEMP_DIRS[@]}"; do
        if [[ -n "$d" && -e "$d" && ! -L "$d" ]]; then
            rm -rf "$d" 2>/dev/null || warn "Could not remove temp dir: $d"
        fi
    done
    # Release the lock last, and only if we created it.
    if (( LOCK_HELD )) && [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
        rm -f "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || warn "Could not remove lock dir: $LOCK_DIR"
    fi
    exit "$rc"
}

on_signal() {
    INTERRUPTED=1
    error "Interrupted by signal ($1); cleaning up."
    case "$1" in
        INT) exit 130 ;;
        TERM) exit 143 ;;
        *) exit 129 ;;
    esac
}

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

untrack_temp() {
    local target="$1" i
    for i in "${!TEMP_DIRS[@]}"; do
        [[ "${TEMP_DIRS[$i]}" == "$target" ]] && unset 'TEMP_DIRS[$i]'
    done
    return 0
}

# ---- Helpers
strip_trailing_slashes() {
    local p="$1"
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    printf '%s' "$p"
}

# Absolute, symlink-resolved path of an existing directory (no realpath needed).
abs_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

is_positive_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Resolve a GNU tool: prefer the Homebrew g-prefixed name, else accept the
# unprefixed one only if it really is GNU (e.g. coreutils gnubin in PATH, Linux).
find_gnu_tool() {
    local name="$1" cand
    for cand in "g$name" "$name"; do
        if command -v "$cand" >/dev/null 2>&1 && "$cand" --version 2>/dev/null | head -n 1 | grep -q 'GNU'; then
            command -v "$cand"
            return 0
        fi
    done
    return 1
}

find_makemkvcon() {
    if [[ -n "${MAKEMKVCON:-}" ]]; then
        [[ -x "$MAKEMKVCON" && ! -d "$MAKEMKVCON" ]] || return 1
        printf '%s' "$MAKEMKVCON"; return 0
    fi
    if command -v makemkvcon >/dev/null 2>&1; then
        command -v makemkvcon; return 0
    fi
    local app="/Applications/MakeMKV.app/Contents/MacOS/makemkvcon"
    [[ -x "$app" ]] && { printf '%s' "$app"; return 0; }
    return 1
}

# Available space on the filesystem holding $1, in KiB (POSIX df -P -k; no "--").
free_kib() {
    df -P -k "$1" | awk 'NR==2 { print $4 }'
}

# ---- Argument parsing
parse_args() {
    local positional=()
    while (( $# )); do
        case "$1" in
            -f|--force) FORCE=1 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -s|--strict) STRICT=1 ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
            --) shift; positional+=("$@"); break ;;
            -?*) usage >&2; echo >&2; die "Unknown option: $1" ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    if (( ${#positional[@]} != 2 )); then
        usage >&2
        exit 2
    fi
    SRC="$(strip_trailing_slashes "${positional[0]}")"
    DEST="$(strip_trailing_slashes "${positional[1]}")"
}

# ---- Pre-flight
preflight() {
    local tool missing=()
    # Exactly the external commands this script calls (besides makemkvcon/gsort).
    for tool in find awk df mktemp mv rm mkdir rmdir date head tail grep sed; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    (( ${#missing[@]} == 0 )) || die "Missing required commands: ${missing[*]}"

    SORT_BIN="$(find_gnu_tool sort)" \
        || die "GNU sort not found. Install GNU coreutils: brew install coreutils (provides gsort)."

    MAKEMKVCON_BIN="$(find_makemkvcon)" \
        || die "makemkvcon not found. Install MakeMKV (/Applications/MakeMKV.app) or set MAKEMKVCON=/path/to/makemkvcon."

    for tool in MIN_LENGTH CACHE_MB MIN_FREE_GB SPACE_HEADROOM_PCT OBFUSCATION_THRESHOLD OBFUSCATION_WINDOW; do
        is_positive_int "${!tool}" || die "$tool must be a non-negative integer (got '${!tool}')."
    done

    [[ -n "$SRC" && -d "$SRC" ]] || die "Source directory does not exist: $SRC"
    [[ -r "$SRC" && -x "$SRC" ]] || die "Source directory is not readable: $SRC"
    SRC="$(abs_dir "$SRC")" || die "Cannot resolve source directory."

    if [[ ! -e "$DEST" ]]; then
        if (( DRY_RUN )); then
            info "[dry-run] Destination does not exist and would be created: $DEST"
            return 0
        fi
        mkdir -p "$DEST" || die "Cannot create destination directory: $DEST"
    fi
    [[ -d "$DEST" ]] || die "Destination is not a directory: $DEST"
    [[ -w "$DEST" && -x "$DEST" ]] || die "Destination directory is not writable: $DEST"
    DEST="$(abs_dir "$DEST")" || die "Cannot resolve destination directory."

    [[ "$DEST" != "$SRC" ]] || die "Source and destination must differ."

    local avail need
    avail="$(free_kib "$DEST")"
    is_positive_int "$avail" || die "Could not determine free space on $DEST."
    need=$(( MIN_FREE_GB * 1024 * 1024 ))
    (( avail >= need )) || die "Only $(( avail / 1024 / 1024 )) GB free on $DEST; need at least $MIN_FREE_GB GB."
}

acquire_lock() {
    LOCK_DIR="$DEST/.bdmv2mkv.lock"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=1
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        return 0
    fi
    local pid="" state="unknown"
    [[ -r "$LOCK_DIR/pid" ]] && pid="$(<"$LOCK_DIR/pid")"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        if kill -0 "$pid" 2>/dev/null; then state="running (PID $pid)"; else state="stale (PID $pid is not running)"; fi
    fi
    error "Another run appears to be using $DEST - lock is $state."
    error "If you are sure no other $PROG is running, remove the lock manually with:"
    error "  rm -rf $(printf '%q' "$LOCK_DIR")"
    exit 3
}

# ---- Discovery
# Prints NUL-separated disc roots (parent of each valid BDMV dir), sorted.
discover_discs() {
    local prune=() n first=1
    for n in "${PRUNE_NAMES[@]}"; do
        if (( first )); then first=0; else prune+=(-o); fi
        prune+=(-name "$n")
    done
    # -P: never follow symlinks. Valid BDMV dirs are printed and pruned (no descent).
    find -P "$SRC" \( -type d \( "${prune[@]}" \) -prune \) \
        -o \( -type d -name BDMV -print0 -prune \) 2>/dev/null \
    | while IFS= read -r -d '' bdmv; do
        [[ -f "$bdmv/index.bdmv" && -d "$bdmv/STREAM" && ! -L "$bdmv/STREAM" ]] || continue
        root="${bdmv%/BDMV}"
        [[ -n "$root" ]] || root="/"
        # Never treat anything inside dest as a source disc.
        [[ "$root/" == "$DEST/"* ]] && continue
        printf '%s\0' "$root"
    done | LC_ALL=C "$SORT_BIN" -z -u
}

# ---- MakeMKV
# Picks the main feature of disc root $1 from `makemkvcon -r info` output.
#
# Selection order:
#   1. Titles MakeMKV flags as the main feature via its BD-Java playlist
#      detection: TINFO attribute 49 (ap_iaComment) == "FPL_MainFeature", or
#      "(FPL_MainFeature)" in attribute 30 (ap_iaTreeInfo). MakeMKV only sets
#      this when it ran the disc's Java code (needs a Java runtime) on a disc
#      using fake-playlist protection. If several are flagged, the longest
#      flagged title wins.
#   2. Otherwise the longest title (tie-break: largest size, then lowest id).
#
# Sets: SEL_ID SEL_SECS SEL_BYTES SEL_DUR SEL_METHOD (fpl|longest)
#       SEL_JAVA (runtime path from MSG:3344, or empty)
#       SEL_MKVVER (MakeMKV version from MSG:1005, e.g. 1.18.4, or empty)
#       SEL_SUSPECT (number of titles within OBFUSCATION_WINDOW s of the longest)
select_main_title() {
    local root="$1" infolog="$2"
    local line id secs bytes
    declare -A dur=() size=() fpl=()
    SEL_ID=""; SEL_SECS=0; SEL_BYTES=0; SEL_DUR=""; SEL_METHOD="longest"; SEL_JAVA=""; SEL_SUSPECT=0; SEL_MKVVER=""

    local rc=0
    "$MAKEMKVCON_BIN" -r --cache="$CACHE_MB" --minlength="$MIN_LENGTH" info "file:$root" >"$infolog" 2>&1 || rc=$?

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^TINFO:([0-9]+),9,[0-9]+,\"([0-9]+):([0-9]{1,2}):([0-9]{1,2})\"$ ]]; then
            id="${BASH_REMATCH[1]}"
            dur[$id]=$(( 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]} ))
        elif [[ "$line" =~ ^TINFO:([0-9]+),11,[0-9]+,\"([0-9]+)\"$ ]]; then
            size[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^TINFO:([0-9]+),49,[0-9]+,\"FPL_MainFeature\"$ ]]; then
            fpl[${BASH_REMATCH[1]}]=1
        elif [[ "$line" =~ ^TINFO:([0-9]+),30,[0-9]+,\".*\(FPL_MainFeature\)\"$ ]]; then
            fpl[${BASH_REMATCH[1]}]=1
        elif [[ "$line" =~ ^MSG:3344,[0-9]+,[0-9]+,\"[^\"]*\",\"[^\"]*\",\"(.*)\"$ ]]; then
            SEL_JAVA="${BASH_REMATCH[1]}"
        elif [[ -z "$SEL_MKVVER" && "$line" =~ ^MSG:1005,[0-9]+,[0-9]+,\"MakeMKV\ v([0-9]+(\.[0-9]+)*) ]]; then
            # e.g. MSG:1005,0,1,"MakeMKV v1.18.4 darwin(arm64-release) started",...
            SEL_MKVVER="${BASH_REMATCH[1]}"
        fi
    done <"$infolog"

    if [[ -n "$SEL_MKVVER" ]] && (( MKV_VERSION_LOGGED == 0 )); then
        info "  MakeMKV version: $SEL_MKVVER"
        MKV_VERSION_LOGGED=1
    fi

    if (( ${#dur[@]} == 0 )); then
        if (( rc > 128 )); then
            error "  makemkvcon crashed (exit $rc = signal $(( rc - 128 ))) before reporting any titles. Last messages:"
        else
            error "  makemkvcon info found no titles (exit $rc). Last messages:"
        fi
        grep '^MSG:' "$infolog" | tail -n 5 | while IFS= read -r line; do error "    $line"; done || true
        # MakeMKV 2.0.0 (20 Sep 2026) segfaults on unencrypted BDMV folders/ISOs
        # (no AACS directory); 1.18.4 works. Confirmed on the user's Mac.
        if [[ "$SEL_MKVVER" == 2.0.0 ]]; then
            error "  MakeMKV 2.0.0 has a known bug: it crashes on unencrypted Blu-ray folders and ISOs (no AACS"
            error "  directory). Install 1.18.4 from https://makemkv.com/download/old/ (settings and key are kept)"
            error "  and turn off update checks in MakeMKV > Preferences until a fixed release is out."
        fi
        # MSG:5053 = MakeMKV asking to start its 30-day evaluation, which makemkvcon
        # cannot answer. Mention it, but do not present it as the cause of a crash.
        if grep -q '^MSG:5053,' "$infolog"; then
            warn "  MakeMKV's evaluation period has not been started (makemkvcon cannot answer that prompt)."
            warn "  Start it once in MakeMKV.app (File > Open files, accept the evaluation) or register a key"
            warn "  (Help > Register)."
        fi
        return 1
    fi

    # Candidate set: FPL-flagged titles (that have a duration) if any, else all.
    local cands=()
    for id in "${!fpl[@]}"; do
        if [[ -n "${dur[$id]:-}" ]]; then cands+=("$id"); fi
    done
    if (( ${#cands[@]} > 0 )); then
        SEL_METHOD="fpl"
    else
        cands=("${!dur[@]}")
    fi

    for id in "${cands[@]}"; do
        secs="${dur[$id]}"; bytes="${size[$id]:-0}"
        if [[ -z "$SEL_ID" ]] \
           || (( secs > SEL_SECS )) \
           || (( secs == SEL_SECS && bytes > SEL_BYTES )) \
           || (( secs == SEL_SECS && bytes == SEL_BYTES && id < SEL_ID )); then
            SEL_ID="$id"; SEL_SECS="$secs"; SEL_BYTES="$bytes"
        fi
    done

    # Obfuscation heuristic: many titles of (nearly) the same length as the longest.
    local maxs=0
    for id in "${!dur[@]}"; do
        if (( dur[$id] > maxs )); then maxs="${dur[$id]}"; fi
    done
    for id in "${!dur[@]}"; do
        if (( maxs - dur[$id] <= OBFUSCATION_WINDOW )); then SEL_SUSPECT=$(( SEL_SUSPECT + 1 )); fi
    done

    printf -v SEL_DUR '%d:%02d:%02d' $(( SEL_SECS / 3600 )) $(( SEL_SECS % 3600 / 60 )) $(( SEL_SECS % 60 ))
    return 0
}

# Reports MakeMKV's main-title detection result for the selected title.
# Returns 1 if the disc should be failed (--strict and obfuscation suspected
# without an FPL_MainFeature flag).
report_selection() {
    local root="$1"
    if [[ -n "$SEL_JAVA" ]]; then
        info "  MakeMKV used Java runtime: $SEL_JAVA"
    fi
    if [[ "$SEL_METHOD" == "fpl" ]]; then
        info "  Main feature: title $SEL_ID (flagged FPL_MainFeature by MakeMKV Java detection), duration $SEL_DUR, size $(( SEL_BYTES / 1024 / 1024 )) MiB"
        return 0
    fi
    info "  Main feature: title $SEL_ID (longest title), duration $SEL_DUR, size $(( SEL_BYTES / 1024 / 1024 )) MiB"
    if (( SEL_SUSPECT >= OBFUSCATION_THRESHOLD )); then
        warn "  $SEL_SUSPECT titles are within ${OBFUSCATION_WINDOW}s of the longest: this disc may use fake-playlist"
        warn "  protection, and MakeMKV did not flag a main feature. The longest title may be a scrambled copy."
        if [[ -z "$SEL_JAVA" ]]; then
            warn "  MakeMKV did not report using Java for this disc - check the Java setup (see README)."
        fi
        if [[ ! -d "$root/BDMV/JAR" ]]; then
            warn "  $root/BDMV/JAR is missing - Java playlist detection cannot work on a backup without it."
        fi
        if (( STRICT )); then
            error "  --strict: refusing to guess on a suspected obfuscated disc."
            return 1
        fi
    fi
    return 0
}

# Best-effort report of the Java runtime MakeMKV is likely to use. Never fatal:
# Java is only needed for BD-Java discs (fake playlists, some BD+/AACS cases).
check_java() {
    local conf="" java="" source="" c ver major
    for c in "$HOME/.MakeMKV/settings.conf" "$HOME/Library/MakeMKV/settings.conf"; do
        [[ -r "$c" ]] && { conf="$c"; break; }
    done
    if [[ -n "$conf" ]]; then
        java="$(sed -n 's/^[[:space:]]*app_Java[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$conf" | tail -n 1)"
        [[ -n "$java" ]] && source="app_Java in $conf"
    fi
    if [[ -z "$java" && -x /usr/libexec/java_home ]]; then
        # java_home exits non-zero when no real JDK is installed (/usr/bin/java is only a stub then).
        if c="$(/usr/libexec/java_home 2>/dev/null)" && [[ -x "$c/bin/java" ]]; then
            java="$c/bin/java"; source="/usr/libexec/java_home (MakeMKV auto-detection may pick a different one)"
        fi
    fi
    if [[ -z "$java" ]] && command -v java >/dev/null 2>&1 && [[ ! -x /usr/libexec/java_home ]]; then
        java="$(command -v java)"; source="PATH"
    fi

    if [[ -z "$java" ]]; then
        # Homebrew JDKs are keg-only: not on PATH and not registered with java_home,
        # so neither this check nor (probably) MakeMKV's auto-detection finds them.
        local found="" cand
        for cand in /opt/homebrew/opt/openjdk@17/bin/java /usr/local/opt/openjdk@17/bin/java \
                    /opt/homebrew/opt/openjdk*/bin/java /usr/local/opt/openjdk*/bin/java; do
            [[ -x "$cand" ]] && { found="$cand"; break; }   # unmatched globs stay literal and fail -x
        done
        if [[ -z "$found" ]] && cand="$(command -v java 2>/dev/null)" && [[ "$cand" != /usr/bin/java && -x "$cand" ]]; then
            found="$cand"
        fi
        if [[ -n "$found" ]]; then
            warn "Java is installed at $found, but it is not registered with macOS (/usr/libexec/java_home)"
            warn "and app_Java is not set, so MakeMKV will probably not find it. Point MakeMKV at it with"
            warn "MakeMKV > Preferences > Protection > Custom Java executable location, or add this line to"
            warn "$HOME/.MakeMKV/settings.conf (MakeMKV closed):  app_Java = \"$found\""
            warn "Each disc's log shows which Java MakeMKV actually used (MSG 3344), if any."
        else
            warn "No Java runtime found. MakeMKV cannot run BD-Java playlist detection, so discs with"
            warn "fake-playlist protection will fall back to 'longest title'. See README > Java main-title detection."
        fi
        return 0
    fi
    if [[ ! -x "$java" ]]; then
        warn "Java path from $source is not executable: $java"
        return 0
    fi
    # First line containing "version" (skips e.g. "Picked up JAVA_TOOL_OPTIONS").
    ver="$("$java" -version 2>&1 | grep -m 1 'version')" || true
    major=""
    if [[ "$ver" =~ \"1\.([0-9]+) ]]; then major="${BASH_REMATCH[1]}"
    elif [[ "$ver" =~ \"([0-9]+) ]]; then major="${BASH_REMATCH[1]}"
    fi
    info "Java for MakeMKV: $java (${ver:-version unknown}; from $source)"
    if [[ -n "$major" ]] && (( major >= 25 )); then
        warn "Java $major: MakeMKV playlist detection has been reported failing on macOS with JDK 25 and working"
        warn "with JDK 17 (brew install openjdk@17, then set app_Java - see README)."
    fi
}

# Runs makemkvcon mkv; full robot output goes to the log, progress to the terminal.
run_mkv() {
    local root="$1" id="$2" outdir="$3"
    local line last_pct=-1 pct
    local -a st
    set +e
    "$MAKEMKVCON_BIN" -r --cache="$CACHE_MB" --minlength="$MIN_LENGTH" --progress=-same \
        mkv "file:$root" "$id" "$outdir" 2>&1 \
    | while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$LOG_FILE" ]] && printf '    %s\n' "$line" >>"$LOG_FILE"
        if [[ "$line" =~ ^PRGV:([0-9]+),([0-9]+),([0-9]+)$ ]] && (( BASH_REMATCH[3] > 0 )); then
            pct=$(( BASH_REMATCH[2] * 100 / BASH_REMATCH[3] ))
            if (( pct != last_pct )); then
                printf '\r  progress: %3d%%' "$pct" >&2
                last_pct=$pct
            fi
        fi
    done
    st=("${PIPESTATUS[@]}")
    set -e
    printf '\n' >&2
    return "${st[0]}"
}

# ---- Per-disc processing. Returns 0 converted, 10 skipped, other = failed.
process_disc() {
    local root="$1" name="$2"
    local outdir="$DEST/$name"
    local existing=()

    info "Disc: $root"
    info "  Output folder: $outdir"

    if [[ -L "$outdir" ]]; then
        error "  Output folder is a symlink; refusing to write or remove through it."
        return 1
    fi
    if [[ -e "$outdir" && ! -d "$outdir" ]]; then
        error "  Output path exists and is not a directory."
        return 1
    fi
    if [[ -d "$outdir" ]]; then
        existing=("$outdir"/*.mkv)
        if (( ${#existing[@]} > 0 )) && (( ! FORCE )); then
            info "  Skipping: output folder already contains ${#existing[@]} .mkv file(s) (use --force to replace)."
            return 10
        fi
    fi

    local infolog
    if (( DRY_RUN )); then
        infolog="$(mktemp "$(strip_trailing_slashes "${TMPDIR:-/tmp}")/bdmv2mkv-info.XXXXXXXXXX")" || { error "  mktemp failed."; return 1; }
        TEMP_DIRS+=("$infolog")
    else
        local work
        work="$(mktemp -d "$DEST/.bdmv2mkv-tmp.XXXXXXXXXX")" || { error "  Could not create temp dir in $DEST."; return 1; }
        TEMP_DIRS+=("$work")
        infolog="$work/.info.txt"
    fi

    if ! select_main_title "$root" "$infolog"; then
        [[ -n "$LOG_FILE" ]] && sed 's/^/    /' "$infolog" >>"$LOG_FILE" 2>/dev/null
        return 1
    fi
    if ! report_selection "$root"; then
        [[ -n "$LOG_FILE" ]] && sed 's/^/    /' "$infolog" >>"$LOG_FILE" 2>/dev/null
        if (( DRY_RUN )); then rm -f "$infolog"; untrack_temp "$infolog"; else rm -rf "$work"; untrack_temp "$work"; fi
        return 1
    fi

    if (( DRY_RUN )); then
        rm -f "$infolog"; untrack_temp "$infolog"
        if (( ${#existing[@]} > 0 )); then
            info "  [dry-run] Would replace ${#existing[@]} existing .mkv file(s) (--force)."
        else
            info "  [dry-run] Would remux title $SEL_ID into $outdir"
        fi
        return 0
    fi

    # Per-disc free-space check against the reported title size.
    if (( SEL_BYTES > 0 )); then
        local need_kib avail_kib
        need_kib=$(( SEL_BYTES * (100 + SPACE_HEADROOM_PCT) / 100 / 1024 ))
        avail_kib="$(free_kib "$DEST")"
        if is_positive_int "$avail_kib" && (( avail_kib < need_kib )); then
            error "  Not enough free space: need ~$(( need_kib / 1024 )) MiB, have $(( avail_kib / 1024 )) MiB."
            rm -rf "$work"; untrack_temp "$work"
            return 1
        fi
    fi

    local outtmp="$work/out"
    mkdir "$outtmp" || { error "  Cannot create $outtmp"; return 1; }
    info "  Remuxing title $SEL_ID ..."
    local rc=0
    run_mkv "$root" "$SEL_ID" "$outtmp" || rc=$?
    (( INTERRUPTED )) && return 1

    local produced=("$outtmp"/*.mkv) f
    if (( rc != 0 )); then
        error "  makemkvcon mkv failed (exit $rc). See log: $LOG_FILE"
        rm -rf "$work"; untrack_temp "$work"
        return 1
    fi
    if (( ${#produced[@]} == 0 )); then
        error "  makemkvcon reported success but produced no .mkv. See log: $LOG_FILE"
        rm -rf "$work"; untrack_temp "$work"
        return 1
    fi
    for f in "${produced[@]}"; do
        if [[ ! -s "$f" ]]; then
            error "  Produced file is empty: ${f##*/}"
            rm -rf "$work"; untrack_temp "$work"
            return 1
        fi
    done

    # Finalise: move existing MKVs aside (force), move new ones in, then drop old.
    [[ -L "$outdir" ]] && { error "  Output folder became a symlink; aborting."; return 1; }
    mkdir -p "$outdir" || { error "  Cannot create $outdir"; return 1; }
    local old=""
    if (( ${#existing[@]} > 0 )); then
        old="$work/old"
        mkdir "$old" || { error "  Cannot create $old"; return 1; }
        if ! mv "${existing[@]}" "$old/"; then
            error "  Could not move existing MKVs aside; leaving them untouched."
            local o; for o in "$old"/*.mkv; do mv "$o" "$outdir/" 2>/dev/null || true; done
            return 1
        fi
    fi
    if ! mv "${produced[@]}" "$outdir/"; then
        error "  Could not move new MKV into $outdir; restoring previous files."
        for f in "${produced[@]}"; do rm -f "$outdir/${f##*/}"; done
        if [[ -n "$old" ]]; then local o; for o in "$old"/*.mkv; do mv "$o" "$outdir/" || true; done; fi
        return 1
    fi
    rm -rf "$work"; untrack_temp "$work"

    for f in "${produced[@]}"; do info "  Wrote: $outdir/${f##*/}"; done
    return 0
}

# ---- Main
main() {
    parse_args "$@"
    preflight

    if (( ! DRY_RUN )); then
        acquire_lock
        LOG_FILE="$DEST/bdmv2mkv.log"
        : >>"$LOG_FILE" || die "Cannot write log file: $LOG_FILE"
    fi

    info "$PROG $VERSION starting$( (( DRY_RUN )) && printf ' (dry-run)')$( (( FORCE )) && printf ' (force)')$( (( STRICT )) && printf ' (strict)')"
    info "Source: $SRC"
    info "Destination: $DEST"
    info "makemkvcon: $MAKEMKVCON_BIN"
    check_java

    local roots=() r
    while IFS= read -r -d '' r; do roots+=("$r"); done < <(discover_discs)

    if (( ${#roots[@]} == 0 )); then
        warn "No BDMV folders found under $SRC."
        exit 0
    fi
    info "Found ${#roots[@]} disc(s)."

    # Deterministic, case-insensitive (APFS default) collision-free folder names.
    declare -A used=()
    local names=() base cand n key
    for r in "${roots[@]}"; do
        base="${r##*/}"
        [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || base="disc"
        cand="$base"; n=2
        key="${cand,,}"
        while [[ -n "${used[$key]:-}" ]]; do
            cand="$base ($n)"; n=$(( n + 1 )); key="${cand,,}"
        done
        used[$key]=1
        names+=("$cand")
    done

    local i rc
    for i in "${!roots[@]}"; do
        (( INTERRUPTED )) && break
        rc=0
        process_disc "${roots[$i]}" "${names[$i]}" || rc=$?
        case "$rc" in
            0) CONVERTED+=("${roots[$i]}") ;;
            10) SKIPPED+=("${roots[$i]}") ;;
            *) FAILED+=("${roots[$i]}"); error "  FAILED: ${roots[$i]}" ;;
        esac
    done

    local verb="Converted"; (( DRY_RUN )) && verb="Would convert"
    info "Summary: $verb ${#CONVERTED[@]}, skipped ${#SKIPPED[@]}, failed ${#FAILED[@]}."
    for r in "${FAILED[@]}"; do error "  failed: $r"; done
    [[ -n "$LOG_FILE" ]] && info "Log: $LOG_FILE"

    (( ${#FAILED[@]} == 0 )) || exit 1
}

main "$@"
