# PTY execution returns `OK` but drops child output

- **Severity:** High
- **Status:** Resolved (2026-09-08)
- **Area:** `exec --pty` and the implicit PTY used by bare `shell`
- **Observed on:** Pomme 0.1.0 signed Release build; normal Sequoia 15.6.1 / 24G90 VM

## Reproduction

With a real interactive terminal:

```text
rtk pomme exec pomme-agent-cli-sequoia-0907 --pty --timeout 5 --format raw -- /bin/sh -c 'printf pty-marker; exit'
```

Observed result:

```text
exit=0
OK
```

The expected `pty-marker` bytes were absent. A bare interactive `pomme shell` probe showed the same `OK` response without the child’s marker.

## Expected result

PTY stdout and stderr should contain the child’s terminal output, including output written before exit.

## Impact

Interactive guest commands appear to succeed while their output is unavailable to the caller. This affects both explicit PTY execution and the bare-shell mode that implicitly requests a PTY.

## Source evidence

The original public CLI PTY branch sends a one-shot process request; the guest agent creates a PTY master and drains it through `streamEvents`. The reproduced command satisfies the documented TTY and format requirements and still loses the child output. `PommePrivatePTYRunner` is the separate password-gated security workflow, not the public terminal path.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/GuestCommands.swift`
- `Sources/PommeCLI/GuestAgent/PommePrivatePTYRunner.swift`
- `Sources/PommeCLI/GuestInternal/PommeAgent.swift`


## Confirmed cause (2026-09-08)

The public `PommeApplication.foregroundCommand` PTY branch uses a one-shot
`sendControlObject` call. It neither attaches terminal input nor owns polling
through child exit and output EOF. The generic control stream path also waits
for input before fetching guest output. `PommePrivatePTYRunner` serves the
separate password-gated security workflow; it is not the public terminal runner.
The guest already exposes PTY output through correlated `streamEvents` frames.

Live interrupt verification exposed a second defect: spawned commands inherit
the persistent daemon's ignored SIGINT disposition. Both PTY and non-PTY shells
ignored a self-delivered SIGINT even after installing a trap. A readiness-gated
terminal probe confirmed this was independent of early host input. Child spawn
attributes must reset SIGINT to its default disposition and unblock signals.

The correction must keep a public terminal session attached, forward output
without requiring input, preserve output written before exit, and return the
child's exit status for both explicit PTY execution and implicit bare shell.

## Implementation

Public `exec --pty` and implicit bare `shell` now use an authenticated terminal
stream. The helper forwards output from the initial exchange and polls guest
status independently of terminal input, continuing until both process exit and
output EOF are observed. The CLI writes exact output bytes, forwards input,
Ctrl-C and terminal dimensions, restores the host terminal settings, and returns
the child's exit status without printing a synthetic `OK`.

Spawn attributes reset inherited SIGINT-ignore state and use an empty child
signal mask, for both PTY and non-PTY commands. The existing session/process
group setup is preserved, including execution through the identity helper.

Public echo is explicitly negotiated through an `agent.describe` request with
`includePublicPTYCapabilities: true` and its `publicPTYEchoVersion: 1` response,
`process.start`'s `ptyEcho: true`, and the
`ptyEchoDisabled: false` start receipt. An older agent without this capability
is rejected before process launch. Private password PTYs retain their default
no-echo policy. Existing guests need an agent build with this new capability.

Control polling retains partial JSONL frames across idle polls and consumes
already-buffered frames without waiting for another socket read. Stream setup
has a bounded handshake. A host timeout reports exit 124 even when its
cancellation reaches the helper before the helper's own deadline; a missing
completion response has a bounded three-second grace period before the host
restores its terminal and reports failure.

Timeout/cancellation requests termination, but does not claim that the child
exited or that all output was drained. The result retains the job identity and
completion evidence for inspection. Normal completion requires both guest exit
status and the output-end frame.

## Automated verification (2026-09-08)

- All 65 focused Debug tests passed, including public relay/control polling,
  byte-exact host terminal output and restoration, input/resize/interrupt
  forwarding, timeout mapping, guest output larger than 64 KiB, public echo,
  private password PTY protection, child signal attributes for both launch
  modes, and the strict MDM description parser.
- Real socket-daemon tests run serially: concurrent blocking descriptor reads
  otherwise exhausted Swift's cooperative worker pool. A sampled stalled test
  run established that cause; serialization preserves all exchange assertions.
- Canonical signed Release build and exact signing/entitlement checks passed.
  Final host executable SHA-256:
  `e1890913cc76afc0b4140195773fe6517b0f519af942456c1bb710cff45bf738`.
- All 22 CLI integration checks passed against that installed executable.

```sh
rtk xcodebuildmcp macos test --project-path pomme.xcodeproj --scheme pomme --configuration Debug --derived-data-path /tmp/pomme-public-pty --extra-args=-only-testing:PommeCLITests/PommePublicPTYRelayTests -only-testing:PommeCLITests/PommePublicPTYTerminalBridgeTests -only-testing:PommeCLITests/PommeAgentProcessExchangeTests -only-testing:PommeCLITests/PommeAgentPTYTests -only-testing:PommeCLITests/PommeAgentTests -only-testing:PommeCLITests/PommePrivatePTYRunnerTests -only-testing:PommeCLITests/PommeForegroundControlTests -only-testing:PommeCLITests/ControlWireTests --output text --verbose
rtk proxy bash Scripts/build-local.sh
rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build
```

## Live verification (2026-09-08)

Fresh disposable VM `pomme-agent-pty-0908-8f3c2a`
(`7043c2b2-57dd-481a-8309-64a3a0c238b6`) was created successfully with
Tahoe 26.6.0 / 25G72, a 40 GB disk, 4 GB memory, and the final signed executable
above pinned as its guest agent. The earlier SIGINT reproduction used the same
OS and resources. No guest binary, journal digest, or credential was manually
replaced during validation.

The VM was started normally after creation. Both the running helper and the
authenticated guest matched the final executable digest; the public capability
receipt reported version 1. Shell self-SIGINT probes now returned their trap
marker and exit 130 in both PTY and non-PTY modes.

The real host pseudo-terminal matrix passed:

| Check | Result |
| --- | --- |
| Output followed by exit 7 | Exact 11-byte marker; host exit 7 |
| Output larger than a stream frame | Exact 70,000 zero bytes plus 15-byte marker; exit 0 |
| Terminal input and echo | Expected input marker; exit 0 |
| Timeout | Start marker received; host exit 124 |
| Ctrl-C after guest readiness marker | Interrupt trap marker received; host exit 130 |
| Bare shell | Split-literal command produced the expected marker; exit 0 |

Every case restored host terminal flags, control characters, and speeds. The
comparison normalizes only Darwin's `PENDIN` pending-input state bit. Ctrl-C
input waits for a guest readiness marker so host startup cannot consume it
before terminal raw mode is active. The bare-shell marker is assembled by the
guest, preventing echoed input from falsely satisfying the output assertion.

The final test VM was stopped normally and verified with no running helper.
Both PTY lab VMs and their pinned journals were retained; the six known local
synthetic test artifacts and their empty temporary directory were removed.
