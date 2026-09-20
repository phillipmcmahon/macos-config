#!/usr/bin/env bash
#
# Script: cert-the-farriers-renew.sh
# Purpose: Renew the-farriers.com and export verified PEM files for UniFi.
# Version: 1.2.0
# Requires: Bash 5+, OpenSSL 3+, adjacent lib/common.sh and existing acme.sh RSA certificate.
# Documentation: Run with --help.
#

# Runtime and configuration
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION='1.2.0'
readonly VERSION="$SCRIPT_VERSION"
readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $SCRIPT_DIR/lib/common.sh ]] || {
    printf 'ERROR Missing shared library: %s/lib/common.sh\n' "$SCRIPT_DIR" >&2
    exit 1
}
source "$SCRIPT_DIR/lib/common.sh"
for helper in load_config log ok die require_cmds lock_acquire lock_release; do
    declare -F "$helper" > /dev/null || {
        printf 'ERROR Incompatible lib/common.sh: missing %s\n' "$helper" >&2
        exit 1
    }
done
unset helper
readonly CONFIG_KEYS='ACME_HOME OUTPUT_DIR DNS_SLEEP'
readonly DOMAIN='the-farriers.com'
readonly -a CERT_NAMES=(
    'the-farriers.com'
    '*.the-farriers.com'
    '*.guest.the-farriers.com'
    '*.management.the-farriers.com'
    '*.services.the-farriers.com'
    '*.trusted.the-farriers.com'
)
ACME_HOME="$HOME/.acme.sh"
OUTPUT_DIR="$HOME/certificates/the-farriers.com/letsencrypt"
DNS_SLEEP=300
FORCE=0
EXPORT_ONLY=0
STAGING=''
DRY_RUN=1
MODE_OPTION=''
CONFIG_FILE="$SCRIPT_DIR/config/cert-the-farriers-renew.conf"
CONFIG_EXPLICIT=0

# Command interface
usage() {
    cat << EOF
${0##*/} $SCRIPT_VERSION
Usage: ${0##*/} [OPTIONS]

Renew the existing RSA certificate using its saved SANs and ClouDNS settings.
Reuse the credentials saved by acme.sh. No credentials are printed or prompted.
If renewal is not due, export the current certificate instead.
This script does not issue a new certificate or change the existing RSA key.
Default mode is dry-run. Add --apply to renew or export.
With --force, also specify --apply to perform immediate renewal.

Options:
  --config PATH        Literal config (default: adjacent config/cert-the-farriers-renew.conf)
  --apply              Perform renewal and export
  -n, --dry-run        Show the plan only (default)
  --log-file PATH      Append script messages (acme.sh output remains on terminal)
  --version            Show version
  -h, --help           Show help
  --force              Renew now, even if not due (CA rate limits still apply)
  --export-only        Export the existing certificate without renewal
  --dns-sleep SECONDS  DNS propagation wait (default: 300)
  --output-dir PATH    Export directory (default: ~/certificates/the-farriers.com/letsencrypt)
  --acme-home PATH     acme.sh installation and configuration (default: ~/.acme.sh)

UniFi import:
  Certificate: fullchain.pem
  Private Key: private-pkcs8.pem

Also exports certificate.pem, chain.pem and private.key. All files are private.
The .acme-export subdirectory holds persistent acme.sh installation targets.
acme.sh remembers those targets for its own future renewals. Run this script
again after such a renewal to refresh the verified files and PKCS#8 conversion.
Existing acme.sh renewal/install hooks can run during renewal and installation.
Automatic installation into UniFi is not configured by this script.
Do not run it concurrently with a separate acme.sh renewal process.
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

read_configuration() {
    local key declaration
    # Discover the selected config first so command-line values take precedence.
    while (($#)); do
        case $1 in
            --help | -h | --version) return ;;
            --config)
                (($# >= 2)) && [[ -n $2 ]] || die 'Missing value for --config'
                CONFIG_FILE=$2
                CONFIG_EXPLICIT=1
                shift
                ;;
            --dns-sleep | --output-dir | --acme-home | --log-file)
                (($# >= 2)) || die "Missing value for $1"
                shift
                ;;
        esac
        shift
    done
    if [[ ! -e $CONFIG_FILE && ! -L $CONFIG_FILE ]]; then
        ((CONFIG_EXPLICIT == 0)) || die "Config file not found: $CONFIG_FILE"
        return 0
    fi
    CONFIG_FILE=$(cd -- "$(dirname -- "$CONFIG_FILE")" && printf '%s/%s' "$(pwd -P)" "${CONFIG_FILE##*/}")
    load_config "$CONFIG_FILE" "$CONFIG_KEYS" || die "Cannot load configuration: $CONFIG_FILE"
    for key in ACME_HOME OUTPUT_DIR DNS_SLEEP; do
        declaration=$(declare -p "$key")
        [[ $declaration != 'declare -a '* && $declaration != 'declare -A '* ]] || die "$key must be a scalar value."
        [[ -n ${!key} ]] || die "$key must not be empty."
    done
}

validate_export() {
    local cert_hash key_hash chain_hash name san_text key_text
    openssl pkey -in "$STAGING/private.key" -check -noout > /dev/null
    key_text=$(openssl rsa -in "$STAGING/private.key" -pubout 2>/dev/null |
        openssl pkey -pubin -text -noout)
    [[ $key_text == *'Public-Key: (4096 bit)'* ]] || die 'Expected the existing RSA 4096-bit key.'
    unset key_text
    openssl x509 -in "$STAGING/certificate.pem" -checkend 0 -noout || die 'Certificate has expired.'
    cert_hash=$(openssl x509 -in "$STAGING/certificate.pem" -pubkey -noout |
        openssl pkey -pubin -outform DER | openssl dgst -sha256)
    key_hash=$(openssl pkey -in "$STAGING/private-pkcs8.pem" -pubout -outform DER |
        openssl dgst -sha256)
    [[ $cert_hash == "$key_hash" ]] || die 'Certificate and exported private key do not match.'
    cert_hash=$(openssl x509 -in "$STAGING/certificate.pem" -outform DER | openssl dgst -sha256)
    chain_hash=$(openssl x509 -in "$STAGING/fullchain.pem" -outform DER | openssl dgst -sha256)
    [[ $cert_hash == "$chain_hash" ]] || die 'Full chain does not start with the server certificate.'
    openssl verify -partial_chain -trusted "$STAGING/chain.pem" "$STAGING/certificate.pem" > /dev/null
    san_text=$(openssl x509 -in "$STAGING/certificate.pem" -noout -ext subjectAltName |
        tr ',' '\n' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
    for name in "${CERT_NAMES[@]}"; do
        grep -Fxq "DNS:$name" <<< "$san_text" || die "Missing certificate SAN: $name"
    done
    ok 'RSA 4096-bit key, certificate match, chain and required SANs verified.'
}

# Operations
main() {
    local rc=0 export_dir file
    local -a renew_args=()
    read_configuration "$@"
    while (($#)); do
        case $1 in
            --force) FORCE=1 ;;
            --export-only) EXPORT_ONLY=1 ;;
            --dns-sleep | --output-dir | --acme-home)
                (($# >= 2)) && [[ -n $2 ]] || die "Missing value for $1"
                case $1 in
                    --dns-sleep) DNS_SLEEP=$2 ;;
                    --output-dir) OUTPUT_DIR=$2 ;;
                    --acme-home) ACME_HOME=$2 ;;
                esac
                shift
                ;;
            --config)
                shift
                ;;
            --apply)
                [[ $MODE_OPTION != dry ]] || die '--apply and --dry-run conflict.'
                MODE_OPTION=apply
                DRY_RUN=0
                ;;
            -n | --dry-run)
                [[ $MODE_OPTION != apply ]] || die '--apply and --dry-run conflict.'
                MODE_OPTION=dry
                DRY_RUN=1
                ;;
            --log-file)
                (($# >= 2)) && [[ -n $2 ]] || die 'Missing value for --log-file'
                LOG_FILE=$2
                shift
                ;;
            --version) printf '%s\n' "$SCRIPT_VERSION"; return ;;
            -h | --help) usage; return ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    ((BASH_VERSINFO[0] >= 5)) || die 'Bash 5+ is required. Use Homebrew Bash.'
    ((!(FORCE && EXPORT_ONLY))) || die '--force and --export-only cannot be combined.'
    [[ $DNS_SLEEP =~ ^[1-9][0-9]*$ ]] || die '--dns-sleep must be a positive integer.'
    require_cmds openssl mkdir mktemp cp mv chmod grep sed tr
    [[ $(openssl version) == 'OpenSSL 3.'* ]] || die 'OpenSSL 3+ from Homebrew is required.'
    [[ -x $ACME_HOME/acme.sh ]] || die "acme.sh not found: $ACME_HOME/acme.sh"
    ACME_HOME=$(cd -- "$ACME_HOME" && pwd -P)
    [[ -f $ACME_HOME/$DOMAIN/$DOMAIN.conf ]] || die 'Existing RSA certificate configuration not found.'
    if [[ -n ${LOG_FILE:-} ]]; then
        [[ ! -L $LOG_FILE ]] || die 'Refusing a symlink log file.'
        touch -- "$LOG_FILE" || die "Cannot write log: $LOG_FILE"
    fi
    if ((DRY_RUN)); then
        log "Certificate: $DOMAIN (existing RSA configuration and saved SANs)"
        log "Renewal: export-only=$EXPORT_ONLY, force=$FORCE, DNS wait=${DNS_SLEEP}s"
        log "Would install to $OUTPUT_DIR/.acme-export, validate and export UniFi PEM files."
        return
    fi
    mkdir -p -- "$OUTPUT_DIR"
    OUTPUT_DIR=$(cd -- "$OUTPUT_DIR" && pwd -P)
    chmod 700 "$OUTPUT_DIR"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    lock_acquire "$OUTPUT_DIR/.renew.lock" || exit 1
    if ((!EXPORT_ONLY)); then
        renew_args=(--renew --home "$ACME_HOME" --server letsencrypt -d "$DOMAIN" --dnssleep "$DNS_SLEEP")
        if ((FORCE)); then renew_args+=(--force); fi
        log "Checking renewal for $DOMAIN."
        "$ACME_HOME/acme.sh" "${renew_args[@]}" || rc=$?
        case $rc in
            0) ok 'acme.sh renewal operation completed.' ;;
            2) log 'Renewal skipped by acme.sh. Exporting the current certificate.' ;;
            *) die "Renewal failed (exit $rc). Existing UniFi export files were not changed." ;;
        esac
    fi
    # Use permanent install targets. acme.sh records these paths for renewals.
    export_dir="$OUTPUT_DIR/.acme-export"
    mkdir -p -- "$export_dir"
    chmod 700 "$export_dir"
    "$ACME_HOME/acme.sh" --install-cert --home "$ACME_HOME" -d "$DOMAIN" \
        --key-file "$export_dir/private.key" \
        --cert-file "$export_dir/certificate.pem" \
        --ca-file "$export_dir/chain.pem" \
        --fullchain-file "$export_dir/fullchain.pem"
    STAGING=$(mktemp -d "$OUTPUT_DIR/.unifi-export.XXXXXXXX")
    for file in private.key certificate.pem chain.pem fullchain.pem; do
        [[ -s $export_dir/$file && ! -L $export_dir/$file ]] || die "Missing or unsafe export: $file"
        chmod 600 "$export_dir/$file"
        cp -- "$export_dir/$file" "$STAGING/$file"
    done
    openssl pkcs8 -topk8 -nocrypt -in "$STAGING/private.key" -out "$STAGING/private-pkcs8.pem"
    validate_export
    # Publish only after validation. Each rename replaces one complete file.
    for file in private.key certificate.pem chain.pem fullchain.pem private-pkcs8.pem; do
        chmod 600 "$STAGING/$file"
        mv -f -- "$STAGING/$file" "$OUTPUT_DIR/$file"
    done
    rmdir -- "$STAGING"
    STAGING=''
    openssl x509 -in "$OUTPUT_DIR/certificate.pem" -noout -dates
    ok "UniFi certificate: $OUTPUT_DIR/fullchain.pem"
    ok "UniFi private key: $OUTPUT_DIR/private-pkcs8.pem"
    log 'Import both files into UniFi. No gateway configuration was changed.'
}

# Entry point
main "$@"
