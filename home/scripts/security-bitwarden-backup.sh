#!/usr/bin/env bash
#
# Script: security-bitwarden-backup.sh
# Purpose: Back up vaults and attachments in encrypted archives.
# Version: 1.0.0
# Requires: Bash 5+, bw, jq, gpg, zip, unzip and adjacent lib/.
# Documentation: docs/USER-MANUAL.md
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION='1.0.0'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"

# Command interface
usage() {
    cat << EOF
${0##*/} $SCRIPT_VERSION
Usage: ${0##*/} [--verify]

Default: export personal and organisation vaults and attachments, validate and encrypt.
Existing sessions are retained. A session unlocked here is relocked before publication.

Options:
  --verify      Decrypt pending backups and reconcile matching NAS copies
  --version     Show version
  -h, --help    Show help

Settings: ~/.config/bitwarden-backup/config. Secrets come from bw, not this file.
Unattended export needs a usable BW_SESSION. A decrypt test is not a restore test.
EOF
}

# Helpers
sanitise_name() {
    local s
    s=$(printf '%s' "$1" |
        LC_ALL=C tr -d '\000-\037\177' |
        LC_ALL=C tr -c 'A-Za-z0-9._ ()-' '_' |
        LC_ALL=C tr -s '_' |
        LC_ALL=C sed -e 's/^[. ]*//' -e 's/[. ]*$//' |
        LC_ALL=C cut -c1-100)
    [ -n "$s" ] || s="unnamed"
    printf '%s' "$s"
}

secure_rm_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    if command -v shred > /dev/null 2>&1; then
        shred -u -n 3 -- "$f"
    else
        rm -P -- "$f"
    fi
}

sha256_of() {
    local output digest
    if command -v shasum > /dev/null 2>&1; then
        output=$(shasum -a 256 -- "$1") || return 1
    else
        output=$(sha256sum -- "$1") || return 1
    fi
    digest=${output%% *}
    [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || {
        err "invalid SHA-256 output for $1." >&2
        return 1
    }
    printf '%s\n' "$digest"
}

hashes_match() {
    local left right
    left=$(sha256_of "$1") || {
        err "cannot hash $1." >&2
        return 1
    }
    right=$(sha256_of "$2") || {
        err "cannot hash $2." >&2
        return 1
    }
    [ "$left" = "$right" ]
}

move_no_replace() {
    [ ! -e "$2" ] && [ ! -L "$2" ] || {
        err "destination exists: $2." >&2
        return 1
    }
    mv -n -- "$1" "$2" || return 1
    [ ! -e "$1" ] && [ ! -L "$1" ] || {
        err "move did not publish $2 (source remains)." >&2
        return 1
    }
}

install_checked() {
    local source="$1" destination="$2" parent
    parent=$(dirname "$destination") || return 1
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
    pending_dir=$(mktemp -d "$parent/.bw-export-pending-XXXXXXXXXX") || return 1
    cp -- "$source" "$pending_dir/export.gpg" || return 1
    hashes_match "$source" "$pending_dir/export.gpg" || {
        err "staged copy failed checksum verification." >&2
        return 1
    }
    move_no_replace "$pending_dir/export.gpg" "$destination" || return 1
    rmdir "$pending_dir" || return 1
    pending_dir=""
}

nas_available() { nas_mount_available "$nas_mount" && [[ -d $nas_dir ]]; }

rotate_into_archive() {
    local dir="$1" keep="${2:-}" f name collisions=0
    local listing
    listing=$(find "$dir" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*.zip.gpg" | sort) || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        name=$(basename "$f")
        [ "$name" != "$keep" ] || continue
        if [ -e "$dir/archive/$name" ] || [ -L "$dir/archive/$name" ]; then
            err "$dir/archive/$name already exists; refusing to overwrite it during rotation." >&2
            collisions=$((collisions + 1))
        fi
    done <<< "$listing"
    [ "$collisions" -eq 0 ] || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        name=$(basename "$f")
        [ "$name" != "$keep" ] || continue
        move_no_replace "$f" "$dir/archive/$name" || {
            err "rotation stopped at $f. Earlier files may already be in archive/." >&2
            return 1
        }
    done <<< "$listing"
    return 0
}

finish_bw_session() {
    [[ $bw_session_finished == 0 ]] || return 0
    local rc=0
    if [[ $script_unlocked == 1 ]]; then
        step 'Locking the vault unlocked by this run'
        if bw lock > /dev/null 2>&1; then
            script_unlocked=0
        else
            err 'Vault relock failed. Cleanup will retry. Check the vault manually if it fails again.'
            rc=1
        fi
    fi
    unset BW_SESSION
    if ((rc == 0)); then bw_session_finished=1; fi
    return "$rc"
}

remove_plaintext() {
    [ -n "$random_dir" ] && [ -d "$random_dir" ] || return 0
    if command -v shred > /dev/null 2>&1; then
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
    finish_bw_session || cleanup_failed=1
    if ! remove_plaintext; then
        err "plaintext staging could not be removed: $random_dir" >&2
        cleanup_failed=1
    fi
    if [ -n "$pending_dir" ]; then
        rm -rf -- "$pending_dir" || cleanup_failed=1
    fi
    if [ -n "$encrypted_stage" ]; then
        rm -rf -- "$encrypted_stage" || cleanup_failed=1
    fi
    if [ "$cleanup_failed" -eq 0 ] && [ "$lock_held" -eq 1 ]; then
        lock_release || cleanup_failed=1
    fi
    if [ "$cleanup_failed" -ne 0 ]; then
        err "cleanup incomplete. Inspect staging and the lock before retrying." >&2
        [ "$status" -ne 0 ] || status=1
    fi
    exit "$status"
}

acquire_lock() {
    lock_acquire "$lock_dir" || exit 1
    lock_held=1
}

require_cmds() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            err "'$cmd' is not installed. Please install it first." >&2
            exit 1
        fi
    done
}

require_sha256() {
    if ! command -v shasum > /dev/null 2>&1 && ! command -v sha256sum > /dev/null 2>&1; then
        err "neither 'shasum' nor 'sha256sum' is installed." >&2
        exit 1
    fi
}

resolve_gpg_enc_fpr() {
    local gpg_colons primary_count
    gpg_colons=$(gpg --batch --with-colons --list-keys "$gpg_key" 2> /dev/null) || {
        err "GPG key $gpg_key not found in keyring." >&2
        exit 1
    }
    primary_count=$(printf '%s\n' "$gpg_colons" | grep -c '^pub:' || true)
    if [ "$primary_count" -ne 1 ]; then
        err "GPG key spec '$gpg_key' matches $primary_count primary keys; expected exactly 1." >&2
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
        err "GPG key $gpg_key has no valid encryption-capable (sub)key." >&2
        exit 1
    fi
    log "Using GPG encryption key fingerprint $gpg_enc_fpr"
}

card_has_enc_key() {
    local card
    card=$(gpg --batch --with-colons --card-status 2> /dev/null) || return 1
    printf '%s\n' "$card" | awk -F: -v want="$gpg_enc_fpr" '
    $1 == "fpr" { for (i = 2; i <= NF; i++) if ($i == want) found = 1 }
    END { exit found ? 0 : 1 }'
}

find_in_dirs() {
    local name="$1" d
    shift
    for d in "$@"; do
        if [ -f "$d/$name" ]; then
            printf '%s' "$d/$name"
            return 0
        fi
    done
    return 1
}

list_unverified() {
    local d
    for d in "$@"; do
        [ -d "$d" ] || continue
        find "$d" -mindepth 1 -maxdepth 1 -type f -name "bw-auto-export-*-unverified.zip.gpg" || return 1
    done | sort
}

decrypt_test() {
    if [ "$interactive_session" -eq 0 ]; then
        err "decrypting $1 requires an interactive run. Re-run --verify in a terminal." >&2
        return 1
    fi
    gpg --decrypt "$1" > /dev/null
}

verify_pending() {
    local f name verified_name dir nas_copy nas_copy_dir local_verified
    local rc=0 count=0 nas_count=0
    local local_dirs=("$downloads_dir" "$downloads_dir/archive")
    local nas_dirs=("$nas_dir" "$nas_dir/archive")
    local nas_ok=0 local_pending nas_pending

    if nas_available; then
        nas_ok=1
        log "NAS mounted; NAS copies will be renamed too."
    else
        log "NAS not mounted; NAS copies (if any) keep their '-unverified' name until a later --verify with the NAS mounted."
    fi

    local_pending=$(list_unverified "${local_dirs[@]}")
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        count=$((count + 1))
        dir=$(dirname "$f")
        name=$(basename "$f")
        verified_name="${name%-unverified.zip.gpg}.zip.gpg"
        nas_copy=""
        log "Verifying $f..."

        if [ -e "$dir/$verified_name" ]; then
            err "$dir/$verified_name already exists; refusing to overwrite. $name left as-is." >&2
            rc=1
            continue
        fi
        if [ "$nas_ok" -eq 1 ] && nas_copy=$(find_in_dirs "$name" "${nas_dirs[@]}"); then
            nas_copy_dir=$(dirname "$nas_copy")
            if [ -e "$nas_copy_dir/$verified_name" ]; then
                err "$nas_copy_dir/$verified_name already exists; refusing to overwrite. $name left as-is." >&2
                rc=1
                continue
            fi
            if ! hashes_match "$f" "$nas_copy"; then
                err "NAS copy $nas_copy differs from the local copy (SHA-256 mismatch or hash failure); nothing renamed." >&2
                rc=1
                continue
            fi
        fi
        if ! decrypt_test "$f"; then
            err "$name failed to decrypt - left as-is for inspection." >&2
            rc=1
            continue
        fi

        move_no_replace "$f" "$dir/$verified_name" || {
            rc=1
            continue
        }
        log "  local: renamed to $dir/$verified_name"
        if [ -n "$nas_copy" ]; then
            if move_no_replace "$nas_copy" "$nas_copy_dir/$verified_name"; then
                log "  nas:   renamed to $nas_copy_dir/$verified_name"
            else
                err "local copy renamed but NAS rename failed; NAS copy remains $nas_copy." >&2
                rc=1
            fi
        fi
    done <<< "$local_pending"
    [ "$count" -gt 0 ] || log "No '-unverified' exports found locally (current or archive/)."

    if [ "$nas_ok" -eq 1 ]; then
        nas_pending=$(list_unverified "${nas_dirs[@]}")
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            nas_count=$((nas_count + 1))
            dir=$(dirname "$f")
            name=$(basename "$f")
            verified_name="${name%-unverified.zip.gpg}.zip.gpg"
            log "Reconciling NAS copy $f..."
            if [ -e "$dir/$verified_name" ]; then
                err "$dir/$verified_name already exists; refusing to overwrite. $name left as-is." >&2
                rc=1
                continue
            fi
            if local_verified=$(find_in_dirs "$verified_name" "${local_dirs[@]}"); then
                if ! hashes_match "$local_verified" "$f"; then
                    err "NAS copy $name differs from verified local copy $local_verified (SHA-256 mismatch or hash failure); left as-is." >&2
                    rc=1
                    continue
                fi
                log "  matches verified local copy $local_verified"
            elif decrypt_test "$f"; then
                log "  no local copy; decrypt test on NAS copy passed"
            else
                err "no local copy and NAS copy $name failed to decrypt - left as-is." >&2
                rc=1
                continue
            fi
            move_no_replace "$f" "$dir/$verified_name" || {
                rc=1
                continue
            }
            log "  nas:   renamed to $dir/$verified_name"
        done <<< "$nas_pending"
        [ "$nas_count" -gt 0 ] || log "No '-unverified' exports left on NAS (current or archive/)."
    fi

    return "$rc"
}

validate_export() {
    jq -e 'type == "object" and .encrypted == false and
    (.items | type == "array") and
    all(.items[]; (.id | type == "string") and (.id | test("^[A-Za-z0-9-]+$"))) and
    (([.items[].id] | length) == ([.items[].id] | unique | length))' "$1" > /dev/null
}

# Operations
main() {
    umask 077
    interactive_session=0
    if [[ -t 0 ]]; then interactive_session=1; fi

    downloads_dir="$HOME/Documents/encrypted/bw-export"
    nas_mount="/Volumes/home"
    nas_dir="$nas_mount/documents/encrypted/bw-export"
    gpg_key="0xA11E70ADFDA60CF9"
    lock_dir="$downloads_dir/.bw-export.lock"
    zip_file="bw-auto-export-$(date +%Y%m%d-%H%M%S%z).zip"

    case ${1:-} in
        --version)
            printf '%s\n' "$SCRIPT_VERSION"
            exit 0
            ;;
        --help | -h)
            usage
            exit 0
            ;;
    esac
    load_config "$HOME/.config/bitwarden-backup/config" 'downloads_dir nas_mount nas_dir gpg_key' || die 'Invalid Bitwarden backup configuration.'
    reject_symlinks "$downloads_dir" || exit 1
    validate_child_dir "$nas_mount" "$nas_dir" || exit 1
    lock_dir="$downloads_dir/.bw-export.lock"

    pending_dir=""

    script_unlocked=0
    bw_session_finished=0

    random_dir=""
    encrypted_stage=""
    lock_held=0
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [ "$#" -gt 1 ]; then
        log "Usage: $0 [--verify]" >&2
        exit 2
    fi
    case "${1:-}" in
        --verify)
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
            log "Usage: $0 [--verify]" >&2
            exit 2
            ;;
    esac

    mkdir -p "$downloads_dir/archive"

    bw_status=$(bw status | jq -r '.status')

    case "$bw_status" in
        unauthenticated)
            log "Please log in to Bitwarden first (bw login)." >&2
            exit 1
            ;;
        locked)
            if [ "$interactive_session" -eq 0 ]; then
                err "vault locked. Unattended exports require a usable BW_SESSION." >&2
                exit 1
            fi
            log "Vault is locked - unlocking..."
            BW_SESSION=$(bw unlock --raw)
            export BW_SESSION
            script_unlocked=1 # we changed the vault state, so we are responsible for re-locking
            ;;
        unlocked)
            log "Vault already unlocked (will be left unlocked)."
            ;;
        *)
            err "unexpected Bitwarden status '$bw_status'." >&2
            exit 1
            ;;
    esac

    tmp_root="${TMPDIR:-/tmp}"
    [[ "$tmp_root" != "/" ]] && tmp_root="${tmp_root%/}" # macOS sets TMPDIR with a trailing slash
    random_dir=$(mktemp -d "$tmp_root/bw_export_XXXXXXXXXX")

    bw sync
    bw export --format json --output "$random_dir/bitwarden_export.json"
    validate_export "$random_dir/bitwarden_export.json" || {
        err "invalid personal JSON export." >&2
        exit 1
    }
    bw list organizations > "$random_dir/organisations.json"
    jq -e 'type == "array" and all(.[];
  (.id | type == "string") and (.id | test("^[A-Za-z0-9-]+$")))' "$random_dir/organisations.json" > /dev/null
    org_ids=$(jq -r '.[].id' "$random_dir/organisations.json")
    export_files=("$random_dir/bitwarden_export.json")
    mkdir "$random_dir/organisations"
    while IFS= read -r org_id; do
        [ -n "$org_id" ] || continue
        org_export="$random_dir/organisations/$org_id.json"
        log "Exporting organisation $org_id..."
        if ! bw export --organizationid "$org_id" --format json --output "$org_export"; then
            err "organisation $org_id could not be exported. Check export permissions. No new backup installed." >&2
            exit 1
        fi
        validate_export "$org_export" || {
            err "invalid organisation JSON: $org_id." >&2
            exit 1
        }
        export_files+=("$org_export")
    done <<< "$org_ids"

    jq -s '[.[].items[]] | unique_by(.id)' "${export_files[@]}" > "$random_dir/exported-items.json"
    bw list items > "$random_dir/visible-items.json"
    jq -e 'type == "array" and all(.[]; (.id | type == "string"))' "$random_dir/visible-items.json" > /dev/null
    jq -e --slurpfile exported "$random_dir/exported-items.json" '([.[].id] - [$exported[0][].id]) | length == 0' "$random_dir/visible-items.json" > /dev/null || {
        err "some visible vault items are missing from the exports." >&2
        exit 1
    }

    mkdir "$random_dir/item-index"
    visible_ndjson=$(jq -c '.[]' "$random_dir/visible-items.json")
    while IFS= read -r item; do
        [[ -n $item ]] || continue
        indexed_id=$(jq -er '.id | select(test("^[A-Za-z0-9-]+$"))' <<< "$item")
        printf '%s\n' "$item" > "$random_dir/item-index/$indexed_id.json"
    done <<< "$visible_ndjson"
    unset visible_ndjson item
    item_ids=$(jq -r '.[].id' "$random_dir/exported-items.json")
    : > "$random_dir/attachments.ndjson"
    attachment_count=0
    expected_attachments=0
    while IFS= read -r item_id; do
        [ -n "$item_id" ] || continue
        item=""
        if [[ -f "$random_dir/item-index/$item_id.json" ]]; then item=$(cat "$random_dir/item-index/$item_id.json"); fi
        if [ -z "$item" ]; then
            item=$(bw get item "$item_id") || {
                err "cannot inspect exported item $item_id for attachments." >&2
                exit 1
            }
        fi
        printf '%s\n' "$item" | jq -e --arg id "$item_id" '
    .id == $id and ((.attachments // []) | type == "array") and
    all((.attachments // [])[];
      (.id | type == "string") and (.id | test("^[A-Za-z0-9-]+$")) and
      (.fileName | type == "string"))' > /dev/null
        attachments=$(printf '%s\n' "$item" | jq -c '(.attachments // [])[]')
        while IFS= read -r att; do
            [ -n "$att" ] || continue
            expected_attachments=$((expected_attachments + 1))
            attachment_id=$(printf '%s\n' "$att" | jq -r '.id')
            attachment_name=$(printf '%s\n' "$att" | jq -r '.fileName')
            relative_path="attachments/$item_id/${attachment_id}_$(sanitise_name "$attachment_name")"
            mkdir -p "$random_dir/attachments/$item_id"
            attachment_path="$random_dir/$relative_path"
            [ ! -e "$attachment_path" ] || {
                err "duplicate attachment ID." >&2
                exit 1
            }
            bw get attachment "$attachment_id" --itemid "$item_id" --output "$attachment_path" > /dev/null || {
                err "attachment download failed for $item_id/$attachment_id." >&2
                exit 1
            }
            [ -f "$attachment_path" ] || {
                err "attachment file missing." >&2
                exit 1
            }
            actual_size=$(wc -c < "$attachment_path" | tr -d '[:space:]')
            expected_size=$(printf '%s\n' "$att" | jq -r '.size // empty')
            attachment_sha=$(sha256_of "$attachment_path")
            printf '%s\n' "$att" | jq -c --arg item "$item_id" --arg path "$relative_path" --arg sha "$attachment_sha" --arg metadata_size "$expected_size" --argjson bytes "$actual_size" '{item_id:$item, attachment_id:.id, original_filename:.fileName,
        path:$path, size_bytes:$bytes, service_reported_size:$metadata_size, sha256:$sha}' >> "$random_dir/attachments.ndjson"
            attachment_count=$((attachment_count + 1))
        done <<< "$attachments"
    done <<< "$item_ids"
    [ "$attachment_count" -eq "$expected_attachments" ] || exit 1

    jq -s '.' "$random_dir/attachments.ndjson" > "$random_dir/attachments.json"
    jq -n --slurpfile organisations "$random_dir/organisations.json" --slurpfile items "$random_dir/exported-items.json" --slurpfile attachments "$random_dir/attachments.json" --arg script_version "$SCRIPT_VERSION" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{schema_version:1, script_version:$script_version, created_utc:$created,
    coverage:"Personal vault plus every listed organisation. Attachments for all exported items.",
    exclusions:["Trash", "Sends", "Server/account configuration"],
    verification:"JSON structure, visible item coverage, attachment downloads and ZIP integrity checked. Attachment plaintext sizes/hashes recorded. Not restore-tested.",
    personal_export:"bitwarden_export.json",
    organisations:[$organisations[0][] | {id, name, export_path:("organisations/" + .id + ".json")}],
    item_count:($items[0] | length), attachment_count:($attachments[0] | length),
    attachments:$attachments[0]}' > "$random_dir/manifest.json"
    cat > "$random_dir/RECOVERY.txt" << RECOVERY
Bitwarden backup recovery - security-bitwarden-backup.sh $SCRIPT_VERSION

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
    rm -rf -- "$random_dir/item-index"
    for intermediate in exported-items.json visible-items.json organisations.json attachments.ndjson attachments.json; do
        secure_rm_file "$random_dir/$intermediate"
    done

    finish_bw_session

    (cd "$random_dir" && zip -qr "$zip_file" .)

    log "Testing ZIP integrity..."
    if ! unzip -tq "$random_dir/$zip_file" > /dev/null; then
        err "ZIP integrity test failed for $zip_file. Aborting." >&2
        exit 1
    fi

    encrypted_stage=$(mktemp -d "$downloads_dir/.bw-export-encrypted-XXXXXXXXXX")
    gpg --batch --trust-model always \
        --recipient "${gpg_enc_fpr}!" \
        --output "$encrypted_stage/$zip_file.gpg" \
        --encrypt "$random_dir/$zip_file"
    log "Encrypted export prepared."

    remove_plaintext || {
        err "plaintext cleanup failed." >&2
        exit 1
    }

    final_name="$zip_file.gpg"
    skip_reason=""
    if [ "$interactive_session" -eq 0 ]; then
        skip_reason="non-interactive session"
    elif ! card_has_enc_key; then
        skip_reason="no YubiKey holding encryption key $gpg_enc_fpr is present"
    fi
    if [ -n "$skip_reason" ]; then
        final_name="${zip_file%.zip}-unverified.zip.gpg"
        warn "$skip_reason - decrypt verification skipped." >&2
        log "Export will be installed as $final_name (decryption NOT verified)." >&2
        log "Run '$0 --verify' with the YubiKey present to decrypt-test it and" >&2
        log "rename the local and NAS copies to '$zip_file.gpg'." >&2
    else
        if decrypt_test "$encrypted_stage/$zip_file.gpg"; then
            ok "Decryption test passed."
        else
            failed_copy="$downloads_dir/DECRYPT-FAILED-$zip_file.gpg"
            move_no_replace "$encrypted_stage/$zip_file.gpg" "$failed_copy"
            err "YubiKey present but the export could not be decrypted (wrong card, PIN, or corrupt output)." >&2
            log "Encrypted file kept at $failed_copy for inspection; previous export left in place, NAS copy skipped." >&2
            exit 1
        fi
    fi

    if ! install_checked "$encrypted_stage/$zip_file.gpg" "$downloads_dir/$final_name"; then
        err "local installation failed. Previous backups retained." >&2
        exit 1
    fi
    ok "Encrypted export saved to $downloads_dir/$final_name"
    if ! rotate_into_archive "$downloads_dir" "$final_name"; then
        err "local rotation incomplete. New backup retained. Older files may be in current or archive/." >&2
        exit 1
    fi

    if nas_available; then
        mkdir -p "$nas_dir/archive"
        log "Copying encrypted export to NAS..."
        if ! install_checked "$downloads_dir/$final_name" "$nas_dir/$final_name"; then
            err "NAS installation failed. Local backup retained. Existing NAS backups were not rotated." >&2
            exit 1
        fi
        ok "NAS copy verified by SHA-256 and published."
        if ! rotate_into_archive "$nas_dir" "$final_name"; then
            err "NAS rotation incomplete. New backup retained. Older files may be in current or archive/." >&2
            exit 1
        fi
    else
        log "NAS unavailable at $nas_mount (or $nas_dir missing). Local backup only."
    fi

    log "Bitwarden export completed. Decryption verification is not a restore test."

}

# Entry point
main "$@"
