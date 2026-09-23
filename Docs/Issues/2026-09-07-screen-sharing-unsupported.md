# Screen Sharing commands are advertised but unsupported by the normal agent

- **Severity:** Medium
- **Status:** Resolved by explicit pre-dispatch unavailability (2026-09-08)
- **Area:** `screen-sharing`
- **Observed on:** Pomme 0.1.0 signed Release build; normal Tahoe VM

## Reproduction

```text
rtk pomme screen-sharing status pomme-agent-cli-tahoe-0907 --format json
rtk pomme screen-sharing enable pomme-agent-cli-tahoe-0907 --format json
rtk pomme screen-sharing disable pomme-agent-cli-tahoe-0907 --format json
```

All three commands exited 1 with `Pomme agent request failed (unsupported-operation)`.

## Expected result

The three public subcommands should report and change the guest Screen Sharing state, or the feature should be reported as unavailable before dispatch.

## Impact

The complete Screen Sharing command family is unusable. The failure is distinct from normal guest validation and occurs after the request reaches the agent.

## Source evidence

`ScreenSharingRequest` serializes the `ui.screenSharing` operation, but the normal `PommeAgent` dispatch contains no `ui.screenSharing` case and the normal capability list does not advertise it.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/SecurityAccessCommands.swift`
- `Sources/PommeCLI/GuestAgent/PommeAgentCLIModels.swift`
- `Sources/PommeCLI/GuestInternal/PommeAgent.swift`

## Resolution approach (2026-09-08)

Use the report's explicit-unavailability alternative. Pomme has no implemented
guest Screen Sharing service, and enabling a launchd record would not prove the
user-facing setting or usable screen-control access.

Before dispatching a Screen Sharing request, the host now queries the
authenticated guest's current capabilities. If `ui.screenSharing` is absent,
it reports that Screen Sharing is unavailable through this agent and does not send
the unsupported operation. A future agent advertising the capability can use
the existing request contract. Help states the guest-support requirement.

Screen Sharing is distinct from Remote Management; Apple documents that the
two cannot be enabled together in
[Screen Sharing settings](https://support.apple.com/en-ie/guide/mac-help/-mh11848/mac).
Apple also states that `kickstart` cannot enable Screen Sharing on macOS 12.1
and later in its
[Remote Desktop guidance](https://support.apple.com/en-au/guide/remote-desktop/apd8b1c65bd/mac).
This correction does not substitute Remote Management, alter privacy policy,
or claim that Screen Sharing has been implemented.

## Implementation

The central application dispatch uses an authenticated `agent.describe`
exchange for each Screen Sharing request. A valid persistent-agent receipt must
contain the expected protocol/version, an ASCII hexadecimal executable digest,
and the exact `ui.screenSharing` capability. Missing, malformed, and Recovery
receipts fail before the dispatch closure runs; a failed query also cannot
fall through to dispatch.

The error now states:

```text
Screen Sharing is unavailable through Pomme because this guest agent does not support it. Configure it in the guest’s Sharing settings instead.
```

The check uses a current authenticated response rather than cached VM metadata.
It does not add `ui.screenSharing` to the current agent's capability list.

## Verification (2026-09-08)

- All 22 focused tests passed, covering capability receipt validation, malformed
  and Recovery receipts, non-ASCII digests, current agent capabilities, and
  dispatch behavior for status, enable, and disable.
- The dispatch tests prove that unsupported guests receive only the describe
  query, failed queries never dispatch, and capable receipts preserve each
  requested action and response.
- Canonical signed Release build and signing/entitlement checks passed.
  Installed executable SHA-256:
  `1b8f4b0d4b057bbf2ce1e4049809ea693544020dca5ccf482ea32c199fae63c8`.
- All 27 CLI integration checks passed, including the support requirement in
  Screen Sharing help.
- Tests used injected receipts and dispatch closures; no VM, Screen Sharing,
  Remote Management, or privacy setting was changed. Live Screen Sharing
  functionality remains unsupported by the current agent.

Current native command equivalents (the results above are historical):

```sh
rtk proxy xcodebuild test CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS' -project pomme.xcodeproj -scheme pomme -configuration Debug -derivedDataPath /tmp/pomme-remote-login -only-testing:PommeCLITests/PommeAgentCLIModelsTests -only-testing:PommeCLITests/PommeScreenSharingDispatchTests -only-testing:PommeCLITests/PommeAgentTests
rtk proxy bash Scripts/build-local.sh
rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build
```
