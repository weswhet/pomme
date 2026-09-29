# One-command MDM enrollment from any VM state — September 28–29, 2026

Status: **passed live on macOS 27 and macOS 26** at `e1f331d`. Each passing
run took `pomme mdm` from a missing VM to a supervised, user-approved
enrollment against the private-CA lab server. SIP/AMFI were restored and the
VM was stopped, with no manual trust setup and no fail-open fallback. MDM
server commands on the enrolled macOS 26 VM confirmed supervision
independently.

## What changed

`pomme mdm VM --profile FILE` now plans from the VM's retained state and runs
only the steps it needs, all under one mutation lease:

1. It creates a missing VM (`--from-template`, `--version`/`--latest`,
   `--restore-image`, `--memory`, `--disk-size`, `--boot none|normal`).
   Creation options are ignored once the VM exists.
2. It resumes an incomplete creation.
3. It finishes a retained standalone SIP/AMFI operation.
4. It enrolls. The existing engine detects SIP and AMFI and disables only what
   enrollment needs.

`--dry-run` reports the detected state, the planned steps, and any blockers.
`--final-security disabled` keeps the SIP/AMFI changes that enrollment made
(MDM journal schema 6). A host TLS preflight checks the profile's server before
anything changes.

Commits, one per slice or fix, each with its offline suite:

| Commit | Change |
| --- | --- |
| `66b0ea8` | `--final-security`; MDM journal schema 6 |
| `662bb44` | Profile trust material and host server-trust evaluation |
| `5d87509` | Guest trust decision before identity import |
| `441ec91` | Pure readiness planner; read-only provisioning classifier |
| `05fb3a1` | Shared direct-creation request for `create` and `mdm` |
| `4423c47` | Orchestrator, dry run, creation options, structured steps |
| `0b75246` | README, security workflow, and release-note documentation |
| `40ed6d8` | Buddy preference checks fail open |
| `67fe57b` | Profile certificates installed as a separate trust profile |
| `d624e83` | Buffered-stream test polls against a real deadline |
| `507b244` | 30-second budget for process launches; honest `commandIncomplete` error |
| `a76ab5f` | Buddy preferences through CFPreferences instead of `sudo defaults` |
| `2ee75ff` | Guest users and owner passwords through OpenDirectory instead of `dscl` |
| `a5d487d` | `owner.credential.read` reads `autoLoginUser` through CFPreferences |
| `e1f331d` | Multi-valued directory attributes reported the way `dscl` reports them |

## Findings that drove the fixes

- **Root CA inside the MDM archive (clone `a`).** `InstallMDMv1Profile`
  accepted an archive that carried the `com.apple.security.root` payload. The
  daemon logged `Assertion Failed` in `MCXTools/ConfigProfile`, and its first
  check-in failed with `system TLS Trust evaluation failed(-9802)`. The root
  therefore now goes first, as its own profile
  (`com.github.weswhet.pomme.mdm-trust.<profile UUID>`) through the private
  `InstallProfile` request. The guest's own trust must then validate the
  server before identity import.
- **Process spawns right after boot.** On fresh macOS 27 clones, a single
  `sw_vers` took 3.5–6.2 s to spawn after boot. The agent spawns before it
  replies, so `process.start` exchanges exceeded the 5-second round-trip
  budget. This produced the "PTY failed: unclassified" and the misleading
  "could not be authenticated" errors. Process launches now get 30 s.
- **Shelling out to `dscl` and `defaults`.** The bootstrap `dscl` owner read
  exceeded its 15 s limit on every fresh clone. The equivalent OpenDirectory
  lookup takes milliseconds in-process. `sudo -u pomme defaults` failed at the
  first `read-type` on macOS 26 and 27. Both are now native, and capability-
  gated: agents pinned before these capabilities keep the old commands.
- **Multi-valued records (clone `e`).** The first native directory read was
  rejected. On macOS 27, 132 of 133 local system records have a `RecordName`
  alias (for example `_www`/`www`), and `root` has two `NFSHomeDirectory`
  values. The agent now reports the primary name and space-joins other values,
  as `dscl` does. The host's strict parser still judges every record it uses.

## Live runs

All runs used the canonical signed runner at `/Users/wes/.local/bin/pomme`,
disposable clones with 4 GB of memory, the templates' 40 GB disks, and
per-clone profiles from the lab NanoHUB server
(`https://10.200.2.165:9444/mdm`). The host preflight reported
`profileRootTrust` every time: Apple's roots do not validate the server, but
the profile's root does.

| Clone | Guest | Build | Outcome |
| --- | --- | --- | --- |
| `…27-20260928a` | 27.0 | `0b75246`→`40ed6d8` | Resumed creation; enrollment failed TLS with the root inside the MDM archive. Deleted. |
| `…27-20260929b` | 27.0 | `67fe57b` | Resumed creation once (`ownerProof` spawn timeout), then **enrolled**. A rerun was a 40 s satisfied no-op. Deleted. |
| `…27-20260929c` | 27.0 | `507b244` | Created and **enrolled** in one pass, run concurrently with `b` under heavy host load. Deleted. |
| `…27-20260929d` | 27.0 | `a76ab5f` | **Enrolled**. The Buddy receipt passed without falling back. Retained, stopped. |
| `…27-20260929e` | 27.0 | `a5d487d` | Native directory read rejected (multi-valued records). Its pinned agent could not be fixed in place. Deleted. |
| `…27-20260929f` | 27.0 | `e1f331d` | **Enrolled** with no fail-open fallback. Retained, stopped. |
| `…26-20260929a` | 26.6.2 | `e1f331d` | **Enrolled** with no fail-open fallback, including fresh-owner creation. Retained, stopped. |

On clone `f`, the guest log recorded both Buddy preferences written and read
back through CFPreferences on first boot (`preference-readback-verified`). They
were skipped as already current on every later boot, including the SIP/AMFI
reboots.

The macOS 26 run completed in about 30 minutes:

1. Recovery agent installation.
2. Fresh-owner creation inside the SIP child: native owner evidence and
   password verification, automatic login, Setup Assistant markers, reboot,
   owner console, both preference receipts, and full desktop proof. This is
   the stage that failed on macOS 26 on September 26 and 27.
3. SIP and AMFI disable.
4. Trust profile, identity import, and MDMv1 setup, install, and approval,
   in 1.4 s.
5. AMFI, then SIP, restoration.

### Supervision validation (macOS 26)

Commands were built from Apple's documentation, retrieved through sosumi. The
supervised-only set comes from Apple's `apple/device-management` schema
(`supportedOS.macOS.supervised: true`). Commands were queued through the
NanoHUB API, and results were read from its `command_results` table. Every
command was `Acknowledged` within about five seconds of a push.

| Command | Supervised-only on macOS | Result |
| --- | --- | --- |
| `DeviceInformation` | no | `IsSupervised = true`, SIP enabled, 26.6.2 (25G83) |
| `SecurityInfo` | no | `UserApprovedEnrollment = true`, `EnrolledViaDEP = false`, `IsUserEnrollment = false`, `IsActivationLockManageable = true`, full secure boot |
| `UserList` | yes | `pomme`, logged in, with a Secure Token |
| `OSUpdateStatus` | yes | Acknowledged; no pending updates |
| `ScheduleOSUpdateScan` | yes | Acknowledged |
| `EnableRemoteDesktop` | yes | In the guest, `com.apple.screensharing` became enabled and `ARDAgent` started |
| `DisableRemoteDesktop` | yes | In the guest, `com.apple.screensharing` returned to disabled and `ARDAgent` stopped |

Not run:

- **Destructive commands** (`DeleteUser`, Activation Lock bypass).
- **The two supervised-only macOS profile keys.** Restrictions'
  `forceClassroom*` keys are typically ignored on unsupervised Macs, so they
  prove little. Managed DNS `ProhibitDisablement` would redirect the guest's
  DNS.
- **An unsupervised negative control.** No unsupervised VM was enrolled to
  confirm the refusals.

The VM was returned to stopped with Remote Desktop off.

## Offline verification

At `e1f331d` the offline suite ran 1,408 tests. Its one failure predates this
work:
`PommeFrameworkOwnerWorkflowTests.exactCredentialFailureHasNoFallback`, stale
since `81ed195`. The CLI contract script passed 133 checks against the
installed runner.

## Open items

- Three `defaults read` calls remain in owner preparation: the login-window
  restriction scan, the `AppleLanguages` readback, and the autologin
  readback. The hidden `lab-autologin` command also uses `defaults`. Both need
  a native system-preferences agent operation.
- `--final-security disabled` and the interrupt/resume scenarios for a retained
  standalone SIP/AMFI operation are covered offline, not live.
- Reinstalling a pinned agent after creation completes has no repair path. It
  is reported as a blocker.
- The stale framework-owner test needs updating.

Protected templates `pomme-agent-base27-20260923a` and
`pomme-agent-ownerloop-base26-20260922a` were unchanged throughout.
