# Recovery navigation performance verification

The September 6, 2026 change speeds up the existing request-bound Recovery
navigation and bootstrap. It does not combine security sessions or change
SIP/AMFI policy operations.

## Implementation

| Work per 11-input navigation trace | Baseline | Updated |
| --- | ---: | ---: |
| Minimum physical framebuffer captures | 88 | 44 |
| Fixed navigation settling | 5 seconds | 0.8 seconds |
| Capability probe characters | 248 | 240 |
| Launcher characters | 224 | 212 |

The driver requests one explicit pair of fresh matching frames before and after
each input. The production port classifies matching pixel digests once, using
its existing classification cache; it does not reuse physical observations
across checkpoints. Cancellation remains checked around the pair requests.

OCR retry throttling is local to each checkpoint. A new checkpoint can classify
immediately after obtaining its stable pair, while unsuccessful OCR retries
within that checkpoint retain their two-second throttle. The eight inferred
focus transitions retain a 100 ms dwell; transitions to a different coarse
screen rely on their expected-screen observation deadline.

The capability probe uses fixed absolute command prefixes and preserves its
short-circuit executable checks and SHA-256 known-vector check. The launcher
uses relative paths only after entering its newly created private workspace.
The read-only mount, exact request tag, copied launcher, one-shot submission,
authentication, and cleanup requirements are unchanged. HID event dwell times
are unchanged.

## Builds and automated validation

- Baseline source: `8af2c87622c7522965d658017a7184aa0f4ed723`.
- Baseline executable SHA-256:
  `8dd368d7ba59b58c48d5f641c32df9f839cda295d9d4dc0d5332e9ba1cbe8756`.
- Updated executable SHA-256:
  `3b24ac3917ac3e7ce5943648b33f53012558e3ce6625f1c5de6c82a2b70baf51`.
- Both executables were built through XcodeBuildMCP using
  `Scripts/build-local.sh`, Release/arm64, the established Developer ID identity,
  Hardened Runtime, and only the Virtualization entitlement. Signature and
  designated-requirement checks passed. The updated executable was installed
  at `~/.local/bin/pomme`.
- The six focused Recovery interaction, readiness, bootstrap, profile, input
  budget, and integration test suites passed: 60 tests, zero failures or skips.
  The result bundle is
  `test_macos_2026-09-06T15-43-01-270Z_pid95438_4c62dc57.xcresult`.
- All 15 CLI contract checks passed against the updated signed executable.
- New launcher execution cases cover success, a pre-existing workspace,
  mount failure, and copy failure, including a workspace path containing spaces.

## Live comparison

The comparison uses the same newly created Tahoe 26.6.2 (`25G83`) VM,
`pomme-agent-recovery-speed-0906b`, with a 60 GB disk, 8 GB memory, English,
and a 1280 by 800 display. Each measured operation starts stopped and runs
`sip status --final-state previous --json --debug`. This exercises Recovery
navigation, capability proof, launcher submission, authenticated security
status, cleanup, and final-state restoration without changing security policy.

The measurement harness timestamps stderr lines from the signed executable
directly with a monotonic clock. Compilation and tests are quiescent during
measurements. No raw frames or OCR text are retained in this report.

| Trial order | Build | Navigation to Terminal | Complete operation | Result |
| --- | --- | ---: | ---: | --- |
| 1 | Baseline | 112.629 s | 227.993 s | Success; restored stopped |
| 2 | Updated | 100.686 s | 217.658 s | Success; restored stopped |
| 3 | Baseline | 113.931 s | 234.218 s | Success; restored stopped |
| 4 | Updated | 99.345 s | 214.548 s | Success; restored stopped |

Across two runs per build, navigation averaged **113.280 seconds before** and
**100.015 seconds after**, a reduction of **13.265 seconds (11.7%)**. The complete
operation averaged **231.106 seconds before** and **216.103 seconds after**, a
reduction of **15.003 seconds (6.5%)**. Both updated navigation measurements were
faster than either baseline measurement. Individual typing and completion
timings varied; this comparison does not isolate the contribution of each code
change or establish performance on other host/guest builds.

All four results reported authenticated, request-bound, consumed credentials
and a finalized Recovery lifecycle. Every cleanup flag and final-state proof
was true, and the returned SIP status remained verified and enabled. The
successful test VM was deleted after the final stopped-state proof, with its
VM-scoped credential removed. Its known temporary timing/log artifacts were
removed individually. The pre-existing `doitlive` VM was not operated.

The first fixture, `pomme-agent-recovery-speed-0906`, was mistakenly created
with a 25 GB disk. It failed installation at 78%, including one resume attempt,
before any navigation measurement. Its failed VM and journal are retained;
its results are excluded from the comparison. The replacement fixture completed
installation and provisioning with 60 GB.
The signed baseline executable remains at
`/private/tmp/pomme-recovery-speed-baseline-bin-0906/pomme` so the failed
fixture's early provisioning phase can retain its original invoking executable.

Future disposable test VMs use 40 GB disks and 4 GB RAM, as recorded in
`AGENTS.md`. This active comparison keeps its original resources throughout.
