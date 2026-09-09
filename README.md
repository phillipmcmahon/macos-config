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
- `~/.ssh/config`
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

## SSH

`~/.ssh/config` is a shared managed file containing the SSH connection policy for `github.com` (port 443 tunnel and connection multiplexing). On restore, the sync script also:

- Sets `~/.ssh` to mode 700 and all files within it to mode 600 (SSH refuses to use a config or key file that is group- or world-readable).
- Creates `~/.ssh/sockets/` (mode 700) if it does not already exist. The `ControlPath` directive in `~/.ssh/config` points to this directory — without it, SSH silently falls back to opening a new connection for every git command, which is slower and prone to intermittent timeouts.

The sockets directory is not tracked in Git (it only holds transient Unix domain sockets created by SSH at runtime). It is created automatically by `pull`, `restore`, and `bootstrap.sh`.
