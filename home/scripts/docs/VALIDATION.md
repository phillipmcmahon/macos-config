# Validation

## Completed checks

Validation ran on Linux with GNU Bash 5.2.21, rsync 3.2.7, shfmt 3.8.0 and ShellCheck 0.9.0. The target is Homebrew Bash 5+, including the user's Bash 5.3.20 on Apple Silicon.

- All eight public commands return 1.0.0 and expose help without service access.
- Bash syntax checks pass across commands, libraries and fixtures.
- All Bash files conform to `shfmt -i 4 -ci -sr`.
- ShellCheck reports no warnings/errors for the eight public entrypoints with sourced libraries, or the standalone sync engine. Narrow engine annotations explain intentional glob comparisons and nameref analysis limitations.
- Nineteen fixture groups pass. See test-results.txt for the group list.

The fixtures use temporary HOME directories, local disposable Git repositories and command doubles for network services, mounts, Bitwarden, GnuPG and YubiKey identity checks. Actual rsync exercises file mirroring. They do not contact GitHub or ClouDNS, access a real vault or provision hardware. The GnuPG fixture deliberately copies test data so the test can inspect the archive; it is not encryption.

## Reproduction

From the directory containing this bundle:

```bash
bash macos-scripts/tests/run.sh
shfmt -i 4 -ci -sr -d macos-scripts/*.sh macos-scripts/lib/*.sh macos-scripts/tests/*.sh
shellcheck -x -P macos-scripts -S warning macos-scripts/*.sh macos-scripts/lib/sync-engine.sh
```

The test suite needs Bash 5+, Git, jq, modern rsync, ZIP tools and a SHA-256 command. It creates and removes disposable fixtures; run it with Homebrew Bash and tools first in PATH on macOS.

## Remaining native checks

Before replacing scheduled live jobs, perform these checks on macOS:

1. Run the fixtures under Bash 5.3.20. Confirm coloured terminal output and plain redirected output with your terminal settings.
2. Run cleanup with `--dry-run`, inspect the exact target list, then test only your intended options. Native filesystem accounting and macOS repair commands were not exercised here.
3. Test ClouDNS against a disposable zone/record set, including additive restore, replacement restore and provider failures. Fixture response checks are not provider integration certification.
4. Test SSH and actual SMB replication to dedicated temporary NAS destinations. Confirm interrupted transfers and missing mounts report the intended failure.
5. Rehearse Bitwarden decryption and restoration with real recovery keys in a controlled destination. Check unlock/relock behaviour with your bw version.
6. Provision a spare YubiKey before any production key. Verify OpenPGP operations, OTP layout, serial checks, CSV results and interruption handling on hardware.
7. Test bootstrap on a clean Mac or disposable macOS environment. Package installation and actual GitHub authentication were not exercised here.

Per-file deployment is checked and resumable after handled interruption. Whole-tree atomicity, abrupt power loss, all filesystem races and exhaustive secret detection are outside these checks.
