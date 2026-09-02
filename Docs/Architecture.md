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

Recovery uses a distinct `PommeRecoverySession`. A session is request-bound,
temporary, and authenticated with an expiring one-shot credential. Recovery
listeners use ports `505052` and `505053` only for their documented bounded
roles. Session teardown removes the share, launcher, credential, listener, and
sensitive in-memory observations before the VM can transition to its requested
final state.

Both roles speak `PommeAgentProtocol` version 1. There is one authenticated,
chunked file path and one operation registry. Normal and Recovery capabilities
are explicit; callers must never infer authorization from the active boot mode.

The local CLI and VM helper speak `PommeControlProtocol` version 1 over a
bounded JSON-lines Unix socket under `/tmp/pomme-*.sock`. This protocol is
independently versioned from the guest protocol.

## Durable creation

Creation resolves the restore image and chooses an accepted Recovery profile
before producing any external effect. It then records an immutable plan and
journals intent before each phase:

1. install macOS and bind the VM, restore image, build, locale, display, and
   agent identities;
2. perform the required display-only first normal boot in a capability-gated
   supervisor/worker process group, prove descendant-liveness EOF, and exactly
   reap both owned children before constructing any Recovery `VZVirtualMachine`
   objects;
3. enter Recovery and install the signed persistent agent through the
   request-bound read-only VirtioFS bootstrap;
4. boot normal, authenticate, verify the executable digest and required
   capabilities; and
5. restore the requested `none`, `normal`, or `recovery` final state.

The development build wires steps 3–5 through the production request-bound
Recovery adapter. It remains pre-release until the live creation and Recovery
qualification matrices are complete; every unresolved phase still fails closed
and retains the VM and journal.

A failed phase preserves the VM and journal exactly as observed. Resume first
revalidates the immutable plan, ownership, digests, and pending intent; it does
not delete the VM or perform an unjournaled compensating boot.

Security policy is not changed by creation. SIP and AMFI are explicit
transactions performed only through an authenticated Recovery session. MDM
requires a verified normal-agent capability set. All workflows restore the
requested final run state and report an unknown state when restoration cannot
be proved.

## Recovery profile status

The selector recognizes these identities at the English `1280×800` geometry:

- macOS Tahoe `26.6.0`, build `25G72` is accepted;
- macOS Sequoia `15.6.1`, build `24G90` is a pending, fail-closed reference and
  emits no input.

Code recognition is not release acceptance. A profile also needs a reviewed
qualification record whose digest is configured by the protected release
environment. Unknown or pending builds, locale, geometry, host ABI, manifest
digest, or ownership evidence produce no input and fail before mutation.
