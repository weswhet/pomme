# VM creation and Recovery navigation — speed evaluation (2026-09-13)

Evaluation only; no code was changed. Binary under test: `~/.local/bin/pomme` at
`48dc617` (Recovery-direct provisioning, four phases). Host: Mac mini M1
(`Macmini9,1`, 4P+4E cores, 16 GB). Guest: macOS 26.6.2 (25G83) from the cached
IPSW, 40 GB disk, 4 GB memory.

Apple documentation was read from sosumi.ai renderings of developer.apple.com
(the sosumi MCP server is not attached to this session) and, where sosumi
omitted the discussion text, from the Virtualization.framework headers in the
macOS 26.5 SDK. Quotes below are verbatim from those sources.

## 1. Measured baseline (`testvm`, 8 min 50 s)

| From | To | Phase | Duration |
|---|---|---|---|
| 07:15:22 | 07:15:34 | Plan: SHA-256 of the 19.7 GB IPSW (pass 1) | 12 s |
| 07:15:34 | 07:15:46 | Install phase start: SHA-256 of the IPSW again (pass 2) | 12 s |
| 07:15:46 | 07:19:42 | `VZMacOSInstaller` restore (0 % → 100 %) | 236 s |
| 07:19:42 | 07:19:43 | Recovery runtime constructed and started | 1 s |
| 07:19:43 | 07:21:15 | Recovery navigation to Terminal (5 keys, 210 frame captures) | 92 s |
| 07:21:15 | 07:22:10 | Capability probe typed (238 chars) + marker OCR | 55 s |
| 07:22:11 | 07:22:56 | Launcher typed (~196 chars) | 45 s |
| 07:22:56 | 07:23:27 | Guest installer runs, Recovery VM stops, normal boot, agent connects | 31 s |
| 07:23:27 | 07:24:12 | Agent verified (instant), graceful stop **times out at 30 s**, force stop, journal | 45 s |

Sources: `create-testvm.log` timestamps, `.pomme/input-v1.json` /
`provisioning-v1.json` mtimes, `TerminalSessions/<vm>` directory mtime (agent
first connect), and the `Recovery performance` counters in the log.

### Host conditions during the measurements (important caveat)

- Load average 4.75–6.14 on 8 cores; `rustc` at 79 % CPU.
- Swap: 8.5 GB of 9.2 GB used; 1.27 M pageouts.
- PID 1995 is a `com.apple.Virtualization.VirtualMachine` XPC service that has
  been running for **8 days 17 h** with ~6 GB resident, parent `launchd`
  (its owner exited), no disk image open — an orphan, plus the `devme` VM.
- Consequence: **every timer sleep overshoots ~7×** on this host right now
  (probe: `usleep(8 ms)` → 55 ms, `Task.sleep(20 ms)` → 143 ms, independent
  of QoS/`taskpolicy`). This inflates the per-keystroke cost and the polling
  loops below. The structural findings stand; absolute savings will be smaller
  on an idle host, but the ratios do not change.

Recommendation before re-measuring anything: `kill 1995` and re-run one create.

## 2. Where the time goes and what is avoidable

| Cost | Cause | Avoidable? |
|---|---|---|
| 24 s | IPSW hashed twice (`sha256File` in `createVMPayload` and again in `verifyRestoreImageDigest`) | Yes — hash once, cache by file identity |
| 236 s | IPSW restore with `synchronizationMode = .full` (runtime-verified default), 4 vCPUs of 8 | Partly — sync mode, CPU count; fully only with a template clone |
| ~100 s | ~1,030 HID events with a sleep after **each** event (20 ms key-down dwell, 8 ms otherwise) for 434 typed characters; each sleep costs ~80 ms on this host | Yes — sleep per character/chord, batch events, shorter commands |
| 30 s | `requestStop` after the verification boot is ignored by a guest sitting in Setup Assistant; `Constants.gracefulStopTimeoutSeconds` elapses, then force stop (measured 31 s for `pomme stop`) | Yes — agent-driven shutdown or force stop during provisioning |
| ~40 s | `verifyNormalAgent` boots, verifies, stops; `restoreProvisioningState(.normalRunning)` boots again | Yes — keep the verified runtime when the final state is `normal` |
| ~15 s of 92 s | Navigation tool overhead: each capture blocks until the guest publishes a *new* frame (~207 ms here), 100 ms poll, 2 s classification cool-down | Partly |
| ~77 s of 92 s | Guest-bound: recoveryOS boot to the startup-options picker, language chooser, Recovery app, Terminal launch | Only via vCPU count, NVRAM shortcuts on later entries, or not entering Recovery |

## 3. Recommendations for initial VM creation (ordered by payoff ÷ effort)

### 3.1 Stop sleeping after every HID event (~100 s → ~10 s)

`VirtualizationPrivateHeadlessBackend.dispatchKeyPlan` sends one `_VZKeyEvent`
per HID event and then `Task.sleep`s `keyDownDwellNanoseconds` (20 ms) or
`transitionGapNanoseconds` (8 ms). A plain character is 2 events; a shifted
one is 4. The probe (238 chars) and launcher (~196 chars) produce ~1,030
events. Measured with `pomme ui type` on `testvm`: 170 ms per plain
character, 332 ms per shifted character → ~80 ms per event, i.e. the sleep,
not the send, dominates (sampling the helper showed the typing task off-CPU
almost the entire time).

Options, compatible with the existing input contract:

- Sleep once per character (after key-up) instead of after every event, or
  hand the whole chord to `sendKeyEvents:` in one call — the private selector
  already takes an `NSArray`; the code passes a one-element array.
- Shorten what is typed. The probe checks `/bin/sh`, four `test -x`, and a
  64-hex known vector; a `case "$($p/sha256 -q …)" in ba7816bf*` style check
  keeps the intent in ~60 characters. The launcher's 36-char UUID tag
  (`pomme-` + 24 hex), `/private/var/run/.pomme-vfs-<id>` workspace and
  `pomme-recovery-launcher` filename are all keystrokes; 8-char tag and
  workspace and a one-letter launcher name cut it to ~80 characters with the
  same read-only-mount, copy-out-then-exec, marker-proof design.
- There is no public API for HID injection (Apple's only supported input path
  is `VZVirtualMachineView`), so the safe cadence is empirical; today's 20/8 ms
  values are already generous compared with real keyboards.

### 3.2 Do not wait 30 s for a graceful stop the guest ignores (~28 s)

`restoreProvisioningState` → `stopRetainedRuntime` → `VMRuntime.stop()` calls
`requestStop()` and waits `gracefulStopTimeoutSeconds` (30 s). A freshly
installed guest at Setup Assistant does not act on it (measured: `pomme stop
testvm` = 31 s). At that point the agent is connected and has `process.start`,
so the host can run `shutdown -h now` in the guest (~3–5 s), or simply force
stop a VM that holds no user data yet. The same applies to the public `stop`
command: prefer an agent-driven shutdown when the agent is connected, keep
`requestStop` as the fallback.

### 3.3 Merge the verification boot with the requested final state (~40 s when `--boot normal`)

`verifyNormalAgent` boots normal, verifies, and `restoreProvisioningState`
stops it before booting again for `.normalRunning`. Keeping the verified
runtime alive when the final state is `normal` removes a stop+boot. (Today
`--boot normal` ends stopped anyway — item 3 in `CLI-Exploration-2026-09-12.md`.)

### 3.4 Hash the IPSW once (12 s; 24 s with a cache)

Both passes run at ~1.6 GB/s, close to the M1's SHA-256 ceiling, so the win is
removing passes, not speeding one up:

- Compute the digest while downloading (the bytes are streamed anyway) and
  store it in a sidecar keyed by `(dev, inode, size, mtime)`; `verifyRestoreImageDigest`
  re-hashes only when the identity changed.
- Within one `create`, pass the digest just computed for the plan into the
  install phase instead of re-verifying (keep the full check for `--resume`,
  which runs in a new process).
- Minor: `sha256File` copies every 1 MiB chunk into a new `Data`; use
  `hasher.update(bufferPointer:)` with 4–8 MiB reads.

### 3.5 Install-phase VM configuration (measure; plausible 30–60 s of the 236 s)

`makeRuntimeConfiguration` is shared by the installer and every later boot:

- **Disk synchronization mode.** The attachment is created with
  `init(url:readOnly:)`; at runtime that yields `cachingMode = .automatic` and
  `synchronizationMode = .full` (verified with a probe). Apple's header on
  `VZDiskImageSynchronizationMode`:
  - `.full`: "The data is synchronized to the permanent storage holding the
    disk image. No synchronized data is lost on panic or loss of power."
  - `.fsync`: "Synchronize the data to the drive. This mode synchronizes the
    data with the drive, but does not ensure the data is moved from the disk's
    internal cache to permanent storage. This is a best-effort mode with the
    same guarantees as the fsync() system call."
  - `.none`: "Do not synchronize the data with the permanent storage. … This
    mode is useful when a virtual machine is only run once to perform a task to
    completion or failure. In that case, the disk image cannot safely be
    reused on failure. Using this mode may result in improved performance
    since no synchronization with the underlying storage is necessary."
  The install phase matches `.none`'s description exactly (a failed install
  is re-run from scratch). Every guest flush during the ~22 GB restore is an
  `F_FULLFSYNC` today. For normal runtime `.fsync` is a reasonable default,
  with `.full` behind an option for anyone who needs power-loss durability of
  guest data. Available since macOS 12 via
  `init(url:readOnly:cachingMode:synchronizationMode:)`.
- **CPU count.** `cpuCount = min(max(4, minimumAllowedCPUCount), maximumAllowedCPUCount)`
  → 4 on this 8-core host (`maximumAllowedCPUCount` reports 64). Apple:
  `VZMacOSInstaller` needs only a stopped VM whose configuration meets
  `mostFeaturefulSupportedConfiguration` — "The following are minimum values;
  you can use larger values if desired." Give the installer VM
  `activeProcessorCount` CPUs; the installed OS does not persist the count.
- **Memory.** The install configuration is not persisted either; more RAM for
  the installer VM is safe when the host has it (not on this 16 GB host under
  today's pressure).

### 3.6 Templates instead of restores (the only way past the 4-minute floor)

An IPSW restore cannot be made much faster than ~3–4 minutes. The way other
tools (Tart, etc.) get seconds-long creates is cloning a prepared image. Two
levels:

1. **Installed-but-unprovisioned template.** After the install phase, keep a
   golden `Disk.img` + `AuxiliaryStorage` + `HardwareModel` per (build, disk
   size). A create becomes an APFS clone (`clonefile`, copy-on-write, <1 s)
   followed by the existing Recovery bootstrap. Apple on auxiliary storage:
   "When moving or performing a backup of a VM, you must move or copy the file
   containing the auxiliary storage along with the main disk image", and the
   hardware model "must match the hardware model used when creating the
   original file". On the machine identifier: "The Mac machine identifier is
   used by macOS guests to uniquely identify the virtual hardware. Two virtual
   machines running concurrently should not use the same identifier." Apple
   does not say whether an installed image boots under a *new* identifier; it
   must be tested. If it does, clones get fresh identities (important for
   MDM/serial-number work); if not, clones share identity and must not run
   concurrently.
2. **Provisioned template.** Clone after the agent is installed and verified.
   Create becomes clone + one verification boot (~1 min). Needs a credential
   rotation step: the guest carries the template's `/private/var/db/pomme/agent.token`
   and the host Keychain item is UUID-scoped, so the normal agent needs a
   "rotate credential" operation on first boot of a clone (it already has
   `maintenance.*` capabilities), and the journal needs a "cloned from template
   digest" provenance instead of an IPSW digest. Largest payoff (8:50 → under a
   minute), largest design change.

A middle path exists — mounting the raw `Disk.img` on the host
(`hdiutil attach -imagekey diskimage-class=CRawDiskImage`) and writing the
LaunchDaemon into the Data volume — which would skip Recovery during creation
entirely, but it bypasses the in-guest signature/digest verification the
bootstrap was built around and mounts an untrusted filesystem on the host. Not
recommended; listed for completeness.

## 4. Recommendations for Recovery navigation

Route for 26.6.2 is already the short one (`directTerminal`: →, →, Return,
Return, ⇧⌘T). Of the 92 s, ~190 of 210 captures were spent waiting for the
guest; tool overhead is roughly 10–15 s.

### 4.1 Return the latest frame instead of blocking for the next update

`captureFrame` registers a request and waits (20 ms polls) until the private
observer publishes a *new* frame; each capture cost ~207 ms here and a static
screen never completes (this is also why `ui screenshot` fails with
`frame_timeout` on an idle desktop). Keeping the last published frame with a
sequence number lets observations return immediately; "two equal frames" can
become "unchanged sequence/hash across ≥100 ms", which is stronger evidence
than two back-to-back publishes. Expect ~5–8 s per navigation, and it removes
the static-screen failure mode.

### 4.2 Tighten the loop after an input

`pollNanoseconds` is 100 ms and the classification cool-down after a changing
frame is 2 s (`lastClassificationAt … >= 2`). Per transition that can add up to
~2 s before the new screen is recognised; a 500 ms cool-down with region OCR
(already cached) is enough. ~5 s per navigation.

### 4.3 Guest-side time (the bulk)

- **vCPUs**: the Recovery VM also runs with 4 of 8 cores; recoveryOS boot and
  app launches are partly CPU-bound. Same change as 3.5.
- **Later Recovery entries (SIP/AMFI/MDM/repair), not the first one**: have the
  normal agent set `nvram recovery-boot-mode=unused` before rebooting — on
  Apple silicon this boots straight into recoveryOS without the startup-options
  picker — and set `prev-lang:kbd=en-US:0` (from the agent, or from the Recovery
  Terminal during the bootstrap) so the language chooser is skipped. That
  removes three of the five keys and their waits (~20–30 s per entry). Needs a
  live check that VZ's NVRAM honours both; it applies to the auxiliary storage
  the VM already owns.
- **Saved state** (macOS 14+): Apple: "Save a paused virtual machine to file"
  / "Restore a stopped virtual machine to a state previously saved …
  The virtual machine must also be configured compatibly with the state
  contained in the file." A paused Recovery-at-Terminal state could make
  repeated security workflows near-instant, but the request-bound VirtioFS
  share is part of the configuration, so the share device would have to be
  configured identically with per-request contents. Speculative; listed only.
- Display geometry is bound to the qualified profiles (`…-en-1280x800`); a
  smaller display would speed capture/OCR but invalidates the reviewed
  records — not worth it.

## 5. Expected effect (this host, today's load)

| Change set | Estimated create time |
|---|---|
| Baseline | 8:50 |
| 3.1 typing + 3.2 stop + 3.4 hash + 4.1/4.2 loop | ~5:45 |
| + 3.5 install VM tuning | ~5:00 (needs measurement) |
| + 3.3 merged final boot (`--boot normal`) | ~4:20 |
| + 3.6 unprovisioned template | ~2:00 |
| + 3.6 provisioned template | < 1:00 |

Killing the orphaned VM service and re-measuring should be the first step; the
typing and polling numbers above will shrink on their own, and the remaining
order of the list will not change.

## 6. Follow-up results (2026-09-13, later the same day)

- **4.1 implemented.** `HeadlessFramebufferCaptureState` now retains the most
  recently published full-frame IOSurface and renders it on demand; the
  observer is no longer detached/re-attached per capture once a surface is
  held. `pomme ui screenshot` on a static screen went from `frame_timeout` to
  0.13 s per call, and captures reflect live changes.
- **4.2 implemented.** The classification cool-down inside one checkpoint is
  0.5 s (`PommeRecoveryObservationReadiness.classificationCooldown`) instead
  of 2 s.
- **4.3 NVRAM shortcuts tested and rejected (for now).**
  - `nvram recovery-boot-mode=unused`, run as root through the agent in a
    normal boot, fails with `(iokit/common) not permitted`. `recovery-boot-mode`
    is one of the NVRAM variables that System Integrity Protection's NVRAM
    protection blocks from userspace on Apple silicon; it can only be written
    where SIP does not apply — from the Recovery Terminal, or in a guest whose
    SIP has been disabled (`pomme sip disable`). **Revisit later:** for a VM
    that is already SIP-disabled, or at the end of a Recovery session
    (setting it there would arm the *next* boot to enter Recovery directly,
    skipping the startup-options picker), this may still be usable. It was
    not tested in either configuration.
  - `nvram prev-lang:kbd=en-US:0` is accepted, but the next Recovery boot
    still shows the startup-options picker and then the Language chooser, so
    it saves nothing under Virtualization.
  The navigation trace stays as is.
- **Validation create after 4.1 + 4.2** (same VM parameters, orphan VM service
  killed, `devme` deleted): total 8:32 (was 8:50). Navigation 87 s (was 92 s):
  331 captures in 14.5 s = **44 ms per capture (was 207 ms)**, but the loop
  simply ran more iterations while waiting on the guest — 323 poll sleeps
  still averaged 208 ms against a 100 ms setting. Typing was unchanged at
  99 s (17:21:27 → 17:23:06). Confirms that navigation is guest-bound and
  that 3.1 (typing) and 3.2 (stop timeout) are the next wins.

## 7. Implementation results (3.1, 3.2, 3.4, 3.5)

Validation create with the same parameters (full unit suite running on the
host at the same time, so restore/navigation numbers are pessimistic):

| Phase | Before (8:32 run) | After | Change |
|---|---|---|---|
| Pre-install (IPSW digest) | 24 s | 16 s | hashed once; a sidecar (`<ipsw>.sha256.json`, identity-keyed) now skips it on later creates |
| `VZMacOSInstaller` restore | 236 s | 249 s | `.none` sync + all cores: no measurable gain under load; kept (doc-backed, harmless), re-measure on an idle host |
| Recovery navigation | 87 s | 85 s | guest-bound, as expected |
| Probe typed + verified | 55 s | 10 s | one 8 ms dwell per chord, ~140-char probe |
| Launcher typed | 45 s | 9 s | 8-hex tag and workspace |
| Install → verify → stop | 76 s | 50 s | agent-driven `shutdown -h now` replaces the 30 s graceful-stop timeout |
| **Total** | **8:32** | **7:01** | |

The next create on the same IPSW should additionally skip the 12 s hash.
`pomme start` + `exec` and `inspect` health on the resulting VM are unchanged.

## 8. Template identity test (3.6)

`testvm`'s `Disk.img`, `AuxiliaryStorage`, and `HardwareModel` were cloned
with `cp -c` (APFS clonefile: 0.01 s for 21 GB) and booted by a small
entitled Virtualization program under a **freshly generated**
`VZMacMachineIdentifier`, with a listener on the agent's VSOCK port 505051.
The guest booted and its installed agent LaunchDaemon connected to the host
after 14.6 s. So a provisioned image is not bound to the machine identifier:
clones can carry distinct identities (and therefore may run concurrently,
which Apple requires for distinct identifiers). Guest-visible identity fields
(serial, platform UUID) were not compared in this test.

Consequences for a template design:
- an installed *or* provisioned template can be cloned per VM in well under a
  second, each clone getting a new identifier, MAC (derived from it), and UUID;
- a provisioned template's clone boots with the template's agent credential,
  so the host must rotate it on first boot before treating the clone as owned.
