# `create --dry-run` accepts zero disk and memory sizes

- **Severity:** High
- **Status:** Resolved (2026-09-08; focused tests and signed CLI validation)
- **Area:** Direct creation plan validation
- **Observed on:** Pomme 0.1.0, signed Release build, Tahoe 26.6.0 / 25G72 test lab

## Reproduction

From the Pomme repository root:

```text
rtk pomme create pomme-agent-cli-invalid-0907 --version 26.6.0 --disk-size 0GB --memory 0GB --dry-run
```

Observed result:

```text
exit=0
Would create pomme-agent-cli-invalid-0907 (disk 0GB, memory 0GB, boot none).
```

The JSON dry-run payload also reports `diskSize: "0GB"` and `memory: "0GB"` while resolving the Tahoe profile successfully. No VM was created by this reproduction.

## Expected result

The CLI should reject non-positive resource sizes before emitting a successful creation plan. A dry-run plan should satisfy the same resource invariants required by an actual creation.

## Impact

Automation can treat an impossible plan as valid. The failure is deferred to a later execution path, so callers using `--dry-run` cannot rely on it as a complete validation pass.

## Source evidence

`Sources/PommeCLI/CLI/Commands/LifecycleCommands.swift` parses the size strings and returns the dry-run payload before invoking the core VM configuration validation. The core model later requires `memorySizeBytes > 0` and `diskSizeBytes > 0` in `Sources/PommeCLI/CLI/PommeCore.swift`.

## Test evidence

- The same command with valid `40GB` disk and `4GB` memory resolved successfully.
- Invalid textual sizes were rejected by the parser.
- The zero-size command above was the only resource case that returned a successful plan with invalid values.

## Resolution — 2026-09-08

Direct command validation now parses both `--disk-size` and `--memory` and
requires positive byte counts before restore-image resolution or a successful
dry-run result. Actual creation and dry-run share this validation. Errors
identify the invalid flag. Existing config-mode and resume exclusivity remain
intact.

Also corrected the shared size parser's overflow boundary: `Double(UInt64.max)`
rounds up to 2^64, so the conversion guard must use a strict upper bound to avoid
a process trap. Values at that rounded boundary now fail size validation.

### Validation

- `rtk proxy bash Scripts/build-local.sh` — signed Release build and installation
  passed with the required identity, exact entitlements, and compatible
  designated requirement.
- `rtk proxy zsh -lc 'command -v pomme'` — `/Users/wes/.local/bin/pomme`.
- Executable assertions checked each resource flag with `0GB`, `0`, `0.1B`,
  invalid text, `-1GB`, `18446744073709551615B`, and `18446744073709551616B`,
  with and without `--dry-run`: all 28 combinations exited 64, identified the
  invalid flag, and emitted no successful plan. Values were supplied using
  `--flag=value` so negative values reached resource validation.
- `rtk pomme create pomme-agent-resource-plan-check --version 26.6.0 --disk-size 40GB --memory 4GB --dry-run --format json`
  — succeeded; asserted `ok`, `dryRun`, `diskSize`, and `memory` in JSON output.
- `rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build`
  — all 22 contract checks passed.
- Tests use command validation and dry-run only; no VM was created or operated.
- `rtk xcodebuildmcp macos test --project-path /Users/wes/dev/pomme/pomme.xcodeproj --scheme pomme --configuration Debug --derived-data-path /Users/wes/Library/Developer/XcodeBuildMCP/workspaces/pomme-repair-tests/DerivedData --extra-args '-only-testing:PommeCLITests/CreateCommandTests' --verbose --output text`
  — 4 tests passed, 0 failed, 0 skipped, with parameterized resource/mode cases.
- Result bundle: `~/Library/Developer/XcodeBuildMCP/workspaces/pomme-64d67e0299b1/result-bundles/test_macos_2026-09-08T14-24-56-430Z_pid51975_d2c98749.xcresult`.
