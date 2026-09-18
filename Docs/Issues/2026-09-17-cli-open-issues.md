# Open CLI issues after the 2026-09-17 full-surface exploration

- **Status:** All fifteen issues below are open. Nothing was fixed in this pass.
- **Binary under test:** `~/.local/bin/pomme` at commit `06ee394`, SHA-256
  `9885a5ad19571244a6db695fb1ef7c2ebb3bffc7b18acb1a842564ca758bc184`,
  signed Release, Developer ID Application: Wesley Whetstone (2D8XQ77EBQ).
  `pomme --version` → `pomme 0.1.0 (06ee394)`.
- **Fixtures:** three disposable VMs, each 4 GB memory / 40 GB disk, macOS
  26.6.2 build 25G83. `a1` cloned from the `mdmready` template, `a2` and `a3`
  from the `base` template. All three deleted afterwards.
- **Run record:** `../CLI-Exploration-2026-09-17.md`, which lists coverage,
  what was verified working, and what was not covered.
- **Prior records:** `Docs/Issues/2026-09-14-cli-open-issues.md` (all resolved),
  `Docs/CLI-Fixes-2026-09-15.md`, `Docs/CLI-Fixes-2026-09-15-low.md`.

Severity: **High** feature broken, **Medium** wrong or misleading behavior,
**Low** poor message or cosmetic.

---

## 1. A VM can reach a state where it always boots the Recovery picker

- **Severity:** High
- **Status:** Open. The stop path identified below as the likely cause was
  hardened on 2026-09-18; the failure was never reproducible on demand, so
  that is a mitigation, not a proven fix.
- **Area:** lifecycle, `start`

### Reproduction

Not reduced to a deterministic sequence. Observed on two of three VMs after
mixed lifecycle use. The two paths that reached it were:

```sh
# a1 (from the mdmready template)
pomme snapshot create a1 snap1      # taken while the VM was RUNNING
pomme sip status a1                 # Recovery round trip, finalState previous
pomme snapshot restore a1 snap1 --force
pomme resume a1                     # guest still healthy here: exec worked
pomme stop a1
pomme start a1                      # never recovers from here

# a2 (from the base template)
pomme snapshot create a2 s1         # taken while PAUSED
pomme snapshot restore a2 s1 --force
pomme resume a2                     # healthy: exec and shell --detach worked
pomme stop a2
pomme start a2 --mode recovery      # fine
pomme stop a2
pomme start a2                      # never recovers from here
```

Observed from that point on, on every subsequent start:

```text
Error: a1 started but its guest agent did not connect within 300 seconds; the
VM is still running. Run `pomme status` to inspect it.
```

```sh
pomme status a2
# VM running boot=normal helper=true jobs=0
# guestAgent connection=disconnected role=normal protocol= digest= update=unavailable
pomme exec a2 -- /usr/bin/true
# Error: PommeAgent is not connected on port 505051.
pomme agent repair a2
# Error: Nothing to repair for a2: agent provisioning is complete. Agent repair
# does not reconcile SIP or AMFI security transactions.
```

A screenshot of the guest shows the **macOS Recovery startup picker**
(`Macintosh HD`, `Options`, `Shut Down`, `Restart`), not normal macOS, even
though `start` was invoked with no `--mode` and `status` reports
`boot=normal`. `a2` reproduced this on three consecutive starts, each
producing a byte-identical 52,432-byte screenshot, so the state is persistent
in the bundle rather than a transient race.

`a3` was used as a control and could **not** be driven into this state by:
a plain stop/start cycle; a Recovery boot followed by a normal start; a
paused-source snapshot restore followed by stop/start; or a restore followed
by a Recovery boot and a normal start. All four sequences left `a3` healthy.

### Expected result

A `start` with no `--mode` boots normal macOS, or fails loudly saying the VM
is parked at the startup picker. `status` should not report `boot=normal` for
a VM sitting in the Recovery picker.

### Impact

The VM is unusable for every guest operation and cannot be recovered through
the CLI: `start`, `restart`, and `agent repair` all fail or refuse, so the
only remaining action is `delete`. Any snapshot or security work done on that
VM is lost.

### Notes

The bundle after the failure has no `SaveFile.vzvmsave` or
`SnapshotRestore.required` marker left behind, and `Metadata.json` still
records the normal startup volume group. The startup-disk selection lives in
`AuxiliaryStorage` (guest NVRAM), which is the likely carrier, but this was
not confirmed.

### Code investigation (2026-09-17, no fix applied)

What the host asks for is not in doubt. `VMRuntime.startOrRestore`
(`Sources/PommeCLI/VM/VMRuntime.swift:179`) sets
`startUpFromMacOSRecovery = false` for a normal boot, and the helper is
launched with `--mode normal` (`PommeCore.startRuntimeInBackground`,
`Sources/PommeCLI/CLI/PommeCore.swift:3568`). Nothing in the tree writes a
"boot to recovery next" NVRAM variable: the only guest NVRAM write is
`boot-args` for the AMFI override
(`PommeRecoverySecurityOperations.swift:3639`). So a normal cold boot that
lands in the startup picker means the guest firmware no longer has a valid
startup selection, not that Pomme asked for Recovery.

The most likely way Pomme produces that state is its own stop path.

1. **`stop` hard-kills the guest after 30 seconds, silently.**
   `VMRuntime.stop()` (`VMRuntime.swift:203-215`) calls `requestStop`, waits
   `Constants.gracefulStopTimeoutSeconds` (30, `Constants.swift:26`), and
   otherwise calls `forceStop()`, which is `VZVirtualMachine.stop()`
   (`PommeCore.swift:1167`) — an immediate power-cut, not a shutdown. The
   reply is the same either way, so `pomme stop` prints `OK stopped` whether
   the guest shut down cleanly or was killed mid-write.
2. **The code already knows 30 seconds is not enough.**
   `stopForLiveRecovery` (`PommeCore.swift:3307-3331`) documents that "VZ's
   `requestStop` behaves like a power button, which a freshly booted macOS
   guest may take the full graceful window to honor", and therefore asks the
   guest agent to run `/sbin/shutdown -h now` first
   (`requestGuestShutdownThroughHelper`, `PommeCore.swift:2902`). Provisioning
   uses the same agent-driven shutdown. The user-facing `PommeApplication.stop`
   (`PommeApplication.swift:290`) does not: it sends the framework stop
   directly. So the operator's `stop` is the least safe of the three.
3. **A paused VM is always hard-killed.** `VMRuntime.stop()` only attempts
   `requestStop` when `canRequestStop` is true, which VZ reports false while
   paused, so `stop` on a paused VM goes straight to the power-cut.
   `snapshotRestore` also force-stops unconditionally before installing the
   machine state (`PommeApplication.swift:464`).

That fits both failures. `a1` was stopped after being resumed from a stale
RAM image; `a2` was stopped while sitting in recoveryOS, which has no guest
agent and is the case the comment above calls out. An unclean power-off while
macOS is writing its boot state is a plausible way to invalidate the startup
selection; that last step is guest and firmware behavior and cannot be proven
from this repository.

A second, weaker candidate is a race the code guards against everywhere
except the ordinary start path. `waitForLiveRecoveryAuxiliaryStorageRelease`
(`PommeCore.swift:3355`) and `waitForRequiredSnapshotRestoreAuxiliaryStorageRelease`
(`PommeCore.swift:1771`) both wait for the previous helper to release the
auxiliary-storage descriptor before any VZ object is constructed, because
"a helper can report stopped just before Virtualization releases its
auxiliary-storage descriptor" and the runtime record is removed before the
process exits (`runForegroundRuntime`, `PommeCore.swift:3660-3675`).
`startRuntimeInBackground` performs no such wait, so a `start` issued
promptly after a `stop` can construct a new VM on an NVRAM file the exiting
process still owns.

### What was changed on 2026-09-18

The stop path now does what `Docs/CreationPerformance-2026-09-13.md` §3.2
recommended for the public command: ask the guest to shut itself down when the
agent is connected, resume a paused VM so it can, give a normal guest 120
seconds rather than 30, and report a power-off as `stopMethod: forced` with
`OK stopped (forced; the guest did not shut itself down)` instead of a plain
`OK stopped`. Measured on a fresh VM: a running guest now stops in about 7
seconds instead of being power-cut at 31, a paused one in about 2, and a
Recovery stop still forces at 30 seconds but says so.

That removes the mechanism most likely to have produced this failure, and it
makes the next occurrence self-documenting: whichever stop precedes it will
have reported `forced`. It does not prove the issue closed. Still open as
confirmation:

- Hash `AuxiliaryStorage` before and after each stop to see when its contents
  stop matching a bootable selection.
- Watch for a `forced` stop preceding any future occurrence.

---

## 2. Guest commands fail instead of waiting for the agent to connect

- **Severity:** Medium
- **Status:** Open
- **Area:** guest agent

### Reproduction and observed output

```sh
pomme create a1 --from-template mdmready --memory 4GB   # exit 0
pomme agent status a1        # OK agent=connected role=normal
pomme exec a1 -- /usr/bin/true
# Error: Timed out waiting for agent operation Pomme agent exchange.
pomme exec a1 -- /usr/bin/true   # immediately after: exit 0
```

```sh
pomme sip status a1          # ~3 min Recovery round trip, exit 0
pomme remote-login status a1
# Error: PommeAgent is not connected on port 505051.
pomme status a1
# VM running boot=normal helper=true jobs=0
# guestAgent connection=disconnected ...
# recovers on its own about two to four minutes later
```

### Expected result

Either the command waits for the agent within its timeout, or the failure
says the agent is still connecting and is worth retrying. `agent status`
should not report `connected` while the next request times out.

### Impact

Scripts that create a VM or run a security workflow and then immediately use
the guest fail intermittently. The two windows report different messages for
the same underlying condition, so neither is a reliable retry signal.

---

## 3. `exec --timeout` reports a job that does not exist

- **Severity:** Medium
- **Status:** Open
- **Area:** `exec`, `jobs`

### Reproduction and observed output

```sh
pomme exec a1 --timeout 1 -- /bin/sleep 30
# Error: Foreground command timed out; the guest job is still running. Run
# `pomme jobs list <vm>` to find its ID, then `pomme jobs wait` or `pomme jobs kill`.
# exit 124
pomme jobs list a1          # the sleep is absent; only detached jobs are listed
pomme exec a1 -- /bin/ps -axo pid,command | grep sleep   # the sleep is gone
```

### Expected result

Either the job is listed so the documented recovery works, or the message
says the guest process was terminated with the foreground request.

### Impact

The recovery instructions cannot be followed. An operator cannot tell whether
a runaway guest process survived the timeout.

---

## 4. `status` always reports `jobs=0`

- **Severity:** Medium
- **Status:** Open
- **Area:** `status`

### Reproduction and observed output

```sh
pomme exec a1 --detach -- /bin/sleep 60
pomme jobs list a1
# RUNNING 6ddbbb77-d7b5-42d4-9b18-623b763f8fcd pid=709
pomme status a1
# VM running boot=normal helper=true jobs=0
pomme status a1 --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("jobs"))'
# None
```

### Expected result

The count matches the agent's job table, or the field is removed from the
status line and payload.

### Impact

`status` is the natural place to notice background work, and it silently
reports none. The JSON consumer sees no field at all.

---

## 5. `restart` prints only `OK stopped`

- **Severity:** Low
- **Status:** Open
- **Area:** `restart`

### Reproduction and observed output

```sh
pomme restart a2
# OK stopped
# exit 0
```

The VM does start: a following `exec` succeeds. `start` prints
`OK boot mode=normal` for the same work.

### Expected result

The final line reports the boot, as `start` does.

### Likely cause

`restart` builds `steps` as `[status, stop, boot]` and `formatBoot`
(`PommeApplication.swift:3060`) returns the **last** step carrying a
`response` string. The boot step has no `response`, so before 2026-09-15 the
formatter fell through to `OK boot mode=…`. Commit `282fb77` (issue 21 of the
2026-09-14 set) started setting `payload["response"]` on every lifecycle
result, which gave the stop step one; it is now the last match and wins. This
is a regression introduced by that fix, not long-standing behavior.

### Impact

The output says the opposite of what happened. A script that greps for the
boot line sees a stop.

---

## 6. `exec` on a paused VM leaks a transport error

- **Severity:** Low
- **Status:** Open
- **Area:** guest agent

### Reproduction and observed output

```sh
pomme pause a2
pomme exec a2 --timeout 10 -- /usr/bin/true
# Error: vsock setsockopt failed: Bad file descriptor
# exit 1
```

### Expected result

Something like `a2 is paused; resume it before running guest commands.`

### Impact

A normal state, a paused VM, is reported as a socket-level failure.

---

## 7. Guest job, session, and redirection failures are still generic

- **Severity:** Low
- **Status:** Open
- **Area:** `jobs`, `sessions`, `exec`

### Reproduction and observed output

```sh
pomme jobs kill a1 00000000-0000-0000-0000-000000000009
pomme jobs inspect a1 00000000-0000-0000-0000-000000000009
pomme jobs logs a1 00000000-0000-0000-0000-000000000009
pomme jobs wait a1 00000000-0000-0000-0000-000000000009 --timeout 2
# all: Error: Pomme agent request failed (not-found): The requested operation
# could not be completed.

pomme sessions terminate a1 <already-exited-session>
# Error: Pomme agent request failed (operation-failed): The requested operation
# could not be completed.

pomme exec a1 --guest-stdin /tmp/nonexistent -- /bin/cat
# Error: Pomme agent request failed (operation-failed): The requested operation
# could not be completed.
```

### Expected result

The same treatment the executable, working-directory, user, and file-open
paths received on 2026-09-15: name the job ID, say the session already
exited, name the missing redirection path. `RunnerError.guestJobNotFound`
already carries the wording `No detached guest job exists with id <id>.` and
is not used on this path.

### Impact

Three of the remaining generic messages are the ones an operator hits most
often while scripting jobs and sessions.

---

## 8. A read-only guest path is reported as a permission error

- **Severity:** Low
- **Status:** Open
- **Area:** `cp`

### Reproduction and observed output

```sh
pomme cp ./h.txt a1:/h.txt
# Error: Pomme agent request failed (operation-failed): Permission denied: /h.txt
pomme exec a1 -- /usr/bin/touch /x.txt
# touch: /x.txt: Read-only file system
```

### Expected result

`Read-only file system: /h.txt`, matching what the guest itself reports.

### Likely cause

The open-failure diagnosis added on 2026-09-15 classifies an unwritable
parent with `access(parent, W_OK)`, which cannot distinguish `EROFS` from
`EACCES`.

### Impact

On a sealed system volume, which is every guest's `/`, the message points at
permissions the operator cannot change.

---

## 9. Thirty-eight positional arguments have no help text

- **Severity:** Low
- **Status:** Open
- **Area:** help

### Reproduction

```sh
pomme jobs wait --help
# ARGUMENTS:
#   <name>
#   <job-id>
```

The same holds for every `<name>`, `<job-id>`, `<session-id>`, and `<path>`
positional in `jobs` (5 commands), `sessions` (6), `sip`, `amfi` (6), `mdm`,
`remote-login`, `screen-sharing` (6), `config validate`, `config render`,
`ui click`, `ui screenshot`, and `tui`. Enumerated with
`--experimental-dump-help` across all 77 commands: 38 positionals with an
empty abstract, plus `pomme help`'s two arguments.

### Expected result

Each names what it takes, and the `<name>` positionals that accept
`POMME_VM_NAME` say so, as `status`, `inspect`, and `delete` already do.

### Impact

`--help` does not say that most VM-targeted commands can take the VM from
the environment, which is the main way the CLI is scripted.

---

## 10. `agent status` and `agent repair` ignore `POMME_VM_NAME`

- **Severity:** Low
- **Status:** Open
- **Area:** `agent`

### Reproduction and observed output

```sh
export POMME_VM_NAME=a1
pomme status          # works
pomme agent status    # Error: Missing expected argument '<name>', exit 64
pomme agent repair    # Error: Missing expected argument '<name>', exit 64
```

`pomme agent-help` advertises `target=<vm>|POMME_VM_NAME` for the whole
surface, including `agent=status|repair`.

### Expected result

Both honor `POMME_VM_NAME`, like every other VM-targeted command.

### Impact

The two commands an operator reaches for when a VM is misbehaving are the
only ones that reject the environment target their own discovery output
promises.

---

## 11. Option validation exits 1 in some commands and 64 in others

- **Severity:** Low
- **Status:** Open
- **Area:** argument parsing

### Reproduction and observed output

Exit 64, before any VM contact:

```sh
pomme start nosuchvm --timeout 0        # --timeout must be greater than zero.
pomme ipsw list --limit 0               # --limit must be greater than zero.
pomme ui click nosuchvm --x -1 --y 1    # --x must be a finite display coordinate…
pomme cat nosuchvm:/tmp/x --count -1    # --count must not be negative.
```

Exit 1, also before any VM contact:

```sh
pomme jobs kill nosuchvm <uuid> --signal bogus   # Unsupported signal bogus. …
pomme cat nosuchvm:/tmp/x --count 999999         # File read count must be between zero and 32 KiB.
pomme ui ai settings nosuchvm goal --max-steps 0 # ui ai settings --max-steps requires a positive integer.
pomme ui ai settings nosuchvm goal --confidence 2
pomme ui ai settings nosuchvm goal --model-timeout 0
```

### Expected result

One exit code for "the arguments are wrong", which the rest of the CLI
reports as 64. The `--count` upper-bound message should also name the flag,
as its lower-bound sibling does.

### Impact

A wrapper cannot distinguish a usage error from a runtime failure by exit
code alone.

---

## 12. `ui click` accepts out-of-range coordinates

- **Severity:** Low
- **Status:** Open
- **Area:** `ui`

### Reproduction and observed output

```sh
pomme ui click a1 --x 99999 --y 1
# OK
# exit 0
```

The guest display is 1280x800 (`inspect` reports `displayWidth`,
`displayHeight`).

### Expected result

A click outside the display is rejected, or the result says the click was
clamped or dropped.

### Impact

A wrong coordinate reports success, so a failing UI script looks like it is
clicking correctly.

---

## 13. The first screenshot after boot fails until input wakes the display

- **Severity:** Low
- **Status:** Open
- **Area:** `ui screenshot`

### Reproduction and observed output

```sh
pomme create a2 --from-template base --memory 4GB
pomme ui screenshot a2 --output shot.png
# Error: Headless VM automation failed [code=frame_invalid,
# partialInputPossible=false]: The framebuffer was blank.
pomme ui key a2 return
pomme ui screenshot a2 --output shot.png   # OK
```

On `a1` the first attempt failed with `code=frame_timeout … did not publish a
frame before the deadline` and later attempts succeeded.

### Expected result

The capture wakes the display itself, or the message says to send input
first.

### Impact

The documented way to observe a guest fails on a freshly booted VM, which is
exactly when an operator reaches for it.

---

## 14. `agent repair --final-state` has one legal value

- **Severity:** Low
- **Status:** Open
- **Area:** `agent`

### Reproduction and observed output

```sh
pomme agent repair --help
#   --final-state <final-state>
#                           Final VM state: previous. (values: previous; default: previous)
pomme agent repair a1 --final-state stopped
# Error: The value 'stopped' is invalid for '--final-state <final-state>'…
```

### Expected result

Either the option accepts the states `sip`/`amfi` accept, or it is removed
because it cannot change anything.

### Impact

Cosmetic, but it reads like a knob that does not exist, and it diverges from
the identically named option on the security commands.

---

## 15. `create --resume` reports success for a VM with nothing to resume

- **Severity:** Low
- **Status:** Open
- **Area:** `create`

### Reproduction and observed output

```sh
pomme create a1 --resume        # a1 is a complete, stopped VM
# OK resumed Pomme provisioning for a1.
# exit 0
pomme status a1                 # still stopped; nothing happened
```

### Expected result

Something like `a1 is already provisioned; nothing to resume.`, or the same
sentence with a non-success exit code.

### Impact

A resume loop cannot tell a real resume from a no-op.

---

## Verified working on this build

Recorded in `../CLI-Exploration-2026-09-17.md`.
