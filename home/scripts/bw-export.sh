#!/usr/bin/env bash
#
# bw-export.sh — Bitwarden vault + attachment backup
# Version: 1.3.0
#
# Exports the full Bitwarden vault (JSON) and all item attachments,
# zips them, encrypts the archive with a GPG public key (private key
# held on a YubiKey), verifies decryptability, and copies the result
# to a NAS if mounted.
#
# Plaintext is staged under $TMPDIR (not ~/Documents) to reduce the chance
# of iCloud/backup capture. Decrypt verification is skipped in
# non-interactive sessions.
#
# v1.3.0:
#   - Only 'bw lock' if this script performed the unlock; pre-existing
#     unlocked state is left as found. BW_SESSION is unset once the last
#     Bitwarden operation has completed.
#   - Rotation of the previous local (and NAS) export into archive/ is
#     deferred until the new export has been encrypted and verified, so a
#     failed run never removes the last known-good backup.
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
# Usage: run interactively with the vault unlocked (bw unlock).
#
set -Eeuo pipefail

# ----
# Configuration
# ----
downloads_dir="$HOME/Documents/encrypted/bw-export"
nas_mount="/Volumes/home"
nas_dir="$nas_mount/documents/encrypted/bw-export"
gpg_key="0xA11E70ADFDA60CF9"
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
}
trap cleanup EXIT INT TERM

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

# Resolve the recipient to exactly one primary key and pick its current
# encryption-capable (sub)key fingerprint. Encrypting to "<fpr>!" removes
# any ambiguity from multiple matching keys and, together with an explicit
# trust model, avoids interactive prompts.
gpg_colons=$(gpg --batch --with-colons --list-keys -- "$gpg_key" 2>/dev/null) || {
  echo "Error: GPG key $gpg_key not found in keyring." >&2
  exit 1
}
primary_count=$(printf '%s\n' "$gpg_colons" | grep -c '^pub:' || true)
if [ "$primary_count" -ne 1 ]; then
  echo "Error: GPG key spec '$gpg_key' matches $primary_count primary keys; expected exactly 1." >&2
  exit 1
fi
# Field 2 = validity (i/d/r/e/n = invalid/disabled/revoked/expired/never-trust),
# field 6 = creation time, field 12 = capabilities (lowercase = this key).
gpg_enc_fpr=$(printf '%s\n' "$gpg_colons" | awk -F: '
  $1 == "pub" || $1 == "sub" {
    want = (index($12, "e") > 0 && $2 !~ /^[idren]$/)
    created = $6 + 0
    next
  }
  $1 == "fpr" && want {
    if (created >= best) { best = created; fpr = $10 }
    want = 0
    next
  }
  { want = 0 }
  END { if (fpr != "") print fpr }')
if [ -z "$gpg_enc_fpr" ]; then
  echo "Error: GPG key $gpg_key has no valid encryption-capable (sub)key." >&2
  exit 1
fi
echo "Using GPG encryption key fingerprint $gpg_enc_fpr"

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
random_dir=$(mktemp -d "${TMPDIR:-/tmp}/bw_export_XXXX")

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
# In a non-interactive context (cron/launchd) skip it rather than hang.
if [[ ! -t 0 ]]; then
  echo "Warning: non-interactive session — skipping decrypt verification." >&2
  echo "Run 'gpg --decrypt $downloads_dir/$zip_file.gpg >/dev/null' manually to verify." >&2
else
  if gpg --decrypt "$random_dir/$zip_file.gpg" >/dev/null 2>&1; then
    echo "Decryption test passed."
  else
    # Keep the unverified file out of the rotation glob so it can never be
    # mistaken for (or archived as) a good backup, but retain it for inspection.
    failed_copy="$downloads_dir/UNVERIFIED-$zip_file.gpg"
    mv "$random_dir/$zip_file.gpg" "$failed_copy"
    echo "Error: could not decrypt the export — check your YubiKey." >&2
    echo "Encrypted file kept at $failed_copy for inspection; previous export left in place, NAS copy skipped." >&2
    exit 1
  fi
fi

# ----
# Rotate previous local export(s) and install the new one
# ----
# Deferred until here so that a failure anywhere above leaves the previous
# known-good export untouched in $downloads_dir.
find "$downloads_dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*" \
  -exec mv {} "$downloads_dir/archive/" \;
mv "$random_dir/$zip_file.gpg" "$downloads_dir/"
echo "Encrypted export saved to $downloads_dir/$zip_file.gpg"

# ----
# Copy to NAS if mounted
# ----
# Check that $nas_mount is an actual mount point (not merely a directory
# left behind on the local disk) before touching anything under it.
# 'df -P' reports the filesystem's mount point in the last column.
nas_mounted=0
if [ -d "$nas_mount" ]; then
  mounted_on=$(df -P -- "$nas_mount" 2>/dev/null | awk 'NR == 2 {print $NF}')
  [ "$mounted_on" = "$nas_mount" ] && nas_mounted=1
fi

if [ "$nas_mounted" -eq 1 ] && [ -d "$nas_dir" ]; then
  mkdir -p "$nas_dir/archive"
  echo "Copying $zip_file.gpg to $nas_dir"
  cp "$downloads_dir/$zip_file.gpg" "$nas_dir/"

  # Verify the copy byte-for-byte before rotating the previous NAS export.
  src_sha=$(sha256_of "$downloads_dir/$zip_file.gpg")
  dst_sha=$(sha256_of "$nas_dir/$zip_file.gpg")
  if [ "$src_sha" != "$dst_sha" ]; then
    echo "Error: NAS copy verification failed (SHA-256 mismatch)." >&2
    echo "  local: $src_sha" >&2
    echo "  nas:   $dst_sha" >&2
    rm -f -- "$nas_dir/$zip_file.gpg"
    echo "Corrupt NAS copy removed; previous NAS export left in place." >&2
    exit 1
  fi
  echo "NAS copy verified (SHA-256 $src_sha)."

  # Rotate everything except the file we just copied.
  find "$nas_dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*" \
    ! -name "$zip_file.gpg" -exec mv {} "$nas_dir/archive/" \;
else
  echo "NAS not mounted at $nas_mount (or $nas_dir missing) — skipping NAS copy."
fi

echo "Bitwarden export completed."