# macOS 26 MDM enrollment comparison — September 26, 2026 (PDT)

Status: enrollment failed on both macOS versions. Independent guest and server
checks found no enrollment. Security restoration and the safe repeat refusal
were verified; the cause remains unresolved. The user requested
an actual macOS 26 enrollment attempt to compare with the macOS 27 failure
recorded in [the previous lab](2026-09-25-mdm-macos27.md).

## Environment and comparison controls

- Clone: `pomme-agent-openmac26-20260926a`.
- Protected source template: `pomme-agent-ownerloop-base26-20260922a`.
- Guest: macOS 26.6.2 / build `25G83`.
- Resources: 4 GB memory and the template's 40 GB disk, on the internal drive.
- Requested creation final state: `--boot none`.

The signed build gate passed. The installed runner is
`/Users/wes/.local/bin/pomme`, version `pomme 0.1.0 (b1cdcc4-dirty)`, with SHA256
`84ae79b2c18c4b4fbe86225b632c68d292e2b4a220a5d22aeda1332e715a7370`.
This is the same executable used for the macOS 27 enrollment attempt. The build
workflow verified signing and entitlements, and the fresh-shell runner and source
version checks passed.

Creation completed with a schema 1 journal and the guest agent installed, but no
owner account. The macOS 27 clone used schema 2 provisioning that created its
owner. This difference must be considered when interpreting the comparison.
The first journaled `sip disable --force` owner-preparation attempt timed out at
`normal-agent-console-transport` after verifying the owner and automatic login.
One exact same-command resume succeeded at `2026-09-26T15:24:36Z`, exiting 0 with
`configuredDisabled`, `runtimeConfigurationVerified`, `enforcementVerified`, and
`finalStateVerified` true, and final state stopped.

SIP enable completed at `2026-09-26T15:28:51Z`, exiting 0 with
`configuredDisabled` false and `runtimeConfigurationVerified`,
`enforcementVerified`, `finalStateVerified`, and `normalBootVerified` true. The
clone was stopped, restoring the enabled SIP baseline before trust setup.

The protected source template has not been used as a live target. The macOS 27 clone was subsequently removed with user authorization; see the
removal note in the previous lab record. Both protected templates remain intact
and unprovisioned, without an owner or disabled security settings.

## Server, profile, and trust preparation

The existing server project is `/Users/wes/dev/nanohub-acme-docker`. The server
health check passed and reported NanoHUB `v0.2.0`.

A fresh profile was generated for this clone with the project's profile script:

`/Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-openmac26-20260926a.mobileconfig`.

The file has mode `0600` and contains one PKCS12 payload, one root certificate
payload, and one MDM payload, with the identity references linked. Its root
certificate matches the server CA SHA256
`32f8c08019e289d48126b80b63ecf80ad503069be79c3d84db0315e3449ee3e8`.
No profile body, credentials, or device identifiers are included in this record.

Pomme's enrollment path does not install the root payload. Trust setup used the
native SecurityAgent approval route established during the macOS 27 lab without
changing authorization database rules. The expected System Certificate Trust
Settings prompt was accepted using the generated guest credential held only in
memory. The trust session exited 0, and guest HTTPS verification passed without
`-k`.

The exact root-owned CA staging file was removed and its absence verified. The
clone stopped with method `guest-stopped`; no helper remained running. The
server's exact per-clone baseline query exited 0 and found zero device or
enrollment rows. Preparation is complete for the supervised enrollment attempt.

## Enrollment attempt and verification

The primary command used:

```sh
rtk proxy /Users/wes/.local/bin/pomme mdm pomme-agent-openmac26-20260926a \
  --profile /Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-openmac26-20260926a.mobileconfig \
  --guest-path /private/var/db/pomme-mdm-enrollment/openmac26-test.mobileconfig \
  --enrollment-mode supervised --timeout 300 --force --format json --debug
```

The attempt started at `2026-09-26T15:33:14Z`. Helper signing, signature,
and entitlement checks were accepted. At `15:48:40Z`, the helper reported the
closed error `enrollment-failed`. The outer command ended at `16:01:18Z` with
exit 1, `enrollmentOutcome` unknown, and phase `restorationComplete`.

The last observed guest result had `enrolled`, `userApproved`, and `supervised`
all false. `securityRestored`, `runStateRestored`, and `artifactsCleaned` were
all true. The baseline, intermediate, and final exact per-clone server queries
all exited 0 and found zero device or enrollment records.

Both macOS 26 and macOS 27 therefore reached the same generic helper failure
with this signed binary and server. This does not identify the root cause or
establish an OS-specific defect. The owner-provisioning difference remains a
comparison limitation.

Independent guest checks reported `Enrolled via DEP: No` and
`MDM enrollment: No`. `csrutil` reported SIP enabled, and configured NVRAM
`boot-args` were empty. The guest was returned to the stopped state.

One exact same-profile, supervised JSONL resume exited 1 and safely refused to
repeat installation without evidence resolving the unknown outcome. No
installation was replayed. Final status showed the VM stopped with no running
helper. Successful enrollment reuse and downgrade checks were not possible
because supervised enrollment did not succeed.

## Cleanup and retained state

The guest CA staging file and private CA prompt directory were absent. Eight
exact Pomme debug directories containing 40 PNGs were removed after strict
validation. The exact lab temporary root was verified absent, with no owned
private temporary artifacts remaining. Cleanup is complete. A fresh check with
the signed installed CLI confirmed the VM stopped, boot mode `none`, and no
running helper. The final repository `git diff --check` passed.

The macOS 26 VM is retained stopped for inspection, with its journals, root CA
trust, required credentials, and private enrollment profile. The lab operator
created no additional direct Keychain labels or items.

No successful enrollment, complete test matrix, or production repair is claimed.
The same generic failure on macOS 26 and 27 remains unresolved. No production
source changes were made for this comparison.
