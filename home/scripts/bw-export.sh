#!/usr/bin/env bash
#
# bw-export.sh — Bitwarden vault + attachment backup
# Version: 1.2.0
#
# Exports the full Bitwarden vault (JSON) and all item attachments,
# zips them, encrypts the archive with a GPG public key (private key
# held on a YubiKey), verifies decryptability, and copies the result
# to a NAS if mounted.
#
# Plaintext is staged in $TMPDIR (not ~/Documents) to avoid iCloud/backup
# capture. Decrypt verification is skipped in non-interactive sessions.
#
# v1.2.0:
#   - Attachment download loops use process substitution (< <(...)) instead
#     of pipe-subshell (printf | while) so that individual download failures
#     propagate to the script and abort the export before encryption
#   - APFS limitation documented on the cleanup shred/rm -P fallback
#
# Requirements: bw (Bitwarden CLI), jq, gpg, zip
# Usage: run interactively with the vault unlocked (bw unlock).
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
downloads_dir="$HOME/Documents/encrypted/bw-export"
nas_dir="/Volumes/home/documents/encrypted/bw-export"
gpg_key="0xA11E70ADFDA60CF9"
zip_file="bw-auto-export-$(date +%Y%m%d-%H%M%S%z).zip"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

# Ensure all required tools are installed
for cmd in bw jq gpg zip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed. Please install it first." >&2
    exit 1
  fi
done

# Verify the GPG public key is in the keyring before doing any work
if ! gpg --list-keys "$gpg_key" >/dev/null 2>&1; then
  echo "Error: GPG key $gpg_key not found in keyring." >&2
  exit 1
fi

mkdir -p "$downloads_dir/archive"

# ---------------------------------------------------------------------------
# Unlock vault and capture session key
# ---------------------------------------------------------------------------
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
    ;;
  unlocked)
    echo "Vault already unlocked."
    ;;
  *)
    echo "Error: unexpected Bitwarden status '$bw_status'." >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Secure temp dir with guaranteed cleanup
# ---------------------------------------------------------------------------
# Use $TMPDIR (per-user, mode 0700, not iCloud-synced, wiped on reboot)
# instead of staging plaintext inside ~/Documents where iCloud/Arq/Spotlight
# could capture it before the cleanup trap runs.
random_dir=$(mktemp -d "${TMPDIR:-/tmp}/bw_export_XXXXXXXXXX")

cleanup() {
  set +e  # cleanup is best-effort; never abort mid-wipe
  if [ -d "$random_dir" ]; then
    # Best-effort overwrite of plaintext files before unlinking. On APFS
    # (the default macOS filesystem since High Sierra) this is largely
    # ineffective: APFS is copy-on-write, so overwritten blocks may not
    # correspond to the original data's physical location. FileVault
    # (full-disk encryption) is the real control for data-at-rest
    # protection. The overwrite is retained as defence-in-depth for any
    # non-APFS volumes (e.g. external HFS+ drives).
    if command -v shred >/dev/null 2>&1; then
      find "$random_dir" -type f -exec shred -u -n 3 {} \;
    else
      find "$random_dir" -type f -exec rm -P {} \;
    fi
    rm -rf "$random_dir"
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Archive previous local exports
# ---------------------------------------------------------------------------
find "$downloads_dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*" \
  -exec mv {} "$downloads_dir/archive/" \;

# ---------------------------------------------------------------------------
# Export vault
# ---------------------------------------------------------------------------
bw sync
echo "Exporting vault to $random_dir/bitwarden_export.json..."
bw export --format json --output "$random_dir/bitwarden_export.json"

# ---------------------------------------------------------------------------
# Download attachments
# ---------------------------------------------------------------------------
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

  # Sanitize the item name for filesystem use and suffix with the id
  # to avoid collisions between identically named items.
  item_name=$(printf '%s' "$item" | jq -r '.name' | tr '/:' '__')
  item_dir="$random_dir/${item_name}_${item_id}"

  mkdir -p "$item_dir"

  while IFS= read -r att; do
    attachment_name=$(printf '%s' "$att" | jq -r '.fileName')
    attachment_id=$(printf '%s' "$att" | jq -r '.id')
    safe_name=$(printf '%s' "$attachment_name" | tr '/:' '__')
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

# Lock the vault as soon as we no longer need it
bw lock

# ---------------------------------------------------------------------------
# Zip and encrypt
# ---------------------------------------------------------------------------
# Subshell keeps the script's working directory unchanged
(cd "$random_dir" && zip -r "$zip_file" .)

# Encryption uses only the public key — the YubiKey is not needed here
gpg --recipient "$gpg_key" --encrypt "$random_dir/$zip_file"
mv "$random_dir/$zip_file.gpg" "$downloads_dir/"
echo "Encrypted export saved to $downloads_dir/$zip_file.gpg"

# ---------------------------------------------------------------------------
# Verify the export is decryptable (requires YubiKey + PIN)
# ---------------------------------------------------------------------------
# A backup that can't be decrypted is worthless — hard-fail before NAS copy.
# The decryption test requires the YubiKey + interactive PIN entry.
# In a non-interactive context (cron/launchd) skip it rather than hang.
if [[ ! -t 0 ]]; then
  echo "Warning: non-interactive session — skipping decrypt verification." >&2
  echo "Run 'gpg --decrypt $downloads_dir/$zip_file.gpg >/dev/null' manually to verify." >&2
elif ! gpg --decrypt "$downloads_dir/$zip_file.gpg" >/dev/null 2>&1; then
  echo "Error: could not decrypt the export — check your YubiKey." >&2
  echo "Encrypted file kept at $downloads_dir/$zip_file.gpg for inspection; NAS copy skipped." >&2
  exit 1
fi
echo "Decryption test passed."

# ---------------------------------------------------------------------------
# Copy to NAS if mounted
# ---------------------------------------------------------------------------
if [ -d "$nas_dir" ]; then
  mkdir -p "$nas_dir/archive"
  find "$nas_dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*" \
    -exec mv {} "$nas_dir/archive/" \;
  echo "Copying $zip_file.gpg to $nas_dir"
  cp "$downloads_dir/$zip_file.gpg" "$nas_dir/"
fi

echo "Bitwarden export completed."

