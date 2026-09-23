# MDM accepts a fractional timeout that the control layer rejects

- **Severity:** Medium
- **Status:** Resolved (2026-09-08)
- **Area:** `mdm --timeout`
- **Observed on:** Pomme 0.1.0 signed Release build

## Reproduction

The following command used a missing profile so no guest mutation could occur, but the timeout validation was reached first:

```text
rtk proxy env POMME_VM_NAME=pomme-agent-cli-sequoia-0907 /Users/wes/.local/bin/pomme mdm --profile /tmp/pomme-cli-missing-0907.mobileconfig --guest-path /private/var/tmp/pomme-cli-missing-0907.mobileconfig --enrollment-mode supervised --timeout 0.1 --format json --debug
```

Observed result: exit 1 with:

```text
Unknown control command: mdm timeout must be between 1 and 300 seconds
```

The CLI correctly rejects `--timeout 0` with exit 64, but a positive value below the agent’s one-second minimum passes the CLI boundary and fails later as an internal control error.

## Expected result

The CLI should reject values below one second with a usage/validation error, or consistently support fractional values through the full MDM workflow.

## Impact

Scripts receive an internal-looking exit-1 error for invalid user input instead of a stable argument-validation result.

## Source evidence

The shared CLI timeout validation checks only that the value is greater than zero. `PommeApplication.mdmEnroll` then checks the stricter one-to-300-second range and throws `invalidControlCommand`, which produces the observed error wording.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/SecurityAccessCommands.swift`
- `Sources/PommeCLI/Operations/PommeApplication.swift`


## Resolution

`MDMCommand.validate()` now rejects non-finite timeouts and values outside the
inclusive 1–300 second range before target resolution or environment access.
Invalid input produces an ArgumentParser usage error (exit 64), with
`--timeout must be between 1 and 300 seconds.` In-range fractional values remain
supported. The shared timeout option and downstream MDM guards are unchanged.

## Verification

- Reproduced the original exit-1 error using the prior signed CLI and an explicitly
  nonexistent VM/profile; no VM operation occurred.
- Focused Debug `MDMCommandTests` passed (5 test methods, including parameterized
  cases). Accepted `1`, `1.5`, and `300`; rejected `-1`, `0`, `0.1`, `300.1`,
  `-inf`, `nan`, and `inf`.
- Built and installed through the canonical signed Release workflow. Signature,
  designated requirement, and exact entitlement checks passed. Executable SHA-256:
  `41e3acd94e8c0559ffc7f4ee4500613abb19194737beebc5bef6a4106b996388`.
- Against that installed CLI, `-1`, `0`, `0.1`, `0.999`, `300.1`, `-inf`, `nan`, and
  `inf` each returned exit 64 and the expected range message, without an internal
  control error. Commands used a nonexistent target and profile.
- All 22 CLI integration checks passed. No VM, profile installation, enrollment,
  credential, or access-service mutation was needed for this parser correction.

Commands:

Current native command equivalents (the results above are historical):

```sh
rtk proxy xcodebuild test CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS' -project pomme.xcodeproj -scheme pomme -configuration Debug -derivedDataPath /tmp/pomme-mdm-timeout-parser -only-testing:PommeCLITests/MDMCommandTests
rtk proxy bash Scripts/build-local.sh
rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build
```
