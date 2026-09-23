# Background job list, logs, and wait operations are unsupported

- **Severity:** High
- **Status:** Resolved (2026-09-08)
- **Area:** `jobs`
- **Observed on:** Pomme 0.1.0 signed Release build; normal Tahoe VM

## Reproduction

A detached execution created job `e4ddb05e-89d5-4384-b1e8-d38062cbda3c` successfully:

```text
rtk pomme exec pomme-agent-cli-tahoe-0907 --detach --format json -- /bin/sh -c 'sleep 3; echo detached-done'
```

Inspection succeeded and later reported `exited: true`, `exitCode: 0`, and the `detached-done` stream frame. The following commands then failed:

```text
rtk pomme jobs list pomme-agent-cli-tahoe-0907 --format json
rtk pomme jobs logs pomme-agent-cli-tahoe-0907 e4ddb05e-89d5-4384-b1e8-d38062cbda3c --format json
rtk pomme jobs wait pomme-agent-cli-tahoe-0907 e4ddb05e-89d5-4384-b1e8-d38062cbda3c --format json
```

Each exited 1 with `Pomme agent request failed (unsupported-operation)`. `jobs kill` accepted TERM, KILL, INT, and HUP for live jobs and returned `signalled: true`; invalid signals were rejected as expected.

## Expected result

Every advertised job subcommand should work for a job created by `exec --detach` or `shell --detach`. `list`, `logs`, and `wait` should expose the same job state and output that `inspect` can observe.

## Impact

Detached work can be started and signalled, but callers cannot enumerate it, retrieve its output through `jobs logs`, or wait for completion through the public job API.

## Original source evidence

The normal agent dispatch implements `process.start`, `process.status`, and `process.signal`. The CLI job commands send separate job-list, job-output, and job-wait requests, for which the agent has no corresponding dispatch cases.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/GuestCommands.swift`
- `Sources/PommeCLI/GuestInternal/PommeAgent.swift`

## Implementation

The normal agent implements `process.list`, `process.output`, and `process.wait`.
List refreshes detached jobs and returns their state. Output retrieves retained
stdout and stderr without consuming them, so `jobs inspect`, `jobs list`, and a
previous `jobs logs` do not erase the next log snapshot.

Detached jobs retain the last 64 KiB of each output channel in memory. Responses
include total byte counts and explicit truncation flags; text output reports
truncation. Job records and logs do not survive an agent restart. Listing returns
at most 256 entries and reports when the list is truncated.

Public `jobs wait` polls short status requests until the child exits and its output
reaches EOF, then fetches its retained logs once. It releases both the VM mutation
lease and the serial guest connection between polls, allowing other commands to
signal the job. Lease contention is retried within the remaining time. A single
host deadline covers polling and control-socket I/O, including partial responses;
timeout returns
124 without signalling the target. Completion propagates the child exit code,
or 128 plus its terminating signal.

The default text and raw representations print log bytes to the correct stdout
and stderr descriptors, without a synthetic `OK` or an extra newline. JSON and
JSONL retain the structured metadata and correlated stream frames. Text listings
show job IDs, PIDs, and state.

The async wait entry point preserves the normal agent's activation-pending gate:
an unresolved agent update still rejects ordinary process operations.

## Verification

An expanded Xcode Debug run passed 42 tests, with no failures or skips,
across `PommeAgentProcessExchangeTests`, `PommeGuestJobWaitTests`,
`PommeAgentTests`, `ControlWireTests`, and `PommeAgentExecutionOptionsTests`.
After the final activation-gate fix, the 25-test jobs, host-wait, and agent subset
passed again, including the extended recovered-journal regression.

Current native command equivalents (the results above are historical):

```text
rtk proxy xcodebuild test CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS' -project pomme.xcodeproj -scheme pomme -configuration Debug -derivedDataPath /tmp/pomme-jobs-debug-final -only-testing:PommeCLITests/PommeAgentProcessExchangeTests -only-testing:PommeCLITests/PommeGuestJobWaitTests -only-testing:PommeCLITests/PommeAgentTests -only-testing:PommeCLITests/ControlWireTests -only-testing:PommeCLITests/PommeAgentExecutionOptionsTests
rtk proxy xcodebuild test CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS' -project pomme.xcodeproj -scheme pomme -configuration Debug -derivedDataPath /tmp/pomme-jobs-activation -only-testing:PommeCLITests/PommeAgentTests -only-testing:PommeCLITests/PommeAgentProcessExchangeTests -only-testing:PommeCLITests/PommeGuestJobWaitTests
rtk proxy bash Scripts/build-local.sh
rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build
```

Authenticated socket-backed daemon tests launch actual detached processes and
verify enumeration, repeated output after status reads, completion, nonzero exit,
unknown IDs, timeout without termination, output larger than pipe capacity, and
bounded retained tails with explicit truncation. Host regressions verify that
wait releases exchanges between polls, waits through output EOF, fetches logs
once, preserves binary stdout/stderr, propagates exit/signal status, and handles
fractional timeouts and lease contention. Real socket tests cover an incomplete
JSONL frame and a delayed host-control response.

The canonical signed Release build passed signature, designated-requirement,
and entitlement verification. Its SHA-256 is
`5ae21208a40c251e47a334b4cde76a5943d3d8afe44b541a683917fff913cf89`.
All 22 CLI contract checks passed against the installed executable; a fresh login
shell resolves `pomme` to `~/.local/bin/pomme`.

No live VM was changed for this issue. The tests exercise the authenticated guest
daemon on macOS with isolated sockets and test credentials. Both retained lab VMs
remain stopped with their earlier pinned guest builds; these new operations were
not installed into them.
