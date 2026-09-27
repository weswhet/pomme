# Guest Buddy maintenance stops at the initial receipt gate on macOS 26

## Scope

The disposable clone `pomme-agent-buddy26-20260927a` was created on September
27, 2026 from the protected, unprovisioned
`pomme-agent-ownerloop-base26-20260922a` template. It used macOS 26.6.2
(25G83), 4 GiB of memory, and a 40 GiB disk. The owner-workflow harness used
the `buddy` strategy, an isolated journal, and no SIP or AMFI operation.

## Result

The experiment stopped at its first failure, before automatic-login markers,
the planned reboot, or desktop proof. The VM and its diagnostics remain
retained and running for investigation.

The guest independently started Buddy preference maintenance before login,
detected the newly created local `pomme` owner (UID 501, verified generated
UUID, and `/Users/pomme` home), and wrote a receipt for the current boot. It
then failed during `maintainingBuild` with the closed error
`preference-write-failed` and numeric status `1`. The bounded guest log adds
no preference contents:

```
Buddy maintenance failed stage=maintainingBuild code=preference-write-failed numeric=1
```

Separately, the host's initial receipt gate attempted the status read through
the control command `agent.perform`. The host helper rejected the request
before guest dispatch because its closed operation allowlist omitted
`buddy.preferences.status`. The agent already advertised this capability.
The missing host allowlist entry was corrected after the live test, with
regression coverage through the control wire codec and router. No live retry
was performed.

## Evidence

The root-owned receipt records boot `8AEE2D4B-888D-436D-A196-8260F33CCBB5`,
macOS `26.6.2`, build `25G83`, stage `maintainingBuild`, and outcome `failed`.
The isolated journal remains at `autologinIntent` with
`normalBootVerified: false`; its directory contains only the experiment
receipt and journal. No marker or desktop-verification receipt exists.

After failure, the normal agent remained connected with the expected signed
digest. A scoped `/usr/bin/id -u` request returned `0`, so ordinary process
transport remained responsive while the failure receipt was retained.

Sequential read-only checks establish the timing of the failed attempt. The
console owner was `_windowserver`, `/var/db/.AppleSetupDone` was absent, and
the specific login-window `autoLoginUser` key did not exist. Buddy maintenance
therefore reached its preference write before a `pomme` console login, Setup
Assistant completion, or configured automatic login.

Before live testing, the signed installed runner was verified at source state
`81ed195-dirty` with SHA-256
`698630cc7b90e204c055d15e83f2bc37335d82ad0c75969d3c3266fcf10a54be`.
Native verification passed 171 tests across 285 parameterized runs, with no
failures or skips. The CLI integration suite passed 114 checks.

## Final offline verification

After correcting host routing and binding the macOS 27 bootstrap receipt to an
independent native owner read, the canonical signed Release build/install gate
passed. A fresh login shell resolved `/Users/wes/.local/bin/pomme`; its version
was `0.1.0 (81ed195-dirty)`, matching the working source. The final installed
SHA-256 is
`761edfb30b746cc640474de86061454b4a3c07b62a12cdea4eef458066689afc`.
The retained guest still uses its original creation-pinned `698630...` artifact;
it was not replaced.

Native `xcodebuild test` passed 185 focused tests across 313 runs, with no
failures or skips. These ran in the native test bundle. Coverage includes the
maintenance lifecycle, actual subprocess output/signal/timeout behavior,
authenticated daemon responsiveness, Recovery exclusion, owner/workflow gates,
bootstrap owner identity, and the host control router. The result bundle is
`~/Library/Developer/Xcode/DerivedData/pomme-native-tests/Logs/Test/Test-pomme-2026.09.27_12-29-22--0700.xcresult`.

The CLI integration script separately passed all 114 checks using the exact
installed executable with `--runner /Users/wes/.local/bin/pomme --no-build`.
These offline checks do not establish successful pre-login preference writes.

## Follow-up

Investigate the guest `defaults` command failure before another live attempt.
The host routing fix does not change the independently observed guest write
failure. The retained VM was not retried, and the macOS 27 experiment did not
start. Another-boot maintenance and the complete live owner workflow remain
unverified. Both protected templates were rechecked after the experiment and
remain unprovisioned and unchanged.
