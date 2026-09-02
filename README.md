# Pomme

Pomme is a private, Apple-silicon macOS virtual-machine CLI built with Swift
and Virtualization.framework. It owns only machines created in
`~/Library/Application Support/pomme`; it does not inspect or migrate machines,
credentials, sockets, or services owned by another product.

The project is pre-release at version `0.1.0`. Publication is disabled pending
the reviewed qualification described in [Docs/Qualification.md](Docs/Qualification.md).

## Build and test

A full Xcode installation is required:

```sh
xcodebuildmcp macos build \
  --project-path pomme.xcodeproj \
  --scheme pomme \
  --configuration Release \
  --arch arm64 \
  --output text
```

Resolve the built executable with:

```sh
xcodebuildmcp macos get-app-path \
  --project-path pomme.xcodeproj \
  --scheme pomme \
  --configuration Release \
  --arch arm64 \
  --output json
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
status, inspect, exec, shell, jobs, cp, cat, agent, sip, amfi,
mdm, remote-login, screen-sharing, config, ipsw, ui, tui
```

Create is a durable provisioning workflow, not only an installation command:

```sh
pomme create dev --version 26.6.0 --boot none
pomme create dev --restore-image /path/to/Restore.ipsw --boot normal
pomme create dev --resume
```

Before creating anything, Pomme resolves and verifies the restore-image build,
English locale, `1280×800` display geometry, closed Recovery profile, and
immutable agent identity. It installs macOS, performs the required display-only
normal boot behind an isolated supervisor/worker boundary, proves that both
processes and their descendants stopped and were reaped, installs the signed
persistent agent in Recovery, verifies the normal agent, and restores `none`,
`normal`, or `recovery` as requested. SIP and AMFI
are never changed by creation.

The `0.1.0` development build includes the request-bound production Recovery
bootstrap adapter. The workflow above remains pre-release: publication stays
disabled until live creation, Recovery security, MDM, and the qualification
matrix have been independently completed and reviewed.

If creation stops after an external effect, Pomme preserves the exact VM and
journal. `--resume` revalidates the immutable plan and continues from the first
unresolved intent. Resume accepts only its target and output/debug options.

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
pomme exec dev --pty --user alice -- /bin/zsh
pomme exec dev --detach -- /usr/bin/sleep 30
pomme jobs list dev
pomme cp ./input dev:/tmp/input
pomme cat dev:/tmp/input
```

Process streams, terminal resize, signals, jobs, and file handles are correlated
and bounded. File transfer is authenticated and chunked, stages adjacent to its
destination, refuses symbolic-link traversal, and commits atomically.

## Security and access

SIP and AMFI operations use only an authenticated Recovery session and restore
the requested final run state on success or failure. MDM requires verified
normal-agent capabilities. Remote Login and Screen Sharing are explicit,
capability-gated operations.

```sh
pomme sip status dev
pomme sip disable dev --final-state previous
pomme amfi enable dev --final-state normal
pomme mdm enroll dev --profile ./enrollment.mobileconfig
```

Pomme currently accepts only the exact Tahoe `26.6.0 (25G72)` profile with its
reviewed qualification digest. Sequoia `15.6.1 (24G90)` remains a fail-closed
reference until its fresh-VM qualification and independent review are complete;
code recognition and unit tests do not enable it.

## Design

- [Architecture](Docs/Architecture.md)
- [Protocol contracts](Docs/Protocols.md)
- [Qualification and publication gates](Docs/Qualification.md)
