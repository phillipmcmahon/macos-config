# macOS configuration

Private repository containing selected macOS configuration, scripts and Homebrew package definitions.

## Shared managed files

Stored beneath the repository's `home` directory and restored on every machine.

- `~/.config/.zsh_functions`
- `~/.config/cloudns/hosts.txt`
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
- `~/Moom.plist`

Caches, logs and known credential files are excluded via `EXCLUDE_PATTERNS`.
New files inside managed directories are local-only by default. Enrol one with
`macos-config-sync.sh add scripts/example.sh`, then run `sync`.
`forget scripts/example.sh` keeps this Mac's local file and proposes deleting
the repository copy. Other Macs will see that deletion. `AUTO_ADD=1` explicitly
enables the older automatic-enrolment behaviour. Individual configured files
are always managed unless forgotten or excluded.

## Baseline and recovery

After upgrading an already-synchronised Mac, inspect the checkout and run
`macos-config-sync.sh adopt` once. This explicitly trusts it as the last deployed
state. Fresh Macs should use deliberate `pull` or `restore` instead.
Python 3 is required. Pending transactions check SHA-256 HOME snapshots before
deploying and stop if newer local edits exist. Resolve rebase conflicts inside
the repository and run `git rebase --continue`, then `sync`.
To abandon a proposal, abort any active rebase first and run `cancel`. It
preserves commits and uncommitted changes before resetting the private checkout,
and never changes HOME. Cancel is not a rollback of an already published commit.
Avoid editing managed HOME files during deployment. Each replacement is atomic,
but the collection of files is not a filesystem-wide atomic transaction.

A no-change run skips backup and deployment, but retries an outstanding NAS
mirror. NAS completion is tracked separately from Git completion.
`DRY_RUN=1` prints an operation explanation without mutating files or fetching.
It is not a computed reconciliation preview.

## Restore

Use `macos-config-sync.sh sync` for normal multi-machine operation. It captures local changes before fetching, reconciles them with GitHub using Git, and deploys only after conflicts are resolved. Use `pull` only when you deliberately want GitHub to replace the managed local state. Shared files are restored everywhere; machine-specific files are restored only on the matching machine.

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

## Moom

[Moom](https://manytricks.com/moom/) window-layout preferences are exported on every push and imported on every pull/restore, using \`defaults export\` / \`defaults import\` as [recommended by the developer](https://manytricks.com/osticket/kb/faq.php?id=53). The exported \`Moom.plist\` is machine-specific (\`machines/<machine-name>/home/Moom.plist\`) because window layouts are typically tied to a machine's display configuration.

**Important:** Quit Moom before running push or pull. While Moom is running it holds preferences in memory, so an export may read stale data and an import may be overwritten when Moom next saves. The script warns if a running Moom process is detected but does not abort — machines without Moom installed simply skip the export/import step.
