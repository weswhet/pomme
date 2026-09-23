# CLI audit fixes — 2026-09-08

Follow-up to `CLI-Audit-2026-09-08.md`. Each issue is validated with a signed
Release CLI and live commands, then committed before work on the next issue.

## 1. Background job wait exit status

The control boundary converts JSON integers to Swift `Int64`. The waiter used
an `as? Int` cast and therefore rejected completed jobs whose exit status was
present. It now decodes the JSON integer before narrowing and checking its
range. The same correction applies to signal termination.

The regression fixtures use the transport's actual `Int64` representation;
the prior waiter fails against those fixtures. Tests also reject Boolean,
fractional, string, and out-of-range completion codes.

Validation:

- Xcode: all 17 `PommeGuestJobWaitTests` and
  `PommeAgentProcessExchangeTests` passed.
- `Scripts/build-local.sh`: signed Release build installed with the required
  Developer ID, team, identifier, Hardened Runtime, exact Virtualization
  entitlement, and compatible designated requirement.
- Fixed executable SHA-256:
  `af52e86f538f64c56f6b1ccb870dcf2b88ee7a91c02d74fb4c3b6780c787da65`.
- All 47 CLI integration checks and all 21 local installer checks passed.
- Live comparison uses the disposable 40GB/4GB Tahoe 26.6.0 (25G72) VM
  `pomme-agent-auditfix-0908-c19f2a`, with the original guest agent retained.
  The archived baseline CLI (`7043bcc6221ff280da89a37dd91f474987b37f8cc1e1e4a24d5ed06e8d8b24fd`)
  reproduced the exact missing-exit-status failure for a completed detached job.
  The fixed CLI passed all of these live cases:

  | Command scenario | Observed result |
  | --- | --- |
  | Detached job exits successfully | CLI exit 0, `exitCode: 0`, expected stdout |
  | Detached job exits 7 | CLI exit 7, `hostExitCode: 7`, `exitCode: 7` |
  | Wait after inspect proves job already exited | CLI exit 0 and retained stdout |
  | Wait for a 30-second job with `--timeout 0.2` | CLI exit 124, `timedOut: true`; inspect proves job still running |
  | Wait again for the timed-out job | CLI exit 0 and expected stdout; job was not cancelled |
  | `jobs kill --signal TERM`, then wait | CLI exit 143, `signal: 15`, `timedOut: false` |

## 2. Malformed APFS evidence after fresh owner creation

The first disposable-VM attempt did not reproduce
the audit's malformed-evidence error: owner creation and verification succeeded.
The pre-owner text output reported no cryptographic users on the exact startup
root device, and its plist contained an empty `Users` collection.

The audit's failed-first-attempt/successful-resume behavior is consistent with
temporarily unavailable native APFS evidence, but the original malformed output
was not retained, so its precise cause is not established. The normal-agent
boundary already requires complete process output. All 66 existing
owner-preparation tests pass.

The baseline attempt later failed at normal desktop proof with
`normal-agent-aqua-timedOut` and a creation-pinned agent authentication error.
Post-failure status showed that the visible agent digest still matched the
immutable plan. Read-only APFS diagnostics showed one `Local Open Directory
User` with `Volume Owner: Yes` on the expected root device. This later failure
is separate from the historical malformed-APFS failure.

Tracing that later error confirmed authentication had already succeeded: the
desktop-proof decoder mapped a timed-out authenticated Aqua probe to the
generic identity error. Rejected proof responses now propagate their existing
closed, redacted diagnostic (for example `normal-agent-aqua-timedOut`) without
changing timeout handling, retries, or final-state restoration.

The mitigation re-observes complete read-only evidence after successful fresh
account creation only when APFS parsing reports malformed evidence. It allows
three retries (four total collections), separated by one-second waits, with no
new retry admitted at or after a monotonic 30-second deadline. An already
admitted collection retains the existing per-command timeouts. Initial
freshness, credential authentication, local-account identity, Secure Token,
administrator membership, startup volume, and exact APFS owner matching retain
their existing acceptance rules. Account creation and credentials are never
replayed; persistent malformed evidence still fails closed.

Validation so far:

- All 73 owner-preparation tests pass, including seven new regressions covering
  convergence, persistent failure, initial freshness rejection, unrelated
  evidence failure, cancellation, deadline enforcement, and existing-owner
  verification without retries.
- All 96 combined owner-preparation and normal-agent tests pass, including
  the redacted Aqua timeout diagnostic regression.
- The final signed Release build passed signature/entitlement/requirement
  checks and was installed. SHA-256:
  `790ac9babb8e549c79a84a7564ec75fd428a05aa20cefb2f5543f635160175e8`.
- All 47 CLI contract checks pass.
- Fresh 40GB/4GB Tahoe VM `pomme-agent-sipfix-0908-d27e4b` completed provisioning
  with the initial mitigation build (`8215125a18f7afcb98bc97f74a5a52e7d6f93cc0069d644497c39769addb8b97`).
  The final host build's first `sip disable --force --final-state stopped`
  attempt passed owner creation and APFS verification. It later failed at
  automatic-login verification, retaining `autologinIntent` and restoring the
  VM to stopped. The historical malformed-APFS failure did not recur; native
  execution of the retry branch is therefore unproven, while its recovery and
  fail-closed behavior are covered by the regression tests.
- The documented same-action resume, without journal changes, passed owner
  verification and Setup Assistant completion but failed at the Aqua probe.
  Its public error was correctly `Normal agent verification failed
  (normal-agent-aqua-timedOut).` The VM was restored to stopped, retaining
  `sipDisable`/`autologinIntent` at generation 10.

Result: bounded APFS mitigation and accurate desktop-proof diagnostics are
validated. The precise historical malformed native output remains unknown.
The initial validation was blocked by a separate intermittent Aqua-probe
timeout. The follow-up resume below completed SIP disable successfully.

### Desktop-proof prerequisite investigation

On the retained disposable VM, the exact Aqua probe succeeded through public
`exec` after a cold normal start (0.123 seconds) and after an in-place native
`/sbin/reboot` with a changed guest boot identity and unchanged helper PID
(0.092 seconds). A Dock-service-specific probe also succeeded (0.029 seconds).
All 20 repeated console/Aqua/process-list sequences then passed in 17.969
seconds using the production exact Dock-path predicate. No probe process was
left running. These observations do not establish the cause of the in-workflow
timeouts. The follow-up diagnostic logs only the closed proof stage and strict
Boolean process-state fields (`exited`, `outputComplete`, and
`terminationRequested`); missing or malformed values are reported as unknown.
All 25 normal-agent tests pass, and the signed diagnostic build is
`51e16c95cb9215deebacfe79f9ee881b3a3dd57d253ece64b5649440c0e93e3d`.
Its same-action SIP resume passed automatic-login and desktop verification
without triggering the timeout diagnostic, then advanced to the Recovery SIP
change. The command then completed with exit 0 and verified
`configuredDisabled`, `normalBootVerified`, `runtimeConfigurationVerified`,
`enforcementVerified`, and the requested stopped final state. This successful
resume does not establish the earlier timeout cause, and the added diagnostic
does not change probe behavior.

## 3. AMFI disable wait investigation

The same retained 40GB/4GB VM completed SIP disable before this investigation.
The signed `51e16c95` baseline AMFI status command verified enforcement enabled,
no active AMFI disabling boot argument, and custom boot arguments permitted.
The exact audit disable command completed successfully: it advanced from the
normal-boot message to verification in 46 seconds and restored the stopped
final state. Configuration and runtime configuration were verified; live AMFI
enforcement was not tested. The historical hang did not reproduce.

The investigation found unbounded host control exchanges inside otherwise
bounded normal-agent and helper-start waits. This is an independently proven
deadline gap, not an established cause of the historical hang. A real socket
peer that withholds a complete response reproduced the old collector waiting
until the peer closed: 1.103 seconds, failing the regression limit of 0.5
seconds. The candidate passes remaining monotonic budgets into helper startup
and authentication exchanges, and bounds foreground control collection.
Guest command deadlines remain unchanged; the host permits 15 additional
seconds for cleanup/results. An uncertain AMFI mutation remains unverified
and journaled, without automatic replay.

All 35 focused foreground-control and normal-agent tests pass with the bounded
path, including partial frames and delayed terminal delivery. All 47 CLI
contract checks pass. The canonical signed candidate is
`09771c475e143db2d44017c06f201b196e0974171956ae2ade8ea3a2dd1c0d4c`.
Candidate AMFI enable completed with exit 0, enabled configuration, verified
normal boot/runtime configuration, and verified stopped final state. Its
normal-boot message to verification took 4m42s, including a subsequent Recovery
policy stage; that stage began 18 seconds after the normal-boot message. Live
enforcement was not tested. Candidate AMFI disable then completed its mutating
path with exit 0, disabled configuration, verified normal boot/runtime
configuration, and verified stopped final state. Its normal-boot message to
verification took 56 seconds. Both candidate operations returned structured
results without hanging. The exact historical hang remains unconfirmed; the
reproduced unbounded control wait is now covered by a passing regression.

## 4. Resume rejects an interrupted provisioning intent

On fresh 40GB/4GB Tahoe VM `pomme-agent-resumefix-0908-e38c5d`, creation was
interrupted after the Recovery capability-probe output. Buffered debug delivery
lagged actual progress: the authoritative retained journal had receipts for
installation, first normal boot, Recovery-agent installation, and normal-agent
verification, followed by an open `restoreFinalState` intent at attempt 1.
The VM was already stopped; the journal had generation 10 and nine events.

The signed `09771c47` baseline immediately reproduced the exact public resume
error, `Pomme provisioning journal has an invalid phase transition.` It left
the journal and stopped state unchanged. Separately, a focused regression for
an interrupted Recovery-agent installation intent failed with `unexpectedEvent`
against the unchanged production code; the other 12 provisioning tests passed.

Resume tried to append a new intent while the prior intent remained open.
The fix validates the complete history, then reuses the existing intent and
attempt only for Recovery-agent installation and final-state restoration.
The former reconciles its guest installation journal; the latter proves the
immutable requested state before recording its receipt. Other interrupted
phases remain rejected without effects or journal changes. Plan, ownership,
credential, and pinned executable checks remain intact.

Validation: all 16 provisioning tests and all 47 CLI contract checks pass.
The canonical signed candidate is
`5143586498f9519b6743a485a5a301e5331dd19d3f71d722bd10c9b37d424d3b`.
On the same retained VM/journal rejected by the baseline, candidate resume
returned exit 0 in about four seconds. It preserved the original nine events
and appended only the `restoreFinalState` receipt at attempt 1 (generation 11,
ten events). The original agent pin remained `09771c47`; final state remained
stopped. A second identical resume returned exit 0 without changing the
journal. Recovery-install pending-intent handling is covered by regression
tests and installer reconciliation review; the live interrupted phase was
final-state restoration.

## Disposable lab cleanup notes

The first lab VM was stopped and deleted after the baseline evidence was
captured. Its bundle was removed, but the public delete command reported
`Pomme agent credential removal failed (Security status -25244)`.
The deleted VM UUID is `1ea03a6a-052f-4b66-9867-3bd4a5ea401d`.
Possible orphan credential cleanup remains unverified; no Keychain permissions
were broadened and no credential reset or replacement was attempted.
The SIP/AMFI test VM `pomme-agent-sipfix-0908-d27e4b` was subsequently deleted
through the public CLI with exit 0; its credential cleanup succeeded without
intervention. The five pre-existing VMs remained stopped and unchanged.

The final resume-test VM `pomme-agent-resumefix-0908-e38c5d` was deleted
through the public signed CLI with exit 0 and no credential error. Its owned
empty temporary directory and runtime socket are absent. Final inventory
contains exactly the original five stopped VMs; available capacity is 52 GiB.
No disposable test VM remains. The first deleted VM’s possible orphan Keychain
credential noted above remains unverified.
