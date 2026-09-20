# macOS scripts

Version **1.0.0** is the clean baseline for all eight commands. The scripts use Bash, share consistent output and configuration helpers, and retain their adjacent `lib/` directory.

Use Homebrew Bash 5 or later. Your Bash 5.3.20 is suitable. `macos-bootstrap.sh` can start with Apple's `/bin/bash` and installs Homebrew Bash before restoring configuration.

```bash
/opt/homebrew/bin/bash archive-zip-extract.sh --help
/opt/homebrew/bin/bash macos-config-sync.sh status
```

On Intel Macs, Homebrew normally uses `/usr/local`. For direct execution, ensure the Homebrew `bin` directory appears before `/bin` in `PATH`. For sudo, specify the Homebrew Bash path explicitly.

## Names

Commands use lowercase `area-subject-action.sh`, with hyphens, a Bash extension and a verb describing the operation. A short `area-action.sh` name is used where the subject is already clear.

| Previous name | Baseline name |
| --- | --- |
| inflate-zips.sh | archive-zip-extract.sh |
| cloudns-backup.sh | dns-cloudns-backup.sh |
| cloudns-cnames.sh | dns-cloudns-cnames-manage.sh |
| bootstrap.sh | macos-bootstrap.sh |
| mac_cleanup.sh | macos-cleanup.sh |
| macos-config-sync.sh | macos-config-sync.sh |
| bw-export.sh | security-bitwarden-backup.sh |
| configure-yubikey.sh | security-yubikey-provision.sh |

Update aliases, launch agents and scheduled jobs that use the previous names. No compatibility wrappers are included. The four excluded scripts are outside this bundle.

## Installation and migration

1. Keep a copy of your current scripts and settings. Finish or cancel existing sync transactions with the original bundle before replacing it.
2. Install the eight scripts together with `lib/`, preserving relative paths. Bootstrap expects sync at `home/scripts/macos-config-sync.sh` inside the configuration repository.
3. Review `config/examples/` and copy only the settings you need to the documented locations. Replace placeholder absolute paths. Existing executable shell configuration must be converted to literal assignments.
4. Read the [user manual](docs/USER-MANUAL.md), especially sync recovery and destructive operations. Check `--help` and use supported dry runs before live operations.

See [changes](docs/CHANGELOG.md), [style](docs/STYLE.md) and [validation](docs/VALIDATION.md). Bash fixtures are in `tests/`.
