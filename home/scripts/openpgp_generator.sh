#!/usr/bin/env bash
#
# openpgp_generator.sh — OPENPGPKEY DNS record generator (RFC 7929)
# Version: 2.0.0
#
# Generates the DNS record that lets mail clients discover your public
# GPG key from your email address (https://www.rfc-editor.org/rfc/rfc7929.txt).
#
# Usage: openpgp_generator.sh [-y|--yes] <email> <GPG key ID>
#   -y, --yes   skip the confirmation prompt (for scripting)
#
# NOT IMPLEMENTED (from RFC 7929 §5):
#
#   2.  The local-part is first canonicalized using the following rules.
#       If the local-part is unquoted, any comments and/or folding
#       whitespace (CFWS) around dots (".") is removed.  Any enclosing
#       double quotes are removed.  Any literal quoting is removed.
#
#   3.  If the local-part contains any non-ASCII characters, it SHOULD be
#       normalized using the Unicode Normalization Form C from
#       [Unicode90].  Recommended normalization rules can be found in
#       Section 10.1 of [RFC6530].
#
# Based on work by Arija A. (Ari Archer) <ari@ari.lt>, CC0 1.0 Universal
# (https://creativecommons.org/publicdomain/zero/1.0/). Substantially
# rewritten: input validation, up-front dependency/key checks, a single
# clear [Y/n] confirmation showing the full parsed email, and clean
# (pipe-safe) record output.
#
set -Eeuo pipefail

usage() {
    cat <<EOF
Generates an OPENPGPKEY DNS record (RFC 7929) from an email address and a
public GPG key ID.

Usage: $0 [-y|--yes] <email> <GPG key ID>

Options:
  -y, --yes    skip the confirmation prompt
  -h, --help   show this help

Example:
  $0 alice@example.com 0x0123456789ABCDEF
EOF
}

err() { printf 'Error: %s\n' "$*" >&2; }

main() {
    local assume_yes=0 arg
    local positional=()
    for arg in "$@"; do
        case "$arg" in
            -y|--yes)  assume_yes=1 ;;
            -h|--help) usage; return 0 ;;
            -*)        err "unknown option: $arg"; usage >&2; return 1 ;;
            *)         positional+=("$arg") ;;
        esac
    done

    if [[ ${#positional[@]} -ne 2 ]]; then
        usage >&2
        return 1
    fi

    local email="${positional[0]}" keyid="${positional[1]}"

    # ---- validate inputs up front, before asking the user anything ----
    for cmd in gpg sha256sum base64; do
        command -v "$cmd" >/dev/null 2>&1 || { err "'$cmd' is not installed."; return 1; }
    done

    # Exactly one '@', with non-empty localpart and domain
    if [[ "$email" != *@* || "$email" == *@*@* || "$email" == @* || "$email" == *@ ]]; then
        err "'$email' does not look like a valid email address (expected local@domain)."
        return 1
    fi

    # RFC 7929 hashes the lowercased localpart; domain is case-insensitive in DNS
    local localpart domain
    localpart="$(printf '%s' "${email%%@*}" | tr '[:upper:]' '[:lower:]')"
    domain="$(printf '%s' "${email##*@}" | tr '[:upper:]' '[:lower:]')"

    # Fail early if the key is not in the keyring (with a useful message),
    # rather than letting the gpg export fail mid-output.
    if ! gpg --list-keys -- "$keyid" >/dev/null 2>&1; then
        err "GPG key '$keyid' not found in the public keyring."
        err "List available keys with: gpg --list-keys"
        return 1
    fi

    # ---- one clear confirmation, showing everything that will be used ----
    if [[ "$assume_yes" -eq 0 ]]; then
        printf 'This record will be generated from:\n' >&2
        printf '  Email localpart : %s  (hashed into the record name)\n' "$localpart" >&2
        printf '  Domain          : %s\n' "$domain" >&2
        printf '  GPG key         : %s\n' "$keyid" >&2
        gpg --list-keys --keyid-format 0xlong -- "$keyid" 2>/dev/null \
            | sed -n 's/^uid.*] /                    uid: /p' >&2
        local reply
        read -rp 'Proceed? [Y/n] ' reply
        case "$reply" in
            ''|y|Y|yes|Yes|YES) ;;
            *) echo 'Aborted.' >&2; return 1 ;;
        esac
    fi

    # ---- build the record ----
    # Owner name: SHA-256 of the localpart, truncated to 28 octets (56 hex chars)
    local localpart_digest gpg_public_key_b64
    localpart_digest="$(printf '%s' "$localpart" | sha256sum | cut -d' ' -f1 | cut -c1-56)"

    # Record value: the minimal binary public key export, base64-encoded
    gpg_public_key_b64="$(gpg --export --export-options export-minimal,no-export-attributes -- "$keyid" | base64 -w 0)"
    if [[ -z "$gpg_public_key_b64" ]]; then
        err "gpg exported an empty key for '$keyid'."
        return 1
    fi

    # The record itself is the only thing written to stdout, so the output
    # can be piped or redirected straight into a zone file.
    echo >&2
    echo 'Add this record to your DNS zone:' >&2
    printf '%s._openpgpkey.%s. IN OPENPGPKEY %s\n' "$localpart_digest" "$domain" "$gpg_public_key_b64"
    echo >&2
    echo "Verify after publishing with: dig ${localpart_digest}._openpgpkey.${domain}. TYPE61 +short" >&2
}

main "$@"

