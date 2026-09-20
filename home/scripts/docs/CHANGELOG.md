# Changes

## 1.0.0

Clean baseline across eight Bash scripts. Earlier in-script release histories are removed.

- Standardised names, headers, sections, indentation, help, versions and terminal-aware status colours.
- Added shared literal-configuration parsing, dependency checks, owned locks, path validation and checked publication helpers.
- ZIP extraction now reports failures, refuses flattened-name collisions and preserves existing files.
- ClouDNS operations validate response structure and mutation status. Backups publish with checksums; restore verifies the selected file. Failed replication reports failure while retaining local output.
- Cleanup uses an explicit, narrower set of targets. User data removal and repair tasks require their own flags. Removed unsafe SQLite sidecar deletion and unrelated application-data cleanup. Reported target sizes are estimates, separate from observed free-space change.
- Bootstrap explicitly installs Bash, jq and rsync, handles existing Git authentication and restores through Homebrew Bash. SSH private-key restoration is not implied.
- Configuration sync uses a Bash inventory and deployment engine instead of embedded Python. It checks concurrent edits, preserves interrupted transactions, verifies deployment and supports offline NAS file recovery and reconnection.
- Bitwarden backup indexes attachments once, checks encrypted publication and retries failed relocking during cleanup.
- YubiKey provisioning verifies the confirmed serial around operations, validates its private workspace and improves failure accounting and cleanup.
- Added literal configuration examples, usage and recovery documentation, and isolated Bash fixtures.

The bundle omits yubikey-gpg-ssh-setup.sh, install-bios.sh, psx-playlist and openpgp_generator.sh as requested.
