#!/usr/bin/env bash
#
# Script: cert-deploy-npm-remote.sh
# Purpose: Stage, back up and install NPM certificates on the remote Podman host.
# Version: 1.0.0
# Requires: Bash, OpenSSL, Podman and standard filesystem utilities on the host.
# Documentation: docs/cert-deploy-npm-user-manual.md. Invoked by cert-deploy-npm.sh.
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
mode=$1 dest=$2 container=$3
stage=${4:-} timeout=${5:-60} expected_cert=${6:-} expected_key=${7:-}
lock="$dest/.cert-deploy-npm.lock"
locked=0 changed=0 committed=0 backup=''

# Helpers
fail() { printf 'ERROR %s\n' "$*" >&2; exit 1; }
safe_path() {
    local path=$1 current='' part
    local -a parts=()
    [[ $path == /* ]] || fail 'Absolute path required.'
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        [[ -n $part ]] || continue
        [[ $part != . && $part != .. ]] || fail 'Dot path components are not supported.'
        current+=/$part
        [[ ! -L $current ]] || fail "Symlink not supported: $current"
    done
}
cleanup() {
    local rc=$?
    trap - EXIT
    if ((changed && !committed)); then
        printf 'ERROR Deployment failed. Restoring the previous pair from %s\n' "$backup" >&2
        if cp "$backup/fullchain.pem" "$dest/fullchain.pem" && cp "$backup/privkey.pem" "$dest/privkey.pem" &&
            chmod 644 "$dest/fullchain.pem" && chmod 600 "$dest/privkey.pem"; then
            podman restart --time "$timeout" "$container" >&2 || printf 'ERROR Restart after rollback failed. Inspect NPM manually.\n' >&2
        else
            printf 'ERROR Rollback failed. Restore the backup manually.\n' >&2
        fi
        rc=1
    fi
    if ((locked)); then rmdir "$lock" || rc=1; fi
    exit "$rc"
}
hash() { openssl dgst -sha256 -r "$1" | cut -d ' ' -f 1; }

# Operations
for tool in podman openssl mktemp cp mv chmod cmp cut; do command -v "$tool" > /dev/null || fail "Missing command: $tool"; done
safe_path "$dest"
[[ -d $dest && -w $dest ]] || fail 'Destination must already exist and be writable.'
podman inspect "$container" > /dev/null
for file in fullchain.pem privkey.pem; do
    safe_path "$dest/$file"
    [[ -f $dest/$file && -s $dest/$file ]] || fail "Existing certificate file missing: $file"
done
case $mode in
    prepare) mktemp -d "$dest/.cert-deploy.XXXXXXXX" ;;
    deploy)
        [[ $stage == "$dest/.cert-deploy."* && ${stage##*/} =~ ^\.cert-deploy\.[a-zA-Z0-9]+$ ]] || fail 'Invalid staging path.'
        safe_path "$stage/fullchain.pem"
        safe_path "$stage/privkey.pem"
        [[ $(hash "$stage/fullchain.pem") == "$expected_cert" && $(hash "$stage/privkey.pem") == "$expected_key" ]] || fail 'Uploaded file checksum mismatch.'
        safe_path "$lock"
        mkdir "$lock" 2>/dev/null || fail "Deployment lock exists: $lock"
        locked=1
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        if cmp -s "$stage/fullchain.pem" "$dest/fullchain.pem" && cmp -s "$stage/privkey.pem" "$dest/privkey.pem"; then
            printf 'Unchanged certificate pair. Restart skipped.\n'
            exit 0
        fi
        backup=$(mktemp -d "$dest/.cert-backup.XXXXXXXX")
        cp -p "$dest/fullchain.pem" "$dest/privkey.pem" "$backup/"
        chmod 600 "$backup/privkey.pem"
        printf 'Backup: %s\n' "$backup"
        chmod 644 "$stage/fullchain.pem"
        chmod 600 "$stage/privkey.pem"
        changed=1
        mv -f "$stage/fullchain.pem" "$dest/fullchain.pem"
        mv -f "$stage/privkey.pem" "$dest/privkey.pem"
        podman restart --time "$timeout" "$container"
        [[ $(podman inspect --format '{{.State.Running}}' "$container") == true ]] || fail 'Container is not running after restart.'
        committed=1
        printf 'Certificate installed and NPM container running.\n'
        ;;
    *) fail 'Unknown operation.' ;;
esac
