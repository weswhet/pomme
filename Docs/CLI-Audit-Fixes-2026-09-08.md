# CLI audit fixes — 2026-09-08

Follow-up to `CLI-Audit-2026-09-08.md`. Each issue is validated with a signed
Release CLI and live commands, then committed before work on the next issue.

## 1. Background job wait exit status

The control boundary converts JSON integers to Swift `Int64`. The waiter used
an `as? Int` cast and therefore rejected completed jobs whose exit status was
present. It now decodes the JSON integer before narrowing and checking its
range. The same correction applies to signal termination.

The regression fixtures use the transport's actual `Int64` representation;
the prior waiter fails against those fixtures. Tests also reject Boolean,
fractional, string, and out-of-range completion codes.

Validation:

- XcodeBuildMCP: all 17 `PommeGuestJobWaitTests` and
  `PommeAgentProcessExchangeTests` passed.
- `Scripts/build-local.sh`: signed Release build installed with the required
  Developer ID, team, identifier, Hardened Runtime, exact Virtualization
  entitlement, and compatible designated requirement.
- Fixed executable SHA-256:
  `af52e86f538f64c56f6b1ccb870dcf2b88ee7a91c02d74fb4c3b6780c787da65`.
- All 47 CLI integration checks and all 21 local installer checks passed.
- Live comparison uses the disposable 40GB/4GB Tahoe 26.6.0 (25G72) VM
  `pomme-agent-auditfix-0908-c19f2a`, with the original guest agent retained.
  The archived baseline CLI (`7043bcc6221ff280da89a37dd91f474987b37f8cc1e1e4a24d5ed06e8d8b24fd`)
  reproduced the exact missing-exit-status failure for a completed detached job.
  The fixed CLI passed all of these live cases:

  | Command scenario | Observed result |
  | --- | --- |
  | Detached job exits successfully | CLI exit 0, `exitCode: 0`, expected stdout |
  | Detached job exits 7 | CLI exit 7, `hostExitCode: 7`, `exitCode: 7` |
  | Wait after inspect proves job already exited | CLI exit 0 and retained stdout |
  | Wait for a 30-second job with `--timeout 0.2` | CLI exit 124, `timedOut: true`; inspect proves job still running |
  | Wait again for the timed-out job | CLI exit 0 and expected stdout; job was not cancelled |
  | `jobs kill --signal TERM`, then wait | CLI exit 143, `signal: 15`, `timedOut: false` |
