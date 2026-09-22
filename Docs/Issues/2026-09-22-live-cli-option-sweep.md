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
