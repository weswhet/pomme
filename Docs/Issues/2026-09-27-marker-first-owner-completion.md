# Marker-first owner completion experiment

## Requested order

The user requested this macOS 26 sequence:

1. Create and verify the owner after the guest agent becomes available.
2. Configure automatic login with native `sysadminctl` and verify it.
3. Create the system Setup Assistant completion markers, including `.AppleSetupDone`.
4. Reboot normally and wait for the owner's console session.
5. Write the per-user Buddy preferences, then verify the desktop.

This is a scoped lab change. The planned target is
`pomme-agent-autologin-markerfirst26-20260927a`, cloned from the protected
macOS 26 template with its 40 GB disk and 4 GB RAM. Existing failed native and
legacy comparison clones are retained. The new sequence does not modify SIP or
AMFI, and a failed operation receives no automatic retry or restoration.

## Initial attempt

The canonical signed build/install and fresh shell path/version gate passed.
The installed runner reports `0.1.0 (b1cdcc4-dirty)` and has digest
`bb7768a2680d10cd6c93f1460d93a4729fa1afbd1fab6931aa6a0dfc5f35cdfd`.
The two earlier comparison clones were still running with connected agents;
both protected templates remained unprovisioned. About 322 GiB was available
on the internal drive.

At 15:32:07 UTC, creation cloned the new bundle and reached Recovery
`runtimeStarting`, but returned exit 1 with
`installRecoveryAgent / recovery_session.cleanup_failed`. It did not reach
`runtimeStarted`, owner creation, or automatic-login setup. The bundle and
provisioning journal were retained. No further VM actions followed this failure.

The two already-running macOS guests may account for the runtime start failure;
the reported cleanup error does not prove that cause. The user was asked whether
the earlier two clones may be stopped while preserving their disks and journals,
because their prior instruction was to leave failed VMs untouched. Implementation
and offline verification can proceed while that decision is pending.

Creation log: `/tmp/pomme-markerfirst-create-20260927.log`.

## Authorization and resumed creation

The user first authorized stopping the old clones, then explicitly requested
removing old VMs. The native comparison clone stopped with `guest-stopped` and
was deleted with `already-stopped`. The legacy clone was deleted with
`guest-stopped`. Both public deletion commands returned exit 0. Protected
templates and the new marker-first fixture were retained.

The marker-first implementation's signed build and path/version checks passed;
installed digest:
`57ed2542b5af4031016b23eb6044d13764e6f5497d44cd01d5c8eb42bb9f8911`.
Native focused owner/lab tests passed 252 invocations with zero failures, and all
114 CLI integration checks passed against `/Users/wes/.local/bin/pomme`.

At 15:36:34 UTC, public `create --resume` continued the retained plan. Recovery
reached `runtimeStarted` at 15:36:35 UTC after the older guests were removed.
This supports the running-VM capacity hypothesis, although the original native
error was masked by the cleanup error. Resume log:
`/tmp/pomme-markerfirst-create-resume-20260927.log`.

Creation resumed successfully and restored the clone to stopped state. Its UUID
is `e00e9a9d-b48d-44b7-a7fd-170a8e7230b6`, plan digest
`093569d71c529bdda813cfe49007f1e551e086f252db8cbea2f24f84271af075`, and
creation-pinned agent digest is the baseline `bb7768a2…f35cdfd` above.
Status confirmed the original 4 GB memory, 40 GB disk, template, version/build,
and stopped/no-helper state before the lab run.

The scoped command is:

```sh
/Users/wes/.local/bin/pomme lab-autologin pomme-agent-autologin-markerfirst26-20260927a --strategy markerfirst
```

This command deliberately returns after reboot/authentication and owner-console
proof, leaving the full desktop receipt pending. The separately signed
CFPreferences probe from the previous experiment will perform and independently
verify the two writes. Only after those succeed does the read-only
`--verify-desktop` stage check preferences and the existing full desktop proof.

## Live result

The marker-first command returned exit 0:

- Owner creation and verification passed.
- At 15:41:09 UTC, native autologin, loginwindow preference, and kcpassword
  metadata checks passed. Neither per-user completion preference was written.
- At 15:41:19 UTC, `finishSetupAssistant` recorded its verified receipt, including
  `.AppleSetupDone`, then initiated the planned normal restart.
- At 15:41:37 UTC, the rebooted normal agent authenticated.
- At 15:41:38 UTC, the exact `pomme` console identity passed. The lab recorded
  `owner-console-ready`, leaving full desktop verification pending.

The same signed CFPreferences probe used in the preceding experiment was
transferred successfully to
`/private/tmp/pomme-cfprefs-markerfirst-20260927`; transfer SHA-256 matched
`e3a094f8fa5d0e6a996ca529d1960056419d04238db0cb2b6b6f7fe18b6a36dd`.

The following guest command exited 1:

```sh
/Users/wes/.local/bin/pomme exec pomme-agent-autologin-markerfirst26-20260927a -- /bin/chmod 755 /private/tmp/pomme-cfprefs-markerfirst-20260927
```

Its error was `Timed out waiting for agent operation Pomme agent exchange.`
Whether chmod executed before the response timeout is unknown. No further guest
commands, CFPreferences writes, desktop verification, reboot, or cleanup followed
this failure. Only existing host-side logs were read afterward. The helper log
ends with successful console-proof exchanges at 15:41:38 UTC and does not expose
the cause of the later chmod timeout.

The requested order therefore reached verified owner login after reboot, but
the post-reboot Buddy writes remain untested because guest command transport
failed before the probe could run. This is not evidence of a CFPreferences
failure after reboot or a completed fix. The sole remaining VM and probe were
retained at this point; protected templates remain unchanged.

Logs:

- `/tmp/pomme-markerfirst-owner-20260927.log`
- `/tmp/pomme-markerfirst-build-20260927.log`
- `/tmp/pomme-markerfirst-tests-20260927.log`
- `/tmp/pomme-markerfirst-integration-20260927.log`

## User-requested screenshot inspection

The user subsequently authorized checking runtime status and taking a screenshot.
After the canonical signed build/path/version gate, status reported running in
normal mode with a connected agent. A host-side `pomme ui screenshot` succeeded.
The 1280×800 image showed a black screen, white Apple logo, and a partially filled
progress bar; no desktop was visible. Thus the earlier owner-console identity
proof did not establish a visible desktop. No input, restart, or guest process
command was issued for this inspection.

Private screenshot retained at
`/tmp/pomme-desktop-inspection-20260927.OMf4e5/desktop.png` (not committed).

The user's next requested screenshot showed progress beyond the Apple-logo
screen: Setup Assistant displayed **Update Mac Automatically**, with
**Only Download Automatically** and **Continue** buttons. No Finder/Dock desktop
was visible. The screenshot was captured without starting, restarting, or
sending input to the VM. The second capture is retained privately as
`/tmp/pomme-desktop-inspection-20260927.OMf4e5/desktop-second.png`; `desktop.png`
was updated to this image for the user-requested Tailscale HTTP server.

## User-requested manual defaults writes

The user then explicitly authorized writing both preferences through manual
agent execs as the owner, rebooting, and observing the result. The canonical
signed build/install/path/version gate passed again. Status showed normal boot,
running, and a connected agent before the writes.

Both commands exited 0:

```sh
/usr/bin/sudo -n -H -u pomme /usr/bin/defaults write com.apple.SetupAssistant LastSeenBuddyBuildVersion -string 25G83
/usr/bin/sudo -n -H -u pomme /usr/bin/defaults write com.apple.loginwindow MiniBuddyLaunch -bool false
```

Separate owner-context defaults reads also exited 0 and returned `25G83` and
`0`, respectively. This establishes that these writes succeeded in the later
post-reboot state where Setup Assistant was visibly running. It does not isolate
which aspect of session initialization made the earlier writes fail.

The explicit public restart was then requested. Its result is retained in
`/tmp/pomme-buddy-manual-restart-20260927.log`.

The restart exited 0 with `stopMethod=guest-stopped`, preserved normal mode, and
authenticated the pinned agent. Repeated host screenshots over several minutes
returned the same 23,685-byte Apple-logo/progress image. A subsequent successful
guest `ps -axo uid=,comm=` showed owner UID 501 running loginwindow, Setup Assistant,
Finder, and Dock. A separate `/dev/console` stat returned `pomme:501`. Thus the
guest was in its user session despite the boot image returned by host capture.

Both post-reboot preference reads succeeded again: build `25G83` and
`MiniBuddyLaunch=0`. These settings persisted but did not prevent Setup Assistant
from launching. Process presence alone does not establish which page, if any,
was visible.

Read-only source inspection found that the host capture backend encodes a new
PNG for each request but can render a retained framebuffer IOSurface without a
new full-frame publication. This is a possible explanation for the display
discrepancy, not a proven cause. A guest-side capture was attempted in the owner's
launchd context:

```sh
/bin/launchctl asuser 501 /usr/bin/sudo -n -H -u pomme /usr/sbin/screencapture -x /private/tmp/pomme-buddy-manual-result-20260927.png
```

It exited 1 with `could not create image from display`. No further guest commands
followed that failure. The VM was left running. Its visible UI after this reboot
remains unconfirmed; neither the retained boot image nor process presence proves
that all Setup Assistant pages were skipped.

Process output was retained privately at
`/tmp/pomme-buddy-manual-processes-20260927.log`. Captures are
`desktop-after-buddy.png` and `desktop-after-buddy-2.png` through
`desktop-after-buddy-6.png` in the previously documented private screenshot
directory. The served `desktop.png` contains the fourth such capture and should
not be treated as proof of current guest boot progress.


## Integration into the normal workflow

The user requested incorporating these findings into normal owner preparation.
The production change keeps the native `sysadminctl` setter and its readbacks,
then verifies the system completion markers and performs a planned normal reboot.
After authentication and exact owner-console proof, it writes and reads back the
two typed preferences as the owner. It retains the existing verified Setup
Assistant process closure and full stable desktop check. Only that final proof
can advance the journal to `autologinVerified`.

The former automatic preference-error reboot/retry is removed from the normal
path. A fresh-owner preparation failure retains the VM run state and journal for
inspection. An explicit rerun revalidates retained owner and autologin evidence;
it does not recreate the owner or silently replace its credential.

The observed post-login defaults success supports changing this ordering. It
does not establish why the early write failed or prove that the two preferences
alone suppress every Setup Assistant page. The failed direct CFPreferences
experiment does not support replacing defaults or running preference writes in
the root agent's launchd startup path.

This integration does not operate the retained failed VM or change either
protected template. Verification results follow.


### Integration verification

The canonical signed Release build/install passed, including signature,
entitlements, and designated-requirement checks. A fresh login shell resolved
`pomme` to `/Users/wes/.local/bin/pomme`; that executable reported
`0.1.0 (b1cdcc4-dirty)`.

Focused native tests covered owner preparation, the security workflow engine,
normal-agent response/desktop proof, the comparison lab, and MDM workflow
execution. The first run passed 435 invocations and found two stale AMFI test
expectations that still required restoration on owner-preparation failure. Those
expectations were corrected only for owner-preparation failures; later AMFI
failures retain their restoration assertions. After another signed-install gate,
the complete security workflow suite passed with no failures. All 114 CLI
integration checks passed against the installed signed runner. `git diff --check`
also passed.

No live VM commands were run for this integration. A fresh end-to-end live run
of the integrated sequence remains unverified; the earlier manual experiment
is evidence for the ordering, not a production workflow success receipt.

Logs:

- `/tmp/pomme-normal-owner-build-20260927.log`
- `/tmp/pomme-normal-owner-tests-20260927.log`
- `/tmp/pomme-normal-owner-integration-20260927.log`
- `/tmp/pomme-normal-owner-recheck-build-20260927.log`
- `/tmp/pomme-normal-owner-workflow-recheck-20260927.log`


## Fresh production-owner live test

The user authorized destroying existing VMs and creating a fresh clone for the
integrated owner workflow. After the signed build/path/version gate, inventory
showed only `pomme-agent-autologin-markerfirst26-20260927a`. Public `delete --force`
shut it down with `stopMethod=guest-stopped` and deleted it successfully. Both
protected templates remained unprovisioned and unchanged.

Created `pomme-agent-ownerflow26-20260927a` from the protected macOS 26 template
with 4 GB RAM and its 40 GB disk, requesting `--boot none`. Creation succeeded
and returned the VM stopped. Identity:

- macOS 26.6.2 / `25G83`
- VM UUID: `e0c1ff24-158c-483b-be72-34be279826ef`
- Plan: `ea7fb5a6296dd51e6a2c8900e0d4179f9fa69a014f4c7a552a232bbf34282260`
- Pinned agent: `ab54e778dc751f19a5e1c723c2c776c4e048252f00b1cbd6a38bc1b400ba361b`

The existing public entry point for fresh-owner preparation is a security
mutation. To test the requested owner sequence alone, the hidden comparison
harness gained a `production` strategy restricted to this exact clone name.
It invokes `PommeSecurityLiveOwnerPreparation` with `labStrategy: nil`, uses the
existing isolated owner journal, and never invokes the SIP/AMFI engine. All
existing template/build/resource/freshness checks remain required; success
requires `autologinVerified` after full desktop proof. Failure retains the VM
and journal without retry or cleanup.

The harness signed build/install and path/version gate passed. All five focused
harness tests and 114 CLI integration checks passed. The live command began at
17:08:49 UTC:

```sh
/Users/wes/.local/bin/pomme lab-autologin pomme-agent-ownerflow26-20260927a --strategy production
```

Logs: `/tmp/pomme-owner-live-create-20260927.log`,
`/tmp/pomme-owner-live-delete-20260927.log`, and
`/tmp/pomme-owner-live-run-20260927.log`.


### Production-owner live result

The command exited 0 after 200 seconds:

- 17:10:33 UTC: native autologin and system markers verified.
- 17:10:50 UTC: planned normal reboot and agent authentication verified.
- 17:10:51 UTC: exact owner console verified.
- 17:11:02 UTC: build preference write entered after diagnostic probes reported
  unavailable user/GUI launchd domains. The write succeeded; the workflow did
  not treat those diagnostic probes as a failed command requiring a retry.
- 17:11:44 UTC: MiniBuddy preference write entered.
- 17:12:03 UTC: preference readbacks and retained Setup Assistant closure passed.
- 17:12:10 UTC: full stable desktop proof passed; journal advanced to
  `autologinVerified`.

No automatic retry, SIP mutation, or AMFI mutation ran. Final public status
reported running in normal mode with a connected agent. The new VM is retained
running for inspection.

A successful host screenshot still returned the 23,685-byte Apple-logo/progress
frame, matching the earlier capture discrepancy. It does not visually confirm
the desktop despite the successful guest desktop proof. The current visible
frame therefore remains unverified; this test establishes the production owner
sequence and authenticated desktop checks passed, not that host screenshot
freshness is fixed. Private image: `/tmp/pomme-ownerflow26-desktop-20260927.png`.
No screenshot was committed. Final status log:
`/tmp/pomme-owner-live-status-20260927.json`.
