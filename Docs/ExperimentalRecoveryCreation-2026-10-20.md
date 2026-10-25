# Experimental Recovery creation — October 20, 2026

## Status and scope

The research worktree implements `pomme create --experimental-recovery` for
direct creation and config batches. The flag was named `--experimental` during
the live runs below; [Review changes after qualification](#review-changes-after-qualification)
lists what changed afterwards, which hasn't been live-qualified yet. The retained macOS 26.6.2 experiment completed
through public resume with the final build, then passed later Recovery and
normal boot checks. This was a resumed experiment across implementation changes,
not a clean creation with the final build. Fresh macOS 27.0.1 creation and later
Recovery and normal boots passed. Clean final-build macOS 26 creation also
passed without manual repair or resume. **Both versions passed creation, and
final cleanup is verified.** macOS 27.0.1 interruption/resume and persistence
through macOS updates remain outside the completed qualification.

Worktree: `~/dev/pomme-recovery-research-20261018`.
Evidence root: `~/Library/Application Support/pomme/Research/RecoveryBoot-2026-10-18/ExperimentalCreation-2026-10-20/`.

## Public contract

```sh
pomme create VM_NAME --version VERSION --memory 4GB --disk-size 40GB --experimental-recovery
pomme create --config lab.yaml --experimental-recovery
pomme create VM_NAME --resume
```

`VM_NAME` is the new VM's name, and `VERSION` selects its macOS version.
The flag selects host-side preparation of the stopped VM's Recovery image.
Creation without the flag retains its existing behavior. Public provisioning
metadata reports `agentInstallMethod: experimental-recovery` for this strategy.

The immutable creation plan records the experimental configuration and its
Recovery session identity. Resume reuses that plan and the pinned signed agent
artifact; it doesn't accept `--experimental-recovery` or change an existing plan's
strategy. A config batch applies the flag to every member. It isn't a config
file key.

## Image preparation

The host attaches only the stopped target VM's disk and locates its Recovery
image. Preparation embeds the signed agent and a launch script, changes the
existing Recovery launchd job to start the script, and clears the copied
BaseSystem image's APFS System role. The script stages the agent and credential
into root-owned runtime files before starting the agent. This avoids requiring
host administrator privileges to create root-owned embedded payload files. The
embedded credential is the resident's own UUID-scoped Keychain item
(`recovery-resident-token`), not the persistent agent's. The host stages it
only while preparation runs and removes the staged copy when the prepared image
is complete, so Keychain and the prepared image hold the only copies.

Pomme retains both the original and prepared Recovery images. When a boot
needs the other image, a transaction under the stopped VM's operation lease
selects the prepared image for Recovery or restores the original for normal
macOS. A boot whose image is already selected doesn't attach the guest's disk:
a selection clears its durable intent only after verifying the bytes and
detaching, and nothing else installs the prepared image. The first integrated
experiment demonstrated that leaving the prepared image active could prevent
normal boot; mode-specific activation is now implemented.

A switch refuses to run while a saved VM state awaits restore, because the
restored guest holds the container's file-system state in memory. When the
recorded image is missing, or matches neither recorded hash, or its companion
files changed beside the original bytes, the guest replaced its Recovery, as a
macOS update does. Pomme then deletes both retained images, records the
replacement, and uses the standard Recovery route from then on. Normal boots
continue without host access.

The modified Recovery image has a broken seal. SIP and AMFI remain unchanged.
This distinction is material: unchanged SIP doesn't mean that the original
Recovery image's integrity properties remain intact. Persistence through macOS
updates or Recovery replacement isn't guaranteed. The prepared image replaces
the `com.apple.DumpPanicRecoveryOS` job, so its Recovery doesn't save panic
reports.

Use a fresh restore or a template whose Recovery image is unmodified. The
implementation rejects an already modified Recovery template, including an
image with its System role already cleared or an existing experimental payload.
It doesn't reuse another VM's embedded credential or session. Protected source
templates remain unchanged; experiments operate on disposable clones.

## Authentication and authority

The resident Recovery terminal agent uses VSOCK port `505054`, separate from
the existing request-bound Recovery connection. The host authenticates the
resident and checks its executable digest, protocol version, terminal version,
and exact terminal capability set before using it. Ordinary Recovery terminal
admission can use this connection without display observation or keyboard input.

For installation or a bounded Recovery operation, the resident terminal starts
the existing launcher from a temporary, read-only share bound to that request.
The separate one-shot connection retains its own credential, expiry, and
operation authority. The resident agent itself receives terminal capabilities,
not installer or security-operation authority. That separation is in protocol
only: a root terminal in Recovery can change anything that Recovery allows. A
successful resident connection alone doesn't prove that the installation
transaction completed.

Relevant implementation areas:

- `Sources/PommeCLI/VM/PommeExperimentalRecoveryImage.swift`: host image preparation, selection, and validation.
- `Sources/PommeCLI/VM/PommeExperimentalRecoveryPayload.swift`: staged payload, launch script, and launchd job.
- `Sources/PommeCLI/VM/PommeExperimentalRecoveryBootstrap.swift`: authenticated terminal launch of the one-shot request.
- `Sources/PommeCLI/CLI/PommeCore.swift`: creation, resume, runtime, and owner-flow integration.
- `Sources/PommeCLI/Operations/PommeProvisioning.swift`: immutable experimental configuration.

## Creation routes

### V1 Recovery route

The host prepares the restored or cloned disk before its Recovery boot. The
resident agent removes the initial Recovery UI navigation needed to start a
terminal. Agent installation still runs as the bounded request, followed by
normal-OS agent verification and the requested final state.

### V2 owner provisioning

Eligible macOS 27 hosts and guests retain Apple's first-boot owner provisioning.
The existing SSH checks establish that the owner is ready. Experimental creation
then uses host-prepared Recovery and the bounded share to install the guest agent.
It doesn't replace owner readiness with resident-agent authentication. Normal
agent, owner, and desktop verification remain required, and Remote Login must
be off at successful completion.

## Review changes after qualification

A review after the live runs below changed the implementation. The checks in
this section ran on the changed implementation; the live results in later
sections predate it.

- The flag is `--experimental-recovery`, because "experimental" already
  describes unqualified macOS builds.
- The resident uses its own Keychain credential, and the host deletes its
  staged copy after preparation. `pomme delete` removes it with the VM's other
  credentials.
- A boot whose image is already selected returns without attaching or hashing
  the guest's disk. Before, every boot attached the disk read-write and hashed
  about 4.6 GB.
- A pending saved-state restore refuses a switch, instead of mounting the
  guest's container read-write under it.
- A replaced Recovery image retires the experiment instead of refusing every
  boot.
- Mounts pass `nobrowse`.
- `pomme status` and `pomme inspect` keep the fixed Recovery-route fields when a
  V1 plan doesn't load.
- The creation space check adds about 5 GB for the retained images and a switch's copy.
- The synchronous activation bridge runs on its own task executor, so a blocked
  caller doesn't wait for a cooperative thread.
- The ROM, UART, offline-checkpoint, and resident-lab hooks are no longer in the
  CLI. The pre-review sources, including those hooks, are retained under the
  evidence root in `pre-review-fixes-snapshot/`.

| Check | Result | Scope |
| --- | --- | --- |
| Signed Release gate | Passed | `pomme 0.3.0 (e2b1d1f-dirty)` at `~/.local/bin/pomme` |
| Focused native tests | 246 passed | Image, payload, bootstrap, daemon, lease, create, planning, space, provisioning, and deletion suites |
| Full offline suite | 2,431 passed, 9 failed | The 9 timing failures, in 3 suites, passed alone (28 tests); a `main` baseline full run fails the same suites |
| CLI integration contracts | 211 passed | Installed runner, `--no-build` |
| Live macOS 26.6.2 clone | Passed | Creation, early-return normal start, Recovery switch and resident terminal, snapshot guard and its workaround, cleanup |

`review-fixes-live/summary.txt` under the evidence root records the live check
on the disposable `pomme-agent-experimental26-20261020c` clone. Creation exited 0
in 124 seconds. After preparation the staging directory had no `agent.token`,
and Keychain held separate `agent-token` and `recovery-resident-token` items. A
normal start took the early return in 13 seconds without attaching the disk.
A Recovery start switched images in 9 seconds, and a PTY terminal through the
resident ran as root with SIP enabled and no screen navigation. With the
prepared image selected, a snapshot restore was refused and left no saved-state
files; after a normal start and stop, the same restore succeeded through the
early return. `delete --force` reported `credentialsRetained: false`, both
Keychain items were absent, and the protected templates were unchanged.

The live check doesn't cover macOS 27, interruption and resume, or a real guest
macOS update; unit tests cover the replaced-image path.

### Guest macOS update check

`review-fixes-update/summary.txt` under the evidence root records an attempt to
upgrade experimental and ordinary (control) macOS 26.6.2 VMs to 26.7.1, the
26.7 release that Software Update offered. Both guests prepared the update and
then hung at its restart, and both cold-started back into 26.6.2, so a guest
macOS update doesn't complete in Pomme VMs on this host whether or not
`--experimental-recovery` is used.

The update's preparation still changed the experimental guest's Recovery
volume by staging `arm64eBaseSystem.dmg.staged`. Normal boots kept working
through the early return. The next Recovery start recorded the replacement,
deleted both retained images, and booted Apple's Recovery image; the
pre-review code would have refused both boots. The standard Recovery route then
received no display frames, and the control failed the same way, so that
failure isn't specific to this strategy.

Activation restores the original BaseSystem with the same bytes but not the
same metadata: owner `99:99` instead of `0:0`, without APFS compression, and
with a `com.apple.provenance` attribute. The control's hang shows this isn't
the cause of the stuck update, but it's a fidelity gap to keep in mind.

## Validation recorded so far

The current signed Release gate passed for `~/.local/bin/pomme`,
version `0.2.3 (e2b1d1f-dirty)`, with fresh login shell resolution verified.
The current runner's SHA-256 is
`d394e994e77817152f850c042ab561eb61abbcfd9a1ffb56a36fcded02a659ed`.
The final website reference was generated from this signed runner. Exact build
identities and evidence are retained under the evidence root, including
`run.json`; the retained VM continued to use its original pinned agent artifact
when the host runner changed.

| Check | Result | Scope |
| --- | --- | --- |
| Final focused native tests | 146 passed across 9 suites | Final mode-activation build |
| CLI integration contracts | 211 passed | Installed-runner contracts |
| Earlier focused native tests | 281 passed | Earlier implementation coverage |
| Earlier image-process and selection regressions | 14 passed | Three-container selection, unknown termination fencing, and native process completion |
| Final CLI reference generation | Passed | Approved installed runner; 34 command pages and generated errors |
| Final crawler consistency | Passed | 37 pages, zero errors or warnings |
| Final website build | Passed | 145 pages |
| Final website style lint | Existing failures | 149 errors, 418 warnings, 557 suggestions; no new handwritten-prose errors or warnings |
| Whitespace diff check | Passed | At completion of the documentation edits |

Final website evidence is in `website-mode-final-reference.log`,
`website-mode-final-check-crawler.log`, `website-mode-final-build.log`, and
`website-mode-final-lint-style.log` under the evidence root. The generated
reference footers retain an existing lowercase-product-name style finding;
their source revision changed, not that wording.

## Live qualification results

Integrated macOS 26 testing found and corrected two host-side preparation
problems. First, child-process completion using `waitUntilExit` was replaced by
a `terminationHandler` that records the child's termination status. Second,
the raw VM disk exposes three Recovery volumes, associated with the iSC,
fallback, and main System/Data containers. Selection now identifies the
Recovery volume paired with the main System/Data container rather than treating
the three candidates as an unresolved ambiguity. Fourteen focused image tests
pass after these changes.

With the current runner, the public resume workflow prepared the Recovery image,
detached the host mounts, booted Recovery, authenticated the resident, and
completed the request-bound agent installation without Recovery UI navigation.
The journal contains a successful `installRecoveryAgent` receipt.

The subsequent `verifyNormalAgent` phase failed after 300 seconds. The normal
helper was running, but no agent connection or display frame was observed.
Offline inspection found the installed agent files intact on the Data volume,
with the exact pinned `b82e5dd9` build digest, and the normal System volume's
role intact. These observations don't establish the cause of the failed normal
boot. In a controlled comparison, restoring only the original Recovery image
allowed the normal agent to connect immediately with the exact pinned `b82e5dd9`
build. The guest reported macOS 26.6.2 / 25G83, and its display showed the Setup
Assistant welcome screen. This implicates the modified image's presence during
normal boot; it doesn't establish a firmware-hash mechanism.

Mode-specific activation is now implemented and passed the signed gate and
focused checks above. The final runner resumed the retained macOS 26 experiment
through successful `verifyNormalAgent` and `restoreFinalState` receipts. Creation
ended with the VM stopped and no owned image attachments.

### Retained macOS 26 experiment

`experimental26a-summary.txt` under the evidence root records the disposable
`pomme-agent-experimental26-20261020a` clone and these results:

- Public resume completed all creation receipts. The normal agent authenticated
  with the original pinned `b82e5dd9` build; `sw_vers` reported macOS 26.6.2,
  build 25G83.
- A later public Recovery start used no lab environment and authenticated before
  any terminal activity or UI activity. PTY terminal access succeeded; the
  unsupported non-PTY `process.start` operation was rejected.
- The Recovery daemon ran as root, PID 54 with PPID 1, on port `505054`.
  The runtime directory was root-owned mode `0700`, the binary `0555`, and the
  token `0400`. Its digest matched the pinned build. SIP remained enabled.
- launchd retained the Recovery job with `RunAtLoad` and `KeepAlive`. After one
  targeted SIGTERM to PID 54, a newly authenticated PTY found replacement root
  PID 288 with PPID 1. Polling didn't capture a disconnected interval, so this
  record makes no transient-disconnect claim.
- A subsequent public normal restart authenticated the pinned normal agent and
  again reported macOS 26.6.2 / 25G83. No Recovery UI action was performed.

Cleanup is complete: `delete --force` reported `credentialsRetained: false`,
the VM bundle was absent, inventory was empty, and the 12 temporary files were
removed. Token contents were never printed or included in evidence.

This proves completion and later mode switching for the retained experiment.
Because that VM resumed across implementation changes, it doesn't replace a
clean creation test using only the final build.

### Clean macOS 27.0.1 creation

`experimental27a-summary.txt` under the evidence root records the disposable
`pomme-agent-experimental27-20261020a` VM, restored from the verified
`UniversalMac_27.0.1_26A434_Restore.ipsw` with a 40 GB disk and 4 GB of memory.
The final `d394e994` runner completed public creation with actual process exit
code 0. The V2 journal contains 10 events and a final `restoreFinalState`
receipt on attempt 1. Metadata reports macOS 27.0.1 / 26A434, `virtualization`
provisioning, `experimental-recovery` agent installation, automatic login
enabled, and Remote Login off.

Framework verification completed the owner reference, normal reboot and agent,
authentication, owner proof, Setup Assistant preferences, desktop proof,
persisted volume identity, and Remote Login checks. A later public Recovery
start authenticated before any PTY or UI activity. The resident ran as root PID
56 with PPID 1 on port `505054`, with the final build digest, a root-owned
runtime directory mode `0700`, binary `0555`, and token `0400`. SIP remained
enabled, and launchd reported `KeepAlive` and `RunAtLoad`. No Recovery UI action
was performed.

A later public normal restart connected the final-build normal agent. An
authenticated command exited 0, reported macOS 27.0.1 / 26A434, and confirmed
`Remote Login: Off`.

The intended detached-image interruption checkpoint was observed too late
because output visibility was delayed. No SIGINT was sent and no resume was
attempted. This run proves clean creation and later boot cycles, not macOS
27.0.1 interruption or resume behavior. The retained macOS 26 experiment
provides the public-resume evidence.

The macOS 27 VM bundle was deleted. Metadata-only queries for its exact
UUID-scoped `agent-token` and `pomme` Keychain items returned item-not-found
(exit 44). No secret retrieval was used. Token contents were never printed or
included in evidence.

### Clean final-build macOS 26 creation

The separate `pomme-agent-experimental26-20261020b` run completed public creation
with the final `d394e994` runner, without manual repair or resume. Its tracked
`create-exit.txt` reports exit code 0. Success JSON reports macOS 26.6.2 / 25G83,
V1 schema 1, `experimental-recovery` agent installation, Recovery guest
provisioning, the final-build agent, a 40 GB disk, 4 GB of memory, and final
state stopped.

`experimental26b-summary.txt` records successful receipts for `install`,
`installRecoveryAgent`, `verifyNormalAgent`, and `restoreFinalState`, with no UI
navigation. This supplies the clean final-build creation result that the
retained 26a experiment couldn't establish. The earlier 26a run separately proves public
resume and later Recovery/normal cycles; the 27a run proves clean macOS 27.0.1
creation with owner provisioning and later Recovery/normal cycles.

### Final cleanup and qualification limits

`experimental-final-cleanup-manifest.txt` records completed cleanup. The clean
macOS 26 VM was stopped; `delete --force` exited 0 with
`credentialsRetained: false`, and its bundle was absent. The macOS 27 bundle
was absent, and the metadata-only Keychain checks above confirmed that its
agent and owner credential items were absent.

The final VM inventory was empty, owned image attachments were zero, and no
Pomme helper remained. All temporary directories for 26a, 26b, and 27a were
absent. The protected base templates remained unchanged: macOS 26.6.2 / 25G83
and macOS 27.0.0 / 26A428, each with a 40 GB disk, unprovisioned, and
`securityDisabled: false`.

Qualification is complete for clean public experimental creation on macOS
26.6.2 and 27.0.1 at the tested resource settings. Public resume and later
Recovery/normal cycles passed on the retained 26a experiment. Later
Recovery/normal cycles also passed on the clean 27a experiment. No Recovery UI
navigation was used for these agent bootstrap checks.

The evidence doesn't qualify macOS 27.0.1 interruption/resume, other OS builds,
cloning from an already modified Recovery template, or persistence through
macOS updates. The last two remain unsupported or unguaranteed as described
above; successful creation doesn't remove those experimental limitations.
