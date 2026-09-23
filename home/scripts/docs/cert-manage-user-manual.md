# Certificate manager

Version 1.0.1. RSA 4096 only, using Let’s Encrypt and the ClouDNS DNS API.

## Installation

Place `cert-manage.sh` in your scripts directory, with the supplied `config/`, `lib/` and `docs/` directories beside it. The included `lib/common.sh` is an unchanged copy of the shared library you supplied. Merge these directories into your existing layout. Do not replace unrelated configuration files.

Use your Homebrew Bash 5+ and OpenSSL 3.x through PATH. acme.sh must already be installed at `~/.acme.sh`, unless configured otherwise. This package does not install software, change DNS outside ACME validation, schedule jobs or deploy certificates to a device.

```bash
chmod 700 ~/scripts/cert-manage.sh
chmod 600 ~/scripts/config/cert-manage.conf
chmod 600 ~/scripts/config/certificates/*.conf
```

If running explicitly with Homebrew Bash, use its actual installation path, which differs between Apple Silicon and Intel Macs. The `#!/usr/bin/env bash` entrypoint otherwise follows your PATH.

## First run

Preview all configured certificates:

```bash
~/scripts/cert-manage.sh
```

Preview and then apply one domain:

```bash
~/scripts/cert-manage.sh --domain phillipmcmahon.com
~/scripts/cert-manage.sh --domain phillipmcmahon.com --apply
```

Apply all configured certificates sequentially:

```bash
~/scripts/cert-manage.sh --all --apply
```

No acme.sh invocation occurs in dry-run. The script reads local state, parses configuration and displays SANs and decisions. An explicitly requested log file can be created/appended during dry-run. Apply processes configurations in filename order and stops at the first failure. Earlier successful domains remain updated.

## Credentials

By default, acme.sh uses its saved ClouDNS credentials or credentials exported in the environment. If your existing the-farriers.com certificate used the same ClouDNS account, its saved credentials can also serve other authorised zones.

To enter main-account credentials interactively:

```bash
~/scripts/cert-manage.sh --domain phillipmcmahon.com --apply --prompt-credentials
```

The password prompt does not echo. This option exports `CLOUDNS_AUTH_ID` and `CLOUDNS_AUTH_PASSWORD` for acme.sh and unsets `CLOUDNS_SUB_AUTH_ID` for the current process. acme.sh manages its own credential persistence. The wrapper does not print credentials or put them in domain configs.

For sub-account credentials, configure acme.sh or the environment appropriately and omit `--prompt-credentials`. Use saved credentials for unattended runs.

## Configuration

Shared settings live in `config/cert-manage.conf`:

| Setting | Default | Meaning |
|---|---|---|
| `ACME_HOME` | `~/.acme.sh` | acme.sh executable and standard certificate state |
| `OUTPUT_ROOT` | `~/certificates` | Parent of domain export directories |
| `CERT_CONFIG_DIR` | `config/certificates` | Per-certificate configuration directory |
| `DNS_SLEEP` | `300` | DNS propagation wait in seconds |

A missing default shared config uses built-in defaults. A missing explicitly selected config is an error. Command-line settings override the shared file. Relative path settings and path overrides resolve against the script directory. The `--config` and `--log-file` paths resolve against the current working directory. Leading `~/` is expanded by the wrapper. `$HOME`, command substitution, shell expressions and executable configuration are not supported.

Configs must be owned by the executing user and must not be writable by group or others. Symbolic links and paths containing `.` or `..` components are rejected by the shared helpers. Use direct paths.

Each certificate has one `DOMAIN.conf` file, containing exactly the primary domain and a literal array of desired names. For example:

```bash
DOMAIN='example.com'
CERT_NAMES=(
    'example.com'
    '*.example.com'
    '*.services.example.com'
)
```

The filename must match `DOMAIN`. Include the primary domain in `CERT_NAMES`. Names must use lower-case ASCII, or punycode for internationalised names. All names must be valid for DNS validation through your ClouDNS account. A certificate may include names from other zones you control.

To add a domain, copy this example to `config/certificates/example.com.conf`, edit it, set private permissions and preview it with `--domain example.com`. No script modification is needed.

The supplied phillipmcmahon.com config uses your corrected domain spelling and reduced eight-name list. Its root wildcard covers immediate subdomains such as management.phillipmcmahon.com, but separate wildcards are retained for names below those subdomains. The the-farriers.com config preserves the six names from your original issuance command.

## Changing SANs

Edit the relevant `CERT_NAMES` array, then preview and apply that domain. The list is authoritative. Both additions and removals trigger replacement issuance. Duplicate names and ordering differences are ignored. The primary domain is always passed first to acme.sh.

The script compares both the saved renewal SAN list and the issued certificate with the desired list. This detects a mismatch after interrupted or failed issuance. Merely reordering the config never requests a replacement.

| State | Behaviour |
|---|---|
| No RSA state | Issue a new certificate |
| SANs differ from issued certificate or saved renewal configuration | Force replacement issuance with the desired names |
| Names match and certificate is valid | Call acme.sh renewal and let it decide when renewal is due |
| Certificate expired | Force replacement issuance |
| Existing RSA state is incomplete | Reissue if saved settings can be validated, otherwise stop for inspection |
| Renewal returns exit 2 | Export the existing certificate after full validation |
| Existing state uses another CA, DNS method or RSA key size | Stop without automatically migrating that state |

Removing a SAN does not revoke previously issued certificates. Existing copies remain usable until their expiry or revocation. Deleting a domain config stops this wrapper managing it, but does not remove an independent acme.sh renewal entry or revoke anything.

The wrapper expects acme.sh's standard RSA state layout under `ACME_HOME/DOMAIN`. Custom separate certificate/config homes are outside this version's scope. ECC state is not modified. RSA 4096 is fixed and no post-quantum or ECDSA variants are generated.

## Outputs and validation

Exports are written beneath:

```text
~/certificates/DOMAIN/letsencrypt/rsa-4096/
```

| File | Contents |
|---|---|
| `certificate.pem` | Leaf/server certificate |
| `chain.pem` | Issuer chain |
| `fullchain.pem` | Leaf certificate followed by issuer chain |
| `private.key` | Private key exported by acme.sh |
| `private-pkcs8.pem` | The same private key in unencrypted PKCS#8 PEM form |

For UniFi, import `fullchain.pem` and `private-pkcs8.pem`. The script does not configure UniFi or any other service.

Before publishing, the script checks the private key, RSA 4096 size, certificate/key match, exact DNS SAN set, certificate expiry, full-chain composition and server-certificate verification against the OpenSSL trust store. OpenSSL verification also checks chain validity periods and trust. If trust verification fails, check the OpenSSL CA bundle. Do not disable verification to work around an unexpected issuer.

Files are private (0600) and the certificate output directory is private (0700). Persistent acme.sh install targets are kept in `.acme-export`. Files are copied to a temporary directory and published only after all validation succeeds. Each final file rename is atomic, but the complete set of files is not an atomic transaction. Import or copy the pair after the script exits successfully. An I/O error during publication can leave a partially updated set.

## Existing the-farriers.com certificate

Use the same `ACME_HOME` as your original script. The new manager recognises the existing RSA configuration and key. With unchanged SANs it checks renewal timing rather than requesting an unnecessary new certificate.

The new export directory includes `rsa-4096`, so the old export directory is left in place and its files can become stale. Use the new output paths going forward. Successful `--install-cert` updates acme.sh's remembered install targets to the new `.acme-export` paths. Existing installation/reload hooks may run as part of acme.sh operations. Review any custom hooks before migration. SAN replacement uses acme.sh `--issue`, which can change its stored issuance settings and hooks.

## Other operations

Export a matching existing certificate without contacting the CA:

```bash
~/scripts/cert-manage.sh --domain the-farriers.com --export-only --apply
```

This still invokes acme.sh installation and can run saved hooks. Export-only refuses SAN drift or an expired certificate.

Force immediate renewal:

```bash
~/scripts/cert-manage.sh --domain the-farriers.com --force --apply
```

CA rate limits still apply. `--force` alone remains a dry-run.

Alternative config directory and log:

```bash
~/scripts/cert-manage.sh --config-dir ~/my-certificate-configs --all --apply --log-file ~/cert-manage.log
```

Logs contain wrapper messages. acme.sh's own output stays on the terminal unless you redirect it yourself.

## Scheduling and concurrency

This package does not modify your scheduler. If scheduling it later, run `--all --apply` with a PATH that selects Homebrew Bash and OpenSSL. Omit the interactive credential option.

Use one coordinated renewal process. The wrapper lock at `ACME_HOME/.cert-manage.lock` prevents two instances of this wrapper from running simultaneously, but independent acme.sh cron/manual runs do not honour that lock. Review existing acme.sh scheduling before adding another schedule.

Independent acme.sh renewals update `.acme-export` only. Run this wrapper afterwards to refresh validated public export paths and the PKCS#8 copy. A stale wrapper lock is never removed automatically. Inspect its `owner` file and confirm no process is active before removing it manually.

## Offline tests

The supplied tests use a disposable local CA, real RSA 4096 keys and an acme.sh test double. They never contact a CA or change DNS.

```bash
bash tests/cert-manage-tests.sh
```

They cover first issuance, renewal not due, SAN changes and reordering, forced renewal, export-only, saved-state drift, failed issuance/renewal, invalid exports, locking and literal-config rejection. They require Bash 5+ and OpenSSL 3.x. Testing on Linux does not replace a dry-run on your Mac or a live ClouDNS issuance check.
