#!/usr/bin/env bash
#
# Script: cert-deploy-npm.sh
# Purpose: Deploy verified RSA 4096 PEM files over SSH and restart rootless Podman NPM.
# Version: 1.0.0
# Requires: Bash 5+, OpenSSL 3+, ssh, scp and adjacent lib/common.sh.
# Documentation: docs/cert-deploy-npm-user-manual.md or run with --help.
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
export LC_ALL=C
readonly SCRIPT_VERSION='1.0.0'
readonly VERSION="$SCRIPT_VERSION"
readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
[[ -r $SCRIPT_DIR/lib/common.sh ]] || { printf 'ERROR Missing lib/common.sh\n' >&2; exit 1; }
source "$SCRIPT_DIR/lib/common.sh"
for helper in load_config log ok die require_cmds reject_symlinks lock_acquire lock_release; do
    declare -F "$helper" > /dev/null || { printf 'ERROR Missing helper: %s\n' "$helper" >&2; exit 1; }
done
unset helper
readonly CONFIG_KEYS='DOMAIN SOURCE_DIR NPM_HOST NPM_CONTAINER DEST_DIR SSH_PORT STOP_TIMEOUT'
DOMAIN='phillipmcmahon.com'
SOURCE_DIR="$HOME/certificates/phillipmcmahon.com/letsencrypt/rsa-4096"
NPM_HOST='phillipmcmahon@dmz-podman.phillipmcmahon.com'
NPM_CONTAINER='proxy.phillipmcmahon.com'
DEST_DIR='/home/phillipmcmahon/podman/npm/data/custom_ssl/npm-21'
SSH_PORT=22
STOP_TIMEOUT=60
CONFIG_FILE="$SCRIPT_DIR/config/cert-deploy-npm.conf"
CONFIG_EXPLICIT=0
DRY_RUN=1
MODE_OPTION=''
STAGING=''
REMOTE_STAGE=''
SSH_OPTIONS=()
SCP_OPTIONS=()

# Command interface
usage() {
    cat << EOF
$SCRIPT_NAME $SCRIPT_VERSION
Usage: $SCRIPT_NAME [OPTIONS]

Upload fullchain.pem and private.key, install as fullchain.pem and privkey.pem,
and restart the configured NPM container. Default mode is dry-run (no SSH).
Unchanged remote files are left in place and NPM is not restarted.

Options:
  --config PATH        Literal config (default: config/cert-deploy-npm.conf)
  --source-dir PATH    Local cert-manage export directory
  --apply              Upload, install and restart when files differ
  -n, --dry-run        Validate local files and show plan only (default)
  --log-file PATH      Append script messages
  --version            Show version
  -h, --help           Show help

Defaults:
  Host:      $NPM_HOST
  Container: $NPM_CONTAINER
  Target:    $DEST_DIR

SSH uses existing keys/agent/config, strict host-key checking and batch mode.
No sudo, certificate issuance, UniFi changes or scheduling is performed.
EOF
}

# Helpers
absolute_path() {
    local path=$1 base=$2
    case $path in
        '~') path=$HOME ;;
        '~/'*) path="$HOME/${path:2}" ;;
        /*) ;;
        *) path="$base/$path" ;;
    esac
    printf '%s\n' "$path"
}

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n $REMOTE_STAGE ]]; then
        ssh "${SSH_OPTIONS[@]}" "$NPM_HOST" "rm -rf -- '$REMOTE_STAGE'" < /dev/null || {
            warn "Remote staging cleanup failed. Remove after inspection: $REMOTE_STAGE"
            ((rc != 0)) || rc=1
        }
    fi
    if [[ -n $STAGING ]]; then rm -rf -- "$STAGING" || rc=1; fi
    lock_release || rc=1
    exit "$rc"
}

read_configuration() {
    local key declaration
    while (($#)); do
        case $1 in
            -h | --help | --version) return ;;
            --config | --source-dir | --log-file)
                (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "Missing value for $1"
                if [[ $1 == --config ]]; then CONFIG_FILE=$2; CONFIG_EXPLICIT=1; fi
                shift ;;
        esac
        shift
    done
    CONFIG_FILE=$(absolute_path "$CONFIG_FILE" "$PWD")
    if [[ ! -e $CONFIG_FILE && ! -L $CONFIG_FILE ]]; then
        ((CONFIG_EXPLICIT == 0)) || die "Config not found: $CONFIG_FILE"
        return 0
    fi
    load_config "$CONFIG_FILE" "$CONFIG_KEYS" || die "Cannot load config: $CONFIG_FILE"
    for key in $CONFIG_KEYS; do
        declaration=$(declare -p "$key")
        [[ $declaration != 'declare -a '* && $declaration != 'declare -A '* && -n ${!key} ]] || die "$key must be a non-empty scalar."
    done
}

validate_pair() {
    local directory=$1 cert_hash key_hash key_text
    [[ -s $directory/fullchain.pem && -s $directory/private.key ]] || die "Missing certificate or key in $directory"
    openssl pkey -in "$directory/private.key" -passin pass: -check -noout > /dev/null
    key_text=$(openssl rsa -in "$directory/private.key" -passin pass: -pubout 2>/dev/null | openssl pkey -pubin -text -noout)
    [[ $key_text == *'Public-Key: (4096 bit)'* ]] || die 'Expected RSA 4096.'
    openssl x509 -in "$directory/fullchain.pem" -checkend 0 -noout > /dev/null || die 'Certificate has expired.'
    cert_hash=$(openssl x509 -in "$directory/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
    key_hash=$(openssl pkey -in "$directory/private.key" -passin pass: -pubout -outform DER | openssl dgst -sha256)
    [[ $cert_hash == "$key_hash" ]] || die 'Certificate and private key do not match.'
    # The first PEM certificate is the leaf, remaining certificates supply intermediates.
    openssl verify -purpose sslserver -verify_hostname "$DOMAIN" -untrusted "$directory/fullchain.pem" "$directory/fullchain.pem" > /dev/null || die 'Certificate chain does not verify against the OpenSSL trust store.'
}

file_hash() { openssl dgst -sha256 -r "$1" | cut -d ' ' -f 1; }

# Operations
main() {
    local cert_hash key_hash helper="$SCRIPT_DIR/lib/cert-deploy-npm-remote.sh"
    read_configuration "$@"
    while (($#)); do
        case $1 in
            --config | --source-dir | --log-file)
                (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "Missing value for $1"
                case $1 in --source-dir) SOURCE_DIR=$2 ;; --log-file) LOG_FILE=$2 ;; esac
                shift ;;
            --apply) [[ $MODE_OPTION != dry ]] || die 'Conflicting modes.'; MODE_OPTION=apply; DRY_RUN=0 ;;
            -n | --dry-run) [[ $MODE_OPTION != apply ]] || die 'Conflicting modes.'; MODE_OPTION=dry; DRY_RUN=1 ;;
            --version) printf '%s\n' "$SCRIPT_VERSION"; return ;;
            -h | --help) usage; return ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    require_cmds openssl ssh scp mkdir mktemp cp rm cut
    [[ $(openssl version) == 'OpenSSL 3.'* ]] || die 'OpenSSL 3.x is required.'
    # Remote command arguments are restricted to literal shell-safe characters.
    [[ $NPM_HOST =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'NPM_HOST must be user@hostname.'
    [[ $NPM_CONTAINER =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die 'Invalid NPM_CONTAINER.'
    [[ $DOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ && $DOMAIN == *.* ]] || die 'Invalid DOMAIN.'
    [[ $DEST_DIR =~ ^/[a-zA-Z0-9_./-]+$ && $DEST_DIR != / && $DEST_DIR != */ && $DEST_DIR != *'//'* && /$DEST_DIR/ != */../* && /$DEST_DIR/ != */./* ]] || die 'DEST_DIR must be an absolute path without spaces or dot components.'
    [[ $SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && ((SSH_PORT <= 65535)) || die 'Invalid SSH_PORT.'
    [[ $STOP_TIMEOUT =~ ^[1-9][0-9]{0,3}$ ]] || die 'Invalid STOP_TIMEOUT.'
    SOURCE_DIR=$(absolute_path "$SOURCE_DIR" "$SCRIPT_DIR")
    reject_symlinks "$SOURCE_DIR/fullchain.pem" && reject_symlinks "$SOURCE_DIR/private.key" || die 'Unsafe source path.'
    [[ -r $helper ]] || die "Missing remote helper: $helper"
    if [[ -n ${LOG_FILE:-} ]]; then
        LOG_FILE=$(absolute_path "$LOG_FILE" "$PWD")
        reject_symlinks "$LOG_FILE" || die 'Unsafe log path.'
        touch "$LOG_FILE" || die 'Cannot write log.'
    fi
    validate_pair "$SOURCE_DIR"
    log "Source: $SOURCE_DIR"
    log "Target: $NPM_HOST:$DEST_DIR"
    log "Container: $NPM_CONTAINER (shutdown timeout: ${STOP_TIMEOUT}s)"
    if ((DRY_RUN)); then
        log 'Would upload, back up and replace changed files, then restart NPM. No SSH connection made.'
        return
    fi
    SSH_OPTIONS=(-p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
    SCP_OPTIONS=(-P "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    lock_acquire "$SOURCE_DIR/.cert-deploy-npm.lock" || exit 1
    STAGING=$(mktemp -d "$SOURCE_DIR/.npm-upload.XXXXXXXX")
    cp "$SOURCE_DIR/fullchain.pem" "$SOURCE_DIR/private.key" "$STAGING/"
    validate_pair "$STAGING"
    cert_hash=$(file_hash "$STAGING/fullchain.pem")
    key_hash=$(file_hash "$STAGING/private.key")
    # The prepare helper checks the target path and container before creating staging.
    REMOTE_STAGE=$(ssh "${SSH_OPTIONS[@]}" "$NPM_HOST" "bash -s -- prepare '$DEST_DIR' '$NPM_CONTAINER'" < "$helper")
    [[ $REMOTE_STAGE == "$DEST_DIR/.cert-deploy."* && ${REMOTE_STAGE##*/} =~ ^\.cert-deploy\.[a-zA-Z0-9]+$ ]] || {
        REMOTE_STAGE=''
        die 'Unexpected remote staging response.'
    }
    scp -p "${SCP_OPTIONS[@]}" "$STAGING/fullchain.pem" "$NPM_HOST:$REMOTE_STAGE/fullchain.pem"
    scp -p "${SCP_OPTIONS[@]}" "$STAGING/private.key" "$NPM_HOST:$REMOTE_STAGE/privkey.pem"
    ssh "${SSH_OPTIONS[@]}" "$NPM_HOST" "bash -s -- deploy '$DEST_DIR' '$NPM_CONTAINER' '$REMOTE_STAGE' '$STOP_TIMEOUT' '$cert_hash' '$key_hash'" < "$helper"
    ok 'Remote deployment completed. An unchanged pair does not trigger a restart.'
}

# Entry point
main "$@"
