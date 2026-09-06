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
whole-frame hashing, classification, Vision recognition, input, and explicit
waits. Classification time includes OCR and regional hashing; input time
includes its settling waits. These inclusive durations must not be summed.
Region cache hits and full-frame fallback counts contain no screen text.

## Verification

Baseline executable SHA-256:
`3b24ac3917ac3e7ce5943648b33f53012558e3ce6625f1c5de6c82a2b70baf51`.

Live comparison and automated validation results are pending.
