#!/usr/bin/env bash
#
# Script: cert-deploy-npm.sh
# Purpose: Deploy verified RSA 4096 PEM files to DMZ and services NPM over SSH.
# Version: 1.1.0
# Requires: Bash 5+, OpenSSL 3+, ssh, scp and adjacent lib/common.sh.
# Documentation: docs/cert-deploy-npm-user-manual.md or run with --help.
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
export LC_ALL=C
readonly SCRIPT_VERSION='1.1.0'
readonly VERSION="$SCRIPT_VERSION"
readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
[[ -r $SCRIPT_DIR/lib/common.sh ]] || { printf 'ERROR Missing lib/common.sh\n' >&2; exit 1; }
source "$SCRIPT_DIR/lib/common.sh"
for helper in load_config log ok warn die require_cmds reject_symlinks lock_acquire lock_release; do
    declare -F "$helper" > /dev/null || { printf 'ERROR Missing helper: %s\n' "$helper" >&2; exit 1; }
done
unset helper
readonly CONFIG_KEYS='DOMAIN SOURCE_DIR NPM_HOST NPM_CONTAINER DEST_DIR SERVICES_NPM_HOST SERVICES_NPM_CONTAINER SERVICES_DEST_DIR SSH_PORT STOP_TIMEOUT'
DOMAIN='phillipmcmahon.com'
SOURCE_DIR="$HOME/certificates/phillipmcmahon.com/letsencrypt/rsa-4096"
# Existing NPM_* and DEST_DIR config keys continue to configure the DMZ target.
NPM_HOST='phillipmcmahon@podman.dmz.phillipmcmahon.com'
NPM_CONTAINER='proxy.dmz.phillipmcmahon.com'
DEST_DIR='/home/phillipmcmahon/podman/npm/data/custom_ssl/npm-21'
SERVICES_NPM_HOST='phillipmcmahon@podman.services.phillipmcmahon.com'
SERVICES_NPM_CONTAINER='proxy.services.phillipmcmahon.com'
SERVICES_DEST_DIR='/home/phillipmcmahon/podman/npm/data/custom_ssl/npm-1'
SSH_PORT=22
STOP_TIMEOUT=60
CONFIG_FILE="$SCRIPT_DIR/config/cert-deploy-npm.conf"
CONFIG_EXPLICIT=0
DRY_RUN=1
MODE_OPTION=''
STAGING=''
REMOTE_STAGE=''
REMOTE_STAGE_HOST=''
SSH_OPTIONS=()
SCP_OPTIONS=()

# Command interface
usage() {
    cat << EOF
$SCRIPT_NAME $SCRIPT_VERSION
Usage: $SCRIPT_NAME [OPTIONS]

Upload fullchain.pem and private.key, install as fullchain.pem and privkey.pem,
and restart each configured NPM container. Default mode is dry-run (no SSH).
Deploy to DMZ, then services. Each container is restarted only if its files differ.
Stop on the first error. Previously completed targets remain updated.

Options:
  --config PATH        Literal config (default: config/cert-deploy-npm.conf)
  --source-dir PATH    Local cert-manage export directory
  --apply              Upload, install and restart when files differ
  -n, --dry-run        Validate local files and show plan only (default)
  --log-file PATH      Append script messages
  --version            Show version
  -h, --help           Show help

DMZ defaults (NPM_HOST, NPM_CONTAINER, DEST_DIR):
  Host:      $NPM_HOST
  Container: $NPM_CONTAINER
  Target:    $DEST_DIR

Services defaults (SERVICES_NPM_HOST, SERVICES_NPM_CONTAINER, SERVICES_DEST_DIR):
  Host:      $SERVICES_NPM_HOST
  Container: $SERVICES_NPM_CONTAINER
  Target:    $SERVICES_DEST_DIR

The optional config file overrides these defaults. SSH_PORT and STOP_TIMEOUT
apply to both targets.

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

cleanup_remote_stage() {
    if [[ -n $REMOTE_STAGE ]]; then
        ssh "${SSH_OPTIONS[@]}" "$REMOTE_STAGE_HOST" "rm -rf -- '$REMOTE_STAGE'" < /dev/null || {
            warn "Remote staging cleanup failed. Remove after inspection: $REMOTE_STAGE_HOST:$REMOTE_STAGE"
            return 1
        }
        REMOTE_STAGE=''
        REMOTE_STAGE_HOST=''
    fi
    return 0
}

cleanup() {
    local rc=$?
    trap - EXIT
    cleanup_remote_stage || { ((rc != 0)) || rc=1; }
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

validate_target() {
    local label=$1 host=$2 container=$3 destination=$4
    # Remote command arguments are restricted to literal shell-safe characters.
    [[ $host =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "$label host must be user@hostname."
    [[ $container =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "Invalid $label container name."
    [[ $destination =~ ^/[a-zA-Z0-9_./-]+$ && $destination != / && $destination != */ && $destination != *'//'* && /$destination/ != */../* && /$destination/ != */./* ]] || die "$label destination must be an absolute path without spaces or dot components."
}

deploy_target() {
    local label=$1 host=$2 container=$3 destination=$4
    local cert_hash=$5 key_hash=$6 helper=$7 remote_stage
    log "Deploying to $label: $host:$destination (container: $container)"
    # The prepare helper checks the target path and container before creating staging.
    # Register the stage for cleanup only after validating the helper's response.
    remote_stage=$(ssh "${SSH_OPTIONS[@]}" "$host" "bash -s -- prepare '$destination' '$container'" < "$helper")
    [[ $remote_stage == "$destination/.cert-deploy."* && ${remote_stage##*/} =~ ^\.cert-deploy\.[a-zA-Z0-9]+$ ]] || die "$label: Unexpected remote staging response."
    REMOTE_STAGE_HOST=$host
    REMOTE_STAGE=$remote_stage
    scp -p "${SCP_OPTIONS[@]}" "$STAGING/fullchain.pem" "$host:$REMOTE_STAGE/fullchain.pem"
    scp -p "${SCP_OPTIONS[@]}" "$STAGING/private.key" "$host:$REMOTE_STAGE/privkey.pem"
    ssh "${SSH_OPTIONS[@]}" "$host" "bash -s -- deploy '$destination' '$container' '$REMOTE_STAGE' '$STOP_TIMEOUT' '$cert_hash' '$key_hash'" < "$helper"
    cleanup_remote_stage
    ok "$label deployment completed. An unchanged pair does not trigger a restart."
}

# Operations
main() {
    local cert_hash key_hash target_index helper="$SCRIPT_DIR/lib/cert-deploy-npm-remote.sh"
    local -a target_labels target_hosts target_containers target_dirs
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
    require_cmds openssl ssh scp mkdir mktemp cp rm cut touch
    [[ $(openssl version) == 'OpenSSL 3.'* ]] || die 'OpenSSL 3.x is required.'
    target_labels=('DMZ' 'services')
    target_hosts=("$NPM_HOST" "$SERVICES_NPM_HOST")
    target_containers=("$NPM_CONTAINER" "$SERVICES_NPM_CONTAINER")
    target_dirs=("$DEST_DIR" "$SERVICES_DEST_DIR")
    for target_index in "${!target_labels[@]}"; do
        validate_target "${target_labels[target_index]}" "${target_hosts[target_index]}" "${target_containers[target_index]}" "${target_dirs[target_index]}"
    done
    [[ $DOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ && $DOMAIN == *.* ]] || die 'Invalid DOMAIN.'
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
    for target_index in "${!target_labels[@]}"; do
        log "${target_labels[target_index]} target: ${target_hosts[target_index]}:${target_dirs[target_index]}"
        log "${target_labels[target_index]} container: ${target_containers[target_index]} (shutdown timeout: ${STOP_TIMEOUT}s)"
    done
    if ((DRY_RUN)); then
        log 'Would deploy to DMZ, then services: upload, back up and replace changed files, then restart each changed NPM. No SSH connection made.'
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
    for target_index in "${!target_labels[@]}"; do
        deploy_target "${target_labels[target_index]}" "${target_hosts[target_index]}" "${target_containers[target_index]}" "${target_dirs[target_index]}" "$cert_hash" "$key_hash" "$helper"
    done
    ok 'Certificate deployment completed for both NPM targets.'
}

# Entry point
main "$@"

