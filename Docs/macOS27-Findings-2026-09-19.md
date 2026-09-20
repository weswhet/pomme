# macOS 27 findings — 2026-09-19

> **Follow-up, 2026-09-19:** §11 supersedes the earlier conclusions that a
> presenter cannot be requested without starting VNC, that superclass frame
> forwarding cannot acknowledge delivery, and that the screenshot crash lacks
> an entitlement explanation. [§12](#12-experimental-implementation-and-live-lab--2026-09-19)
> records the implemented fix and successful repeated captures in Recovery and
> normal boot, including visible changes. The first capture can still show a
> transient boot frame; macOS 26 live compatibility remains unverified. §§1–11
> retain the investigation evidence available at each stage.

Investigation of Pomme on a host upgraded to macOS 27. The headless frame-capture
regression now has a working presenter-registration implementation, validated
on the disposable fixture in §12. Earlier sections preserve the original
findings and hypotheses; §12 contains the current result and its limits.

- **Host:** macOS 27.0, build 26A428, Apple silicon (M1, 16 GB).
- **Toolchain:** Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0 SDK.
  Previously Xcode 26.6 (17F113) / Swift 6.3.3.
- **Framework under test:** Virtualization.framework build **308.1.7**.
- **Binary:** `~/.local/bin/pomme`, signed Release,
  `Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)`, from `48af02b`
  plus the working-tree changes described below.
- **Fixture:** disposable VM `m27`, 4 GB / 40 GB, restored from the local
  `UniversalMac_27.0_26A428_Restore.ipsw` (macOS 27.0, build 26A428).

---

## 1. Summary (initial investigation)

macOS 27 renamed the private framebuffer-observation SPI Pomme depends on. That
rename is real and was fixed. But the rename turned out to be the surface of a
larger restructuring: **guest display output now flows through a display
presenter that must be requested through methods Pomme cannot call.** Three
independent routes to guest pixels were examined and all are closed.

| Area | Status |
|---|---|
| Private frame-observation ABI preflight | Fixed (dual variant, macOS 26 + 27) |
| Headless frame capture on macOS 27 | **Unresolved — no reachable route found** |
| Swift 6.4 test-target compile failure | Fixed |
| Integration harness binary discovery | Fixed |
| `agent repair` dropped failure code | Fixed |
| `sessions list` stale session state | Fixed |

---

## 2. The rename (fixed)

`VirtualizationPrivateABIPreflight` required one fixed table of eleven private
selectors plus a protocol conformance check. Two entries moved in macOS 27:

| Expected (macOS 26) | macOS 27 |
|---|---|
| protocol `_VZFramebufferObserver` | `_VZDisplayPresenterObserver` |
| `-[_VZVNCServer framebuffer:didUpdateFrame:]` | `presenter:didUpdateFrame:` |

The ObjC type encoding is **byte-identical** across both:

```
v40@0:8@16{shared_ptr<const VzCore::Hardware::FrameUpdate>=^{FrameUpdate}^{__shared_weak_count}}24
```

On macOS 27 `_VZFramebufferObserver` does not exist and
`framebuffer:didUpdateFrame:` is absent from the class; `_VZVNCServer` adopts
`_VZDisplayPresenterObserver` and `_VZVirtualMachineAccessorObserver`, and gains
`presenter:didUpdateCursor:`, `presenter:didUpdateHostDisplay:`,
`presenter:didUpdateContentHeadroom:`, `setVirtualMachine:`, and
`virtualMachineAccessor:associateWithDisplayPresenter:`.

**Everything else still matches exactly**: the other ten selectors, and the
`_VZHIDEventMonitor` layout (instance size 24, `_filter`@8, `_enabled`@16,
`_hasEventTranslators`@17). Guest **input injection is unaffected**; only frame
observation broke.

`FrameUpdate` field layout is also unchanged. Disassembly of
`-[_VZVNCServer presenter:didUpdateFrame:]` reads the surface pointer at offset
0 and tests a validity bit at offset 8 (`*(p+8) & 1`) — exactly what
`HeadlessFramebufferFrameLayout` already assumes.

### Observed failure before the fix

```
m27 Recovery bootstrap milestone: requestValidated.
m27 provisioning phase installRecoveryAgent failed [code=headless.private_abi_mismatch].
Error: m27 provisioning phase installRecoveryAgent failed; the VM and journal were retained.
```

`pomme create` restored to 100%, then failed at `installRecoveryAgent`, exit 1.
`agent repair` and `create --resume` reproduced it identically and idempotently.
The guest itself **booted and ran normally** under `pomme start`; only the agent
never installed. The single gate is
`VirtualizationPrivateABIPreflight.validateRuntime()` at
`Sources/PommeCLI/CLI/PommeCore.swift:906`.

### After the fix

Provisioning advances from a dead stop at `requestValidated` through
`profileAccepted` → `hostStagingPrepared` → `runtimeConstructed` →
`sessionStarting` → `runtimeStarting` → `runtimeStarted` →
`recoveryBootVerified` → `navigationStarted`, then fails at the next stage
(§3).

---

## 3. The real change: display output moved behind a presenter (unresolved)

Frames are no longer published by the display's framebuffer. They are published
by a `_VZDisplayPresenter` obtained from a `_VZVirtualMachineAccessor`.

`-[_VZVNCServer presenter:didUpdateFrame:]` begins by requiring an accessor and
a matching presenter — otherwise it returns without delivering:

```
r8 = self->_accessor;              if (r8 == 0) return;   // ivar 18, +0x90
r22 = _accessor->_presenter;       if (r22 != presenter) return;
```

Pomme never called `setVirtualMachine:`, so `_accessor` was nil. Adding that
call populates the accessor — but capture still fails. Reading the live ivars in
the running helper after `setVirtualMachine:` + `setGraphicsDisplay:`:

```
observer=PommePrivateHeadlessFramebufferObserver
  _virtualMachine=1044b3c10  _graphicsDisplay=1044b3fd0  _accessor=76fac54200
accessor=_VZVirtualMachineAccessor
  _presenter=nil  _presenter_requested=nil
  _graphicsDevices=76fad6c0c0  _hidEventMonitor=76fac6c0c0
```

**The presenter is never requested**, so nothing publishes. Result:

```
Error: Headless VM automation failed [code=frame_timeout]:
The private framebuffer observer did not publish a frame before the deadline.
```

and, during provisioning:

```
Recovery navigation observation timed out [expected=startupOptions, lastObserved=none].
m27 provisioning phase installRecoveryAgent failed [code=recovery_session.observation_timed_out].
```

### Why it cannot be requested

`-[_VZVirtualMachineAccessor _requestDisplayPresenter]` exists in the binary but
is **`objc_direct`**. Verified at runtime — `class_copyMethodList` on
`_VZVirtualMachineAccessor` returns only:

```
.cxx_construct  .cxx_destruct  _hidEventMonitor  _processHIDReports:forDevice:deviceType:
_shouldSendHIDReports  dealloc  graphicsDevices  initWithAccessorEndpoint:  queue
sendDigitizerEvents:… sendIOHIDEvents:… sendKeyboardEvents:… sendMagnifyEvents:…
sendMouseEvents:… sendMultiTouchEvents:… sendPointerNSEvent:… sendQuickLookEvents:…
sendRotationEvents:… sendScrollWheelEvents:… sendSmartMagnifyEvents:…
```

`_requestDisplayPresenter`, `createDisplayPresenterWithEndpoint:`,
`addAccessorObserver:`, `invalidateDisplayPresenter` and `presenter` are all
absent from the method list — not reachable by `objc_msgSend`, method lookup, or
`dlsym`. The only in-framework trigger found is `-[_VZVNCServer start]`, which
dispatches onto `_serverQueue` and starts a real VNC listener. Pomme must not
open a network listener.

### The frame-credit gate (relevant if a presenter is ever obtained)

`_VZDisplayPresenterMessenger::process_frame_update` walks `_presenterObservers`
(stride `0x30`) and, per entry:

```
if (entry[0x28] & 1) { entry@0x28 = 0x100; deliver(entry); }   // credit spent
else                 { entry[0x29] = 0;   }                     // frame DROPPED
```

`-[_VZDisplayPresenter setDidProcessFrameUpdateForPresenterObserver:]` restores
the credit — and is also `objc_direct`, so it cannot be called either. Calling
`super` does not ack: `-[_VZVNCServer presenter:didUpdateFrame:]` returns early
on a nil `_accessor`.

The practical consequence, which applies to **macOS 26 as well**: an observer
that never acks receives one frame per registration. Pomme's
`ensureFramebufferObserver` previously re-armed only while
`!hasLatestSurface`, so it effectively received a single frame for the life of
the backend. It worked only because the guest reuses one scanout IOSurface; a
surface reallocation (resolution change, sleep/wake, Recovery→normal) would have
served stale pixels that still pass `validateFrame` — right size, not blank — so
Recovery would navigate on a dead screen with nothing thrown. This was fixed
independently (always re-arm; ask for the frame before re-arming).

---

## 4. `_takeScreenshotWithCompletionHandler:` crashes the VM service

`-[VZGraphicsDisplay _takeScreenshotWithCompletionHandler:]` (`v24@0:8@?16`) is
present and **not** `objc_direct`, and looked like a better fit than streaming
frames. It is unusable:

```
attempt=1 -> arg1=nil ERR domain=VZErrorDomain code=1
   desc=Internal Virtualization error. Failed to take a screenshot
attempt=2 -> arg1=nil ERR domain=VZErrorDomain code=3
   desc=Invalid virtual machine state. The virtual machine must be "running"
        to take a screenshot, it is currently "error".
```

Attempt 1 fails; the VM is dead from then on. The system's own crash reports
show one crash per attempt:

```
com.apple.Virtualization.VirtualMachine   build 308.1.7   macOS 27.0 (26A428)
exception : EXC_BREAKPOINT (SIGTRAP), codes 0x1, 0x1006a7e88
faulting thread: com.apple.virtualization.virtual-machine-service
  com.apple.Virtualization.VirtualMachine  ? + 4259464
  com.apple.Virtualization.VirtualMachine  ? + 70040
  com.apple.Virtualization.VirtualMachine  ? + 277880
  com.apple.Virtualization.VirtualMachine  ? + 33380
  com.apple.Virtualization.VirtualMachine  ? + 393984
  libxpc.dylib  _xpc_connection_call_event_handler
  libxpc.dylib  _xpc_connection_mach_event
```

Disassembly confirms the call sends a
`VzMessages::VirtualMachine::Display::take_screenshot` XPC message; the service
hits a deliberate assertion handling it and dies. Reports are in
`~/Library/Logs/DiagnosticReports/com.apple.Virtualization.VirtualMachine-2026-09-19-*.ips`.

Confounders ruled out:

- **Not thread affinity** — same crash when dispatched on the VM's own queue.
- **Not Recovery-specific** — same crash on a normal boot.
- **Not a sick VM** — control run: booted and left untouched, `m27` stayed
  `running` across 60 s of polling. The crash occurs only when the call is made.

This looks like a first-party Apple bug worth reporting: a `_take…` SPI should
not SIGTRAP the virtual-machine service.

---

## 5. `VZGraphicsDisplayObserver` carries no frames

`VZGraphicsDisplay` has public-looking `addObserver:` / `removeObserver:` and a
`VZGraphicsDisplayObserver` protocol. Its entire method list is:

```
optional: displayDidBeginReconfiguration:   v24@0:8@16
optional: displayDidEndReconfiguration:     v24@0:8@16
```

Reconfiguration notices only. Not a capture route.

---

## 6. Routes examined

| Route | Result |
|---|---|
| `_VZVNCServer` + `_VZDisplayPresenterObserver` | Needs `_requestDisplayPresenter`; `objc_direct`, unreachable |
| `-[_VZVNCServer start]` | Would request the presenter, but opens a VNC listener |
| `-[VZGraphicsDisplay _takeScreenshotWithCompletionHandler:]` | Crashes the VM service (SIGTRAP) |
| `VZGraphicsDisplayObserver` | Reconfiguration callbacks only |

Untried: driving a real `VZVirtualMachineView` offscreen so the framework
requests a presenter itself; calling `start` with a port that cannot bind.

---

## 7. Fixed in this pass

### 7.1 Dual-ABI frame observation

`Sources/PommeCLI/UIAutomation/VirtualizationPrivateHeadlessBackend.swift`.
`VirtualizationPrivateFrameObservation` names the protocol, selector, encoding
and (where required) the `setVirtualMachine:` association for one interface
generation. `resolveFrameObservation(using:)` accepts a variant only when its
protocol exists, `_VZVNCServer` adopts it, the protocol's own required-method
encoding matches, and the class's selector encoding matches — and requires
**exactly one** variant to qualify, so a host that declares a superseded
interface alongside its successor is rejected rather than guessed at. The
eleven-entry table became ten shared entries plus the resolved variant's.
Variants are tagged `gen1`/`gen2` so naming the resolved one in a diagnostic
reveals nothing about the private interface.

`validateRuntime()` now passes on macOS 27.

### 7.2 Swift 6.4 blocks the whole test target

`Tests/PommeCLITests/CLI/NumericOptionTests.swift:28`

```
macro expansion @Test:12:10: error: the compiler is unable to type-check this
expression in reasonable time; try breaking up the expression into distinct
sub-expressions
```

A 13-element `arguments:` array of untyped `(String, [String], String)` tuples
exceeds Swift 6.4's type-checker budget; `xcodebuild test` exits 65 and nothing
runs. Compiled on Swift 6.3.3. Fixed by hoisting to a file-level constant with
an explicit type. CI (`macos-15`) has not hit this yet — it will when the runner
image updates.

### 7.3 Integration harness cannot find the binary

`Tests/PommeCLIIntegrationTests.sh:39` expected `appPath` at the JSON top level;
XcodeBuildMCP now emits `schemaVersion: 2` with it under
`data.artifacts.appPath`. Exit 66, 0 of 88 checks ran. Fixed by reading
`data.artifacts` first with a fallback. **Local only** — CI passes
`--runner … --no-build` and bypasses the parse.

### 7.4 `agent repair` dropped the failure code

`create --resume` logged `… failed [code=headless.private_abi_mismatch].`;
`agent repair` logged nothing but the generic retained-journal message, because
`PommeCore.repairProvisioning` reimplements the failure path inline instead of
going through `PommeProvisioningOrchestrator.executeEffect`. It now emits the
same redacted code and throws `phaseFailed(next.phase, vmName:)` rather than a
hard-coded phase with no name.

### 7.5 `sessions list` presented remembered state as current

Not the originally suspected defect. `terminal.list` is answered from the
**host-side** durable record store over the control socket, never via
`agent.perform`, so answering with the agent down is correct — that is what
durable sessions are for, and "No terminal sessions." on an unprovisioned VM is
true. The real defect is narrower: each record carries a `state` (`running`, …)
that is only as fresh as the last agent contact, and nothing said so. The
`terminal.list` / `terminal.inspect` envelopes now carry the agent connection,
and table output marks states as last-recorded when it is not `connected`.

### Test coverage added

The existing `installedRuntimeABI` test could not catch this class of
regression: on throw it only asserted `.privateABIMismatch ||
.unsupportedArchitecture`, so it passed on a host whose SPI was broken. That is
why the suite was green while `create` was failing. It now hard-fails a
mismatch at or above a declared support floor (macOS 26, checked with
`ProcessInfo.isOperatingSystemAtLeast` so it is a host claim, not an SDK claim),
leaving `macos-15` CI green. Added: resolver selection and rejection tests over
injected probes (missing interface, wrong encoding, non-conforming class, absent
callback, protocol/class disagreement, crossed interfaces, ambiguity), a pinned
golden encoding literal, table well-formedness, and a mechanical redaction test
asserting no failure message names a protocol, selector, encoding, or `_VZ`.
`abiMatching` is now parameterized over both variants and corrupts every entry
rather than only `requiredMethods[0]`.

Offline suites: **1215 unit cases**, 88/88 CLI contract checks, 21/21 local
build/install checks, identifier audit and packaging identity all green.

---

## 8. Open decision

The dual-ABI fix makes `validateRuntime()` pass on macOS 27 — correctly, since
the interface it checks is present. But capture still fails, so `create` now
proceeds past a green preflight and dies later at
`recovery_session.observation_timed_out`, which is **less diagnostic** than the
old `headless.private_abi_mismatch`.

1. Make macOS 27 fail closed at the preflight with an explicit
   "frame observation unavailable on this host" reason until a capture route
   exists. Honest, and preserves macOS 26.
2. Land as-is and accept the vaguer late failure.
3. Keep looking (offscreen `VZVirtualMachineView`; `start` with an unbindable
   port).

---

## 9. Other issues observed

- **A VM in `error` state cannot be stopped.** `pomme stop` returns
  `Invalid virtual machine state transition. Transition from state "error" to
  state "stopping" is invalid.`, leaving the helper running with no CLI way to
  clear it; the helper had to be killed by hand. `pomme start` afterwards
  reports `OK boot mode=recovery` while status stays `error`.
- **`agent repair` cannot reconcile an interrupted repair intent.** After a
  failed repair it returns `Agent repair cannot reconcile an interrupted
  installRecoveryAgent intent … obtain recovery assistance before retrying`,
  with no CLI path forward; the VM had to be deleted and recreated.
- **`pomme delete` requires a TTY** and says so, but `--force` is the only
  option offered — fine, noted for scripted cleanup.
- **`ipsw` cannot list already-downloaded images**, though they live in
  `~/Library/Application Support/pomme/RestoreImages/`. There is no
  `restoreImageStoreDirectory()` helper; the path is inlined at
  `PommeCore.swift:2218` and `:4857`.
- **`privateHostABI` is positional, not evidentiary.**
  `PommeCore.recoveryProfileEvidence(for:)` hard-codes
  `.qualifiedRecoveryInputV1` at `:926` and `:938` regardless of the host, and
  two callers never run the preflight at all:
  `PommeSecurityWorkflowLive.swift:54-56` (`sip`/`amfi enable|disable`) and the
  `profileResolver` at `PommeCore.swift:3087`. On a host with a broken ABI those
  commands pass the qualification gate and fail deeper instead of failing
  closed.
- **New deprecation, cosmetic.** `SettingsAIPlanner.swift:1047,1098` —
  `GenerationOptions(sampling:temperature:maximumResponseTokens:)` is deprecated
  in the macOS 27 SDK in favour of `init(samplingMode:…)`. No other macOS
  26/27-era deprecations appeared.
- **An orphaned `com.apple.Virtualization.VirtualMachine` XPC service** from a
  pre-upgrade session was found reparented to `launchd`, holding 608 MB and ~3%
  CPU with no corresponding VM. A `pomme` process had exited without cleanly
  stopping its VM.

---

## 10. Reproducing

```sh
# ABI surface, no VM required
#   protocol/selector presence and encodings on the live framework
#   (Virtualization is weak-linked: touch VZVirtualMachine.self first or the
#    private classes are not realized and every lookup returns nil)

# Capture failure, VM required
pomme create m27 --restore-image \
  "$HOME/Library/Application Support/pomme/RestoreImages/UniversalMac_27.0_26A428_Restore.ipsw" \
  --disk-size 40GB --memory 4GB
pomme start m27 --mode recovery --timeout 180
pomme ui screenshot m27 --output /tmp/shot.png --timeout 30
#   -> frame_timeout

# Service crash
#   call -[VZGraphicsDisplay _takeScreenshotWithCompletionHandler:] on a running
#   VM; the VM enters "error" and a crash report appears under
#   ~/Library/Logs/DiagnosticReports/
```

Notes for anyone repeating this: `pomme ui screenshot` is served by the
long-lived **helper** process, so a rebuilt CLI has no effect until the VM is
stopped and started again. The helper is detached, so debug output must go to a
file rather than stderr.


---

## 11. Hopper follow-up — 2026-09-19

This follow-up used read-only Hopper inspection, live Objective-C metadata, and
signature/entitlement inspection. No build, test suite, or VM experiment was run
for this follow-up. The addresses below identify instructions in the inspected
macOS 27 build, not addresses to call from Pomme; they are not portable API.

### 11.1 Presenter request and observer registration are separate gates

The earlier claim that `start` is the only presenter-request trigger is wrong.
The VNC display-setup path tests `activeClientCount` at object offset `+0x98`
at `0x2260f0ac0`–`0x2260f0ac8`. The first-client path triggers setup at
`0x2260f19f0`–`0x2260f1aa8`. This explains why copying VNC's setup sequence
without a client need not register Pomme for frames, but does not establish
that the accessor can never request a presenter.

The VNC `setGraphicsDisplay` implementation variant at `0x2260f2d64` creates an
accessor with options value `2`. Accessor construction schedules an asynchronous
callback at `0x22607515c`–`0x226075170`. The callback at `0x226063124` automatically
requests a presenter when the presenter at `+0xb0` is nil and the request flag
at `+0xb8` is false. Its dispatch table at `0x27acd6530` leads to
`0x22605b994`, which writes the request flag to `1` at `0x22605ba18`.
An immediate nil-ivar snapshot after `setGraphicsDisplay:` therefore cannot
prove that no request will occur: accessor initialization is asynchronous.
Runtime ivar metadata confirms `_VZVNCServer._accessor` at `+0x90` is an
accessor object, `_activeClientCount` at `+0x98` has encoding `I`, accessor
`_presenter` at `+0xb0` is a presenter object, and `_presenter_requested` at
`+0xb8` has encoding `B` (Boolean). The earlier `_presenter_requested=nil`
notation must not be interpreted as an object-valued field; a probe must read
the Boolean correctly and account for queued initialization.

A distinct runtime-callable method is present:

```
virtualMachineAccessor:associateWithDisplayPresenter:
v32@0:8@16@24
```

Its body at `0x2260f0cbc` checks accessor identity and a nonnil current
presenter, then calls `setDisplayProperties` at `0x2260f0ec8` with a 12 fps
setting. The implementation at `0x226166530` inserts a missing observer record;
from `0x2261665f4` onward that record is initialized with one frame credit at
record offset `+0x28`. This is a promising registration route through an
Objective-C method even though the lower-level request and credit methods
remain `objc_direct`.

A narrow experiment would wait for asynchronous accessor initialization, safely
retain the current accessor and presenter, and invoke this association callback
on the accessor queue. It must establish the relevant object lifetimes, queue
ownership, and identity checks before doing so. This candidate requires no VNC
`start`, connected client, ivar writes, or calls to hard-coded addresses.
**End-to-end reachability and frame delivery have not been verified.**

### 11.2 The superclass can acknowledge a matching frame

The superclass `presenter:didUpdateFrame:` implementation acknowledges delivery
at `0x2260f1374` after its accessor/presenter matching checks. The earlier
nil-accessor case explains an early return; it does not show that forwarding
can never acknowledge a correctly associated frame.

Pomme's current `frameUpdateImplementation` in
`Sources/PommeCLI/UIAutomation/VirtualizationPrivateHeadlessBackend.swift:939`
only calls `state.receive`; it does not forward to the superclass. Forwarding
after Pomme has read the frame is a candidate for restoring credit. The
superclass also queues VNC backend frame work at `0x2260f1358` before the
acknowledgment, so it is not a pure acknowledgment helper; behavior with an
unstarted backend must be verified. The original handler moves and clears the
C++ `shared_ptr`, so Pomme must retain the needed IOSurface before forwarding
and establish callback ABI, queue, render completion, and ownership rules.
Forwarding has not been established as safe.

The existing re-arm change also does not prove stale-frame safety. The fallback
at `VirtualizationPrivateHeadlessBackend.swift:1505` renders the retained surface
after the short fresh-frame budget, and `ensureFramebufferObserver` at `:1527`
does not clear that cache when changing the display. A retained surface may
remain nonblank and have the expected dimensions after becoming obsolete.
The historical claim in §3 that this is fixed is therefore too strong.

### 11.3 Screenshot SIGTRAP is an entitlement assertion

The VM-service binary has UUID
`4a6a588d-1afd-30f5-a64d-6304eb79be0b`. Its entitlement helper
`sub_1002e994c` copies an entitlement at `0x1002e9990`, checks for an XPC Boolean
at `0x1002e99ac`, and reads its value at `0x1002e99e4`; a non-Boolean produces
zero. In `sub_1002e9874`, `com.apple.private.virtualization = true` produces mask
`3` (`mov w20, #3` at `0x1002e9898`). Otherwise the standard virtualization
entitlement contributes its raw Boolean value, `0` or `1`, at `0x1002e98b0`.

`sub_100014d4c` computes that mask at `0x100014d84` and passes it to
`sub_10000c24c` at `0x100014dd4`–`0x100014de0`. The constructor stores it at
object offset `+0x28`: `stur w19, [x8, #-8]` at `0x10000c32c`, with
`x8 = object + 0x30`.

The screenshot handler at `0x1000110fc`/`0x100011100` tests bit 1 of that mask.
When absent, it branches to the assertion at `0x100011194`, reaching
`_os_crash` at `0x10040fe84` and `brk` at `0x10040fe88`. The latter is image
offset **4259464**, matching the crash reports in §4. This establishes a
private-entitlement gate as the cause of the observed trap, superseding the
inference that an otherwise authorized screenshot implementation is simply
broken.

The installed signed Pomme CLI was verified to have only
`com.apple.security.virtualization = true`, the documented
[Virtualization entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project).
That yields the standard entitlement bit, not the private bit the screenshot
handler requires. Do not add private entitlements or alter signing to pursue
this route. An Apple report can narrowly ask for an error response instead of
terminating the service when an unauthorized private screenshot request arrives.

### 11.4 Proposed validation, not completed

Use a fresh disposable `pomme-agent-*` VM with explicit
`--disk-size 40GB --memory 4GB`; preserve those resources for the before/after
comparison. Build any credential-bearing experimental CLI with the repository's
canonical signed Release workflow. Start a new helper so it uses that build.

Acceptance criteria for the headless registration candidate:

1. Observe completion of accessor initialization and a matching presenter, then
   verify that association registers the observer without starting VNC or
   opening a network listener.
2. Capture multiple changing frames beyond the initial frame credit; correlate
   callbacks with changing pixels so a reused or cached surface cannot by itself
   satisfy the check. Verify normal boot and Recovery separately.
3. Verify frame delivery continues after a display/surface replacement and that
   a missing fresh frame times out instead of returning an obsolete cached
   image. Exercise teardown/reassociation to expose lifetime and queue errors.
4. Verify the macOS 26 path still delivers repeated fresh frames before claiming
   compatibility. Keep this separate from macOS 27 ABI-presence checks.

The present conclusion is a concrete headless registration hypothesis and an
explained screenshot-service trap. Neither constitutes a working capture fix.


---

## 12. Experimental implementation and live lab — 2026-09-19

**Status: Candidate 4 delivers repeated useful screenshots after initial
publication in Recovery and normal boot; a cold first capture can still be
black with a cursor.** The user authorized live resolution attempts. This section records
experimental changes in
`Sources/PommeCLI/UIAutomation/VirtualizationPrivateHeadlessBackend.swift` and
their partial results. The signed Candidate 4 remains installed. Initial-frame visual readiness,
full creation/resume, and macOS 26 live compatibility remain unverified.

### 12.1 Initial candidate behavior (historical)

The gen2 path obtains the current accessor from the observer on the VM queue,
then asynchronously dispatches association work onto the accessor's own queue.
It polls within the capture deadline for a matching accessor and a nonnil
presenter, allowing the framework's queued initialization to complete. Object
ivar reads validate the runtime type encoding, offset bounds and alignment,
and the actual object's class against its declared class. Queue and association
selectors are checked against their expected method encodings before use.
There are no hard-coded address calls or ivar writes.

Once the presenter matches, the code invokes
`virtualMachineAccessor:associateWithDisplayPresenter:` and preserves continuous
gen2 observation across captures of the same display. It does not tear down and
re-arm the gen2 observer for every screenshot. The existing gen1 path retains
its previous re-arm behavior.

The gen2 frame callback checks source identity, retains the IOSurface through
`state.receive`, and then forwards to the validated superclass callback to
restore frame credit. The surface is retained before the superclass can move
and clear the C++ `shared_ptr`. Rendering remains asynchronous. The superclass's
VNC backend work and the timing of acknowledgment versus rendering still need
live validation; successful compilation does not establish their runtime safety.

Changing the associated source clears the cached surface and completed frame,
and increments a source generation so a render from the previous source cannot
complete the current request. A fresh gen2 full-frame or damage callback is
required to satisfy a screenshot request. Damage callbacks may render the
retained surface for that same presenter; the elapsed-time cache fallback is
disabled for gen2. The gen1 fallback remains, so this change alone does not
establish stale-frame safety on macOS 26.

### 12.2 Live results and candidate revisions

The disposable lab VM is `pomme-agent-m27-capture-20260919a`, with **40 GB disk /
4 GB memory**, restored from the exact macOS **27.0 (26A428)** IPSW. Keep these
resources constant for subsequent comparisons.

The copied baseline binary (SHA-256 abbreviated `8e21…c77b7`) completed the OS
installation during `create`, but `installRecoveryAgent` failed with
`cleanup_failed`. A standalone baseline Recovery attempt then returned
`vm_state_invalid`, with `vmState: error`. No cause has been established for
these baseline failures, so this is a confounded before/after comparison.

| Revision | Signed Release SHA-256 | Observation |
|---|---|---|
| Candidate 1 | `47efab5220342c449a7db2a7fdd0e628a22f0f06f33e82ab5b434c01a6520efd` | First Recovery capture returned a 1280 × 800 PNG, 21,615 bytes, showing black with a cursor. A second capture of the static display timed out after 20 seconds. |
| Candidate 2 | `086f4fdb52f36e573b8927650a6293faa3f81a70e552121c137af891a4986cf4` | Made source validation and cache mutation atomic within `receive`. A first Recovery capture delayed by 25 seconds still showed black with a cursor. |
| Candidate 3 | `88fbb495c02dddfe74367f4816d882f570705782ad079ba5052780de911db666` | Re-arms every capture. Initial Recovery image remained black with a cursor; subsequent captures showed the chooser and a visible selection change. First normal-boot capture was blank; no repeat attempted. |
| Candidate 4 | `33149c2442768cc64f83d337e0127f4eaa0d34575633299645029d781f9d4d2a` | Signed and installed. Repeated Recovery and normal-boot captures showed useful UI after the initial black-with-cursor frame. Synchronous replay suppression does not guarantee visual readiness of the first capture. |

Candidate 1 establishes that the registration route can deliver an image in
this live configuration. A black image with a cursor does not establish usable
Recovery UI capture, and its second-capture timeout does not establish the
cause of the missing update. Delaying Candidate 2's initial capture did not
resolve the black-with-cursor observation.

### 12.3 Candidate 3 live evidence and limits

After 56 seconds of Recovery boot, Candidate 3's first screenshot was still the
21,615-byte black-with-cursor image. The second request re-armed observation and
returned in 0.44 seconds with a 52,847-byte image showing the Recovery chooser
(Macintosh HD and Options). The third request returned the same meaningful
screen in 0.38 seconds. The investigator visually inspected the chooser image.

One click at `(752, 352)` selected Options, without pressing Continue. The next
screenshot returned in 0.45 seconds and showed Options selected with Continue
available; the PNG increased from 52,847 to 55,003 bytes. Visual inspection
confirmed that change. This demonstrates repeated capture and a guest UI change
in this Recovery session, beyond one initial frame.

A TCP-listener check with `lsof` against verified helper PID `58576` exited `1`
with no output: no TCP listener was found for that helper during the check.
This is observed evidence for the headless experiment, not a guarantee for
uninspected processes or future sessions.

The first registration can replay a boot-era frame even when the screenshot is
requested later. A callback caused by registration alone therefore does not
guarantee the newest guest pixels; a subsequent re-arm after publication yielded
the updated surface in this run.

For normal boot, the first Candidate 3 screenshot after 75 seconds was blank and
failed with `frameInvalid`. The VM was stopped before any repeat capture, so
this single result does not establish a general normal-boot capture failure.

### 12.4 Current candidate and completed focused checks

Candidate 3 supersedes the continuous-observation behavior described in §12.1.
Both gen1 and gen2 now detach and re-arm on every capture, explicitly clearing
capture state with `associateSource(nil)`. Gen2 waits for the replacement
accessor/presenter registration on the accessor queue. It still requires a
fresh callback and has no Pomme elapsed-time fallback to a cached surface.
The repeated Recovery results above show that re-registration delivered useful
updates in that session. Candidate 4 keeps these subsequent re-arms and changes
initial association: synchronous replay may populate the retained surface and
be acknowledged, but cannot complete the pending screenshot request. The request
waits for asynchronous publication. The live results below show that this does
not guarantee a visually ready first frame: asynchronous publication can also
supply the initial black-with-cursor image.

Candidate 2's race fix remains: source identity validation and surface-cache
mutation occur under the same lock, preventing an old presenter's callback from
installing a surface after reassociation. Explicit nil association clears state
even when no presenter identity was previously installed, including gen1.
Superclass forwarding still retains the needed IOSurface before the
`shared_ptr` move; asynchronous rendering and backend behavior retain the
validation limits described above.

The canonical signed Release build/signature checks passed. A focused suite
run through XcodeBuildMCP reported **22 passed, 0 failed**, with result bundle:

```
test_macos_2026-09-20T05-57-17-276Z_pid54226_8a4563fa.xcresult
```

A separate architecture check reported **6 passed, 0 failed**:

```
test_macos_2026-09-20T05-59-32-834Z_pid59353_f580be24.xcresult
```

After Candidate 4's replay change, the focused capture and architecture suites
reported **29 passed, 0 failed** (23 capture and 6 architecture):

```
test_macos_2026-09-20T06-05-33-995Z_pid71732_2c51ed20.xcresult
```

These focused checks passed; live evidence and its remaining limits are
recorded below.


### 12.5 Candidate 4 final live results

The final installed signed Release remains Candidate 4, SHA-256
`33149c2442768cc64f83d337e0127f4eaa0d34575633299645029d781f9d4d2a`.
Both boot modes were exercised on the disposable lab VM at the same
**40 GB / 4 GB** settings. The user's existing `m27` VM was not modified.

| Scenario | Observed result |
|---|---|
| Recovery, cold first capture after 20 seconds | Black with cursor, 21,615 bytes; abbreviated image SHA-256 `c12e…ce131`. |
| Recovery, repeated capture | Actual startup chooser, 52,847 bytes; `7859…0cdab`. |
| Recovery, one Options click, no Continue | Selected Options and Continue visible, 55,003 bytes; `fe817…a7efd`. |
| Normal boot, cold first capture | Black with cursor. |
| Normal boot, later captures | Two full Setup Assistant animated welcome frames, 1,700,266 bytes (`648c…5424e`) and 1,697,511 bytes (`dee2…40dd0`). No normal-boot input was sent. |

The investigator visually inspected the third normal-boot screenshot. The two
later normal images and Recovery selection change show that repeated capture
can follow changing guest output. Image hashes above are deliberately
abbreviated identifiers, not full digest strings.

For verified Candidate 4 helper PID `79544`, the `lsof` TCP-listener check
returned exit `1` with empty output, finding no TCP listener for that helper.
Together with the Candidate 3 check, this supports the observed headless route
without invoking VNC `start`.

The screenshot route now works after initial publication in both tested boot
modes. **The cold initial black frame has not been eliminated.** Initial
association suppression only ignores synchronous replay when present; it does
not establish that the first asynchronous frame contains visually ready guest
UI. A black image with a cursor can pass the existing nonblank validation.

The 29 focused tests in §12.4 passed. Full `create`/`create --resume` completion,
macOS 26 live compatibility, and broader display/surface-replacement coverage
remain unverified. The baseline error-state failure is still unexplained, so
this is not a clean end-to-end provisioning comparison.

### 12.6 Cleanup status

The disposable lab VM stopped successfully. Target-only deletion through the
public CLI then failed:

```
pomme delete pomme-agent-m27-capture-20260919a --force
Pomme agent credential removal failed (Security status -25244)
```

The final read-only inventory corrected the initial cleanup report: the public
delete command removed the VM bundle **before** credential cleanup failed.
`pomme status` now finds no owned lab VM, and `pomme list` contains only the
untouched existing `m27`. No lab VM bundle or journal remains.

Security status `-25244` means “Invalid attempt to change owner.” A potentially
remaining credential is scoped to service
`com.github.weswhet.pomme.vm.15b4c30f-a763-40ad-a76c-4185f78eebda`, account
`agent-token`. This identifier was derived from source and VM metadata; no
secret query was performed to establish whether the item remains.

Cleanup halted without retrying credential deletion, broadening Keychain ACLs,
or manually bypassing the CLI. All regular temporary logs, raw PNGs, and copied
executables remain; raw-artifact cleanup did not occur. The installed signed
Candidate 4 and shared artifact archive remain unchanged.
