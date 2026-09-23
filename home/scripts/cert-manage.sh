#!/usr/bin/env bash
#
# Script: cert-manage.sh
# Purpose: Issue or renew configured RSA 4096 certificates and export verified PEM files.
# Version: 1.0.1
# Requires: Bash 5+, OpenSSL 3+, acme.sh and adjacent lib/common.sh.
# Documentation: docs/cert-manage-user-manual.md or run with --help.
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
export LC_ALL=C
readonly SCRIPT_VERSION='1.0.1'
readonly VERSION="$SCRIPT_VERSION"
readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
[[ -r $SCRIPT_DIR/lib/common.sh ]] || {
    printf 'ERROR Missing shared library: %s/lib/common.sh\n' "$SCRIPT_DIR" >&2
    exit 1
}
source "$SCRIPT_DIR/lib/common.sh"
for helper in load_config log ok die require_cmds reject_symlinks lock_acquire lock_release; do
    declare -F "$helper" > /dev/null || { printf 'ERROR Missing helper: %s\n' "$helper" >&2; exit 1; }
done
unset helper
readonly CONFIG_KEYS='ACME_HOME OUTPUT_ROOT CERT_CONFIG_DIR DNS_SLEEP'
readonly CERT_CONFIG_KEYS='DOMAIN CERT_NAMES'
readonly CA_URL='https://acme-v02.api.letsencrypt.org/directory'
ACME_HOME="$HOME/.acme.sh"
OUTPUT_ROOT="$HOME/certificates"
CERT_CONFIG_DIR="$SCRIPT_DIR/config/certificates"
DNS_SLEEP=300
CONFIG_FILE="$SCRIPT_DIR/config/cert-manage.conf"
CONFIG_EXPLICIT=0
SELECTED_DOMAIN=''
ALL=0
DRY_RUN=1
MODE_OPTION=''
FORCE=0
EXPORT_ONLY=0
PROMPT_CREDENTIALS=0
STAGING=''
DOMAIN=''
CERT_NAMES=()
DESIRED_NAMES=''
ACTION=''
REASON=''
STATE_DIR=''
OUTPUT_DIR=''

# Command interface
usage() {
    cat << EOF
$SCRIPT_NAME $SCRIPT_VERSION
Usage: $SCRIPT_NAME [--domain DOMAIN | --all] [OPTIONS]

Manage RSA 4096 certificates using Let’s Encrypt and ClouDNS DNS validation.
Default: dry-run of all configured certificates. No acme.sh calls in dry-run.
Config SAN additions/removals trigger replacement issuance with --apply.
Unchanged certificates use acme.sh renewal timing. Reordering has no effect.

Options:
  --domain DOMAIN      Process one domain (config filename DOMAIN.conf)
  --all                Process all certificate configs (also the default)
  --config PATH        Shared literal config (default: config/cert-manage.conf)
  --config-dir PATH    Directory containing certificate configs
  --acme-home PATH     acme.sh installation and state (default: ~/.acme.sh)
  --output-root PATH   Export root (default: ~/certificates)
  --dns-sleep SECONDS  DNS propagation wait (default: 300)
  --apply              Perform issuance/renewal and verified export
  -n, --dry-run        Show decisions only (default)
  --force              Force renewal with --apply
  --export-only        Export only, requiring an exact match to configured SANs
  --prompt-credentials Prompt for ClouDNS main-account credentials with --apply
  --log-file PATH      Append wrapper messages (not acme.sh output)
  --version            Show version
  -h, --help           Show help

Exports: OUTPUT_ROOT/DOMAIN/letsencrypt/rsa-4096/
  fullchain.pem, certificate.pem, chain.pem, private.key, private-pkcs8.pem
UniFi import: fullchain.pem and private-pkcs8.pem.

Uses ClouDNS credentials already saved by acme.sh or exported in the environment.
Existing acme.sh hooks and install targets may run during renewal/installation.
Do not overlap this script with an independent acme.sh process.
EOF
}

# Helpers
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n $STAGING ]]; then rm -rf -- "$STAGING" || rc=1; fi
    lock_release || rc=1
    exit "$rc"
}

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

require_scalar() {
    local declaration
    declaration=$(declare -p "$1")
    [[ $declaration != 'declare -a '* && $declaration != 'declare -A '* && -n ${!1} ]] || die "$1 must be a non-empty scalar."
}

valid_name() {
    local name=$1 label
    local -a labels=()
    name=${name#\*.}
    [[ ${#name} -le 253 && $name == *.* && $name != *. && $name != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$name"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
    [[ ${labels[-1]} =~ [a-z] ]] || return 1
}

normalise_names() { printf '%s\n' "$@" | tr '[:upper:]' '[:lower:]' | sort -u; }

read_configuration() {
    local key
    while (($#)); do
        case $1 in
            --help | -h | --version) return ;;
            --config | --config-dir | --acme-home | --output-root | --dns-sleep | --domain | --log-file)
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
    for key in ACME_HOME OUTPUT_ROOT CERT_CONFIG_DIR DNS_SLEEP; do require_scalar "$key"; done
}

load_certificate() {
    local path=$1 name declaration
    DOMAIN=''
    unset CERT_NAMES
    load_config "$path" "$CERT_CONFIG_KEYS" || die "Cannot load certificate config: $path"
    require_scalar DOMAIN
    valid_name "$DOMAIN" && [[ $DOMAIN != \*.* ]] || die "Invalid primary domain: $DOMAIN"
    [[ ${path##*/} == "$DOMAIN.conf" ]] || die "Config filename must be $DOMAIN.conf"
    declaration=$(declare -p CERT_NAMES 2>/dev/null) || die "Missing CERT_NAMES in $path"
    [[ $declaration == 'declare -a '* && ${#CERT_NAMES[@]} -gt 0 ]] || die 'CERT_NAMES must be a non-empty array.'
    for name in "${CERT_NAMES[@]}"; do
        valid_name "$name" || die "Invalid SAN: $name (use lower-case ASCII or punycode)."
    done
    DESIRED_NAMES=$(normalise_names "${CERT_NAMES[@]}")
    grep -Fxq -- "$DOMAIN" <<< "$DESIRED_NAMES" || die "CERT_NAMES must include $DOMAIN"
    # Keep the primary name first for acme.sh identity, then sort the other names.
    CERT_NAMES=("$DOMAIN")
    while IFS= read -r name; do [[ $name == "$DOMAIN" ]] || CERT_NAMES+=("$name"); done <<< "$DESIRED_NAMES"
    STATE_DIR="$ACME_HOME/$DOMAIN"
    OUTPUT_DIR="$OUTPUT_ROOT/$DOMAIN/letsencrypt/rsa-4096"
    reject_symlinks "$STATE_DIR" || die 'Unsafe acme.sh state path.'
    reject_symlinks "$OUTPUT_DIR" || die 'Unsafe output path.'
}

read_state_value() {
    # Read only known scalar fields. Never source acme.sh state as shell code here.
    local key=$1 line value='' count=0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "$key="* ]] || continue
        ((count += 1))
        value=${line#*=}
        [[ $value != "("* ]] || die "Unsupported state value for $key"
        if [[ $value == \"*\" || $value == \'*\' ]]; then value=${value:1:${#value}-2}; fi
    done < "$STATE_DIR/$DOMAIN.conf"
    ((count <= 1)) || die "Duplicate state field: $key"
    printf '%s\n' "$value"
}

certificate_names() {
    local text
    text=$(openssl x509 -in "$1" -noout -ext subjectAltName) || return 1
    printf '%s\n' "$text" | tr ',' '\n' | sed -nE 's/^[[:space:]]*DNS:([^[:space:]]+)[[:space:]]*$/\1/p' |
        tr '[:upper:]' '[:lower:]' | sort -u
}

rsa_4096() {
    local text
    text=$(openssl rsa -pubin -in /dev/stdin -text -noout 2>/dev/null) || return 1
    [[ $text == *'Public-Key: (4096 bit)'* ]]
}

determine_action() {
    local saved_main saved_alt saved_names saved_key saved_ca saved_dns cert_names item
    local -a alt_names=() dns_methods=()
    ACTION=issue REASON='No existing RSA certificate.'
    if [[ -f $STATE_DIR/$DOMAIN.conf ]]; then
        [[ ! -L $STATE_DIR/$DOMAIN.conf ]] || die 'Refusing symlink certificate state.'
        ACTION=reissue REASON='Incomplete existing certificate state.'
        saved_main=$(read_state_value Le_Domain)
        saved_alt=$(read_state_value Le_Alt)
        saved_key=$(read_state_value Le_Keylength)
        saved_ca=$(read_state_value Le_API)
        saved_dns=$(read_state_value Le_Webroot)
        [[ $saved_main == "$DOMAIN" ]] || die 'Existing acme.sh primary domain does not match.'
        if [[ -n $saved_ca && $saved_ca != "$CA_URL" ]]; then die "Existing certificate uses another CA. Use a separate ACME_HOME: $DOMAIN"; fi
        [[ -n $saved_dns ]] || die "Missing DNS method in existing state: $DOMAIN"
        IFS=, read -r -a dns_methods <<< "$saved_dns"
        for item in "${dns_methods[@]}"; do [[ $item == dns_cloudns ]] || die "Existing certificate does not use ClouDNS: $DOMAIN"; done
        [[ $saved_key == 4096 ]] || die "Existing key is not configured as RSA 4096: $DOMAIN. Migrate it separately or use a separate ACME_HOME."
        if [[ -s $STATE_DIR/$DOMAIN.cer && -s $STATE_DIR/$DOMAIN.key ]]; then
            [[ ! -L $STATE_DIR/$DOMAIN.cer && ! -L $STATE_DIR/$DOMAIN.key ]] || die 'Refusing symlink certificate/key.'
            IFS=, read -r -a alt_names <<< "$saved_alt"
            if [[ $saved_alt == no || -z $saved_alt ]]; then alt_names=(); fi
            saved_names=$(normalise_names "$saved_main" "${alt_names[@]}")
            cert_names=$(certificate_names "$STATE_DIR/$DOMAIN.cer") || die 'Cannot read existing certificate.'
            openssl x509 -in "$STATE_DIR/$DOMAIN.cer" -pubkey -noout | rsa_4096 || die 'Existing certificate is not RSA 4096.'
            if [[ $saved_names != "$DESIRED_NAMES" || $cert_names != "$DESIRED_NAMES" ]]; then
                REASON='Configured SANs differ from the certificate or saved renewal settings.'
            elif ! openssl x509 -in "$STATE_DIR/$DOMAIN.cer" -checkend 0 -noout > /dev/null; then
                REASON='Existing certificate has expired.'
            else
                ACTION=renew REASON='SANs match. acme.sh will check whether renewal is due.'
            fi
        fi
    elif [[ -e $STATE_DIR ]]; then
        die "RSA state directory exists without its config. Inspect before continuing: $STATE_DIR"
    fi
    if ((EXPORT_ONLY)); then
        [[ $ACTION == renew ]] || die "Cannot export $DOMAIN: $REASON"
        ACTION=export REASON='Export-only requested.'
    elif ((FORCE)) && [[ $ACTION == renew ]]; then
        REASON='Forced renewal requested.'
    fi
}

validate_export() {
    local cert_hash key_hash leaf_hash full_hash names
    openssl pkey -in "$STAGING/private.key" -check -noout > /dev/null
    openssl pkey -in "$STAGING/private.key" -pubout | rsa_4096 || die 'Exported key is not RSA 4096.'
    openssl x509 -in "$STAGING/certificate.pem" -checkend 0 -noout > /dev/null || die 'Exported certificate has expired.'
    cert_hash=$(openssl x509 -in "$STAGING/certificate.pem" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
    key_hash=$(openssl pkey -in "$STAGING/private-pkcs8.pem" -pubout -outform DER | openssl dgst -sha256)
    [[ $cert_hash == "$key_hash" ]] || die 'Certificate and private key do not match.'
    leaf_hash=$(openssl x509 -in "$STAGING/certificate.pem" -outform DER | openssl dgst -sha256)
    full_hash=$(openssl x509 -in "$STAGING/fullchain.pem" -outform DER | openssl dgst -sha256)
    [[ $leaf_hash == "$full_hash" ]] || die 'Full chain does not start with the leaf certificate.'
    # Require fullchain to contain exactly the installed leaf and chain, in order.
    [[ $(cat "$STAGING/certificate.pem" "$STAGING/chain.pem" | tr -d '[:space:]') == "$(tr -d '[:space:]' < "$STAGING/fullchain.pem")" ]] || die 'Full chain differs from certificate plus chain.'
    openssl verify -purpose sslserver -untrusted "$STAGING/chain.pem" "$STAGING/certificate.pem" > /dev/null || die 'Certificate does not verify against the OpenSSL trust store.'
    names=$(certificate_names "$STAGING/certificate.pem") || die 'Cannot read exported SANs.'
    [[ $names == "$DESIRED_NAMES" ]] || die 'Exported SANs do not exactly match configuration.'
    ok 'RSA 4096, key match, trusted chain, validity and exact SAN set verified.'
}

export_certificate() {
    local export_dir="$OUTPUT_DIR/.acme-export" file
    reject_symlinks "$export_dir" || die 'Unsafe acme.sh export path.'
    mkdir -p -- "$export_dir"
    chmod 700 "$OUTPUT_DIR" "$export_dir"
    for file in private.key certificate.pem chain.pem fullchain.pem private-pkcs8.pem; do
        [[ ! -L $export_dir/$file && ! -L $OUTPUT_DIR/$file ]] || die "Refusing symlink export: $file"
    done
    "$ACME_HOME/acme.sh" --install-cert --home "$ACME_HOME" -d "$DOMAIN" \
        --key-file "$export_dir/private.key" --cert-file "$export_dir/certificate.pem" \
        --ca-file "$export_dir/chain.pem" --fullchain-file "$export_dir/fullchain.pem"
    STAGING=$(mktemp -d "$OUTPUT_DIR/.verified-export.XXXXXXXX")
    for file in private.key certificate.pem chain.pem fullchain.pem; do
        [[ -s $export_dir/$file && ! -L $export_dir/$file ]] || die "Missing or unsafe export: $file"
        chmod 600 "$export_dir/$file"
        cp -- "$export_dir/$file" "$STAGING/$file"
    done
    openssl pkcs8 -topk8 -nocrypt -in "$STAGING/private.key" -out "$STAGING/private-pkcs8.pem"
    validate_export
    # Each rename replaces a complete file, after all validation has succeeded.
    # The five-file set is not an atomic transaction. Consumers must wait for success.
    for file in private.key certificate.pem chain.pem fullchain.pem private-pkcs8.pem; do
        chmod 600 "$STAGING/$file"
        mv -f -- "$STAGING/$file" "$OUTPUT_DIR/$file"
    done
    rmdir -- "$STAGING"
    STAGING=''
    openssl x509 -in "$OUTPUT_DIR/certificate.pem" -noout -dates
    ok "Certificate: $OUTPUT_DIR/fullchain.pem"
    ok "Private key: $OUTPUT_DIR/private-pkcs8.pem"
}

# Operations
main() {
    local file name rc key value
    local -a files=() args=()
    read_configuration "$@"
    while (($#)); do
        case $1 in
            --config | --config-dir | --acme-home | --output-root | --dns-sleep | --domain | --log-file)
                (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "Missing value for $1"
                case $1 in
                    --config) ;;
                    --config-dir) CERT_CONFIG_DIR=$2 ;;
                    --acme-home) ACME_HOME=$2 ;;
                    --output-root) OUTPUT_ROOT=$2 ;;
                    --dns-sleep) DNS_SLEEP=$2 ;;
                    --domain) SELECTED_DOMAIN=$2 ;;
                    --log-file) LOG_FILE=$2 ;;
                esac
                shift ;;
            --all) ALL=1 ;;
            --apply) [[ $MODE_OPTION != dry ]] || die 'Conflicting modes.'; MODE_OPTION=apply; DRY_RUN=0 ;;
            -n | --dry-run) [[ $MODE_OPTION != apply ]] || die 'Conflicting modes.'; MODE_OPTION=dry; DRY_RUN=1 ;;
            --force) FORCE=1 ;;
            --export-only) EXPORT_ONLY=1 ;;
            --prompt-credentials) PROMPT_CREDENTIALS=1 ;;
            --version) printf '%s\n' "$SCRIPT_VERSION"; return ;;
            -h | --help) usage; return ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    ((!(FORCE && EXPORT_ONLY))) || die '--force and --export-only conflict.'
    [[ -z $SELECTED_DOMAIN || $ALL == 0 ]] || die '--domain and --all conflict.'
    [[ $DNS_SLEEP =~ ^[1-9][0-9]*$ ]] || die 'DNS_SLEEP must be a positive integer.'
    require_cmds openssl sort tr sed grep mkdir mktemp cp mv chmod stat cat rm rmdir
    [[ $(openssl version) == 'OpenSSL 3.'* ]] || die 'OpenSSL 3.x from Homebrew is required.'
    for key in ACME_HOME OUTPUT_ROOT CERT_CONFIG_DIR; do
        value=$(absolute_path "${!key}" "$SCRIPT_DIR")
        printf -v "$key" '%s' "$value"
        reject_symlinks "$value" || die "Unsafe path: $value"
    done
    [[ -x $ACME_HOME/acme.sh ]] || die "acme.sh not found: $ACME_HOME/acme.sh"
    [[ -d $CERT_CONFIG_DIR ]] || die "Certificate config directory not found: $CERT_CONFIG_DIR"
    if [[ -n ${LOG_FILE:-} ]]; then
        LOG_FILE=$(absolute_path "$LOG_FILE" "$PWD")
        reject_symlinks "$LOG_FILE" || die 'Unsafe log path.'
        touch -- "$LOG_FILE" || die 'Cannot write log file.'
    fi
    if [[ -n $SELECTED_DOMAIN ]]; then
        valid_name "$SELECTED_DOMAIN" && [[ $SELECTED_DOMAIN != \*.* ]] || die 'Invalid --domain.'
        files=("$CERT_CONFIG_DIR/$SELECTED_DOMAIN.conf")
    else
        shopt -s nullglob
        files=("$CERT_CONFIG_DIR/"*.conf)
        shopt -u nullglob
    fi
    ((${#files[@]})) || die 'No certificate configurations found.'
    # Preflight all configs before any ACME mutation.
    for file in "${files[@]}"; do
        [[ -f $file ]] || die "Certificate config not found: $file"
        load_certificate "$file"
        determine_action
        log "$DOMAIN: $ACTION. $REASON"
        for name in "${CERT_NAMES[@]}"; do log "  SAN: $name"; done
        log "  Export: $OUTPUT_DIR"
    done
    if ((DRY_RUN)); then log 'Dry-run complete. Use --apply to perform these actions.'; return; fi
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    lock_acquire "$ACME_HOME/.cert-manage.lock" || exit 1
    if ((PROMPT_CREDENTIALS && !EXPORT_ONLY)); then
        read -r -p 'ClouDNS API Auth ID: ' CLOUDNS_AUTH_ID < /dev/tty
        read -r -s -p 'ClouDNS API password: ' CLOUDNS_AUTH_PASSWORD < /dev/tty
        printf '\n'
        [[ -n $CLOUDNS_AUTH_ID && -n $CLOUDNS_AUTH_PASSWORD ]] || die 'Both credentials are required.'
        export CLOUDNS_AUTH_ID CLOUDNS_AUTH_PASSWORD
        unset CLOUDNS_SUB_AUTH_ID
    fi
    for file in "${files[@]}"; do
        load_certificate "$file"
        determine_action
        log "$DOMAIN: $ACTION. $REASON"
        rc=0
        case $ACTION in
            issue | reissue)
                args=(--issue --home "$ACME_HOME" --server letsencrypt --dns dns_cloudns --dnssleep "$DNS_SLEEP" --keylength 4096)
                for name in "${CERT_NAMES[@]}"; do args+=(-d "$name"); done
                # Force only a deliberate replacement, or an explicit --force request.
                if [[ $ACTION == reissue || $FORCE == 1 ]]; then args+=(--force); fi
                "$ACME_HOME/acme.sh" "${args[@]}" || rc=$?
                ((rc == 0)) || die "Issuance failed for $DOMAIN (exit $rc). Verified exports were not changed."
                ;;
            renew)
                args=(--renew --home "$ACME_HOME" --server letsencrypt -d "$DOMAIN" --dnssleep "$DNS_SLEEP")
                if ((FORCE)); then args+=(--force); fi
                "$ACME_HOME/acme.sh" "${args[@]}" || rc=$?
                case $rc in
                    0) ok 'Renewal completed.' ;;
                    2) log 'Renewal not due. Exporting the existing certificate.' ;;
                    *) die "Renewal failed for $DOMAIN (exit $rc). Verified exports were not changed." ;;
                esac ;;
        esac
        export_certificate
    done
}

# Entry point
main "$@"
