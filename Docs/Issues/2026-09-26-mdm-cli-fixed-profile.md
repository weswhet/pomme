# macOS 26 CLI enrollment with corrected profile — September 26, 2026 (PDT)

Status: the CLI helper reported enrollment failure despite the corrected
profile succeeding in the native UI. Security, run state, and artifact cleanup
were restored. The clone was subsequently deleted at the user's request for
fresh macOS 26 and 27 tests.
The user requested testing Pomme's enrollment workflow with the corrected
profile already proven through the [native UI](2026-09-26-mdm-native-ui.md).
Native UI success does not establish that the private CLI helper is fixed.

## Target and signed runner

The target is the existing `pomme-agent-mdmui26-20260926a` clone, running macOS
26.6.2 / `25G83`, with 4 GB memory and a 40 GB internal disk. It was created from
protected template `pomme-agent-ownerloop-base26-20260922a`. Before this test it
was enrolled and stopped, with SIP and AMFI enabled.

A fresh canonical signed build gate passed. The installed runner is
`/Users/wes/.local/bin/pomme`, version `pomme 0.1.0 (b1cdcc4-dirty)`, SHA256
`84ae79b2c18c4b4fbe86225b632c68d292e2b4a220a5d22aeda1332e715a7370`.
This is the same binary used in the preceding comparisons.

The corrected profile is:
`/Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-mdmui26-20260926a-importfix.mobileconfig`.

Its SHA256 is
`e6c98a9dd988d199da76ba08106cee03ca64ec936d2853f49f6494d7581b3f71`.
Only the PKCS12 container payload changed in that correction; the prior report
records the controlled comparison and successful native enrollment. This record
contains no profile contents, credentials, device identifiers, or raw frames.

The server baseline before preparation contained one device and one enabled
Device enrollment, with `token_update_tally` 1, created at
`2026-09-26 17:18:05 UTC` and updated at `17:19:52 UTC`.

## Preparation and CLI workflow

Native UI checkout began at `2026-09-26T17:39:16Z`. Guest profile checks then
reported no enrollment. NanoHUB recorded `PUT /mdm` HTTP 200 at `17:40:15.029Z`;
the exact enrollment row had `enabled` 0, `token_update_tally` 0, and update time
`17:40:15 UTC`.

Unenrollment removed the guest System CA. The exact pinned public CA was restored
through the owner's GUI SecurityAgent approval. The root pin matched, guest
HTTPS returned 200 without `-k`, and the staging file was removed. The clone was
stopped, establishing the unenrolled baseline. No standalone SIP preparation
was used.

The full command started at `2026-09-26T17:43:52Z`:


```sh
rtk proxy /Users/wes/.local/bin/pomme mdm pomme-agent-mdmui26-20260926a \
  --profile /Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-mdmui26-20260926a-importfix.mobileconfig \
  --guest-path /private/var/db/pomme-mdm-enrollment/openmac26-cli-fixed.mobileconfig \
  --enrollment-mode supervised --timeout 300 --force --format json --debug
```

The initial journal recorded `securityPreparationIntent`, pending operation
`sipDisable`, and `dispatched` false. This snapshot does not establish completion
of the transition. The user's latest request authorizes the CLI's own SIP/AMFI
preparation and restoration for this full workflow. The CLI reached `enrollmentIntent` at approximately `17:58 UTC`. At
`17:59:48 UTC`, the helper reported the closed error `enrollment-failed`. The
outer journal recorded `enrollmentDispatched` true, `enrollmentVerified` false,
and `helperTerminationUnproven` false.

This is an observed CLI failure with the same corrected profile that succeeded
through the native UI. Installation was not replayed, and the ineligible JSONL
reuse test was skipped. The unknown-outcome journal remained intact through
restoration and independent verification.

## Failure boundary and server evidence

A bounded server check for `17:58–18:01 UTC` found no timestamped Caddy or
NanoHUB lines, no `/mdm` events, and no Caddy TLS error. The logger recorded the
prior native UI enrollment traffic. The database still contains one device and
one enrollment, disabled with `token_update_tally` 0 and unchanged update time
`17:40:15 UTC`. No HTTP request was observed for this CLI attempt; the absence of
logs is not absolute proof that no request occurred.

Read-only source mapping in `Sources/PommeCLI/GuestInternal/GuestMDMEnrollment.swift`
places the closed `enrollment-failed` error among steps before installation XPC:
profile observation or `CPProfile` initialization, identity-Keychain selection
or snapshot, and identity attachment or archiving. Actual `SecPKCS12Import`
failures and installation or approval XPC errors map to
`enrollment-outcome-unknown`. The journal's `enrollmentDispatched` flag records
helper-process launch, not an XPC call.

These boundaries narrow the investigation but do not identify the failing step.
The current diagnostics cannot distinguish the exact cause. Further diagnosis
requires safe stage receipts, outside this test's source-change scope.

## Final result and subsequent removal

The command exited 1 at `18:12:21 UTC`, with phase `restorationComplete`,
`enrollmentOutcome` unknown, and `securityRestored`, `runStateRestored`, and
`artifactsCleaned` all true. The last enrollment, approval, and supervision
observations were false. Independent guest checks confirmed no MDM enrollment,
SIP enabled, empty boot arguments, the expected trusted root pin, and HTTPS 200.
The clone was stopped with no running helper.

The user then requested deleting all existing VMs and testing fresh clones of
both OS versions. The signed CLI deleted this clone with exit 0 and
`stopMethod` `already-stopped`. Its bundle and journal were removed as part of
that explicit deletion. Both protected templates remain intact. The prior
failure was not retried or bypassed by changing its journal.

No CLI enrollment success is claimed. No production source changes were part of
this test. Private host debug screenshot cleanup is tracked with the follow-up
test preparation.
