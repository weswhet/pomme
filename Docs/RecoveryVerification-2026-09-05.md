# Recovery installation and direct UI verification

Development verification completed on 2026-09-05 UTC. This is not a release
qualification record and does not promote an experimental profile to reviewed
status. No raw screenshots, credentials, or guest request bodies are retained
in this document.

## Verified build and machine

- Host: macOS build `25G72`, Apple silicon.
- Guest: Tahoe `26.6.2`, build `25G83`, English, 1280 by 800.
- Disposable Pomme VM: `pomme-agent-tahoe-exec-0905f`.
- Profile: `experimental-26.6.2-25G83-en-1280x800`; no review digest.
- Installed CLI: `~/.local/bin/pomme`, built by `Scripts/build-local.sh`.
- Signing identifier: `com.github.weswhet.pomme`.
- Signer: Developer ID Application, Wesley Whetstone (`2D8XQ77EBQ`).
- Hardened Runtime and secure timestamp verified; Virtualization is the only
  entitlement. Strict signature verification and designated requirement passed.
- Initial host executable and authenticated normal-agent SHA-256:
  `e3b740f2d8488d9aa0acabaee5a69dc3b99d7763a664db68be672e92bc528d34`.
- Immutable provisioning-plan digest:
  `d88835185f9fbcc1e7630268eabf33ac76c1c25e98d135d62a15ac243f657564`.

## End-to-end evidence

`pomme create pomme-agent-tahoe-exec-0905f --version 26.6.2 --boot none`
completed successfully. Its generation-11 journal records an intent and receipt
for each of these phases, all on attempt 1: install, display-only first normal
boot, Recovery agent installation, normal-agent verification, and final-state
restoration. The requested final state is stopped.

After an additional normal boot, `pomme agent status` reported an authenticated
normal-role protocol-1 connection with the exact executable digest above and
process, file, system, network, MDM, and maintenance capabilities. Capability
advertisement is not evidence that every advertised operation was exercised.
`pomme exec ... -- /usr/bin/id -u` returned stdout `0` and host exit status 0.
Separate checks also preserved stdout/stderr with exit 7, silent success,
200,000 binary output bytes, and a 24,000-byte stdin round trip.

A separate manual Recovery boot exercised the public `ui` commands without a
guest-agent connection or OCR. Two fresh matching screenshots were checked at
each navigation checkpoint. Individual keys traversed the boot picker,
English selection, and menus; Control-F2 and Shift-Command-T opened Terminal.
`ui type --text '/usr/bin/id -u'`, followed by `ui key ... return`, visibly
produced `0` in the Recovery shell. `ui click --x 82 --y 14` opened Terminal's
menu and `ui key-sequence ... escape` closed it. These input responses identified
their backend as `virtualization-private-direct`. Normal-OS screenshot capture
also reported that backend.

The final Recovery root-output screenshot pair had SHA-256
`4420e692ba01ca77a696ca5c2745a8d7928577bb9e95c97e55f16697671775f7`.
This digest identifies an observation only; it is not a profile-enabling token.

## Boot-proof ordering follow-up

Review found that the live composition had bundled navigation into VM startup,
before the root port's independent boot checks. Startup and launcher effects
are now separate. VM identity, a successfully completed Recovery-mode start,
current runtime liveness, and the exact share are checked before any navigation
or launcher input. Runtime boot proof is queue-confined and cleared on failure
or teardown; stable Recovery frames remain required before navigation events.

The corrected Release CLI was signed and installed with SHA-256
`d7d9bd6c0ca75c25195d7cb50d09065543119630330aeab63f23ec8a1a7c5605`.
Signature, designated requirement, signer, identifier, and entitlements were
verified by the canonical installer. The VM's existing agent remains pinned to
the original digest above; its plan was not rewritten.

At 06:30:18 UTC, `pomme sip status ... --final-state previous --json --debug`
logged `recoveryBootVerified` before `navigationStarted`. It subsequently
verified Terminal and the bootstrap tool probe, authenticated the request-bound
one-shot Recovery agent on port `505053`, and returned verified SIP-enabled
status with exit 0. The finalized response proved share, launcher, credential,
and listener cleanup, sensitive-frame clearing, and final-state restoration.
The output digest was
`170c91ac20922977a98ac25692c35b71af831bfd4e81b1c33b6f0519cc9ae779`.
This was a read-only security query, not a SIP or AMFI mutation.

## Regression evidence

- Final Release test result: 428 tests passed, zero failed or skipped (446 executions
  when parameterized cases are expanded).
- Result bundle: `test_macos_2026-09-05T06-28-17-213Z_pid17305_6176fca4.xcresult`.
- New regressions prove each failed post-start check prevents launch, successful
  launch precedes authentication, and production startup cannot navigate.
- CLI integration suite against the installed signed executable: 15 passed.
- Mocked local build/install regression suite: 21 passed.
- Packaging identity validator tests and worktree identifier audit passed.
- `git diff --check` passed. No reachable-history audit or signed installer
  package qualification is claimed by these checks.

## Cleanup and limits

At 06:35:00 UTC, the VM was stopped, its helper was absent, and its original
provisioning plan and journal were retained. The 50 known temporary screenshots
and their private directory were deleted; no raw images entered the repository.
All source-editing leases were released.

This run does not qualify Sequoia, the 150-cycle host-state matrix, SIP/AMFI mutations,
MDM enrollment, interactive CLI PTY execution, or explicit identity overrides.
The current Darwin supplementary-group lookup can reject explicit UID/GID
overrides, including 0/0; default root execution works. The public interactive
PTY path and `ui ai settings` remain unavailable. Publication remains gated by
[the separate release qualification requirements](Qualification.md).
