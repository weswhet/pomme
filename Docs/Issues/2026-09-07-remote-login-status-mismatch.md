# Remote Login enable reports success while status remains Off

- **Severity:** Medium
- **Status:** Resolved (2026-09-08)
- **Area:** `remote-login`
- **Observed on:** Pomme 0.1.0 signed Release build; normal Tahoe VM

## Reproduction

The initial status was `Remote Login: Off`.

```text
rtk pomme remote-login enable pomme-agent-cli-tahoe-0907 --format json --debug
```

Observed result: exit 0 with `{"result":{"enabled":true}}` and `ok: true`.

```text
rtk pomme remote-login status pomme-agent-cli-tahoe-0907 --format json --debug
```

Observed result: exit 0, with the streamed status still reporting `Remote Login: Off`. `remote-login disable` also returned success with `enabled: false`.

## Expected result

After a successful enable, the status command should report the enabled state. If the two commands refer to different system settings, the CLI should name that distinction.

## Impact

Automation cannot use the enable result as evidence that the setting observed by the status command changed.

## Source evidence

The enable/disable request calls `launchctl enable|disable system/com.openssh.sshd`, while status runs `/usr/sbin/systemsetup -getremotelogin`. These are separate state surfaces, but the public commands present them as one Remote Login setting.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/SecurityAccessCommands.swift`
- `Sources/PommeCLI/GuestInternal/PommeAgent.swift`

## Confirmed cause and correction (2026-09-08)

The mutation acknowledges a launchd enable record without verifying the Remote
Login setting that the status command observes. Successful process termination
alone therefore cannot establish the requested state.

Apple documents `systemsetup -setremotelogin on|off` as the command for changing
Remote Login. The correction uses that command and verifies the result with
`-getremotelogin` before returning success. See
[Apple's systemsetup documentation](https://support.apple.com/en-gb/guide/remote-desktop/apd95406b8d/mac).

Apple also documents a Full Disk Access requirement for the parent process on
macOS Catalina and later. Permission denial must produce an actionable failure,
including when the utility exits zero without changing the setting. Pomme must
not grant itself access or change TCC policy. See the
[archived Apple administrator guidance](https://support.apple.com/en-us/101653).

## Implementation

Enable/disable runs `systemsetup -f -setremotelogin on|off`, then parses the
`-getremotelogin` response and requires the observed value to match the request.
The returned `enabled` field comes from that verified observation. The `-f`
option avoids the interactive confirmation when disabling Remote Login.

The utility runs with closed stdin and a C locale, bounded output capture, and
a deadline. Its raw diagnostics are not forwarded. Full Disk Access denial and
failed verification have distinct, safe errors that survive the authenticated
guest-to-host exchange and cause a nonzero CLI result.

## Verification (2026-09-08)

- All 49 focused tests passed: guest transaction behavior, protocol error
  mapping, host session handling, authenticated Remote Login exchanges, public
  request payloads, and foreground result handling.
- The three authenticated exchange tests also passed after strengthening
  success coverage to run the real verification logic for both on and off.
- Canonical signed Release build and signing/entitlement checks passed.
  Installed executable SHA-256:
  `408ff9dea03fdaf36ca1af364847149cd9af47f04cd67c08307d30c046601179`.
- All 22 CLI integration checks passed against the installed executable.
- Verification used injected utility results and real in-process authenticated
  protocol exchanges. No host or guest Remote Login setting or Full Disk Access
  policy was changed. A live enable/disable cycle with this build remains
  unverified; existing guests need the corrected agent implementation.

```sh
rtk xcodebuildmcp macos test --project-path pomme.xcodeproj --scheme pomme --configuration Debug --derived-data-path /tmp/pomme-remote-login --extra-args=-only-testing:PommeCLITests/PommeAgentTests -only-testing:PommeCLITests/PommeAgentProtocolTests -only-testing:PommeCLITests/PommeAgentSessionFailureTests -only-testing:PommeCLITests/PommeRemoteLoginExchangeTests -only-testing:PommeCLITests/PommeAgentCLIModelsTests -only-testing:PommeCLITests/PommeForegroundControlTests --output text --verbose
rtk proxy bash Scripts/build-local.sh
rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build
```
