# Pomme protocol contracts

## PommeAgentProtocol 1

Every frame is one UTF-8 JSON object terminated by a newline. A frame is at
most 256 KiB. Requests contain `protocol`, `version`, `kind`, `requestID`,
`operation`, and `payload`. Responses repeat the request identifier and contain
`ok` plus exactly one of `result` or a redacted `error` object with `code` and
`message`.

Authentication is the first permitted operation. Challenge proofs use
HMAC-SHA256, constant-time comparison, expiry checks, and replay rejection.
Persistent credentials are reusable across connections; Recovery credentials
are one-shot and expire. A connection cannot authenticate twice.

Version 1 operations are capability-gated and include:

- `agent.describe`, `agent.health`;
- `process.start`, `process.status`, `process.signal`;
- `file.open`, `file.read`, `file.write`, `file.seek`, `file.flush`,
  `file.close`;
- `system.info`, `network.interfaces`, `remoteLogin.set`; and
- transactional maintenance activation, status, commit, and repair.

Stream frames remain correlated to the originating request and carry stdin,
stdout, stderr, EOF, terminal resize, signals, and process exit. Stream chunks
are at most 64 KiB. File chunks are at most 32 KiB. Partial mutation is terminal
for a transfer; callers do not retry an operation whose commit state is
unknown.

Process identity accepts at most one of user name or UID and at most one of
group name or GID. The agent resolves supplementary groups and drops group and
user privileges before `exec`. PTY jobs accept resize and signals, and detached
jobs remain addressable while the persistent daemon owns their records.

File writes use adjacent private staging, refuse symbolic-link traversal,
flush before commit, atomically publish the destination, and clean exact known
artifacts. Maintenance activation verifies the executable digest and journal;
ordinary operations remain blocked until an interrupted activation is resolved.

## PommeControlProtocol 1

The host control protocol uses the same 256 KiB JSON-lines bound and correlated
64 KiB stream chunks, but has its own envelope and operation registry. The
client validates helper identity using socket path, process identifier, and
start time. No earlier protocol version is accepted.
