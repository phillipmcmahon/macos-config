# User manual

## Runtime and configuration

Use Homebrew Bash 5+, with Homebrew tools first in PATH. For cleanup, run `sudo /opt/homebrew/bin/bash macos-cleanup.sh ...`. Bootstrap alone supports starting under Apple's Bash 3.2. Keep `lib/` alongside the public commands. Every command supports `--help` and `--version` without accessing credentials or performing its operation.

Core dependencies are listed in each script header. Sync requires Git, jq and modern rsync; macOS's old bundled rsync is unsuitable. DNS requires curl, jq and shasum, plus rsync/ssh for replication. Bitwarden requires bw, jq, GnuPG and ZIP utilities. Provisioning requires ykman, GnuPG and a terminal. Install only the tools needed for your chosen commands.

Optional settings files must be owned by the invoking user and not group- or world-writable. ClouDNS credentials must have no group or other permissions, normally mode 600. Missing optional settings use defaults. Parent path symlinks are rejected where checked. Keep private configuration outside the synced repository.

Settings accept literal `KEY=value` and `KEY=('value' 'another')` assignments, with single/double quotes and comments. They do **not** support `$HOME`, `~` expansion, command substitution, escapes, `source`, expressions or arbitrary shell code. Use absolute paths and replace example placeholders. Unknown and repeated keys fail. Arrays replace defaults rather than append. Environment overrides are supported only where listed by the particular command.

Owned lock directories prevent overlapping operations. They are not automatically stolen when a PID looks stale. After an interruption, inspect the lock and confirm no corresponding process remains before removing that specific lock directory. Do not remove another running process's lock.

## ZIP extraction

```bash
bash archive-zip-extract.sh --dry-run /path/to/archives
bash archive-zip-extract.sh /path/to/archives
```

Walks recursively and flattens each archive's internal directories beside the ZIP. Archives remain intact. Duplicate flattened names, including case-only duplicates, existing destinations and invalid archives cause that archive to fail. Other archives are still attempted; any failure gives a non-zero exit. Names containing control characters are unsupported. Publication is per file; an interruption can leave some extracted files present, which a retry will refuse to overwrite.

## ClouDNS

Copy the config, credentials and hosts examples to `~/.config/cloudns/config`, `credentials` and `hosts.txt`. Existing CLOUDNS_AUTH_ID and CLOUDNS_AUTH_PASSWORD environment values override credentials-file values. API credentials travel in the request body rather than command arguments. No live API integration was exercised during validation.

```bash
bash dns-cloudns-cnames-manage.sh --dry-run
bash dns-cloudns-cnames-manage.sh
bash dns-cloudns-cnames-manage.sh --delete
bash dns-cloudns-backup.sh --no-nas
bash dns-cloudns-backup.sh --restore /path/to/backup.bind --dry-run
```

CNAME dry-run performs read-only API calls. Normal mode creates or reconciles matching relative hosts against TARGET and TTL. Delete mode prompts unless `--yes` is supplied. Malformed lookups must not be treated as absent records. Large record sets reaching the lookup limit are refused rather than partly processed. Other record types are untouched.

Backup defaults to `~/.config/cloudns/backups`, with 30 timestamped copies and SHA-256 sidecars. Retention runs after successful publication. `--retention-count 0` disables pruning. `--output FILE` creates a custom backup without retention or replication. Existing output is never overwritten. DNS backup's dry-run applies to restore only.

Restore verifies the selected file's checksum sidecar and configured zone before import. Normal restore is additive. `--replace-existing` requests replacement and can remove existing records. Neither mode promises a transactional rollback from the provider; make a fresh backup first. Restore requires confirmation unless `--yes` is supplied.

NAS settings come from the environment as listed by `--help`. Use dedicated destination directories. Replication synchronises matching backups for the configured domain and can delete older matching destination copies; unrelated names are excluded. An alternate `--backup-dir` still uses the configured NAS destination, so choose a separate NAS target for a separate backup set. SSH is attempted first, then an actual SMB mount. An existing unmounted directory does not qualify as mounted storage. Replication failure returns non-zero but preserves the local backup.

## Bootstrap

```bash
/bin/bash macos-bootstrap.sh --dry-run
/bin/bash macos-bootstrap.sh
```

Review GITHUB_USER, GITHUB_REPO, GIT_BRANCH, REPO_DIR and MACHINE_NAME overrides in `--help`. Bootstrap installs Homebrew if needed, installs Bash/rsync/jq, clones using HTTPS, installs the selected Brewfile and invokes sync restore using Homebrew Bash. Existing Git authentication is tried first. GITHUB_PAT is an optional fallback handled through a temporary askpass script. The repository remote is switched to SSH; arrange SSH authentication separately for later sync. Missing package installations produce a failure result.

## Cleanup

```bash
sudo /opt/homebrew/bin/bash macos-cleanup.sh --dry-run
sudo /opt/homebrew/bin/bash macos-cleanup.sh
```

Quit affected applications first. Default cleanup removes the invoking user's application-cache tree and system caches. `--skip-browsers` conservatively preserves the entire general user-cache tree. User logs, Trash, developer caches, Time Machine snapshots, Docker pruning, saved application state, iOS backups and Xcode archives each require their documented option. Repair, Spotlight and routing operations are separate opt-ins. Read `--help` before combining flags.

Dry-run inspects targets and reports estimates without deleting or repairing. Target sizes can overlap or differ from actual reclaimed space. The summary distinguishes estimated bytes from the observed free-space delta. Removal failures give a non-zero result. Logs are private files under `/private/var/log`; a root-owned lock is under `/private/var/run`. This workflow requires native macOS validation.

## Configuration sync

Settings are `~/.config/macos-config-sync/config`. Review the arrays at the top of the script before replacing defaults with the intentionally small example. Managed paths are HOME-relative, non-overlapping scopes. Symlinks and unsupported path types are refused. Do not put repository, backup or state directories inside managed scopes. Use dedicated, separate absolute directories for the checkout and backups. NAS paths must also identify a dedicated destination; mirroring deletes destination files absent from the checkout.

The default scopes include scripts, docs and selected configuration files, with machine-specific Brewfile, installed-apps.txt and Moom.plist. Exclusions and staged-content scans reduce accidental secret commits but are not an exhaustive secret detector. Review enrolled files yourself.

```bash
bash macos-config-sync.sh status
bash macos-config-sync.sh sync --dry-run
bash macos-config-sync.sh adopt
bash macos-config-sync.sh sync
```

`adopt` declares that the current checkout is already the deployed baseline. Use it only when that is true; it does not reconcile differences. A sync captures local state, collects owned/enrolled files, checks changes, commits/rebases, pushes, backs up affected HOME content and deploys checked files. It refuses concurrent edits rather than overwriting them. `add PATH` enrols a file within a configured scope; `forget PATH` keeps its local file while removing the repository copy on the next sync. AUTO_ADD controls automatic enrolment.

`--dry-run` explains steps without writes; it is not a computed remote diff. `--yes` skips supported confirmation prompts, not validation. `restore` uses the committed checkout; `pull` fetches first. Both intentionally replace managed HOME content and require confirmation. Directory restores mirror configured trees and may delete extra files there. Missing individually configured source files are skipped. Keep backups outside all managed scopes.

### Interrupted sync

Do not change settings while a transaction is pending. Re-run `sync` after correcting a transient failure. If Git reports a rebase conflict, inspect the private checkout and either resolve and continue the rebase or abort it. `cancel` preserves the proposal under a recovery ref and resets the private checkout; it does not undo a pushed commit or restore HOME automatically. Inspect the displayed refs before discarding anything.

Deployment uses checked, per-file replacement and a resumable journal. It is not an atomic update of the entire collection and does not guarantee durability against sudden power loss. Backups and pending state remain important. A failure after push may mean GitHub already has the new commit even though HOME deployment is incomplete. A NAS failure may mean GitHub and HOME are updated but the mirror is not; retry `nas-push` once available.

Finish old pending transactions with the old scripts before upgrading. The legacy state-directory name is retained for continuity; its numeric suffix is not this release's version. The new engine rejects incompatible pending manifests instead of guessing their meaning.

### NAS recovery

`nas-push` requires a clean committed checkout and mirrors files without `.git` history. `nas-pull` restores into a new checkout; it refuses an ordinary existing checkout. Offline recovery records a local snapshot and recovery ref, allowing `restore --yes` while GitHub is unavailable. Once online, repeat `nas-pull` on the marked clean recovery checkout. Reconnection retains the NAS files as working-tree differences against the fetched branch. Inspect and commit intended recovery changes before invoking restore or sync. The NAS mirror is a file recovery source, not a full Git repository backup.

## Bitwarden backup

Copy settings to `~/.config/bitwarden-backup/config`. Choose a full GPG recipient fingerprint, local encrypted-output directory and dedicated mounted NAS destination. Log in with bw before starting; a usable BW_SESSION is needed for unattended runs.

```bash
bash security-bitwarden-backup.sh
bash security-bitwarden-backup.sh --verify
```

Exports personal and accessible organisation vaults, downloads attachments, builds a checksum manifest and encrypts the ZIP before publication. Sessions unlocked by this script are relocked; existing sessions are retained. Failed relocking is reported and retried during cleanup. Plaintext staging is removed on normal completion and handled failures. Process kills and storage failures can prevent cleanup; inspect the reported staging path after such failures. Secure deletion cannot guarantee physical erasure on APFS snapshots or SSDs.

`--verify` decrypts pending backups and reconciles matching NAS copies. Successful decryption is not proof that every vault item can be restored. Periodically perform a controlled restore rehearsal with your own backup and recovery keys. Never treat the mocked encryption fixture as cryptographic validation.

## YubiKey provisioning

Copy settings to `~/.config/yubikey-provision/config`. Verify names, login, full primary fingerprint, keyboard layout and workspace. The existing private GnuPG workspace must be owned by you with mode 700 and contain the required private subkeys. PINs and passwords are prompted, not stored in config.

```bash
bash security-yubikey-provision.sh
```

This resets OpenPGP and overwrites OTP slot 2. Use a spare device for first validation. Keep exactly one YubiKey attached throughout provisioning. ykman operations target the confirmed serial, and serial identity is rechecked around GnuPG operations; a physical hot-swap race cannot be eliminated by these checks. `--yes` skips individual confirmation but retains the abort countdown. `--verbose` redacts diagnostics. There is no simulated dry-run and no hardware test was performed here. Retain and inspect the generated provisioning CSV privately.
