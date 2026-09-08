# Unified MDM enrollment validation — September 7, 2026

## Scope

The public command is `pomme mdm VM --profile FILE`, defaulting to
`--enrollment-mode supervised`. Explicit `unapproved` requests require observed
enrollment with both approval and supervision false. The old enrollment and
approval subcommands and acknowledgement flag are rejected.

The parent MDM journal owns one VM mutation lease, exact profile identity and
digest, selected mode, original run state, owned guest artifacts, security
baseline, and child-operation intents. It contains no profile bytes or
credentials. SIP/AMFI changes use the existing inherited-lease Recovery
workflows. AMFI restoration precedes SIP restoration; unproved helper or
Recovery cleanup blocks further boot transitions.

## Automated checks

- 138 focused parser, evidence, helper, enrollment, journal, execution, and
  Recovery/security tests passed, including all 20 original run/security-state
  combinations, cleanup barriers, staged-profile ownership, and schema-3
  pre-transfer resume compatibility.
- 22 CLI integration checks passed against the canonical signed Release.
- 21 offline local build/install checks passed.
- The signed installer verified Developer ID identity, team, designated
  requirement compatibility, secure timestamp, Hardened Runtime, and exactly
  the Virtualization entitlement before replacement. Previous signed bytes
  were retained in the append-only artifact store.

Final installed Release SHA-256:
`16cf6bc8f23a19a43d03a4e173e4b6a368e0f679719287daae15cf3fa10e5379`.
The final focused result bundle is
`test_macos_2026-09-07T17-19-16-523Z_pid25175_41125a06.xcresult`.
Build warnings remain in pre-existing code; the focused tests had no failures.

The evidence tests cover the actual macOS 15.7.9 device-level
`profiles show` schema and bounded `mdmclient` daemon wrapper, including
`QueryResponses.IsSupervised`. No raw profiles or device responses are retained
in this document.

## Existing macOS 15.7.9 VM

Target: `pomme-agent-sequoia-1579-final-0906`, macOS 15.7.9 (24G830).
Original state: running normal macOS, SIP enabled, empty active boot arguments,
and present-but-empty configured `boot-args`.

The original authenticated protocol-v1 agent remained pinned to SHA-256
`fce77dcf695b6740c8da395bc213b4ead347707e427bd1cb4167acc545567022`.

An independent server DeviceInformation command
`8a78ed8e-d82c-4bf1-b538-2d01225cefab` was acknowledged with
`IsSupervised=false`, OSVersion 15.7.9, and BuildVersion 24G830.

The direct `unapproved` command passed on the installed profile, reporting:

```json
{"enrolled":true,"userApproved":false,"supervised":false,
 "enrollmentMode":"unapproved","securityRestored":true,
 "runStateRestored":true,"artifactsCleaned":true}
```

Its journal independently recorded no helper dispatch, no SIP/AMFI changes,
verified enrollment, no pending child, and `restorationComplete`. Independent
guest checks still showed SIP enabled and empty active boot arguments.

The supervised upgrade was attempted, but stopped during existing-owner
authorization. The retained SIP child remains at `credentialPending`, before
the security-mutation intent. The parent remains at
`securityPreparationIntent`, with `pendingChild=sipDisable` and
`enrollmentDispatched=false`. These journals were not rewritten to claim
completion. The command reported incomplete restoration and verified the
original normal-running state.

Independent checks after the attempt established:

- The same exact device-level profile remains installed.
- `profiles status` still reports enrollment without User Approved status.
- Guest `QueryResponses.IsSupervised` remains false.
- Server DeviceInformation command `ecbc8697-67ea-4390-b57a-e6ea41ace3bc`
  was acknowledged with supervision false and the same OS/build.
- SIP remains enabled; active boot arguments remain empty; configured
  `boot-args` remains present and empty.
- The original pinned agent remains authenticated in normal macOS.
- All five reserved MDM artifact paths are independently absent, including
  symbolic-link checks.

The baseline also exposed an existing `enabledVerified` AMFI completion record
whose exact policy proof must be repeated after SIP preparation. The parent now
defers only this enabled/SIP-enabled case, and revalidates it before starting
any AMFI child. A failed revalidation does not authorize AMFI mutation or a
guessed policy reset.

Successful supervised upgrade, post-upgrade approval/supervision, and the
complete live security restoration cycle remain **unverified**. Resume the
same command, profile, and mode once existing VM-owner authorization is
available:

```sh
pomme mdm pomme-agent-sequoia-1579-final-0906 \
  --profile /Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-sequoia-1579-final-0906.mobileconfig \
  --timeout 120 --json --debug
```

Use the existing VM-scoped owner credential or the workflow's private
interactive authorization. Do not recreate credentials, alter Keychain ACLs,
rewrite journals, or invoke a competing security command to bypass this
retained operation. Schema-3 pre-transfer journals can resume under schema 4
without claiming ownership of a staged profile.

The final installed binary also rejected both a changed enrollment mode and a
competing AMFI status command against this unfinished parent journal, before
any VM transition. The live staging-ownership collision test was not run while
that operation remains unfinished; journal ownership behavior is covered by
the focused tests.

## Fresh VM limitation

The requested disposable fixture used **4 GiB RAM and a 60 GB sparse disk**.
There was no directly available macOS 15.7.9 restore image; the attempt used
15.6.1 (24G90) as the required installation/update starting point. Creation
consumed approximately 19 GiB of host space and did not reach an authenticated
agent before the remaining space fell to approximately 21 GiB. That was not
enough safe capacity to proceed with the OS update and enrollment experiment.

The newly created `pomme-agent-mdm-unified-0907` fixture and its exact temporary
credential were deleted, restoring host capacity. No pre-existing VM or pinned
agent artifact was deleted. Fresh unenrolled macOS 15.7.9 live enrollment is
therefore **not qualified** by these checks and still requires additional host
disk capacity.
