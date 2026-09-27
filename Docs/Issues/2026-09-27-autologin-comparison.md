# macOS 26 automatic-login comparison

## Scope

The user requested deletion of existing VM instances and a controlled comparison
of native `sysadminctl` automatic login with Tiddly-style loginwindow preference
and `/etc/kcpassword` writes. The comparison uses two fresh internal-drive clones
of `pomme-agent-ownerloop-base26-20260922a` (macOS 26.6.2, build 25G83), each with
the template's 40 GB disk and 4 GB memory.

Owner creation, native readback, per-user Setup Assistant completion,
`.AppleSetupDone`, and desktop verification remain common to both arms. The
experiment does not request SIP or AMFI changes. On a failed operation, the lab
entry retains the VM and journal without an automatic retry, shutdown, or
restoration. This deliberately omits the production workflow's single
preference-error reboot recovery in both arms.

## Initial cleanup and build

The canonical signed Release build/install passed before any CLI operation.
The installed runner was `/Users/wes/.local/bin/pomme`, version
`0.1.0 (b1cdcc4-dirty)`, digest
`d2d3e4991b4708382d0eba8eb18820773106d9232a05687388e34235240147f9`.
Fresh-login-shell resolution, signature, entitlements, and designated-requirement
checks passed.

Inventory contained two stopped VMs. Explicit public `delete --force` calls
removed both with exit 0 and `stopMethod=already-stopped`:

- `pomme-agent-mdmdebug26-20260926b`
- `pomme-agent-mdmdebug27-20260926b`

The subsequent VM inventory was empty. Both protected templates remained
unprovisioned and unchanged. No MDM server enrollment records were modified.

## Experiment fixtures

| Arm | VM name | Resources |
| --- | --- | --- |
| Native | `pomme-agent-autologin-native26-20260927a` | 40 GB / 4 GB |
| Legacy | `pomme-agent-autologin-legacy26-20260927a` | 40 GB / 4 GB |

Both create operations completed successfully and restored stopped state. The
native clone UUID is `d7570b75-26c9-40d2-8f52-0520cce09b1e`; the legacy clone UUID
is `bc075bd4-0d78-40ad-a002-3fa27ffd70ce`. Both pin the initial signed guest digest
above. Their plan digests are respectively
`645d4c9f59fff871af7db7cfeade4e29e93e6de4635886906617a297f01351b5` and
`7a466096c79d4f07ba947a26d5e2413bbf46f2fbe1b5eabea8e0b2c11c5b201c`.

## Lab runner verification

A hidden, exactly scoped `lab-autologin` command reuses owner preparation and
keeps its journal in an exclusive experiment directory. The legacy setter
preserves other loginwindow keys and writes root-owned plist mode 0644 and
kcpassword mode 0600. Encoded credential bytes use authenticated stdin, never
argv or environment. Shared native readback remains mandatory.

The first build found a Swift Sendable closure inference error. After correction,
the canonical signed build passed with installed digest
`33412abd321de6a5f54ccd023c5f28a1592b89467895334c07557a19c3688da6`.
Fresh shell resolution and source version checks passed. Native focused owner
and lab suites passed 247 invocations, zero failures; all 114 CLI contract checks
passed using the installed runner.

The first lab invocation rejected its template/resource preflight before any VM
boot, owner mutation, or experiment journal creation. This was a lab harness
validation failure, not an autologin result. Immutable clone input intentionally
has no startup-volume-group UUID; runtime metadata contains it. The guard now
uses the same runtime identity source as production and reports each rejected
condition separately. A regression proves that absent input UUID plus valid
runtime UUID passes, while absent runtime identity fails.

The corrected signed runner digest is
`bb7768a2680d10cd6c93f1460d93a4729fa1afbd1fab6931aa6a0dfc5f35cdfd`.
The signature/install/path/version checks passed again; all three lab tests
passed after the correction. The live native arm began at 07:15:37 UTC.

## Native arm

At 07:17:04 UTC, native automatic-login status named the expected owner,
loginwindow `autoLoginUser` matched, and kcpassword metadata passed. The native
setter therefore completed the shared autologin proof.

At 07:17:06 UTC, the first owner `LastSeenBuddyBuildVersion` preference write
began. It failed with status 1 and the specific
`ownerWriteStderrWriteDomainFailed` classification. Existing bounded diagnostics
found the expected home, UID, HOME, writable/searchable Preferences mode, an
owner cfprefsd process, and stock Setup Assistant. The owner user domain was
reachable; the GUI domain probe returned nonzero. The build preference remained
missing. These observations do not establish the underlying write failure cause.

The command exited 1 at 07:17:10 UTC after 92 seconds, retaining
`autologinIntent`. It did not reach Pomme's `.AppleSetupDone` creation or reboot
and desktop verification. It did not automatically retry, restore, or shut down.
No further VM commands were issued against the native clone after that failure.

## Legacy arm

The legacy arm began at 07:17:37 UTC. It used the same signed host executable and
creation-pinned guest digest as the native arm. Owner creation, verification,
restrictions, and Setup Assistant handoff passed. At 07:19:19 UTC, the legacy
setter completed its writes and file readbacks. The immediately following
shared native `sysadminctl -autologin status` probe returned automatic login OFF.

The command exited 1 at 07:19:19 UTC after 102 seconds, retaining
`autologinIntent`. It did not proceed to owner completion, Pomme's
`.AppleSetupDone` creation, or reboot and desktop verification. No retry,
restoration, shutdown, or subsequent VM command followed the failure.

## Result and limits

| Stage | Native | Legacy |
| --- | --- | --- |
| Owner creation and verification | Passed | Passed |
| Autologin setter | Returned success | Wrote and checked both files |
| Shared native autologin readback | Passed | Reported OFF; failed |
| Owner Setup Assistant preferences | First build preference write failed | Not reached |
| Pomme `.AppleSetupDone` creation | Not reached | Not reached |
| Reboot and desktop proof | Not reached | Not reached |

The native run reproduces a completion-preference failure after verified
autologin. Replacing the setter alone did not make the unchanged workflow pass:
the legacy approach failed an earlier native-state check. This does not prove
that legacy login would fail after a reboot; the experiment intentionally did
not bypass that check or operate either failed clone again. It also does not
prove that the two per-user preference writes are required. An experiment that
changes that requirement would be a separate comparison.

The two runs were sequential. The failed native clone remained untouched while
the legacy arm ran, so elapsed times are recorded only as trace context, not a
performance comparison. Both clones remain at their failure state for inspection;
their run state was not probed afterward. SIP and AMFI were not changed. A
template-only inventory after the native failure confirmed both protected
templates still have their original builds, unprovisioned state, 40 GB disks,
restore digests, and no owner.

Local diagnostic logs:

- `/tmp/pomme-autologin-native26-20260927.log`
- `/tmp/pomme-autologin-legacy26-20260927.log`
- `/tmp/pomme-autologin-ab-build-20260927.log`
- `/tmp/pomme-autologin-ab-tests-20260927.log`
- `/tmp/pomme-autologin-ab-preflight-tests-20260927.log`
- `/tmp/pomme-autologin-ab-integration-20260927.log`

The lab command remains hidden and restricted to these two exact fixture names.
Its exclusive experiment directory blocks reruns. Production uses the native
setter and its existing completion behavior; this experiment does not change
that default.
