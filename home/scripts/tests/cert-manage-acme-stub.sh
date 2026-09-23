#!/usr/bin/env bash
#
# Script: cert-manage-acme-stub.sh
# Purpose: Emulate acme.sh locally for the certificate manager integration tests.
# Version: 1.0.1
# Requires: Bash 5+, OpenSSL 3+, TEST_ROOT set by cert-manage-tests.sh.
# Documentation: docs/cert-manage-user-manual.md
#
set -Eeuo pipefail
umask 077
: "${TEST_ROOT:?Run through cert-manage-tests.sh}"
printf '%s\t' "$@" >> "$TEST_ROOT/calls"
printf '\n' >> "$TEST_ROOT/calls"
operation='' acme_home='' domain='' keylength='' dns='' key_file='' cert_file='' ca_file='' fullchain_file=''
names=()
while (($#)); do
    case $1 in
        --issue | --renew | --install-cert) operation=$1 ;;
        --home) acme_home=$2; shift ;;
        -d) names+=("$2"); shift ;;
        --keylength) keylength=$2; shift ;;
        --dns) dns=$2; shift ;;
        --key-file) key_file=$2; shift ;;
        --cert-file) cert_file=$2; shift ;;
        --ca-file) ca_file=$2; shift ;;
        --fullchain-file) fullchain_file=$2; shift ;;
        --server | --dnssleep) shift ;;
        --force) ;;
        *) exit 99 ;;
    esac
    shift
done
domain=${names[0]}
state="$acme_home/$domain"
case $operation in
    --issue)
        [[ ${FAIL_ISSUE:-0} == 0 ]] || exit 1
        [[ $keylength == 4096 && $dns == dns_cloudns ]]
        mkdir -p "$state"
        cp "$TEST_ROOT/leaf.key" "$state/$domain.key"
        {
            printf 'subjectAltName=DNS:%s' "${names[0]}"
            for name in "${names[@]:1}"; do printf ',DNS:%s' "$name"; done
            printf '\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n'
        } > "$state/ext"
        openssl req -new -key "$state/$domain.key" -out "$state/request.csr" -subj "/CN=$domain" > /dev/null 2>&1
        openssl x509 -req -in "$state/request.csr" -CA "$TEST_ROOT/ca.pem" -CAkey "$TEST_ROOT/ca.key" \
            -set_serial 1234 -days 1 -extfile "$state/ext" -out "$state/$domain.cer" > /dev/null 2>&1
        alt=no
        if ((${#names[@]} > 1)); then alt=$(IFS=,; printf '%s' "${names[*]:1}"); fi
        {
            printf "Le_Domain='%s'\nLe_Alt='%s'\n" "$domain" "$alt"
            printf "Le_Keylength='4096'\nLe_API='https://acme-v02.api.letsencrypt.org/directory'\nLe_Webroot='dns_cloudns'\n"
        } > "$state/$domain.conf"
        ;;
    --renew) exit "${RENEW_RC:-2}" ;;
    --install-cert)
        cp "$state/$domain.cer" "$cert_file"
        cp "$state/$domain.key" "$key_file"
        cp "$TEST_ROOT/ca.pem" "$ca_file"
        cat "$cert_file" "$ca_file" > "$fullchain_file"
        if [[ ${BAD_EXPORT:-0} == 1 ]]; then cp "$TEST_ROOT/ca.key" "$key_file"; fi
        ;;
    *) exit 99 ;;
esac
