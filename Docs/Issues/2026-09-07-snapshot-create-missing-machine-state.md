# Snapshot creation fails because the saved-state artifact is missing

- **Severity:** High
- **Status:** Resolved and live verified
- **Area:** Named snapshots
- **Observed on:** Pomme 0.1.0 signed Release build; normal Tahoe 26.6.0 / 25G72 VM

## Reproduction

The VM was running in normal mode and `snapshot list` returned an empty list.

```text
rtk pomme snapshot create pomme-agent-cli-tahoe-0907 cli-snap-0907 --format json --debug
```

Observed result: exit 1 with:

```text
Snapshot is missing a regular MachineState.vzvmsave artifact.
```

The command left no named snapshot, so restore and delete could only be exercised against a missing name and could not reach a successful snapshot prerequisite.

## Expected result

The running normal VM should be paused, its saved state should be captured into the staging directory, and the named snapshot should be published with its manifest.

## Impact

No snapshot can be created through the public command, so successful restore and delete paths are unreachable from a clean VM.

## Source evidence

`PommeApplication.snapshotCreate` pauses the VM and sends the `snapshot-save` control command before calling `VMSnapshotStore.complete`. `complete` requires a regular `MachineState.vzvmsave` file. The tested control path returned without producing that required artifact.

Relevant files:

- `Sources/PommeCLI/Operations/PommeApplication.swift`
- `Sources/PommeCLI/VM/VMRuntime.swift`
- `Sources/PommeCLI/VM/VMSnapshotStore.swift`


## Root cause and fix

The typed control router accepted `snapshot-save`, but the runtime dispatcher rejected it as an unavailable capability. That failure was encoded as an inner `ok: false` payload inside a successful control response. The application ignored the payload and attempted snapshot publication, masking the real failure as a missing artifact.

The dispatcher now awaits `saveSnapshotMachineState(in:)`, which validates the paused normal VM and confined stage, checks save/restore support, and waits for Virtualization's save completion before acknowledging success.

Both snapshot creation and restore's rollback capture now require an explicit successful `snapshot-save` completion receipt and a nonempty regular state file. Helper failures remain visible. A missing, empty, or symlink artifact cannot be used to publish a snapshot or mark rollback as captured before stopping the original VM.

The first live cycle verified both snapshot captures but exposed another unfinished route: `startRequiredSnapshotRestorePayload` sent `resume` to the helper that restore had just stopped. It never launched a helper to consume the required saved state. This path now waits for the previous helper to exit, starts a normal helper, and verifies a successful paused-normal state. It does not take a cold-boot fallback. Snapshot pause/resume/stop responses are also checked before advancing workflow state.

Successful required restoration now durably removes the consumed state file before clearing its required marker. Native restore failures retain the artifacts. A required marker without its state file refuses cold startup, including after interrupted cleanup. Helper replacement also checks that auxiliary storage is no longer locked by the old runtime.

## Verification

All 35 final focused Xcode tests passed, with zero failures or skips: capture receipts/artifacts, snapshot store, pause/resume transitions, snapshot CLI grammar, restore startup, and control wire behavior. New tests cover preserved native failure messages, incomplete acknowledgements, missing/empty/symlink artifacts, a valid capture, rejected lifecycle failures, launching exactly one restore helper, and rejecting failed or inactive helper receipts.

Canonical signed Release build/install passed the required identity, designated-requirement and entitlement checks. Final installed SHA-256: `182db3e3310c079b08618fab6cc0e5599b1562ecda3e29a8be78d1a08cd50e3f`. A fresh login shell resolves `/Users/wes/.local/bin/pomme`; all 31 CLI integration checks passed against it.

Scoped live validation completed on `pomme-agent-snapshot-0908-2c674e`, UUID `d4a02559-7699-42dd-8ea2-37684b7a6a2e`, newly created with Tahoe 26.6.0/25G72, 40GB disk and 4GB memory. The guest remains pinned to signed build `309353a733244d81b199652e465c455008eab00e3120d64c3fc6049825175eec`; this fix runs in the host helper.

### Initial live cycle

Both captures succeeded with host build `10f42f6…`: `running-capture` wrote 1,610,616,832 bytes in 8.45 seconds and left the VM running; `paused-capture` wrote 1,577,062,400 bytes in 8.97 seconds and left it paused. Forced restore then exposed the missing helper-launch implementation; it failed and retained both captures and rollback artifacts. Public status and stop confirmed the VM was stopped. No manual state-file or journal changes were made.

A second live pass with build `12dbbd1…` proved startup into the required paused state, but then exposed stale consumed-state artifacts blocking a subsequent restore. The final build adds success-only consumption and passed the complete retry cycle below.

### Final live cycle

With signed host build `182db3e…`, public normal start consumed the retained state in 3.50 seconds and returned paused. Both `SaveFile.vzvmsave` and `SnapshotRestore.required` were verified absent through read-only file checks. Forced restore of `running-capture` then succeeded in 13.88 seconds, returned paused, and again left neither consumed artifact. The disposable test explicitly accepted the recorded disk/auxiliary-storage drift with `--force`; it does not establish that drifting filesystems are generally safe to restore.

Resume succeeded; the guest reauthenticated against its unchanged pinned agent; `/usr/bin/true` exited 0. Deleting `running-capture` and `paused-capture` both succeeded, and snapshot list returned `[]`. Public stop and status verified the VM stopped, boot mode none, and helper not running. Other lab VMs remained stopped and untouched.

The VM is retained. Rollback stages from the failed intermediate attempts were left untouched for diagnosis; no saved-state, journal, credential, or security state was manually changed. Each empty assignment temporary directory was removed and its absence verified. `git diff --check` passed.
