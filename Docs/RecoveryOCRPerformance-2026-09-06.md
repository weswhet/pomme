# Recovery OCR performance verification

This follow-up compares against `ebaf65c`, using a new disposable Tahoe
26.6.2 (`25G83`) VM with a 40 GB disk and 4 GB RAM.

## Implementation

The experimental 26.6.2 / `25G83` route uses five inputs:
Right, Right, Return, Return, Shift–Command–T. A manual run verified two fresh
stable screenshots around every event, including Terminal appearing directly
from Recovery utilities. Other build selections keep the eleven-input menu
route. The tested route reduces the minimum physical captures from 44 to 20
and fixed navigation settling from 0.8 to 0.2 seconds.

Navigation starts with accurate full-frame OCR. Subsequent classifications
reuse OCR text only for horizontal regions whose pixel digests are unchanged.
The regions overlap and cover the entire display. Unknown classifications,
conflicts, and ambiguous crop boundaries fall back to accurate full-frame OCR.
Each input still requires two fresh matching captures before delivery, one
receipt, and two fresh matching captures afterward. Cached OCR is cleared
before launcher authorization.

Terminal capability proof retains full-frame accurate OCR, with the existing
scaled crop as a fallback. Crop-only acceptance was rejected during review
because it could hide a conflicting dialog outside the Terminal window.

The port emits cumulative numeric counters and monotonic durations for capture,
whole-frame hashing, classification, Vision recognition, navigation input, and
explicit waits. Classification time includes OCR and regional hashing;
navigation input time includes its settling waits. Terminal typing is not
included in the input counter. These inclusive durations must not be summed.
Region cache hits and full-frame fallback counts contain no screen text.

## Verification

Baseline executable SHA-256:
`3b24ac3917ac3e7ce5943648b33f53012558e3ce6625f1c5de6c82a2b70baf51`.

Updated source: `e656586`.
Updated executable SHA-256:
`fce77dcf695b6740c8da395bc213b4ead347707e427bd1cb4167acc545567022`.

The signed Release/arm64 build completed through `Scripts/build-local.sh` and
XcodeBuildMCP. Signature, exact entitlements, designated-requirement continuity,
and atomic installation checks passed. All 78 focused Recovery tests passed,
with zero failures or skips, and all 15 CLI contract checks passed.
The test result bundle is
`test_macos_2026-09-06T16-49-15-111Z_pid31109_4d1ac3c6.xcresult`.

## Live comparison

The disposable VM is `pomme-agent-ocr-speed-0906`, UUID
`2405f796-25b4-4c66-96ca-cbf089bd030f`. Each trial uses
`sip status --final-state previous --json --debug`, starting stopped, to
exercise authenticated status, navigation, capability proof, launcher
submission, cleanup, and restoration without changing security policy.
The harness timestamps the signed executable's output directly using a
monotonic clock. Builds and tests are quiescent during measurement.

| Trial order | Build | Navigation to Terminal | Complete operation | Result |
| --- | --- | ---: | ---: | --- |
| 1 | Baseline | 98.650 s | 241.152 s | Success; restored stopped |
| 2 | Updated | 89.627 s | 209.916 s | Success; restored stopped |
| 3 | Baseline | 96.665 s | 219.633 s | Success; restored stopped |
| 4 | Updated | 89.406 s | 220.184 s | Success; restored stopped |

Navigation averaged **97.6575 s before** and **89.5165 s after**, a reduction
of **8.141 s (8.3%)**. Both updated runs reached Terminal faster than either
baseline run. Two runs per executable on one host/guest identity establish a
local comparison, not performance qualification for other builds. The
comparison combines route and OCR changes and does not isolate each one's
contribution.

The first updated navigation reported 223 captures (41.545 s), 14
classifications (3.181 s), 36 Vision requests (3.064 s), five inputs (1.303 s),
215 explicit waits (42.747 s), 17 regional cache hits, and nine full-frame
fallback/initialization passes. OCR accounted for about 3.4% of navigation
time. The measured physical capture count includes boot/transient/stability
polling beyond the minimum twenty event-boundary captures.

The second updated navigation reported 222 captures (41.046 s), 222
whole-frame hashes (1.231 s), 15 classifications (2.989 s), 38 Vision
requests (2.852 s), five inputs (1.329 s), 214 waits (43.150 s), 20 region
cache hits, and ten full-frame fallback/initialization passes. Across both
updated runs, OCR averaged 2.958 s, about 3.3% of navigation. Capture and
stability waiting dominate the remaining measured time; eliminating more OCR
alone therefore has limited headroom on this host.

The interval before navigation also varied: 30.620 s on baseline trial 1 and
0.316 s on updated trial 1. Complete-operation differences therefore cannot
be attributed entirely to the navigation changes.
The second baseline's pre-navigation interval was 0.291 s and the second
updated run's was 0.295 s.
End-to-end speed was not consistently better: the final updated operation was
0.551 s slower than the second baseline despite its faster navigation. The
observed repeatable improvement is in navigation; typing and other transaction
phases remain variable.

All four operations returned verified enabled SIP status, authenticated
request-bound credentials, finalized lifecycle, successful cleanup flags, and
verified restoration. Each trial independently verified stopped state with no
helper before the next trial. The test did not change SIP or AMFI policy.

After the successful comparison, the disposable VM and its exact agent-token
Keychain item were deleted. Known screenshots and timing/harness artifacts
were removed individually, followed by the empty temporary directory. The
temporary baseline copy was removed; verified signed builds remain in the
append-only agent artifact store. Final inventory retained only the untouched
stopped `doitlive` and the pre-existing failed
`pomme-agent-recovery-speed-0906` fixture.
