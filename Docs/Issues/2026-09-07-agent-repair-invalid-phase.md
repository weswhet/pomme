# `agent repair` rejects a clean VM with an invalid provisioning phase

- **Severity:** High
- **Status:** Resolved (2026-09-08; regression tests and signed Release verification)
- **Area:** `agent repair`
- **Observed on:** Pomme 0.1.0 signed Release build; both a clean Sequoia VM and the Tahoe VM with the retained SIP transaction

## Reproduction

On the clean Sequoia VM, with no `SecurityWorkflowJournal.json` present:

```text
rtk pomme agent repair pomme-agent-cli-sequoia-0907 --final-state previous --format json --debug
```

Observed result: exit 1 with `Pomme provisioning journal has an invalid phase transition.` The same command on Tahoe after the SIP failure produced the same error. The parser correctly rejects an unsupported final state such as `--final-state normal`.

## Expected result

For a VM with no repairable provisioning transaction, the command should return a clear “nothing to repair” or unavailable result. For a retained failed transaction, it should either repair it or report a specific unsupported phase with recovery guidance.

## Impact

The only public repair command cannot distinguish a clean VM from a repairable workflow and does not provide a usable recovery path for the retained SIP failure.

## Source evidence

`PommeCore.repairProvisioning` loads the provisioning journal and requires `PommeProvisioningCoordinator.nextPhase(in:)` to produce `.installRecoveryAgent`. A fully created VM has no such next phase, but the resulting `unexpectedEvent` is rendered as the generic invalid phase transition.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/AgentCommands.swift`
- `Sources/PommeCLI/Operations/PommeApplication.swift`
- `Sources/PommeCLI/CLI/PommeCore.swift`


## Resolution — 2026-09-08

Repair now classifies the verified provisioning journal before capturing the
VM's runtime state or journaling a Recovery effect:

- Completed provisioning returns an explicit “Nothing to repair” error and
  explains that agent repair does not reconcile SIP/AMFI transactions.
- Other supported journal phases return the phase name and the exact
  `pomme create NAME --resume` command.
- An unfinished intent returns a specific interrupted-phase error with status
  inspection guidance; it is retained without attempting another effect.
- A fresh or failed Recovery-agent installation phase remains repairable,
  including its next attempt number. Invalid journal history still fails
  validation.

The separate retained-security-transaction issue remains tracked in
[security-workflow-retained-after-sip-failure](2026-09-07-security-workflow-retained-after-sip-failure.md).

### Validation

- `rtk proxy bash Scripts/build-local.sh` — passed signed Release build, exact
  entitlements/signature verification, compatible designated requirement,
  artifact retention, and installation.
- `rtk proxy zsh -lc 'command -v pomme'` — resolved `/Users/wes/.local/bin/pomme`.
- `rtk pomme --help` — passed.
- `rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build`
  — all 22 contract checks passed.
- Regression tests exercise completed, unsupported, interrupted, repairable,
  retry, and invalid journal histories through the production eligibility
  function. No existing VM or real Pomme credential was used for these tests.
- Current native equivalent of the historical test invocation: `rtk proxy xcodebuild test CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS' -project /Users/wes/dev/pomme/pomme.xcodeproj -scheme pomme -configuration Debug -derivedDataPath /tmp/pomme-repair-tests '-only-testing:PommeCLITests/PommeProvisioningTests'`
  — historical result: 12 tests passed, 0 failed, 0 skipped (including parameterized runs).
- Result bundle: `test_macos_2026-09-08T14-17-58-253Z_pid42116_f26c8618.xcresult`.
- Live Recovery installation was not rerun: this change only classifies the
  journal before the existing Recovery effect.
