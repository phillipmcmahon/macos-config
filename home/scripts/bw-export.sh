#!/usr/bin/env bash
#
# bw-export.sh — Bitwarden vault + attachment backup
# Version: 1.3.4
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
# decrypt-tested directly if no local copy remains).
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
# A lock in $downloads_dir prevents concurrent runs of either mode.
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
  if [ "$lock_held" -eq 1 ]; then
    rm -rf "$lock_dir"
  fi
  if [ -n "$random_dir" ] && [ -d "$random_dir" ]; then
    # See secure_rm_file for the APFS caveat.
    if command -v shred >/dev/null 2>&1; then
      find "$random_dir" -type f -exec shred -u -n 3 {} \;
    else
      find "$random_dir" -type f -exec rm -P {} \;
    fi
    rm -rf "$random_dir"
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
# which macOS does not ship. The PID inside lets a later run detect and
# clear a lock left behind by a crashed/killed process.
acquire_lock() {
  local other_pid
  mkdir -p "$downloads_dir"
  if mkdir "$lock_dir" 2>/dev/null; then
    lock_held=1
    printf '%s\n' "$$" > "$lock_dir/pid"
    return 0
  fi
  other_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
  if [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null; then
    echo "Error: another bw-export.sh (PID $other_pid) is running. Aborting." >&2
    exit 1
  fi
  echo "Warning: removing stale lock $lock_dir (owner PID '${other_pid:-unknown}' not running)." >&2
  rm -rf "$lock_dir"
  if mkdir "$lock_dir" 2>/dev/null; then
    lock_held=1
    printf '%s\n' "$$" > "$lock_dir/pid"
    return 0
  fi
  echo "Error: could not acquire lock $lock_dir. Aborting." >&2
  exit 1
}

# ----
# Pre-flight checks
# ----

# Ensure all required tools are installed
for cmd in bw jq gpg zip unzip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed. Please install it first." >&2
    exit 1
  fi
done
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "Error: neither 'shasum' nor 'sha256sum' is installed." >&2
  exit 1
fi

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

# ----
# --verify mode: decrypt-test pending '-unverified' exports and rename
# the local copy and its NAS copy together.
# ----
verify_pending() {
  local f name verified_name nas_note has_nas candidate rc=0 count=0
  if [[ ! -t 0 ]]; then
    echo "Error: --verify needs an interactive session (YubiKey PIN entry)." >&2
    return 1
  fi
  if nas_available; then
    nas_note="NAS mounted; NAS copies will be renamed too."
  else
    nas_note="NAS not mounted; NAS copies (if any) keep their '-unverified' name until a later --verify with the NAS mounted."
  fi
  echo "$nas_note"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    count=$((count + 1))
    name=$(basename "$f")
    verified_name="${name%-unverified.zip.gpg}.zip.gpg"
    has_nas=0
    echo "Verifying $name..."

    # --- Phase 1: all checks. Nothing is renamed until every check passes. ---

    # Never overwrite an existing verified file (local or NAS).
    if [ -e "$downloads_dir/$verified_name" ]; then
      echo "Error: $downloads_dir/$verified_name already exists; refusing to overwrite. $name left as-is." >&2
      rc=1; continue
    fi
    if nas_available && [ -f "$nas_dir/$name" ]; then
      has_nas=1
      if [ -e "$nas_dir/$verified_name" ]; then
        echo "Error: $nas_dir/$verified_name already exists; refusing to overwrite. $name left as-is." >&2
        rc=1; continue
      fi
    fi

    # The NAS copy is only considered verified if it is byte-identical to
    # the local file we are about to decrypt-test.
    if [ "$has_nas" -eq 1 ] && [ "$(sha256_of "$f")" != "$(sha256_of "$nas_dir/$name")" ]; then
      echo "Error: NAS copy $name differs from the local copy (SHA-256 mismatch); nothing renamed." >&2
      rc=1; continue
    fi

    if ! gpg --decrypt "$f" >/dev/null 2>&1; then
      echo "Error: $name failed to decrypt — left as-is for inspection." >&2
      rc=1; continue
    fi

    # --- Phase 2: all checks passed — rename local, then NAS. ---
    # Two separate renames cannot be atomic; if the second fails the NAS
    # copy stays '-unverified' and the NAS pass below reconciles it later.
    mv "$f" "$downloads_dir/$verified_name"
    echo "  local: renamed to $verified_name"
    if [ "$has_nas" -eq 1 ]; then
      if mv "$nas_dir/$name" "$nas_dir/$verified_name"; then
        echo "  nas:   renamed to $verified_name"
      else
        echo "Error: local copy renamed but NAS rename failed; NAS copy remains $name." >&2
        rc=1
      fi
    fi
  done < <(find "$downloads_dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*-unverified.zip.gpg" | sort)

  [ "$count" -gt 0 ] || echo "No '-unverified' exports found in $downloads_dir."

  # --- Pass 2: reconcile NAS '-unverified' files whose local copy has ---
  # --- already been verified (e.g. the NAS was offline at the time).   ---
  if nas_available; then
    local nas_count=0 local_verified
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      nas_count=$((nas_count + 1))
      name=$(basename "$f")
      verified_name="${name%-unverified.zip.gpg}.zip.gpg"
      echo "Reconciling NAS copy $name..."
      if [ -e "$nas_dir/$verified_name" ]; then
        echo "Error: $nas_dir/$verified_name already exists; refusing to overwrite. $name left as-is." >&2
        rc=1; continue
      fi
      # Prefer matching against a verified local copy (current or archived)
      # so the YubiKey is not needed; otherwise decrypt-test the NAS file.
      local_verified=""
      for candidate in "$downloads_dir/$verified_name" "$downloads_dir/archive/$verified_name"; do
        [ -f "$candidate" ] && { local_verified="$candidate"; break; }
      done
      if [ -n "$local_verified" ]; then
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
      mv "$f" "$nas_dir/$verified_name"
      echo "  nas:   renamed to $verified_name"
    done < <(find "$nas_dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*-unverified.zip.gpg" | sort)
    [ "$nas_count" -gt 0 ] || echo "No '-unverified' exports left on NAS."
  fi

  return "$rc"
}

case "${1:-}" in
  --verify)
    acquire_lock
    verify_pending
    exit $?
    ;;
  "")
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
find "$downloads_dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*.zip.gpg" \
  -exec mv {} "$downloads_dir/archive/" \;
mv "$random_dir/$zip_file.gpg" "$downloads_dir/$final_name"
echo "Encrypted export saved to $downloads_dir/$final_name"

# ----
# Copy to NAS if mounted
# ----
if nas_available; then
  mkdir -p "$nas_dir/archive"
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
  find "$nas_dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*.zip.gpg" \
    ! -name "$final_name" -exec mv {} "$nas_dir/archive/" \;
else
  echo "NAS not mounted at $nas_mount (or $nas_dir missing) — skipping NAS copy."
fi

echo "Bitwarden export completed."