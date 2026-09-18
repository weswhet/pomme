# Pomme protocol contracts

## PommeAgentProtocol 1

Every frame is one UTF-8 JSON object terminated by a newline. A frame is at
most 256 KiB. Requests contain `protocol`, `version`, `kind`, `requestID`,
`operation`, and `payload`. Responses repeat the request identifier and contain
`ok` plus exactly one of `result` or a redacted `error` object with `code` and
`message`.

Authentication is the first permitted operation. Challenge proofs use
HMAC-SHA256, constant-time comparison, expiry checks, and replay rejection.
Persistent credentials are reusable across connections; request-bound Recovery
security credentials are one-shot and expire. Ordinary Recovery terminal
admission credentials expire until first authentication, then remain only in
memory for that boot and can reauthenticate after a transient VSOCK loss. A
connection cannot authenticate twice.

Version 1 operations are capability-gated and include:

- `agent.describe`, `agent.health`;
- `process.start`, `process.status`, `process.signal`;
- `file.open`, `file.read`, `file.write`, `file.seek`, `file.flush`,
  `file.close`;
- `system.info`, `network.interfaces`, `remoteLogin.set`; and
- transactional maintenance activation, status, commit, and repair.

The additive terminal-session capability is advertised as
`terminalSessionVersion: 1`. It is separate from the bounded `process.*` job
table. The guest service accepts only `terminal.create`, `terminal.status`,
`terminal.read`, `terminal.ack`, `terminal.input`, `terminal.resize`,
`terminal.signal`, `terminal.terminate`, `terminal.release`, and paginated
`terminal.list`. Recovery's terminal authority advertises only
`agent.describe`, `agent.health`, and this terminal vocabulary.

### Request and stream exchange

Stream frames remain correlated to the originating request and carry stdin,
stdout, stderr, EOF, terminal resize, signals, and process exit. Stream chunks
are at most 64 KiB; file chunks are at most 32 KiB. For a successful process
request, output stream frames are written before the matching response. That
response is the completion delimiter, even when the request produced no
output.

An accepted input stream mutation (`stdin`, `eof`, resize, or signal) has its
own correlated response acknowledgement. The acknowledgement is sent after
the mutation and any resulting bounded output frames, including when there are
no output frames. Callers never retry a mutating operation when its outcome is
unknown; partial mutation is terminal for a transfer.

`process.start` is a launch acknowledgement, not a completion result. Its
result identifies the job and process and may report `exited: false`. A
foreground caller sends input in chunks no larger than 64 KiB, sends EOF, then
polls status while consuming output until the terminal exchange is complete.

A started process inherits the agent's environment with `HOME`, `USER`,
`LOGNAME`, and `SHELL` set from the passwd record of the account it runs as
(root unless a user or uid is requested). Values in the request's
`environment` take precedence. `PATH` is left as the agent's.

On each status/stream drain pass, the agent performs at most one nonblocking
read of up to 64 KiB from each stdout and stderr descriptor. EOF is established
by an observed read EOF (not merely by `POLLHUP`). The exit frame is emitted
only after the child has exited and every output descriptor has reached EOF, so
all output precedes the exit frame. Detached jobs remain addressable while the
persistent daemon owns their records.

### Foreground completion and CLI output

The CLI preserves stdout and stderr as separate channels and retains their
stream-frame order; it does not merge the channels or synthesize text. A
completed process reports either an exit code in `0...255` or a signal in
`1...127`. The host exit code for a signal is `128 + signal`. A foreground
timeout reports host exit `124`; cancellation reports host exit `130` only for
the foreground helper task, and neither is launch success.

The unary foreground helper buffers at most 64 KiB per stdout and stderr
channel. Channel truncation is reported and becomes a foreground failure. The
outer buffered CLI collector separately permits at most 16 MiB and 16,384
output frames; exceeding either bound is a reported failure rather than silent
truncation.

Interactive PTYs are durable terminal sessions. The host preallocates the
session UUID, sends a monotonically increasing mutation sequence and canonical
payload digest for every input, resize, signal, and termination, and treats an
exact retry as the same acknowledgement. Guest PTY bytes are continuously
drained into a private spool and replayed by byte offset until the host
transcript has appended and acknowledged them. Normal transcripts are private
per-VM records retained until `terminal.delete`; Recovery transcript bytes are
helper/boot scoped and are never persisted.

Process identity accepts at most one of user name or UID and at most one of
group name or GID. The agent attempts supplementary-group resolution and drops
group and user privileges before `exec`. On current Darwin, explicit UID/GID
overrides have a known limitation: the `getgrouplist(nil, count: 0)` sizing
path can leave the group count at zero, so overrides including UID 0/GID 0 may
fail; the default root path works. This protocol does not promise successful
overrides until that sizing issue is fixed.

File writes use adjacent private staging, refuse symbolic-link traversal,
flush before commit, atomically publish the destination, and clean exact known
artifacts. Maintenance activation verifies the executable digest and journal;
ordinary operations remain blocked until an interrupted activation is resolved.

## PommeControlProtocol 1

The host control protocol uses the same 256 KiB JSON-lines bound and correlated
64 KiB stream chunks, but has its own envelope and operation registry. The
client validates helper identity using socket path, process identifier, and
start time. No earlier protocol version is accepted.

A streaming control request has one request ID and an ordered sequence of
correlated stream frames followed by exactly one terminal response. The
terminal response is the completion delimiter, including for a silent command;
output frames must therefore be consumed before matching that response. Closing
the client input direction is a half-close, leaving the helper's output and
terminal response available. Mutating requests are sent once and are not
retried after an unknown outcome.

For buffered foreground execution, the host helper waits through the
process-start acknowledgement, polls and consumes output until terminal
completion, and then applies the CLI exit/output bounds above. The public
interactive PTY path uses the durable terminal-session engine instead. Its
attachment has no duration or idle deadline. A local TTY disconnect only
detaches; `~.` at the start of an input line detaches, while `~~` sends a
literal tilde. Attachments are exclusive unless takeover is requested, and
logs can replay any validated transcript byte offset.

### Stopping a VM

`stop` prefers a guest-driven shutdown. When the VM is running in normal boot
with the persistent agent connected, the host first asks the guest to run
`shutdown -h now`, then sends the framework stop; the framework's request
alone behaves like a power button that macOS may take a full minute to act on.
A paused VM is resumed first, because a paused guest can neither be asked to
shut down nor act on the framework's request; `--force` skips that. A stop
whose guest was asked to shut down carries `guestShutdownRequested` and gives
it `guestShutdownTimeoutSeconds` (120) to finish. Every other stop, including
one in Recovery, which never acts on the request, keeps
`gracefulStopTimeoutSeconds` (30): where nothing asked the guest to shut down,
the framework's request either lands quickly or not at all. Only after that
window does the helper stop the VM outright.

The lifecycle reply carries `changed` and, for a stop, `stopMethod`:
`guest-stopped` when the guest powered itself down, `forced` when the VM was
stopped outright, and `already-stopped` for a no-op. `pomme stop` reports a
forced stop in its own output rather than presenting it as a clean one, so an
unclean stop is never silent. `stop --force` asks for that outright stop
deliberately and always reports `forced`. `restart` ends on its boot line and
keeps a forced stop's line above it.

## Terminal-session control operations

`PommeControlProtocol` version 1 advertises the additive `terminalSessions`
feature. Its closed `terminal.session` registry contains `terminal.create`,
`terminal.list`, `terminal.inspect`, `terminal.attach`, `terminal.logs`,
`terminal.terminate`, and `terminal.delete`. Attach is a full-duplex control
stream; all setup and frame sizes remain bounded, but an admitted session is
not subject to a wall-clock or idle timeout. Storage failures report
`storage-blocked` and stop acknowledgements rather than truncating output.
