# macOS configuration

Managed by macos-config-sync.sh 1.0.0.

Use `sync` for normal reconciliation. `pull` and `restore` replace managed local files.

## Shared files

- `.config/.zsh_functions`
- `.config/cloudns/hosts.txt`
- `.config/topgrade.toml`
- `.gitconfig`
- `.gnupg/gpg-agent.conf`
- `.gnupg/gpg.conf`
- `.gnupg/scdaemon.conf`
- `.gnupg/sshcontrol`
- `.ssh/config`
- `.zprofile`
- `.zshenv`
- `.zshrc`

## Shared directories

- `.config/git/`
- `docs/`
- `scripts/`

## Machine files

- `Brewfile`
- `installed-apps.txt`
- `Moom.plist`

## Machine directories

None configured.

Private keys and credentials are excluded. SSH authentication must be restored separately.

See `home/scripts/docs/USER-MANUAL.md` for recovery, ownership and configuration rules.
