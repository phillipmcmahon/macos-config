#!/usr/bin/env bash
# configure-yubikey.sh — reset + fully configure one or more YubiKeys (OpenPGP + OTP slot 2) on macOS
#
# v1.4.0 — 2026-09-08
#   • Pre-flight subkey mapping is derived from `gpg --list-secret-keys
#     --with-colons` (ssb records) instead of the public listing, and requires
#     field 15 == "+" (secret material present locally). Stubs ("#") and
#     subkeys already on a smartcard (">") are rejected before any card is
#     reset, instead of failing at step 6 keytocard after the wipe.
#     Record format verified against GnuPG 2.2.40.
#
# v1.3.2 — 2026-09-08
#   • Subkey capability parser rejects disabled subkeys (uppercase D in the
#     capabilities field) in addition to the existing validity-field filter
#
# v1.3.1 — 2026-09-08 (hotfix)
#   • Step 5: removed --force from `ykman openpgp access set-signature-policy`
#     — that subcommand does not accept --force (unlike set-touch / set-retries)
#     and ykman would exit with "No such option: --force", aborting every card
#
# v1.3.0 — 2026-09-08 (third review)
#   • Step 5: forced signature PIN is set with `ykman openpgp access
#     set-signature-policy always` (idempotent) instead of gpg's `forcesig`,
#     which is a toggle and could silently un-force on a card that was
#     already forced. Verification via gpg --card-status is unchanged.
#   • Expected sig/enc/auth fingerprints are derived from the GPG capability
#     field (colon-format sub record, field 12) and filtered to usable
#     subkeys, requiring exactly one per capability. The interactive
#     "confirm sign=1, enc=2, auth=3 order" prompt is removed; the derived
#     mapping is printed instead.
#   • Step 6: keytocard selects subkeys with `key <fingerprint>` rather than
#     positional `key N`, so the transfer no longer depends on list order.
#   • Touch-policy report: att set via set-touch but not readable via
#     `keys info` is tracked as set-but-unverified and reported on its own
#     line instead of being folded into the verified list.
#
# v1.2.0 — 2026-09-08 (second review)
#   • Step 7: fingerprints are now validated per slot (sig/enc/auth against
#     their specific expected subkey) instead of set-membership across all three
#   • Touch-policy reporting tracks which slots were set to cached vs FIXED
#     and reports the actual result, not a blanket "all four cached" claim
#   • FIXED policy detection uses case-insensitive matching (grep -qi)
#   • `ykman openpgp keys info att` is probed before use — older ykman
#     versions that do not support it get a warn-and-skip instead of a failure
#   • Added GnuPG version-dependency note in the header
#
# v1.1.0 — 2026-09-08 (review fixes)
#   • Step 1: `ykman openpgp reset` exit status is now checked (was silently
#     ignored — `if configure_card` disables set -e inside the function)
#   • ModHex validation of the static password when KEYBOARD_LAYOUT=modhex
#     (alphabet bcdefghijklnrtuv, case-insensitive) right after it is entered
#   • Step 6: keytocard exit code is captured and tested alongside the
#     status-line grep instead of being discarded with `|| true`
#   • Step 5: language, salutation/sex, URL and login are now verified from
#     `gpg --card-status`, not just name + forced signature PIN
#   • Key identity: PRIMARY_FPR (full 40-hex fingerprint) is the config
#     constant; KEYID (last 16 chars) and URL are derived from it
#   • Step 8: `ykman otp static` exit status checked and slot 2 confirmed
#     as programmed via `ykman otp info`
#   • Pre-flight: workspace + secret-key checks run BEFORE prompting for secrets
#   • wait_for_new_key refuses to proceed while more than one YubiKey is present
#   • `gpg --card-status` captures in steps 5/7 fail the key instead of
#     silently yielding empty output
#   • mktemp calls use an explicit 10-X template (XXXXXXXXXX)
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
# GnuPG version note: cardholder-attribute and card-slot verification parse
# gpg --card-status human-readable output (field labels, fingerprint lines).
# Tested with GnuPG 2.2.x and 2.4.x on macOS; keep the installed version
# reasonably controlled — a major label change would need matching updates.
# Requires: brew install gnupg ykman
set -Eeuo pipefail

# ---- EDIT THESE ----
NAME_SURNAME="McMahon"    # surname
NAME_GIVEN="Phillip"      # given name
LANG_PREF="en"            # lang preference
SALUTATION="M"            # M, F, or empty
URL_BASE="https://keys.openpgp.org/vks/v1/by-fingerprint/"   # URL = URL_BASE + PRIMARY_FPR
LOGIN="phillip.mcmahon+04bfca0123c1a0d3@gmail.com"
PRIMARY_FPR="EA0483D4C864AA7C10994BE6A11E70ADFDA60CF9"   # full 40-hex fingerprint of the primary key
WORKSPACE="/Users/phillipmcmahon/tmp/gnupg-workspace"
KEYBOARD_LAYOUT="modhex"          # layout for the static password scancodes: modhex, US or UK etc.
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

# ---- PRIMARY_FPR format check + derived identifiers ----
[[ "$PRIMARY_FPR" =~ ^[0-9A-Fa-f]{40}$ ]] || { err "PRIMARY_FPR must be 40 hex characters"; exit 1; }
KEYID="${PRIMARY_FPR:24}"          # long key ID = last 16 hex chars of the fingerprint (display only)
URL="${URL_BASE}${PRIMARY_FPR}"    # cardholder URL always points at the same key

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

# ---- pre-flight environment checks (before any secrets are requested) ----
[[ -d "$WORKSPACE" ]] || { err "Workspace $WORKSPACE not found"; exit 1; }
gpg --list-secret-keys "$PRIMARY_FPR" >/dev/null 2>&1 || { err "Secret key $KEYID (${PRIMARY_FPR}) not found in workspace"; exit 1; }

# ---- temp file + secrets cleanup ----
YK_ERR=$(mktemp "${TMPDIR:-/tmp}/yubikey-err.XXXXXXXXXX")
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
  tmp=$(mktemp "${TMPDIR:-/tmp}/yubikey-csv.XXXXXXXXXX")

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
  # Refuses to proceed while more than one YubiKey is connected: `ykman info`
  # (used by get_serial/get_firmware) and the ykman calls in configure_card
  # assume exactly one device and would otherwise pick one arbitrarily.
  local prev="$1" cur="" removed=0 nkeys=0 multi_warned=0
  while true; do
    nkeys=$(ykman list 2>/dev/null | grep -c . || true)
    if [[ "$nkeys" -gt 1 ]]; then
      if [[ $multi_warned -eq 0 ]]; then
        err "Multiple YubiKeys detected (${nkeys}). Remove all but one to continue..."
        multi_warned=1
      fi
      sleep 1                # NB: does not set removed=1 — the previous key must still
      continue               # be physically removed before it can be re-detected
    fi
    multi_warned=0
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

  # NOTE: configure_card is invoked as `if configure_card`, which suspends
  # `set -e` for the whole function body. Every command in here therefore
  # needs an explicit exit-status check — nothing fails "automatically".
  FAIL_STEP="step1"
  step "  [1/8] Resetting OpenPGP applet..."
  release_card
  if [[ "$VERBOSE" -eq 1 ]]; then
    ykman openpgp reset --force || {
      err "OpenPGP applet reset failed (ykman exit $?). Aborting this key."
      return 1
    }
  else
    ykman openpgp reset --force >/dev/null 2>"$YK_ERR" || {
      cat "$YK_ERR" >&2
      err "OpenPGP applet reset failed. Aborting this key."
      return 1
    }
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
quit
EOF
  # Signature PIN policy: gpg's `forcesig` is a TOGGLE (it flips whatever the
  # card currently has), so it is not safe to script. ykman's
  # set-signature-policy is idempotent ("always" == gpg's "forced") and does
  # not prompt for confirmation (no --force needed — unlike set-touch or
  # set-retries). Admin PIN is piped on stdin (same technique as step 8).
  release_card
  if ! printf '%s\n' "$NEW_ADMIN" | ykman openpgp access set-signature-policy always >/dev/null 2>"$YK_ERR"; then
    redact "$(cat "$YK_ERR")" >&2
    err "Failed to set signature PIN policy to 'always'. Aborting this key."
    return 1
  fi
  release_card
  gpg_card_available || return 1
  # Verify that EVERY attribute actually landed (name, lang, salutation, URL,
  # login, forced signature PIN). Each check names the field so a failure is
  # diagnosable.
  local cs sal_re="" bad=""
  cs=$(gpg --card-status 2>/dev/null) || {
    err "gpg --card-status failed after setting cardholder attributes. Aborting this key."
    return 1
  }
  # GnuPG 2.2 prints "Sex ..........: male|female"; 2.3+ prints
  # "Salutation .......: Mr.|Mrs." — accept either form.
  case "$SALUTATION" in
    M|m) sal_re='^(Salutation|Sex)[ .]*: *(Mr\.|male)$' ;;
    F|f) sal_re='^(Salutation|Sex)[ .]*: *(Mrs\.|female)$' ;;
    *)   sal_re="" ;;   # empty/unset salutation — nothing to verify
  esac
  echo "$cs" | grep -q  "^Name of cardholder: ${NAME_GIVEN} ${NAME_SURNAME}"    || bad="${bad} name"
  echo "$cs" | grep -qE "^Language prefs[ .]*: *${LANG_PREF}$"                  || bad="${bad} lang"
  if [[ -n "$sal_re" ]]; then
    echo "$cs" | grep -qE "$sal_re"                                             || bad="${bad} salutation"
  fi
  echo "$cs" | grep "^URL of public key" | grep -qF "$URL"                      || bad="${bad} url"
  echo "$cs" | grep "^Login data"        | grep -qF "$LOGIN"                    || bad="${bad} login"
  echo "$cs" | grep -q  "^Signature PIN ....: forced"                          || bad="${bad} forcesig"
  if [[ -n "$bad" ]]; then
    redact "$LAST_OUT" >&2
    err "Cardholder attributes not set correctly (failed:${bad}). Aborting this key."
    return 1
  fi

  FAIL_STEP="step6"
  step "  [6/8] Transferring subkeys to card (local copies kept)..."
  # Subkeys are selected by FINGERPRINT (`key <fpr>`), not by list position, so
  # the transfer does not depend on creation order. Card slot numbers are
  # fixed by the OpenPGP spec: 1 = signature, 2 = encryption, 3 = authentication.
  local kt_spec kt_slot kt_fpr kt_out kt_rc
  for kt_spec in "1:${EXPECTED_SIG_FPR}" "2:${EXPECTED_ENC_FPR}" "3:${EXPECTED_AUTH_FPR}"; do
    kt_slot="${kt_spec%%:*}"
    kt_fpr="${kt_spec#*:}"
    # Kill agent so PIN/passphrase caching doesn't change the prompt count
    # (one component per gpgconf --kill call — see release_card)
    gpgconf --kill gpg-agent 2>/dev/null || true
    gpgconf --kill scdaemon 2>/dev/null || true
    sleep 1
    gpg_card_available || return 1

    # Capture gpg's real exit code (not discarded) AND scan the status lines:
    # gpg can exit 0 after a failed keytocard, and can exit non-zero without
    # a recognisable status line, so both signals are tested.
    kt_rc=0
    kt_out=$(gpg --no-tty --status-fd=1 --command-fd=0 --pinentry-mode=loopback --edit-key "$PRIMARY_FPR" 2>&1 <<EOF
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
  card_status=$(gpg --card-status 2>/dev/null) || {
    err "gpg --card-status failed while verifying card slots. Aborting this key."
    return 1
  }
  # Each card slot must hold its specific expected subkey — not just any of the
  # three.  A swapped slot assignment (e.g. enc key in the sig slot) would pass
  # a set-membership test but produce wrong behaviour at use time.
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
    # Extract the fingerprint from the card slot (strip label and spaces)
    card_fpr=$(echo "$card_status" | grep "^${slot_label}" | sed 's/^[^:]*: *//' | tr -d ' ')
    if [[ -z "$card_fpr" ]]; then
      err "${slot_label} on card is empty (could not parse fingerprint). Aborting this key."
      return 1
    fi
    # Case-insensitive comparison (GnuPG may print upper- or lowercase hex)
    if [[ "$(printf '%s' "$card_fpr" | tr '[:upper:]' '[:lower:]')" != \
          "$(printf '%s' "$slot_expected" | tr '[:upper:]' '[:lower:]')" ]]; then
      err "${slot_label} fingerprint on card (${card_fpr}) does not match expected (${slot_expected}). Aborting this key."
      return 1
    fi
  done
  ok "        all three card fingerprints match their expected slots"

  FAIL_STEP="step8"
  step "  [8/8] Touch policies + OTP static password..."
  release_card
  # ykman takes --admin-pin as a literal value only ("-" would be used as the
  # PIN itself). Omitting the option makes ykman prompt, and its prompt reads
  # a line from stdin when stdin is not a TTY — so pipe the PIN instead.
  #
  # Probe whether the installed ykman accepts "att" for `keys info` — some
  # versions (≤ 5.1) do not, even though `set-touch att` works fine.  When
  # unsupported we still attempt set-touch but skip the read-back verification
  # and warn the operator.
  local att_info_supported=1
  ykman openpgp keys info att >/dev/null 2>&1 || att_info_supported=0

  # Three outcome buckets so the final report never overstates verification:
  #   cached_slots      set to cached AND read back as Cached
  #   unverified_slots  set-touch succeeded but could not be read back (att on old ykman)
  #   fixed_slots       policy is FIXED on the card and was left untouched
  local slot cached_slots="" unverified_slots="" fixed_slots=""
  for slot in sig dec aut att; do
    if printf '%s\n' "$NEW_ADMIN" | ykman openpgp keys set-touch "$slot" cached --force >/dev/null 2>"$YK_ERR"; then
      # Verify — except att when the installed ykman cannot query it
      if [[ "$slot" == "att" && "$att_info_supported" -eq 0 ]]; then
        warn "        touch policy for att set (installed ykman cannot verify via keys info — verify manually)"
        unverified_slots="${unverified_slots} ${slot}"
      elif ! ykman openpgp keys info "$slot" 2>/dev/null | grep -qi "Touch policy: *Cached"; then
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
  # Report each bucket separately — never fold unverified or FIXED slots into
  # the "verified" line.
  [[ -n "$cached_slots" ]]     && ok   "        touch policy 'cached' set + verified on:${cached_slots}"
  [[ -n "$unverified_slots" ]] && warn "        touch policy 'cached' set but NOT verified on:${unverified_slots}"
  [[ -n "$fixed_slots" ]]      && warn "        touch policy FIXED (permanent, not changed):${fixed_slots}"

  release_card
  # Same stdin technique: omit the PASSWORD argument so ykman prompts and
  # reads the piped line ("-" would be taken as the literal password).
  local otp_rc=0
  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '%s\n' "$STATIC_PW" | ykman otp static --keyboard-layout "$KEYBOARD_LAYOUT" --no-enter --force 2 || otp_rc=$?
  else
    printf '%s\n' "$STATIC_PW" | ykman otp static --keyboard-layout "$KEYBOARD_LAYOUT" --no-enter --force 2 >/dev/null 2>"$YK_ERR" || otp_rc=$?
    [[ "$otp_rc" -eq 0 ]] || redact "$(cat "$YK_ERR")" >&2
  fi
  if [[ "$otp_rc" -ne 0 ]]; then
    err "FAILED programming OTP slot 2 static password (ykman exit ${otp_rc}). Aborting this key."
    return 1
  fi
  # Verify: `ykman otp info` lists "Slot 2: programmed" once the slot is set
  if ! ykman otp info 2>/dev/null | grep -qE "^Slot 2: *programmed"; then
    err "OTP slot 2 does not report as programmed after ykman otp static. Aborting this key."
    return 1
  fi
  ok "        OTP slot 2 static password set + verified programmed"

  FAIL_STEP=""
  BUSY=0
  # Final one-screen summary instead of full card status dump (non-fatal:
  # the key is already fully configured at this point)
  release_card
  card_status=$(gpg --card-status 2>/dev/null) || card_status=""
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
# With the modhex layout ykman only accepts the ModHex alphabet
# (bcdefghijklnrtuv — 16 keys that sit in the same place on every keyboard).
# Validate here so a bad password fails before any card is wiped.
# (tr instead of ${var,,}: bash 3.2 has no case-conversion expansion.)
if [[ "$(printf '%s' "$KEYBOARD_LAYOUT" | tr '[:upper:]' '[:lower:]')" == "modhex" ]]; then
  [[ "$STATIC_PW" =~ ^[bcdefghijklnrtuvBCDEFGHIJKLNRTUV]+$ ]] || {
    err "Static password is not valid ModHex: only the characters b c d e f g h i j k l n r t u v (any case) are allowed with KEYBOARD_LAYOUT=modhex"
    exit 1
  }
fi

# ---- validate the passphrase up-front (before touching any card) ----
step "==> Validating GPG key passphrase..."
if ! echo test | gpg --batch --pinentry-mode=loopback --passphrase-fd 3 \
  --local-user "$PRIMARY_FPR" --sign --output /dev/null 3< <(printf '%s' "$PASSPHRASE") 2>/dev/null; then
  err "Passphrase for $KEYID is incorrect. Aborting."
  exit 1
fi
# Kill the agent so the validation sign doesn't leave the passphrase cached,
# which would change the expected prompt count in the keytocard sessions.
gpgconf --kill gpg-agent 2>/dev/null || true
ok "Passphrase verified."

# ---- derive expected subkey fingerprints from the SECRET keyring ----
# We parse `gpg --list-secret-keys --with-colons`, not --list-keys: the public
# listing proves a subkey exists but not that its secret material is here to
# transfer. Record format (verified on GnuPG 2.2.40):
#   ssb:<validity>:...:<caps>:::<secret-flag>:...   followed by
#   fpr:::::::::<fingerprint>:
# field 2  = validity (r/e/i/d = revoked/expired/invalid/disabled)
# field 12 = capabilities (s/e/a; uppercase D = disabled)
# field 15 = secret-key presence: "+" material present locally,
#            "#" stub (no secret), ">" stored on a smartcard (not transferable)
# Only "+" is accepted — a ">" subkey already lives on another card and
# keytocard would fail on it at step 6, after this card had been wiped.
# Pair each ssb with its following fpr and require exactly one usable,
# locally-present subkey per capability. (The earlier "confirm sign=1,
# enc=2, auth=3 order" prompt is replaced by this mechanical mapping.)
subkey_fpr_for_cap() {
  # Usage: subkey_fpr_for_cap <s|e|a>  -> prints matching fingerprint(s), one per line
  gpg --list-secret-keys --with-colons "$PRIMARY_FPR" | awk -F: -v cap="$1" '
    $1 == "ssb" { keep = (index($12, cap) > 0 && index($12, "D") == 0 && $2 !~ /^[reid]$/ && $15 == "+"); next }
    $1 == "fpr" && keep { print $10; keep = 0 }
    { keep = 0 }'
}
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
