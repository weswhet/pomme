# Pomme

Pomme is a private, Apple-silicon macOS virtual-machine CLI built with Swift
and Virtualization.framework. It owns only machines created in
`~/Library/Application Support/pomme`; it does not inspect or migrate machines,
credentials, sockets, or services owned by another product.

The project is pre-release at version `0.1.0`. Publication is disabled pending
the reviewed qualification described in [Docs/Qualification.md](Docs/Qualification.md).

## Build and test

A full Xcode installation and the configured Developer ID certificate are
required for the credential-bearing CLI. Build, sign, verify, and install it
consistently to `~/.local/bin/pomme`:

```sh
rtk proxy bash Scripts/build-local.sh
```

Run isolated offline tests without accessing real VM credentials:

```sh
rtk xcodebuildmcp macos test \
  --project-path pomme.xcodeproj \
  --scheme pomme \
  --configuration Release \
  --extra-args CODE_SIGNING_ALLOWED=NO \
  --output text
```

The package installs the host executable at `/usr/local/bin/pomme`. The guest
service executable is `/usr/local/libexec/pomme`, its launchd label is
`com.github.weswhet.pomme.agent`, and its private credential is
`/private/var/db/pomme/agent.token`.

## Commands

VM names are positional. `POMME_VM_NAME` can supply an omitted target; Pomme
never chooses a machine merely because it is the only running one.

```text
create, list|ls, start, stop, restart, pause, resume, delete|rm,
status, inspect, exec, shell, sessions, jobs, cp, cat, agent, sip, amfi,
mdm, remote-login, screen-sharing, snapshot, template, config, ipsw, ui, tui
```

Create is a durable provisioning workflow, not only an installation command:

```sh
pomme create dev --latest                 # installs, verifies the agent, leaves it running
pomme create dev --version 26.6.0 --shutdown
pomme create dev --latest --recovery
pomme create dev --resume
```

Before creating anything, Pomme resolves and verifies the restore-image build,
English locale, `1280×800` display geometry, closed Recovery profile, and
immutable agent identity. It installs macOS, boots straight into Recovery to
install the signed persistent agent, verifies the normal agent, and restores
`none`, `normal`, or `recovery` as requested. SIP and AMFI are never changed
by creation.

The restore is the slow part (about four minutes for a 20 GB image). Do it
once into a template, then clone:

```sh
pomme template create base --latest --disk-size 40GB
pomme create dev --from-template base --memory 4GB
pomme template list
```

Every create path, `--dry-run` included, requires at least 4 GiB of guest
memory; when the restore image is already local the image's own minimum is
applied as well.

A template holds only the restored disk image, auxiliary storage, and
hardware model. `--from-template` clones them copy-on-write (APFS) under a
fresh machine identifier and UUID and then runs the same journaled Recovery
bootstrap and verification, so a VM is ready in roughly two and a half
minutes instead of seven. Every VM cloned from a template inherits its disk
size.

Creating the owner account an authenticated workflow needs is the other slow
step, and it can be captured into the template too:

```sh
pomme template create mdm-ready --latest --disk-size 40GB --provisioned
pomme create lab --from-template mdm-ready
pomme mdm lab --profile enroll.mobileconfig
```

`--provisioned` builds a disposable VM, prepares the `pomme` owner with
persistent automatic login, restores System Integrity Protection, and captures
that state. A VM cloned from it can run MDM enrollment as its first command
instead of creating an owner first. `pomme template list` shows which
templates carry an owner.

The owner's password is never printed and is not stored in the template. Each
clone gets its own VM UUID, so the host Keychain item from the VM the template
was captured from cannot follow it; instead the root agent recovers the
password from that guest's own `/etc/kcpassword` and the host adopts it for the
clone after proving the account's administrator membership, Secure Token, and
APFS ownership. Nothing has to know the password, including you.

Creation ends with the VM booted normally and its agent verified — the same
boot that proved the agent — unless `--shutdown` or `--recovery` (or
`--boot none|recovery`, or `boot:` in a config) asks for another state.

The `0.1.0` development build includes the request-bound production Recovery
bootstrap adapter. The workflow above remains pre-release: publication stays
disabled until live creation, Recovery security, MDM, and the qualification
matrix have been independently completed and reviewed.

If creation stops after an external effect, Pomme preserves the exact VM and
journal. `--resume` revalidates the immutable plan and continues from the first
unresolved intent. Resume accepts only its target and output/debug options.
The local build script retains signed agent artifacts by SHA-256. Recovery
installation after a host rebuild uses the original pinned artifact, not a
replacement digest; missing or altered artifacts fail closed.

Config-driven creation supports JSON, YAML, TOML, and Pkl. Every member is
profile-qualified during whole-batch preflight. After execution begins,
successful siblings remain when another member fails.

## Guest agent

Normal macOS runs the persistent `PommeAgent`; Recovery uses a distinct,
temporary `PommeRecoverySession`. Both speak the authenticated
`PommeAgentProtocol` version 1 described in
[Docs/Protocols.md](Docs/Protocols.md). The host helper independently speaks
`PommeControlProtocol` version 1.

```sh
pomme agent status dev
pomme agent repair dev --final-state previous
```

Repair is Recovery-only. Agent status reports a closed `guestAgent` object with
connection state, `normal` or `recovery` role, protocol version, executable
digest, capabilities, and update state.

Guest process and file examples:

```sh
pomme exec dev -- /usr/bin/sw_vers
pomme shell dev
pomme shell dev --detach
pomme exec dev --pty --user alice -- /bin/zsh
pomme exec dev --pty --detach -- /usr/bin/top
pomme sessions list dev
pomme sessions attach dev SESSION_ID --takeover
pomme sessions logs dev SESSION_ID --follow
pomme sessions terminate dev SESSION_ID
pomme sessions delete dev SESSION_ID
pomme exec dev --detach -- /usr/bin/sleep 30
pomme jobs list dev
pomme cp ./input dev:/tmp/input
pomme cat dev:/tmp/input
```

Process streams, terminal resize, signals, jobs, and file handles are correlated
and bounded. Bare `shell` and `exec --pty` create durable reconnectable
sessions; `shell [expression]` remains the one-shot `/bin/sh -c` workflow.
Guest processes get `HOME`, `USER`, `LOGNAME`, and `SHELL` for the account they
run as (root by default, or `--user`); `--env` overrides them.
Interactive attachments require local TTYs, reject JSON output, and detach on
socket loss without signalling the guest. File transfer is authenticated and chunked, stages adjacent to its
destination, refuses symbolic-link traversal, and commits atomically.

## Direct guest display input

The helper delivers UI input directly through the VM's private Virtualization
keyboard/pointer interfaces and captures its framebuffer without a host window.
These operations work in normal macOS and Recovery without a guest agent:

The following illustrate input syntax, not a complete Recovery navigation sequence.

```sh
pomme start dev --mode recovery
pomme ui key dev ctrl-f2
pomme ui key dev cmd+shift+t
pomme ui key-sequence dev left right
pomme ui type dev --text '/usr/bin/id -u'
pomme ui key dev return
pomme ui keys
```

`pomme ui keys` lists the named keys, modifier prefixes, and aliases that `ui key`
and `ui key-sequence` accept.

Observe the guest with `pomme ui screenshot dev --output /absolute/private/path.png`.
Keep Recovery screenshots in a private temporary lab directory, outside the
repository. Named navigation/function keys and modifier combinations are
supported; numeric HID scan codes are not exposed. Requests do not move the host
pointer or change its frontmost app. `ui ai` remains unavailable. Automatic
provisioning owns an exclusive VM lease; do not mix manual input into it.

## Security and access

SIP and AMFI LocalPolicy changes use authenticated Recovery sessions. AMFI
boot-argument writes use the authenticated normal agent with SIP disabled.
Disable SIP before changing AMFI, and restore AMFI before re-enabling SIP. Security
workflows are state-first: status and an already-satisfied no-op observe the
guest without requesting or transmitting an owner password. Success restores
the requested `--final-state`; failure restores the run state captured at the
start when that state can be safely proved, otherwise the journal is retained
and restoration is reported incomplete. `--force` confirms the fresh-owner
branch only; it does not override credentials, ownership, native login
protections, or cleanup barriers. MDM requires verified normal-agent
capabilities. `mdm VM --profile FILE` defaults to supervised, user-approved
enrollment. It prepares SIP and AMFI automatically when needed, verifies the
installed profile, approval, and supervision, then restores the original
security settings and VM run state. `--enrollment-mode unapproved` selects
enrollment without approval or supervision. Remote Login and Screen Sharing
are explicit, capability-gated operations.

For a VM that starts with SIP and AMFI enabled:

```sh
pomme mdm dev --profile ./enrollment.mobileconfig
# Or request unapproved enrollment:
pomme mdm dev --profile ./enrollment.mobileconfig --enrollment-mode unapproved
```

The profile remains required when upgrading an existing unapproved enrollment.
A matching enrollment is reused; an already-satisfied request avoids security
changes. Conflicting profiles and downgrades from approved or supervised
enrollment are rejected. Repeat the same command and mode to resume interrupted
work from its journal. The former `mdm enroll` and `mdm approve` commands are
removed. These modes use Pomme's profile enrollment flow; they do not implement
Apple User Enrollment or Automated Device Enrollment.

Pomme permits new OS versions as experimental Recovery attempts. It records the
actual restore version/build and warns when that combination has not been
qualified; an unlisted build is not a reason to refuse creation. The existing
Tahoe `26.6.0 (25G72)` reviewed profile remains distinct from experimental
attempts, including Sequoia. Ownership, host-ABI, locale, display, and profile
integrity checks still apply. Unexpected or unstable Recovery screens stop
navigation, and a failed phase retains the VM and journal for diagnosis/resume.
An attempted or successful one-off run is not release qualification.

Fresh-owner decisions bind the exact native stock account name, numeric UID,
and GeneratedUID baseline; an unfamiliar record blocks freshness. Unknown OS
versions remain guarded experimental identities when their exact profile,
ownership, and host checks pass. Native automatic-login refusals, including
Touch ID, Apple Pay, App Store, and related protections, are closed
login-restriction results. Pomme has no native-force override, and qualification
of the actual native automatic-login diagnostic remains pending. See
[Security workflows](Docs/SecurityWorkflows.md) for the owner, journal, and
retry rules.

## Design

- [Architecture](Docs/Architecture.md)
- [Security workflows](Docs/SecurityWorkflows.md)
- [Protocol contracts](Docs/Protocols.md)
- [Qualification and publication gates](Docs/Qualification.md)
