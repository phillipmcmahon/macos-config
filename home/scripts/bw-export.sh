#!/usr/bin/env bash
#
# bw-export.sh - Bitwarden personal + organisation vault backup
# Version: 1.5.0
#
# Exports personal JSON plus a separate JSON for EVERY organisation returned
# by bw list organizations. An inaccessible organisation aborts the backup:
# no silent omissions. Export permissions are required for each organisation.
# Downloads attachments for every exported item, including organisation items
# fetched individually when absent from bw list items. Any access failure aborts.
# Trash and Sends are excluded by Bitwarden exports. This is a vault-content
# backup, not a complete server/account/configuration backup.
#
# Validates JSON, reconciles visible item IDs against exported IDs, records
# attachment names, parent IDs, sizes and SHA-256 hashes in manifest.json,
# tests the ZIP, and encrypts it to the configured GPG recipient.
# A successful decrypt test means DECRYPTION VERIFIED, not restore-tested.
# An actual test import and attachment restoration remain a separate exercise.
# See RECOVERY.txt inside each new archive for layout and restore guidance.
#
# Plaintext uses a private directory under TMPDIR and is removed before PIN
# entry or replication. Overwriting cannot guarantee erasure on APFS/SSDs.
# FileVault protects data at rest. Hard kills/power loss can leave staging.
#
# Usage:
#   bw-export.sh            export (YubiKey optional for encryption)
#   bw-export.sh --verify   decrypt pending backups using each file's own key
#
# Without a TTY or the current encryption card, exports are '-unverified'.
# --verify lets GPG select the historical key and prompt for the required card.
# Hash-only NAS reconciliation needs neither a card nor a TTY. Legacy archives
# remain supported, but are only decryption-verified and have no new manifest.
# Unattended export requires an already usable BW_SESSION. A locked vault in
# a non-interactive run fails promptly. Existing unlocked sessions are retained.
#
# v1.5.0:
#   - Check hash command success and digest format before comparison.
#   - Propagate every rotation move failure, report partial rotation honestly.
#   - Include organisation exports, validate coverage and attachment inventory.
#   - Publish local/NAS files only after checked copy to destination staging.
#     Install locally before rotation. Never deliberately overwrite a target.
#   - Verify historical files without resolving today's encryption recipient.
#   - Replace recovery-tested claims with precise decryption verification.
#     Include encrypted manifest and recovery notes.
#   - Restrictive umask, early plaintext removal and explicit cleanup failures.
#
# Requirements: Bash 3.2+, bw, jq, gpg, zip, unzip, shasum or sha256sum.
# --verify requires only gpg and a SHA-256 tool (plus standard shell utilities).
# A local mkdir lock serialises runs on this machine, not other NAS writers.
# Stale locks require manual inspection/removal. Archives are retained forever.
#
set -Eeuo pipefail
umask 077
# Save terminal availability before read loops redirect stdin to file lists.
interactive_session=0
if [[ -t 0 ]]; then interactive_session=1; fi

# ----
# Configuration
# ----
downloads_dir="$HOME/Documents/encrypted/bw-export"
nas_mount="/Volumes/home"
nas_dir="$nas_mount/documents/encrypted/bw-export"
gpg_key="0xA11E70ADFDA60CF9"
lock_dir="$downloads_dir/.bw-export.lock"
zip_file="bw-auto-export-$(date +%Y%m%d-%H%M%S%z).zip"

# ----
# Helpers
# ----

# Sanitise a string for use as a filesystem name:
#   - strip control characters (incl. newlines/tabs) and DEL
#   - replace any byte outside a conservative safe set with '_'
#   - squeeze runs of '_' and strip leading dots (no hidden/'..' names)
#   - truncate to a sane length and never return an empty string
# Uniqueness is provided by the item/attachment id that callers append,
# so information lost here does not cause collisions.
sanitise_name() {
  local s
  s=$(printf '%s' "$1" \
      | LC_ALL=C tr -d '\000-\037\177' \
      | LC_ALL=C tr -c 'A-Za-z0-9._ ()-' '_' \
      | LC_ALL=C tr -s '_' \
      | LC_ALL=C sed -e 's/^[. ]*//' -e 's/[. ]*$//' \
      | LC_ALL=C cut -c1-100)
  [ -n "$s" ] || s="unnamed"
  printf '%s' "$s"
}

# Best-effort overwrite of a single file before unlinking. On APFS
# (the default macOS filesystem since High Sierra) this is largely
# ineffective: APFS is copy-on-write, so overwritten blocks may not
# correspond to the original data's physical location. FileVault
# (full-disk encryption) is the real control for data-at-rest
# protection. The overwrite is retained as defence-in-depth for any
# non-APFS volumes (e.g. external HFS+ drives).
secure_rm_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  if command -v shred >/dev/null 2>&1; then
    shred -u -n 3 -- "$f"
  else
    rm -P -- "$f"
  fi
}

# Print the SHA-256 hex digest of a file (macOS ships shasum; Linux sha256sum).
sha256_of() {
  local output digest
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 -- "$1") || return 1
  else
    output=$(sha256sum -- "$1") || return 1
  fi
  digest=${output%% *}
  [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || {
    echo "Error: invalid SHA-256 output for $1." >&2
    return 1
  }
  printf '%s\n' "$digest"
}

# Status 0: equal. Status 1: mismatch OR read/hash failure. Never compare
# empty/failed command output as though it were a valid digest.
hashes_match() {
  local left right
  left=$(sha256_of "$1") || { echo "Error: cannot hash $1." >&2; return 1; }
  right=$(sha256_of "$2") || { echo "Error: cannot hash $2." >&2; return 1; }
  [ "$left" = "$right" ]
}

# mv -n can return success after skipping an existing target. Check that the
# source disappeared too. Destination directory is controlled by this script.
move_no_replace() {
  [ ! -e "$2" ] && [ ! -L "$2" ] || {
    echo "Error: destination exists: $2." >&2; return 1;
  }
  mv -n -- "$1" "$2" || return 1
  [ ! -e "$1" ] && [ ! -L "$1" ] || {
    echo "Error: move did not publish $2 (source remains)." >&2; return 1;
  }
}

# Copy into a private directory on the destination filesystem, validate,
# then rename within that filesystem. A failed copy is never a final backup.
# pending_dir is cleaned on EXIT. A hard kill may leave a hidden staging dir.
pending_dir=""
install_checked() {
  local source="$1" destination="$2" parent
  parent=$(dirname "$destination") || return 1
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  pending_dir=$(mktemp -d "$parent/.bw-export-pending-XXXXXXXXXX") || return 1
  cp -- "$source" "$pending_dir/export.gpg" || return 1
  hashes_match "$source" "$pending_dir/export.gpg" || {
    echo "Error: staged copy failed checksum verification." >&2; return 1;
  }
  move_no_replace "$pending_dir/export.gpg" "$destination" || return 1
  rmdir "$pending_dir" || return 1
  pending_dir=""
}

# True if $nas_mount is an actual mount point (not merely a directory left
# behind on the local disk) and $nas_dir exists under it.
# 'df -P' reports the filesystem's mount point in the last column. No '--'
# is passed: $nas_mount is a fixed absolute path (cannot look like an
# option) and the native macOS df does not reliably accept '--'.
nas_available() {
  local mounted_on
  [ -d "$nas_mount" ] || return 1
  mounted_on=$(df -P "$nas_mount" 2>/dev/null | awk 'NR == 2 {print $NF}')
  [ "$mounted_on" = "$nas_mount" ] && [ -d "$nas_dir" ]
}

# Move every bw-auto-export-*.zip.gpg in $1 (except an optional $2) into
# $1/archive/, refusing to overwrite. All collisions are detected before
# anything is moved, so a refusal leaves the directory untouched.
rotate_into_archive() {
  local dir="$1" keep="${2:-}" f name collisions=0
  local listing
  # Explicit '|| return 1': errexit is suspended inside an 'if !' condition.
  listing=$(find "$dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*.zip.gpg" | sort) || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name=$(basename "$f")
    [ "$name" != "$keep" ] || continue
    if [ -e "$dir/archive/$name" ] || [ -L "$dir/archive/$name" ]; then
      echo "Error: $dir/archive/$name already exists; refusing to overwrite it during rotation." >&2
      collisions=$((collisions + 1))
    fi
  done <<< "$listing"
  [ "$collisions" -eq 0 ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name=$(basename "$f")
    [ "$name" != "$keep" ] || continue
    move_no_replace "$f" "$dir/archive/$name" || {
      echo "Error: rotation stopped at $f. Earlier files may already be in archive/." >&2
      return 1
    }
  done <<< "$listing"
  return 0
}

# Lock the vault only if *this script* unlocked it, then drop the session
# key from our environment. Idempotent; safe to call from the EXIT trap.
script_unlocked=0
bw_session_finished=0
finish_bw_session() {
  [ "$bw_session_finished" -eq 0 ] || return 0
  bw_session_finished=1
  if [ "$script_unlocked" -eq 1 ]; then
    echo "Locking vault (unlocked by this script)..."
    bw lock >/dev/null 2>&1 || echo "Warning: 'bw lock' failed." >&2
  fi
  unset BW_SESSION
}

# ----
# Cleanup trap (registered before any secret material exists)
# ----
random_dir=""
encrypted_stage=""
lock_held=0
# Remove staging and explicitly report failure. Physical erasure is not
# guaranteed. Only release the lock once staging paths have been removed.
remove_plaintext() {
  [ -n "$random_dir" ] && [ -d "$random_dir" ] || return 0
  if command -v shred >/dev/null 2>&1; then
    find "$random_dir" -type f -exec shred -u -n 3 {} \; || true
  else
    find "$random_dir" -type f -exec rm -P {} \; || true
  fi
  rm -rf -- "$random_dir" || return 1
  [ ! -e "$random_dir" ] || return 1
  random_dir=""
}
cleanup() {
  local status=$? cleanup_failed=0
  trap - EXIT
  set +e
  finish_bw_session
  if ! remove_plaintext; then
    echo "Error: plaintext staging could not be removed: $random_dir" >&2
    cleanup_failed=1
  fi
  if [ -n "$pending_dir" ]; then
    rm -rf -- "$pending_dir" || cleanup_failed=1
  fi
  if [ -n "$encrypted_stage" ]; then
    rm -rf -- "$encrypted_stage" || cleanup_failed=1
  fi
  if [ "$cleanup_failed" -eq 0 ] && [ "$lock_held" -eq 1 ]; then
    rm -rf -- "$lock_dir" || cleanup_failed=1
  fi
  if [ "$cleanup_failed" -ne 0 ]; then
    echo "Error: cleanup incomplete. Inspect staging and the lock before retrying." >&2
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
# Signals only trigger an exit (with the conventional 128+signal status);
# the single EXIT trap then performs cleanup exactly once.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ----
# Concurrency lock
# ----
# mkdir is atomic on local and network filesystems and needs no flock(1),
# which macOS does not ship. The PID inside is informational only: a lock
# is NEVER removed automatically, because "check PID, then rm, then mkdir"
# is racy (two late starters can both see a dead PID and both proceed).
# If a run was killed hard and left the lock behind, the user removes it
# after confirming no bw-export.sh is running.
acquire_lock() {
  local other_pid
  mkdir -p "$downloads_dir"
  if mkdir "$lock_dir" 2>/dev/null; then
    lock_held=1
    printf '%s\n' "$$" > "$lock_dir/pid"
    return 0
  fi
  other_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
  echo "Error: lock $lock_dir is held (owner PID '${other_pid:-unknown}')." >&2
  if [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null; then
    echo "Another bw-export.sh appears to be running. Aborting." >&2
  else
    echo "That PID is not running, so the lock is probably stale (e.g. from a" >&2
    echo "hard kill). Confirm no bw-export.sh is running, then remove it with:" >&2
    echo "  rm -rf '$lock_dir'" >&2
  fi
  exit 1
}

# ----
# Mode-specific pre-flight
# ----
require_cmds() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: '$cmd' is not installed. Please install it first." >&2
      exit 1
    fi
  done
}
require_sha256() {
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "Error: neither 'shasum' nor 'sha256sum' is installed." >&2
    exit 1
  fi
}

# Resolve the recipient to exactly one primary key and pick its newest
# usable encryption-capable (sub)key fingerprint. Encrypting to "<fpr>!"
# removes any ambiguity from multiple matching keys and, together with an
# explicit trust model, avoids interactive prompts.
#
# --with-colons record layout (see gnupg/doc/DETAILS):
#   pub/sub records: field 2 = validity, field 6 = creation time (epoch),
#                    field 12 = key capabilities (lowercase = own capability)
#   fpr record:      field 10 = fingerprint of the preceding pub/sub
# The newest usable key is chosen by its creation timestamp explicitly;
# listing order is not relied upon.
resolve_gpg_enc_fpr() {
  local gpg_colons primary_count
  gpg_colons=$(gpg --batch --with-colons --list-keys "$gpg_key" 2>/dev/null) || {
    echo "Error: GPG key $gpg_key not found in keyring." >&2
    exit 1
  }
  primary_count=$(printf '%s\n' "$gpg_colons" | grep -c '^pub:' || true)
  if [ "$primary_count" -ne 1 ]; then
    echo "Error: GPG key spec '$gpg_key' matches $primary_count primary keys; expected exactly 1." >&2
    exit 1
  fi
  gpg_enc_fpr=$(printf '%s\n' "$gpg_colons" | awk -F: '
    ($1 == "pub" || $1 == "sub") {
      want = ($12 ~ /e/ && $2 !~ /^[idren]$/); created = $6 + 0; next
    }
    $1 == "fpr" && want {
      if (fpr == "" || created > best) { best = created; fpr = $10 }
      want = 0
    }
    END { print fpr }')
  if [ -z "$gpg_enc_fpr" ]; then
    echo "Error: GPG key $gpg_key has no valid encryption-capable (sub)key." >&2
    exit 1
  fi
  echo "Using GPG encryption key fingerprint $gpg_enc_fpr"
}

# True if an OpenPGP card (YubiKey) that carries the encryption key is
# currently inserted. --card-status --with-colons emits
#   fpr:<sig fpr>:<enc fpr>:<auth fpr>:
# and exits non-zero when no card is available. The check never prompts for
# a PIN, so it is safe to run before deciding whether to decrypt-test.
card_has_enc_key() {
  local card
  card=$(gpg --batch --with-colons --card-status 2>/dev/null) || return 1
  printf '%s\n' "$card" | awk -F: -v want="$gpg_enc_fpr" '
    $1 == "fpr" { for (i = 2; i <= NF; i++) if ($i == want) found = 1 }
    END { exit found ? 0 : 1 }'
}

# ----
# --verify mode: decrypt-test pending '-unverified' exports and rename
# the local copy and its NAS copy after all checks pass.
# ----

# Print the first existing file named $1 in the directories $2..; empty if none.
find_in_dirs() {
  local name="$1" d; shift
  for d in "$@"; do
    if [ -f "$d/$name" ]; then printf '%s' "$d/$name"; return 0; fi
  done
  return 1
}

# List '-unverified' exports in the given directories (current + archive/),
# one path per line. Callers capture the output with $(...) BEFORE looping
# so that a failing 'find' propagates through 'set -e' rather than being
# lost inside a process substitution.
list_unverified() {
  local d
  for d in "$@"; do
    [ -d "$d" ] || continue
    find "$d" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*-unverified.zip.gpg" || return 1
  done | sort
}

# Historical keys may be expired for encryption but still decrypt old files.
# GPG selects the required key/card from the ciphertext. Preserve diagnostics.
decrypt_test() {
  if [ "$interactive_session" -eq 0 ]; then
    echo "Error: decrypting $1 requires an interactive run. Re-run --verify in a terminal." >&2
    return 1
  fi
  gpg --decrypt "$1" >/dev/null
}

verify_pending() {
  local f name verified_name dir nas_copy nas_copy_dir local_verified
  local rc=0 count=0 nas_count=0
  local local_dirs=("$downloads_dir" "$downloads_dir/archive")
  local nas_dirs=("$nas_dir" "$nas_dir/archive")
  local nas_ok=0 local_pending nas_pending

  if nas_available; then
    nas_ok=1
    echo "NAS mounted; NAS copies will be renamed too."
  else
    echo "NAS not mounted; NAS copies (if any) keep their '-unverified' name until a later --verify with the NAS mounted."
  fi

  # --- Pass 1: local '-unverified' exports (current dir and archive/). ---
  # Files are renamed in place, wherever they currently live.
  local_pending=$(list_unverified "${local_dirs[@]}")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    count=$((count + 1))
    dir=$(dirname "$f")
    name=$(basename "$f")
    verified_name="${name%-unverified.zip.gpg}.zip.gpg"
    nas_copy=""
    echo "Verifying $f..."

    # --- Phase 1: all checks. Nothing is renamed until every check passes. ---
    if [ -e "$dir/$verified_name" ]; then
      echo "Error: $dir/$verified_name already exists; refusing to overwrite. $name left as-is." >&2
      rc=1; continue
    fi
    if [ "$nas_ok" -eq 1 ] && nas_copy=$(find_in_dirs "$name" "${nas_dirs[@]}"); then
      nas_copy_dir=$(dirname "$nas_copy")
      if [ -e "$nas_copy_dir/$verified_name" ]; then
        echo "Error: $nas_copy_dir/$verified_name already exists; refusing to overwrite. $name left as-is." >&2
        rc=1; continue
      fi
      # The NAS copy is only considered verified if it is byte-identical to
      # the local file we are about to decrypt-test.
      if ! hashes_match "$f" "$nas_copy"; then
        echo "Error: NAS copy $nas_copy differs from the local copy (SHA-256 mismatch or hash failure); nothing renamed." >&2
        rc=1; continue
      fi
    fi
    if ! decrypt_test "$f"; then
      echo "Error: $name failed to decrypt - left as-is for inspection." >&2
      rc=1; continue
    fi

    # --- Phase 2: all checks passed - rename local, then NAS. ---
    # Two separate renames cannot be atomic; if the second fails the NAS
    # copy stays '-unverified' and pass 2 below reconciles it later.
    move_no_replace "$f" "$dir/$verified_name" || { rc=1; continue; }
    echo "  local: renamed to $dir/$verified_name"
    if [ -n "$nas_copy" ]; then
      if move_no_replace "$nas_copy" "$nas_copy_dir/$verified_name"; then
        echo "  nas:   renamed to $nas_copy_dir/$verified_name"
      else
        echo "Error: local copy renamed but NAS rename failed; NAS copy remains $nas_copy." >&2
        rc=1
      fi
    fi
  done <<< "$local_pending"
  [ "$count" -gt 0 ] || echo "No '-unverified' exports found locally (current or archive/)."

  # --- Pass 2: NAS '-unverified' exports (current dir and archive/) whose ---
  # --- local copy was verified earlier, e.g. while the NAS was offline.  ---
  if [ "$nas_ok" -eq 1 ]; then
    nas_pending=$(list_unverified "${nas_dirs[@]}")
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      nas_count=$((nas_count + 1))
      dir=$(dirname "$f")
      name=$(basename "$f")
      verified_name="${name%-unverified.zip.gpg}.zip.gpg"
      echo "Reconciling NAS copy $f..."
      if [ -e "$dir/$verified_name" ]; then
        echo "Error: $dir/$verified_name already exists; refusing to overwrite. $name left as-is." >&2
        rc=1; continue
      fi
      # Prefer matching against a verified local copy (current or archive/)
      # so the YubiKey is not needed; otherwise decrypt-test the NAS file.
      if local_verified=$(find_in_dirs "$verified_name" "${local_dirs[@]}"); then
        if ! hashes_match "$local_verified" "$f"; then
          echo "Error: NAS copy $name differs from verified local copy $local_verified (SHA-256 mismatch or hash failure); left as-is." >&2
          rc=1; continue
        fi
        echo "  matches verified local copy $local_verified"
      elif decrypt_test "$f"; then
        echo "  no local copy; decrypt test on NAS copy passed"
      else
        echo "Error: no local copy and NAS copy $name failed to decrypt - left as-is." >&2
        rc=1; continue
      fi
      move_no_replace "$f" "$dir/$verified_name" || { rc=1; continue; }
      echo "  nas:   renamed to $dir/$verified_name"
    done <<< "$nas_pending"
    [ "$nas_count" -gt 0 ] || echo "No '-unverified' exports left on NAS (current or archive/)."
  fi

  return "$rc"
}

# ----
# Mode dispatch - parsed before any tool/key checks so each mode only
# demands what it actually uses.
# ----
if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [--verify]" >&2
  exit 2
fi
case "${1:-}" in
  --verify)
    # Needs only gpg (decrypt) and a SHA-256 tool; no bw/jq/zip/unzip and
    # no encryption-key resolution.
    require_cmds gpg
    require_sha256
    acquire_lock
    verify_pending
    exit $?
    ;;
  "")
    require_cmds bw jq gpg zip unzip
    require_sha256
    resolve_gpg_enc_fpr
    acquire_lock
    ;;
  *)
    echo "Usage: $0 [--verify]" >&2
    exit 2
    ;;
esac

mkdir -p "$downloads_dir/archive"

# ----
# Unlock vault and capture session key
# ----
bw_status=$(bw status | jq -r '.status')

case "$bw_status" in
  unauthenticated)
    echo "Please log in to Bitwarden first (bw login)." >&2
    exit 1
    ;;
  locked)
    if [ "$interactive_session" -eq 0 ]; then
      echo "Error: vault locked. Unattended exports require a usable BW_SESSION." >&2
      exit 1
    fi
    echo "Vault is locked - unlocking..."
    # --raw prints only the session key; prompts for master password on the TTY
    BW_SESSION=$(bw unlock --raw)
    export BW_SESSION
    script_unlocked=1  # we changed the vault state, so we are responsible for re-locking
    ;;
  unlocked)
    echo "Vault already unlocked (will be left unlocked)."
    ;;
  *)
    echo "Error: unexpected Bitwarden status '$bw_status'." >&2
    exit 1
    ;;
esac

# ----
# Secure temp dir
# ----
# Stage plaintext under $TMPDIR rather than inside ~/Documents, where
# iCloud/Arq/Spotlight could capture it before the cleanup trap runs.
# On macOS $TMPDIR is normally a per-user directory that is not synced by
# iCloud; nothing beyond that is assumed about its lifecycle or filesystem.
# Falls back to /tmp if $TMPDIR is unset.
tmp_root="${TMPDIR:-/tmp}"
[[ "$tmp_root" != "/" ]] && tmp_root="${tmp_root%/}"  # macOS sets TMPDIR with a trailing slash
random_dir=$(mktemp -d "$tmp_root/bw_export_XXXXXXXXXX")

# ----
# Export personal and organisation data, with explicit completeness checks.
# ----
validate_export() {
  jq -e 'type == "object" and .encrypted == false and
    (.items | type == "array") and
    all(.items[]; (.id | type == "string") and (.id | test("^[A-Za-z0-9-]+$"))) and
    (([.items[].id] | length) == ([.items[].id] | unique | length))' "$1" >/dev/null
}

bw sync
bw export --format json --output "$random_dir/bitwarden_export.json"
validate_export "$random_dir/bitwarden_export.json" || {
  echo "Error: invalid personal JSON export." >&2; exit 1;
}
bw list organizations > "$random_dir/organisations.json"
jq -e 'type == "array" and all(.[];
  (.id | type == "string") and (.id | test("^[A-Za-z0-9-]+$")))'   "$random_dir/organisations.json" >/dev/null
org_ids=$(jq -r '.[].id' "$random_dir/organisations.json")
export_files=("$random_dir/bitwarden_export.json")
mkdir "$random_dir/organisations"
while IFS= read -r org_id; do
  [ -n "$org_id" ] || continue
  org_export="$random_dir/organisations/$org_id.json"
  echo "Exporting organisation $org_id..."
  if ! bw export --organizationid "$org_id" --format json --output "$org_export"; then
    echo "Error: organisation $org_id could not be exported. Check export permissions. No new backup installed." >&2
    exit 1
  fi
  validate_export "$org_export" || { echo "Error: invalid organisation JSON: $org_id." >&2; exit 1; }
  export_files+=("$org_export")
done <<< "$org_ids"

# Build one inventory from all exports. Keep original JSON exports unchanged.
jq -s '[.[].items[]] | unique_by(.id)' "${export_files[@]}" > "$random_dir/exported-items.json"
bw list items > "$random_dir/visible-items.json"
jq -e 'type == "array" and all(.[]; (.id | type == "string"))' "$random_dir/visible-items.json" >/dev/null
jq -e --slurpfile exported "$random_dir/exported-items.json"   '([.[].id] - [$exported[0][].id]) | length == 0' "$random_dir/visible-items.json" >/dev/null || {
    echo "Error: some visible vault items are missing from the exports." >&2; exit 1;
  }

# Exports may cover organisation items outside the normal list. Fetch those
# individually to obtain attachment metadata, failing if access is unavailable.
item_ids=$(jq -r '.[].id' "$random_dir/exported-items.json")
: > "$random_dir/attachments.ndjson"
attachment_count=0
expected_attachments=0
while IFS= read -r item_id; do
  [ -n "$item_id" ] || continue
  item=$(jq -c --arg id "$item_id" '.[] | select(.id == $id)' "$random_dir/visible-items.json")
  if [ -z "$item" ]; then
    item=$(bw get item "$item_id") || {
      echo "Error: cannot inspect exported item $item_id for attachments." >&2; exit 1;
    }
  fi
  printf '%s\n' "$item" | jq -e --arg id "$item_id" '
    .id == $id and ((.attachments // []) | type == "array") and
    all((.attachments // [])[];
      (.id | type == "string") and (.id | test("^[A-Za-z0-9-]+$")) and
      (.fileName | type == "string"))' >/dev/null
  attachments=$(printf '%s\n' "$item" | jq -c '(.attachments // [])[]')
  while IFS= read -r att; do
    [ -n "$att" ] || continue
    expected_attachments=$((expected_attachments + 1))
    attachment_id=$(printf '%s\n' "$att" | jq -r '.id')
    attachment_name=$(printf '%s\n' "$att" | jq -r '.fileName')
    relative_path="attachments/$item_id/${attachment_id}_$(sanitise_name "$attachment_name")"
    mkdir -p "$random_dir/attachments/$item_id"
    attachment_path="$random_dir/$relative_path"
    [ ! -e "$attachment_path" ] || { echo "Error: duplicate attachment ID." >&2; exit 1; }
    bw get attachment "$attachment_id" --itemid "$item_id" --output "$attachment_path" >/dev/null || {
      echo "Error: attachment download failed for $item_id/$attachment_id." >&2; exit 1;
    }
    [ -f "$attachment_path" ] || { echo "Error: attachment file missing." >&2; exit 1; }
    actual_size=$(wc -c < "$attachment_path" | tr -d '[:space:]')
    expected_size=$(printf '%s\n' "$att" | jq -r '.size // empty')
    # Preserve the service's size separately. Do not assume it represents
    # plaintext length across client/server versions or encrypted storage.
    # The local plaintext size and hash below describe the downloaded file.
    attachment_sha=$(sha256_of "$attachment_path")
    # Read fileName directly from JSON so original trailing newlines survive.
    printf '%s\n' "$att" | jq -c --arg item "$item_id" --arg path "$relative_path"       --arg sha "$attachment_sha" --arg metadata_size "$expected_size" --argjson bytes "$actual_size"       '{item_id:$item, attachment_id:.id, original_filename:.fileName,
        path:$path, size_bytes:$bytes, service_reported_size:$metadata_size, sha256:$sha}' >> "$random_dir/attachments.ndjson"
    attachment_count=$((attachment_count + 1))
  done <<< "$attachments"
done <<< "$item_ids"
[ "$attachment_count" -eq "$expected_attachments" ] || exit 1

jq -s '.' "$random_dir/attachments.ndjson" > "$random_dir/attachments.json"
jq -n --slurpfile organisations "$random_dir/organisations.json"   --slurpfile items "$random_dir/exported-items.json"   --slurpfile attachments "$random_dir/attachments.json"   --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)"   '{schema_version:1, script_version:"1.5.0", created_utc:$created,
    coverage:"Personal vault plus every listed organisation. Attachments for all exported items.",
    exclusions:["Trash", "Sends", "Server/account configuration"],
    verification:"JSON structure, visible item coverage, attachment downloads and ZIP integrity checked. Attachment plaintext sizes/hashes recorded. Not restore-tested.",
    personal_export:"bitwarden_export.json",
    organisations:[$organisations[0][] | {id, name, export_path:("organisations/" + .id + ".json")}],
    item_count:($items[0] | length), attachment_count:($attachments[0] | length),
    attachments:$attachments[0]}' > "$random_dir/manifest.json"
cat > "$random_dir/RECOVERY.txt" <<'RECOVERY'
Bitwarden backup recovery - bw-export.sh 1.5.0

Decrypt the .gpg file with its matching private key/YubiKey and extract the ZIP
into a private location on an encrypted disk. Test ZIP integrity before use.

bitwarden_export.json: personal vault export.
organisations/<id>.json: separate organisation exports.
manifest.json: scope, excluded data, item/attachment counts, original filenames,
parent item IDs, attachment paths, byte sizes and SHA-256 digests.

Import personal and organisation JSON separately into the appropriate vaults.
Use a disposable test vault first. Imports can create duplicate items.
Attachments are separate files and require explicit reattachment. Use the
manifest and original exported item IDs to map each file to its parent record.
Newly imported items may have new IDs. Restore each original filename from the
manifest. Verify attachment sizes/hashes and inspect representative records.

A filename without '-unverified' indicates a successful GPG decrypt test (or a
successful hash comparison to such a file). It is NOT evidence of a test import
or complete recovery. Older backups may lack this manifest and these notes.
Trash, Sends and server/account configuration are not included.
Keep historical private keys or recovery key material available independently
of the vault. Remove plaintext recovery files when finished.
RECOVERY
# Intermediate inventories contain secrets. Remove before creating the ZIP.
for intermediate in exported-items.json visible-items.json organisations.json attachments.ndjson attachments.json; do
  secure_rm_file "$random_dir/$intermediate"
done

# We no longer need the vault: re-lock it if we unlocked it, and drop the
# session key from the environment.
finish_bw_session

# ----
# Zip, validate, encrypt
# ----
# Subshell keeps the script's working directory unchanged
(cd "$random_dir" && zip -qr "$zip_file" .)

# Validate the archive before we encrypt it - a corrupt ZIP is not a backup.
echo "Testing ZIP integrity..."
if ! unzip -tq "$random_dir/$zip_file" >/dev/null; then
  echo "Error: ZIP integrity test failed for $zip_file. Aborting." >&2
  exit 1
fi

# Encryption uses only the public key - the YubiKey is not needed here.
# The '!' suffix forces gpg to use exactly the resolved subkey.
encrypted_stage=$(mktemp -d "$downloads_dir/.bw-export-encrypted-XXXXXXXXXX")
gpg --batch --trust-model always \
    --recipient "${gpg_enc_fpr}!" \
    --output "$encrypted_stage/$zip_file.gpg" \
    --encrypt "$random_dir/$zip_file"
echo "Encrypted export prepared."

# Remove the entire plaintext working set before PIN entry or replication.
remove_plaintext || { echo "Error: plaintext cleanup failed." >&2; exit 1; }

# Decryption verification is optional when no interactive card is available.
# Failure with the card present preserves ciphertext for inspection.
final_name="$zip_file.gpg"
skip_reason=""
if [ "$interactive_session" -eq 0 ]; then
  skip_reason="non-interactive session"
elif ! card_has_enc_key; then
  skip_reason="no YubiKey holding encryption key $gpg_enc_fpr is present"
fi
if [ -n "$skip_reason" ]; then
  final_name="${zip_file%.zip}-unverified.zip.gpg"
  echo "Warning: $skip_reason - decrypt verification skipped." >&2
  echo "Export will be installed as $final_name (decryption NOT verified)." >&2
  echo "Run '$0 --verify' with the YubiKey present to decrypt-test it and" >&2
  echo "rename the local and NAS copies to '$zip_file.gpg'." >&2
else
  if decrypt_test "$encrypted_stage/$zip_file.gpg"; then
    echo "Decryption test passed."
  else
    # Keep the file out of the rotation glob so it is never installed,
    # rotated or replicated as a backup, but retain it for inspection.
    failed_copy="$downloads_dir/DECRYPT-FAILED-$zip_file.gpg"
    move_no_replace "$encrypted_stage/$zip_file.gpg" "$failed_copy"
    echo "Error: YubiKey present but the export could not be decrypted (wrong card, PIN, or corrupt output)." >&2
    echo "Encrypted file kept at $failed_copy for inspection; previous export left in place, NAS copy skipped." >&2
    exit 1
  fi
fi

# ----
# Publish before rotating. On any failure, existing backups remain available.
# ----
if ! install_checked "$encrypted_stage/$zip_file.gpg" "$downloads_dir/$final_name"; then
  echo "Error: local installation failed. Previous backups retained." >&2
  exit 1
fi
echo "Encrypted export saved to $downloads_dir/$final_name"
if ! rotate_into_archive "$downloads_dir" "$final_name"; then
  echo "Error: local rotation incomplete. New backup retained. Older files may be in current or archive/." >&2
  exit 1
fi

if nas_available; then
  mkdir -p "$nas_dir/archive"
  echo "Copying encrypted export to NAS..."
  if ! install_checked "$downloads_dir/$final_name" "$nas_dir/$final_name"; then
    echo "Error: NAS installation failed. Local backup retained. Existing NAS backups were not rotated." >&2
    exit 1
  fi
  echo "NAS copy verified by SHA-256 and published."
  if ! rotate_into_archive "$nas_dir" "$final_name"; then
    echo "Error: NAS rotation incomplete. New backup retained. Older files may be in current or archive/." >&2
    exit 1
  fi
else
  echo "NAS unavailable at $nas_mount (or $nas_dir missing). Local backup only."
fi

echo "Bitwarden export completed. Decryption verification is not a restore test."
