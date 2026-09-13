# Pomme CLI error reproduction — 2026-09-09

This run removed the existing VM inventory, rebuilt the current signed Release runner, and repeated the previously observed Pomme CLI failures on fresh disposable VMs. No source code or product behavior was changed, and no workaround was applied.

## Setup and cleanup

- Runner: `/Users/wes/.local/bin/pomme`
- Signed Release agent digest: `f807a0b5445a725822ced3a6955ff9458e7cb26575b40febf0b698ebf9b153cc`
- Guest image: macOS 26.6.0, build 25G72
- Disposable VM resources: 40GB disk and 4GB memory
- Initial inventory: five stopped VMs
- Final inventory: `{"ok":true,"vms":[]}`

The initial delete pass returned `Pomme agent credential removal failed (Security status -25244)` for `pomme-agent-files-0908-a6d54e`. The command still removed that VM bundle, and the final inventory was empty. The three repro VMs were subsequently deleted successfully.

## Reproduction results

### SIP disable: reproduced

On a freshly provisioned Tahoe VM, the baseline status command passed and verified SIP enabled. The first disable attempt returned exit 1 after owner preparation:

```text
rtk pomme sip disable pomme-repro-tahoe-0909 --force --final-state stopped --format json --debug
Error: The native normal guest automatic-login state could not be verified; Setup Assistant completion was not recorded. Resume the retained security operation with `pomme sip disable 'pomme-repro-tahoe-0909' --final-state stopped` after resolving any reported cleanup or restoration failure; the operation and final state must match the retained transaction.
```

The documented same-action resume was then attempted. It also returned exit 1, this time with:

```text
Error: Normal agent verification failed (normal-agent-aqua-timedOut). Resume the retained security operation with `pomme sip disable 'pomme-repro-tahoe-0909' --final-state stopped` after resolving any reported cleanup or restoration failure; the operation and final state must match the retained transaction.
```

The SIP workflow failure therefore still reproduces on a fresh VM and on the current rebuilt runner. The exact verification failure is state-sensitive across attempts, and the supported resume did not recover it in this run.

### AMFI disable: reproduced

On a separate freshly provisioned Tahoe VM, AMFI status passed with `amfiDisabled: false` and `amfiBootArgActive: false`. The exact disable vector then failed to return:

```text
rtk pomme amfi disable pomme-repro-amfi-0909 --force --final-state stopped --format json --debug
```

After approximately six minutes, `pomme status` reported `vmState: stopped` and `helperRunning: false`, while the Pomme AMFI process was still alive and had produced no result. The debug workflow had reached the Recovery boot-argument-change path. The test process was terminated only to prevent an orphaned CLI process. This reproduces the earlier AMFI hang on a clean VM without a preceding SIP mutation.

### AMFI workflow comparison

Source inspection confirms that `pomme amfi disable` is intended to perform the complete AMFI-specific sequence: verify the AMFI state and SIP prerequisite, journal the operation, prepare and verify the owner, change LocalPolicy in authenticated Recovery, write the exact AMFI boot-argument change through the normal agent, reboot and verify the result, then restore the requested VM run state. The MDM workflow invokes this same `amfiWorkflow` child after disabling SIP when necessary.

The workflows still have different responsibilities. Standalone AMFI disable requires SIP to already be disabled for a real change and leaves AMFI disabled as requested. MDM captures the original SIP/AMFI baseline, disables SIP and AMFI for enrollment, then restores both settings and verifies the original baseline after enrollment. The reproduced AMFI hang occurs inside the shared child path, before the standalone command published success or completed normal-boot verification, so the implementation is complete by design but not completing reliably at runtime.

The create-config `workflow.disableAMFI` field is not an active alternative: create-config validation rejects all `workflow` controls and directs callers to explicit operations.

### Background-job wait: not reproduced

Detached jobs, listing, inspection, and logs all passed. Both wait probes also passed on the rebuilt runner:

```text
rtk pomme jobs wait pomme-repro-tahoe-0909 c22b26e7-9138-4643-982d-f8b1c6f085a0 --timeout 5 --format json --debug
exit 0, exitCode 0

rtk pomme jobs wait pomme-repro-tahoe-0909 e390d68f-e52e-4e89-b33d-e88f31323b09 --timeout 8 --format json --debug
exit 0, exitCode 0
```

The first job was already complete when waited on; the second was still running when the wait request started. The earlier `Missing background job exit status` error did not recur.

### Provisioning resume: not reproduced

A controlled fresh creation was allowed to reach `Recovery bootstrap milestone: capabilityProbeVerified`, then the creator was interrupted with Ctrl-C. The interrupted VM was stopped and its creator exited 130. The documented resume command then completed successfully:

```text
rtk pomme create pomme-repro-resume-0909 --resume --format json --debug
exit 0
operation: create-resume
```

The resumed VM subsequently booted normally and authenticated its agent. The earlier `Pomme provisioning journal has an invalid phase transition` error did not recur on the current rebuilt runner.

## Final state

All repro VMs were stopped and deleted. The VM inventory is empty. No source files were modified, and no issue was fixed during the reproduction run.
