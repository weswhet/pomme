# SIP disable failure leaves a retained security transaction that blocks follow-up operations

- **Severity:** Critical
- **Status:** Resolved — explicit retained-transaction resume guidance and regression coverage
- **Area:** SIP security workflow and recovery
- **Observed on:** Pomme 0.1.0 signed Release build; Tahoe 26.6.0 / 25G72 VM created with a 40GB disk and 4GB memory

## Reproduction

```text
rtk pomme sip disable pomme-agent-cli-tahoe-0907 --force --final-state stopped --format json --debug
```

The command completed Recovery bootstrap, authenticated the persistent normal agent, created and verified the owner account, and reached the native automatic-login verification stage. It exited 1 with:

```text
The native normal guest automatic-login state could not be verified; Setup Assistant completion was not recorded.
```

The debug sequence included:

```text
Preparing and verifying owner pomme...
createOwner receipt
verifyOwner receipt
globalAutoLoginReadback
loginRestrictions
setupAssistantHandoff
configureLogin
ownerCompletion intent
Restarting normal boot once to initialize fresh-owner preference domains after owner completion status 1.
```

The VM was returned to the stopped state, but the redacted durable `SecurityWorkflowJournal.json` remained at:

```text
operation=sipDisable
phase=autologinIntent
requestedFinalState=stopped
originalRunState=stopped
ownerPreparation=new
accountUsername=pomme
normalBootVerified=false
noMutationNeeded=false
```

The public repair attempt also failed:

```text
rtk pomme agent repair pomme-agent-cli-tahoe-0907 --final-state previous --format json --debug
```

Observed result: exit 1 with `Pomme provisioning journal has an invalid phase transition.` Subsequent AMFI attempts were blocked immediately:

```text
rtk pomme amfi enable pomme-agent-cli-tahoe-0907 --force --final-state stopped --format json --debug
rtk pomme amfi disable pomme-agent-cli-tahoe-0907 --force --final-state stopped --format json --debug
```

Both returned `Another unfinished Pomme security operation owns this VM.`

## Expected result

A failed security transaction should either complete its cleanup and release the VM, or leave a valid transaction that the documented repair/resume path can reconcile. Follow-up security operations should not be permanently blocked by an unusable retained phase.

## Original impact

One failed SIP operation prevented later AMFI operations on the VM. The disposable VM remained stopped and had to be discarded rather than repaired through the public command surface.

## Source review

The security workflow intentionally retains progress after a failure and uses the journal phase to gate subsequent operations. The journal store reports conflicting ownership for unfinished phases. The original diagnostics did not explain the supported security resume command. Source review confirmed that `autologinIntent` is already a valid resumable phase; `agent repair` belongs to the separate provisioning workflow. Its completed-provisioning diagnostic was corrected in commit `481e0f5`.

Relevant files:

- `Sources/PommeCLI/Security/PommeSecurityWorkflow.swift`
- `Sources/PommeCLI/Security/PommeSecurityWorkflowJournal.swift`
- `Sources/PommeCLI/Operations/PommeApplication.swift`
- `Sources/PommeCLI/CLI/PommeCore.swift`

## Resolution

Repeat the same security action with the original `--final-state` to resume the retained transaction. For the reported journal:

```sh
rtk pomme sip disable pomme-agent-cli-tahoe-0907 --final-state stopped --format json --debug
```

The retained fresh-owner authorization makes another `--force` unnecessary at this phase. A retry reuses the exact stored owner credential and verifies the existing account. It skips account creation, reconciles automatic login and owner completion, then proceeds through security verification and final-state restoration. It does not replace credentials or discard the journal.

Security failures and conflicting requests now provide the retained operation's resume command. SIP and AMFI help explain the same-action/same-final-state requirement. Diagnostics preserve the original failure. Incomplete-restoration and failed-cleanup errors remain unwrapped barriers with no resume instruction. Guidance is derived only from a validated, matching, unfinished journal, and requires any previously reported cleanup or restoration failure to be resolved before retrying; the journal alone is not proof of cleanup. A different security operation remains blocked until this transaction completes; agent repair does not take ownership of it.

## Verification

XcodeBuildMCP ran 114 focused tests with 114 passing, zero failures and zero skips: `PommeSecurityWorkflowTests`, `PommeSecurityWorkflowJournalTests`, `PommeSecurityOwnerPreparationTests`, and `PommeSecurityWorkflowResumeGuidanceTests`.

The new durable regression begins at `autologinIntent`, fails owner preparation, proves the journal is unchanged and the original stopped state is requested, rejects AMFI and a different final state, then reopens the same transaction and reaches verified completion. The retained owner and credential reference remain identical; a subsequent AMFI operation is admitted only after completion. Guest effects are injected in this test. Existing concrete owner-preparation tests cover account retry without `-addUser`, partial native preference-write recovery, and already-configured login reconciliation.

Guidance tests cover exact operation/final-state formatting, shell quoting, identity mismatch, terminal-journal exclusion, primary error preservation, and unwrapped restoration/cleanup barriers.

Canonical signed Release build/install passed with the required Developer ID, designated requirement and exact entitlement checks. Installed SHA-256: `7b4b72f51503eff0eaf8905ea5b3025abfc5f40a35b0194f7bbffb55e345dd61`. A fresh login shell resolves `/Users/wes/.local/bin/pomme`.

All 31 CLI integration checks passed against that signed executable, including SIP/AMFI resume help. `git diff --check` passed. The final changes after the focused suite were help strings only, verified by the final build and CLI checks.

The original VM was not modified or retried. Offline coverage verifies journal/state-machine behavior with injected guest effects, not a successful live Tahoe owner-completion retry. If native owner completion continues to fail, the transaction stays retained and the underlying failure remains visible; the resume command does not guarantee that an external guest problem has cleared.
