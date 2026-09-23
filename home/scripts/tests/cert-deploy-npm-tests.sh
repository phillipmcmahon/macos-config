#!/usr/bin/env bash
#
# Script: cert-deploy-npm-tests.sh
# Purpose: Offline deployment, no-change and rollback tests using Bash test doubles.
# Version: 1.0.0
# Requires: Bash 5+, OpenSSL 3+ and standard filesystem utilities.
# Documentation: docs/cert-deploy-npm-user-manual.md
#
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cert-deploy-tests.XXXXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
export TEST_ROOT
trap 'rm -rf -- "$TEST_ROOT"' EXIT
trap 'printf "FAIL at line %s\n" "$LINENO" >&2' ERR
mkdir "$TEST_ROOT/bin" "$TEST_ROOT/source" "$TEST_ROOT/remote"
export PATH="$TEST_ROOT/bin:${BASH%/*}:$PATH"
export SSL_CERT_FILE="$TEST_ROOT/ca.pem"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TEST_ROOT/ca.key" -out "$SSL_CERT_FILE" -days 2 -subj /CN=OfflineCA \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign > /dev/null 2>&1
openssl req -new -newkey rsa:4096 -nodes -keyout "$TEST_ROOT/source/private.key" -out "$TEST_ROOT/request" \
    -subj /CN=phillipmcmahon.com > /dev/null 2>&1
printf 'subjectAltName=DNS:phillipmcmahon.com,DNS:*.phillipmcmahon.com\nextendedKeyUsage=serverAuth\n' > "$TEST_ROOT/ext"
openssl x509 -req -in "$TEST_ROOT/request" -CA "$SSL_CERT_FILE" -CAkey "$TEST_ROOT/ca.key" -set_serial 1 -days 1 \
    -extfile "$TEST_ROOT/ext" -out "$TEST_ROOT/cert.pem" > /dev/null 2>&1
cat "$TEST_ROOT/cert.pem" "$SSL_CERT_FILE" > "$TEST_ROOT/source/fullchain.pem"
printf 'old certificate\n' > "$TEST_ROOT/remote/fullchain.pem"
printf 'old key\n' > "$TEST_ROOT/remote/privkey.pem"
cat > "$TEST_ROOT/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ssh\n' >> "$TEST_ROOT/connections"
bash -c "${!#}"
EOF
cat > "$TEST_ROOT/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'scp\n' >> "$TEST_ROOT/connections"
[[ ${FAIL_UPLOAD:-0} == 0 ]] || exit 1
args=("$@")
source=${args[${#args[@]}-2]}
target=${args[${#args[@]}-1]}
cp "$source" "${target#*:}"
EOF
cat > "$TEST_ROOT/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case $1 in
    inspect) if [[ ${2:-} == --format ]]; then printf 'true\n'; fi ;;
    restart)
        printf 'restart\n' >> "$TEST_ROOT/restarts"
        if [[ -f $TEST_ROOT/fail-restart ]]; then rm "$TEST_ROOT/fail-restart"; exit 1; fi
        ;;
    *) exit 99 ;;
esac
EOF
chmod 700 "$TEST_ROOT/bin/"*
cat > "$TEST_ROOT/deploy.conf" <<EOF
SOURCE_DIR='$TEST_ROOT/source'
DEST_DIR='$TEST_ROOT/remote'
EOF
base=("$BASH" "$ROOT/cert-deploy-npm.sh" --config "$TEST_ROOT/deploy.conf")
run_ok() {
    if output=$("${base[@]}" "$@" 2>&1); then return 0; fi
    printf '%s\n' "$output" >&2
    return 1
}
run_fail() {
    if output=$("${base[@]}" "$@" 2>&1); then printf 'Unexpected success\n%s\n' "$output" >&2; return 1; fi
}
run_ok
[[ ! -e $TEST_ROOT/connections ]]
printf 'PASS dry-run validates locally without SSH\n'
export FAIL_UPLOAD=1
run_fail --apply
unset FAIL_UPLOAD
grep -Fxq 'old certificate' "$TEST_ROOT/remote/fullchain.pem"
[[ ! -e $TEST_ROOT/restarts && ! -e $TEST_ROOT/source/.cert-deploy-npm.lock ]]
printf 'PASS failed upload preserves existing files and releases local lock\n'
run_ok --apply
cmp "$TEST_ROOT/source/fullchain.pem" "$TEST_ROOT/remote/fullchain.pem"
cmp "$TEST_ROOT/source/private.key" "$TEST_ROOT/remote/privkey.pem"
[[ $(wc -l < "$TEST_ROOT/restarts") -eq 1 ]]
printf 'PASS changed pair installed and container restarted\n'
run_ok --apply
[[ $(wc -l < "$TEST_ROOT/restarts") -eq 1 ]]
printf 'PASS unchanged pair skips restart\n'
cp "$TEST_ROOT/remote/fullchain.pem" "$TEST_ROOT/expected.pem"
printf '\n' >> "$TEST_ROOT/source/fullchain.pem"
touch "$TEST_ROOT/fail-restart"
run_fail --apply
cmp "$TEST_ROOT/remote/fullchain.pem" "$TEST_ROOT/expected.pem"
[[ $(wc -l < "$TEST_ROOT/restarts") -eq 3 && ! -e $TEST_ROOT/remote/.cert-deploy-npm.lock ]]
printf 'PASS failed restart restores previous pair and retries restart\n'
cp "$TEST_ROOT/source/private.key" "$TEST_ROOT/key.saved"
cp "$TEST_ROOT/ca.key" "$TEST_ROOT/source/private.key"
before=$(wc -l < "$TEST_ROOT/connections")
run_fail --apply
[[ $(wc -l < "$TEST_ROOT/connections") -eq $before ]]
cp "$TEST_ROOT/key.saved" "$TEST_ROOT/source/private.key"
printf 'PASS invalid key rejected before SSH\n'
# Valid RSA key but wrong hostname must also be rejected before SSH.
printf "DOMAIN='unrelated.example.net'\n" >> "$TEST_ROOT/deploy.conf"
run_fail --apply
[[ $(wc -l < "$TEST_ROOT/connections") -eq $before ]]
printf 'PASS wrong certificate hostname rejected before SSH\n'
printf 'All offline deployment tests passed.\n'
