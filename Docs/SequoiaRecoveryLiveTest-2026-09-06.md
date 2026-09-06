# Sequoia Recovery live test

The user requested a live test on the latest macOS 15. Apple's current
[security release list](https://support.apple.com/en-asia/100100) lists
15.7.9, released August 6, 2026. Pomme's live signed IPSW catalog instead
tops out at **15.6.1 (`24G90`)** for Sequoia. This test uses that newest
available restore image; it does not qualify 15.7.9.

Pomme currently derives Recovery profile evidence from the immutable restore
plan. An unmanaged guest update would leave that evidence on the original
build. A 15.7.9 test therefore needs an upgrade/version-observation path before
it can truthfully qualify automated Recovery on that build.

## Fixture

- Disposable VM: `pomme-agent-sequoia-latest-0906`.
- VM UUID: `acb13752-fe5d-4e5a-9243-337960bc5b80`.
- Resources: 40 GB disk, 4 GB RAM; requested final state `none`.
- Restore: 15.6.1 (`24G90`), downloaded from Apple's restore CDN.
- Host source: `0c4003f`; executable source: `e656586`.
- Signed Release executable SHA-256:
  `fce77dcf695b6740c8da395bc213b4ead347707e427bd1cb4167acc545567022`.
- Signature and established Developer ID designated requirement verified.
- Sequoia remains an experimental profile. The production selector uses the
  existing eleven-key menu route; the direct five-key shortcut is not enabled
  for this build.

## Results

Installation and the display-only first normal boot completed. Creation's
Recovery navigation reached Terminal in **38.195 seconds**, using eleven
inputs. Its capability probe and final creation verification succeeded, and
the VM returned to stopped with no helper. Including the fresh IPSW download,
creation completed in 1,204.190 seconds.

Navigation metrics reported 74 captures (20.404 s), 17 classifications
(3.889 s), 37 OCR requests (3.777 s), eleven inputs (3.633 s), 60 waits
(11.434 s), 26 region cache hits, and seven full-frame fallback/initialization
passes. Classification includes OCR, and input includes settling waits; these
inclusive durations must not be summed.

The separate `sip status --final-state previous --json --debug` operation
completed in **166.061 seconds**, with **33.986 seconds** of navigation. It
verified enabled SIP, authenticated Recovery, successful cleanup, and
restoration to stopped state with no helper. It made no SIP or AMFI changes.
This navigation used 67 captures (18.418 s), 28 OCR requests (3.029 s), eleven
inputs (3.987 s), and 53 waits (9.806 s).

The manual **Right, Right, Return, Return, Shift–Command–T** shortcut check
also succeeded on 15.6.1 (`24G90`). It opened Terminal from Recovery utilities
and showed a shell prompt. Every event had two fresh stable captures before
and after delivery. The operator waited through the Recovery boot transition
until the language picker was actually visible before sending the next key.
This is live evidence for the direct shortcut; the production Sequoia route
was not changed by this test.

## Cleanup

The successful disposable VM, its exact UUID-scoped agent-token Keychain item,
and individually known screenshots, logs, and harness files were removed.
The empty lab temporary directory was removed. Final inventory contains only
the untouched stopped `doitlive` and pre-existing failed
`pomme-agent-recovery-speed-0906` fixture. The downloaded restore image remains
in Pomme's normal restore cache for reuse. No production source changed.
