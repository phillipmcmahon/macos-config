#!/usr/bin/env bash
# configure-yubikey.sh — reset + fully configure one or more YubiKeys (OpenPGP + OTP slot 2) on macOS
#
# v1.0.0 — 2026-09-01 (first versioned release)
#   • Split `gpgconf --kill scdaemon gpg-agent` into separate per-component
#     calls (gpgconf --kill accepts a single component; a second argument may
#     be silently ignored on older GnuPG, leaving gpg-agent holding the card)
#   • Same fix applied in the step-6 keytocard loop
#
# Usage: ./configure-yubikey.sh [-y|--yes] [-v|--verbose]
#   -y  skips the per-key wipe confirmation (3-second abort window instead)
#   -v  shows full gpg/ykman output (secrets redacted) instead of one-line summaries
# Keys are auto-detected on insertion; press Ctrl-C when finished.
# Results are logged (upsert per serial) to $CSV_LOG. Failures are tagged
# with the step that failed, e.g. FAILED-step3. Ctrl-C mid-configuration
# records the key as FAILED-<step>-interrupted and exits non-zero.
# Note: CSV upsert is not safe against concurrent runs (single-user tool).
# PINs and passwords are piped to ykman/gpg via stdin or an fd, never on the
# command line (ykman's prompts read a line from stdin when it is not a TTY).
# Compatible with macOS stock bash 3.2 (no arrays/mapfile used).
# Requires: brew install gnupg ykman
set -Eeuo pipefail

# ---- EDIT THESE ----
NAME_SURNAME="McMahon"    # surname
NAME_GIVEN="Phillip"      # given name
LANG_PREF="en"            # lang preference
SALUTATION="M"            # M, F, or empty
URL="https://keys.openpgp.org/vks/v1/by-fingerprint/EA0483D4C864AA7C10994BE6A11E70ADFDA60CF9"
LOGIN="phillip.mcmahon+04bfca0123c1a0d3@gmail.com"
KEYID="A11E70ADFDA60CF9"
WORKSPACE="/Users/phillipmcmahon/tmp/gnupg-workspace"
KEYBOARD_LAYOUT="modhex"          # layout for the static password scancodes: US or UK etc.
CSV_LOG="${WORKSPACE}/yubikey-config-log.csv"
# ----

# Factory default PINs after reset
DEFAULT_PIN="123456"
DEFAULT_ADMIN="12345678"

# ---- colours (disabled if stdout is not a terminal) ----
if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi
ok()    { echo "${C_GREEN}$*${C_RESET}"; }
err()   { echo "${C_RED}$*${C_RESET}" >&2; }
warn()  { echo "${C_YELLOW}$*${C_RESET}"; }
step()  { echo "${C_BLUE}$*${C_RESET}"; }

# ---- dependency check ----
for cmd in gpg ykman gpgconf; do
  command -v "$cmd" >/dev/null || { err "Missing dependency: $cmd (brew install gnupg ykman)"; exit 1; }
done

# ---- KEYID format check ----
[[ "$KEYID" =~ ^[0-9A-Fa-f]{16}$ ]] || { err "KEYID must be 16 hex characters"; exit 1; }

ASSUME_YES=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    *) err "Usage: $0 [-y|--yes] [-v|--verbose]"; exit 1 ;;
  esac
done

export GNUPGHOME="$WORKSPACE"

# ---- temp file + secrets cleanup ----
YK_ERR=$(mktemp)
COUNT=0
FAIL_STEP=""   # set before each failure return; used to tag the CSV row
BUSY=0         # 1 while inside configure_card; used by the interrupt handler
cleanup() {
  rm -f "$YK_ERR"
  [[ -n "${STTY_SAVED:-}" ]] && stty "$STTY_SAVED" 2>/dev/null || true
  unset -v NEW_PIN NEW_PIN2 NEW_ADMIN NEW_ADMIN2 PASSPHRASE STATIC_PW STATIC_PW2
}
trap cleanup EXIT
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
  exit 0
}
trap on_interrupt INT

# Suppress the terminal's ^C echo when Ctrl-C is pressed
STTY_SAVED=$(stty -g 2>/dev/null || true)
stty -echoctl 2>/dev/null || true

redact() {
  # Strip secrets from a string before it is ever displayed.
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
  # gpgconf --kill takes a single component per invocation; kill each one
  # separately so the second is never silently ignored.
  gpgconf --kill scdaemon 2>/dev/null || true
  gpgconf --kill gpg-agent 2>/dev/null || true
  local i
  for i in 1 2 3; do
    sleep 1
    if ykman list 2>/dev/null | grep -qi "yubikey"; then
      return 0
    fi
  done
  return 0   # explicit success even if no key reappeared; callers check presence themselves
}

gpg_card_edit_quiet() {
  # Runs a scripted --card-edit session, capturing ALL output. --no-tty stops
  # gpg writing straight to the terminal; --status-fd=1 makes it emit
  # machine-readable [GNUPG:] status lines (SC_OP_SUCCESS / SC_OP_FAILURE)
  # that callers verify against, since the human-readable "PIN changed."
  # text is TTY-only and disappears under --no-tty.
  LAST_OUT=$(gpg --no-tty --status-fd=1 --command-fd=0 --pinentry-mode=loopback --card-edit 2>&1) || true
  show_if_verbose "$LAST_OUT"
}

card_op_succeeded() {
  # True if the last card-edit session reported success and no failure.
  # NOTE: only valid for sessions performing a SINGLE card operation —
  # a multi-op session could contain one success and one failure and this
  # helper would still (correctly) fail, but the diagnosis would be murky.
  echo "$LAST_OUT" | grep -q "SC_OP_SUCCESS" && ! echo "$LAST_OUT" | grep -q "SC_OP_FAILURE"
}

gpg_card_available() {
  # Confirm gpg/scdaemon can actually talk to the card; retry a few times.
  local i
  for i in 1 2 3; do
    if gpg --card-status >/dev/null 2>"$YK_ERR"; then
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
  ykman info 2>/dev/null | awk '/Serial number:/{print $NF}'
}

get_firmware() {
  ykman info 2>/dev/null | awk -F': *' '/Firmware version:/{print $2}'
}

record_result() {
  # Usage: record_result <serial> <firmware> <status>
  # Upserts a row keyed on serial — no duplicates, latest run wins.
  local serial="$1" firmware="$2" status="$3"
  local date_str tmp
  date_str=$(date '+%Y-%m-%d %H:%M:%S')
  tmp=$(mktemp)

  if [[ ! -f "$CSV_LOG" ]]; then
    echo "serial,firmware_version,last_configured,status" > "$CSV_LOG"
  fi

  # Copy header + all rows except this serial, then append the new row
  { head -n1 "$CSV_LOG"
    tail -n +2 "$CSV_LOG" | awk -F',' -v s="$serial" '$1 != s'
    echo "${serial},${firmware},${date_str},${status}"
  } > "$tmp" && mv "$tmp" "$CSV_LOG"
}

wait_for_new_key() {
  # Usage: wait_for_new_key <previous_serial>
  # Blocks until a YubiKey with a different serial is present (or the same
  # key is removed and reinserted). Echoes the new serial.
  local prev="$1" cur="" removed=0
  while true; do
    cur=$(get_serial)
    if [[ -z "$cur" ]]; then
      removed=1              # no key present — previous one was removed
    elif [[ "$cur" != "$prev" || $removed -eq 1 ]]; then
      echo "$cur"
      return 0
    fi
    sleep 1
  done
}

configure_card() {
  LAST_OUT=""
  FAIL_STEP=""
  BUSY=1

  FAIL_STEP="step1"
  step "  [1/8] Resetting OpenPGP applet..."
  release_card
  if [[ "$VERBOSE" -eq 1 ]]; then
    ykman openpgp reset --force
  else
    ykman openpgp reset --force >/dev/null 2>&1
  fi
  release_card
  gpg_card_available || return 1

  FAIL_STEP="step2"
  step "  [2/8] Enabling KDF..."
  gpg_card_edit_quiet <<EOF
admin
kdf-setup
${DEFAULT_ADMIN}
quit
EOF
  gpg --card-status 2>/dev/null | grep -q "KDF setting.*on" || {
    redact "$LAST_OUT" >&2
    err "KDF was not enabled — card communication likely failed. Aborting this key."
    return 1
  }

  FAIL_STEP="step3"
  step "  [3/8] Changing user PIN..."
  gpg_card_edit_quiet <<EOF
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
  gpg_card_edit_quiet <<EOF
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
  gpg_card_edit_quiet <<EOF
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
forcesig
quit
EOF
  # Verify the attributes actually landed
  local cs
  cs=$(gpg --card-status 2>/dev/null)
  { echo "$cs" | grep -q "Name of cardholder: ${NAME_GIVEN} ${NAME_SURNAME}" &&
    echo "$cs" | grep -q "Signature PIN ....: forced"; } || {
    redact "$LAST_OUT" >&2
    err "Cardholder attributes / forcesig not set correctly. Aborting this key."
    return 1
  }

  FAIL_STEP="step6"
  step "  [6/8] Transferring subkeys to card (local copies kept)..."
  local n kt_out
  for n in 1 2 3; do
    # Kill agent so PIN/passphrase caching doesn't change the prompt count
    # (one component per gpgconf --kill call — see release_card)
    gpgconf --kill gpg-agent 2>/dev/null || true
    gpgconf --kill scdaemon 2>/dev/null || true
    sleep 1
    gpg_card_available || return 1

    kt_out=$(gpg --no-tty --status-fd=1 --command-fd=0 --pinentry-mode=loopback --edit-key "$KEYID" 2>&1 <<EOF
key ${n}
keytocard
${n}
${PASSPHRASE}
${NEW_ADMIN}
${NEW_ADMIN}
quit
n
EOF
) || true
    show_if_verbose "$kt_out"

    if echo "$kt_out" | grep -qE "KEYTOCARD failed|SC_OP_FAILURE"; then
      redact "$kt_out" >&2
      err "keytocard failed for subkey ${n} — check passphrase/admin PIN. Aborting this key."
      return 1
    fi
    ok "        subkey ${n}/3 transferred"
  done

  FAIL_STEP="step7"
  step "  [7/8] Verifying subkeys on card (slots + fingerprints)..."
  release_card
  local card_status label card_fpr
  card_status=$(gpg --card-status 2>/dev/null)
  for label in "Signature key" "Encryption key" "Authentication key"; do
    if echo "$card_status" | grep -q "^${label}[ .]*: *\[none\]"; then
      err "keytocard failed: ${label} slot is empty. Aborting this key."
      return 1
    fi
    # Extract the fingerprint from the card slot (strip label and spaces)
    card_fpr=$(echo "$card_status" | grep "^${label}" | sed 's/^[^:]*: *//' | tr -d ' ')
    if [[ -z "$card_fpr" ]] || ! echo "$EXPECTED_FPRS" | grep -qi "^${card_fpr}$"; then
      err "${label} on card (${card_fpr:-empty}) does not match any local subkey fingerprint. Aborting this key."
      return 1
    fi
  done
  ok "        all three card fingerprints match local subkeys"

  FAIL_STEP="step8"
  step "  [8/8] Touch policies + OTP static password..."
  release_card
  # ykman takes --admin-pin as a literal value only ("-" would be used as the
  # PIN itself). Omitting the option makes ykman prompt, and its prompt reads
  # a line from stdin when stdin is not a TTY — so pipe the PIN instead.
  local slot
  for slot in sig dec aut att; do
    if printf '%s\n' "$NEW_ADMIN" | ykman openpgp keys set-touch "$slot" cached --force >/dev/null 2>"$YK_ERR"; then
      :
    elif grep -q "FIXED" "$YK_ERR"; then
      warn "        touch policy for $slot is FIXED (permanent) — skipping."
      continue
    else
      cat "$YK_ERR" >&2
      err "FAILED setting touch policy for $slot"
      err "Check admin PIN retries with: ykman openpgp info"
      return 1
    fi
    # Verify
    if ! ykman openpgp keys info "$slot" 2>/dev/null | grep -qi "Touch policy: *Cached"; then
      err "Touch policy for $slot did not verify as Cached."
      return 1
    fi
  done
  ok "        touch policy 'cached' set + verified on sig/dec/aut/att"

  release_card
  # Same stdin technique: omit the PASSWORD argument so ykman prompts and
  # reads the piped line ("-" would be taken as the literal password).
  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '%s\n' "$STATIC_PW" | ykman otp static --keyboard-layout "$KEYBOARD_LAYOUT" --no-enter --force 2
  else
    printf '%s\n' "$STATIC_PW" | ykman otp static --keyboard-layout "$KEYBOARD_LAYOUT" --no-enter --force 2 >/dev/null 2>&1
  fi
  ok "        OTP slot 2 static password set"

  FAIL_STEP=""
  BUSY=0
  # Final one-screen summary instead of full card status dump
  release_card
  card_status=$(gpg --card-status 2>/dev/null)
  echo
  ok "  Summary:"
  echo "$card_status" | grep -E "Serial number|KDF setting|Signature PIN|UIF setting|Key attributes|^Signature key|^Encryption key|^Authentication key" | sed 's/^/    /'
  [[ "$VERBOSE" -eq 1 ]] && { echo; echo "$card_status"; }
  return 0
}

# ---- gather secrets once ----
read -rsp "New user PIN (6-127 chars): " NEW_PIN; echo
read -rsp "Confirm new user PIN: " NEW_PIN2; echo
[[ "$NEW_PIN" == "$NEW_PIN2" ]] || { err "User PINs do not match"; exit 1; }
[[ ${#NEW_PIN} -ge 6 && ${#NEW_PIN} -le 127 ]] || { err "User PIN must be 6-127 chars"; exit 1; }

read -rsp "New admin PIN (8-127 chars): " NEW_ADMIN; echo
read -rsp "Confirm new admin PIN: " NEW_ADMIN2; echo
[[ "$NEW_ADMIN" == "$NEW_ADMIN2" ]] || { err "Admin PINs do not match"; exit 1; }
[[ ${#NEW_ADMIN} -ge 8 && ${#NEW_ADMIN} -le 127 ]] || { err "Admin PIN must be 8-127 chars"; exit 1; }

read -rsp "GPG key passphrase for ${KEYID}: " PASSPHRASE; echo

read -rsp "Static password for OTP slot 2 (long press, max 38 chars): " STATIC_PW; echo
read -rsp "Confirm static password: " STATIC_PW2; echo
[[ "$STATIC_PW" == "$STATIC_PW2" ]] || { err "Static passwords do not match"; exit 1; }
[[ -n "$STATIC_PW" ]] || { err "Static password must not be empty"; exit 1; }
[[ ${#STATIC_PW} -le 38 ]] || { err "Static password exceeds 38 characters"; exit 1; }

[[ -d "$WORKSPACE" ]] || { err "Workspace $WORKSPACE not found"; exit 1; }
gpg --list-secret-keys "$KEYID" >/dev/null 2>&1 || { err "Secret key $KEYID not found in workspace"; exit 1; }

# ---- validate the passphrase up-front (before touching any card) ----
step "==> Validating GPG key passphrase..."
if ! echo test | gpg --batch --pinentry-mode=loopback --passphrase-fd 3 \
  --local-user "$KEYID" --sign --output /dev/null 3< <(printf '%s' "$PASSPHRASE") 2>/dev/null; then
  err "Passphrase for $KEYID is incorrect. Aborting."
  exit 1
fi
# Kill the agent so the validation sign doesn't leave the passphrase cached,
# which would change the expected prompt count in the keytocard sessions.
gpgconf --kill gpg-agent 2>/dev/null || true
ok "Passphrase verified."

# ---- capture expected subkey fingerprints (bash-3.2 safe: newline-separated string) ----
EXPECTED_FPRS=$(gpg --list-keys --with-colons "$KEYID" | awk -F: '/^fpr/{print $10}' | tail -n +2)
[[ $(echo "$EXPECTED_FPRS" | grep -c .) -eq 3 ]] || { err "Expected exactly 3 subkey fingerprints for $KEYID"; exit 1; }

# ---- confirm subkey order once (it cannot change between cards) ----
step "==> Subkey layout for $KEYID (confirm order: sign=1, enc=2, auth=3):"
gpg --list-keys --with-subkey-fingerprints "$KEYID"
read -rp "Does the subkey order match expected (sign=1, enc=2, auth=3)? Type 'yes' to continue: " SK_CONFIRM
[[ "$SK_CONFIRM" == "yes" ]] || { err "Aborting — verify subkey order manually."; exit 1; }

# ---- loop over YubiKeys (auto-detect insertion) ----
LAST_SERIAL=""
while true; do
  echo
  step "==> Waiting for a YubiKey to be inserted... (Ctrl-C to exit)"
  release_card
  SERIAL=$(wait_for_new_key "$LAST_SERIAL")
  [[ -n "$SERIAL" ]] || SERIAL="unknown"
  ok "==> Detected YubiKey (serial: ${SERIAL})"

  FIRMWARE=$(get_firmware)
  [[ -n "$FIRMWARE" ]] || FIRMWARE="unknown"

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    # --yes still gives a short abort window: auto-detect + auto-wipe is
    # dangerous if the wrong key gets inserted absent-mindedly.
    warn "WARNING: OpenPGP applet and OTP slot 2 on serial ${SERIAL} will be WIPED in 3 seconds. Ctrl-C or remove the key to abort..."
    for i in 3 2 1; do printf '  %s...\r' "$i"; sleep 1; done
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
    record_result "$SERIAL" "$FIRMWARE" "FAILED-${FAIL_STEP:-unknown}"
    err "==> Configuration FAILED at ${FAIL_STEP:-unknown} for this key (serial: ${SERIAL}) — remove it and investigate."
  fi
  LAST_SERIAL="$SERIAL"
done
