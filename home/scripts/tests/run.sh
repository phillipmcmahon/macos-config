#!/usr/bin/env bash
#
# Script: run.sh
# Purpose: Exercise failure handling without macOS services or live credentials.
# Version: 1.0.0
# Requires: Bash 5+, git, jq, zip, unzip and shasum or sha256sum.
# Documentation: docs/VALIDATION.md
#

set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
export HOME="$TEMP/home"
mkdir -p "$HOME" "$TEMP/repo"
PASSED=0
pass() {
    PASSED=$((PASSED + 1))
    printf 'PASS: %s\n' "$*"
}
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
expect_failure() { if "$@" > "$TEMP/failure.out" 2>&1; then
    cat "$TEMP/failure.out"
    fail "Unexpected success: $*"
fi; }

# All public help/version commands must work without service dependencies.
for script in "$ROOT"/*.sh; do
    [[ $(bash "$script" --version) == 1.0.0 ]] || fail "Version: $script"
    bash "$script" --help > /dev/null
    bash -n "$script"
done
pass 'Eight help/version interfaces and Bash syntax'
source "$ROOT/lib/common.sh"

# Literal configuration parsing and code rejection.
mkdir -p "$HOME/.config"
cat > "$HOME/.config/test" << 'CONF'
ITEMS=("one path" 'two' three)
SETTING='literal value'
CONF
chmod 600 "$HOME/.config/test"
ITEMS=() SETTING=''
load_config "$HOME/.config/test" 'ITEMS SETTING'
[[ ${#ITEMS[@]} == 3 && ${ITEMS[0]} == 'one path' && $SETTING == 'literal value' ]] || fail 'Literal parser'
printf 'SETTING=$(touch forbidden)\n' > "$HOME/.config/test"
expect_failure load_config "$HOME/.config/test" 'SETTING'
pass 'Literal configuration and expansion rejection'

# Locks refuse concurrent starts and never steal a stale lock automatically.
lock_acquire "$TEMP/lock"
expect_failure bash -c 'source "$1/lib/common.sh"; lock_acquire "$2"' bash "$ROOT" "$TEMP/lock"
lock_release
[[ ! -e $TEMP/lock ]] || fail 'Lock release'
expect_failure validate_remote_dir .
expect_failure validate_remote_dir a/../b
pass 'Lock ownership and remote destination validation'

# Corrupt ZIP and collisions must be failures, with no destination overwrite.
mkdir -p "$TEMP/zips" "$TEMP/zip-source"
printf 'broken' > "$TEMP/zips/broken.zip"
expect_failure bash "$ROOT/archive-zip-extract.sh" "$TEMP/zips"
rm "$TEMP/zips/broken.zip"
printf 'source' > "$TEMP/zip-source/music.txt"
(cd "$TEMP/zip-source" && zip -q "$TEMP/zips/good.zip" music.txt)
bash "$ROOT/archive-zip-extract.sh" --dry-run "$TEMP/zips" > /dev/null
[[ ! -e $TEMP/zips/music.txt ]] || fail 'Dry-run wrote output'
bash "$ROOT/archive-zip-extract.sh" "$TEMP/zips" > /dev/null
[[ $(cat "$TEMP/zips/music.txt") == source ]] || fail 'ZIP content'
expect_failure bash "$ROOT/archive-zip-extract.sh" "$TEMP/zips"
pass 'ZIP corruption, dry-run, extraction and collision reporting'

# Transport test double responds without contacting ClouDNS.
mkdir -p "$TEMP/bin" "$HOME/.config/cloudns"
cat > "$TEMP/bin/curl" << 'MOCK'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "${MOCK_DNS_RESPONSE:-not-json}"
MOCK
chmod +x "$TEMP/bin/curl"
printf 'host\nhost\n' > "$HOME/.config/cloudns/hosts.txt"
export CLOUDNS_AUTH_ID=test CLOUDNS_AUTH_PASSWORD=test
expect_failure env PATH="$TEMP/bin:$PATH" bash "$ROOT/dns-cloudns-cnames-manage.sh" --dry-run
env PATH="$TEMP/bin:$PATH" MOCK_DNS_RESPONSE='{}' bash "$ROOT/dns-cloudns-cnames-manage.sh" --dry-run > "$TEMP/dns.out"
grep -q 'Hosts processed: 1. Failed: 0.' "$TEMP/dns.out" || fail 'Host deduplication'
pass 'Malformed DNS response refusal and host deduplication'

# Isolated Git transaction engine, no remote/network required.
git -C "$TEMP/repo" init -q -b main
git -C "$TEMP/repo" config user.name Test
git -C "$TEMP/repo" config user.email test@localhost
mkdir -p "$TEMP/repo/home/scripts" "$HOME/scripts"
printf 'base\n' > "$TEMP/repo/home/scripts/file.txt"
cp "$TEMP/repo/home/scripts/file.txt" "$HOME/scripts/file.txt"
git -C "$TEMP/repo" add .
git -C "$TEMP/repo" commit -qm base
BASE=$(git -C "$TEMP/repo" rev-parse HEAD)
engine() {
    bash "$ROOT/lib/sync-engine.sh" "$1" "$HOME" "$TEMP/repo" testmac 1 "${2:-}" \
        --shared-files --shared-dirs scripts --machine-files --machine-dirs --explicit-dirs --excludes '*.secret'
}
engine snapshot "$BASE"
engine collect
engine local
engine plan
[[ $(engine needs-deploy) == no ]] || fail 'No-change plan'
engine clear
pass 'Sync no-change transaction'

engine snapshot "$BASE"
printf 'concurrent\n' > "$HOME/scripts/file.txt"
expect_failure engine check
printf 'base\n' > "$HOME/scripts/file.txt"
engine clear
pass 'Concurrent HOME edit refusal'

printf 'local edit\n' > "$HOME/scripts/file.txt"
engine snapshot "$BASE"
engine collect
git -C "$TEMP/repo" add .
git -C "$TEMP/repo" commit -qm local
engine local
printf 'reconciled\n' > "$TEMP/repo/home/scripts/file.txt"
git -C "$TEMP/repo" add .
git -C "$TEMP/repo" commit -qm reconciled
engine plan
[[ $(engine needs-deploy) == yes ]] || fail 'Changed plan'
engine deploy
[[ $(cat "$HOME/scripts/file.txt") == reconciled ]] || fail 'Deployment content'
engine check
engine deploy
engine clear
pass 'Checked deployment and idempotent resume'

BASE=$(git -C "$TEMP/repo" rev-parse HEAD)
engine forget scripts/file.txt
engine snapshot "$BASE"
engine collect
[[ -f $HOME/scripts/file.txt && ! -e $TEMP/repo/home/scripts/file.txt ]] || fail 'Forget preservation'
engine clear
git -C "$TEMP/repo" reset --hard -q HEAD
engine add scripts/file.txt
engine snapshot "$BASE"
ln -s /dev/null "$HOME/scripts/link.txt"
expect_failure engine check
rm "$HOME/scripts/link.txt"
engine clear
pass 'Forget keeps HOME and symlinks are refused'

# Legacy engine transactions must not be silently reinterpreted.
printf '{"base":"%s"}\n' "$BASE" > "$TEMP/repo/.git/macos-config-sync-v31-testmac/pending.json"
expect_failure engine check
pass 'Legacy pending transaction guard'
# Extract an individual reviewed function for deterministic failure injection.
load_function() {
    local file=$1 name=$2
    awk -v name="$name" '$0 == name "() {" {inside=1} inside {print; if ($0 == "}") exit}' "$file" > "$TEMP/function.sh"
    [[ -s $TEMP/function.sh ]] || fail "Missing helper: $name"
    source "$TEMP/function.sh"
}
load_function "$ROOT/security-bitwarden-backup.sh" finish_bw_session
script_unlocked=1 bw_session_finished=0 lock_calls=0
bw() {
    lock_calls=$((lock_calls + 1))
    ((lock_calls > 1))
}
expect_failure finish_bw_session
[[ $bw_session_finished == 0 && $script_unlocked == 1 ]] || fail 'Relock failure cannot be retried'
finish_bw_session
[[ $bw_session_finished == 1 && $script_unlocked == 0 && $lock_calls == 2 ]] || fail 'Relock retry'
unset -f bw
pass 'Failed vault relock is retried and reported'

# Invalid mutation responses must fail even after a successful empty lookup.
cat > "$TEMP/bin/curl" << 'MOCK'
#!/usr/bin/env bash
cat >/dev/null
case ${*: -1} in */records.json) printf '{}' ;; *) printf '{"status":"Unexpected"}' ;; esac
MOCK
expect_failure env PATH="$TEMP/bin:$PATH" bash "$ROOT/dns-cloudns-cnames-manage.sh"
pass 'Unexpected DNS mutation response refusal'

# Backup exports are checked, checksummed and never overwrite custom output.
cat > "$TEMP/bin/curl" << 'MOCK'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"status":"Success","zone":"$ORIGIN phillipmcmahon.com.\n@ 300 IN A 192.0.2.1\n"}'
MOCK
env PATH="$TEMP/bin:$PATH" bash "$ROOT/dns-cloudns-backup.sh" --output "$TEMP/zone.bind" > /dev/null
[[ -f $TEMP/zone.bind.sha256 ]] || fail 'Backup checksum missing'
expect_failure env PATH="$TEMP/bin:$PATH" bash "$ROOT/dns-cloudns-backup.sh" --output "$TEMP/zone.bind"
bash "$ROOT/dns-cloudns-backup.sh" --restore "$TEMP/zone.bind" --dry-run > /dev/null
printf 'changed\n' >> "$TEMP/zone.bind"
expect_failure bash "$ROOT/dns-cloudns-backup.sh" --restore "$TEMP/zone.bind" --dry-run
pass 'DNS backup publication, collision and restore checksum validation'

# A changed connected device prevents entry into GPG card operations.
cat > "$TEMP/bin/ykman" << 'MOCK'
#!/usr/bin/env bash
printf '456\n'
MOCK
cat > "$TEMP/bin/gpg" << 'MOCK'
#!/usr/bin/env bash
exit 99
MOCK
chmod +x "$TEMP/bin/ykman" "$TEMP/bin/gpg"
load_function "$ROOT/security-yubikey-provision.sh" gpg
BUSY=1 SERIAL=123
saved_path=$PATH
PATH="$TEMP/bin:$PATH"
expect_failure gpg --card-edit
grep -q 'Device selection changed' "$TEMP/failure.out" || fail 'Device guard not exercised'
PATH=$saved_path
unset -f gpg
pass 'YubiKey identity guard'
printf '\nPassed %s test groups.\n' "$PASSED"
bash "$ROOT/tests/sync-workflow.sh"
bash "$ROOT/tests/bitwarden-workflow.sh"
