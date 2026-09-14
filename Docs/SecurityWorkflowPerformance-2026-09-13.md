# SIP and AMFI workflow speed evaluation (2026-09-13)

Evaluation only; no product code was changed. Binary under test:
`~/.local/bin/pomme` at `1ae7380` (SHA-256
`6deab02e2189fd0e6f114d31aa195f2f6060e701efa7c8317c1ffaacdb558a5a`), which is
also the agent digest pinned by the test VM. Host: Mac mini M1, 16 GB, load
average 3.8 to 5.4, 4.2 GB of 5 GB swap in use. Guest: `tvm3`, macOS 26.6.2
(25G83), template-sourced, 40 GB / 4 GB, stopped before the run.

The question was whether the `sip` and `amfi` subcommands do avoidable work.
They do. The cost is almost entirely the number of VM boots each command
performs, not the speed of any one step. Every Recovery entry is a full
request-bound session (boot recoveryOS, navigate to Terminal, type the probe
and launcher, authenticate, operate, stop), and the workflows enter Recovery
two to three times per mutation when one entry is required.

## 1. Measured cost of one Recovery session

`pomme sip status tvm3 --final-state previous --json --debug`, from stopped,
stderr timestamped with a monotonic clock. This is the first measurement since
the September 13 typing change (`5f67b05`); the September 6 figures in
`RecoveryNavigationPerformance-2026-09-06.md` predate it.

| From | To | Phase | Duration |
|---|---|---|---|
| 0.0 s | 0.4 s | Request validated, staging prepared, VZ runtime started | 0.4 s |
| 0.4 s | 86.4 s | recoveryOS boot and navigation to Terminal (5 keys, 327 captures) | 86.0 s |
| 86.4 s | 96.1 s | Capability probe typed and marker proven (2 attempts) | 9.7 s |
| 96.1 s | 105.2 s | Launcher typed | 9.1 s |
| 105.2 s | 105.9 s | Launcher runs, Recovery agent authenticates (host staging cleared in the same second) | < 1 s |
| 105.9 s | 136.0 s | `csrutil status`, teardown, Recovery guest stop, cleanup, final-state proof | 30.1 s |
| | | **Total** | **136.1 s** |

Navigation counters: 327 captures (13.6 s), 326 hashes (0.8 s), 21
classifications (3.4 s), 59 OCR requests (3.3 s), 5 inputs (0.6 s), 319 waits
(67.9 s). Navigation is guest-bound, as the creation evaluation found.

The final 30 s window has no milestone inside it. Two facts bound it: the host
staging root was removed at 20:00:59Z, which `LiveGuestPort.perform` does only
after the guest session has authenticated, and `Disk.img` was last written at
20:01:27Z, three seconds before the command exited. The operation itself is
one `csrutil status`. The remaining 25 to 28 s is consistent with
`PommeRecoveryRuntimeResources.stopReapAndClean` calling `runtime.stop()`,
which issues `requestStop` and waits up to `gracefulStopTimeoutSeconds` (30 s)
before forcing (`VMRuntime.swift:200`). recoveryOS does not act on the
framework's stop request the way a booted desktop does, the same behavior the
creation evaluation recorded for a guest at Setup Assistant. Confirm by adding
a `runtimeStopped` milestone before changing it.

Other unit costs used below, from earlier records rather than this run: a
normal boot to agent connection is about 15 s (`CreationPerformance-2026-09-13.md`
section 8); a native reboot through `rebootAndAuthenticate` is roughly one
normal boot plus authentication; stopping a booted desktop guest through the
helper is a few seconds, and a guest still at Setup Assistant takes the full
30 s window because the helper's stop path has no agent-driven shutdown
(`PommeCore.swift:3560`; only the in-process provisioning runtime received
that in `5f67b05`).

## 2. Boot sequence per command

Existing owner with a saved credential, VM running normal at the start,
`--final-state previous`. R = one Recovery session (136 s today), N = normal
boot to authenticated agent, S = stop of a normal guest, ↻ = native reboot.

| Command | Sequence | R | N/↻ | Estimated today |
|---|---|---|---|---|
| `sip status`, `amfi status` | S, R(status), N | 1 | 1 | ~2.7 min (136 s from stopped) |
| `sip disable` / `enable` | S, R(status), N(owner), S, R(mutate), N(verify) | 2 | 2 | ~5.5 min |
| `amfi disable` | S, R(amfi.status), R(sip.status), N(owner), S, R(policy), N(NVRAM write), ↻, ↻, verify | 3 | 4 | ~8.5 min |
| `amfi enable` | S, R(amfi.status), R(sip.status), N(owner), NVRAM write, ↻, S, R(policy), N, ↻, verify | 3 | 4 | ~8.5 min |

Where each step comes from:

- `PommeSecurityRecoveryAdapter.execute` builds a new integration per call, so
  `observe`, `requireSIPDisabled`, and `mutate` are each a complete Recovery
  session ending stopped (`PommeSecurityRecoveryAdapter.swift:56`).
- `PommeSecurityAMFIPreflight.inspect` always calls `requireSIPDisabled` unless
  the request is already a no-op, so a real AMFI change pays two Recovery
  sessions before owner preparation.
- `PommeSecurityWorkflowLive.runLive`: `changeNormalBootArguments` ends with
  `rebootAndAuthenticate`; `verifyNormalBoot` for AMFI then calls
  `rebootAndAuthenticate` again. For disable that is two consecutive native
  reboots with no Recovery transition between them. For enable, the VM is
  stopped after the Recovery policy stage, `restoreStableVMRunState(.running(.normal))`
  performs a fresh boot, and the verify step reboots that fresh boot again.
- `sip status` and `amfi status` go straight to a Recovery session in
  `PommeApplication.sipWorkflow` / `amfiWorkflow`.
- MDM enrollment runs `sip disable`, `amfi disable`, `amfi enable`, and
  `sip enable` as children, plus its own `recovery.observe(.amfiDisable)`
  calls, so every saving below applies several times per enrollment.

## 3. Recommendations, ordered by payoff ÷ effort

### 3.1 Stop the Recovery guest without waiting out the graceful window (~25 s per session, every command, host only)

`stopReapAndClean` should not use the desktop stop path for a Recovery
runtime. For `sip.*` nothing is mounted and the request workspace lives on the
Recovery ramdisk, so a force stop loses nothing; the credential and launcher
vanish with the guest, and the cleanup evidence is host-side. For `amfi.*`
the agent mounts the Data volume through `PommeRecoveryDataVolumeResolver` and
never unmounts it, so either unmount it in the guest after the receipt or
accept an APFS journal replay on the next boot. A guest-side alternative is
for the Recovery agent to halt after its receipt is acknowledged, but that is
a pinned-agent change and only new VMs would benefit. Add `agentAuthenticated`,
`operationComplete`, `runtimeStopped`, and `finalStateProven` milestones first
so the 30 s window is attributed rather than inferred.

### 3.2 Observe SIP through the normal agent (removes one Recovery session from every `sip enable`/`disable`; host only)

`PommeSecurityRecoveryAdapter.observe` for a SIP operation can run
`csrutil status` through `PommeSecurityNormalAgent.execute`; the exact-match
parse already exists in `verifyNormalSecurity`. The workflow boots normal for
`prepareOwner` immediately after observing, so when the VM starts stopped the
boot is moved, not added, and when it starts running normal the observation
costs a few seconds. The state-first rule survives: agent authentication does
not require owner credentials. Precedent: `observeMDMNormalSecurity` already
uses the normal agent's `csrutil status` as the MDM baseline, and every SIP
workflow's final proof is this same normal-boot read. Existing pinned agents
already support `process.start`, so no VM needs recreating.

`SecurityWorkflows.md` states that status observes through Recovery, and the
public `sip status` result carries Recovery evidence (request ID, lifecycle,
cleanup flags). Change the workflow-internal observe first, which alters no
public output; whether `sip status` itself should become a normal-agent read
(a few seconds on a running VM, ~20 s from stopped, versus 136 s) is a
contract decision.

### 3.3 Check the AMFI SIP prerequisite through the normal agent (removes one Recovery session from every `amfi enable`/`disable`; host only)

`requireSIPDisabled` exists to guard the normal-boot NVRAM write, and the
effective SIP state of the normal boot is exactly what governs that write. The
same `csrutil status` read replaces the second Recovery session. The preflight
order in `PommeSecurityAMFIPreflight.inspectRetained` is unchanged; only the
injected `requireSIPDisabled` closure changes.

### 3.4 Drop the duplicate reboot before AMFI normal-boot verification (one native reboot per `amfi enable`/`disable`; host only)

In `runLive`, make the `verifyNormalBoot` reboot conditional. For disable, the
preceding `changeNormalBootArguments` has just proven a changed boot identity
in this process; verify the effective arguments on that boot. For enable, skip
the reboot when `restoreStableVMRunState` actually started the VM from stopped.
Keep the reboot on the retry path where the VM was already running when
verification began, which is the case the reboot exists for. The
`PommeSecurityAMFIStages` tests inject `changeBootArguments`, so the stage
contract does not change; the affected code is the live composition.

### 3.5 AMFI status through the normal agent (removes the last non-mutating Recovery session from AMFI; pinned-agent change, new VMs and templates only)

Add an `amfi.normal.status` operation that reuses the body of
`amfiStatusResult` with `normalSnapshotStore`. `captureAMFIState`, including
`bputil --json --display-policy`, already runs in normal mode for
`amfi.normal.verifyDisabled`. Gate it behind `normalAMFIWorkflowVersion` 2 so
older pinned agents fail explicitly rather than silently. With this, `amfi
status` on a running VM is seconds, and an AMFI mutation enters Recovery
exactly once, for the LocalPolicy write it genuinely needs.

### 3.6 Smaller items

- `stopForLiveRecovery` and the helper's `stop` command should ask a connected
  normal agent for `shutdown -h now` before `requestStop`, as provisioning now
  does. A fresh VM at Setup Assistant otherwise burns 30 s before each Recovery
  entry during the fresh-owner path.
- Navigation (86 s) is guest-bound: 68 s of the 86 s is explicit waiting on
  the guest, capture is 14 s, OCR is 3 s. The NVRAM shortcuts were tested and
  rejected on September 13. The only untested host-side lever is the Recovery
  VM's vCPU count.
- Probe and launcher typing (19 s) has already been cut from ~100 s; further
  gains need shorter strings, not faster keys.

## 4. Expected effect

Estimates for the section 2 scenario, using 108 s per Recovery session after
3.1 and the unit costs above. They are arithmetic on measured phases, not
measurements of the changed code.

| Command | Today | With 3.1 to 3.4 | With 3.5 as well |
|---|---|---|---|
| `sip status` | ~2.7 min | ~2.2 min (seconds if status moves to the normal agent) | same |
| `sip disable` / `enable` | ~5.5 min | ~2.4 min | same |
| `amfi status` | ~2.7 min | ~2.2 min | seconds |
| `amfi disable` / `enable` | ~8.5 min | ~5.0 min | ~2.8 min |

MDM enrollment on a stock VM runs four of these workflows and would drop by
roughly the sum.

## 5. Verification and cleanup

The measured run returned `sipEnabled: true`, an authenticated request-bound
consumed credential, a finalized lifecycle, every cleanup flag true, and
`finalStateVerified: true` with the VM back at stopped. No security policy was
changed. The timing log is in the session scratchpad and was not added to the
repository.

## 6. Implementation results (3.2, 3.3, 3.4, 3.5, 3.6)

All five host-side recommendations and the pinned-agent one are implemented.

`amfi.normal.status` (3.5) is advertised separately from the four staging
operations, so an agent pinned before it keeps working for AMFI disable and
enable and only the status read observes through Recovery. The host preflights
the additive describe receipt and, when it declines, logs a closed reason
rather than silently spending a Recovery session.

Adding a guest operation is not enough on its own: the helper's
`agent.perform` forwarding allowlist is closed, so both new operations had to
be named in it. Until they were, the host saw a transport failure and observed
through Recovery, which is the safe outcome but hid the cause. That is what
the decline diagnostic now reports.

Measured live on a VM cloned from a provisioned template, enrolling with a
deliberately nonexistent MDM server so only the security path is under test:

| | Before 3.5 | After 3.5 |
| --- | ---: | ---: |
| AMFI baseline read | 170 s (Recovery session) | 5.5 s (normal agent) |
| Recovery sessions in an enrollment | 1 | 0 |
| Security child workflows | 0 | 0 |
| Reached the enrollment helper at | 251 s | 54 s |
| Complete command | 317 s | 121 s |

Both runs reported the same baseline, `sipDisabled=true, amfiDisabled=true,
baselinePresent=true, phase=disabledVerified, reconciliationRequired=false`,
verified the enrollment helper's signature and entitlements, failed only at the
unreachable server, and restored security and run state.
