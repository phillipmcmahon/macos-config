#!/usr/bin/env bash
#
# Script: dns-cloudns-backup.sh
# Purpose: Back up, restore and replicate a ClouDNS zone.
# Version: 1.0.0
# Requires: Bash 5+, curl, jq, shasum and adjacent lib/.
# Documentation: docs/USER-MANUAL.md
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION='1.0.0'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/cloudns.sh"
BACKUP_DIR="$HOME/.config/cloudns/backups"
RETENTION_COUNT=30
NAS_SSH_HOST=${NAS_SSH_HOST:-homestorage}
NAS_SSH_DIR=${NAS_SSH_DIR:-backups/dns/cloudns/phillipmcmahon.com}
NAS_RSYNC_PATH=${NAS_RSYNC_PATH:-/opt/bin/rsync}
NAS_ROOT=${NAS_ROOT:-/Volumes/home}
NAS_BACKUP_DIR=${NAS_BACKUP_DIR:-$NAS_ROOT/backups/dns/cloudns/phillipmcmahon.com}
OUTPUT_FILE='' RESTORE_FILE='' STAGING=''
DRY_RUN=0 REPLACE_EXISTING=0 NAS_ENABLED=1 ASSUME_YES=0

# Command interface
usage() {
    cat << EOF
${0##*/} $SCRIPT_VERSION
Usage: ${0##*/} [BACKUP OPTIONS]
       ${0##*/} --restore FILE [--replace-existing] [--dry-run] [--yes]

Default: timestamped BIND backup, SHA-256 sidecar, retention and NAS mirror.
Restore is additive unless --replace-existing is selected. Both require confirmation.

Options:
  --backup-dir DIR     Dedicated local backup directory
  --output FILE        Custom output, without retention or replication
  --retention-count N  Keep N timestamped backups (0 disables pruning)
  --no-nas             Local backup only
  --restore FILE       Import a BIND backup (must belong to the configured zone)
  --replace-existing   Delete existing records before import
  --dry-run            Validate and display restore file without an API request
  --yes                Skip restore confirmation
  --version            Show version
  -h, --help           Show help

Settings: ~/.config/cloudns/config. Credentials: ~/.config/cloudns/credentials.
NAS_SSH_HOST, NAS_SSH_DIR, NAS_RSYNC_PATH, NAS_ROOT and NAS_BACKUP_DIR accept env overrides.
NAS replication failure returns non-zero while preserving the successful local backup.
EOF
}

# Helpers
cleanup() {
    local rc=$?
    trap - EXIT
    [[ -z $STAGING ]] || rm -rf -- "$STAGING" || rc=1
    lock_release || rc=1
    exit "$rc"
}

validate_zone_file() {
    local file=$1 origin
    [[ -s $file && -f $file && ! -L $file ]] || {
        err 'Expected a non-empty regular zone file.'
        return 1
    }
    origin=$(awk '$1 == "$ORIGIN" {print $2}' "$file") || return 1
    [[ ${origin,,} == "${DOMAIN,,}." || ${origin,,} == "${DOMAIN,,}" ]] || {
        err 'Backup origin does not match the configured zone, or contains multiple origins.'
        return 1
    }
    grep -Eq '[[:space:]]IN[[:space:]]' "$file" || {
        err 'No DNS records found.'
        return 1
    }
}

checksum_verify() {
    local file=$1 expected actual
    if [[ ! -f $file.sha256 ]]; then
        warn 'No checksum sidecar. Restore integrity is not verified.'
        return 0
    fi
    # Verify this file, never a different filename named inside the sidecar.
    read -r expected _ < "$file.sha256" || return 1
    [[ $expected =~ ^[[:xdigit:]]{64}$ ]] || return 1
    actual=$(sha256_of "$file") || return 1
    [[ ${expected,,} == "$actual" ]] || {
        err 'Backup checksum mismatch.'
        return 1
    }
    ok 'Backup checksum verified.'
}

retention() {
    local file name remove i
    local -a backups=()
    ((RETENTION_COUNT > 0)) || return 0
    shopt -s nullglob
    for file in "$BACKUP_DIR/$DOMAIN-"*.bind; do
        name=${file##*/}
        [[ ${name#"$DOMAIN-"} =~ ^[0-9]{8}-[0-9]{6}\.bind$ && -f $file && ! -L $file ]] || continue
        backups+=("$file")
    done
    remove=$((${#backups[@]} - RETENTION_COUNT))
    for ((i = 0; i < remove; i++)); do
        file=${backups[i]}
        rm -f -- "$file" "$file.sha256"
        log "Pruned: ${file##*/}"
    done
}

replicate() {
    require_cmds rsync ssh
    validate_remote_dir "$NAS_SSH_DIR" || return 1
    [[ $NAS_SSH_HOST =~ ^[A-Za-z0-9][A-Za-z0-9@._-]*$ ]] || die 'Invalid NAS SSH host.'
    [[ $NAS_RSYNC_PATH =~ ^/[A-Za-z0-9_./-]+$ ]] || die 'Invalid remote rsync path.'
    local -a options=(--archive --checksum --delete --protect-args
        --include="$DOMAIN-????????-??????.bind" --include="$DOMAIN-????????-??????.bind.sha256" --exclude='*')
    if ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$NAS_SSH_HOST" true 2> /dev/null; then
        if rsync "${options[@]}" -e 'ssh -o BatchMode=yes -o ConnectTimeout=5' \
            --rsync-path="mkdir -p $NAS_SSH_DIR && $NAS_RSYNC_PATH" "$BACKUP_DIR/" "$NAS_SSH_HOST:$NAS_SSH_DIR/"; then
            ok 'NAS mirror updated over SSH.'
            return 0
        fi
        warn 'SSH replication failed. Trying the mounted SMB share.'
    fi
    if nas_mount_available "$NAS_ROOT"; then
        validate_child_dir "$NAS_ROOT" "$NAS_BACKUP_DIR" || return 1
        mkdir -p "$NAS_BACKUP_DIR"
        rsync "${options[@]}" --no-perms "$BACKUP_DIR/" "$NAS_BACKUP_DIR/" || return 1
        ok 'NAS mirror updated over SMB.'
    else
        err 'NAS unavailable. Local backup remains valid.'
        return 1
    fi
}

backup_zone() {
    local file parent response zone digest
    file=${OUTPUT_FILE:-$BACKUP_DIR/$DOMAIN-$(date '+%Y%m%d-%H%M%S').bind}
    [[ $file == /* ]] || file=$PWD/$file
    parent=${file%/*}
    reject_symlinks "$parent" || exit 1
    [[ ! -e $file && ! -L $file && ! -e $file.sha256 && ! -L $file.sha256 ]] || die 'Output or checksum already exists.'
    mkdir -p "$parent"
    STAGING=$(mktemp -d "$parent/.cloudns-backup.XXXXXXXX")
    response=$(api_request /dns/records-export.json domain-name "$DOMAIN")
    api_success "$response" || exit 1
    zone=$(jq -er '.zone | select(type == "string" and length > 0)' <<< "$response")
    printf '; %s %s\n; UTC: %s\n%s\n' "${0##*/}" "$SCRIPT_VERSION" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$zone" > "$STAGING/zone.bind"
    validate_zone_file "$STAGING/zone.bind" || exit 1
    digest=$(sha256_of "$STAGING/zone.bind")
    printf '%s  %s\n' "$digest" "${file##*/}" > "$STAGING/checksum"
    move_no_replace "$STAGING/zone.bind" "$file" || die 'Could not publish the backup.'
    move_no_replace "$STAGING/checksum" "$file.sha256" || die 'Backup published, but checksum publication failed. No retention performed.'
    rmdir "$STAGING"
    STAGING=''
    ok "Local backup: $file"
    if [[ -z $OUTPUT_FILE ]]; then
        retention
        if ((NAS_ENABLED)); then replicate; fi
    fi
}

restore_zone() {
    local response content
    validate_zone_file "$RESTORE_FILE" || exit 1
    checksum_verify "$RESTORE_FILE" || exit 1
    if ((DRY_RUN)); then
        log "Validated restore preview. Replace existing: $REPLACE_EXISTING. No remote changes computed."
        cat "$RESTORE_FILE"
        return 0
    fi
    confirm "Import $RESTORE_FILE into $DOMAIN (replace existing: $REPLACE_EXISTING)?" || return 0
    cloudns_credentials
    content=$(cat "$RESTORE_FILE")
    local -a args=(domain-name "$DOMAIN" format bind content "$content")
    if ((REPLACE_EXISTING)); then args+=(delete-existing-records 1); fi
    response=$(api_request /dns/records-import.json "${args[@]}")
    api_success "$response" || die 'Import did not confirm success. Inspect DNS before retrying.'
    ok 'ClouDNS confirmed the import request.'
}

# Operations
main() {
    local backup_option=0
    while (($#)); do
        case $1 in
            --backup-dir | --output | --retention-count | --restore)
                (($# >= 2)) || die "$1 requires a value."
                case $1 in
                    --backup-dir)
                        BACKUP_DIR=$2
                        backup_option=1
                        ;;
                    --output)
                        OUTPUT_FILE=$2
                        backup_option=1
                        ;;
                    --retention-count)
                        RETENTION_COUNT=$2
                        backup_option=1
                        ;;
                    --restore) RESTORE_FILE=$2 ;;
                esac
                shift
                ;;
            --no-nas)
                NAS_ENABLED=0
                backup_option=1
                ;;
            --replace-existing) REPLACE_EXISTING=1 ;;
            --dry-run) DRY_RUN=1 ;; --yes | -y) ASSUME_YES=1 ;;
            --version)
                printf '%s\n' "$SCRIPT_VERSION"
                return
                ;;
            --help | -h)
                usage
                return
                ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    require_cmds jq shasum
    cloudns_configuration
    [[ $RETENTION_COUNT =~ ^(0|[1-9][0-9]{0,5})$ ]] || die 'Retention must be a decimal integer from 0 to 999999.'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -n $RESTORE_FILE ]]; then
        ((backup_option == 0)) || die 'Backup options cannot accompany --restore.'
        if ((!DRY_RUN)); then
            require_cmds curl
            lock_acquire "$HOME/.local/state/cloudns/$DOMAIN.lock" || exit 1
        fi
        restore_zone
    else
        ((DRY_RUN == 0 && REPLACE_EXISTING == 0)) || die '--dry-run and --replace-existing require --restore.'
        require_cmds curl
        cloudns_credentials
        [[ $BACKUP_DIR == /* ]] || BACKUP_DIR=$PWD/$BACKUP_DIR
        reject_symlinks "$BACKUP_DIR" || exit 1
        lock_acquire "$HOME/.local/state/cloudns/$DOMAIN.lock" || exit 1
        backup_zone
    fi
}

# Entry point
main "$@"
