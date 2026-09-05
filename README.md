# macOS configuration

Private repository containing selected macOS configuration, scripts and Homebrew package definitions.

## Shared managed files

Stored beneath the repository's `home` directory and restored on every machine.

- `~/.config/.zsh_functions`
- `~/.config/topgrade.toml`
- `~/.gitconfig`
- `~/.gnupg/gpg-agent.conf`
- `~/.gnupg/gpg.conf`
- `~/.gnupg/scdaemon.conf`
- `~/.gnupg/sshcontrol`
- `~/.zprofile`
- `~/.zshenv`
- `~/.zshrc`

## Shared managed paths

- `~/.config/git/`
- `~/scripts/`

## Machine-specific files and paths

Stored beneath `machines/<machine-name>/home` and restored only on the machine whose name matches (from `scutil --get LocalHostName`, overridable via `MACHINE_NAME`).

- `~/Brewfile`
- `~/installed-apps.txt`

Caches, logs and known credential files (for example `hosts.yml`, `rclone.conf`, `*.token`, `*.key`) are excluded from directory syncs via `EXCLUDE_PATTERNS` in `macos-config-sync.sh`.

## Restore

Use `macos-config-sync.sh pull` to retrieve the current GitHub version and restore files to their normal locations. Shared files are restored everywhere; machine-specific files are restored only on the matching machine.

## Homebrew

The Brewfile is machine-specific (`machines/<machine-name>/home/Brewfile`). After restoring on the matching machine, install its contents with:

```bash
brew bundle --file="$HOME/Brewfile"
```
