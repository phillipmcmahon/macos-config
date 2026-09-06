#!/usr/bin/env bash
#
# bw-export.sh — Bitwarden vault + attachment backup
# Version: 1.3.7
#
# Exports the full Bitwarden vault (JSON) and all item attachments,
# zips them, encrypts the archive with a GPG public key (private key
# held on a YubiKey), verifies decryptability, and copies the result
# to a NAS if mounted.
#
# Plaintext is staged under $TMPDIR (not ~/Documents) to reduce the chance
# of iCloud/backup capture.
#
# Decrypt verification needs the YubiKey + PIN, so it only runs in an
# interactive session. Unattended runs (cron/launchd) ARE allowed to become
# the current backup — an unverified backup beats none — but are named
# bw-auto-export-<ts>-unverified.zip.gpg so they are never mistaken for a
# recovery-tested one. Run './bw-export.sh --verify' later (with the
# YubiKey present): it decrypt-tests every '-unverified' export and renames
# BOTH the local copy and its NAS copy (after confirming they are identical).
# If the NAS is not mounted at that time, the NAS copy keeps its
# '-unverified' name; a later '--verify' with the NAS mounted reconciles it
# in a second pass (hash-matched against the verified local copy, or
# decrypt-tested directly if no local copy remains). Both passes cover the
# current directory and archive/.
#
# v1.3.7:
#   - Both local and NAS installation refuse to proceed if a file with the
#     target name already exists, preventing silent overwrites.
#
# v1.3.6:
#   - Lock is released as the very last step of cleanup(), after the
#     plaintext staging directory has been wiped.
#   - --verify captures the '-unverified' file list up front so a failing
#     'find' aborts the run instead of silently yielding an empty list.
#   - Rotation into archive/ never overwrites: an existing identically
#     named archive file aborts before anything is moved.
#
# v1.3.5:
#   - Lock is never removed automatically (the check-PID/rm/mkdir sequence
#     was racy); a held lock aborts with instructions for manual removal.
#   - --verify scans current dir AND archive/, both locally and on the NAS,
#     renaming files in place.
#   - Mode is parsed first; --verify only requires gpg + a SHA-256 tool and
#     skips encryption-key resolution.
#
# v1.3.4:
#   - --verify has a second reconciliation pass over NAS '-unverified'
#     files, so a NAS copy that was offline during an earlier --verify
#     can still be reconciled (matched against a verified local copy, or
#     decrypt-tested directly if no local copy remains).
#   - Concurrency lock (mkdir-based, stale-PID aware): two exports, or an
#     export and a --verify, cannot run at the same time.
#   - INT/TERM traps now just exit; cleanup runs once from the EXIT trap.
#   - Wording: local/NAS rename happens "after all checks", not atomically.
#
# v1.3.3:
#   - --verify performs ALL checks (decrypt test, NAS hash, no existing
#     target names) before renaming anything; local and NAS copies are then
#     renamed together. Never overwrites an existing verified file.
#   - Rotation comment clarified: an unattended run deliberately makes its
#     '-unverified' export current and rotates the previous one.
#
# v1.3.2:
#   - GPG encryption subkey is chosen by explicit creation timestamp
#     (field 6), not by listing order.
#   - New '--verify' mode: decrypt-tests '-unverified' exports and renames
#     the local and NAS copies together.
#
# v1.3.1:
#   - Unverified (non-interactive) exports are installed/replicated under a
#     distinct '-unverified' name; a failed decrypt test is kept as
#     DECRYPT-FAILED-*.zip.gpg outside the rotation glob.
#   - Rotation globs narrowed to bw-auto-export-*.zip.gpg.
#   - Simpler GPG encryption-subkey selection (still --with-colons).
#   - 'df -P' called without '--' for macOS df compatibility.
#   - mktemp template restored to ten X's.
#
# v1.3.0:
#   - Only 'bw lock' if this script performed the unlock; pre-existing
#     unlocked state is left as found. BW_SESSION is unset once the last
#     Bitwarden operation has completed.
#   - Rotation of the previous local (and NAS) export into archive/ is
#     deferred until the new export has been encrypted (and, when
#     interactive, decrypt-tested), so a failed run never removes the
#     previous backup.
#   - ZIP archive is integrity-tested (unzip -t) before encryption.
#   - Plaintext ZIP is securely deleted immediately after encryption.
#   - "Decryption test passed" is only printed when a decrypt actually ran.
#   - NAS mount point is validated (not just the directory path) and the
#     NAS copy is verified via SHA-256 comparison.
#   - The exact encryption-capable GPG subkey fingerprint is resolved up
#     front and used explicitly (no key ambiguity / trust prompts).
#   - Stricter filename sanitisation (control chars / unusual chars).
#
# v1.2.0:
#   - Attachment download loops use process substitution (< <(...)) instead
#     of pipe-subshell (printf | while) so that individual download failures
#     propagate to the script and abort the export before encryption
#   - APFS limitation documented on the cleanup shred/rm -P fallback
#
# Requirements: bw (Bitwarden CLI), jq, gpg, zip, unzip,
#               shasum or sha256sum
# Usage:
#   bw-export.sh            run an export (interactive: vault unlock + decrypt test)
#   bw-export.sh --verify   decrypt-test pending '-unverified' exports and
#                           rename local + NAS copies (needs YubiKey + TTY)
# A lock in $downloads_dir prevents concurrent runs of either mode; a lock
# left by a hard-killed run must be removed manually (the script says how).
#
set -Eeuo pipefail

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
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    sha256sum -- "$1" | awk '{print $1}'
  fi
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
    if [ -e "$dir/archive/$name" ]; then
      echo "Error: $dir/archive/$name already exists; refusing to overwrite it during rotation." >&2
      collisions=$((collisions + 1))
    fi
  done <<< "$listing"
  [ "$collisions" -eq 0 ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name=$(basename "$f")
    [ "$name" != "$keep" ] || continue
    mv "$f" "$dir/archive/$name"
  done <<< "$listing"
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
lock_held=0
cleanup() {
  set +e  # cleanup is best-effort; never abort mid-wipe
  finish_bw_session
  if [ -n "$random_dir" ] && [ -d "$random_dir" ]; then
    # See secure_rm_file for the APFS caveat.
    if command -v shred >/dev/null 2>&1; then
      find "$random_dir" -type f -exec shred -u -n 3 {} \;
    else
      find "$random_dir" -type f -exec rm -P {} \;
    fi
    rm -rf "$random_dir"
  fi
  # Release the lock last, only once all plaintext has been wiped, so a
  # concurrent run can never start while staging data still exists.
  if [ "$lock_held" -eq 1 ]; then
    rm -rf "$lock_dir"
  fi
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

verify_pending() {
  local f name verified_name dir nas_copy nas_copy_dir local_verified
  local rc=0 count=0 nas_count=0
  local local_dirs=("$downloads_dir" "$downloads_dir/archive")
  local nas_dirs=("$nas_dir" "$nas_dir/archive")
  local nas_ok=0 local_pending nas_pending

  if [[ ! -t 0 ]]; then
    echo "Error: --verify needs an interactive session (YubiKey PIN entry)." >&2
    return 1
  fi
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
      if [ "$(sha256_of "$f")" != "$(sha256_of "$nas_copy")" ]; then
        echo "Error: NAS copy $nas_copy differs from the local copy (SHA-256 mismatch); nothing renamed." >&2
        rc=1; continue
      fi
    fi
    if ! gpg --decrypt "$f" >/dev/null 2>&1; then
      echo "Error: $name failed to decrypt — left as-is for inspection." >&2
      rc=1; continue
    fi

    # --- Phase 2: all checks passed — rename local, then NAS. ---
    # Two separate renames cannot be atomic; if the second fails the NAS
    # copy stays '-unverified' and pass 2 below reconciles it later.
    mv "$f" "$dir/$verified_name"
    echo "  local: renamed to $dir/$verified_name"
    if [ -n "$nas_copy" ]; then
      if mv "$nas_copy" "$nas_copy_dir/$verified_name"; then
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
        if [ "$(sha256_of "$local_verified")" != "$(sha256_of "$f")" ]; then
          echo "Error: NAS copy $name differs from verified local copy $local_verified (SHA-256 mismatch); left as-is." >&2
          rc=1; continue
        fi
        echo "  matches verified local copy $local_verified"
      elif gpg --decrypt "$f" >/dev/null 2>&1; then
        echo "  no local copy; decrypt test on NAS copy passed"
      else
        echo "Error: no local copy and NAS copy $name failed to decrypt — left as-is." >&2
        rc=1; continue
      fi
      mv "$f" "$dir/$verified_name"
      echo "  nas:   renamed to $dir/$verified_name"
    done <<< "$nas_pending"
    [ "$nas_count" -gt 0 ] || echo "No '-unverified' exports left on NAS (current or archive/)."
  fi

  return "$rc"
}

# ----
# Mode dispatch — parsed before any tool/key checks so each mode only
# demands what it actually uses.
# ----
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
    echo "Vault is locked — unlocking..."
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
random_dir=$(mktemp -d "${TMPDIR:-/tmp}/bw_export_XXXXXXXXXX")

# ----
# Export vault
# ----
bw sync
echo "Exporting vault to $random_dir/bitwarden_export.json..."
bw export --format json --output "$random_dir/bitwarden_export.json"

# ----
# Download attachments
# ----
# Capture output first so a failure in 'bw list items' aborts the script
# instead of silently producing an empty loop.
items=$(bw list items | jq -c '.[] | select(.attachments != null)')

# Process substitution (< <(...)) keeps the loop body in the current shell
# so that (a) 'set -e' propagates failures from 'bw get attachment' to the
# script, and (b) any variables set inside the loop are visible afterwards.
# A pipe (printf | while) runs the loop in a subshell where failures are
# silently swallowed.
attachment_errors=0

while IFS= read -r item; do
  [ -n "$item" ] || continue
  item_id=$(printf '%s' "$item" | jq -r '.id')

  # Sanitise the item name for filesystem use and suffix with the id
  # to avoid collisions between identically named items.
  item_name=$(printf '%s' "$item" | jq -r '.name')
  item_dir="$random_dir/$(sanitise_name "$item_name")_${item_id}"

  mkdir -p "$item_dir"

  while IFS= read -r att; do
    attachment_name=$(printf '%s' "$att" | jq -r '.fileName')
    attachment_id=$(printf '%s' "$att" | jq -r '.id')
    safe_name=$(sanitise_name "$attachment_name")
    echo "Downloading '$attachment_name' for item '$item_name'..."
    # Fetch by attachment id (not filename) so two identically named
    # attachments on one item each download their own content.
    if ! bw get attachment "$attachment_id" --itemid "$item_id" --output "$item_dir/${attachment_id}_${safe_name}"; then
      echo "Error: failed to download attachment '$attachment_name' (id: $attachment_id) for item '$item_name'." >&2
      attachment_errors=$((attachment_errors + 1))
    fi
  done < <(printf '%s' "$item" | jq -c '.attachments[]')
done < <(printf '%s\n' "$items")

if [[ "$attachment_errors" -gt 0 ]]; then
  echo "Error: $attachment_errors attachment(s) failed to download. Aborting." >&2
  exit 1
fi

# We no longer need the vault: re-lock it if we unlocked it, and drop the
# session key from the environment.
finish_bw_session

# ----
# Zip, validate, encrypt
# ----
# Subshell keeps the script's working directory unchanged
(cd "$random_dir" && zip -r "$zip_file" .)

# Validate the archive before we encrypt it — a corrupt ZIP is not a backup.
echo "Testing ZIP integrity..."
if ! unzip -tq "$random_dir/$zip_file" >/dev/null; then
  echo "Error: ZIP integrity test failed for $zip_file. Aborting." >&2
  exit 1
fi

# Encryption uses only the public key — the YubiKey is not needed here.
# The '!' suffix forces gpg to use exactly the resolved subkey.
gpg --batch --trust-model always \
    --recipient "${gpg_enc_fpr}!" \
    --output "$random_dir/$zip_file.gpg" \
    --encrypt "$random_dir/$zip_file"
echo "Encrypted export written to staging: $random_dir/$zip_file.gpg"

# The plaintext ZIP is no longer needed — remove it now rather than
# leaving it around until the EXIT trap.
secure_rm_file "$random_dir/$zip_file"

# ----
# Verify the export is decryptable (requires YubiKey + PIN)
# ----
# A backup that can't be decrypted is worthless — hard-fail before the
# previous local export is rotated out or anything is copied to the NAS.
# The decryption test requires the YubiKey + interactive PIN entry.
#
# Policy for non-interactive runs (cron/launchd): the export IS installed
# and replicated — an unverified backup is better than none — but under a
# distinct '-unverified' name so it can never be confused with a
# recovery-tested backup. Verify it manually and rename it when convenient.
final_name="$zip_file.gpg"
if [[ ! -t 0 ]]; then
  final_name="${zip_file%.zip}-unverified.zip.gpg"
  echo "Warning: non-interactive session — decrypt verification skipped." >&2
  echo "Export will be installed as $final_name (NOT recovery-tested)." >&2
  echo "Run '$0 --verify' with the YubiKey present to decrypt-test it and" >&2
  echo "rename the local and NAS copies to '$zip_file.gpg'." >&2
else
  if gpg --decrypt "$random_dir/$zip_file.gpg" >/dev/null 2>&1; then
    echo "Decryption test passed."
  else
    # Keep the file out of the rotation glob so it is never installed,
    # rotated or replicated as a backup, but retain it for inspection.
    failed_copy="$downloads_dir/DECRYPT-FAILED-$zip_file.gpg"
    mv "$random_dir/$zip_file.gpg" "$failed_copy"
    echo "Error: could not decrypt the export — check your YubiKey." >&2
    echo "Encrypted file kept at $failed_copy for inspection; previous export left in place, NAS copy skipped." >&2
    exit 1
  fi
fi

# ----
# Rotate previous local export(s) and install the new one
# ----
# Deferred until here so that a failure anywhere above (export, zip test,
# encryption, or an interactive decrypt test) leaves the previous export
# untouched in $downloads_dir. Note: in an unattended run the decrypt test
# is skipped by design, so a new '-unverified' export deliberately becomes
# current here and the previous (possibly verified) export is rotated into
# archive/. It is not deleted, and the '-unverified' name makes the
# distinction visible until '--verify' has been run.
if [ -e "$downloads_dir/$final_name" ]; then
  echo "Error: $downloads_dir/$final_name already exists; refusing to overwrite. New export left in staging and will be wiped." >&2
  exit 1
fi
if ! rotate_into_archive "$downloads_dir"; then
  echo "Error: local rotation aborted; new export left in staging and will be wiped. Previous export untouched." >&2
  exit 1
fi
mv "$random_dir/$zip_file.gpg" "$downloads_dir/$final_name"
echo "Encrypted export saved to $downloads_dir/$final_name"

# ----
# Copy to NAS if mounted
# ----
if nas_available; then
  mkdir -p "$nas_dir/archive"
  if [ -e "$nas_dir/$final_name" ]; then
    echo "Error: $nas_dir/$final_name already exists; refusing to overwrite. NAS copy skipped." >&2
    exit 1
  fi
  echo "Copying $final_name to $nas_dir"
  cp "$downloads_dir/$final_name" "$nas_dir/"

  # Verify the copy byte-for-byte before rotating the previous NAS export.
  src_sha=$(sha256_of "$downloads_dir/$final_name")
  dst_sha=$(sha256_of "$nas_dir/$final_name")
  if [ "$src_sha" != "$dst_sha" ]; then
    echo "Error: NAS copy verification failed (SHA-256 mismatch)." >&2
    echo "  local: $src_sha" >&2
    echo "  nas:   $dst_sha" >&2
    rm -f -- "$nas_dir/$final_name"
    echo "Corrupt NAS copy removed; previous NAS export left in place." >&2
    exit 1
  fi
  echo "NAS copy verified (SHA-256 $src_sha)."

  # Rotate everything except the file we just copied.
  if ! rotate_into_archive "$nas_dir" "$final_name"; then
    echo "Error: NAS rotation aborted; new NAS copy $final_name kept alongside the previous export(s)." >&2
    exit 1
  fi
else
  echo "NAS not mounted at $nas_mount (or $nas_dir missing) — skipping NAS copy."
fi

echo "Bitwarden export completed."