#!/usr/bin/env bash
#
# Script: cert-manage-tests.sh
# Purpose: Test issuance, renewal, SAN changes and export protection without network access.
# Version: 1.0.1
# Requires: Bash 5+, OpenSSL 3+ and standard filesystem utilities.
# Documentation: docs/cert-manage-user-manual.md
#
set -Eeuo pipefail
umask 077
((BASH_VERSINFO[0] >= 5)) || { printf 'Bash 5+ required.\n' >&2; exit 1; }
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cert-manage-tests.XXXXXXXX")
TEST_ROOT=$(cd -- "$TEST_ROOT" && pwd -P)
export TEST_ROOT
trap 'rm -rf -- "$TEST_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "FAIL at line %s\n" "$LINENO" >&2' ERR
export PATH="${BASH%/*}:$PATH"
export SSL_CERT_FILE="$TEST_ROOT/ca.pem"
unset FAIL_ISSUE BAD_EXPORT RENEW_RC
mkdir "$TEST_ROOT/acme" "$TEST_ROOT/configs"
cp "$ROOT/tests/cert-manage-acme-stub.sh" "$TEST_ROOT/acme/acme.sh"
chmod 700 "$TEST_ROOT/acme/acme.sh"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TEST_ROOT/ca.key" -out "$SSL_CERT_FILE" \
    -days 2 -subj '/CN=Offline Test CA' -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' > /dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$TEST_ROOT/leaf.key" > /dev/null 2>&1
base=("$BASH" "$ROOT/cert-manage.sh" --config-dir "$TEST_ROOT/configs" --acme-home "$TEST_ROOT/acme" --output-root "$TEST_ROOT/output")
initial=('example.com' '*.example.com' '*.services.example.com')
published="$TEST_ROOT/output/example.com/letsencrypt/rsa-4096"
config="$TEST_ROOT/configs/example.com.conf"
result=''

# Helpers
pass() { printf 'PASS %s\n' "$*"; }
write_names() {
    { printf "DOMAIN='example.com'\nCERT_NAMES=(\n"; printf "    '%s'\n" "$@"; printf ')\n'; } > "$config"
    chmod 600 "$config"
}
run_ok() {
    if result=$("${base[@]}" "$@" 2>&1); then return 0; fi
    printf '%s\n' "$result" >&2
    return 1
}
run_fail() {
    if result=$("${base[@]}" "$@" 2>&1); then
        printf 'Expected failure but command succeeded:\n%s\n' "$result" >&2
        return 1
    fi
}
reset_calls() { : > "$TEST_ROOT/calls"; }
called() { grep -Fq -- "$1" "$TEST_ROOT/calls"; }
assert_unchanged() {
    local file
    for file in "$TEST_ROOT/snapshot/"*; do cmp "$file" "$published/${file##*/}"; done
}

# Operations
write_names "${initial[@]}"
run_ok
[[ $result == *'example.com: issue.'* && ! -e $TEST_ROOT/calls && ! -e $TEST_ROOT/output ]]
pass 'New-certificate dry-run makes no acme.sh calls or output directory'
run_ok --apply
grep -Fq -- '-----BEGIN PRIVATE KEY-----' "$published/private-pkcs8.pem"
for file in "$published/"*.pem "$published/private.key"; do
    mode=$(stat -f '%Lp' "$file" 2>/dev/null) || mode=$(stat -c '%a' "$file")
    (((8#$mode & 8#077) == 0))
done
pass 'Initial issuance, real RSA 4096 validation and private PEM exports'
reset_calls
run_ok --apply
called --renew
! called --force
pass 'Unchanged SANs use renewal and accept not-due exit 2'
write_names '*.services.example.com' '*.example.com' 'example.com' 'example.com'
run_ok
[[ $result == *'example.com: renew.'* ]]
pass 'SAN ordering and duplicates do not trigger replacement'
write_names "${initial[@]}" '*.guest.example.com'
run_ok
[[ $result == *'example.com: reissue.'* ]]
reset_calls
run_ok --apply
called --issue
called --force
pass 'SAN addition forces replacement'
write_names 'example.com' '*.example.com'
reset_calls
run_ok --apply
called --issue
! called '*.services.example.com'
pass 'SAN removal forces replacement and exact SAN validation'
reset_calls
run_ok --force --apply
called --renew
called --force
pass 'Explicit forced renewal'
reset_calls
run_ok --export-only --apply
called --install-cert
! called --issue
! called --renew
pass 'Export-only does not issue or renew'
mkdir "$TEST_ROOT/snapshot"
cp "$published/"*.pem "$published/private.key" "$TEST_ROOT/snapshot/"
export RENEW_RC=1
run_fail --apply
unset RENEW_RC
assert_unchanged
export BAD_EXPORT=1
run_fail --apply
unset BAD_EXPORT
assert_unchanged
[[ ! -e $TEST_ROOT/acme/.cert-manage.lock ]]
pass 'Renewal failure and invalid key preserve verified exports and release lock'
write_names "${initial[@]}"
reset_calls
run_fail --apply --export-only
[[ ! -s $TEST_ROOT/calls ]]
export FAIL_ISSUE=1
run_fail --apply
unset FAIL_ISSUE
assert_unchanged
pass 'Changed SANs reject export-only and failed issuance preserves exports'
write_names 'example.com' '*.example.com'
state_config="$TEST_ROOT/acme/example.com/example.com.conf"
cp "$state_config" "$TEST_ROOT/saved.conf"
sed "s/^Le_Alt=.*/Le_Alt='*.old.example.com'/" "$TEST_ROOT/saved.conf" > "$state_config"
run_ok
[[ $result == *'example.com: reissue.'* ]]
cp "$TEST_ROOT/saved.conf" "$state_config"
pass 'Saved renewal SAN drift detected even when certificate matches'
cat > "$config" <<'EOF'
DOMAIN='example.com'
CERT_NAMES=('example.com' '$(touch /tmp/unsafe)')
EOF
run_fail --apply
pass 'Literal parser rejects shell substitution'
write_names 'example.com' '*.example.com'
run_fail --apply --dry-run
run_fail --force --export-only
run_fail --domain
pass 'Conflicting and incomplete options rejected'
mkdir "$TEST_ROOT/acme/.cert-manage.lock"
printf 'another-process\n' > "$TEST_ROOT/acme/.cert-manage.lock/owner"
reset_calls
run_fail --apply
[[ ! -s $TEST_ROOT/calls && -d $TEST_ROOT/acme/.cert-manage.lock ]]
rm "$TEST_ROOT/acme/.cert-manage.lock/owner"
rmdir "$TEST_ROOT/acme/.cert-manage.lock"
pass 'Existing lock is neither stolen nor removed'
run_ok --config-dir "$ROOT/config/certificates"
[[ $result == *'phillipmcmahon.com: issue.'* && $result == *'the-farriers.com: issue.'* ]]
pass 'Both supplied domain configs load successfully'
printf 'All offline integration checks passed.\n'
