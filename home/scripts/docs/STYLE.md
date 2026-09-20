# Script style

All eight public scripts use the same header fields, section order and four-space indentation:

```bash
#!/usr/bin/env bash
#
# Script: area-subject-action.sh
# Purpose: One sentence describing the operation.
# Version: 1.0.0
# Requires: Interpreter, commands and adjacent lib/.
# Documentation: docs/USER-MANUAL.md
#
```

The sections are Runtime and configuration, Command interface, Helpers, Operations and Entry point. Functions use `lower_snake_case`; constants and settings use uppercase where consistent with the existing interface. Existing Bitwarden configuration keys remain lowercase for compatibility.

`SCRIPT_VERSION` supplies runtime version output. Header and runtime values must change together. All current public versions are 1.0.0. Historical release narratives have been removed; future notable changes belong in CHANGELOG.md. Internal state-format identifiers are not release numbers and must not be renamed casually.

Comments explain intent, constraints or a non-obvious decision. They do not repeat every command or preserve a running diary. Use short sentences and a space after `#`. Keep related operations in small named functions and use explicit error checks where failure changes the outcome.

Output uses the shared `[INFO]`, `[STEP]`, `[OK]`, `[WARN]` and `[ERROR]` helpers. Colour is enabled only for a terminal, honours `NO_COLOR` and is disabled for `TERM=dumb`. Log files remain plain text. Bootstrap carries a small equivalent helper because the shared library is not yet installed.

Use `printf` for machine-readable output, quote expansions and use arrays for command arguments. Configuration is data, never sourced or evaluated. Keep implementation in Bash; jq and existing command-line utilities handle their specialised formats.

Format with `shfmt -i 4 -ci -sr`. Check public entrypoints with `shellcheck -x -P macos-scripts -S warning macos-scripts/*.sh` from the parent directory. See VALIDATION.md for fixture checks.
