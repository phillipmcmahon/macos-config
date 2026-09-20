#!/usr/bin/env bash
#
# Script: security-yubikey-provision.sh
# Purpose: Provision OpenPGP and OTP slot 2 on confirmed YubiKeys.
# Version: 1.0.0
# Requires: Bash 5+, macOS, gpg, ykman and adjacent lib/.
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
Usage: ${0##*/} [--yes] [--verbose]

Reset and provision OpenPGP and overwrite OTP slot 2 on confirmed YubiKeys.
Keep exactly one device connected throughout each operation. Private subkeys
must already be available in the configured private GnuPG workspace.

Options:
  --yes          Skip per-device confirmation, retaining the abort countdown
  --verbose      Show redacted diagnostic output
  --version      Show version
  -h, --help     Show help

Settings: ~/.config/yubikey-provision/config. PINs and passwords are prompted.
No dry-run: provisioning must be tested on a spare physical device.
EOF
}

# Helpers
ykman() {
    if [[ ${1:-} == list || -z $SERIAL ]]; then
        command ykman "$@"
    else command ykman --device "$SERIAL" "$@"; fi
}

gpg() {
    if [[ $BUSY == 1 ]]; then
        local connected
        connected=$(command ykman list --serials) || return 1
        [[ $connected == "$SERIAL" ]] || {
            err 'Device selection changed. Aborting the card operation.'
            return 1
        }
    fi
    command gpg "$@"
}

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ ${BUSY:-0} == 1 ]]; then
        err "Provisioning stopped at ${FAIL_STEP:-unknown}. Inspect the confirmed card before retrying."
        if [[ -n ${SERIAL:-} && -n ${FIRMWARE:-} ]]; then
            record_result "$SERIAL" "$FIRMWARE" "FAILED-${FAIL_STEP:-unknown}-interrupted" || rc=1
        fi
    fi
    rm -f "$YK_ERR" || rc=1
    lock_release || rc=1
    [[ -n "${STTY_SAVED:-}" ]] && stty "$STTY_SAVED" 2> /dev/null || true
    unset -v NEW_PIN NEW_PIN2 NEW_ADMIN NEW_ADMIN2 PASSPHRASE STATIC_PW STATIC_PW2
    exit "$rc"
}

on_interrupt() {
    echo
    if [[ "$BUSY" -eq 1 ]]; then
        err "Interrupted mid-configuration at ${FAIL_STEP:-unknown}! This key may be in a bad state."
        if [[ -n "${SERIAL:-}" && -n "${FIRMWARE:-}" ]]; then
            record_result "$SERIAL" "$FIRMWARE" "FAILED-${FAIL_STEP:-unknown}-interrupted"
        fi
        err "Configured ${COUNT} YubiKey(s) before interruption. Log: ${CSV_LOG}"
        exit 1
    fi
    ok "Done. Configured ${COUNT} YubiKey(s). Log: ${CSV_LOG}"
    if ((FAILED_COUNT > 0)); then exit 1; fi
    exit 0
}

redact() {
    local s="$1"
    s=${s//"$NEW_ADMIN"/[REDACTED-ADMIN-PIN]}
    s=${s//"$NEW_PIN"/[REDACTED-USER-PIN]}
    s=${s//"$PASSPHRASE"/[REDACTED-PASSPHRASE]}
    s=${s//"$STATIC_PW"/[REDACTED-STATIC-PW]}
    echo "$s"
}

show_if_verbose() {
    [[ "$VERBOSE" -eq 1 && -n "$1" ]] && redact "$1"
    return 0
}

release_card() {
    gpgconf --kill scdaemon 2> /dev/null || true
    gpgconf --kill gpg-agent 2> /dev/null || true
    local i
    for i in 1 2 3; do
        sleep 1
        if ykman list 2> /dev/null | grep -qi "yubikey"; then
            return 0
        fi
    done
    return 0 # explicit success even if no key reappeared; callers check presence themselves
}

gpg_card_edit_quiet() {
    LAST_OUT=$(gpg --no-tty --status-fd=1 --command-fd=0 --pinentry-mode=loopback --card-edit 2>&1) || true
    show_if_verbose "$LAST_OUT"
}

card_op_succeeded() {
    grep -q "SC_OP_SUCCESS" <<< "$LAST_OUT" && ! grep -q "SC_OP_FAILURE" <<< "$LAST_OUT"
}

gpg_card_available() {
    local i
    for i in 1 2 3; do
        if gpg --card-status > /dev/null 2> "$YK_ERR"; then
            return 0
        fi
        sleep 2
    done
    cat "$YK_ERR" >&2
    err "gpg cannot access the card (smart-card service problem?)."
    err "Try: sudo pkill -f pcscd  — or reboot if the service stays wedged."
    return 1
}

get_serial() {
    ykman info 2> /dev/null | awk '/Serial number:/{print $NF}'
}

get_firmware() {
    ykman info 2> /dev/null | awk -F': *' '/Firmware version:/{print $2}'
}

record_result() {
    local serial="$1" firmware="$2" status="$3"
    local date_str tmp
    date_str=$(date '+%Y-%m-%d %H:%M:%S')
    tmp=$(mktemp "$WORKSPACE/.yubikey-csv.XXXXXXXXXX")

    if [[ ! -f "$CSV_LOG" ]]; then
        echo "serial,firmware_version,last_configured,status" > "$CSV_LOG"
    fi

    {
        head -n1 "$CSV_LOG"
        tail -n +2 "$CSV_LOG" | awk -F',' -v s="$serial" '$1 != s'
        echo "${serial},${firmware},${date_str},${status}"
    } > "$tmp" && mv "$tmp" "$CSV_LOG"
}

wait_for_new_key() {
    local prev="$1" cur="" removed=0 nkeys=0 multi_warned=0
    while true; do
        nkeys=$(ykman list 2> /dev/null | grep -c . || true)
        if [[ "$nkeys" -gt 1 ]]; then
            if [[ $multi_warned -eq 0 ]]; then
                err "Multiple YubiKeys detected (${nkeys}). Remove all but one to continue..."
                multi_warned=1
            fi
            sleep 1  # NB: does not set removed=1 — the previous key must still
            continue # be physically removed before it can be re-detected
        fi
        multi_warned=0
        cur=$(get_serial)
        if [[ -z "$cur" ]]; then
            removed=1 # no key present — previous one was removed
        elif [[ "$cur" != "$prev" || $removed -eq 1 ]]; then
            echo "$cur"
            return 0
        fi
        sleep 1
    done
}

configure_card() {
    LAST_OUT=""
    [[ $(command ykman list --serials) == "$SERIAL" ]] || {
        err "Confirmed device is no longer the only connected device."
        return 1
    }
    FAIL_STEP=""
    BUSY=1

    FAIL_STEP="step1"
    step "  [1/8] Resetting OpenPGP applet..."
    release_card
    if [[ "$VERBOSE" -eq 1 ]]; then
        ykman openpgp reset --force || {
            err "OpenPGP applet reset failed (ykman exit $?). Aborting this key."
            return 1
        }
    else
        ykman openpgp reset --force > /dev/null 2> "$YK_ERR" || {
            cat "$YK_ERR" >&2
            err "OpenPGP applet reset failed. Aborting this key."
            return 1
        }
    fi
    release_card
    gpg_card_available || return 1

    FAIL_STEP="step2"
    step "  [2/8] Enabling KDF..."
    gpg_card_edit_quiet << EOF
admin
kdf-setup
${DEFAULT_ADMIN}
quit
EOF
    gpg --card-status 2> /dev/null | grep -q "KDF setting.*on" || {
        redact "$LAST_OUT" >&2
        err "KDF was not enabled — card communication likely failed. Aborting this key."
        return 1
    }

    FAIL_STEP="step3"
    step "  [3/8] Changing user PIN..."
    gpg_card_edit_quiet << EOF
admin
passwd
1
${DEFAULT_PIN}
${NEW_PIN}
${NEW_PIN}
q
quit
EOF
    card_op_succeeded || {
        redact "$LAST_OUT" >&2
        err "User PIN change failed. Aborting this key."
        return 1
    }

    FAIL_STEP="step4"
    step "  [4/8] Changing admin PIN..."
    gpg_card_edit_quiet << EOF
admin
passwd
3
${DEFAULT_ADMIN}
${NEW_ADMIN}
${NEW_ADMIN}
q
quit
EOF
    card_op_succeeded || {
        redact "$LAST_OUT" >&2
        err "Admin PIN change failed. Aborting this key."
        return 1
    }

    FAIL_STEP="step5"
    step "  [5/8] Setting cardholder attributes + forced signature PIN..."
    gpg_card_edit_quiet << EOF
admin
name
${NAME_SURNAME}
${NAME_GIVEN}
${NEW_ADMIN}
lang
${LANG_PREF}
salutation
${SALUTATION}
url
${URL}
login
${LOGIN}
quit
EOF
    release_card
    if ! printf '%s\n' "$NEW_ADMIN" | ykman openpgp access set-signature-policy always > /dev/null 2> "$YK_ERR"; then
        redact "$(cat "$YK_ERR")" >&2
        err "Failed to set signature PIN policy to 'always'. Aborting this key."
        return 1
    fi
    release_card
    gpg_card_available || return 1
    local cs sal_re="" bad=""
    cs=$(gpg --card-status 2> /dev/null) || {
        err "gpg --card-status failed after setting cardholder attributes. Aborting this key."
        return 1
    }
    case "$SALUTATION" in
        M | m) sal_re='^(Salutation|Sex)[ .]*: *(Mr\.|male)$' ;;
        F | f) sal_re='^(Salutation|Sex)[ .]*: *(Mrs\.|female)$' ;;
        *) sal_re="" ;; # empty/unset salutation — nothing to verify
    esac
    echo "$cs" | grep -q "^Name of cardholder: ${NAME_GIVEN} ${NAME_SURNAME}" || bad="${bad} name"
    echo "$cs" | grep -qE "^Language prefs[ .]*: *${LANG_PREF}$" || bad="${bad} lang"
    if [[ -n "$sal_re" ]]; then
        echo "$cs" | grep -qE "$sal_re" || bad="${bad} salutation"
    fi
    echo "$cs" | grep "^URL of public key" | grep -qF "$URL" || bad="${bad} url"
    echo "$cs" | grep "^Login data" | grep -qF "$LOGIN" || bad="${bad} login"
    echo "$cs" | grep -q "^Signature PIN ....: forced" || bad="${bad} forcesig"
    if [[ -n "$bad" ]]; then
        redact "$LAST_OUT" >&2
        err "Cardholder attributes not set correctly (failed:${bad}). Aborting this key."
        return 1
    fi

    FAIL_STEP="step6"
    step "  [6/8] Transferring subkeys to card (local copies kept)..."
    local kt_spec kt_slot kt_fpr kt_out kt_rc
    for kt_spec in "1:${EXPECTED_SIG_FPR}" "2:${EXPECTED_ENC_FPR}" "3:${EXPECTED_AUTH_FPR}"; do
        kt_slot="${kt_spec%%:*}"
        kt_fpr="${kt_spec#*:}"
        gpgconf --kill gpg-agent 2> /dev/null || true
        gpgconf --kill scdaemon 2> /dev/null || true
        sleep 1
        gpg_card_available || return 1

        kt_rc=0
        kt_out=$(
            gpg --no-tty --status-fd=1 --command-fd=0 --pinentry-mode=loopback --edit-key "$PRIMARY_FPR" 2>&1 << EOF
key ${kt_fpr}
keytocard
${kt_slot}
${PASSPHRASE}
${NEW_ADMIN}
${NEW_ADMIN}
quit
n
EOF
        ) || kt_rc=$?
        show_if_verbose "$kt_out"

        if [[ "$kt_rc" -ne 0 ]] || echo "$kt_out" | grep -qE "KEYTOCARD failed|SC_OP_FAILURE"; then
            redact "$kt_out" >&2
            err "keytocard failed for slot ${kt_slot} (${kt_fpr}, gpg exit ${kt_rc}) — check passphrase/admin PIN. Aborting this key."
            return 1
        fi
        ok "        slot ${kt_slot}/3 transferred (${kt_fpr})"
    done

    FAIL_STEP="step7"
    step "  [7/8] Verifying subkeys on card (slots + fingerprints)..."
    release_card
    local card_status card_fpr slot_spec slot_label slot_expected
    card_status=$(gpg --card-status 2> /dev/null) || {
        err "gpg --card-status failed while verifying card slots. Aborting this key."
        return 1
    }
    for slot_spec in \
        "Signature key:${EXPECTED_SIG_FPR}" \
        "Encryption key:${EXPECTED_ENC_FPR}" \
        "Authentication key:${EXPECTED_AUTH_FPR}"; do
        slot_label="${slot_spec%%:*}"
        slot_expected="${slot_spec#*:}"
        if echo "$card_status" | grep -q "^${slot_label}[ .]*: *\[none\]"; then
            err "keytocard failed: ${slot_label} slot is empty. Aborting this key."
            return 1
        fi
        card_fpr=$(echo "$card_status" | grep "^${slot_label}" | sed 's/^[^:]*: *//' | tr -d ' ')
        if [[ -z "$card_fpr" ]]; then
            err "${slot_label} on card is empty (could not parse fingerprint). Aborting this key."
            return 1
        fi
        if [[ "$(printf '%s' "$card_fpr" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$slot_expected" | tr '[:upper:]' '[:lower:]')" ]]; then
            err "${slot_label} fingerprint on card (${card_fpr}) does not match expected (${slot_expected}). Aborting this key."
            return 1
        fi
    done
    ok "        all three card fingerprints match their expected slots"

    FAIL_STEP="step8"
    step "  [8/8] Touch policies + OTP static password..."
    release_card
    local att_info_supported=1
    ykman openpgp keys info att > /dev/null 2>&1 || att_info_supported=0

    local slot cached_slots="" unverified_slots="" fixed_slots=""
    for slot in sig dec aut att; do
        if printf '%s\n' "$NEW_ADMIN" | ykman openpgp keys set-touch "$slot" cached --force > /dev/null 2> "$YK_ERR"; then
            if [[ "$slot" == "att" && "$att_info_supported" -eq 0 ]]; then
                warn "        touch policy for att set (installed ykman cannot verify via keys info — verify manually)"
                unverified_slots="${unverified_slots} ${slot}"
            elif ! ykman openpgp keys info "$slot" 2> /dev/null | grep -qi "Touch policy: *Cached"; then
                err "Touch policy for $slot did not verify as Cached."
                return 1
            else
                cached_slots="${cached_slots} ${slot}"
            fi
        elif grep -qi 'fixed' "$YK_ERR"; then
            warn "        touch policy for $slot is FIXED (permanent) — skipping."
            fixed_slots="${fixed_slots} ${slot}"
        else
            cat "$YK_ERR" >&2
            err "FAILED setting touch policy for $slot"
            err "Check admin PIN retries with: ykman openpgp info"
            return 1
        fi
    done
    [[ -n "$cached_slots" ]] && ok "        touch policy 'cached' set + verified on:${cached_slots}"
    [[ -n "$unverified_slots" ]] && warn "        touch policy 'cached' set but NOT verified on:${unverified_slots}"
    [[ -n "$fixed_slots" ]] && warn "        touch policy FIXED (permanent, not changed):${fixed_slots}"

    release_card
    local otp_rc=0
    if [[ "$VERBOSE" -eq 1 ]]; then
        printf '%s\n' "$STATIC_PW" | ykman otp static --keyboard-layout "$KEYBOARD_LAYOUT" --no-enter --force 2 || otp_rc=$?
    else
        printf '%s\n' "$STATIC_PW" | ykman otp static --keyboard-layout "$KEYBOARD_LAYOUT" --no-enter --force 2 > /dev/null 2> "$YK_ERR" || otp_rc=$?
        [[ "$otp_rc" -eq 0 ]] || redact "$(cat "$YK_ERR")" >&2
    fi
    if [[ "$otp_rc" -ne 0 ]]; then
        err "FAILED programming OTP slot 2 static password (ykman exit ${otp_rc}). Aborting this key."
        return 1
    fi
    if ! ykman otp info 2> /dev/null | grep -qE "^Slot 2: *programmed"; then
        err "OTP slot 2 does not report as programmed after ykman otp static. Aborting this key."
        return 1
    fi
    ok "        OTP slot 2 static password set + verified programmed"

    FAIL_STEP=""
    BUSY=0
    release_card
    card_status=$(gpg --card-status 2> /dev/null) || card_status=""
    echo
    ok "  Summary:"
    echo "$card_status" | grep -E "Serial number|KDF setting|Signature PIN|UIF setting|Key attributes|^Signature key|^Encryption key|^Authentication key" | sed 's/^/    /'
    [[ "$VERBOSE" -eq 1 ]] && {
        echo
        echo "$card_status"
    }
    return 0
}

subkey_fpr_for_cap() {
    gpg --list-secret-keys --with-colons "$PRIMARY_FPR" | awk -F: -v cap="$1" '
    $1 == "ssb" { keep = (index($12, cap) > 0 && index($12, "D") == 0 && $2 !~ /^[reid]$/ && $15 == "+"); next }
    $1 == "fpr" && keep { print $10; keep = 0 }
    { keep = 0 }'
}

# Operations
main() {

    NAME_SURNAME="McMahon"                                     # surname
    NAME_GIVEN="Phillip"                                       # given name
    LANG_PREF="en"                                             # lang preference
    SALUTATION="M"                                             # M, F, or empty
    URL_BASE="https://keys.openpgp.org/vks/v1/by-fingerprint/" # URL = URL_BASE + PRIMARY_FPR
    LOGIN="phillip.mcmahon+04bfca0123c1a0d3@gmail.com"
    PRIMARY_FPR="EA0483D4C864AA7C10994BE6A11E70ADFDA60CF9" # full 40-hex fingerprint of the primary key
    WORKSPACE="/Users/phillipmcmahon/tmp/gnupg-workspace"
    KEYBOARD_LAYOUT="modhex" # layout for the static password scancodes: modhex, US or UK etc.
    CSV_LOG="${WORKSPACE}/yubikey-config-log.csv"

    DEFAULT_PIN="123456"
    DEFAULT_ADMIN="12345678"

    ASSUME_YES=0 VERBOSE=0
    for arg in "$@"; do
        case $arg in
            --yes | -y) ASSUME_YES=1 ;;
            --verbose | -v) VERBOSE=1 ;;
            --version)
                printf '%s\n' "$SCRIPT_VERSION"
                exit 0
                ;;
            --help | -h)
                usage
                exit 0
                ;;
            *) die "Unknown option: $arg" ;;
        esac
    done
    load_config "$HOME/.config/yubikey-provision/config" 'NAME_SURNAME NAME_GIVEN LANG_PREF SALUTATION URL_BASE LOGIN PRIMARY_FPR WORKSPACE KEYBOARD_LAYOUT' || die 'Invalid YubiKey configuration.'
    CSV_LOG="$WORKSPACE/yubikey-config-log.csv"
    case ${KEYBOARD_LAYOUT^^} in MODHEX | US | UK | DE | FR | IT | BEPO | NORMAN) ;; *) die "Unsupported keyboard layout." ;; esac
    KEYBOARD_LAYOUT=${KEYBOARD_LAYOUT^^}
    export LC_ALL=C
    umask 077
    SERIAL='' BUSY=0
    for cmd in gpg ykman gpgconf; do
        type -P "$cmd" > /dev/null || {
            err "Missing dependency: $cmd (brew install gnupg ykman)"
            exit 1
        }
    done

    [[ "$PRIMARY_FPR" =~ ^[0-9A-Fa-f]{40}$ ]] || {
        err "PRIMARY_FPR must be 40 hex characters"
        exit 1
    }
    KEYID="${PRIMARY_FPR:24}"       # long key ID = last 16 hex chars of the fingerprint (display only)
    URL="${URL_BASE}${PRIMARY_FPR}" # cardholder URL always points at the same key

    export GNUPGHOME="$WORKSPACE"
    reject_symlinks "$WORKSPACE" || exit 1
    workspace_mode=$(stat -f '%u %Lp' "$WORKSPACE")
    IFS=" " read -r workspace_owner workspace_permissions <<< "$workspace_mode"
    [[ $workspace_owner == "$EUID" ]] && (((8#$workspace_permissions & 8#077) == 0)) || die "GnuPG workspace must be owned by you and mode 700."
    [[ -t 0 ]] || die "YubiKey provisioning requires a terminal."

    [[ -d "$WORKSPACE" ]] || {
        err "Workspace $WORKSPACE not found"
        exit 1
    }
    gpg --list-secret-keys "$PRIMARY_FPR" > /dev/null 2>&1 || {
        err "Secret key $KEYID (${PRIMARY_FPR}) not found in workspace"
        exit 1
    }

    YK_ERR=$(mktemp "${TMPDIR:-/tmp}/yubikey-err.XXXXXXXXXX")
    COUNT=0 FAILED_COUNT=0
    FAIL_STEP="" # set before each failure return; used to tag the CSV row
    BUSY=0       # 1 while inside configure_card; used by the interrupt handler
    trap cleanup EXIT
    lock_acquire "$HOME/.local/state/yubikey-provision/run.lock" || exit 1
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    trap on_interrupt INT

    STTY_SAVED=$(stty -g 2> /dev/null || true)
    stty -echoctl 2> /dev/null || true

    read -rsp "New user PIN (6-127 chars): " NEW_PIN
    echo
    read -rsp "Confirm new user PIN: " NEW_PIN2
    echo
    [[ "$NEW_PIN" == "$NEW_PIN2" ]] || {
        err "User PINs do not match"
        exit 1
    }
    [[ ${#NEW_PIN} -ge 6 && ${#NEW_PIN} -le 127 ]] || {
        err "User PIN must be 6-127 chars"
        exit 1
    }

    read -rsp "New admin PIN (8-127 chars): " NEW_ADMIN
    echo
    read -rsp "Confirm new admin PIN: " NEW_ADMIN2
    echo
    [[ "$NEW_ADMIN" == "$NEW_ADMIN2" ]] || {
        err "Admin PINs do not match"
        exit 1
    }
    [[ ${#NEW_ADMIN} -ge 8 && ${#NEW_ADMIN} -le 127 ]] || {
        err "Admin PIN must be 8-127 chars"
        exit 1
    }

    read -rsp "GPG key passphrase for ${KEYID}: " PASSPHRASE
    echo

    read -rsp "Static password for OTP slot 2 (long press, max 38 chars): " STATIC_PW
    echo
    read -rsp "Confirm static password: " STATIC_PW2
    echo
    [[ "$STATIC_PW" == "$STATIC_PW2" ]] || {
        err "Static passwords do not match"
        exit 1
    }
    [[ -n "$STATIC_PW" ]] || {
        err "Static password must not be empty"
        exit 1
    }
    [[ ${#STATIC_PW} -le 38 ]] || {
        err "Static password exceeds 38 characters"
        exit 1
    }
    if [[ "$(printf '%s' "$KEYBOARD_LAYOUT" | tr '[:upper:]' '[:lower:]')" == "modhex" ]]; then
        [[ "$STATIC_PW" =~ ^[bcdefghijklnrtuvBCDEFGHIJKLNRTUV]+$ ]] || {
            err "Static password is not valid ModHex: only the characters b c d e f g h i j k l n r t u v (any case) are allowed with KEYBOARD_LAYOUT=modhex"
            exit 1
        }
    fi

    step "==> Validating GPG key passphrase..."
    if ! echo test | gpg --batch --pinentry-mode=loopback --passphrase-fd 3 \
        --local-user "$PRIMARY_FPR" --sign --output /dev/null 3< <(printf '%s' "$PASSPHRASE") 2> /dev/null; then
        err "Passphrase for $KEYID is incorrect. Aborting."
        exit 1
    fi
    gpgconf --kill gpg-agent 2> /dev/null || true
    ok "Passphrase verified."

    EXPECTED_SIG_FPR=$(subkey_fpr_for_cap s)
    EXPECTED_ENC_FPR=$(subkey_fpr_for_cap e)
    EXPECTED_AUTH_FPR=$(subkey_fpr_for_cap a)
    for pair in "sign:${EXPECTED_SIG_FPR}" "encrypt:${EXPECTED_ENC_FPR}" "auth:${EXPECTED_AUTH_FPR}"; do
        cnt=$(printf '%s\n' "${pair#*:}" | grep -c . || true)
        [[ "$cnt" -eq 1 ]] || {
            err "Expected exactly one usable ${pair%%:*} subkey with local secret material on $KEYID, found ${cnt}. Aborting."
            err "Check with: gpg --list-secret-keys --with-colons $PRIMARY_FPR  (ssb field 15 must be '+', not '#' or '>')"
            exit 1
        }
    done
    unset pair cnt
    step "==> Subkey → card slot mapping for $KEYID (derived from secret-key capabilities):"
    echo "    slot 1 (sig): ${EXPECTED_SIG_FPR}"
    echo "    slot 2 (enc): ${EXPECTED_ENC_FPR}"
    echo "    slot 3 (aut): ${EXPECTED_AUTH_FPR}"

    LAST_SERIAL=""
    while true; do
        echo
        step "==> Waiting for a YubiKey to be inserted... (Ctrl-C to exit)"
        release_card
        SERIAL=""
        SERIAL=$(wait_for_new_key "$LAST_SERIAL")
        [[ -n "$SERIAL" ]] || SERIAL="unknown"
        ok "==> Detected YubiKey (serial: ${SERIAL})"

        FIRMWARE=$(get_firmware)
        [[ -n "$FIRMWARE" ]] || FIRMWARE="unknown"

        if [[ "$ASSUME_YES" -eq 1 ]]; then
            warn "WARNING: OpenPGP applet and OTP slot 2 on serial ${SERIAL} will be WIPED in 3 seconds. Ctrl-C or remove the key to abort..."
            for i in 3 2 1; do
                printf '  %s...\r' "$i"
                sleep 1
            done
            printf '        \r'
            if [[ "$(get_serial)" != "$SERIAL" ]]; then
                warn "Key removed during countdown — skipping."
                record_result "$SERIAL" "$FIRMWARE" "SKIPPED"
                LAST_SERIAL="$SERIAL"
                continue
            fi
        else
            read -rp "${C_YELLOW}WARNING: the OpenPGP applet AND OTP slot 2 on this key will be overwritten. Type 'yes' to proceed (anything else skips): ${C_RESET}" CONFIRM
            if [[ "$CONFIRM" != "yes" ]]; then
                warn "Skipping this key."
                record_result "$SERIAL" "$FIRMWARE" "SKIPPED"
                LAST_SERIAL="$SERIAL"
                continue
            fi
        fi

        if configure_card; then
            COUNT=$((COUNT + 1))
            record_result "$SERIAL" "$FIRMWARE" "SUCCESS"
            ok "==> YubiKey #${COUNT} (serial: ${SERIAL}) COMPLETE. Remove it — next key will be detected automatically."
        else
            BUSY=0
            ((FAILED_COUNT += 1))
            record_result "$SERIAL" "$FIRMWARE" "FAILED-${FAIL_STEP:-unknown}"
            err "==> Configuration FAILED at ${FAIL_STEP:-unknown} for this key (serial: ${SERIAL}) — remove it and investigate."
        fi
        LAST_SERIAL="$SERIAL"
    done

}

# Entry point
main "$@"
