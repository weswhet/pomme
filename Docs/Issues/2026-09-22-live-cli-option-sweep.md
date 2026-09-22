# Live Pomme CLI option sweep — 2026-09-22

Status: complete — live macOS 27 then macOS 26 sweep finished 2026-09-22

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

For compatibility, `pomme-agent-recovery26-20260922a` was created on internal
storage from macOS `26.6.2 (25G83)` with a 40 GB disk and 4 GB RAM, using
signed build `ef37f16`. Restore began at 06:32:22Z; the existing five-input
Recovery route reached Terminal at 06:38:00Z and passed marker proof on attempt
1. Creation then completed successfully and restored the requested stopped
state. The sweep's macOS 26 bootstrap failure did not reproduce in this run.
