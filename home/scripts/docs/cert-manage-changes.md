# Version 1.0.1

- Renamed documentation to cert-manage-user-manual.md and cert-manage-changes.md to avoid generic documentation filename collisions.
- Replaced the Python integration tests and ACME test double with Bash scripts.
- Updated documentation references and test commands. No Python dependency remains in the package.
- Certificate management behaviour and domain configurations are unchanged from 1.0.0.
- The supplied shared common.sh 1.0.0 is unchanged.

# Version 1.0.0

New generic manager based on cert-the-farriers-renew.sh 1.2.0.

- Per-domain literal SAN configuration for the-farriers.com and phillipmcmahon.com.
- Initial issuance, due renewal and SAN replacement with RSA 4096 only.
- Dry-run default, private permissions, logging, locking and verified PEM/PKCS#8 exports.
- Exact SAN and trusted-chain validation before publishing to a separate rsa-4096 directory.

No live certificates were requested, DNS records changed or scheduling configured during development.
