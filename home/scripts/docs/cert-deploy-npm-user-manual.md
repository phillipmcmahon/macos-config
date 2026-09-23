# NPM certificate deployment

Version 1.0.0. All supplied scripts and tests use Bash.

## Installation

Merge the package into your existing scripts directory, keeping this layout:

| File | Purpose |
|---|---|
| `cert-deploy-npm.sh` | Public entrypoint |
| `config/cert-deploy-npm.conf` | Deployment settings |
| `lib/cert-deploy-npm-remote.sh` | Bash helper streamed over SSH |
| `lib/common.sh` | Unchanged copy of your supplied shared library |
| `docs/cert-deploy-npm-user-manual.md` | This guide |
| `tests/cert-deploy-npm-tests.sh` | Offline Bash integration tests |

Keep your existing matching common.sh. Documentation and new helper filenames are specific to this script, avoiding the generic manual and changelog names.

```bash
chmod 700 ~/scripts/cert-deploy-npm.sh
chmod 600 ~/scripts/config/cert-deploy-npm.conf
```

Local requirements: Bash 5+, OpenSSL 3.x, OpenSSH ssh/scp and standard filesystem tools. Your PATH must select Homebrew Bash and OpenSSL. The remote Ubuntu host needs Bash, OpenSSL, Podman and standard filesystem tools. The remote helper does not require common.sh or a permanent installation on the host.

## Defaults

The script has working built-in defaults even without the default configuration file:

| Setting | Value |
|---|---|
| `DOMAIN` | `phillipmcmahon.com` |
| `SOURCE_DIR` | `~/certificates/phillipmcmahon.com/letsencrypt/rsa-4096` |
| `NPM_HOST` | `phillipmcmahon@dmz-podman.phillipmcmahon.com` |
| `NPM_CONTAINER` | `proxy.phillipmcmahon.com` |
| `DEST_DIR` | `/home/phillipmcmahon/podman/npm/data/custom_ssl/npm-21` |
| `SSH_PORT` | `22` |
| `STOP_TIMEOUT` | `60` seconds |

The destination and its existing fullchain.pem and privkey.pem must already exist. Run as the local user owning the source files. Remote operations run as phillipmcmahon, without sudo, against that user's rootless Podman container.

## Use

Preview and validate local files, with no SSH connection:

```bash
~/scripts/cert-deploy-npm.sh
```

Deploy:

```bash
~/scripts/cert-deploy-npm.sh --apply
```

Run after successful issuance or renewal:

```bash
~/scripts/cert-manage.sh --domain phillipmcmahon.com --apply && \
    ~/scripts/cert-deploy-npm.sh --apply
```

Other options:

```bash
~/scripts/cert-deploy-npm.sh --config ~/my-configs/npm.conf --apply
~/scripts/cert-deploy-npm.sh --source-dir ~/certificates/phillipmcmahon.com/letsencrypt/rsa-4096 --apply
~/scripts/cert-deploy-npm.sh --apply --log-file ~/cert-deploy-npm.log
~/scripts/cert-deploy-npm.sh --help
~/scripts/cert-deploy-npm.sh --version
```

Config values are literal, loaded through common.sh. Shell expressions and substitutions are rejected. The wrapper expands leading ~/ in paths. Relative source paths resolve against the script directory. Relative config and log paths resolve against the working directory. An explicitly requested missing config is an error. Config files must belong to the executing user and not be writable by group or others. Symlink source/config paths are rejected.

Remote paths must be absolute and contain only letters, digits, underscores, dots, hyphens and slashes, without dot-directory components. This deliberately narrow syntax prevents remote shell interpretation of configuration values.

## SSH setup

The script honours your existing SSH configuration and agent. It uses batch mode so unattended runs fail rather than wait for passwords, and requires a trusted host key already in known_hosts. Establish and verify the normal SSH connection first if needed:

```bash
ssh phillipmcmahon@dmz-podman.phillipmcmahon.com
```

Do not disable host-key checking. If using your Bitwarden SSH agent, it must be available and unlocked as required by your setup. There are no credentials in the config. The script does not alter your SSH settings.

## Deployment behaviour

1. Check that the local private key is valid RSA 4096, matches the certificate, and that the certificate is unexpired, covers DOMAIN and verifies through the OpenSSL trust store for server use.
2. In apply mode, lock local deployment and copy the pair into a private snapshot, then validate that snapshot again.
3. Check the remote target directory, existing files and named Podman container. Create a unique private staging directory under the destination.
4. Upload both files and compare their SHA-256 hashes with the validated snapshot.
5. Acquire a remote deployment lock. If both uploaded files are byte-identical to the installed pair, skip installation and restart.
6. Back up the existing pair in a private `.cert-backup.*` directory, replace both files and restart the named container with a 60-second shutdown timeout.
7. Check Podman reports the container running and clean up staging and locks.

Mapping:

| Local file | Remote file | Installed permission |
|---|---|---|
| `fullchain.pem` | `fullchain.pem` | 0644 |
| `private.key` | `privkey.pem` | 0600 |

Use only after cert-manage.sh has finished. Do not run another certificate writer against the source or destination during deployment. The source snapshot protects the transfer from later changes, but the pair is not captured as a filesystem transaction. Certificate-manager and deployment locks are separate.

The complete SAN set remains controlled and checked by cert-manage.sh. This deployment script checks the configured hostname and matching key rather than independently loading the certificate manager's SAN config.

Restarting NPM briefly interrupts its proxy services. Checking container-running status does not prove all proxy hosts are serving HTTPS correctly. Verify an HTTPS endpoint after the first live deployment. No live host was contacted during development.

The script directly replaces NPM's existing custom certificate files. It does not call NPM's API or update its database metadata. NPM UI certificate edits or other automation can overwrite those files. It does not interact with UniFi.

## Backups and failure handling

Backups are retained beneath DEST_DIR as `.cert-backup.*` and their paths are printed. The directories are private. They include previous private keys, so remove unneeded backups deliberately after verifying deployment. No automatic backup deletion is performed.

Upload or validation failures leave the installed pair untouched. Once replacement starts, a failed replacement, restart or running-state check triggers an attempt to restore the old pair and restart NPM again. Rollback failure is reported and returns failure. Inspect the backup path and NPM logs if recovery needs manual action.

An untrappable process termination, host failure or some SSH failures can prevent cleanup or leave uncertain deployment state. The two file replacements are not a single atomic operation. Inspect files, backup and container status before retrying after a connection failure.

Locks are at SOURCE_DIR/.cert-deploy-npm.lock locally and DEST_DIR/.cert-deploy-npm.lock remotely. Other writers do not honour them. Stale locks require inspection and manual removal after confirming there is no deployment running. Remote staging cleanup is attempted on failure, but may need manual removal if the connection is unavailable.

Wrapper messages can be appended with --log-file. Remote Podman/helper output remains on the terminal. Exit status is zero for successful installation or an unchanged pair, and non-zero on failure. No scheduling is configured.

## Offline tests

```bash
bash ~/scripts/tests/cert-deploy-npm-tests.sh
```

The tests generate disposable certificates and substitute Bash SSH, SCP and Podman commands. They test local validation, failed upload protection, changed and unchanged deployments, rollback after restart failure and rejection of an invalid key or hostname. They do not access your host or change real certificate files.
