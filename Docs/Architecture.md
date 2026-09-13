# Pomme architecture

Pomme owns macOS virtual machines created in its private application-support
directory. It does not discover, read, or adopt machines owned by another
product. A bundle is considered Pomme-owned only when its immutable ownership
record, VM identifier, journal binding, and integrity reference all validate.

## Agent roles

Normal macOS runs one persistent `PommeAgent` from
`/usr/local/libexec/pomme`. Its launchd label is
`com.github.weswhet.pomme.agent`; its private credential is stored at
`/private/var/db/pomme/agent.token`. The host connects on VSOCK port `505051`.

The host keeps its copy of each persistent-agent credential in the user's
file-based login Keychain, using Apple's `Security.framework` with explicit
Keychain selection and a UUID-scoped service/account. Existing values are never
overwritten during provisioning; concurrent creation reuses the winning value.
The store requires an already-unlocked Keychain and does not read host passwords,
alter ACLs, migrate Data Protection items, or require Keychain entitlements.
Builds preserve Pomme's signing identity so authorized login-Keychain access can
remain valid across rebuilds.

Recovery uses a distinct `PommeRecoverySession`. Security sessions are
request-bound, temporary, and authenticated with an expiring one-shot
credential. Ordinary Recovery terminal admission uses the same short-lived
credential only until the terminal authority authenticates; afterward the
credential remains in memory for that Recovery boot so transient VSOCK
reconnects can reauthenticate. Recovery listeners use ports `505052` and
`505053` only for their documented bounded roles. Session teardown removes the
share, launcher, credential, listener, and sensitive in-memory observations
before the VM can transition to its requested final state.

Recovery staging keeps its request-bound `/private/var/tmp` spelling. Lexical
validation must not use Foundation's filesystem-aware URL standardization,
which can rewrite an existing `/private` path. File operations instead walk
directory descriptors with `O_NOFOLLOW`. Tahoe Recovery's root-owned
`/private -> System/Volumes/Data/private` link uses a root-relative target, not
an absolute one. The walker accepts only that literal target or its absolute
`/System/Volumes/Data/private` equivalent, with a stable checked link identity;
the fixed target components are then opened without following symlinks. Other
relative spellings, other targets, and nested symlinks remain rejected. Offline
fixtures reproduce this Recovery layout beneath a temporary root descriptor
without changing the host filesystem.

Both roles speak `PommeAgentProtocol` version 1. There is one authenticated,
chunked file path and one operation registry. Normal and Recovery capabilities
are explicit; callers must never infer authorization from the active boot mode.

## Durable terminal sessions

Normal macOS terminal sessions are owned by the helper's
`PommeDurableTerminalSessionManager`, scoped to the exact VM runtime and boot
generation. The manager does not hold the bundle mutation lease while a
session is attached. The persistent guest `PommeTerminalService` owns the PTY,
process group, and replayable guest spool; the helper appends raw bytes to a
private per-VM store and acknowledges guest offsets only after the append is
durable. Session metadata is atomic and symlink-resistant. A storage error
transitions the session to `storage-blocked` and preserves unread bytes.

Recovery terminal admission is a distinct terminal-only agent authority. Its
short-lived admission credential is consumed before the first authenticated
request, then remains only in memory for the current Recovery boot so a
transient VSOCK reconnect can reauthenticate. That authority rejects file
transfer, generic process, maintenance, SIP/AMFI, installation, and unrelated
terminal operations. Recovery PTY and transcript state is helper-scoped and
is discarded when the helper, agent, or Recovery boot ends.

Pause/resume leaves live sessions attached to the runtime. Stop, restart,
guest reboot, mode changes, snapshot restore, helper exit, and agent exit mark
sessions lost; normal raw transcripts remain available for inspection and
deletion. Active terminal sessions block Recovery security workflows until
they are terminated and cleanup is proven.

The local CLI and VM helper speak `PommeControlProtocol` version 1 over a
bounded JSON-lines Unix socket under `/tmp/pomme-*.sock`. This protocol is
independently versioned from the guest protocol.

## Direct display interaction

The helper routes `pomme ui key|key-sequence|type|click|screenshot` through
the VM's private Virtualization keyboard, pointer, and framebuffer interfaces.
These routes do not need a guest agent, OCR, a host window, or host event
injection. One helper UI operation may run at a time; the full input request is
validated before delivery. Numeric HID codes and separate key-down/up commands
are not public interfaces. Guided `ui ai` remains unavailable.

Automatic Recovery provisioning owns a separate exclusive runtime. Manual input
must not be mixed into its request-bound navigation. Recovery observation waits
through blank boot transitions, requires two matching fresh captures before
classification, and caches classifications for identical in-memory frames.
Uncached OCR is rate-limited; neither pixels nor OCR text enter diagnostics.
Only an expected checkpoint permits the next single receipted input. A selected
startup tile may be anchored by its geometrically associated Continue button
when OCR omits the low-contrast bottom power-action captions.

## Durable creation

Creation resolves the restore image and chooses either its reviewed Recovery
profile or an experimental attempt before producing any external effect. A new
OS build is not rejected merely for being unreviewed. It records an immutable plan and
journals intent before each phase:

1. install macOS and bind the VM, restore image, build, locale, display, and
   agent identities;
2. enter Recovery directly from the freshly installed image and install the
   signed persistent agent through the request-bound read-only VirtioFS
   bootstrap;
3. boot normal, authenticate, verify the executable digest and required
   capabilities; and
4. restore the requested `none`, `normal`, or `recovery` final state.

No normal boot precedes Recovery: a restored image boots into Recovery
directly, and the agent verification boot in step 3 is the guest's first
normal boot.

The development build wires steps 2–4 through the production request-bound
Recovery adapter. It remains pre-release until the live creation and Recovery
qualification matrices are complete; every unresolved phase still fails closed
and retains the VM and journal.

A failed phase preserves the VM and journal exactly as observed. Resume first
revalidates the immutable plan, ownership, digests, and pending intent; it does
not delete the VM or perform an unjournaled compensating boot.

Local signed builds retain verified executables in the append-only
`AgentArtifacts/sha256` store under Pomme's application-support directory.
Recovery installation can use the exact signed artifact pinned by the journal
after the host CLI is rebuilt. This does not rewrite the plan, substitute a
new agent digest, or relax guest staging verification. Earlier first-normal-boot
worker phases still require their original invoking executable.

Security policy is not changed by creation. Security workflows are state-first:
status and already-satisfied no-op paths do not request or transmit owner
passwords. SIP and AMFI are explicit transactions performed only through an
authenticated Recovery session. A successful transaction restores the
requested final state; a failed transaction restores the original captured
run state only when that state can be safely proved, otherwise the journal is
retained and restoration is reported incomplete. `--force` confirms the fresh
owner branch only and cannot override credentials, ownership, native login
protections, or cleanup barriers. MDM requires a verified normal-agent
capability set.

Freshness binds the exact native stock account name, numeric UID, and
GeneratedUID baseline; an unfamiliar record blocks a fresh-account decision.
Unknown OS versions remain guarded experimental identities when their exact
profile, ownership, and host checks pass. Native automatic-login refusals,
including Touch ID, Apple Pay, App Store, and related protections, are closed
login restrictions with no native-force override. Qualification of the actual
native automatic-login diagnostic remains pending.

## Recovery profile status

The existing Tahoe `26.6.0 (25G72)` profile remains reviewed. Other syntactically
valid restore versions/builds, including Sequoia, can be attempted experimentally
at English `1280×800`. Their deterministic profile descriptor is bound to the
actual restore identity and journal; they carry no claimed review digest.

Experimental attempts reuse the screen-observed navigation trace, with two stable
frames before and after every single input receipt. Unexpected screens or input
delivery uncertainty stop the attempt. Locale, geometry, private host ABI,
profile digest, ownership, session authentication, and launcher authorization
checks remain mandatory. Release qualification and protected publication gates
are separate from permission to try a new OS version.
