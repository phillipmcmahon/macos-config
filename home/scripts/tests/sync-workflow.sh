#!/usr/bin/env bash
#
# Script: sync-workflow.sh
# Purpose: Exercise sync and recovery against disposable Git repositories.
# Version: 1.0.0
# Requires: Bash 5+, Git, jq and modern rsync.
# Documentation: docs/VALIDATION.md
#

set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
export HOME=$TEMP/home
mkdir -p "$HOME/managed" "$HOME/.config/macos-config-sync" "$TEMP/nas" "$TEMP/bin"
cat > "$HOME/.config/macos-config-sync/config" << 'CONF'
MANAGED_DIRECTORIES=(managed)
MANAGED_FILES=()
MACHINE_DIRECTORIES=()
MACHINE_FILES=()
CONF
chmod 600 "$HOME/.config/macos-config-sync/config"
cat > "$TEMP/bin/ssh" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
cat > "$TEMP/bin/mount" << 'MOCK'
#!/usr/bin/env bash
printf '//test/home on %s (smbfs, nodev)\n' "$NAS_ROOT"
MOCK
chmod +x "$TEMP/bin/ssh" "$TEMP/bin/mount"
export PATH="$TEMP/bin:$PATH"
export REPO_DIR=$TEMP/repo NAS_ROOT=$TEMP/nas NAS_REPO_DIR=$TEMP/nas/config NAS_SSH_HOST=unreachable MACHINE_NAME=testmac
export GITHUB_REPO=$TEMP/remote.git
git init -q --bare -b main "$GITHUB_REPO"
git clone -q "$GITHUB_REPO" "$REPO_DIR"
git -C "$REPO_DIR" config user.name Test
git -C "$REPO_DIR" config user.email test@localhost
mkdir -p "$REPO_DIR/home/managed"
printf 'base\n' > "$REPO_DIR/home/managed/a.txt"
cp "$REPO_DIR/home/managed/a.txt" "$HOME/managed/a.txt"
git -C "$REPO_DIR" add .
git -C "$REPO_DIR" commit -qm base
git -C "$REPO_DIR" push -q origin main
bash "$ROOT/macos-config-sync.sh" adopt
printf 'local edit\n' > "$HOME/managed/a.txt"
bash "$ROOT/macos-config-sync.sh" sync
[[ $(cat "$NAS_REPO_DIR/home/managed/a.txt") == 'local edit' ]]
BEFORE=$(git -C "$REPO_DIR" rev-parse HEAD)
bash "$ROOT/macos-config-sync.sh" sync
[[ $(git -C "$REPO_DIR" rev-parse HEAD) == "$BEFORE" ]]
printf 'deliberately overwritten\n' > "$HOME/managed/a.txt"
bash "$ROOT/macos-config-sync.sh" restore --yes
[[ $(cat "$HOME/managed/a.txt") == 'local edit' ]]
printf 'PASS: Full sync, NAS mirror, no-change sync and explicit restore\n'

# Reject a push without deploying or advancing the local baseline, then resume.
before_ref=$(git -C "$REPO_DIR" rev-parse refs/macos-config-sync/testmac/deployed)
printf '#!/usr/bin/env bash\nexit 1\n' > "$GITHUB_REPO/hooks/pre-receive"
chmod +x "$GITHUB_REPO/hooks/pre-receive"
printf 'pending local edit\n' > "$HOME/managed/a.txt"
if bash "$ROOT/macos-config-sync.sh" sync > "$TEMP/rejected.out" 2>&1; then
    printf 'FAIL: Rejected push returned success\n' >&2
    exit 1
fi
[[ $(git -C "$REPO_DIR" rev-parse refs/macos-config-sync/testmac/deployed) == "$before_ref" ]]
[[ -f $REPO_DIR/.git/macos-config-sync-v31-testmac/pending.json ]]
[[ $(cat "$HOME/managed/a.txt") == 'pending local edit' ]]
rm "$GITHUB_REPO/hooks/pre-receive"
bash "$ROOT/macos-config-sync.sh" sync > "$TEMP/resumed.out" 2>&1
[[ ! -e $REPO_DIR/.git/macos-config-sync-v31-testmac/pending.json ]]
[[ $(cat "$NAS_REPO_DIR/home/managed/a.txt") == 'pending local edit' ]]
printf 'PASS: Failed push preserves baseline and resumes\n'

# Create an actual conflict from a second checkout of the same remote.
git clone -q "$GITHUB_REPO" "$TEMP/other"
git -C "$TEMP/other" config user.name Test
git -C "$TEMP/other" config user.email test@localhost
printf 'remote conflict\n' > "$TEMP/other/home/managed/a.txt"
git -C "$TEMP/other" add .
git -C "$TEMP/other" commit -qm remote
git -C "$TEMP/other" push -q origin main
printf 'local conflict\n' > "$HOME/managed/a.txt"
if bash "$ROOT/macos-config-sync.sh" sync > "$TEMP/conflict.out" 2>&1; then
    printf 'FAIL: Rebase conflict returned success\n' >&2
    exit 1
fi
[[ $(cat "$HOME/managed/a.txt") == 'local conflict' ]]
[[ -d $REPO_DIR/.git/rebase-merge || -d $REPO_DIR/.git/rebase-apply ]]
git -C "$REPO_DIR" rebase --abort
bash "$ROOT/macos-config-sync.sh" cancel > "$TEMP/cancel.out" 2>&1
[[ $(cat "$HOME/managed/a.txt") == 'local conflict' ]]
[[ ! -e $REPO_DIR/.git/macos-config-sync-v31-testmac/pending.json ]]
printf 'PASS: Rebase conflict and cancel preserve HOME\n'

# Recover the file mirror without GitHub, then reconnect without losing its files.
export REPO_DIR=$TEMP/recovered
saved_remote=$GITHUB_REPO
export GITHUB_REPO=$TEMP/unavailable.git
bash "$ROOT/macos-config-sync.sh" nas-pull > "$TEMP/offline.out" 2>&1
[[ -f $REPO_DIR/.git/macos-nas-offline ]]
bash "$ROOT/macos-config-sync.sh" restore --yes > "$TEMP/offline-restore.out" 2>&1
[[ $(cat "$HOME/managed/a.txt") == 'pending local edit' ]]
git -C "$REPO_DIR" remote set-url origin "$saved_remote"
export GITHUB_REPO=$saved_remote
bash "$ROOT/macos-config-sync.sh" nas-pull > "$TEMP/reconnect.out" 2>&1
[[ ! -e $REPO_DIR/.git/macos-nas-offline ]]
[[ $(cat "$REPO_DIR/home/managed/a.txt") == 'pending local edit' ]]
[[ $(git -C "$REPO_DIR" show refs/macos-config-sync/nas-recovery:home/managed/a.txt) == 'pending local edit' ]]
printf 'PASS: Offline NAS restore and reconnection preserve recovered files\n'
