# Live Pomme CLI option sweep — 2026-09-22

Status: complete — live macOS 27 then macOS 26 sweep finished 2026-09-22

The sweep is complete, not every reported issue. Follow-up fixes and remaining
observations are recorded below; historical rows retain their original status.

## Current follow-up status

| Observation | Current evidence |
|---|---|
| CLI discovery omissions / `agent-help` output ambiguity | Fixed in `e0f6544`; signed CLI contract and live compatibility checks passed. |
| macOS 27 inactive Language Chooser / framebuffer replay | Guarded activation and replay-policy fixes validated; complete SIP/AMFI status workflows passed. |
| Recovery Terminal marker recognition | Bounded prompt-punctuation and word-encoding/output-separation fixes validated; not a claim of universal OCR reliability. |
| macOS 26 first-owner desktop readiness / cleanup | Same-job cleanup-verified retry and pinned reconnect adapter implemented. Three fresh signed-candidate SIP cycles passed, including a live Aqua timeout recovered after instrumentation cleanup; original intermittent signal delay and earlier console transport failure remain unexplained. |
| macOS 27 creation `ownerProof` | Open; subsequent internal-drive baselines passed, including fresh creation with the exact original `ffc41a7` host, without a targeted fix. |
| macOS 26 creation `verifyNormalAgent` / slow first boot | Open historical failure; subsequent internal-drive creations passed, including a fresh original-`ffc41a7` run with first-attempt verification receipts, without establishing its cause. |
| macOS 27 restart after pause/resume | Open; two earlier internal-drive sequences plus ten-cycle runs with both current `a3852a5` and original `ffc41a7` hosts passed without reproducing the missing helper. |
| Retained SIP private-PTY / pinned-authentication failures | Open historical observations; a fresh original-`ffc41a7` SIP disable/enable cycle passed without producing the failed transaction needed to test that resume sequence. |
| TUI status projection / boot-mode warning | Fixed in `3fb1ccb`; canonical state/agent regression tests and live running, paused, resumed, and stopped display comparisons passed. Boot-mode warning cancellation preserved both running and paused sessions. |
| Integrated test-suite concurrency hang | Test-peer thread isolation in `0291f65` removes the observed hang in the focused stress run and subsequent full parallel comparisons. Signed Release and live execution/timeout smoke checks passed. Reconnect fixture admission now has a red/green delayed-start regression, passing repeated parallel comparison, and a 1,166-function full pass; other stress-run timeout failures keep full-suite reliability open. |
| Private-PTY logical test timing | Fixed in `f7a6139`: injected-clock regressions verify prompt/process deadlines and cleanup without parallel scheduling determining logical test time; production retains `ContinuousClock`. Focused/repeated checks and a 1,168-function full run passed. Signed Release live owner authentication and a complete SIP disable/enable cycle passed, restoring SIP enabled and the stopped VM state. |
| Coordinator-pin fixture polling | Fixed in `f3dfff6`: checks readiness after delayed sleep with cancellation precedence and bounded unavailability. Deterministic red/green, ten-pass full-workload coordinator checks, and a 1,170-function full pass succeeded. Signed Release/live start, execution, restart, reauthentication, and stopped-state restoration passed. Production pin/authentication behavior is unchanged; other stress failures remain open. |
| Daemon socket-admission fixture timing | Fixed in `ca45976`: waits for actual serving-task entry before starting the response-read budget, with separate bounded/cancellable setup. Delayed-start red/green, timeout/cancellation safeguards, full ten-pass socket checks, and a 1,175-function full pass succeeded. Signed Release/live agent status, execution, and stopped-state restoration passed; production daemon and Recovery one-shot test are unchanged. |
| Recovery one-shot daemon fixture timing | Fixed in `fc4e4bf`: separates serving-task admission from the response budget without weakening natural one-shot completion or replay assertions. Delayed-start red/green, setup timeout/cancellation checks, ten-pass one-shot checks, and a 1,178-function full pass succeeded. Signed Release/live authenticated SIP status and stopped-state restoration passed; production daemon behavior is unchanged and other stress failures remain open. |

This is an observational live test. The CLI and guest images are not being
modified during the sweep. Every failure, timeout, unexpected state, and
environmental limitation is appended below with its command and timestamp.

## Scope

- Destroy all Pomme-managed VMs found in the explicitly selected state roots.
- Create fresh disposable macOS 27 and macOS 26 VMs on the LACIE state root.
- Exercise every public CLI verb and available option where the fresh VM and
  current host capabilities make the operation meaningful.
- Record expected destructive effects and observed behavior; do not fix source
  or retry a failed operation with altered inputs unless the test matrix calls
  for the next independent case.

## Initial inventory — 2026-09-22T02:22:30Z

Installed runner: `pomme 0.1.0 (ffc41a7)` at `/Users/wes/.local/bin/pomme`.

State roots inspected:

- `/Users/wes/Library/Application Support/pomme`
  - `pomme-agent-recovery-debug-20260921b`: macOS 27, running, helper and
    normal agent connected.
- `/Volumes/LACIE/pomme-macos27-private/pomme`
  - `pomme-agent-macos27-option-sweep-20260922`: macOS 27.0 (26A428), 4 GB,
    40 GB, stopped, incomplete/pending automatic login.
  - `pomme-agent-macos27-option-sweep-8gb-20260922`: macOS 27.0 (26A428),
    8 GB, 40 GB, stopped, automatic login enabled, Remote Login off.

Available storage at inventory: 58 GiB on the system data volume and 818 GiB
on `/Volumes/LACIE`.

Available signed restore images include macOS 27.0 (26A428) and macOS 26.6.2
(25G83). The macOS 26 image is an experimental/unreviewed live case for this
sweep.

The live matrix covers lifecycle, guest execution, jobs, sessions, file copy,
SIP/AMFI, MDM/access services, snapshots, templates, config/IPSW, UI, TUI,
global output/debug flags, and hidden utility/help surfaces. Host-only parser
checks are recorded separately from guest-backed results.

## Issue log

| UTC time | Platform/command | Observation | Classification |
|---|---|---|---|
| 2026-09-22T02:22:34Z | macOS 27/default `delete --force` | Delete refused while the VM was running: `Stop the VM before deleting it.` | Expected lifecycle guard; continued with explicit stop then delete |
| 2026-09-22T02:22:40Z | All known roots | Stopped the running default VM, deleted it, then deleted both isolated macOS 27 VMs. Both `pomme list` inventories are now empty. | Destructive setup completed |
| 2026-09-22T02:23:00Z | `ipsw list` | Host resolved signed macOS 27.0 (26A428) and macOS 26.6.2 (25G83), plus older signed images. | Inventory |
| 2026-09-22T02:24:00Z | `tools --format json`, `agent-help` | Read-only option inventory shows `sessions` and `template` in root help/source but omitted from these machine-readable utility/help surfaces. | Discovery issue; no fix attempted |
| 2026-09-22T02:35:44Z | macOS 27 create | Restore completed enough to begin installation; CLI warned Recovery support for 27.0/26A428 is experimental and reported install progress 0%. | Expected experimental qualification warning |
| 2026-09-22T03:15:19Z | macOS 27 create | Fresh 4 GB VM completed restore, bootstrap, SSH/UID verification, staging, installer, and agent connection, but framework `ownerProof` failed after normal reboot: `The normal guest owner identity could not be verified.` VM was retained running with a healthy connected agent; automatic login remains pending. | Live failure; no fix attempted |
| 2026-09-22T03:26:24Z | macOS 27 `agent status --debug` / `sip status` | `agent status --debug` unexpectedly entered Recovery navigation. The following `sip status` timed out waiting for `recoveryUtilities` with `lastObserved=unknown`; the batch was cancelled before repeating the same wait for AMFI/access status. VM was restored stopped afterward. | Live Recovery navigation failure; no fix attempted |
| 2026-09-22T03:28:00Z | macOS 27 `exec --pty`, `sessions attach` | Both commands correctly rejected the non-interactive harness: `requires an interactive terminal for standard input and output` / `Terminal session attachment requires interactive stdin and stdout`. | Environment limitation; not classified as guest failure |
| 2026-09-22T03:18:00Z | macOS 27 sessions | Detached shell session list/inspect/logs/terminate worked. Immediate delete after terminate was refused until the session reached `exited`; delete then succeeded. | Lifecycle sequencing observation |
| 2026-09-22T03:30:00Z | macOS 27 `pause`, `resume`, `restart` | Pause/resume returned success and the agent reconnected, but `restart --mode normal` failed: `No running VM helper is listening at ...pomme-c54982e2380a2.sock`. The VM ended stopped with helper/agent disconnected. | Live lifecycle failure; no fix attempted |
| 2026-09-22T03:32:41Z | macOS 27 config | `config validate` and `config render` passed against the existing multi-VM YAML fixture and resolved both planned selectors without mutation. | Expected host-side behavior |
| 2026-09-22T03:37:39Z | macOS 27 snapshots | Snapshot create/list/restore/delete all completed. List and restore reported expected `disk, auxiliaryStorage` backing-file drift; restore required `--force` and left the VM paused, then resume/reconnect succeeded. | Expected documented drift warning |
| 2026-09-22T03:40:00Z | macOS 27 access services | Remote Login status reported `On`; disable failed with `remote-login-full-disk-access-required`, enable returned enabled. Screen Sharing status was unavailable because this agent lacks Screen Sharing support. | Host privilege/capability limitations |
| 2026-09-22T03:42:00Z | macOS 27 UI | `ui keys`, key, key-sequence, type, and click returned success; screenshot failed with `frame_invalid` because the framebuffer was blank. UI AI settings reported unavailable in this build even with its option set. | Headless/display capability limitation |
| 2026-09-22T03:43:00Z | `config init` formats json/yaml/toml/pkl | All four formats rejected the non-interactive harness with `config init requires an interactive terminal`; no files were written. | Environment limitation |
| 2026-09-22T03:44:00Z | `tools --format json`, `agent-help --format json` | `tools` omitted `sessions`/`template`; `agent-help` omitted them and rejected its documented-looking `--format` option as unknown. Plain `agent-help` returned its text inventory. | CLI surface/documentation mismatch; no fix attempted |
| 2026-09-22T03:45:00Z | macOS 27 `mdm` | MDM invocation with a missing profile and both enrollment-mode/guest-path/force-related inputs was rejected early with `invalidJournal` because the VM’s durable create journal remains incomplete. | Expected safety guard for incomplete provisioning; no fix attempted |
| 2026-09-22T03:49:05Z | macOS 27 `amfi status --debug` | Recovery navigation saved four action PNGs plus `timeout-awaiting-recoveryUtilities`; observation timed out with `lastObserved=unknown`, then the command returned `Recovery display observation timed out`. Normal VM state was restored and the agent remained connected. | Live Recovery failure; screenshots retained |
| 2026-09-22T03:50:00Z | Recovery screenshot artifacts | All five retained files were valid 1280×800 RGBA PNGs. Directory mode was 0700 and file mode was 0600; the timeout image was retained after failure. | Expected debug-artifact behavior |
| 2026-09-22T03:51:00Z | macOS 27 template/IPSW | `template list` returned empty; deleting a missing template produced the expected named-template error. `ipsw download 27.0 --device Macmini9,1` reused the cached signed image and returned 26A428 without downloading. | Expected host-side behavior |
| 2026-09-22T03:55:10Z | macOS 27 cleanup | `stop --force --debug` returned forced stop, and `rm --force --debug` deleted the fresh macOS 27 VM. The isolated sweep root is empty before macOS 26 creation. | Destructive phase transition completed |
| 2026-09-22T04:33:25Z | macOS 26 create | Fresh 4 GB VM completed Recovery navigation through Terminal and launcher submission, saving 11 ordered action PNGs, but `verifyNormalAgent` failed with `internal.unknown` after roughly five minutes. The VM/journal were retained; `status`/`inspect` show a running normal VM with helper healthy, normal guest agent disconnected, `guestProvisioning=recovery`, and `hostExitCode=0`. | Live bootstrap failure; no fix attempted |
| 2026-09-22T04:35–04:40Z | macOS 26 `pause`/`resume`/`restart`/`start` | Pause/resume succeeded. Restart stopped the VM; `start --mode normal` waited roughly five minutes, then succeeded and the normal guest agent connected with the full capability set. This recovered the retained VM without source changes. | Slow first normal boot; live timing issue |
| 2026-09-22T04:44–04:50Z | macOS 26 `sip status --debug` | Recovery navigation completed and saved 11 action PNGs, but Terminal marker proof failed on all 20 attempts (`exactMarker=false`, `freshPromptAfterMarker=false`); command ended `Recovery Terminal capability proof failed`. VM was restored to running normal with agent connected. | Live Recovery capability failure; no fix attempted |
| 2026-09-22T04:51–04:59Z | macOS 26 `amfi status --debug` | Recovery navigation completed; marker proof passed on attempt 2; AMFI status returned verified full security (`amfiDisabled=false`, `securityMode=full`, `finalState=previous`) and restored the VM. 11 action PNGs were retained. | Expected success |
| 2026-09-22T04:59:00Z | macOS 26 Recovery artifacts | The create, SIP, and AMFI screenshot directories are mode 0700 and all PNGs mode 0600; `file` validates every image as 1280×800 8-bit RGBA PNG. No timeout frame was emitted because these attempts reached Terminal; artifacts remain in the system temporary directory after command completion. | Expected debug-artifact behavior |
| 2026-09-22T04:59–05:01Z | macOS 26 `agent repair` / `create --resume` | `agent repair --final-state previous` correctly refused during retained `verifyNormalAgent`; `create --resume --debug` then succeeded and finalized with `finalState=stopped`. A subsequent normal start with `--timeout 300` waited about five minutes and connected the agent, but the guest still has no `pomme` user (`id pomme`: no such user); the VM remains `automaticLogin=legacy`, `guestProvisioning=recovery`. | Resume closes journal but does not establish a normal owner identity |
| 2026-09-22T05:05–05:14Z | macOS 26 `sip disable` | Without `--force`, the command correctly required interactive confirmation for owner creation. With `--force`, it created/verifed `pomme` but failed native Setup Assistant Aqua-session verification. Resuming with `--final-state previous` progressed through owner verification/automatic-login readback, then the private owner PTY timed out; security progress was retained and the VM restored running. | Live owner-session/PTY failure; retained transaction requires cleanup/resume |
| 2026-09-22T05:14–05:15Z | macOS 26 `amfi disable` / SIP resume | AMFI correctly refused while the unfinished SIP transaction owned the VM. A second SIP resume then failed creation-pinned normal-agent authentication. No AMFI mutation was performed. | Live retained-security-operation/authentication failure |
| 2026-09-22T05:15:39–05:15:43Z | macOS 26 cleanup | Forced stop and `rm --force` deleted the disposable macOS 26 VM despite the retained SIP transaction. `pomme list` and a scoped bundle search show the LACIE sweep root has no VMs. | Destructive cleanup completed |

## macOS 26 guest and host option results

- `status`/`inspect`/`list`/`ls`, table/JSON/JSONL output, lifecycle pause/resume/restart/start/stop/delete, guest `exec` (cwd/env, root user/group, UID/GID, timeout, stdin, guest stdin/stdout/stderr), `cp`, `cat` offset/count, detached jobs, job inspection/output/wait/TERM, shell expressions, durable sessions (list/inspect/logs/terminate/delete), snapshots, config validate/render, IPSW list/download, UI keys/key-sequence/type/click/screenshot, Remote Login, Screen Sharing, MDM guards, agent status/repair, SIP/AMFI status, and global debug paths were exercised.
- Guest-dependent commands that need the created owner initially exposed the missing `pomme` account; forced SIP owner preparation created it, after which `--user pomme --group staff` succeeded. The native Aqua/PTY path remained unavailable, so SIP disable could not proceed.
- macOS 26 screenshot output was valid 1280×800 RGBA PNG; ordinary UI screenshot was valid but visually blank/black with a cursor. The Recovery debug directories/files were retained with 0700/0600 permissions.
- Interactive-only surfaces (`exec --pty`, `sessions attach`, `tui`, `config init`) rejected the noninteractive harness as expected. Template creation from a missing source rejected without leaving a VM; template list and missing delete were exercised.

## Final state

Both fresh macOS 27 and macOS 26 disposable VMs were stopped and deleted. No Pomme VM bundles remain in `/Volumes/LACIE/pomme-live-option-sweep-20260922/pomme`; Recovery screenshot directories remain in the host temporary directory for post-run inspection. No source or installed CLI changes were made during this sweep.

Final scoped inventories at 2026-09-22T05:16Z were empty for the default root, the prior `/Volumes/LACIE/pomme-macos27-private/pomme` root, and the new sweep root.

## Follow-up investigation — 2026-09-22

The observations above are preserved as recorded. Review of the current
creation contract clarifies that the macOS 26 missing-owner observation at
04:59–05:01Z is not, by itself, a failed creation postcondition. The Recovery
route installs and verifies the persistent agent; owner preparation is a
separate security/provisioned-template step. `guestProvisioning=recovery` and
`automaticLogin=legacy` describe that route, not an unfinished phase. See
`README.md` under durable creation and provisioned templates. The preceding
`verifyNormalAgent` failure and subsequent owner-session/security failures
remain unresolved.

The first fix investigation targets the explicit macOS 27 framework
`ownerProof` failure. Baseline build `d780b81` was built and installed with
`Scripts/build-local.sh`, passed signature/entitlement/requirement checks,
and passed all 88 CLI contract checks; the installer regression suite passed
all 21 checks. The disposable baseline VM is
`pomme-agent-ownerproof-20260922a`, using local macOS 27.0 (26A428), a 40 GB
disk, and 4 GB RAM. Its bundle and restore image are on the internal drive
under `/Users/wes/Library/Application Support/pomme`.

At 06:05:20Z, the unchanged baseline completed successfully. Restore began at
05:56:54Z; owner proof passed between 06:04:49Z and 06:05:12Z, desktop proof
passed, Remote Login was disabled, and creation restored the requested stopped
state with automatic login enabled. Both focused owner-verification suites also
passed (80 tests). The earlier failure is not reproduced on this internal-drive
run; this does not establish its cause or justify a product fix. It remains open
pending a failing reproduction. The next sequential investigation uses this
same disposable VM for the reported pause/resume/restart failure.

The initial pause/resume/restart sequence passed at 06:07Z, with a clean guest
shutdown and a new connected helper. `agent status --debug` stayed in normal
macOS. `sip status --debug` then reproduced the Recovery failure: after the
English-language confirmation at 06:09:30Z, it waited five minutes for
`recoveryUtilities` and reported `lastObserved=unknown` at 06:14:30Z. The
retained timeout PNG is byte-identical to the pre-input PNG, showing English
selected in Language Chooser. A first image rendering appeared blank, but
reopening the full image and comparing SHA-256 corrected that interpretation.
This alone cannot distinguish replayed pixels from a key that did not advance
the guest. The command failed and restored normal macOS with
a connected agent. A second pause/resume/restart sequence after that failure
also passed. The restart defect remains unconfirmed on internal storage.

Normal display capture subsequently returned a boot image followed by the
logged-in desktop; `/dev/console` was `pomme:501`, and Dock/Finder were running.
The Recovery failure is being investigated at the framebuffer publication and
observer-registration boundary. No navigation or security guard has been
relaxed, and no fix is claimed from these probes.

### Frame publication candidate

The production presenter-association path previously suppressed synchronous
cached-frame completion only on the first registration. Later captures detach
and re-register the observer, but could accept the synchronous replay as their
result. The candidate applies replay suppression to every native association,
retaining the surface for a subsequent fresh full-frame or damage callback.
Re-registration, source-identity validation, ABI qualification, and navigation
guards are unchanged.

A regression at the actual registration-policy seam reproduces this behavior
across three registrations. With the old policy, the new parameterized test
failed while the other 22 capture tests passed. With the candidate, all 23
capture tests passed via XcodeBuildMCP. The test also checks old-source callback
rejection and both full-frame and damage-only publication. This establishes
the replay-policy change, not yet the cause or resolution of the live Recovery
timeout. Signed Release and live validation follow the candidate commit.

Candidate `ef37f16` was signed and installed successfully. A fresh helper on
the same VM passed repeated static Recovery captures and a changed-screen
capture after one Right key; the changed image matched the baseline's known
selected-disk image. Each repeated capture completed in about 20–25 ms, with
no static-screen timeout. All 88 CLI contract checks passed. Cold initial
capture can still show the boot-time black/cursor frame; the change does not
claim to establish visual readiness by itself.

### Language Chooser activation evidence

A manual baseline probe with the prior helper isolated the navigation defect:
two stable Language Chooser images showed English highlighted gray. Return did
not advance this inactive window. One click on the visible Continue arrow
activated the window (English became blue) without advancing it. After two
stable active-window images, one Return opened Recovery Utilities immediately.
All inputs were single events bounded by observed screens; no security change
was performed. The next change must prove window activation before language
confirmation, rather than treating the inactive chooser as ready for Return.
Both manual probes ended with the disposable VM stopped.

### Guarded macOS 27 activation change

The new experimental route is limited to canonical macOS `27.0.0` build
`26A428`. Navigation represents keyboard and fixed language-activation input
as distinct actions. The classifier checks the exact English label and
Language heading geometry plus the selected row's gray/blue highlight; OCR
text alone cannot authorize activation or Return. An inactive chooser permits
one fixed Continue click. Two stable active-English frames are required before
Return. An already-active chooser skips the click, and a click that reaches
Utilities skips Return. Unknown/unstable observations or uncertain delivery
retain the existing cleanup requirement rather than retrying input.

Other routes, immutable profile descriptors/digests, journals, and security
policy are unchanged. Offline and live validation results will be recorded
below before this issue is considered fixed.

The classifier-to-interaction regression failed before implementing the
selection proof and passed afterward. A temporary rehearsal then exercised the
production Vision OCR recognizer on the private inactive/active screenshots,
including regional OCR reuse. It exposed an English confidence of `0.5`, so
the exact-label confidence bound was corrected to accept that observed value
while retaining the geometry and 80-percent row-color requirements. Both
private screenshots then classified correctly. The temporary image-backed test
was removed; raw screenshots are not committed. Permanent synthetic coverage
locks down the confidence boundary as well as stale/unknown frames, uncertain
delivery, mismatched receipts, and alternate observed branches.

The final five focused XcodeBuildMCP suites passed all 68 tests, with no
failures or skips: language activation, interaction, profile selection,
virtualization observation readiness, and incremental navigation recognition.
The local build/install regression script also passed all 21 checks. These are
offline results; the signed build must still pass the original live SIP-status
workflow before the Recovery navigation issue is closed.

Signed Release `385ac5f` was installed with all signing/entitlement checks
passing, and all 88 CLI contract checks passed. Its live `sip status` attempt
started at 06:47:52Z on the same stopped internal-drive macOS 27 VM. The
inactive chooser was recognized; the activation event's pre-input screenshot
was saved at 06:49:12Z. At 06:54:13Z, observation timed out with
`expected=languageEnglishActive, lastObserved=recoveryUtilities`. The timeout
image visibly shows Recovery Utilities and the pointer at Continue. The click
advanced the guest, but a transient active-English post-click pair had already
committed the route to waiting for active English again before Return. No
Return event followed the click. The command exited with failure and the
original stopped state was restored. This candidate is therefore not a complete
fix; the asynchronous Continue transition needs to be addressed before another
signed build and live retest.

A subsequent single-event manual probe selected the already-highlighted English
row at `(640,343)` instead of Continue. It activated the chooser and remained
there across repeated identical screenshots; a second, separately observed
click on the active row did not advance it. One Return then reached Utilities.
However, the production OCR rehearsal classified the active screenshot as
unknown with the cursor over the English label. The next bounded probe moves
the activation point to the blank left side of the same proved row, avoiding
the text. No security state was changed in these navigation probes.

The next boot reached an already-active chooser, exercising the other observed
entry state. One click at `(550,343)` on the blank left side of the selected
English row left the chooser active with identical post-event screenshots and
the English text unobscured. This run does not by itself prove the inactive
entry branch for that exact point; the subsequent full automated retest must
cover that branch.

The production regional OCR rehearsal recognized the left-side-pointer image
as active English (one test passed); its temporary image-backed test was then
removed. The production dispatcher now uses `(550,343)`. A recording-backend
regression exercises that actual dispatcher and rejects the old Continue
coordinates (one expected failure, 15 other port tests passed). It verifies one
click and no keyboard event. This changes only the fixed activation target;
the exact build scope and frame/receipt guards remain in place.

All 69 permanent tests across the same five focused XcodeBuildMCP suites passed
after the target change, with no failures. Signed build and full live retest
follow this commit; manual navigation is not a substitute for SIP-status
completion.

Signed Release `e9076c6` passed signing/entitlement/requirement checks and all
88 CLI contract checks. The original macOS 27 `sip status --debug` retest
started at 07:05:29Z. It proved the inactive chooser, activated the selected row
at 07:06:51Z, proved active English, sent Return at 07:06:53Z, reached Utilities
at 07:06:58Z, and verified Terminal at 07:07:07Z. This validates the previously
failing inactive-to-active branch in the complete production navigation path.
The original Language Chooser timeout no longer reproduced.

The command nevertheless failed the subsequent Terminal capability proof:
all 20 attempts reported `terminalWindow=true, exactMarker=false,
freshPromptAfterMarker=false`, and the probe was rejected at 07:07:23Z.
It exited with `Recovery Terminal capability proof failed` and restored the
stopped state. SIP status is not yet end-to-end successful. Investigation now
moves to the separately observed Terminal marker failure; the activation
change is retained with its live navigation evidence, not represented as a
successful security-status command.

The macOS 26 compatibility `sip status --debug` run on `e9076c6` began at
07:08:16Z and completed successfully. Its unchanged five-input direct-Terminal
route reached Terminal at 07:09:43Z; marker proof passed on attempt 1 at
07:09:45Z. The authenticated, request-bound Recovery session returned verified
`sipEnabled=true`, finalized with all cleanup fields true, and verified the
previous stopped state. The historical macOS 26 marker failure did not
reproduce in this internal-drive run. The current repeatable marker failure
is on macOS 27 after its now-successful navigation.

### Terminal marker investigation

A scoped manual macOS 27 Recovery session tested benign fixed markers only.
The simple marker printed with a fresh prompt; `/sbin/mount_virtiofs` was
executable and `/sbin/sha256 -q` produced the expected `abc` digest. The
production-shaped conditional command then printed both an eight-character
test marker and a ten-character marker using the production-safe alphabet.
Temporary tests through the production Terminal OCR/proof path passed for all
three private screenshots; those tests were removed without committing images.
The same conditional probe also printed after retracing the production menu
sequence into a fresh Terminal window. These slower manual probes do not
reproduce the automated failure and do not establish its cause. The VM was
stopped again before repeating the original automated command unchanged.

The unchanged macOS 27 SIP-status repeat on `e9076c6` started at 07:22:19Z
and passed end to end. Inactive English activation and Return passed again;
Terminal was verified at 07:23:55Z and marker proof passed on attempt 1 at
07:23:57Z. The authenticated request-bound session returned verified SIP
enabled, all cleanup fields true, and `finalStateVerified=true` for the prior
stopped state. This supplies full-workflow validation for the activation fix.
The marker failure is intermittent, not consistently reproducible; no marker
implementation was changed and no cause is claimed from the successful retry.

The macOS 27 AMFI-status regression on the same build began at 07:25:04Z and
also passed end to end. It exercised inactive-English activation again,
verified Terminal at 07:26:39Z, and passed marker proof on attempt 1 at
07:26:41Z. The finalized authenticated session reported verified Full Security,
`amfiDisabled=false`, all cleanup fields true, and verified restoration of the
previous stopped state. Both originally blocked status workflows now have
successful live results after the activation fix. Marker reliability remains
an open intermittent observation rather than a claimed marker fix.

For compatibility, `pomme-agent-recovery26-20260922a` was created on internal
storage from macOS `26.6.2 (25G83)` with a 40 GB disk and 4 GB RAM, using
signed build `ef37f16`. Restore began at 06:32:22Z; the existing five-input
Recovery route reached Terminal at 06:38:00Z and passed marker proof on attempt
1. Creation then completed successfully and restored the requested stopped
state. The sweep's macOS 26 bootstrap failure did not reproduce in this run.

### macOS 26 SIP-disable baseline

With the Recovery activation change validated and documented, the next
sequential baseline used `e9076c6` on the same internal-drive 4 GB/40 GB macOS
26 VM: `sip disable --force --final-state previous --format json --debug`.
It began at 07:27:42Z, created and verified `pomme`, passed login restrictions,
and completed the native Setup Assistant handoff at 07:29:01Z. This run did
not reproduce the sweep's initial Aqua-session rejection.

Automatic-login configuration reached its readback receipt at 07:29:12Z.
Owner completion returned status 1, triggering the existing single normal-boot
retry at 07:29:13Z. Owner verification passed again at 07:29:33Z, but the next
global automatic-login readback failed with the closed native-state error.
The operation retained `phase=autologinIntent`, `operation=sipDisable`,
`requestedFinalState=previous`, and original state stopped; the VM was verified
stopped after failure. No SIP mutation stage was reached. This new red is being
investigated before any credential, journal, or automatic-login policy change.

Read-only normal-agent probes after a separate diagnostic boot found native
automatic login OFF, the global `autoLoginUser` key absent, and `/etc/kcpassword`
present with metadata `0:0:600` (contents were never read). Both owner completion
preferences were absent with the expected native diagnostic; the owner home,
Library, and Preferences directories had correct UID 501 ownership. The console
was still `_mbsetupuser:248`.

The supported same-operation/same-final-state resume began at 07:36:15Z without
source changes. It reused the retained owner credential, configured automatic
login, passed owner completion at 07:36:28Z, and finished Setup Assistant at
07:36:31Z. After the normal reboot, desktop verification instead failed at
07:37:30Z with `normal-agent-aqua-timedOut`: `stage=aqua, exited=false,
outputComplete=false, terminationRequested=true`. No security mutation was
reached. The preference-write failure did not repeat; the current investigation
is the later bounded Aqua process timeout, not a claimed preference fix.

A diagnostic normal boot at 07:45:10Z ran the same shell/`launchctl print
gui/501` command with stdout redirected to `/dev/null` through public guest
execution, explicitly as root. It completed within its 15-second deadline
with exit 0 and no output; `/dev/console` reported `pomme:501`, and
`/usr/bin/true` also completed. This is not an identical host transport replay:
the security path has an additional outer deadline and uses the daemon's
default identity rather than explicit UID/GID options. The VM was stopped
again before retrying the original workflow.

The unchanged, supported SIP-disable resume began at 07:46:46Z on `e9076c6`.
Owner completion and Setup Assistant completion passed, and desktop verification
ran from 07:47:54Z until the workflow advanced to Recovery at 07:48:21Z.
The normal desktop proof therefore passed without a code or policy change.
Recovery reached Terminal at 07:50:19Z; marker proof passed on attempt 2.
SIP disable then completed with `normalBootVerified=true`,
`runtimeConfigurationVerified=true`, `enforcementVerified=true`, and verified
restoration of the previous stopped state. No credentials, agent pins, or
journal contents were manually changed. A concurrent public process-list probe
was rejected by the existing mutation lease; no bypass was attempted.

This supplies an end-to-end successful retained retry, not a fix for the
earlier Aqua timeout. That timeout remains an intermittent observation. SIP
enable started at 07:51:46Z to restore the original security setting and
completed successfully after normal-boot verification at 07:55:37Z. It
reported `configuredDisabled=false`, all three normal-boot/runtime/enforcement
verification fields true, and verified restoration to stopped. Its Recovery
marker proof passed on attempt 1. Both directions therefore completed on the
unchanged signed build; the intermittent failure remains open without a
speculative timeout increase or relaxed desktop proof.

### CLI command discovery consistency

The next isolated issue is the missing `sessions` and `template` command
families in `tools` and compact `agent-help`. The signed `e9076c6` baseline
still exposes both families in root help but omits both from discovery.
`agent-help --format json` exits 64 because the command has no shared output
options, even though its default text advertises those options for the broader
CLI. This is a help-contract ambiguity, not evidence that its old parser
implemented structured output.

The candidate adds both families to the shared catalog, derives compact
top-level inventory text from that catalog, and gives `agent-help` the existing
shared output options. Its default remains compact text. JSON uses the same
schema-version-2 discovery payload as `tools`; JSONL emits one group per line.
The README documents these representations. No VM or security behavior changes.

Before implementation, the expanded CLI contract suite ran against the old
installed binary: 104 checks, with exactly nine expected discovery/format
failures and all prior 88 checks passing. The new checks compare registered
root commands and aliases against both inventories, verify session/template
leaf discovery, compare structured payloads, and exercise invalid/conflicting
format options. All 21 local build/install regression checks also passed.
Signed Release and live verification follow the candidate commit.

Candidate `e0f6544` was committed before building and installed through
`Scripts/build-local.sh`. XcodeBuildMCP Release/arm64 build and all exact
signature, entitlement, designated-requirement, and archive checks passed.
A fresh login shell resolved `/Users/wes/.local/bin/pomme`, reporting
`pomme 0.1.0 (e0f6544)`. All 104 CLI contract checks passed against that signed
installed binary, including the nine baseline failures.

For the requested live check, the same internal-drive macOS 26 VM was started
normally at 08:04:07Z with unchanged 4 GB/40 GB resources and its original
creation-pinned guest agent. `sessions list --format json --debug` succeeded
with a connected agent and an empty session list at 08:05:00Z. Host-side
`template list --format json --debug` returned an empty inventory, and
`agent-help --format json --debug` included both newly discoverable families.
Guest `/usr/bin/true` completed and native `csrutil status` still reported
SIP enabled. Graceful stop restored the VM to stopped. This validates the
discovery fix and basic live compatibility; it does not claim to retest
template creation or resolve the unrelated intermittent Recovery/Aqua issues.

### Terminal marker repeatability and diagnostic gap

Three unchanged macOS 27 SIP-status runs on signed `e0f6544` began at
08:06:57Z, 08:09:38Z, and 08:12:14Z. Each used the same internal-drive
`pomme-agent-ownerproof-20260922a` with 4 GB RAM and a 40 GB disk. Marker
verification passed on attempt 1 at 08:08:36Z, 08:11:17Z, and 08:13:51Z,
respectively. All three finalized authenticated, request-bound sessions,
reported SIP enabled, proved cleanup, and restored the previous stopped state.
The third run entered an already-active Language Chooser, while the first two
exercised the inactive activation branch. None reproduced the earlier marker
failure, and none is evidence of a marker fix.

The existing failed-run diagnostics show Terminal recognized but no exact
standalone marker or fresh prompt below it. They cannot distinguish a missing
command echo, a misrecognized marker-shaped output line, or unchanged captures.
The next diagnostic-only change will expose closed command-echo/near-marker
booleans and whether existing consecutive marker captures differ. It will not
add captures, record Terminal screenshots or OCR text, print markers or image
digests, or alter configured input delays, attempt limits, and strict proof
acceptance.

Consecutive-frame equality can suggest an unchanged observation, not prove that
the capture is stale. Diagnostic regression coverage and signed live validation
will be recorded before claiming that this instrumentation is useful.

The diagnostic candidate uses a fixed non-secret command-prefix witness and
whole-line marker shape; neither diagnostic participates in `isVerified`.
`frameChangedSincePreviousAttempt` is `unknown` for the first capture or a
failed best-effort hash, and otherwise compares only adjacent captures within
one verification call. It performs no extra capture, stores no image, and
discards comparison state on return or failure. The temporary closed log line
is tagged `[DEBUG-marker-20260922]` for removal after the investigation.

The focused Terminal-recognition and virtualization-port suites demonstrated
four expected diagnostic failures with inert false/unknown implementations
(21 other cases passed), then all 25 cases passed with the implementation.
Coverage includes echo/near-marker rejection by strict proof, exact redacted
rendering, independent frame-comparison calls, and a diagnostic hash failure
that leaves a valid proof intact. These tests validate instrumentation, not
reproduction or resolution of the intermittent marker failure. The green
XcodeBuildMCP result is
`test_macos_2026-09-22T08-18-38-433Z_pid60265_d337737e.xcresult`.

Read-only review found no proof-gate or redaction regression. The diagnostic
limits are intentional: `commandEcho` means the fixed witness is visible in
OCR and can include scrollback; it is not a receipt for this submission.
`nearMarker` means a standalone nonexact marker-shaped line, not a measured
edit distance from the requested marker; it can include older output. Neither
field, nor adjacent-frame equality, establishes the cause of a failure alone.

Diagnostic candidate `0f030b4` was committed, built and installed through the
canonical signed Release workflow, and passed all 104 CLI contract checks.
The first live macOS 27 SIP-status run began at 08:21:24Z and finalized
successfully with SIP enabled, verified cleanup, and restoration to stopped.
At 08:23:03Z its marker proof passed on attempt 1 while the new evidence line
reported `commandEcho=false`, `nearMarker=false`, and adjacent-frame comparison
`unknown`. Thus false echo evidence is not evidence of missing input, even on
a successful current run. The fixed echo witness is being checked against the
retained benign manual-probe images before using it to interpret a failure.
No marker-reliability fix is claimed.

Four temporary image-backed rehearsals then used the production OCR/proof
path on retained benign manual-probe captures. All four passed the current
echo witness, simpler fixed-witness variants, and strict marker proof. They
did not reproduce the live false-echo condition, so no production recognizer
change followed. Temporary tests/imports and private path references were
removed; no images or OCR text entered source control or logs. Result:
`test_macos_2026-09-22T08-26-29-480Z_pid62089_639a636c.xcresult`.

The unchanged diagnostic build also passed the internal-drive macOS 26
SIP-status compatibility run begun at 08:26:50Z. Its five-input route reached
Terminal at 08:28:18Z and strict marker proof passed on attempt 1 at 08:28:20Z.
Closed evidence was `commandEcho=true`, `nearMarker=false`, and first-attempt
frame comparison `unknown`. The session finalized with verified SIP enabled,
all cleanup fields true, and verified restoration of the previous stopped
state. The new diagnostics have successful live coverage on both OS versions;
a failing instrumented run is still needed to investigate the original
intermittent failure. Temporary diagnostics remain explicitly investigative.

The next unchanged instrumented macOS 27 SIP-status run began at 08:30:43Z.
It again passed strict marker proof on attempt 1 at 08:32:21Z, with
`commandEcho=false`, `nearMarker=false`, and first-frame comparison `unknown`.
The session finalized with SIP enabled, verified cleanup, and restoration to
stopped. Since full workflows are not currently reproducing the failure, a
temporary deterministic, memory-only synthetic Terminal corpus is being used
to test marker spelling sensitivity through the production OCR/proof path.
This cannot by itself establish the cause of the historical live failure.

The ordinary synthetic `ACDEHJKMNP` baseline passed. Two identical 64-case
corpus runs then produced the same seven strict-proof misses in 5.371 and
5.398 seconds of test execution. Every miss still recognized Terminal but
reported `exactMarker=false` and `freshPromptAfterMarker=false`. The generated
suffixes were `HHHHHHHHHH`, `QQQQQQQQQQ`, `EHEHEHEHEH`, `QRQRQRQRQR`,
`AQDKQRQPEK`, `UDKYTRQNDN`, and `KMRQNQMPKE`. No images were persisted and
no production code changed. A real Recovery Terminal comparison of the mixed
case `AQDKQRQPEK` is the next step; a synthetic miss alone does not justify a
live-workflow fix.

The paired synthetic spacing experiment kept the same 64 suffixes and strict
proof requirements. Adding spaces between suffix characters increased misses
from 7/64 to 22/64: 20 recognized the exact marker but lacked fresh-prompt
proof, and two missed the exact marker. Character spacing is therefore not a
supported fix. No production marker format changed.

The retained internal-drive macOS 27 VM was then manually navigated into
Recovery Terminal using stable pre/post frame pairs. A benign `printf` printed
`POMME AQDKQRQPEK OK` correctly with a fresh prompt visibly below it. Initial
production OCR replay of two byte-identical captures passed once and rejected
fresh-prompt proof once despite recognizing the exact marker. This differs
from the synthetic case's missing-exact-marker symptom. Repeated identical-image
replays and a benign baseline control are being used to measure that distinction
before selecting a production change. Only private temporary lab images were
captured; no credentials, launcher payloads, or image data entered this log.

The serial replay then reused the same decoded mixed-marker image ten times:
all ten failed with Terminal and exact marker recognized but no accepted shell
prompt. Each used both full-frame and supplemental crop OCR and returned two
exact-marker lines. The baseline image passed ten of ten replays. The paired
PNG files also had equal decoded pixels, checked without logging their digests.
This supplies a repeatable real-image prompt-recognition failure, not evidence
that the earlier missing-exact-marker failures share its cause. The result is
`test_macos_2026-09-22T08-51-37-315Z_pid66241_e807a27f.xcresult`.

### Narrow prompt-punctuation correction

The repeated real-image failure was minimized to one OCR spelling difference:
the visible leading hyphen in the fresh `-bash-3.2#` prompt was recognized as
U+2014 EM DASH. The remaining prompt characters were correct, but the anchored
prompt matcher accepted only the ASCII hyphen. Adding a blank output line
before the prompt still failed all ten replays. Test-only crop-scale comparisons
recovered that prompt at scales 1, 3, and 4, but no single scale recovered all
observed marker cases. No crop-scale or marker-format change is justified by
those results.

The six additional real Terminal marker comparisons passed four cases and
missed the exact marker for `HHHHHHHHHH` and `EHEHEHEHEH`. Those remain a
separate unresolved recognition problem. The narrow candidate accepts the
observed em dash only in the existing optional leading-hyphen position of the
anchored shell-prompt pattern. It retains the exact marker, Terminal, and
below-marker prompt requirements; it does not treat arbitrary nearby text or
command echo as a fresh prompt. Tests-first verification and signed live
validation follow before claiming that correction complete.

The manual VM was returned to its original stopped state. Public `stop`
reported its existing forced-stop fallback because Recovery did not shut down
itself; a subsequent status check verified stopped with no helper. No security
settings, credentials, creation records, or pinned agent artifacts changed.

The new permanent regression failed against the unchanged matcher (one failed,
eight passed), then all nine permanent Terminal-recognition tests passed with
the single-character-class correction. Three temporary image-backed cases also
passed: ten serial replays each of the original mixed-marker frame, the extra
blank-line frame, and the baseline, for 30/30 strict proofs. All temporary
corpus, scale-matrix, private-path, and Unicode diagnostic tests/imports were
removed before committing. Read-only review found no proof-gate regression;
the existing Terminal, exact-marker, and prompt-order checks remain intact.
All 21 local installer regression checks also passed.

The cleaned permanent suite run passed all 80 tests across language activation,
interaction, profile selection, virtualization keyboard delivery, navigation,
and Terminal recognition, with no failures. Result:
`test_macos_2026-09-22T09-01-02-073Z_pid68986_5696bd72.xcresult`.
The candidate is committed before the canonical signed Release build and live
SIP-status compatibility checks. The remaining exact-marker misses are not
represented as fixed by this prompt correction.

Candidate `6aa030c` was built and installed through `Scripts/build-local.sh`.
Release/arm64 compilation and the exact signing, entitlement, designated-
requirement compatibility, and signed-artifact preservation checks all passed.
A fresh login shell resolved `/Users/wes/.local/bin/pomme`, reporting that
commit; all 104 CLI contract checks passed against the installed binary.

The macOS 27 original SIP-status workflow began at 09:03:22Z on the same
internal-drive 4 GB/40 GB VM. Inactive-English activation and the full Terminal
menu route passed. Marker proof passed on attempt 1 at 09:05:01Z. The
authenticated request-bound session returned verified SIP enabled, all cleanup
fields true, and verified restoration of the previous stopped state; a separate
status call confirmed stopped with no helper. This validates the signed build
in the complete live workflow, while the deterministic image replay supplies
the specific em-dash regression evidence. It does not resolve the independent
exact-marker misses.

The macOS 26 compatibility SIP-status run on the same signed `6aa030c` began
at 09:05:43Z, retaining the internal-drive 4 GB/40 GB settings and creation-
pinned guest agent. Its unchanged five-input navigation reached Terminal at
09:07:12Z. Attempt 1 lacked the exact marker; attempt 2 at 09:07:15Z passed
all proof fields with a changed adjacent frame. The authenticated request-bound
session finalized with verified SIP enabled, all cleanup fields true, and
verified restoration to stopped. A separate status check confirmed stopped
with no helper. The narrow em-dash correction therefore has deterministic
red/green regression evidence and signed live compatibility on both OS versions.
Exact-marker OCR reliability remains open; temporary closed marker diagnostics
remain for that investigation, with no additional Terminal screenshot logging.

### Exact-marker spelling investigation

With the prompt correction installed, ten serial production-OCR replays each
of the retained repeated-`H` and alternating-`EH` real Terminal captures still
missed the exact marker; the baseline passed ten of ten. Geometric inspection
found a separate output line in the marker region with the expected compact
character count, but different recognized spelling. An earlier text-filter
heuristic had incorrectly classified those lines as missing. No fuzzy marker
acceptance or character substitution was added.

Two deterministic 64-case synthetic comparisons produced identical strict-proof
miss counts: ungrouped 7, groups of four 4, groups of three 3, individual
characters 2, and pairs 0. Every layout preserved the same ten suffix characters
and used the production OCR and unchanged exact-marker proof. Grouping into
pairs is a candidate only, pending a broader corpus and real Terminal comparison.

The expanded ungrouped corpus completed 1,000 cases with 53 exact-marker
misses and no Terminal-recognition misses. The following grouped run encountered
a Vision `unknownError`, so it did not provide a valid grouped result. The
temporary harness is being isolated into bounded runs with per-iteration
autorelease pools; this test-process failure is not claimed as a product bug.
Real comparison frames were captured on the same internal-drive macOS 27 VM
using benign fixed `printf` commands, clearing the viewport between formats
to prevent equivalent compact markers in scrollback from masking a failure.

The real comparison rejected grouping: all 40 serial proofs failed exact-marker
recognition (ten each for original and paired `H` and `EH` output). Bounded
inspection of these fixed, benign output lines found Cyrillic substitutions
across the marker, including the `POMME` prefix, and some additional glyph
substitutions. The live result does not support a spacing fix despite its
synthetic improvement. The repeat 1,000-pair experiment was cancelled without
claiming a result, and the VM was stopped again.

The next test-only comparison isolates Vision language detection, explicit
English selection, and language correction. Apple's
[customWords documentation](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/customwords)
states that custom words are ignored when language correction is disabled.
Consequently, enabling correction would also activate the existing expected-
marker hints. Any candidate must be checked without expected-nonce hints and
against wrong-marker images; making OCR correct an incorrect marker into the
requested value would undermine the proof. No production behavior has changed
in this investigation.

The real-image language matrix found runtime defaults of detection disabled,
revision 3, and `en_US`. Explicit detection-off and `en-US` selection did not
recover any of the four failing original/grouped `H`/`EH` cases; the baseline
passed. Language correction recovered only grouped `H`. Empty and fixed-only
custom-word lists produced that same partial result, and all 15 sampled
one-character-wrong expected-marker checks rejected proof. These results do
not support a complete correction-mode fix. The next isolated comparison varies
letter case, leaving nonce characters, spacing, and proof rules unchanged.

Letter-case changes also failed to eliminate synthetic misses: nonce-only
lowercase missed 9/64, entire-marker lowercase 13/64, and lowercase wrapper
with uppercase nonce 4/64, versus the original 7/64. The marker format remains
unchanged. A test-only fast-OCR comparison then failed all six real cases when
used for both passes, and failed the same four problematic cases when used
only as a crop supplement to the accurate full frame. Neither fast native-size
nor fast 2x crop recovered those cases. No fast-path fallback was adopted.
Result: `test_macos_2026-09-22T09-28-35-984Z_pid74956_b4d08441.xcresult`.

The runtime supports Vision request revisions 1, 2, and 3 (default 3). Each
revision missed the same four problematic real cases, so pinning an older
revision is not supported by the evidence. A test-only 16-word encoding of the
same ten UUID nibbles then recognized all 64 synthetic markers exactly, but
three cases lacked fresh-prompt proof. Before selecting that larger format
change, a smaller fixed Latin-disambiguating prefix is being compared. Neither
experiment changes nonce entropy, production code, or proof acceptance.

The fixed `READY` prefix did not eliminate synthetic misses: the uppercase
wrapper missed 4/64 and the lowercase wrapper missed 3/64. The three word-nonce
fresh-prompt failures contained recognized prompt-region lines with internal
punctuation or character substitutions, not just the already-corrected leading
em dash. A separate single-variable comparison added one blank line between
the word marker and prompt: exact recognition remained 64/64 and strict proof
improved from 61/64 to 64/64. Result: `50eef54c.xcresult`. This remains a
test-only candidate pending a larger corpus and real Recovery Terminal output;
the matcher and production marker format are unchanged.

The expanded word-plus-blank-line corpus completed 1,000 cases without a
resource error: all 1,000 exact markers were recognized, compared with 53
exact-marker misses in the original format. Strict proof passed 998/1,000;
one case missed Terminal recognition and one missed fresh-prompt recognition.
Both isolated cases passed when the simplified synthetic command echo was
replaced with the full wrapped capability probe. These are bounded comparison
results, not a universal OCR guarantee.

On the same internal-drive macOS 27 VM, the word encoding of repeated `H`
(`elm` repeated ten times) initially failed all ten real-image replays without
a blank line. The output region was recognized with a wrong word count, not
Cyrillic substitutions. Adding only one blank line after the same output made
all ten strict proofs pass. The full production-shaped capability probe with
that word marker and blank line also passed ten of ten. Wrong-first-word and
typed-command-only controls each rejected ten of ten for both passing cases.
The alternating `dry`/`elm` control passed without a blank line; the `hen`,
`ink`, and `key` repeated-word controls with blank lines each passed ten strict
proofs and rejected ten wrong-marker and ten typed-only checks. All captures
contain benign fixed lab probes only and remain private temporary artifacts.

The candidate therefore changes the transient capability marker to ten fixed
three-letter words encoding the same first ten UUID nibbles (40 bits), and
prints a blank line between probe output and the shell prompt. One marker
value is shared by the probe and launcher. The launcher keeps its existing
single-newline output. Generated-command assertions measured the probe at
138 bytes before the change and 169 bytes afterward, correcting the earlier
hand estimate. This remains within the
unchanged 256-byte limit; its focused regression budget is deliberately updated
from less than 160 to at most 176 bytes. Exact whole-line recognition, Terminal
recognition, and a fresh prompt below the marker remain mandatory. No fuzzy
matching, language correction, credential, pinned-agent, journal, or profile
change is included. Temporary diagnostic instrumentation is being removed.
Tests-first candidate verification precedes commit, signed build, and live
end-to-end status retests.

The manual macOS 27 session was stopped through the public command, which used
its existing forced-stop fallback after Recovery did not shut itself down.
Separate status calls verified both internal-drive test VMs stopped with no
helper. Both retain their original 4 GB/40 GB resources and creation-pinned
agent identities. All 21 local build/install regression checks passed before
candidate integration.

The permanent generator regressions first failed on the old implementation
(four failed, twelve passed), then all sixteen test functions passed with the
candidate, including 160 nibble-position/value combinations. The plan-driven
Vision regression independently reproduced the old alternating-nibble marker
failure before implementation. With the candidate, all 25 functions in the
Terminal-recognition and virtualization-port suites passed (26 parameterized
executions), including actual-OCR wrong-output and typed-only rejection.
Results: generator `575c3a63.xcresult`; OCR/port `9ed90fa8.xcresult`.
The renderer reads the generated probe output and newline count rather than
independently recreating the desired marker. All temporary corpus/image-backed
tests and private-path references were removed, as were the temporary
`[DEBUG-marker-20260922]` evidence and adjacent-frame-hash instrumentation.
The existing closed Terminal/exact-marker/fresh-prompt diagnostics remain.

Combined XcodeBuildMCP verification passed all 98 test functions across eight
Recovery suites, with zero failures or skips (112 reported executions):
`test_macos_2026-09-22T09-56-57-932Z_pid82062_9194c16d.xcresult`.
This includes navigation, interaction, profile selection, observation,
Terminal OCR, VirtioFS bootstrap, and live-runtime composition. The candidate
and this evidence are committed before the signed Release build; live
end-to-end validation remains pending at that commit.

Candidate `1f8c47e` was committed and then built and installed through
`Scripts/build-local.sh`. Release/arm64 compilation and the exact signature,
entitlement, designated-requirement compatibility, and signed-artifact archive
checks passed. The installed SHA-256 is
`d640a76adda6f5e6f7690d0fa5af590bfe2a53ee644d3a87b0fba38d4ca2597d`.
A fresh login shell resolved `/Users/wes/.local/bin/pomme`, reporting
`pomme 0.1.0 (1f8c47e)`. All 104 CLI contract checks passed against the installed
binary. The build retained existing warnings in SettingsAIPlanner and
PommeCore; this marker change does not claim to resolve them.

The signed macOS 27 SIP-status run began at 09:59:50Z. The same internal-drive
4 GB/40 GB VM passed inactive-English activation and the full menu route,
reached Terminal at 10:01:27Z, and passed the new marker proof on attempt 1
at 10:01:29Z. The authenticated, request-bound session finalized with verified
SIP enabled and every cleanup field true. A separate status call verified
restoration to stopped with no helper and unchanged creation-pinned identities.

The macOS 26 compatibility run began at 10:02:17Z on the same internal-drive
4 GB/40 GB VM and original pinned agent. Its five-input route reached Terminal
at 10:03:45Z. Attempt 1 lacked the exact marker; attempt 2 at 10:03:48Z passed
all strict proof fields. The authenticated, request-bound session finalized
with verified SIP enabled, every cleanup field true, and verified restoration
to stopped; a separate status call confirmed no helper. This passes complete
workflow compatibility without claiming that every initial capture contains
recognizable marker output.

The second unchanged macOS 27 run began at 10:04:33Z with a fresh request.
It exercised the already-active Language Chooser branch, reached Terminal at
10:06:07Z, and passed marker proof on attempt 1 at 10:06:10Z. It finalized with
authenticated request binding, verified SIP enabled, all cleanup fields true,
and restoration to stopped confirmed by a separate status call. The two macOS
27 runs and macOS 26 compatibility run therefore passed end to end on the
installed candidate. No security settings, credentials, creation records, or
agent pins were changed.

This closes the bounded word-encoding/output-separation fix with deterministic
red/green evidence and signed live validation. It does not establish universal
OCR reliability or resolve the other creation, owner-session, and lifecycle
observations. The earlier 998/1,000 synthetic strict result and macOS 26's first
attempt miss remain recorded limitations. Both test VMs remain stopped on
internal storage at unchanged 4 GB/40 GB settings. The 54 individually known
benign screenshots from this comparison and their empty private directory were
deleted after validation; no raw images entered source control. Earlier
investigation artifacts and production navigation-only debug directories were
not removed by this cleanup.

### Fresh macOS 26 owner-session reproduction

After committing the marker fix and its live validation, the next isolated
investigation returns to the intermittent macOS 26 owner-preparation and
post-reboot Aqua timeout. The prior macOS 26 test VM already completed owner
preparation, so it cannot repeat the fresh-owner branch without changing its
established state. It and the macOS 27 compatibility VM remain stopped.

Signed `1f8c47e` began creation of `pomme-agent-owner26-20260922b` at 10:08:44Z,
using the internal cached `UniversalMac_26.6.2_25G83_Restore.ipsw`, explicitly
`--disk-size 40GB --memory 4GB --boot none`. Dry-run preflight confirmed the
exact experimental 26.6.2/25G83 identity and existing Recovery provisioning
route. The new bundle is under the default internal Pomme state directory;
327 GiB was available before creation. No external-drive resource is used.
The new VM UUID is `d114a794-b34c-40b1-83fe-4d4d05de9b8a`, and its immutable
agent digest is the installed candidate's `d640a76a…ca2597d`. No timeout,
owner policy, credential, or journal change is being tested at this baseline.

Restore reached 100% at 10:12:28Z. The unchanged Recovery route reached
Terminal at 10:13:56Z and the word marker passed on attempt 1 at 10:13:58Z.
Creation completed successfully, including normal-agent verification, and
returned the requested stopped state. Public inspection confirmed the internal
bundle, original 4 GB/40 GB settings, and the expected pinned agent. The
earlier macOS 26 creation failure did not reproduce in this prerequisite run.

Read-only tracing distinguishes three separate boundaries before further
diagnosis: preference writes use the buffered owner-completion executor;
private owner input uses the bounded private-PTY runner; post-reboot Aqua
verification runs `launchctl print gui/<uid>` through the default-identity
normal-agent foreground path. The historical typed Aqua result indicates the
guest's 15-second process deadline, not the additional 30-second host collector
deadline. A public probe with explicit UID 0 takes a different identity path
and is not an equivalent reproduction. No timeout or retry behavior changed.

The fresh `sip disable --force --final-state previous` baseline began at
10:15:12Z and reproduced the target failure. Owner creation and verification
passed. Owner completion returned status 1 at 10:16:25Z and triggered the
existing single normal-boot retry; that retry passed owner completion and
configure-login receipts at 10:17:22Z, then Setup Assistant completion at
10:17:25Z. After normal reboot, desktop verification began at 10:17:41Z and
failed at 10:18:25Z with `normal-agent-aqua-timedOut`, `stage=aqua`,
`exited=false`, `outputComplete=false`, and `terminationRequested=true`.
The command exited 1 before SIP mutation, retained its security progress, and
restored stopped state confirmed by public status. This is a new live failing
reproduction of the later Aqua issue, not a private-PTY timeout.

The existing normal-agent verification, foreground execution, and foreground
control suites passed all 45 test functions (48 executions) unchanged:
`test_macos_2026-09-22T10-15-51-642Z_pid85918_552f8420.xcresult`.
These cover closed timeout decoding and separate inner/outer deadline behavior,
but not the live failure timing. The next minimization compares the exact
default-identity Aqua command with a simple foreground control on the retained
VM; no retry, deadline, or owner/security policy is being changed.

The standalone minimization did not reproduce the timeout. A normal diagnostic
boot followed by the exact default-identity request (`/bin/sh -c 'exec
/bin/launchctl print "gui/$1" >/dev/null' pomme-aqua-proof 501`, timeout 15)
returned exit 0 with complete output. Console ownership was `pomme:501`, and
the `/usr/bin/true` control passed. A second stop/start followed immediately
by the same Aqua request also passed: start took about 9.2 seconds and the
request about 4.4 seconds. Ten subsequent console/Aqua/true sequences completed
all 30 requests successfully in about 5.2 seconds. No request supplied an
explicit user or UID override. These public probes share the guest request but
not the security caller's outer transport deadline; they do not establish a
fix or reproduce the fresh-owner workflow context.

Read-only tracing also found that foreground timeout results retain their last
pre-signal process status. The signal response is discarded, so
`exited=false, outputComplete=false, terminationRequested=true` is not proof
that the child remained alive after SIGTERM. This is an evidence limitation,
not an explanation of why the Aqua command reached its deadline. No process
completion or timeout behavior has been changed. The diagnostic VM was
gracefully stopped again and public status confirmed no helper before the
unchanged supported SIP-disable resume began at 10:29:55Z.

That unchanged resume passed owner completion and Setup Assistant completion.
After reboot, console/desktop verification ran from 10:31:07Z until entry to
Recovery at 10:31:14Z. Recovery marker proof passed on attempt 1 at 10:33:15Z.
SIP disable then returned exit 0 with normal-boot, runtime-configuration,
enforcement, and final-state verification all true; public status confirmed
stopped with no helper. As in the earlier retained-VM run, this successful
retry does not resolve the fresh-owner timeout. SIP enable began at 10:34:37Z
to restore the original setting before further experiments.

The next diagnostic candidate records only closed monotonic timing, poll-count,
and process-state fields for the exact Aqua probe, with no guest output,
command text, process identifiers, credentials, or extra guest requests. Its
purpose is to distinguish a live child with responsive status polls from
transport time consumption or a missing completion receipt. Public and
security requests both use the helper's authenticated persistent guest-agent
connection, so the public-command comparison does not independently test a
different guest connection lifetime. No timeout increase, retry, weakened
desktop proof, or claimed bug fix is included. All 21 local installer checks
passed again before preparing this diagnostic build.

SIP enable completed successfully after normal-boot verification at 10:38:15Z,
returning `configuredDisabled=false` and all normal-boot, runtime,
enforcement, and final-state verification fields true. Separate public status
confirmed stopped with no helper. The retained test VM therefore has its
original SIP-enabled/stopped state again; no credentials or immutable pins
were replaced. Both directions used the unchanged signed `1f8c47e` baseline.

The timing evidence must be interpreted conservatively: the pinned guest's
`refreshStatus` treats non-EINTR `waitpid` errors like an unchanged running
record. Consequently, even a positive spawn PID plus repeated fast
`exited=false` replies would not distinguish a live child from an unreported
wait error. Read-only review found no broad competing reaper in this repository;
inherited SIGCHLD disposition remains an untested external possibility. This
is a diagnostic limitation, not a diagnosed cause or reason to change proof
acceptance.

The temporary diagnostic regressions first failed twice on the unchanged
implementation (35 tests passed). The final focused foreground-execution and
normal-agent suites passed all 38 functions, 44 executions, without failures
or skips: `test_macos_2026-09-22T10-39-33-531Z_pid91073_63183827.xcresult`.
Coverage uses the actual generated Aqua payload, rejects opt-in mismatches and
private/malformed logging values, and proves that a signal-response exit frame
does not convert a timeout into success. Total monotonic elapsed time includes
unmeasured polling sleeps and processing; separate start, EOF, status, and
signal timings measure the exchanges. Thrown transport failures can still
return no timing envelope. This diagnostic candidate is committed before its
signed Release build and fresh-owner live test; it is not a fix.

Diagnostic commit `227b0d1` passed read-only review, then the canonical signed
Release build and install completed successfully. Signature, exact entitlement,
designated-requirement compatibility, and signed-artifact archive checks passed.
The installed SHA-256 is
`5d1a82a0b7719183c6e6f6d761f7e8088780ef4817ea6b99c1202e8092edfcd5`.
A fresh login shell resolves `/Users/wes/.local/bin/pomme`, reporting that
commit, and all 104 CLI contract checks passed. Existing PommeCore warnings
remain unrelated to this diagnostic. Dry-run preflight at 10:42:24Z confirmed
the same internal macOS 26.6.2/25G83 restore image and 4 GB/40 GB resources for
new disposable `pomme-agent-owner26-20260922c`; no retained VM is reset or
repinned to obtain another fresh-owner run.

Fresh creation began at 10:42:42Z and passed restore (100% at 10:46:24Z),
Recovery navigation, marker proof on attempt 2 at 10:47:54Z, installation,
and normal-agent verification. It exited 0 and returned stopped state,
independently confirmed by public status. The new internal-drive VM UUID is
`eef17d8a-3cc8-4462-ac9b-88f18aff7795`, startup-volume group
`a32f15b1-d2f2-47bd-a8f0-78dbe2a5dbbd`, and plan digest
`cef6ce048104936b1c276665a23cbf5251617ea8907e2c8a6b7200aacd3fa4f1`.
It pins the diagnostic build's `5d1a82a0…2edfcd5` agent and retains the
comparison's exact 4 GB/40 GB resources. The first-owner SIP-disable run follows
without intervening guest probes or account changes.

The first-owner SIP-disable diagnostic run began at 10:49:02Z. Fresh owner
creation/verification and native Setup Assistant handoff passed. Initial owner
completion returned status 1 at 10:50:24Z, invoking the unchanged single boot
retry; owner completion then passed at 10:51:18Z and Setup Assistant completion
at 10:51:22Z. Post-reboot desktop verification began at 10:51:39Z.

Seven Aqua requests completed successfully (approximately 1.785 s, 0.073 s,
0.039 s, 0.030 s, 0.056 s, 0.032 s, and 2.653 s), but the eighth reproduced
`normal-agent-aqua-timedOut` at 10:52:24Z. Its closed diagnostics were:

| Measurement | Value |
|---|---:|
| Total foreground duration, including signal exchange | 16,410,068 µs |
| Start exchange | 709,345 µs |
| Stdin EOF exchange | 162,246 µs |
| Status exchanges | 72 |
| Total status-exchange duration | 12,926,756 µs |
| Maximum status-exchange duration | 1,523,248 µs |
| Signal exchange | 548,735 µs |
| Positive spawn PID | true |
| Last status exited | false |
| Exit frame before signal / in signal response | false / false |

The workflow exited 1 before SIP mutation, retained its transaction, and
restored stopped state confirmed by public status. This repeats the exact
fresh-owner Aqua failure on the signed diagnostic build. It rules out a single
stuck transport exchange or spending the entire deadline before process start;
it does not yet distinguish a genuinely running child from the guest's hidden
wait-status errors. The normal desktop was not verified, and no fix is claimed.

The next bounded diagnostic adds exact-Aqua-only closed guest wait outcomes
and records the host's existing console/Aqua/desktop observation after each
completed loop. It preserves the current waitpid calls, EINTR retry, signal
calls, deadlines, and proof acceptance. This is needed because the existing
signal receipt reports group-or-process success, which does not prove the
exact child PID was still alive. No extra signal, sample, guest command, or
credential access is part of this candidate. The four retained test VMs are
all stopped, and internal storage has about 272 GiB available before another
fresh diagnostic comparison.

The additive wait-diagnostic snapshot test failed before implementation. The
final four focused suites (foreground execution, normal-agent decoding,
persistent agent, and real daemon process exchange) passed all 63 functions,
82 executions, with no failures or skips:
`test_macos_2026-09-22T10-59-00-870Z_pid94554_cc6382d3.xcresult`.
Tests cover all wait classifications, exact-payload exclusions, malformed and
missing old-agent fields, and a real harmless `/usr/bin/true` process that
receives no diagnostic metadata. They do not execute an Aqua probe on the host.
The closed outcome codes are 0 running, 1 reaped, 2 interrupted, 3 no-child,
and 4 other-error; counters accumulate per guest job and the host copies the
latest snapshot without summing it. All temporary instrumentation remains
explicitly diagnostic, pending signed-build live reproduction.

Candidate `b35bbdc` was committed, then built and installed through the
canonical signed Release workflow. All signature/entitlement/requirement and
artifact-archive checks passed; the installed digest is
`0dd4236141483d68f6b63fe39cfdf27a2a5b1b7074d0bc19fc756d9ad21fa127`.
Fresh login-shell resolution and version matched, and all 104 CLI contract
checks passed. The build reports existing PommeCore and guest MDM Keychain
deprecation warnings, not changes to those paths. Read-only review confirmed
unchanged wait/signal/proof behavior. Per-loop closed proof observations are
intentionally retained to identify why successful Aqua probes did not yield
stable desktop proof. Counters are the last completed status-response snapshot:
the daemon can perform another wait during stream-event collection after
encoding that response, so they are not a complete final syscall census.
Preflight at 11:01:51Z confirmed the same internal restore image, experimental
profile, and explicit 4 GB/40 GB resources for `pomme-agent-owner26-20260922d`.

Fresh creation began at 11:02:11Z and completed successfully: restore reached
100% at 11:05:52Z, marker proof passed on attempt 2 at 11:07:23Z, and normal
agent verification passed before return to stopped. Public status independently
confirmed stopped with no helper. The new internal VM UUID is
`5f07b9ad-41c7-4be7-8a9e-97dc644db000`, startup-volume group
`d2b1f757-1938-4b1f-b437-2b166ab459e5`, and immutable plan digest
`1b4a96afed065f5d372a3ee567f30cfb5d729b2383fc89da0b6e14b72a6aa8bd`.
Its pinned agent is the signed `0dd42361…1fa127` diagnostic build. The original
first-owner SIP-disable command follows without additional guest probes.

The first-owner run began at 11:08:30Z. Initial owner completion status 1
triggered the unchanged boot retry at 11:09:53Z; completion then passed at
11:10:53Z and Setup Assistant completion at 11:10:56Z. Desktop verification
began at 11:11:12Z. Early completed Aqua probes took approximately 31–161 ms;
the first did not satisfy Aqua proof, then subsequent Aqua proofs passed while
the existing desktop-process predicate remained false. A later probe took
4.154 s. At 11:12:00Z a probe completed in 14.141 s, just below the 15-second
limit: start 2.112 s, EOF 0.278 s, 31 status exchanges totaling 10.830 s,
maximum 1.440 s. Its last guest snapshot showed 62 running waits, one reap,
zero EINTR/ECHILD/other-error waits, and last outcome reaped. Desktop proof
then matched at 11:12:05Z. The next Aqua request completed in 7.386 s with
102 running waits, one reap, and no wait errors. The combined desktop proof
passed at 11:12:18Z and the workflow entered Recovery.

This fresh run did not reproduce the timeout. It proves that a nearly
deadline-length successful probe can involve a genuinely running child, not
a hidden wait error. It does not classify the earlier failing probe on the
other VM or establish a fix. The temporary per-loop observation reuses the
existing formatter's phrase `deadline expired`; those tagged lines above are
observations, not additional failures. The actual 120-second desktop deadline
did not expire. SIP restoration will follow the pending transaction.

SIP disable completed successfully after normal-boot verification at 11:15:31Z,
returning all normal-boot/runtime/enforcement/final-state verification fields
true and `configuredDisabled=true`. Public status confirmed stopped with no
helper before the matching SIP-enable restoration was started. Recovery marker
proof in the successful disable workflow passed on attempt 2 at 11:14:21Z.
This is diagnostic-build live compatibility and a slow successful first-owner
run, not closure of the intermittent Aqua defect.

SIP enable started at 11:15:50Z and completed successfully after normal-boot
verification at 11:19:38Z. Recovery marker proof passed on attempt 1 at
11:18:36Z. The final result reported `configuredDisabled=false` and all
normal-boot/runtime/enforcement/final-state verification fields true, restoring
the original SIP-enabled/stopped state. A separate inventory confirmed all
five internal-drive test VMs stopped with no helper. The failing `...22c` VM
retains its unmodified pre-mutation SIP transaction; the successful `...22d`
comparison retains its own exact agent pin. No guest credentials, immutable
journals, or pinned agents were manually replaced, and no external drive was
used. Temporary closed diagnostics remain for the unresolved Aqua investigation;
the next step must preserve fail-closed behavior when process cleanup is not
proven, rather than treating a signal acknowledgement as termination proof.

### Cleanup-verified Aqua readiness retry candidate

The next candidate targets the readiness-loop failure, not a claimed diagnosis
of the native child delay. Ranked hypotheses are: first-login load keeps a
real Aqua probe running past its 15-second attempt deadline; an unreported
wait-status error prevents completion; or aggregate transport work consumes
the attempt budget. The slow successful run supports the first hypothesis,
while the failing run excludes a single stuck exchange but cannot classify
its child wait outcome. A retry must not conceal unknown process cleanup.

The real `verifyConsoleLogin` loop now has injectable command/status, monotonic
clock, and sleep boundaries for deterministic tests. Its first new regression
failed on the old behavior (one failed, 28 passed): a timed-out Aqua attempt
aborted even when the same job subsequently supplied reaped-and-drained proof
and the desktop could become stable within the original deadline. This is a
host readiness-loop regression, not a simulated explanation for guest delay.

The candidate keeps the timed-out attempt failed and preserves the single
SIGTERM behavior. It permits another readiness iteration only after validating
a same-job exit frame already received by the foreground host or obtained by
bounded status reads. Cleanup reads have at most three seconds within the
original 120-second deadline. Signal acknowledgements, `exited` flags alone,
foreign/malformed frames, cancellation, transport uncertainty, and insufficient
remaining time cannot authorize another probe. A retry resets desktop stability
and rechecks console ownership, Aqua, Dock, and absence of Setup Assistant.

Review identified two important protocol details before validation: a native
signaled exit frame carries its signal, and the status result can precede the
reap performed while collecting stream events. A valid same-job exit frame is
therefore the cleanup evidence even when that preceding result says running.
No guest protocol, credential, creation pin, journal, or security predicate is
being changed. Earlier diagnostic paragraphs were moved here from the marker
section to restore chronological grouping without changing their evidence.

The final combined XcodeBuildMCP run passed 76 test functions, 125 executions,
with zero failures or skips across foreground execution, normal-agent proof,
foreground control, persistent agent, and real daemon process exchanges:
`test_macos_2026-09-22T11-35-23-544Z_pid2493_ac50f82a.xcresult`.
New cases cover stale status plus exit, signaled exit, consumed host receipts,
false signal acknowledgement with a valid exit, forged/foreign/malformed
evidence, actual task cancellation, stability reset, repeated timeout attempts
under one original deadline, and a late desktop response. A first green run
exposed an overly strict fake-clock call-count assertion (six probes already
provide 5.2 seconds of stability); that assertion was corrected without changing
production behavior. All 21 local installer checks passed again. Temporary
closed diagnostics remain for the signed live comparison; this candidate is
not yet a live-validated fix.

Final read-only review found no remaining blocker. The three-second cleanup
budget bounds the host caller across control negotiation, connect, write, and
read. A helper-side status exchange can continue to its existing five-second
VSOCK budget after the caller disconnects; that uncertainty returns failure and
never starts another probe. The candidate does not claim a three-second bound
on guest-side request execution. Cancellation and the original deadline are
rechecked before subsequent requests and before accepting stable proof.

Candidate `e84f32a` was committed before the canonical signed Release build.
Build, signature, exact entitlements, designated-requirement compatibility,
and signed-agent archiving passed. The installed SHA-256 is
`4cdd14436372c930ad2943a10b1827fe19671e0ffba4f6505d1f183dcc6b2c98`.
A fresh login shell resolves `/Users/wes/.local/bin/pomme` and reports that
commit; all 104 CLI contract checks passed. The four existing PommeCore build
warnings are unrelated to this candidate. All five retained VMs were confirmed
stopped, and internal storage had 245 GiB available before this comparison.

Fresh `pomme-agent-owner26-20260922e` creation began at 11:38:20Z from the
same internal cached macOS 26.6.2/25G83 image, explicitly using a 40 GB disk,
4 GB RAM, and `--boot none`. Dry-run preflight confirmed the exact experimental
profile and Recovery route. This run tests the first-owner workflow, not a
reset or credential replacement on a previously provisioned owner.

Restore reached 100% at 11:42:02Z. Recovery navigation reached Terminal at
11:43:30Z, and marker proof passed on attempt 2 at 11:43:33Z. Creation then
passed normal-agent verification and returned stopped state, independently
confirmed by public status. The new VM UUID is
`617748c1-e04e-4967-b697-29a5e1335e71`, startup-volume group
`fda5f1f3-bfd2-4fe5-8558-c821e1d6e14c`, and immutable plan digest
`8dc8c9026c4efd8bd61c157dd9f2ac666509a0257cb57dfce34d3477d7d10de2`.
It pins the installed `4cdd1443…c6b2c98` agent. The original fresh-owner
`sip disable --force --final-state previous` began at 11:44:36Z without
intervening guest probes or account changes.

The candidate's fresh-owner run failed at a different readiness stage. Owner
creation/verification passed, and the unchanged owner-completion status-1 boot
retry began at 11:45:53Z. The retry passed owner completion at 11:46:46Z and
Setup Assistant completion at 11:46:49Z. Desktop verification began at
11:47:06Z. Five Aqua probes completed in approximately 0.331, 0.285, 0.118,
0.082, and 0.037 seconds, with console/Aqua matched but desktop not matched.
The next Aqua probe completed in 5.085 seconds at 11:47:24Z, with a reap and
no recorded wait errors. The following process-list probe failed at 11:47:40Z
with `normal-agent-ps-timedOut`, `exited=false`, `outputComplete=false`, and
`terminationRequested=true`. The workflow retained progress, restored stopped
state, and exited 1 before SIP mutation. No Aqua retry was exercised.

This is a failed live candidate, not a fix or successful retry demonstration.
The first-login readiness issue is not confined to the Aqua command: the fixed
read-only process-list probe can reach the same foreground deadline. The next
candidate must apply the same verified-cleanup requirement consistently to the
fixed readiness probes, with regressions for each stage and unchanged console,
Aqua, desktop, stable-duration, cancellation, and overall-deadline predicates.
It must not enable retries for arbitrary guest commands or reinterpret timeout
as successful proof. The retained VM and its pinned agent will not be reset.

### All fixed readiness probes: revised candidate

The next revision keeps the cleanup mechanism and moves the typed-timeout
handler around the complete readiness iteration. Only the exact console
`stat`, Aqua `launchctl`, and process-list `ps` payloads qualify. The foreground
host and security caller both validate that closed payload set; identity,
working-directory, environment, input, PTY, extra-option, and altered-command
variants do not qualify. A failed retry retains its original console/Aqua/ps
diagnostic. Generic command execution and all owner/security mutations retain
their existing no-retry behavior.

The permanent receipt is renamed for desktop proof rather than Aqua alone.
The temporary Aqua timing gate stays Aqua-only. New tests cover console and
process-list timeout recovery and exact-payload exclusions alongside the
existing Aqua negatives, and the security workflow guide records the full
retry contract. Six internal-drive VMs are stopped with no helpers; 219 GiB
is available before any further fresh-owner comparison. No retained journal,
owner, credential, or pinned executable is changed for this revision.

The tests-first run `0b5b50c2` executed 77 functions / 134 cases. Only the new
`allDesktopStagesRetry` console/verified and process-list/verified cases failed,
each with its original stage's timeout diagnostic; the other cases passed.
After implementation, the final five-suite XcodeBuildMCP run passed all 78
functions / 190 executions, with zero failures or skips:
`test_macos_2026-09-22T11-55-17-742Z_pid6490_03f44743.xcresult`.
Coverage now includes exact-payload negatives and all-stage cleanup uncertainty,
wrong-job/malformed evidence, cancellation, original-deadline exhaustion, and
stability reset. Parent review confirmed the classifier is checked at both the
foreground receipt and private readiness-caller boundaries. No generic guest
executor gained automatic retries. This revision is committed before its
signed build and new fresh-owner live comparison.

Revision `f9a3598` was committed and built through the canonical signed
Release workflow. Signature, exact entitlements, designated requirements,
archive preservation, and install checks passed. The installed digest is
`990bf1bc07b4e766cd2bb04c4d1b335e3779e7cffd07b2e8baf0be54b7df69f6`.
A fresh login shell resolves the installed CLI and its expected commit;
all 104 CLI contract checks passed. Fresh comparison VM
`pomme-agent-owner26-20260922f` began creation at 11:56:56Z after dry-run
preflight, using the same internal 26.6.2/25G83 restore image, explicit
40 GB/4 GB resources, and `--boot none`. Existing VMs remain stopped.

The new restore reached 100% at 12:00:37Z. Recovery navigation reached Terminal
at 12:02:04Z and passed marker proof on attempt 2 at 12:02:07Z. Creation
completed normal-agent verification and returned stopped state, confirmed by
public status. The VM UUID is `2ac870e3-e53f-4505-abad-abacd9e333c1`, startup-
volume group `905e9c8a-994c-47d8-8b81-bb7835ba2588`, and plan digest
`1ffdace9a50c6dc11e02ec1cc8492661dc89fed6c80b712b886f03c1df5ad3b7`.
It pins `990bf1bc…7df69f6`. The first-owner SIP-disable command began at
12:03:09Z with `--force --final-state previous`, without intervening guest
probes or account changes.

The `...22f` run exercised the new retry but did not complete the workflow.
Owner-completion status 1 invoked the existing boot retry at 12:04:24Z;
completion passed at 12:05:23Z and Setup Assistant at 12:05:26Z. Desktop
verification began at 12:05:42Z. Initial Aqua probes completed, with a
5.418-second probe at 12:05:59Z; the desktop predicate was still false.

At 12:06:21Z an Aqua probe reached its attempt deadline. Total foreground
duration including signal exchange was 15.800 seconds: start 0.522 s, EOF
0.244 s, 31 status exchanges totaling 13.643 s (maximum 1.547 s), and signal
0.484 s. The last guest snapshot showed 63 running waits, zero reaps, zero
EINTR/ECHILD/other errors, and last outcome running. No exit frame was present
before or in the signal response. This failing probe supplies the missing
evidence of a genuinely running child at its last observed wait, rather than
an ignored wait error; it does not identify why native execution was slow.

The loop subsequently obtained same-job cleanup proof and retried without
restarting the overall deadline. A fresh Aqua probe completed in 0.116 seconds
at 12:06:24Z; console, Aqua, and desktop matched at 12:06:30Z. The next console
probe instead failed with `normal-agent-console-transport` at 12:06:37Z, before
the full stable-desktop proof could complete. The closed error does not yet
distinguish an inner agent exchange failure from another transport boundary.
The workflow retained progress, restored stopped state, and exited 1 before
SIP mutation. Public inventory confirmed all seven internal-drive VMs stopped
with no helpers. No credential, owner, creation record, or agent pin was reset.

This validates the live cleanup-verified Aqua retry path, but the complete
fresh-owner workflow still fails and the issue remains open. The earlier
process-list timeout and this subsequent console transport failure show that
first-login readiness can encounter more than one failure boundary. Unknown
transport outcomes must not be blindly replayed: the next investigation must
identify the failing exchange and whether an owned job was established before
changing retry or deadline behavior. Temporary diagnostics remain pending that
investigation; this is not a claim that the whole issue is fixed.

### Console transport boundary investigation

The tracked tree and installed `f9a3598` were revalidated before continuing;
all seven VMs were stopped. The failed `...22f` helper log was empty. Read-only
tracing identified separate five-second normal-agent exchanges for process
start, stdin EOF, and status, inside the usual 30-second host collector budget
for a 15-second proof attempt. The approximately six-second console failure
favors an inner exchange over the outer deadline, but does not identify a
phase or prove that a job had been established.

Ranked hypotheses are an inner status exchange failure after job establishment,
an inner start/EOF failure before reliable job ownership, or a host/helper peer,
deadline, or protocol failure. Closed phase/error-category, timing, poll-count,
and job-established evidence can distinguish these without logging output,
arguments, process/job identities, credentials, or arbitrary error messages.

A bounded minimization started the retained `...22f` normally at 12:11:56Z
on the unchanged installed build. The exact default-identity console probe
completed immediately with exit 0, complete output, and `pomme:501`. Five
subsequent serial console/Aqua/process-list sequences passed all 15 probes.
Results were reduced to closed completion fields; no user/UID override was
supplied. One earlier successful process-list invocation exceeded the tool's
output-capture budget, so the complete sequence was rerun with closed JSON
projection rather than treating that capture limitation as a guest failure.
These public requests share the helper's authenticated agent path but not the
security caller's outer collector deadline or fresh-owner timing. They do not
reproduce or fix the live first-login transport failure.

Graceful stop began at 12:13:47Z and succeeded with `guest-stopped`; public
status confirmed stopped with no helper. The retained transaction and exact
creation pin remain unchanged. The next change is diagnostic only, preserving
all deadlines, thrown errors, signal behavior, cleanup requirements, and proof
acceptance. It will identify inner foreground phases in the helper's closed
log and distinguish outer caller error categories without raw error text.

The diagnostic-only candidate now logs `[DEBUG-desktop-transport-20260922]`
for the exact three desktop-proof payloads. `side` identifies the emitting
layer, not the origin of the error; boundary and closed error kind distinguish
validation, cancellation/deadline, and exchange failures. Helper records also
include elapsed milliseconds, job-established state, and status poll count;
the outer caller records its elapsed time and budget. No raw error text,
commands, paths, identities, or guest output enter these new diagnostics.
The original thrown errors, one-start/single-cleanup behavior, deadlines, and
retry/acceptance policy are preserved. Frame acceptance includes both validation
and forwarding; this label does not claim to distinguish those operations.

Tests-first evidence: `5942af2a` failed the missing exact-probe start diagnostic
while ordinary-command exclusion passed; `27b7cacd` failed the four missing
outer error-category cases. The final seven-suite XcodeBuildMCP run passed
103 test functions / 225 executions, zero failures or skips:
`test_macos_2026-09-22T12-20-12-746Z_pid11259_8a9d1cfd.xcresult`.
Tests exercise the real foreground executor and console verification catch
using injected failures, checking preserved original errors and operation
counts. They do not reproduce a physical VSOCK failure; the existing wire,
coordinator, foreground-control, and real daemon exchange suites also passed.
Read-only review found no behavioral or redaction blocker. All seven VMs are
stopped and internal storage has 191 GiB free before the next signed comparison.
This candidate is committed before building and is not a transport fix.

Diagnostic candidate `051bd6c` built and installed through the canonical signed
Release workflow. Signature, exact entitlements, designated-requirement
compatibility, and archive checks passed. Installed SHA-256:
`0297d320550ff5c3b1fc7a4146e9e8b0440d1baba54d2361825143569a29af24`.
A fresh login shell resolved `/Users/wes/.local/bin/pomme` with the expected
commit. All 104 CLI contract checks and all 21 installer checks passed.
Fresh `pomme-agent-owner26-20260922g` creation began at 12:26:23Z after dry-run
preflight, using the internal cached 26.6.2/25G83 IPSW, explicit 40 GB disk and
4 GB RAM, and `--boot none`. The seven existing VMs remain stopped. No
previously pinned agent, owner, credential, or journal is replaced.

Restore reached 100% at 12:30:09Z; Recovery reached Terminal at 12:31:36Z
and marker proof passed on attempt 2 at 12:31:39Z. Creation passed normal-agent
verification and returned stopped state, independently confirmed by public
status. The VM UUID is `d3636887-e18e-4fcc-857a-2d3dc4e36a3a`, startup-volume
group `8a66674d-549a-4c2a-ab50-bc8a7874b81e`, and immutable plan digest
`3b74c054627ccec45f0f9534f344cc2c2365b26cf2625258b65065a84416e1dc`.
It pins the installed `0297d320…a29af24` agent. The original fresh-owner
`sip disable --force --final-state previous` began at 12:32:42Z without
intervening guest probes or owner changes.

This diagnostic run passed fresh-owner desktop proof without a transport
failure or cleanup retry. The existing owner-completion status-1 boot retry
began at 12:34:03Z; owner completion passed at 12:34:51Z and Setup Assistant
at 12:34:54Z. Desktop verification began at 12:35:11Z. Aqua probes included
3.387 seconds at 12:35:31Z and 9.305 seconds at 12:35:46Z, each with a reap
and no recorded wait errors. All desktop predicates matched at 12:35:56Z;
the next Aqua probe took 4.085 seconds and stable proof passed at 12:36:06Z.
The workflow advanced to authenticated Recovery. This is slow successful
first-owner compatibility, not a reproduction or fix of the transport failure.

SIP disable completed successfully after its 12:38:07Z first-attempt Recovery
marker proof and fresh normal-boot verification. The result reported
`configuredDisabled=true` and all normal-boot, runtime-configuration,
enforcement, and final-state verification fields true. Public status separately
confirmed stopped with no helper. Matching SIP-enable restoration began at
12:39:48Z. Internal storage has 166 GiB free; subsequent fresh comparisons
remain sequential so concurrent guest load does not alter this baseline.

SIP-enable restoration passed its second-attempt marker proof at 12:42:23Z,
then returned `configuredDisabled=false` with all normal-boot, runtime,
enforcement, and final-state verification fields true. Public inventory
confirmed all eight internal VMs stopped with no helpers. A closed journal
projection confirmed `phase=restorationComplete`, `operation=sipEnable`, and
`requestedFinalState=previous` for `...22g`. Its original SIP-enabled/stopped
state is restored. The signed diagnostic build is compatible with the complete
disable/enable cycle, but the intermittent first-login transport failure remains
open and the temporary diagnostics remain. The next evidence step is another
fresh, sequential comparison on this unchanged binary and resource settings,
not a reset of any retained failing VM or a speculative transport retry.

The next sequential comparison revalidated clean tracked state at `6cd841b`,
the installed `051bd6c` digest, all eight VMs stopped, and 166 GiB internal
free space. Fresh `pomme-agent-owner26-20260922h` creation began at 12:44:36Z
after dry-run preflight using the same internal 26.6.2/25G83 image, explicit
40 GB disk / 4 GB RAM, and `--boot none`. No source, timeout, workload,
credential, owner, or retry-policy change separates this run from `...22g`.

Restore reached 100% at 12:48:24Z, Terminal at 12:49:51Z, and exact marker
proof on attempt 2 at 12:49:54Z. Creation passed normal-agent verification
and returned stopped state, separately confirmed by public status. VM UUID:
`bd4acfad-f091-4248-878b-002459d0ff23`; startup-volume group:
`2e6e4129-dd83-4bf4-ac06-de8e5ebeb4e6`; immutable plan digest:
`9858c2678125cd90afae2427b07d630823f3c7bb1e504a787243f61706290234`.
The VM pins the unchanged `0297d320…a29af24` agent. The first-owner SIP-disable
workflow follows immediately, without standalone guest probes or account edits.

The first-owner command began at 12:51:01Z. Owner-completion status 1 invoked
the existing single boot retry at 12:52:25Z; owner completion passed at
12:53:21Z and Setup Assistant at 12:53:24Z. Desktop verification began at
12:53:40Z. Initial Aqua probes passed; the 12:54:00Z probe took 7.537 seconds
with a reap and no wait errors, while the desktop remained not matched.

At 12:54:28Z the next Aqua probe timed out after 15.159 seconds including
signal: start 3.264 s, EOF 0.488 s, 37 status exchanges totaling 10.246 s
(maximum 0.888 s), signal 0.079 s. The final guest snapshot recorded 75
running waits, zero reaps or wait errors, and no exit frame before/in signal.
The new helper diagnostic was captured before another helper could replace
its log: `boundary=checkpoint`, `elapsedMs=15079`, `jobEstablished=true`,
`pollCount=37`, `errorKind=foregroundDeadline`. This identifies the attempt
deadline, not an inner transport error.

The loop subsequently proved same-job cleanup and retried within its original
deadline. Aqua completed in 3.299 seconds at 12:54:34Z; the desktop matched
at 12:54:35Z. Another Aqua probe completed in 1.430 seconds at 12:54:40Z,
and stable proof passed at 12:54:41Z. The command advanced to authenticated
Recovery. This is the first complete live desktop-proof success after exercising
the cleanup-verified retry; the earlier `...22f` retry was followed by a console
transport failure. No transport failure occurred in this run so far.

SIP disable then completed successfully after second-attempt Recovery marker
proof at 12:56:43Z and fresh normal-boot verification. The result reported
`configuredDisabled=true` and all normal-boot, runtime, enforcement, and
final-state verification fields true. Public status confirmed stopped with no
helper before matching SIP-enable restoration. This supplies the first full
successful SIP-disable workflow that actually exercised the verified retry.

Matching SIP enable began at 12:58:10Z, passed second-attempt marker proof at
13:00:51Z, and completed after fresh normal-boot verification and restoration
at 13:01:49Z. The result reported `configuredDisabled=false` and all normal-
boot, runtime, enforcement, and final-state verification fields true. Public
inventory confirmed all nine internal VMs stopped with no helpers; the `...22h`
journal projection is `restorationComplete`, `sipEnable`, `previous`. Internal
storage has 139 GiB free. No retained failing VM or immutable identity was reset.

This validates the bounded cleanup-verified readiness retry in a complete live
SIP cycle. It does not establish why native first-login probes become slow,
nor resolve `...22f`'s later console transport error. The old Aqua timing/wait
instrumentation is now being removed, preserving the newer closed transport
diagnostics for that distinct unresolved boundary. Regression testing was
deferred until all VMs were stopped to avoid altering measured guest load.

### Aqua instrumentation cleanup

Removed the obsolete Aqua elapsed-time metadata, per-job wait counters, and
per-iteration observation logging from the foreground executor, guest agent,
and private security caller. Seven instrumentation-only tests were removed;
the permanent payload gates, same-job cleanup receipts, timeout summaries,
retry/deadline/stability checks, and native `waitpid`/`EINTR` behavior remain.
The newer `[DEBUG-desktop-transport-20260922]` diagnostics and their tests
remain temporary evidence for the unresolved console transport failure.

Main and read-only review found no behavior or validation blocker; repository
search found no old Aqua diagnostic tags/types in Sources or Tests. The final
seven-suite XcodeBuildMCP run passed 96 functions / 199 executions with zero
failures or skips:
`test_macos_2026-09-22T13-02-56-186Z_pid19434_e01c9770.xcresult`.
The cleanup is committed before building another signed Release. Its new guest
binary still requires live validation; earlier pinned guests are not replaced.

Cleanup commit `5a30a3e` built and installed through the canonical signed
Release workflow. Signature, exact entitlement, designated-requirement, and
archive checks passed. The installed digest is
`d64e754e120fef42698b6688f79925396d84b6c9d77298123628adabd52e274a`;
fresh login resolution and reported commit match. All 104 CLI checks passed.
The build reported existing PommeCore and GuestMDMEnrollment warnings; those
files are unchanged. New comparison `pomme-agent-owner26-20260922i` uses the
same internal IPSW, 40 GB disk / 4 GB RAM, and `--boot none` after dry-run
preflight. Existing VMs remain stopped; 139 GiB was available internally.

Creation began at 13:06:05Z, restore reached 100% at 13:09:57Z, Terminal was
verified at 13:11:24Z, and marker proof passed on attempt 2 at 13:11:27Z.
Normal-agent verification passed and public status confirmed stopped with no
helper. The VM UUID is `4c39e416-4ab5-48b9-aaf4-fef22d553158`, startup-volume
group `60a52b9b-12d7-4940-b0d3-f4c9bf0f03d9`, and immutable plan digest
`d11ba48042b48e3e2a798138a2a52fb96a14e1fbd41ee576c789d11fe465fa82`.
It pins the new `d64e754e…52e274a` agent. First-owner SIP disable follows
without intervening guest probes or account edits.

The cleanup-build first-owner command began at 13:12:35Z. The existing
owner-completion status-1 boot retry began at 13:13:57Z; owner completion passed
at 13:14:51Z and Setup Assistant at 13:14:54Z. Desktop verification started
at 13:15:11Z. The workflow failed at 13:16:00Z with
`normal-agent-aqua-timedOut`, `exited=false`, `outputComplete=false`, and
`terminationRequested=false`, then restored stopped state before SIP mutation.

The closed helper log was captured before any new boot. At 13:15:55Z it
reported `boundary=checkpoint`, `elapsedMs=15457`, `jobEstablished=true`,
`pollCount=19`, `errorKind=foregroundDeadline`. At 13:16:00Z it reported
`boundary=signal`, `elapsedMs=20459`, the same job-established/poll-count fields,
and `errorKind=agentTimeout`. Thus the single cleanup signal exchange hit its
five-second agent timeout after the original foreground deadline. This is
newly identified transport uncertainty at cleanup, not a console-start/status
reproduction and not evidence that SIGTERM was delivered or the child exited.

Public status confirmed stopped with no helper. The closed journal projection
is `phase=autologinIntent`, `operation=sipDisable`, `requestedFinalState=previous`.
The VM retains its exact creation pin and progress; no retry was permitted
without same-job cleanup proof. This confirms fail-closed behavior on the
new build but leaves the full first-owner workflow unsuccessful. The next
investigation targets the signal exchange and delayed-response boundaries,
without replaying an uncertain signal or widening proof acceptance.

### Signal exchange characterization

Read-only tracing found no blocking native termination wait in `process.signal`:
the guest issues group/process `kill` calls, then uses nonblocking reap/output
checks before writing stream frames and the final correlated response. The
host wire waits for that response, not merely a stream frame. Its timeout closes
the authenticated connection; the immediate ordinary cleanup-status request
cannot establish proof on the disconnected session.

A real socketpair characterization now covers a correlated signal response,
a withheld response, and a correlated exit stream with the response withheld.
Both withheld cases throw the exact exchange timeout, never return a partial
response, and write exactly one signal request. Peer synchronization and joined
cleanup avoid near-deadline scheduling sleeps. The first run exposed only a
test assertion comparing raw JSON key order; comparing decoded envelopes fixed
that assertion without a production change. Focused wire, foreground, and
coordinator suites passed 35 functions / 86 executions, zero failures/skips:
`test_macos_2026-09-22T13-24-36-586Z_pid23524_17e91d71.xcresult`.
This characterizes existing fail-closed behavior, not the cause of the live
delay or a transport fix. Any subsequent retry must obtain new authenticated
same-job cleanup proof rather than inferring success from a missing response.

Read-only reconnect tracing confirmed that the persistent daemon retains one
`PommeAgent` and its job registry across socket reconnects; the next connection
authenticates again. There is no guaranteed reconnect duration. If the daemon
restarts instead, the original in-memory job is absent and must be rejected.
The normal agent emits another correlated exit frame on a later status request
once that job is reaped and output is drained. A preceding status result may
still say running when the subsequent stream collection performs the reap.

The next candidate keeps the existing three-second cleanup window and original
120-second readiness deadline. A closed host-only cleanup adapter will capture
one authenticated normal session, verify its describe receipt against the
creation-pinned digest, persistent role, protocol/version, and status capability,
then query only the original job on that same pinned session. Only a closed
temporarily-unavailable connection state may be polled within the existing
window. Wrong identity, missing job, malformed evidence, cancellation, or budget
exhaustion remains failure; the uncertain signal is never repeated. This does
not claim daemon-instance continuity from a digest: it requires the original
guest-generated job ID to exist and supply fresh authenticated reap/drain proof.
No guest protocol, agent pin, credential, journal, or ordinary-command retry
behavior changes are intended. Tests must establish the reconnect and fresh-
registry rejection paths before signed live validation.

The candidate implements that host-only adapter and routes the reserved marker
before ordinary guest forwarding. The marker is stripped only after identity
proof. It does not replay the signal or change guest code, protocol, credentials,
pins, or journals. The three-second bound is the caller's cleanup deadline:
helper-side describe/status retain their ordinary exchange limits and may
outlive it, but late results cannot authorize another readiness probe.

Tests-first evidence: the real desktop-readiness loop failed only the new
unavailable-then-verified reconnect case before implementation (83 executions,
one failure, `test_macos_2026-09-22T13-29-00-323Z_pid24443_1f5aa90f.xcresult`).
Real authenticated two-connection daemon tests establish that the original
job survives a socket reconnect after an unread signal response, supplies a
later correlated exit frame without another start/signal, and is absent from
a fresh daemon registry. Concrete coordinator tests reject replacement during
describe or status; a subsequent attempt must describe the new session again.

Integration review caught a separate candidate defect before installation:
the control bridge adds `ok` and `hostExitCode`, which the initial closed
receipt parser rejected. Two tests through the actual response-normalization
function reproduced that mismatch (49 executions, two failures,
`test_macos_2026-09-22T13-36-48-656Z_pid26911_6a7c51e0.xcresult`). The canonical
host receipt now includes and strictly checks those fields. Unknown extras,
wrong field types, old-helper responses, wrong identity/job, cancellation, and
expired cleanup/readiness budgets remain failures.

Final XcodeBuildMCP verification across eight foreground, normal-security,
cleanup-adapter, daemon, wire, and coordinator suites passed 103 test functions /
260 executions, zero failures or skips:
`test_macos_2026-09-22T13-38-41-073Z_pid27301_735e3234.xcresult`.
All 21 offline installer checks also passed. These results do not establish
the cause of the live signal delay or a successful live reconnect. The change
and documentation are committed before signed Release and fresh-VM validation.

Candidate `e38d50a` built and installed through the canonical signed Release
workflow. Signature, exact entitlements, designated-requirement compatibility,
and archive checks passed. Installed SHA-256:
`2728f132889ac0d96f750731bf750b8717680e0cce97ce401998359e10e36d7e`.
Fresh login resolution and the reported commit matched; all 104 CLI contract
checks passed. Four existing PommeCore warnings remain outside this change.
After dry-run preflight and confirmation that all ten existing VMs were stopped,
fresh `pomme-agent-owner26-20260922j` creation began at 14:12:40Z. It uses the
same internal 26.6.2/25G83 IPSW, explicit 40 GB disk / 4 GB RAM, and `--boot none`.
There was 112 GiB free internally; no external drive, retained VM reset, or
creation-pin replacement is involved.

Restore reached 100% at 14:16:19Z, Recovery Terminal at 14:17:46Z, and marker
proof passed on attempt 1 at 14:17:48Z. Creation passed normal-agent verification
and returned stopped; public status independently confirmed no helper. VM UUID:
`8f979849-b72c-460a-ab29-1a367d1a54dd`; startup-volume group:
`a5f87069-a66e-4367-82d1-7534ce461616`; immutable plan digest:
`3bb45d246f3af95c09e1ca4a4ceaaae6bb79436f4812c1d16ba74cdd8fde2932`.
The VM pins the installed `2728f132…0e36d7e` agent. First-owner SIP disable
began at 14:18:49Z without standalone guest probes or owner changes.

The existing fresh-owner preference reboot retry began at 14:20:14Z. Owner
completion passed at 14:21:04Z and Setup Assistant completion at 14:21:07Z.
Desktop verification began at 14:21:24Z and the workflow advanced to Recovery
at 14:22:19Z. No timeout or reconnect was observed in the collected output;
this establishes successful desktop-proof compatibility, not live exercise
of the new reconnect path or resolution of the intermittent signal delay.

SIP disable passed first-attempt Recovery marker proof at 14:24:20Z and then
fresh normal-boot verification. It returned `configuredDisabled=true` with
normal-boot, runtime, enforcement, and final-state verification all true. Public
status separately confirmed stopped with no helper. Matching SIP enable began
at 14:25:38Z to restore the original security setting; no AMFI change was made.

SIP enable passed second-attempt marker proof at 14:28:20Z, verified a fresh
normal boot, and restored stopped state after 14:29:20Z. The result reported
`configuredDisabled=false` and all normal-boot, runtime, enforcement, and
final-state verification fields true. Public inventory confirmed all eleven
internal VMs stopped with no helpers; the journal projection for `...22j` is
`restorationComplete`, `sipEnable`, `previous`. Internal free space is 87 GiB.

This completes signed-build compatibility validation through a fresh creation
and full first-owner SIP disable/enable cycle. The intermittent live signal
timeout did not have an observed recurrence, so live reconnect recovery is not
yet established; deterministic reconnect and rejection coverage passed. The
temporary closed transport diagnostics remain for that open investigation.
No other issue is being declared fixed by this successful comparison.

The next sequential comparison revalidated clean tracked state at `e4358f3`,
the installed `e38d50a` digest, all eleven VMs stopped, and 87 GiB internal free
space. Fresh `pomme-agent-owner26-20260922k` uses the same internal 26.6.2/25G83
IPSW, explicit 40 GB disk / 4 GB RAM, and `--boot none` after dry-run preflight.
No implementation, deadline, or guest-load change separates this comparison
from `...22j`; no retained VM is reset.

Creation began at 14:31:04Z, restore reached 100% at 14:34:51Z, Terminal was
verified at 14:36:18Z, and marker proof passed on attempt 2 at 14:36:22Z.
Normal-agent verification passed and public status independently confirmed
stopped with no helper. VM UUID: `4cab2038-c0f4-4712-bc72-19adc7eabaf0`;
startup-volume group: `e91ed476-f537-4cb3-a77e-55f09f817c23`; plan digest:
`1c1943fd6898e1efca7f819536de6745416f565a2a58758d44c8644bda2fdea7`.
The installed `2728f132…0e36d7e` digest remains the new VM's creation pin.
First-owner SIP disable began at 14:37:25Z. A read-only host log follower
was attached beforehand, emitting only the existing closed desktop-transport
diagnostic tag, to retain any timeout evidence before helper-log replacement.
No raw helper output is stored and no guest probe or implementation changed.

The existing owner-completion reboot retry began at 14:38:42Z. Owner completion
passed at 14:39:38Z and Setup Assistant at 14:39:41Z. Desktop verification began
at 14:39:58Z and advanced to Recovery at 14:41:05Z. The continuous filtered
helper-log follower emitted no desktop-transport tags through that transition.
This is a second successful fresh-owner desktop comparison on the unchanged
candidate, not a live signal-timeout/reconnect reproduction.

SIP disable passed first-attempt marker proof at 14:43:07Z, then normal-boot
verification and stopped-state restoration after 14:44:06Z. All normal-boot,
runtime, enforcement, and final-state verification fields were true, with
`configuredDisabled=true`. The filtered log follower emitted no matching tags
through command completion and was stopped; no raw log artifact was created.
Public status confirmed stopped with no helper before matching SIP enable
began at 14:44:33Z.

SIP enable passed first-attempt marker proof at 14:47:06Z and completed
normal-boot verification and stopped-state restoration after 14:48:06Z.
`configuredDisabled=false` and all verification fields were true. Public
inventory confirmed all twelve internal VMs stopped with no helpers; the
`...22k` journal projection is `restorationComplete`, `sipEnable`, `previous`.
Internal free space is 63 GiB. The second unchanged fresh creation and full
first-owner SIP cycle passed without a captured desktop-transport timeout.
This evidence is committed before further experiments. The original signal
delay remains unexplained; successful comparisons are not presented as proof
that the reconnect branch ran.

### Live cleanup-adapter boundary check

Read-only lifecycle tracing rejected pause/resume as reconnect evidence: those
operations retain the runtime/coordinator and do not deliberately replace the
authenticated session. Restart or stop/start would discard the guest job
registry. No incidental lifecycle reconnect is claimed.

A separately scoped adapter check started `...22k` normally at 14:53:01Z
after confirming its stopped state. The signed installed helper and connected
normal agent reported the expected creation digest. One detached `/bin/sleep 2`
job was created and allowed to exit naturally. A same-user request through the
existing private host-control socket invoked the production reserved cleanup
adapter with that exact job and expected digest. It returned the canonical
version-1 `verified-status` receipt, matching job/digest, and a correlated exit
frame with no output. Separate wrong-digest, unknown-job, and null-marker
requests returned the closed `rejected` state. The socket remained owner-only;
no credential, protocol, helper, or agent configuration was changed.

Native `csrutil status` still reported SIP enabled. Graceful stop began at
14:54:29Z. This validates the actual control routing, live pinned describe/status
path, canonical receipt, and rejection responses—not transport loss/reconnect.
The next offline regression composes the real daemon, wire timeout, coordinator
replacement, and cleanup adapter to close the gap between the existing separate
daemon and mocked-coordinator tests. Test builds wait until this VM is stopped.

Graceful stop completed with `guest-stopped`; public inventory confirmed all
twelve VMs stopped with no helpers before test compilation began. The new
tests-only integration uses two socketpairs as a relay between the production
wire and real daemon. It delivers one signal, observes the actual successful
daemon reply, withholds that reply, and verifies the wire's real timeout and
coordinator connection closure. A newly authenticated connection against the
same agent registry then runs the production pinned cleanup adapter and obtains
the original job's exit proof. A fresh-registry variant returns `not-found` and
is rejected. Neither replacement connection starts nor signals a process;
all tasks and sockets are joined/closed and the bounded child is reaped.

The full nine-suite XcodeBuildMCP run passed 104 test functions / 262 executions,
zero failures or skips:
`test_macos_2026-09-22T14-55-45-864Z_pid40021_4b8e36aa.xcresult`.
This composes the formerly separate regression seams without a synthetic thrown
timeout or production fault hook. It is socketpair evidence, not physical VSOCK
fault injection or an explanation of the original live delay. Production source
is unchanged from `e38d50a`; the new test and live protocol evidence are committed
before refreshing the signed Release and verifying retained-pin compatibility.

Tests/evidence commit `1f377b7` was built and installed through the canonical
signed Release workflow. Signature, exact entitlements, designated requirement,
and archive checks passed. Installed SHA-256:
`c34baeda5838e1f3e934a1c2dde04500a05e613916c38afb398c1993eb3427c8`.
Fresh-login command resolution and reported commit matched; all 104 CLI checks
passed. Production source/configuration/scripts remain identical to `e38d50a`.
The retained `...22k` was confirmed stopped and started normally at 14:58:00Z
for live host compatibility against its unchanged `2728f132…0e36d7e` guest pin.

The refreshed host passed the live adapter check using another naturally exited
two-second job. The canonical receipt carried the original guest digest and
same-job exit frame. Supplying the new host executable digest instead was
rejected, demonstrating that rebuilding the host did not substitute its digest
for the retained creation pin. Native `csrutil status` returned enabled with
complete output and exit 0. Graceful stop began at 14:59:07Z and completed with
`guest-stopped`; public inventory again confirmed all twelve VMs stopped with
no helpers. No guest update, credential change, or journal rewrite occurred.

### Transport instrumentation cleanup

With composed real-wire reconnect/rejection coverage and signed live adapter
checks in place, the temporary `[DEBUG-desktop-transport-20260922]` layer is
now removed. Permanent stage/error diagnostics, timeout summaries, original
thrown errors, exact-probe gating, and all cleanup/retry/deadline guards remain.
This cleanup does not explain the original native first-login delay or claim
that the earlier console transport failure was reproduced. The current status
table retains those limits rather than treating successful comparisons as a
root-cause finding. All twelve VMs were stopped before the cleanup test build;
61 GiB was free internally before final signed-build validation.

The nine focused XcodeBuildMCP suites passed 104 test functions / 262 executions,
zero failures or skips:
`test_macos_2026-09-22T15-02-35-709Z_pid41953_29c3041c.xcresult`.
Independent review confirmed the diff removes only diagnostic instrumentation;
error propagation, single-start/single-signal assertions, cleanup receipts, and
all readiness/reconnect bounds remain. Temporary-symbol searches in Sources
and Tests and `git diff --check` passed. This cleanup is committed before the
signed Release build and fresh internal-drive live validation.

Cleanup commit `a3852a5` built and installed through the canonical signed Release
workflow. Signature, exact entitlements, designated-requirement compatibility,
and signed-artifact archival checks passed. Installed SHA-256:
`55142e268e4402985cb6012326df6450687fca094888ffad3937bc1701887b5a`.
Fresh-login command resolution and version matched; all 104 CLI contract checks
and 21 installer regression checks passed. Four existing PommeCore warnings
remain outside this cleanup. All twelve retained VMs were stopped before
preflight. Fresh `pomme-agent-owner26-20260922l` creation began at 15:07:57Z
using the same internal 26.6.2/25G83 IPSW, explicit 40 GB disk / 4 GB RAM,
and `--boot none`; 61 GiB was free internally. No retained VM was reset and
no external storage is used.

Restore reached 100% at 15:11:51Z, Terminal verification at 15:13:19Z, and
second-attempt marker proof at 15:13:22Z. Normal-agent verification passed and
creation returned stopped, independently confirmed by public status. VM UUID:
`4631bbe6-33d2-4ad0-82b5-2ac74c1fa1f7`; startup-volume group:
`2a6bfc5c-5626-4883-8192-8f0fb2df46d9`; immutable plan digest:
`02686510ca39f044fc561e0e31f58b090be57f1d3ca226f7a7573f127f8e1899`.
The VM pins the installed `55142e26…887b5a` agent. First-owner SIP disable
began at 15:14:21Z without standalone guest probes or owner changes.

The existing fresh-owner preference reboot retry began at 15:15:43Z. Owner
completion passed at 15:16:39Z, Setup Assistant at 15:16:42Z, and desktop
verification began at 15:16:58Z. At 15:17:39Z the permanent diagnostic reported
`normal-agent-aqua-timedOut`, with `exited=false`, `outputComplete=false`, and
`terminationRequested=true`. The workflow subsequently completed desktop proof
and advanced to authenticated Recovery at 15:18:13Z. This exercises the bounded
cleanup-verified retry in the instrumentation-free signed build. It does not
establish that reconnect was required or explain the underlying probe delay.

SIP disable passed second-attempt Recovery marker proof at 15:20:14Z, then
normal-boot verification and stopped-state restoration after 15:21:19Z. The
result reported `configuredDisabled=true` with normal-boot, runtime,
enforcement, and final-state verification all true. Public status independently
confirmed stopped with no helper before matching SIP enable was started to
restore the original security setting. No AMFI change was made.

Matching SIP enable began at 15:21:41Z, passed first-attempt Recovery marker
proof at 15:24:11Z, and completed normal-boot verification and stopped-state
restoration after 15:25:13Z. The result reported `configuredDisabled=false`
and all verification fields true. Public inventory confirmed all thirteen
internal VMs stopped with no helpers. The `...22l` journal is
`restorationComplete`, `sipEnable`, `previous`. Internal free space is 35 GiB;
another fresh installation requires a capacity decision, not smaller test
resources or external storage. No retained VM or pinned artifact was deleted.

The instrumentation-free candidate therefore passed fresh creation and a full
first-owner SIP disable/enable cycle, including a timed-out Aqua probe followed
by successful bounded cleanup/retry. This is stronger than a no-timeout
compatibility comparison, but does not establish the original delay's cause,
live reconnect recovery, or resolution of the earlier console transport error.
The live outcome is committed before moving to further investigation.

### Retained console-transport fixture resume

After the instrumentation-free fresh cycle, the next bounded comparison uses
the retained internal `pomme-agent-owner26-20260922f` rather than allocating
another VM. All thirteen VMs were stopped; 35 GiB was free internally. Signed
host `a3852a5` and its `55142e26…887b5a` digest were revalidated. The target
still has its original `990bf1bc…df69f6` creation pin and
`autologinIntent` / `sipDisable` / `previous` journal, with original run state
stopped and no normal-boot success receipt. No journal, credential, owner,
agent, or immutable creation record is manually changed.

The exact retained SIP-disable request is repeated through the public CLI.
This preserves the failure record above but necessarily advances the live
journal if resume succeeds. The fixture has already had a later normal boot
and passing standalone probes; success therefore cannot establish a fresh
first-login reproduction or identify the original console transport boundary.
The intended check is recovery of the retained workflow with the newer signed
host and older pinned guest, followed by SIP enable and stopped-state proof.

Resume began at 15:27:18Z. Existing-owner completion passed at 15:28:02Z and
Setup Assistant completion at 15:28:04Z. Console/desktop verification began at
15:28:35Z and advanced to authenticated Recovery at 15:28:47Z, with no reported
timeout. Recovery marker proof passed on attempt 2 at 15:30:48Z. Normal-boot
verification followed at 15:31:23Z and stopped-state restoration at 15:31:52Z.
The command returned `configuredDisabled=true` with all verification fields
true. Public status confirmed stopped with no helper and the original guest
pin unchanged. The journal reached `restorationComplete` for `sipDisable` /
`previous`; matching SIP enable follows to restore the original enabled state.

SIP enable began at 15:32:19Z, passed first-attempt marker proof at 15:34:48Z,
and completed normal-boot verification and stopped-state restoration after
15:35:49Z. `configuredDisabled=false` and all verification fields were true.
The final journal is `restorationComplete` / `sipEnable` / `previous`, with
normal-boot verification true. Public inventory confirmed all thirteen VMs
stopped with no helpers. The original VM UUID, immutable plan, and guest digest
are unchanged; no agent update or credential replacement was performed.

This closes the retained transaction on `...22f` and validates current-host /
older-pinned-agent resume compatibility through the complete SIP cycle. No
desktop timeout or transport failure recurred. It does not resolve the
historical console-transport cause, reproduce the original fresh-login timing,
or establish live reconnect recovery. Those observations remain open.

### macOS 27 pause/resume/restart repetition

After committing the retained-console fixture outcome, investigation returns
to the historical missing-helper failure after pause/resume/restart. No
production change is proposed without a failing reproduction. The same
internal `pomme-agent-ownerproof-20260922a` remains macOS 27.0/26A428 with an
explicit 40 GB disk / 4 GB RAM, original UUID
`30d2a972-988e-4c69-9015-6bb5f1df2baf`, and agent pin
`011eea30cd2a4f48164332e062f05ecd8dd70417b30ad05603befa3495ce42f2`.
All thirteen VMs were stopped before this scoped run. Installed signed host
`a3852a5` is unchanged; normal start began at 15:37:24Z and passed with a
connected, correctly pinned agent.

A ten-cycle sequential loop began at 15:38:18Z. Each cycle runs public `pause`,
checks paused state with a live helper, runs `resume`, and immediately runs
`restart --mode normal` with the unchanged default 300-second readiness bound.
It then requires public status to report running/normal, helper present, and a
connected normal agent with the exact original digest. The shell uses
`set -euo pipefail` and `jq -e` checks, so the first command or postcondition
failure terminates the loop without another mutation or automatic retry.
Commands use `--format json --debug`; no artificial wait or guest load is
inserted. No VM is created or moved and no credential, journal, or pin is reset.

All ten cycles passed, ending at 15:45:37Z. Completion timestamps were
15:38:57, 15:39:40, 15:40:18, 15:41:21, 15:42:03, 15:42:43, 15:43:09,
15:44:14, 15:44:54, and 15:45:37Z. Each restart returned a different helper PID
and the required running/normal/connected status with the unchanged agent pin.
No missing-helper error or failed postcondition occurred. The ten cycles are
correlated observations on one initialized VM, not ten independent fresh VM
creations. There is no post-resume agent-readiness wait or assertion; the final
check proves eventual readiness after restart, not uninterrupted connectivity
across resume. This run supplies stronger non-reproduction evidence but no
root-cause finding or justified lifecycle source change.

Graceful stop began at 15:45:50Z and completed with `guest-stopped`. Public
inventory confirmed all thirteen internal VMs stopped with no helpers. The
current signed Release remains installed; only this evidence document changed.

Read-only archive inspection found the exact original sweep host `ffc41a7`
preserved at `AgentArtifacts/sha256/2e0a2f4959071eb80051ab103b9b41cd5f8fea8eae8aa257376cbf4a747aaeff/pomme-agent`.
It is an owned regular non-symlink executable with mode `0555`; digest, version,
and required Developer ID/team/signature checks passed. The next comparison
invokes that archived binary directly for the same ten-cycle sequence on the
same stopped internal VM. The installed `a3852a5` remains untouched. Using
the original host removes a host-build difference, but the fixture remains an
initialized internal-drive VM rather than the deleted original sweep VM.

Original-host baseline start began at 15:49:04Z and passed independently before
the loop. All ten baseline cycles then passed from 15:49:56Z to 15:56:58Z.
Cycle completion times were 15:50:39, 15:51:23, 15:52:06, 15:52:46, 15:53:26,
15:54:12, 15:54:37, 15:55:22, 15:55:53, and 15:56:58Z. Each restart returned
a new helper PID and passed identical postconditions. No missing-helper error
or failed readiness/status check occurred. The original signed host therefore
also fails to reproduce the historical symptom on this fixture; later source
changes cannot be credited as its fix from these observations.

The original host gracefully stopped the VM at 15:57:18Z with `guest-stopped`.
Current-host public inventory independently confirmed all thirteen VMs stopped
with no helpers. Installed version remains `a3852a5`, SHA-256
`55142e268e4402985cb6012326df6450687fca094888ffad3937bc1701887b5a`.
No lifecycle source change or rebuild was made without a failing case. This
bounded original/current-host comparison is complete; the issue stays open
pending evidence that distinguishes the deleted sweep fixture or its timing.

### Authorized capacity recovery

The user authorized deleting Pomme VMs needed for continued testing. At
16:15:57Z the signed installed CLI deleted only the completed internal fixtures
`pomme-agent-owner26-20260922j`, `pomme-agent-owner26-20260922k`, and
`pomme-agent-owner26-20260922l`. Before deletion each was stopped with no helper,
and its journal was `restorationComplete` / `sipEnable` / `previous` with
normal-boot verification true. Their live results remain recorded above.
The public delete results all succeeded; inventory independently confirmed
the three targets absent and all ten remaining VMs stopped. Free internal
space increased from 35 GiB to 113 GiB. These three VM states were permanently
removed; the retained failure fixtures, restore images, and signed-agent
archives were preserved. No external storage was used.

### Fresh original-host macOS 27 creation comparison

With capacity recovered, original signed host `ffc41a7` passed a local-image
dry run for fresh `pomme-agent-ownerproof-20260922b`. The resolved identity is
macOS 27.0.0/26A428 with virtualization provisioning and SSH bootstrap, matching
the route that reported the original `ownerProof` failure. Creation began at
16:16:52Z using internal `UniversalMac_27.0_26A428_Restore.ipsw`, explicit
40 GB disk / 4 GB RAM, and requested stopped final state (`--boot none`).
The archived host is invoked directly; installed `a3852a5` is unchanged.
No older VM is reset or cloned. This is a fresh internal-drive reproduction
attempt with the original host bytes, not a replay of the deleted external-
drive sweep fixture. No owner-proof source change is proposed without a
failing case.

Restore reached 100% at 16:21:39Z. SSH authentication/UID verification,
artifact/manifest staging, and installer invocation passed; the agent
connected at 16:22:35Z. After normal reboot, authentication and owner proof
began at 16:23:43Z. Owner proof passed by the desktop-proof checkpoint at
16:23:58Z, followed by volume-identity persistence at 16:24:04Z and complete
verification at 16:24:05Z. Creation succeeded and restored stopped state with
automatic login enabled and Remote Login off. Public status independently
confirmed stopped with no helper.

New VM UUID: `3537678d-d4a8-4272-b8df-c1952f3f6aac`; startup-volume group:
`582fb9d1-d8b5-420c-a479-9066c6fb5b0a`; immutable plan digest:
`ce709acef2d958e5e202988c14351874f906bfbb1254004da645bdadee71ab2b`.
Its persistent agent pins the original `2e0a2f49…47aaeff` executable. This
fresh original-host run did not reproduce the reported owner-proof failure;
it is not evidence that later changes fixed that historical observation.
No owner-proof source change or installed-host replacement occurred.

### Fresh original-host macOS 26 bootstrap comparison

After the original-host macOS 27 owner-proof run passed, the next single-issue
comparison targets the historical macOS 26 `verifyNormalAgent` failure. All
eleven retained VMs were stopped; 84 GiB was free internally. Original signed
host `ffc41a7` passed direct local-image dry run for new
`pomme-agent-bootstrap26-20260922a`, resolving macOS 26.6.2/25G83 and Recovery
agent installation. Creation uses the same internal IPSW, explicit 40 GB disk
/ 4 GB RAM, and `--boot none`. The archived original host is invoked directly;
installed `a3852a5` remains unchanged. No retained fixture is reset or cloned.
If the attempt fails, the phase/result and public state are captured before
any retry; an earlier navigation/marker failure is not counted as a reproduction
of the later normal-agent verification failure.

Creation began at 17:09:56Z and restore reached 100% at 17:13:42Z. Recovery
Terminal was verified at 17:15:09Z, first-attempt marker proof passed at
17:15:11Z, and launcher submission followed at 17:15:14Z. The command completed
successfully with requested final state stopped. The closed journal projection
is schema 1 / generation 9, with first-attempt intent and receipt pairs for
`install`, `installRecoveryAgent`, `verifyNormalAgent`, and `restoreFinalState`;
there are no failure events. Public status independently confirmed stopped
with no helper and the original-host agent pin unchanged.

VM UUID: `1d66aa22-5c8d-46a4-8af4-cc16f6377c85`; startup-volume group:
`1a0d05f1-1264-498e-b249-19b65eff2625`; immutable plan digest:
`d200ce057a9fc2bd8ace9baf5d3853e8d3c3bcd5946756994b7b74f581b798fc`.
The persistent agent pins `2e0a2f4959071eb80051ab103b9b41cd5f8fea8eae8aa257376cbf4a747aaeff`.
All twelve internal VMs are stopped with no helpers; free internal space is
62 GiB. The original-host fresh run did not reproduce `verifyNormalAgent`
failure or require a five-minute recovery start/resume. `automaticLogin=legacy`
and Recovery provisioning are expected for this route, not owner-proof success.
No source fix or installed-host replacement is justified by this passing run;
the historical slow-boot cause remains open.

### Original-host owner-session/private-PTY comparison

The next bounded comparison uses newly created internal
`pomme-agent-bootstrap26-20260922a` to investigate the historical SIP owner-
session/private-PTY/authentication sequence. Preflight confirmed stopped with
no helper, Recovery provisioning, original `2e0a2f49…47aaeff` agent pin,
40 GB disk / 4 GB RAM, and no existing security workflow journal. The exact
original signed `ffc41a7` host invokes public `sip disable --force
--final-state previous --format json --debug`. No standalone guest probes,
owner changes, credential substitutions, journal edits, or agent updates precede
the attempt. A failure will be captured and classified before any retained
resume. Successful mutation will be followed by SIP enable to restore the
original enabled security setting and stopped run state.

Original-host SIP disable began at 17:17:55Z. Setup Assistant handoff passed
at 17:18:53Z; the existing one-time fresh-owner preference reboot began at
17:19:16Z. Owner completion and automatic-login configuration passed at
17:20:18Z, followed by Setup Assistant completion at 17:20:21Z. Desktop
verification began at 17:20:37Z and advanced to authenticated Recovery at
17:21:35Z. No owner-session, private-PTY, desktop-timeout, or pinned-authentication
failure was reported. First-attempt Recovery marker proof passed at 17:23:35Z;
normal-boot verification followed at 17:24:10Z and stopped-state restoration
at 17:24:39Z. The result reported `configuredDisabled=true` with all verification
fields true. Public status confirmed stopped with no helper and the journal
reached `restorationComplete` / `sipDisable` / `previous`. Matching original-
host SIP enable follows to restore the initial enabled state; no AMFI command
or manual retained-state change is used.

Original-host SIP enable began at 17:25:06Z, reverified the existing owner,
and passed first-attempt Recovery marker proof at 17:27:45Z. Normal-boot
verification began at 17:28:20Z and stopped-state restoration at 17:28:47Z.
The successful result reported `configuredDisabled=false` and all verification
fields true. The journal reached `restorationComplete` / `sipEnable` /
`previous`, with normal-boot verification true. Public inventory confirmed all
twelve VMs stopped with no helpers. VM identity, creation plan, and original
agent pin remain unchanged; SIP is restored enabled and no AMFI mutation was
performed.

The original-host first-owner cycle passed without the historical Aqua-session,
private-PTY, or pinned-authentication failure. Since it did not leave a failed
transaction, this does not exercise the reported failing SIP-resume sequence;
no artificial failure or journal state was introduced to manufacture one.
It supplies another bounded non-reproduction result, not a root-cause finding
or a justification for credential/PTY changes. The current signed host remains
installed, and the original failures remain open pending a matching failure.

### Integrated verification: parallel test-run hang

The installed signed `a3852a5` host again passed all 104 CLI contract checks,
all 21 local installer checks, strict code-signature verification, and fresh
login-shell command resolution. Its SHA-256 remains
`55142e268e4402985cb6012326df6450687fca094888ffad3937bc1701887b5a`.
All twelve VMs were confirmed stopped, with no helpers and all bundles on the
internal drive. No VM deletion or mutation was needed for these checks.

An unrestricted Debug `PommeCLITests` run through XcodeBuildMCP began at
17:35:44Z, discovering 1,156 test functions. The runner used a fresh private
`POMME_APP_SUPPORT_DIR`, with target and owner-authorization environment values
cleared; temporary-Keychain tests did not target the login Keychain. Progress
stopped after reporting 919 completed tests and no failures. Two live process
samples minutes apart showed the main thread blocked in
`CreateVMTUIPTYTests.cancellationRestoresTerminal` → `TUITerminal.readKey` →
`read`, alongside cooperative workers blocked in socket reads and Vision OCR.
The isolated runner was cancelled through its exact `xcodebuild` parent after
preserving diagnostics; the reported 937 passes and 44 cancellation failures
are not a completed or successful full-suite result. Result bundle:
`test_macos_2026-09-22T17-35-44-560Z_pid70082_9d85d319.xcresult`.

Without source changes, the two `CreateVMTUIPTYTests` passed alone (5.4 seconds),
and a group with `PommeAgentDaemonTests`, `ControlWireTests`,
`PommeSecurityHelperShutdownTests`, and `PommeRecoveryTerminalRecognitionTests`
passed all 34 test functions (5.8 seconds). An unchanged full-suite retry at
17:47:28Z reproduced the same blocked TUI cancellation stack and blocked
cooperative workers. It too was cancelled after sampling, not counted as a
test pass. Result bundle:
`test_macos_2026-09-22T17-47-28-787Z_pid72086_0b79c43e.xcresult`.

The baseline cancellation test sends input from a detached async task and
returns from a failed transcript wait without unblocking the TUI's read.
Cooperative-worker starvation and that failure-cleanup gap are the next
bounded test-harness investigation. The smaller passing group has not isolated
a deterministic minimal combination. This validation hang is not evidence of
the cause of the historical live VM failures, and no production fix is claimed.

A test-only dedicated-thread PTY driver candidate passed the create and
snapshot PTY suites (six functions / seven invocations), including injected
driver failure and missing-transcript timeout at the actual restore-source
menu. The full-suite candidate run at 17:53:37Z still stalled. Its live sample
showed an idle main thread rather than the previous TUI read, with cooperative
workers blocked in socket/OCR operations and the desktop-cleanup integration
test's relay read. This does not establish that the candidate resolves the
integrated hang. The run was cancelled after sampling; result bundle:
`test_macos_2026-09-22T17-53-37-527Z_pid73435_b34bc320.xcresult`.
Review also identified timeout-fallthrough weaknesses in the candidate's own
join/cancellation cleanup, which must be corrected before it is committed.
No full-suite pass, production change, release replacement, or live VM fix is
claimed from this test-harness work.

The corrected PTY harness uses a dedicated OS thread for transcript-driven
input, propagates driver errors back to the owning test, and closes the master
only in the output-drain cancellation handler. Broadcast completion joins
prevent teardown while a driver or drain callback can still use its descriptors.
Transcript waits have finite deadlines; completion joins deliberately do not
claim an absolute deadline under stalled OS/GCD scheduling. Initialization
failure before source registration also completes teardown without waiting for
a callback that cannot exist. Production TUI and VM code are unchanged.

Final create/snapshot PTY verification passed six test functions / seven
invocations, including injected error and missing-transcript failure after
reaching the real restore-source menu. Normal cancellation still verifies no
creation and restored terminal modes. Result bundle:
`test_macos_2026-09-22T17-57-42-219Z_pid74243_9d29bf3b.xcresult`.
This fixes the test input driver's dependency and failure-cleanup gap; the
separate full-suite socket/OCR stall remains under investigation.

Test-harness commit `052f05d` was built and installed using the canonical signed
Release workflow at 17:58:43Z. Signature, exact entitlements, designated-
requirement compatibility, and archive/install checks passed. Installed digest:
`4b0d2e777be8abb3c57f72fe7c44d7b44af0a3c7521ea0072ae8d0911ed62d06`.
Fresh login-shell resolution selected `/Users/wes/.local/bin/pomme`, reporting
`052f05d`. All 104 CLI contract and 21 installer regression checks passed.

The existing internal-drive 40 GB / 4 GB macOS 27 fixture
`pomme-agent-ownerproof-20260922a` was explicitly confirmed stopped before
normal start at 17:59:01Z. Start succeeded with a connected normal agent and
unchanged creation pin `011eea30…95ce42f2`. The signed CLI then ran interactively
under a host PTY: dashboard → create form → proposed name
`pomme-agent-pty-cancel-20260922a` → restore-source menu → Escape → dashboard →
`q`. It exited zero with cursor/alternate-screen restoration sequences; the
inventory remained twelve VMs and the proposed name did not exist. This is a
live cancellation smoke check, not an exact termios measurement or a full-suite
pass. Direct invocation through the command proxy rejected its noninteractive
stdin/stdout; `script -q /dev/null` supplied the real PTY without a transcript
file. Graceful stop at 18:00:14Z succeeded with `stopMethod=guest-stopped`;
the final inventory confirmed all twelve VMs stopped with no helpers.

#### Parallel socket/OCR reproduction narrowing

After the TUI fixes, an unchanged six-suite selection (create PTY, daemon,
control wire, helper shutdown, Terminal OCR, and desktop cleanup integration)
passed 36 test functions / 39 invocations once at 18:15:19Z. Repeating that
selection ten times reproduced the stall at 18:16:06Z. The main thread was idle;
all eight cooperative workers were occupied by socket reads or Vision OCR.
The isolated runner was cancelled after sampling, not counted as a pass.
Result bundles: `test_macos_2026-09-22T18-15-19-788Z_pid81160_8382e014.xcresult`
and `test_macos_2026-09-22T18-16-06-815Z_pid81329_2871cb8d.xcresult`.

The following six-method selection with `-test-iterations 10` reproduced the
same stall at 18:20:17Z, without the TUI or helper-shutdown suites:

```text
PommeAgentDaemonTests/socketpairAdmission()
PommeAgentDaemonTests/oneShotOperation()
ControlWireTests/streamingSocketRoundTrip()
PommeRecoveryTerminalRecognitionTests/generatedProbeHasStrictOCRProof(_:)
PommeRecoveryTerminalRecognitionTests/generatedProbeEchoCannotAuthorize()
PommeSecurityDesktopCleanupIntegrationTests/lostSignalResponse(newRegistry:)
```

Each selector is supplied as `-only-testing:PommeCLITests/<selector>` through
XcodeBuildMCP with the same isolated app-support environment and Debug build
settings as the full run. After five minutes, a process sample again showed
three synchronous client reads, the cleanup relay's daemon read and relay
`recv`, and three OCR invocations occupying the cooperative pool. Cancellation
ended the run; its result is
`test_macos_2026-09-22T18-20-17-621Z_pid82430_6b872c5b.xcresult`.
An earlier selector attempt without the function-signature suffixes executed
zero test cases despite the discovery banner and success exit; it is excluded
from validation evidence.

Each single-method removal from that selection then completed ten repetitions
without code changes. Actual executed case lines, rather than the discovery
banner, establish the counts (parameterized functions have multiple cases):

| Removed method | Passing invocations | Elapsed | Result bundle suffix (2026-09-22) |
|---|---:|---:|---|
| `lostSignalResponse(newRegistry:)` | 60 | 11.8 s | `18-25-34-343Z_pid83348_7dba8885` |
| `socketpairAdmission()` | 70 | 25.5 s | `18-26-18-057Z_pid83547_64983b4e` |
| `oneShotOperation()` | 70 | 25.3 s | `18-27-09-369Z_pid83864_b2dc17ab` |
| `streamingSocketRoundTrip()` | 70 | 25.3 s | `18-27-41-739Z_pid83966_983d39ba` |
| `generatedProbeHasStrictOCRProof(_:)` | 60 | 25.5 s | `18-28-15-364Z_pid84139_09f34f2f` |
| `generatedProbeEchoCannotAuthorize()` | 70 | 25.3 s | `18-28-55-113Z_pid84327_2c9b265e` |

The leading hypothesis is aggregate cooperative-pool starvation, with the
test relay's synchronous blocking loop as the first removable contributor.
The bounded candidate moves only that loop to a dedicated thread and delivers
its completion/error back to the owning test asynchronously. The actual async
daemon and host exchange remain unchanged for this comparison. A passing
candidate must still rerun the six-method reproducer, the six-suite repeated
selection, and the full parallel suite. This is not evidence of a production
multi-connection daemon bug or the historical live-VM failures' root cause.

The relay-only candidate passed the exact six-method selection for all 80
invocations across ten repetitions (25.3 seconds), result
`test_macos_2026-09-22T18-32-24-235Z_pid85200_22377fe0.xcresult`.
Adding the malformed-relay-input/repeated-finish regression also passed all
90 invocations, result
`test_macos_2026-09-22T18-31-39-938Z_pid84995_5daee562.xcresult`.
The regression delivers a real decode error to the owning test only after
coordinated teardown; repeated finish preserves the same error without closing
descriptors again.

The expanded six-suite repeated run still stalled, result
`test_macos_2026-09-22T18-33-04-678Z_pid85323_cc3521c5.xcresult`.
Its sample confirmed that the relay loop no longer occupied a cooperative
worker, but `PommeSecurityHelperShutdownTests.normalClientReleasesExitAfterResponseHook`
joined the two daemon-test client reads, control-stream client read, daemon
read, and three OCR invocations in occupying all eight workers. The runner was
cancelled after sampling. Thus relay isolation is a verified contributor fix,
not a complete integrated-hang fix. The next bounded comparison moves the two
sampled daemon-test client reads off the cooperative pool, leaving actual
daemon serving unchanged and requiring shutdown/await before descriptor close
on failure as well as success.
Xcode also reported that cancellation prevented the action log from finishing
within its result-save window; this incomplete bundle is not validation proof.
The exact runner and test-host processes were confirmed gone before further
testing.

The second candidate moves the two daemon-test client read loops onto dedicated
threads, returning results through checked continuations. Polling uses a total
five-second deadline and nonblocking receive; a silent-peer deadline regression
covers error delivery before descriptor teardown. Successful tests still require
the actual daemon to finish naturally (including the one-shot operation); they
do not force success by shutting down its socket after reading the responses.
Only a read failure or completion-watchdog failure triggers shutdown, followed
by joining before close. The watchdog joins both results so a shutdown-induced
daemon return cannot disguise a timeout as natural completion.

With both test-only changes, the six-suite selection passed all 38 functions /
410 invocations across ten repetitions (37.7 seconds), result
`test_macos_2026-09-22T18-39-50-158Z_pid86710_da7578fe.xcresult`.
Production code, test parallelism, the real daemon/wire/coordinator boundaries,
and authentication/job-correlation assertions remain unchanged. Full parallel
verification is still required before declaring the integrated hang resolved.

Three unrestricted, unchanged full parallel comparisons subsequently finished
without the hang, each reporting 1,164 passing functions and one failure:

| Start UTC | Elapsed | Remaining failure | Result bundle |
|---|---:|---|---|
| 18:40:42 | 13.5 s | `PommePrivatePTYRunnerTests.initialPromptGatesPrivateInput`: `processTimedOut` | `test_macos_2026-09-22T18-40-42-033Z_pid87056_6d1ebc40.xcresult` |
| 18:41:10 | 11.9 s | `PommeAgentProcessExchangeTests.reconnectAfterDroppedSignalResponse`: `guestAgentTimedOut` | `test_macos_2026-09-22T18-41-10-042Z_pid87221_f716aad0.xcresult` |
| 18:41:49 | 12.1 s | Same reconnect exchange timeout | `test_macos_2026-09-22T18-41-49-826Z_pid87447_24e11d84.xcresult` |

These are completed failing runs, not passes, cancellations, or proof that all
parallel timing issues are fixed. The bounded change removes three known
blocking test peers from the cooperative pool and preserves the original
assertions; it does not change production code or extend the failing tests'
deadlines. The newly exposed prompt/reconnect timing failures remain the next
investigation after committing, signed-building, and live-checking this change.
Read-only review found no descriptor-lifetime or one-shot-proof blocker. The
reader's cancellation may wait for its five-second deadline; this bounded wait
does not allow descriptor teardown while its thread can still access them.

The test-harness fix and evidence were committed as `0291f65` before the
canonical signed Release build at 18:42:48Z. Build, strict signature, exact
entitlements, designated-requirement compatibility, archive retention, and
atomic installation checks passed. Fresh login-shell resolution selected
`/Users/wes/.local/bin/pomme`, reporting `0291f65`. Installed SHA-256:
`be61ee7ac5aa30d5c22bdb2f6b7ac2cda3f69da3b8b4c8464fafcaaa1644ed4c`.
All 104 CLI contract checks and 21 local build/install checks passed.

For the required live release smoke check, the explicitly scoped internal-drive
macOS 27 fixture `pomme-agent-ownerproof-20260922a` was verified stopped, with
40 GB disk / 4 GB memory, before normal start at 18:43:05Z. The new signed host
started helper PID 89541 and connected to the unchanged creation-pinned guest
agent `011eea30…95ce42f2`. A foreground `/bin/echo` returned the expected output
and exit zero. `/bin/sleep 5` with `--timeout 1` returned host exit 124 and
`terminationRequested=true`. Inspection of that exact job
`78e37a7c-6255-4e8c-83ec-80e1347afde2` subsequently returned `exited=true` and an
exit frame with signal 15; a guest `ps -p 638` returned no matching process.
The agent remained responsive. Graceful stop at 18:43:53Z returned
`stopMethod=guest-stopped`; helper PID 89541 was confirmed gone, and final
inventory showed all twelve VMs stopped without helpers on the internal drive.
No VM was deleted or moved and no guest agent, journal, credential, or security
state was changed. This verifies release compatibility and live process
behavior, not a live reproduction of the host test-pool hang. The two full-suite
timeout observations above remain open.

### Reconnect exchange timeout under parallel test load

With signed host `0291f65` installed and all twelve internal VMs stopped,
the next investigation isolates the remaining
`PommeAgentProcessExchangeTests.reconnectAfterDroppedSignalResponse` failure.
No production code, timeout, or VM state was changed during these comparisons.
Debug tests retain the private app-support environment described above.

| Selection | Repetitions | Observed result | Result bundle suffix (2026-09-22) |
|---|---:|---|---|
| Reconnect method alone | 30 | All 30 invocations passed | `18-45-27-659Z_pid90125_e1834561` |
| Prior six stress suites plus reconnect | 10 | All 39 functions passed | `18-45-56-273Z_pid90392_33debf93` |
| Above plus GuestAgent / VM / Control suites | 3 | Reconnect passed; `RecoveryRuntimeAgentCoordinatorTests.retryAfterFailure` failed once | `18-47-02-183Z_pid90904_159c951c` |
| Above plus GuestInternal / GuestFiles suites | 3 | Reconnect failed once; 366 other functions passed | `18-47-44-422Z_pid91053_eab379f9` |
| Added GuestInternal / GuestFiles suites alone | 3 | All 139 functions passed | `18-48-17-455Z_pid91302_3665955a` |
| Those 139 plus prior six stress suites | 3 | All 177 functions passed | `18-48-49-965Z_pid91481_b2ea1540` |
| 367-function selection minus prior six stress suites | 3 | All 329 functions passed | `18-49-24-550Z_pid91733_32982d4c` |
| 329-function selection plus Terminal OCR suite | 3 | All 338 functions passed | `18-49-55-738Z_pid91915_cda4c3e9` |

Result-bundle inspection confirms that the 367-function failure is the same
`guestAgentTimedOut("Pomme agent exchange")`, not a different assertion. The
229-function run's separate coordinator failure is an authenticated Recovery
readiness timeout and remains an additional observation, not a reconnect
failure. Removing groups changes scheduling; these passes do not establish
which operation missed its deadline or that the underlying failure is fixed.

The test currently loses operation/connection phase in its generic wire error.
The next diagnostic step adds temporary, redacted test-local phase and
monotonic timing: initial connection, reconnected original registry, and fresh
registry; exchange queued/start/end and daemon task start/return. It does not
record IDs, tokens, frames, command paths, or process output, and preserves
existing protocol checks and deadlines. Ranked hypotheses are cooperative
scheduling delay, a particular authentication/start/status phase exceeding its
budget, and a connection/framing failure. No candidate fix is established yet.

The initial diagnostic full run reproduced the reconnect timeout, result
`test_macos_2026-09-22T18-52-04-244Z_pid92378_52351d57.xcresult`, but Xcode did
not retain the test's printed trace in a console log. Diagnostics were then
attached to the already-failing owning test rather than printed. With that
reporting-only adjustment, one full run hit the separate private-PTY process
timeout (`test_macos_2026-09-22T18-53-48-311Z_pid92913_62e588b4.xcresult`),
and the next passed all 1,165 functions in 12.2 seconds
(`test_macos_2026-09-22T18-54-28-142Z_pid93147_01d9f49f.xcresult`). This is a
full pass for that diagnostic build/run, not evidence that the intermittent
timeouts are fixed. No deadline or functional fix has been applied.

An unchanged three-iteration full run captured the failing initial connection
in `test_macos_2026-09-22T18-54-57-844Z_pid93297_b65ef279.xcresult`:

| Event | Milliseconds after fixture start |
|---|---:|
| Daemon task created | 0.041 |
| Initial authentication exchange queued | 0.218 |
| Exchange worker started; one-second wire budget begins | 0.331 |
| Exchange returned an error | 1,001.737 |
| Daemon task actually started | 2,821.517 |
| Failure cleanup shut down the client socket | 2,835.628 |
| Daemon returned | 2,835.652 |

No job had been created or signalled, and reconnection had not begun. This
failure is attributable to starting the client deadline before the fixture's
daemon task was scheduled, not evidence of a production reconnect defect.
That stress run also recorded separate private-PTY, daemon admission/one-shot,
and desktop coordinator timeouts; those are not explained or closed by this
trace.

A deterministic regression delays the actual serving task by 1.2 seconds
while retaining the one-second wire deadline. Before an admission barrier,
`delayedDaemonAdmission` failed both its admitted-state assertion and initial
authentication with `guestAgentTimedOut`, result
`test_macos_2026-09-22T18-57-43-537Z_pid93950_2ac30681.xcresult`.
The bounded candidate awaits task entry after fixture setup and immediately
before real daemon serving, then invoke the client body. This synchronizes
test setup; it does not assert that the daemon has read bytes, extend protocol
deadlines, or alter production scheduling. Temporary trace instrumentation is
removed before committing the candidate.

With the barrier and no temporary tracing, the complete process-exchange suite
passed all ten functions / 100 invocations across ten repetitions (63.3 seconds
including build), result
`test_macos_2026-09-22T19-02-40-195Z_pid94638_f1542b0d.xcresult`.
The barrier uses a mutex-protected single checked continuation and resumes it
outside the lock; both enter-before-wait and wait-before-enter are safe.
Cancellation is checked after admission and enters existing shutdown/join/close
cleanup. Like the pre-existing daemon join, admission depends on serving-task
scheduling; this is not a general cancellation or pool-starvation solution.
The injected setup hook is bounded to 1.2 seconds.

The original failing parallel selection, now including the added regression,
passed all 368 functions / 1,341 invocations across three repetitions in
22.4 seconds, result
`test_macos_2026-09-22T19-04-16-626Z_pid95085_bf4ff9c4.xcresult`.

The unrestricted three-iteration comparison finished in 28.9 seconds with
all three reconnect and all three delayed-admission invocations passing,
result `test_macos_2026-09-22T19-04-59-161Z_pid95292_6f8282c5.xcresult`.
The first delayed-admission invocation took 7.346 seconds under parallel load,
but its subsequent authentication still met the unchanged wire budget.
The full run is a failure overall: 1,162 passing / four failing functions,
4,758 passing / six failing invocations. Remaining failures were
`PommeSecurityDesktopCleanupTests.coordinatorPinIntegration`
(`guestAgentUnavailable`), `PommePrivatePTYRunnerTests.initialPromptGatesPrivateInput`
(`processTimedOut`), `PommeRecoveryRuntimeSessionTests.launchPrecedesAuthentication`
(`listenerAuthenticationTimedOut`), and
`PommeForegroundExecutionTests.delayedOutputAndCompletion` (`exited=false`).
These are retained observations, not silently retried or counted as passes.

An unchanged unrestricted single-iteration comparison subsequently passed all
1,166 functions in 12.4 seconds, result
`test_macos_2026-09-22T19-05-50-474Z_pid95683_d2fd1189.xcresult`.
Read-only review found no new continuation, descriptor-lifetime, or deadlock
blocker. The pre-existing unbounded serving-task join already depended on
eventual task scheduling; the new barrier moves that wait before issuing a
timed client request without blocking another worker. The change fixes the
captured fixture admission race, not all possible cooperative-pool starvation
or the separate stress failures. Production daemon and transport are unchanged.

The fixture fix and evidence were committed as `db8b69a` before the canonical
signed Release build at 19:06:49Z. Build, strict signature, exact entitlements,
designated-requirement compatibility, archive retention, and atomic install
checks passed. Fresh login-shell resolution selected
`/Users/wes/.local/bin/pomme`, reporting `db8b69a`. Installed SHA-256:
`950a21bf8aa80873a66336848a6924380b29e7ced41350f278e9b9faefaed9b3`.
All 104 CLI contract checks and 21 local build/install checks passed.

Live release verification reused the explicitly scoped internal-drive
`pomme-agent-ownerproof-20260922a`, confirmed stopped with its unchanged
40 GB disk / 4 GB memory, UUID, plan, and agent pin beforehand. Normal start
at 19:07:06Z created helper PID 97254 and connected to the original
`011eea30…95ce42f2` guest agent. Foreground `/bin/echo` returned the expected
output and exit zero. `/bin/sleep 5 --timeout 1` returned host exit 124 with
`terminationRequested=true`; a subsequent connection inspecting exact job
`3509cd79-0f95-4a46-a681-b18f25febb91` reported `exited=true` and signal 15.
Guest `ps -p 688` found no remaining process. Graceful stop at 19:08:04Z
returned `stopMethod=guest-stopped`, and helper PID 97254 exited. Final
inventory confirmed all twelve VMs stopped, with no helpers, on the internal
drive. No VM was deleted or moved; no guest agent, pin, credential, journal,
or security configuration was changed. This is release compatibility and
live execution/cleanup verification, not a live reproduction of the host
test-fixture admission race.

### Private-PTY initial-prompt timeout under parallel test load

After completing the `db8b69a` signed release/live verification and committing
its evidence as `4aa37ad`, the next isolated issue is
`PommePrivatePTYRunnerTests.initialPromptGatesPrivateInput` returning
`processTimedOut` in full parallel comparisons. All twelve internal VMs remain
stopped; these comparisons use the isolated Debug test environment, not a VM.

The unchanged test passed all 30 isolated invocations, result
`test_macos_2026-09-22T19-08-53-082Z_pid97979_3f6760c3.xcresult`.
A complementary 799-function selection (the full suite minus the earlier
368-function selection, with this prompt test added back) also passed all
three prompt invocations; its separate coordinator-pin failure remains
recorded in `test_macos_2026-09-22T19-09-19-955Z_pid98302_d700e775.xcresult`.
Adding the six earlier stress suites reproduced the exact prompt timeout once
across three repetitions, with the other 836 functions passing in 18.2 seconds:
`test_macos_2026-09-22T19-09-43-519Z_pid98537_da1c08fe.xcresult`.
No runner, test deadline, or fixture behavior has been changed; minimization
and phase diagnosis continue before selecting a fix.

Splitting the complementary suites into two halves, each retaining the same
six stress suites and prompt test, passed all 473 and 403 functions across
three repetitions respectively:
`test_macos_2026-09-22T19-10-18-088Z_pid98840_2e728e6f.xcresult` and
`test_macos_2026-09-22T19-10-58-642Z_pid99058_160fad28.xcresult`.
These passes narrow the observed trigger to combined load; they do not prove
that any individual suite causes it. The failing prompt test uses a scripted
actor transport and no real guest or OS PTY, so the test failure is not itself
a reproduction of the historical live private-PTY failure.

Removing OCR still reproduced the prompt timeout in the 828-function selection
(`test_macos_2026-09-22T19-11-25-379Z_pid99269_255dda6b.xcresult`). Retaining
only the daemon suite from the six stress suites also reproduced it in an
811-function selection in 12.8 seconds
(`test_macos_2026-09-22T19-12-21-469Z_pid99554_1b485d13.xcresult`). Both runs
also recorded the separate coordinator-pin failure. Ranked phase hypotheses
are callback/actor scheduling consuming the process budget, delayed resumption
of the 25 ms poll sleep, and incorrect scripted status progression. Temporary
test-local timestamps around validation, start/status, frame callbacks, and
input delivery are the next discriminator; no secret, frame content, payload,
or identity is logged. The production runner's two deadlines begin after the
start response, and no injectable clock/sleeper currently exists.

The first instrumented comparison did not reproduce the prompt failure
(`test_macos_2026-09-22T19-14-01-792Z_pid99987_43b7922e.xcresult`); the
unchanged next comparison did, in 12.8 seconds, with 810 other functions
passing (`test_macos_2026-09-22T19-14-49-770Z_pid384_e33bdde2.xcresult`).
Its redacted phase trace shows validation, start, initial prompt callback,
input delivery, and the first nonterminal status/callback all completed by
0.388 ms. The next event is timeout cleanup at 2,364.793 ms. Cleanup signals
the scripted job, retrieves its second/terminal status, and rethrows
`processTimedOut` at 2,364.818 ms. The intervening runner operation is its
25 ms poll sleep; late resumption crosses the two-second process deadline.
There is no slow initial actor callback or incorrect status ordering in this
failure. The runner correctly enforces elapsed time; the logical prompt-order
test is coupled to wall-clock scheduling of unrelated parallel tests.

The bounded next change introduces a controllable clock for unit verification,
with production continuing to use `ContinuousClock` and its existing timeout
values, checkpoints, cleanup clock, and secret-handling rules. The test keeps
the same scripted status progression and assertions. A deterministic advanced-
clock timeout regression will be run red before clock wiring; no blanket
deadline extension or new test serialization is planned.

The compilable red scaffold accepted but deliberately ignored an injected
clock, forwarding to the unchanged runner. Both selected regressions failed
as intended in `test_macos_2026-09-22T19-18-41-528Z_pid1229_a04367f4.xcresult`:
the logical prompt-order test observed zero injected sleeps, and advancing the
test clock beyond the two-second process budget incorrectly returned success
without the expected SIGTERM cleanup. These are assertion failures after
successful compilation, not compiler failures. Temporary phase tracing has
been removed. Clock wiring is the subsequent candidate change.

After wiring, both existing runner entry points explicitly delegate to
`ContinuousClock`. Internal generic overloads drive only prompt/process
deadline creation, checkpoints, and the bounded 25 ms poll sleep. Validation,
prompt/echo proof, secret delivery/wiping, correlation, cancellation mapping,
and real-clock cleanup are unchanged. A second injected-clock regression
advances past the prompt deadline but not the process deadline and requires
`promptTimedOut`, no stdin delivery, and verified SIGTERM cleanup. The existing
real-clock prompt-timeout and cancellation tests remain unchanged.

The complete private-PTY suite passed all 17 functions / 170 invocations over
ten repetitions, result
`test_macos_2026-09-22T19-21-07-604Z_pid1846_eb9da0a7.xcresult`.
Read-only review found no blocking clock, validation-order, secret-handling,
or cleanup change. This makes logical test time controllable; it does not
claim to fix the historical live private-PTY failure or global pool starvation.

The original 811-function comparison then passed all three prompt invocations;
the overall run still failed only the separately recorded coordinator-pin test
(810 passing functions), result
`test_macos_2026-09-22T19-22-27-153Z_pid2136_c688e66e.xcresult`.
The first prompt invocation took 1.989 seconds of wall time but its logical
clock remained governed by the scripted polling steps.

In the unrestricted three-iteration comparison, all private-PTY functions and
clock regressions passed, including a 5.342-second wall-time first prompt
invocation. Result:
`test_macos_2026-09-22T19-23-01-515Z_pid2406_ea10f3a0.xcresult`.
The run still failed overall (1,164 passing / four failing functions;
4,764 passing / six failing invocations): coordinator-pin availability,
foreground delayed completion, and the daemon admission/one-shot deadlines
remain separate failures. They are not hidden by the clock change.

An unchanged unrestricted single-iteration comparison passed all 1,168
functions in 12.5 seconds, result
`test_macos_2026-09-22T19-23-54-170Z_pid2744_f6d73de0.xcresult`.
The candidate is ready for commit, canonical signed Release build, and live
private-PTY verification. The planned target is the completed internal-drive
macOS 26 fixture `pomme-agent-bootstrap26-20260922a`, verified stopped with
40 GB disk / 4 GB memory and an existing terminal `sipEnable` journal
(`restorationComplete`, normal-boot verification true). A public SIP disable /
enable cycle exercises existing-owner authentication through the production
private-PTY provider path and restores SIP enabled and the stopped run state.
No owner, credential, pin, or journal is manually replaced to prepare the test.

The candidate and evidence were committed as `f7a6139` before the canonical
signed Release build at 19:24:35Z. Build, strict signature, exact entitlements,
designated-requirement compatibility, archive retention, and atomic installation
checks passed. Fresh login-shell resolution selected
`/Users/wes/.local/bin/pomme`, reporting `f7a6139`. Installed SHA-256:
`8b2af021f535af31daa1327a0d04a4aef51b6fbddcfb0c59df82b8468ed08ea7`.
All 104 CLI contract and 21 local build/install checks passed.

Public SIP disable began at 19:25:04Z on the scoped macOS 26 fixture with
`--force --final-state previous --format json --debug`. The unchanged
creation-pinned normal agent authenticated at 19:25:19Z and owner-evidence
collection began at 19:25:20Z. The matching enable operation will restore the
initial security state after a successful disable; no other VM is operated.
Existing-owner verification began at 19:25:37Z and returned its receipt at
19:25:42Z, exercising the real private-PTY password authentication path on the
new host. The workflow then entered authenticated Recovery and confirmed the
Recovery runtime at 19:26:13Z.
Recovery Terminal was verified at 19:27:41Z; marker proof passed on attempt 2
at 19:27:44Z, and the launcher was submitted at 19:27:46Z.
Normal-boot verification began at 19:28:19Z and stopped-state restoration at
19:28:46Z. SIP disable completed successfully with `configuredDisabled=true`
and all verification fields true; public status confirmed stopped/no helper
and the journal reached `restorationComplete` / `sipDisable` / `previous`.
The matching public enable operation began at 19:28:58Z to restore the original
enabled state.
Enable reverified the existing owner from 19:29:27Z to 19:29:31Z, providing a
second successful live private-PTY authentication, then verified its Recovery
runtime at 19:30:02Z.
Terminal was verified at 19:31:30Z; marker proof passed on attempt 1 at
19:31:32Z, the launcher was submitted at 19:31:35Z, and normal-boot
verification began at 19:32:08Z.
Stopped-state restoration began at 19:32:37Z, and SIP enable completed with
`configuredDisabled=false` and every verification field true. Public status
confirmed stopped/no helper, and the journal reached `restorationComplete` /
`sipEnable` / `previous` with normal-boot verification true. Final inventory
confirmed all twelve VMs stopped with no helpers and internal bundle paths.
The target retains its original UUID, startup volume, immutable plan,
`2e0a2f49…47aaeff` agent pin, and 40 GB / 4 GB resource settings. SIP is restored
enabled; no AMFI operation, VM deletion, relocation, manual journal change,
credential replacement, or guest-agent update was performed.

The signed-release live check validates both existing-owner private-PTY
authentications and the completed security/restoration workflows with the
unchanged production clock. It does not reproduce or close the historical
private-PTY/pinned-authentication failure, nor the separate full-suite stress
failures retained above.

### Coordinator-pin fixture readiness under parallel test load

After committing the `f7a6139` live verification as `b8a5e65`, current-tree
inspection confirms only unrelated untracked artifacts remain, the installed
signed CLI still reports `f7a6139`, and all twelve internal VMs are stopped.
The next isolated failure is
`PommeSecurityDesktopCleanupTests.coordinatorPinIntegration(replaceDuring:)`
returning `guestAgentUnavailable` during repeated full-suite runs.

Unchanged comparisons in the isolated Debug environment:

| Selection | Repetitions | Result | Result bundle suffix (2026-09-22) |
|---|---:|---|---|
| Coordinator-pin method alone | 10 | All 30 parameter invocations passed | `19-34-13-396Z_pid6096_56920b28` |
| Entire five-function cleanup suite | 10 | All 490 parameter invocations passed | `19-34-38-407Z_pid6188_136685db` |
| Earlier complementary 799-function selection | 3 | All passed | `19-35-09-713Z_pid6306_07543eb4` |
| Above plus daemon suite, 811 functions | 3 | All passed | `19-35-49-461Z_pid6600_f917d94a` |
| Unrestricted full suite | 3 | Coordinator pin failed; daemon admission/one-shot and Recovery listener deadlines also failed | `19-36-19-052Z_pid6812_9d9ddd90` |

The in-process fixture creates independent coordinators/connections per case.
Its two-second `awaitPin` polling helper discards readiness error distinctions
and throws `guestAgentUnavailable` when the loop deadline passes. The test
then verifies the concrete coordinator's before/after-await pin checks while
replacing a session during describe or status. No real VM or credential is
used by this fixture. The smallest current red selection remains the full
parallel workload; phase timing is needed to minimize further without guessing
which scheduling interaction matters.

Ranked diagnostic hypotheses are late authentication admission, authentication
completed but a late-resumed poll omits a final ready-state check, and an actual
unavailable/replacement transition. Temporary bounded phase/readiness timing
will distinguish them without logging tokens, digests, IDs, payloads, or
frames. No deadline, pin assertion, fixture behavior, or production code has
been changed.

The first instrumented full three-pass run passed all 1,168 functions / 4,770
invocations (`19-39-27-425Z_pid7680_33e1cae7`). The subsequent full ten-pass
run reproduced the coordinator failure in four parameter invocations, alongside
five other failing functions: daemon admission/one-shot, foreground completion,
Recovery listener authentication, and Recovery coordinator retry. Overall it
finished with 1,162 passing / six failing functions and 15,889 passing / eleven
failing invocations (`19-43-54-186Z_pid8565_30b596e2`).

All four coordinator traces show the same initial-readiness boundary: the first
probe reports connecting, the requested 1 ms sleep resumes after 6.43–9.28
seconds, and the loop exits without another readiness probe. Authentication
exchange itself starts late (6.23–9.13 seconds), but has completed before the
poll resumes; both diagnostic-only final reads report an authenticated session.
Thus this evidence shows delayed admission AND a missed final ready-state
check, not authentication completing within the original two-second interval.
None of these failures reached the replacement/adapter assertions.

The next regression will exercise that delayed-poll ordering against the real
coordinator with controlled test time, including a still-unavailable negative
case. The proposed test-helper correction checks readiness after resumption
before declaring its polling budget exhausted; it does not extend production
authentication deadlines or relax concrete session-pin validation. No live VM
was operated for these isolated tests, and no product fix is claimed yet.

The minimized regression uses the existing concrete coordinator and its real
authentication/pin capture, with injected `now`/`sleep` closures confined to the
test helper. Its first poll is unavailable; the controlled sleep connects the
test peer, waits for actual authenticated publication, then advances test time
three seconds before returning. The old loop reproduced `guestAgentUnavailable`
despite the ready session. A separate actual child-task cancellation case also
failed because the old loop returned unavailable after the cancelled sleep
resumed. The never-ready negative case passed. The focused red run finished
with two failing / five passing functions and two failing / fifty passing
invocations (`19-48-46-166Z_pid10138_f72192a7`). Temporary phase tracing was
removed before this regression run; no production file changed.

The candidate checks task cancellation, then captures readiness, then applies
the unchanged two-second polling guard before another one-millisecond sleep.
The entire cleanup suite passed all seven functions / 520 invocations over
ten repetitions (`19-50-02-609Z_pid10379_36d721dc`). Read-only review found no
weakened replacement assertion or production change. The positive regression
also sends describe/status through the captured concrete pin and verifies its
cleanup receipt; the unavailable/cancelled cases each stop after one sleep.
This correction tests readiness and pin identity, not an authentication latency
SLA.

The original full ten-pass workload passed all 30 coordinator replacement
invocations, ten delayed-final-poll regressions, and twenty unavailable/cancelled
invocations (`19-50-29-008Z_pid10489_9ff66000`). The full run still failed five
other functions: daemon admission/one-shot (`deadline`), foreground completion,
Recovery listener authentication, and MDM shared-file lease (`leaseBusy`).
Overall 1,165 functions / 15,925 invocations passed and five functions / five
invocations failed. Those independent stress observations remain open; this
fixture correction does not claim full-suite reliability or a live guest
authentication fix.

The subsequent unrestricted single run passed all 1,170 functions / 1,593
invocations (`19-52-01-075Z_pid11520_d43b6cc7`). No temporary coordinator trace
remains, `git diff --check` is clean, and review found no blocker. The code and
evidence are being committed before the canonical signed Release build; live
verification will exercise normal authentication, guest execution, restart,
reauthentication, and restoration on the existing internal macOS 27 fixture.

Candidate `f3dfff6` was committed before the canonical signed Release build at
19:52:51Z. Build, signature, exact entitlements, designated-requirement
compatibility, append-only archive, and atomic installation checks passed.
Fresh login-shell resolution is `/Users/wes/.local/bin/pomme`; its version is
`f3dfff6`, SHA-256
`657354e68167f8537631f8ca84f00f81e93559bce5db89981f4bf98b4df1ed17`.
All 104 CLI contract and 21 installer regression checks passed.

Live preflight confirmed `pomme-agent-ownerproof-20260922a` stopped with no
helper, internal bundle storage, and unchanged 40 GB / 4 GB resources. The
public normal start began at 19:53:12Z using the newly installed signed CLI.
Start succeeded with helper PID 13413 and the original authenticated normal
agent pin. Guest `/bin/echo coordinator-pin-before-restart` passed at 19:54:05Z,
with exact stdout, exit zero, and complete output. Public normal restart began
at 19:54:08Z, gracefully stopped the guest, and returned helper PID 13638 with
the same authenticated pin. Guest `/bin/echo coordinator-pin-after-restart`
passed at 19:55:09Z with exact stdout, exit zero, and complete output; independent
status confirmed running/normal, connected agent, and protocol 1.

Graceful stop began at 19:55:09Z and completed with `guest-stopped`. Final public
inventory confirmed all twelve VMs stopped, no helpers, and internal bundle
paths. The target's UUID, startup volume, immutable plan, original agent digest,
40 GB disk, and 4 GB memory are unchanged. No VM was deleted or moved; no guest
agent update, security change, credential replacement, or journal edit occurred.
This live cycle qualifies host compatibility, not reproduction of the unit
fixture's scheduling race or closure of the separate historical VM failures.

### Daemon socket-admission deadline under parallel test load

After the coordinator polling fix and signed/live verification were committed,
the next isolated failure is `PommeAgentDaemonTests.socketpairAdmission()`
throwing `DaemonPeerReader.Failure.deadline` under the full ten-pass workload
(`19-50-29-008Z_pid10489_9ff66000`). The working tree began clean except for
unrelated untracked artifacts; installed signed Release is `f3dfff6`.

Unchanged narrowing comparisons all passed:

| Selection | Repetitions | Actual invocations | Result bundle suffix (2026-09-22) |
|---|---:|---:|---|
| Socket-admission method | 100 | 100 | `19-56-23-729Z_pid15308_01f02eae` |
| Entire daemon suite (12 functions) | 100 | 1,200 | `19-56-45-777Z_pid15410_eb208b2d` |
| Existing socket/OCR/PTY/reconnect selection (39 functions) | 10 | 420 | `19-57-02-767Z_pid15545_9cf8ee50` |

The reader already runs blocking socket work on a dedicated thread, but its
five-second deadline is created before that thread starts and independently
of the daemon's serving task admission. Ranked hypotheses are late serving
task admission, late reader-thread admission, and a stall after both start.
A bounded failure-only timing trace will distinguish those boundaries while
preserving framing assertions, both five-second guards, natural server
completion proof, and descriptor cleanup. No production fix or timeout change
has been made, and no VM is needed for this isolated diagnostic.

The first instrumented full ten-pass run did not reproduce the daemon failure;
all daemon invocations passed. It finished with 1,168 passing / two failing
functions (15,928 passing / two failing invocations), with only the independent
foreground-completion and Recovery-listener failures remaining in that run
(`19-59-13-487Z_pid15921_2fefd9b5`). The same workload is being repeated without
changing instrumentation or behavior; a passing diagnostic run does not identify
the earlier timeout's cause.

The second identical full ten-pass run reproduced socket admission and one-shot
daemon deadlines alongside the two previously observed failures: 1,166 passing /
four failing functions and 15,926 passing / four failing invocations
(`20-01-21-261Z_pid16993_2fdd6245`). Socket-admission timing isolated the boundary:
the reader thread entered at 0.139 ms, polled for the original five-second budget,
and timed out at 5,001 ms with zero bytes. The daemon serving task did not enter
until 14,451.816 ms and returned at 14,452.156 ms. The test resumed at 14,464 ms,
then shut down and joined before closing descriptors. This is late serving-task
admission, not delayed native reader startup or observed slow daemon processing.

The next minimized regression will deliberately delay serving admission beyond
a shorter test-specific reader budget while using the real daemon and actual
authentication/health frames. The proposed fixture correction awaits admission
after writing/half-closing requests but before starting the response-read clock.
It retains the default five-second read/finish guards, natural-completion proof,
and shutdown/join/close order. Production behavior and the separate one-shot
test are not being changed without evidence for their own boundary.

The minimized delayed-admission test reproduced `.deadline` with a 1.2-second
pre-serving delay and a one-second response-read budget, while all twelve
existing daemon tests passed (`20-05-39-771Z_pid19190_53dab79e`). It shares the
same real socketpair/authentication/health fixture as the original test, without
an admission gate yet. Temporary diagnostics were removed before the red run.

The candidate will keep the five-second response and natural-completion guards,
but separate task setup from those measured operations. Admission gets a
distinct 30-second setup watchdog plus cancellation handling; setup failure
must shut down sockets, cancel and join the serving task, and only then allow
descriptor closure. This is a bounded fixture-setup policy, not a longer guest
response deadline or a change to production authentication.

The initial gated fixture passed all fifteen daemon functions / 150 invocations
over ten repetitions (`20-08-00-538Z_pid19608_b38a19a5`), including the delayed
admission regression, explicit setup timeout, and caller cancellation. Both
failure tests verify that the cooperative setup hook has returned before the
fixture throws. The setup watchdog is cancelled and joined on either result;
only the admission gate is touched by that watchdog. The reader and natural
completion watchdog remain unchanged, as does the Recovery one-shot test.

Added admission-before-wait and sticky timeout/cancellation cases, and aligned
the caller-cancellation test's hook-entry guard with the 30-second setup bound.
The final focused run passed all seventeen functions / 180 invocations over
ten repetitions (`20-09-21-462Z_pid20029_987d7709`). Review found no blocker:
the gate has a single terminal winner, resumes outside its mutex, and every
setup failure joins the serving task before descriptor closure. The known
limitation is cooperative teardown: a deliberately non-cooperative injected
hook could still prevent its serving task from joining; all actual hooks are
cancellable sleeps. No temporary trace remains.

The original full ten-pass workload passed socket admission, delayed admission,
setup timeout, and caller cancellation in all ten repetitions each, together
with the helper-order regressions (`20-10-13-072Z_pid20205_85c47d29`). The two
remaining failing functions were the unchanged Recovery one-shot operation
(`deadline`) and Recovery listener authentication (`listenerAuthenticationTimedOut`).
Overall 1,173 functions / 15,988 invocations passed, and two functions / two
invocations failed. This qualifies the observed socket-admission boundary only;
the other stress failures and historical live failures are not closed.

The unrestricted single run passed all 1,175 functions / 1,599 invocations
(`20-12-13-143Z_pid21290_60f0f4e0`). Final review and `git diff --check` passed,
temporary diagnostics are absent, and only the assigned test file plus this
evidence document changed. The fix is being committed before the canonical
signed Release build and a scoped internal-VM live compatibility check.

Candidate `ca45976` was committed before the canonical signed Release build at
20:12:50Z. Build/signature/entitlement/designated-requirement/archive/atomic
installation checks passed. Fresh login-shell resolution is
`/Users/wes/.local/bin/pomme`, version `ca45976`, SHA-256
`6f1facffae2ca8e47ed47340c553843c69134b137bdf9c204011577d16ba7cc3`.
All 104 CLI contract and 21 local installer checks passed.

Live preflight confirmed internal `pomme-agent-ownerproof-20260922a` stopped
with no helper and unchanged 40 GB / 4 GB resources. Public normal start began
at 20:13:13Z and succeeded with helper PID 23182 and the original normal agent
pin. `agent status --debug` passed at 20:14:00Z without leaving normal macOS,
reporting connected/protocol 1 and the same agent digest. Authenticated guest
`/bin/echo daemon-admission-live` passed at 20:14:01Z with exact stdout, exit
zero, and complete output. Graceful stop began at 20:14:20Z and completed with
`guest-stopped`. Final public inventory confirmed all twelve VMs stopped with
no helpers and internal bundle paths. Target UUID, startup volume, immutable
plan, original agent pin, disk size, and memory remain unchanged. No VM was
deleted or moved; no guest agent, credential, security setting, or journal was
changed. The live result verifies release compatibility; the scheduling defect
is proven by the isolated red/green fixture and full-workload comparison, not
by a claim that a unit-only timing seam executes in the live CLI.

### Recovery one-shot daemon deadline under parallel test load

After committing the socket-admission release/live evidence as `dc083f3`, the
next isolated failure is `PommeAgentDaemonTests.oneShotOperation()` throwing
`DaemonPeerReader.Failure.deadline` in the full ten-pass workload
(`20-10-13-072Z_pid20205_85c47d29`). Installed signed Release remains `ca45976`;
the working tree began clean except for unrelated untracked artifacts.

The unchanged one-shot method passed 100 isolated repetitions
(`20-15-41-581Z_pid23827_77f3f9c1`). It also passed the preceding focused daemon
comparisons, including the final seventeen-function ten-pass run. Those passing
cases do not explain its full-workload failure.

Ranked hypotheses are late serving-task admission, late native reader-thread
entry, and a stall during authentication/one-shot processing. A bounded,
failure-only timing trace will distinguish admission from post-entry behavior.
Unlike persistent socket admission, this test deliberately does not half-close
the client; it requires the daemon to return after the allowed operation while
a replay request is buffered. Binding, sixty-second one-shot expiry, allowlist,
two-response correlation, and natural-completion proof must remain unchanged.
No deadline or production behavior has been altered, and no VM is being operated
for this isolated diagnostic.

The instrumented full ten-pass run reproduced the one-shot deadline alongside
foreground completion, Recovery listener authentication, and Recovery retry:
1,171 passing / four failing functions and 15,986 passing / four failing
invocations (`20-17-44-497Z_pid24221_fc00ac6c`). The reader thread entered at
0.511 ms and timed out at 5,001.55 ms with zero bytes. The one-shot serving task
did not enter until 17,941.556 ms, then returned at 17,941.951 ms; the owning test
resumed at 17,993 ms and performed shutdown/join before descriptor closure.
This identifies delayed serving-task admission rather than delayed reader
startup or observed post-entry processing delay. The configured sixty-second
one-shot expiry remains unchanged; the reader failed far earlier than that bound.

The next red regression deliberately delays this same one-shot fixture's serving
task by 1.2 seconds against a one-second reader budget. The intended fix reuses
the existing bounded/cancellable admission gate before starting response timing;
the no-half-close/replay and natural-completion requirements remain intact.

The minimized regression failed with `.deadline` while all seventeen existing
daemon functions passed (`20-21-30-362Z_pid25533_4f122ea2`). Original and delayed
cases share the same real one-shot fixture, which still uses the old ungated
ordering in this red run. All temporary diagnostics were removed before the run.
The candidate now reuses `DaemonServingAdmission` and the existing 30-second
setup policy, leaving the response-read and natural-completion guards at five
seconds. One-shot setup timeout/cancellation will also verify task joining before
descriptor closure; no protocol or production behavior is being changed.

The candidate passed all twenty daemon functions / 210 invocations over ten
repetitions (`20-22-58-614Z_pid25818_c67bc7b7`). Delayed one-shot admission now
passes, and dedicated one-shot timeout/caller-cancellation tests confirm the
cooperative setup hook has exited before failure returns. Review found no
blocker: client write-side openness, binding/expiry/allowlist, buffered replay,
response correlation, and natural completion remain unchanged. The shared gate
and persistent socket fixture were not modified.

The unrestricted ten-pass comparison (`20-23-46-257Z_pid26026_15db5953`)
passed all ten invocations of each original/delayed one-shot and setup
timeout/cancellation function. Overall, 1,175 functions passed and three
failed (16,017 passed / three failed invocations): Recovery listener
authentication, coordinator retry authentication, and terminal output replay
(99,328 rather than 100,000 bytes). These remain separate open observations;
this test-only change does not explain or fix them. The subsequent unrestricted
single run (`20-25-26-208Z_pid26993_84f24d13`) passed all 1,178 functions /
1,602 invocations, with no failures or skips. The candidate is ready for the
required pre-build commit, signed Release install, and scoped live Recovery
compatibility check; no live result is claimed yet.

Candidate `fc4e4bf` was committed before the canonical signed Release build
at 20:29:13Z. Build, signature, exact entitlements, designated-requirement
compatibility, artifact archival, and atomic installation passed. A fresh
login shell resolves `/Users/wes/.local/bin/pomme`; it reports `fc4e4bf` and
SHA-256 `e4b394a159af5a5af88a8cf73c047ce9b1487bf723d658c43359ee57d8f7421f`.
All 104 CLI contract checks and 21 installer regression checks passed.

Live compatibility verification began at 20:29:30Z with read-only
`sip status pomme-agent-bootstrap26-20260922a --final-state previous
--format json --debug`. Preflight confirmed the same internal-drive 40 GB /
4 GB macOS 26.6.2 fixture was stopped, with unchanged UUID, startup volume,
creation plan, agent pin, and a completed prior security journal. No security
mutation, agent update, credential change, or VM deletion was requested.
This exercises the signed CLI's Recovery compatibility, not the test-only
admission hook.

The live command completed successfully, observed by 20:31:50Z. Recovery
reached Terminal, passed marker proof on attempt two, and authenticated the
request-bound one-shot session on port 505053. SIP status returned
`sipEnabled=true`, `sipDisabled=false`, and `verified=true`; session lifecycle
was finalized with the credential consumed, all cleanup flags true, and
`finalStateVerified=true`. Independent status confirmed stopped/no helper,
unchanged VM/startup/plan/pin/resources, and the unchanged completed prior
security journal. Inventory confirmed all twelve VMs stopped on the internal
drive. No VM was deleted, no persistent credential or pin was changed, and
private screenshots remain outside the repository. The one-shot fixture race
is fixed; the remaining full-stress failures and historical live issues are
not closed by this result.

### Recovery listener authentication under parallel test load

After committing the one-shot release/live evidence as `b8c6fea`, the next
isolated investigation is `PommeRecoveryRuntimeSessionTests.launchPrecedesAuthentication()`
throwing `listenerAuthenticationTimedOut` in repeated full workloads, most
recently `20-23-46-257Z_pid26026_15db5953`. Installed signed Release is
`fc4e4bf`; no production change or new live operation has been made for this
investigation. The unchanged test passed 100 isolated repetitions
(`20-32-56-112Z_pid29979_9875d260`), so removing parallel workload does not
retain the failure. The original full ten-pass run remains the red-capable
comparison while the timing trigger is minimized.

Ranked hypotheses are late authentication-task admission, timely authentication
missed by a delayed polling task, and connection rejection/teardown before
authentication. Bounded failure-only timing probes will distinguish these;
the production authentication deadline and security checks must remain intact.

The instrumented full ten-pass run (`20-35-30-761Z_pid30483_b1cae687`)
failed only this function: 1,177 functions / 16,019 invocations passed, one
function / invocation failed. Launch/connect returned at 0.257 ms, but the
authentication task's binding/secret providers first ran at 13,299.266 ms;
the fake exchange ran at 13,299.420–13,299.540 ms. The final helper probe at
13,510.009 ms observed authentication ready, followed immediately by timeout
teardown. Authentication itself was therefore late relative to the fixture's
five-second wall-clock budget, not proven ready before the deadline. The
production timeout was correct. The ordering fixture needs controlled logical
time, with a separate bounded scheduler wait and a regression retaining strict
rejection of authentication observed after the logical deadline.

The minimized regression (`20-39-44-953Z_pid32003_57f410e4`) delayed the
concrete fixture's authentication exchange by 120 ms against a 50 ms
wall-clock budget, retaining acceptable-evidence and exact
`start → launch → authenticate` assertions. It failed with the same
`listenerAuthenticationTimedOut`; the other eight functions passed. This
demonstrates the ordering fixture's unwanted dependence on real scheduling,
not a defect in the production deadline. Temporary trace was removed before
the candidate seam is applied.

The candidate injects the root's existing clock and sleeper, preserving default
`Date()` and cancellable 25 ms sleep and the exact deadline/helper/authentication/
failed-status/cancellation ordering. The ordering fixture holds logical time
steady while a cancellation-aware, monotonic 30-second setup observer waits
for the concrete coordinator's authenticated session. Its fake exchange waits
for the root polling hook, so the seam is deterministically exercised. No
production timeout is increased and no post-deadline readiness check is added.

All eleven focused functions / 150 invocations passed over ten repetitions
(`20-42-00-219Z_pid33199_40270b8b`). Coverage includes delayed ordering, an
authenticated session rejected after the injected deadline, bounded fixture
waiting, and actual task cancellation. Review found production defaults and
security ordering intact, but identified that fallback test teardown could
mask the strict-negative cleanup assertions. Those assertions were moved
before any fixture teardown; the final candidate's full comparison follows.
No temporary diagnostic prefix remains.

The final full ten-pass comparison (`20-43-41-704Z_pid35061_ed28ac57`)
passed all ten invocations of the original listener ordering, delayed ordering,
and strict-deadline rejection functions, plus all twenty parameterized
fixture-wait timeout/cancellation invocations. Overall 1,180 functions /
16,059 invocations passed and one function / invocation failed:
`PommeForegroundExecutionTests.delayedOutputAndCompletion()` returned
`exited=false`. That independent stress observation remains open; the listener
fixture correction does not claim to fix it. Final review confirmed the
root teardown assertions now precede fixture cleanup and found no remaining
blocker.

The unrestricted single run (`20-45-44-340Z_pid36218_12a7efc8`) passed all
1,181 functions / 1,606 invocations, with no failures or skips. The candidate
is being committed before the canonical signed Release build and scoped
read-only Recovery live check. This fixes the ordering fixture's clock
coupling; it does not identify the cause of historical live authentication
failures or relax the production authentication deadline.

### Live TUI status projection mismatch

The same signed `052f05d` PTY smoke check exposed a separate reproducible
display mismatch. While `pomme-agent-ownerproof-20260922a` was running normally,
the dashboard counted `running=0 stopped=12` and displayed `[STOP]` for that
row, even though its adjacent VM-state column said `running` and agent column
said connected. The selected agent detail also rendered `protocol=- digest=-`.
Independent public JSON status at that point reported `vmState=running`,
`helperRunning=true`, agent `connection=connected`, numeric protocol version 1,
and the exact creation-pinned executable digest. Returning from the cancelled
create form reproduced the same dashboard mismatch. No VM lifecycle failure
occurred. This is an open TUI projection/formatting observation, not a fix or
evidence that the underlying VM stopped; the fixture was subsequently stopped
explicitly as recorded above.

The unchanged signed `052f05d` reproduced the mismatch again after an explicit
normal start at 18:01:50Z on the same internal 40 GB / 4 GB fixture. Public
`list --format json` confirmed that the live row has no `running` Boolean;
it reports `vmState=running`, `helperRunning=true`, numeric agent protocol 1,
and `executableDigest`. The dashboard and VM menu both displayed `[STOP]`
beside `vmState=running`, and the selected agent detail again omitted protocol
and digest. Returning to the dashboard preserved the mismatch, ruling out a
single stale initial frame. The TUI exited normally and graceful stop at
18:02:41Z restored the fixture; all twelve internal VMs were then stopped.

The projection boundary explains all three mismatches: `TUIVMEntry` reads the
retired `running` field rather than `vmState`, and `TUIGuestAgent` expects a
string protocol plus `digest` rather than a numeric protocol plus
`executableDigest`. The existing renderer/snapshot fixtures repeated those
retired fields. The false running value also bypasses the TUI's boot-mode
change confirmation before a running session would be stopped.

New canonical-payload regressions failed before the correction: four test
functions / five invocations failed, covering badges/counts, protocol/digest,
and the actual confirmation prompt for running and paused sessions. Red bundle:
`test_macos_2026-09-22T18-06-33-678Z_pid77579_359de227.xcresult`.
The candidate derives running, paused, stopped, and unknown display categories
from `vmState`, retains the raw state in the VM-state column, and no longer
counts paused/unknown VMs as stopped. It reads the numeric protocol and
`executableDigest` from the closed agent object. Both running and paused
sessions require confirmation when changing boot mode; same-mode requests and
existing unknown-state behavior are unchanged. The cancellation tests invoke
the real prompt but no lifecycle operation. No public status producer, VM
lifecycle, guest protocol, credential, or journal behavior is changed.

The final focused renderer, create-PTY, and snapshot-PTY suites passed all
13 test functions / 16 invocations, with no failures or skips. Coverage checks
actual dashboard row badges and counts, VM summaries, unknown/null values,
the production `GuestAgentStatusV1` encode/decode projection, and cancellation
of the real boot-transition guard for running and paused sessions. Green bundle:
`test_macos_2026-09-22T18-09-36-761Z_pid78404_f26d3363.xcresult`.
These results qualify the candidate for signed build and live comparison;
they do not close the unrelated full-suite concurrency hang.

Candidate `3fb1ccb` was committed before its canonical signed Release build
at 18:10:45Z. Build, signature, exact entitlements, designated-requirement
compatibility, archive, and atomic install checks passed. The installed CLI
resolves from `/Users/wes/.local/bin/pomme`, reports `3fb1ccb`, and has SHA-256
`2b10ef689f685ba4161d3609a774d3a1a4bc7a949ea9dd1943e9bedc4f8c7707`.
All 104 CLI contract and 21 installer regression checks passed.

Live verification used the same internal-drive 40 GB / 4 GB
`pomme-agent-ownerproof-20260922a`, explicitly confirmed stopped beforehand.
Normal start at 18:11:07Z succeeded with helper PID 80159 and the unchanged
creation-pinned agent. A real host PTY running the newly installed CLI showed
`[RUN]`, `running=1 paused=0 stopped=11 unknown=0`, protocol 1, and the full
creation-pinned executable digest. Independent JSON status agreed. Selecting
Boot Recovery displayed the stop/restart warning; cancelling returned to the
normal-running menu with the same helper PID, connected agent, and boot mode.

Explicit pause at 18:12:12Z succeeded. Dashboard refresh showed `[PAUSE]` and
`running=0 paused=1 stopped=11 unknown=0`, matching JSON `vmState=paused` and
`helperRunning=true`. Agent-disconnected/null details were rendered as absent,
not inferred from the stored creation pin. Selecting Boot Recovery again
displayed the warning, now naming the paused state. Cancellation preserved
paused/normal state and PID 80159. No Recovery boot was performed.

Explicit resume at 18:13:00Z succeeded; dashboard refresh restored `[RUN]`,
the running count, protocol 1, and the same authenticated agent digest.
Graceful stop at 18:13:12Z succeeded with `stopMethod=guest-stopped`. Final
refresh showed `[STOP]` and `running=0 paused=0 stopped=12 unknown=0`, matching
JSON `vmState=stopped`, `helperRunning=false`, and null live agent details.
The PTY exited zero, and inventory confirmed all twelve internal VMs stopped
with no helpers. VM UUID, creation plan, agent pin, disk size, and memory were
unchanged. The live TUI projection mismatch and active-session confirmation
regression are fixed; this result does not resolve the independent historical
creation/security/lifecycle observations or the full-suite concurrency hang.
