#!/usr/bin/env bash
# Rsync upload and timestamp repair for SMB/CIFS-backed restricted rsync destinations.
# Uses the existing SSH agent (such as Bitwarden) and does not require a private-key file.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage:
  rsync-upload-with-times.sh SOURCE_DIRECTORY REMOTE_DESTINATION

Example:
  ./rsync-upload-with-times.sh \
    "$HOME/rsync-validation" \
    'burner-test-rsync@10.77.170.80:./'

Files inside SOURCE_DIRECTORY are uploaded into REMOTE_DESTINATION.
Pass 1: ordinary rsync upload with safe temporary-file handling.
Pass 2: repair modification timestamps of existing same-size files.

No checksums, --delete or --inplace are used.
The second pass is only performed if the first pass succeeds.
Run when the source and destination will not be changed concurrently.

SSH: uses the client's existing SSH agent (e.g. Bitwarden).
HELP
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

source_dir=$1
remote_dest=$2

if [[ ! -d "$source_dir" ]]; then
  printf 'ERROR: Source directory not found: %s\n' "$source_dir" >&2
  exit 2
fi

case "$remote_dest" in
  ?*:* ) ;;
  * ) printf 'ERROR: Destination must be an rsync SSH remote (user@host:path).\n' >&2; exit 2 ;;
esac

if ! command -v rsync >/dev/null 2>&1; then
  printf 'ERROR: rsync is not installed.\n' >&2
  exit 2
fi

# Trailing slash copies the contents of the source directory.
source_dir=${source_dir%/}/
ssh_command='ssh -T -o BatchMode=yes'

printf '\n== Stage 1 of 2: upload ==\n'
rsync -rtv --no-perms --omit-dir-times --progress \
  -e "$ssh_command" \
  -- "$source_dir" "$remote_dest"

printf '\n== Stage 2 of 2: restore modification times ==\n'
# --size-only skips same-sized file content and -t sets their modification time.
# --existing excludes missing destination files, so stage 2 does not create new ones.
# If a file changes size between stages, rsync MAY transfer it again.
rsync -rtvi --size-only --existing --no-perms --omit-dir-times \
  -e "$ssh_command" \
  -- "$source_dir" "$remote_dest"

printf '\nBoth stages completed successfully.\n'
