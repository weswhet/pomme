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
rtk proxy xcodebuild test \
  -project pomme.xcodeproj \
  -scheme pomme \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
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
status, inspect, log, exec, shell, sessions, jobs, cp, cat, agent, sip, amfi,
mdm, remote-login, screen-sharing, snapshot, template, config, ipsw, ui, tui
```

`pomme tools` lists command groups and `pomme agent-help` prints a compact
inventory for coding agents. Both accept `--format table|json|jsonl` and
`--json`; their JSON discovery payloads are the same, while JSONL emits one
command group per line. Neither command needs a VM.

View Pomme subsystem records from a running guest with `pomme log`. History
defaults to 10 minutes; `--follow` streams new records until interrupted:

```sh
pomme log VM
pomme log VM --last 1h --category buddy-preferences
pomme log VM --follow
pomme log VM --follow --level debug --format jsonl
```

`stop` asks the guest to shut itself down when the agent is connected, resuming
a paused VM so it can, and waits before powering the VM off; if it has to power
off, it says so. `stop --force` powers the VM off immediately.

For unattended deletion, `delete --force` (or `rm --force`) skips confirmation
and stops a running VM before deleting it. It uses the normal shutdown sequence
described above and verifies that the helper exits before deletion. If stopping
or helper exit cannot be confirmed, the VM bundle is retained:

```sh
pomme delete NAME --force
```

Create is a durable provisioning workflow, not only an installation command:

```sh
pomme create dev --latest                 # installs, verifies the agent, leaves it running
pomme create dev --version 26.6.0 --shutdown
pomme create dev --latest --recovery
pomme create dev --resume
pomme create dev --resume --debug
```

Before creating anything, Pomme resolves and verifies the restore-image build,
English locale, `1280×800` display geometry, closed Recovery profile, and
immutable agent identity. On macOS 27 hosts with a fresh macOS 27 guest, it uses
Apple's first-boot provisioning to create the `pomme` account, enable automatic
login, and temporarily enable Remote Login. Pomme finds the guest through its
DHCP lease, pins its SSH host key on first connection, and installs the signed
agent over SSH. It then verifies the agent and owner account and turns Remote
Login off. The generated password stays in the host login Keychain.

Older hosts, older guests, already-provisioned templates, and existing legacy
journals retain Recovery agent installation. Both routes restore `none`,
`normal`, or `recovery` as requested. SIP and AMFI are never changed by creation.

Apple describes the macOS 27 first-boot account and Remote Login options in
[Expand the capabilities of your Virtualization app](https://developer.apple.com/videos/play/wwdc2026/224/?time=63).

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
fresh machine identifier and UUID and then runs the applicable journaled
bootstrap and verification. Every VM cloned from a template inherits its disk
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

### Command progress

Long-running commands show one status line on standard error, with a dotted
apple animation, the current step, and elapsed time. IPSW downloads and macOS
installation show measured percentages. Downloads also show the resolved macOS
version, byte counts, transfer rate, and estimated time remaining once enough
data has arrived to measure the rate. Compact terminals omit secondary counters
to keep the status on one line.
Parallel creation shares the line and rotates between VMs when space is limited.

Use `--progress auto|plain|off` to control the display. `auto` is the default:
it animates on a capable terminal and prints deduplicated step lines when
standard error is redirected or `TERM=dumb`. JSON and JSONL suppress progress
unless you explicitly select `plain`. `--debug` uses plain progress with verbose
diagnostics. `NO_COLOR` disables color, and non-Unicode locales use ASCII symbols.
Warnings and errors remain visible with `off`.

Progress clears before results, prompts, guest output, and PTY attachment.
The full-screen TUI retains its own display and log capture.

### Recovery debug screenshots

`--debug` retains a full-resolution PNG immediately before each automatic
Recovery navigation action, including navigation used by create/resume, agent
repair, SIP, AMFI, MDM enrollment, and an ordinary Recovery shell admission.
Pomme prints the private directory and saved filenames to standard error. Each Recovery attempt
uses its own `pomme-recovery-debug-…` directory under the host temporary
directory; images remain available after either success or failure and are not
pruned automatically. Full-resolution frames can show local identifiers, so
remove the printed private directory manually when you no longer need it.

Capture is diagnostic only: it never changes public table, JSON, or JSONL
output, capture failures warn and let the original navigation continue, and no
images are made unless Recovery navigation actually begins. Screenshot work is
bounded to two additional seconds per attempt. PNG capture stops before a
Terminal command is entered, so neither launcher submission nor command output
is recorded.

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
pomme agent repair dev --final-state previous --debug
```

Repair installs the agent through Recovery. If provisioning is complete and the
connected normal agent has the required protocol and capabilities and its SHA-256
matches the host CLI, `agent repair` reports that the agent is already healthy
and exits with status 0 without changing the VM or provisioning journal.
Agent status reports a closed `guestAgent` object with connection state, `normal`
or `recovery` role, protocol version, executable digest, capabilities, and update
state.

Guest process and file examples:

```sh
pomme exec dev -- /usr/bin/sw_vers
pomme shell dev
pomme shell dev --detach
pomme exec dev --pty --user alice -- /bin/zsh
pomme exec dev --pty --detach -- /usr/bin/top
pomme sessions list dev
pomme sessions attach dev --session SESSION_ID --takeover
pomme sessions logs dev --session SESSION_ID --follow
pomme sessions terminate dev --session SESSION_ID
pomme sessions delete dev --session SESSION_ID
pomme exec dev --detach -- /usr/bin/sleep 30
pomme jobs list dev
pomme cp ./input dev:/tmp/input
pomme cat dev:/tmp/input
```

Process streams, terminal resize, signals, jobs, and file handles are correlated
and bounded. `shell` and `exec --pty` create durable reconnectable
sessions; a one-shot shell expression is `exec NAME -- /bin/sh -c '...'`.
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
pomme ui key --vm dev --key ctrl-f2
pomme ui key --vm dev --key cmd+shift+t
pomme ui key-sequence --vm dev -- left right
pomme ui type --vm dev --text '/usr/bin/id -u'
pomme ui key --vm dev --key return
pomme ui keys
```

`pomme ui keys` lists the named keys, modifier prefixes, and aliases that `ui key`
and `ui key-sequence` accept.

Observe the guest with `pomme ui screenshot --vm dev --output /absolute/private/path.png`.
Keep Recovery screenshots in a private temporary lab directory, outside the
repository. Named navigation/function keys and modifier combinations are
supported; numeric HID scan codes are not exposed. Requests do not move the host
pointer or change its frontmost app. Automatic provisioning owns an exclusive
VM lease; do not mix manual input into it.

## Security and access

SIP and AMFI LocalPolicy changes use authenticated Recovery sessions. AMFI
boot-argument writes use the authenticated normal agent with SIP disabled.
Disable SIP before changing AMFI, and restore AMFI before re-enabling SIP. Security
workflows are state-first: status and an already-satisfied no-op observe the
guest without requesting or transmitting an owner password. Success restores
the requested `--final-state`. A fresh-owner preparation failure preserves the current
VM state for inspection. Other security failures may restore the run state captured
at the start when that state can be safely proved; otherwise, the journal is
retained and restoration is reported incomplete. `--force` confirms the fresh-owner
branch only; it does not override credentials, ownership, native login
protections, or cleanup barriers. Remote Login and Screen Sharing are
explicit, capability-gated operations.

`mdm VM --profile FILE` takes a VM from any state to the requested enrollment.
It works out what is missing from the VM's retained state and runs only those
steps, in order, under one mutation lease:

1. Create the VM when it does not exist (`--from-template`, `--version`,
   `--latest`, or `--restore-image`, with `--memory`, `--disk-size`, and
   `--boot none|normal`). These options are ignored once the VM exists.
2. Resume an incomplete creation, which installs and verifies the agent.
3. Finish a retained standalone `sip` or `amfi` operation with its own
   operation and final state.
4. Enroll: boot normal macOS, verify the pinned agent, read SIP and AMFI, and
   disable only what enrollment needs. On a fresh VM without an owner, the SIP
   step creates the `pomme` owner, which needs `--force` or a confirmation.

Enrollment defaults to supervised, user-approved enrollment;
`--enrollment-mode unapproved` selects enrollment without approval or
supervision. It verifies the installed profile, approval, and supervision, then
restores the original SIP/AMFI settings and VM run state. `--final-security
disabled` instead leaves what this enrollment disabled switched off; re-enable
later with `pomme amfi enable` and then `pomme sip enable`.

Before touching the VM, the host checks the profile's MDM server. When the
host reaches it and neither Apple's roots nor the profile's own certificate
payloads validate it, a command that could still install the profile stops
(`--skip-server-preflight` skips this when the guest already trusts the
server); an unreachable server only warns. Inside the guest, the enrollment helper checks again
before importing the identity. When only the profile's roots validate the
server, their certificate payloads are installed first as a separate
configuration profile, `com.github.weswhet.pomme.mdm-trust.<profile UUID>`, so a
private-CA server needs no manual trust setup. That profile stays installed;
remove it with `profiles remove -identifier` when it is no longer wanted.

Each step keeps its own journal. If one fails, Pomme exits nonzero and
preserves the current SIP/AMFI settings, VM run state, staged files, and
journals; it does not poll for enrollment or clean up automatically. Repeat the
same command, profile, mode, and `--final-security` to resume. States that
cannot be resumed safely, such as a dispatched first boot without a receipt, a
pinned agent that lacks MDM capabilities, or a retained enrollment for a
different request, stop before any effect with a named blocker. `--dry-run`
reports the detected state and planned steps without changing the VM.

```sh
# Create from a template if needed and enroll, whatever state the VM is in:
pomme mdm dev --profile ./enrollment.mobileconfig --from-template base --memory 4GB --force
# See what it would do first:
pomme mdm dev --profile ./enrollment.mobileconfig --from-template base --dry-run
# Leave SIP and AMFI disabled afterwards:
pomme mdm dev --profile ./enrollment.mobileconfig --final-security disabled
# Or request unapproved enrollment:
pomme mdm dev --profile ./enrollment.mobileconfig --enrollment-mode unapproved
# Include detailed enrollment diagnostics:
pomme mdm dev --profile ./enrollment.mobileconfig --debug --format json
```

The profile remains required when upgrading an existing unapproved enrollment.
A matching enrollment is reused; an already-satisfied request avoids security
changes. Conflicting profiles and downgrades from approved or supervised
enrollment are rejected. Diagnostics identify the failing guest stage and include
elapsed times, numeric status codes, and Keychain status flags without profile
contents or credentials. Structured output lists each step with its status in
`steps` and includes `result.readiness` (detected state, blockers, and
warnings), `result.serverTrust`, `result.failureStage` and `result.diagnostics`
when the helper returns them, plus `result.failureStatePreserved` and
`result.retryAllowed` on failure.

After rebuilding and installing Pomme, repeat the same command, profile, and mode
to inspect retained work. Each enrollment attempt stages a helper from the
current host CLI, so a guest enrollment fix does not require replacing the
persistent agent. A failure proved to occur before identity import can retry
after checking the retained state and cleaning its owned staging files. Unknown
outcomes remain protected against automatic reinstallation. The former
`mdm enroll` and `mdm approve` commands are
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

## Documentation site

The documentation is published at <https://pommevm.dev> from the `main`
branch. Its source lives in [Website](Website/README.md); to preview changes,
run `npm install` and `npm run dev` in that directory, then open
`http://localhost:4321`.

## Design

- [Architecture](Docs/Architecture.md)
- [Security workflows](Docs/SecurityWorkflows.md)
- [Protocol contracts](Docs/Protocols.md)
- [Qualification and publication gates](Docs/Qualification.md)

## License

Pomme is licensed under the [Apache License 2.0](LICENSE).
