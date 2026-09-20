#!/usr/bin/env bash
#
# Script: bitwarden-workflow.sh
# Purpose: Exercise backup publication with fixture vault and encryption commands.
# Version: 1.0.0
# Requires: Bash 5+, jq, zip and unzip.
# Documentation: docs/VALIDATION.md
#

set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
export HOME=$TEMP/home MOCK_ROOT=$TEMP
mkdir -p "$HOME" "$TEMP/bin" "$TEMP/plain"
export TMPDIR=$TEMP/plain
cat > "$TEMP/bin/bw" << 'MOCK'
#!/usr/bin/env bash
set -eu
case $1 in
    status) printf '{"status":"unlocked"}\n' ;;
    sync) : ;;
    export)
        while (($#)); do if [[ $1 == --output ]]; then shift; printf '{"encrypted":false,"items":[{"id":"item-1"}]}' > "$1"; break; fi; shift; done ;;
    list)
        if [[ $2 == organizations ]]; then printf '[]'
        else printf '[{"id":"item-1","attachments":[{"id":"att-1","fileName":"example.txt","size":"7"}]}]'; fi ;;
    get)
        while (($#)); do if [[ $1 == --output ]]; then shift; printf 'example' > "$1"; break; fi; shift; done ;;
    lock) : ;;
    *) exit 1 ;;
esac
MOCK
cat > "$TEMP/bin/gpg" << 'MOCK'
#!/usr/bin/env bash
set -eu
if [[ " $* " == *' --list-keys '* ]]; then
    printf 'pub:u:2048:1:KEY:100::::::e:\nfpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:\n'
elif [[ " $* " == *' --encrypt '* ]]; then
    output=''
    while (($#)); do
        case $1 in --output) output=$2; shift ;; --encrypt) cp "$2" "$output"; break ;; esac
        shift
    done
else exit 1; fi
MOCK
chmod +x "$TEMP/bin/bw" "$TEMP/bin/gpg"
PATH="$TEMP/bin:$PATH" bash "$ROOT/security-bitwarden-backup.sh" > "$TEMP/result" 2>&1
archive=("$HOME/Documents/encrypted/bw-export/"*-unverified.zip.gpg)
[[ ${#archive[@]} == 1 && -f ${archive[0]} ]]
unzip -p "${archive[0]}" manifest.json | jq -e '.script_version == "1.0.0" and .attachment_count == 1' > /dev/null
[[ -z $(find "$TEMP/plain" -mindepth 1 -print -quit) ]]
printf 'PASS: Bitwarden inventory, attachment, publication and plaintext cleanup\n'
