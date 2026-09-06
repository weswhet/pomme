---
name: pomme-cli
description: "Build, test, or change the Pomme macOS VM CLI, Pomme agent protocols, durable creation, Recovery security, MDM/access, or UI automation."
---

# Pomme CLI

## Routing

The primary agent integrates cross-domain work. Route bounded behavior to the
repository specialists:

| Behavior | Owner |
| --- | --- |
| Root syntax, config, IPSW resolution, create preflight | `pomme-cli-config` |
| VM/helper lifecycle, PommeControlProtocol, runtime state | `pomme-vm-control` |
| PommeAgentProtocol, authentication, processes, jobs, files, update | `pomme-guest-transport` |
| Recovery, SIP/AMFI, rescue and credential risk review | `pomme-recovery-security` (read-only) |
| MDM, Remote Login, Screen Sharing and privileges | `pomme-mdm-access` |
| TUI, UI automation, Recovery profile interaction and display | `pomme-interaction` |
| Disposable live experiments explicitly assigned by the primary | `pomme-lab-operator` |

Specialists must read `.codex/agents/README.md`. Use its atomic per-path lease
for shared routers, bootstrap/core/application/environment files, shared
protocol/support files, and cross-domain tests. A directly spawned specialist
may use at most one read-only explorer inside its assigned subsystem.

## Build and verification

Work from the repository root. Use a full Xcode installation and build through
XcodeBuildMCP:

```sh
rtk xcodebuildmcp macos build \
  --project-path pomme.xcodeproj \
  --scheme pomme \
  --configuration Release \
  --arch arm64 \
  --output text
```

Resolve the executable with:

```sh
rtk xcodebuildmcp macos get-app-path \
  --project-path pomme.xcodeproj \
  --scheme pomme \
  --configuration Release \
  --arch arm64 \
  --output json
```

After parser or workflow changes:

```sh
rtk Tests/PommeCLIIntegrationTests.sh --runner "$POMME" --no-build
```

Do not operate a VM for parser/unit verification. A live command requires an
explicitly scoped existing Pomme-owned VM, or a disposable experiment assigned
by the primary under the lab rules.

## Product and command contract

Pomme uses only its own state and identities:

- `~/Library/Application Support/pomme`;
- `/tmp/pomme-*.sock` and `POMME_*` environment variables;
- `/usr/local/bin/pomme` on the host;
- `/usr/local/libexec/pomme` with launchd label
  `com.github.weswhet.pomme.agent` in normal macOS; and
- `/private/var/db/pomme/agent.token` for guest private state.

Never read, migrate, alias, or rewrite another product's VM, host state,
credential, socket, or guest service.

Public syntax uses top-level verbs and positional VM names. Keep only `list|ls`
and `delete|rm` aliases. Bare `pomme` prints concise help; only `pomme tui`
enters the terminal UI.

```text
create, list|ls, start, stop, restart, pause, resume, delete|rm,
status, inspect, exec, shell, jobs, cp, cat, agent, sip, amfi,
mdm, remote-login, screen-sharing, config, ipsw, ui, tui
```

`POMME_VM_NAME` may supply an omitted target. Never infer a target from the set
of running VMs. Representation uses `--format table|json|jsonl|raw`; `--json`
is shorthand and `--output` always means a file path. Keep `--debug`.

## Durable creation

Direct creation accepts one restore source and `--boot none|normal|recovery`.
Configuration mode supports JSON, YAML, TOML, and Pkl, resolves every selector,
and collision-checks the entire batch before mutation. Once execution starts,
successful siblings remain when another member fails.

Creation resolves an exact restore identity before its first external effect.
New OS versions and builds are allowed as experimental attempts; do not block
them solely because no reviewed build entry exists. Keep the actual version and
build in the immutable plan and expose experimental qualification honestly.
Tahoe `26.6.0 (25G72)` retains its existing reviewed profile. Experimental attempts
do not inherit a reviewed-record digest, including attempts of Sequoia.
Unknown locale, geometry, private host ABI, profile digest, or ownership evidence
still emits no input. Navigation requires the expected stable screen before and
after each single event. `latest` resolves to an exact identity, not an alias in
the durable plan. A failed experiment retains its VM/journal and is not release
qualification.

Journal intent before every effect. Install macOS, perform the required
display-only normal boot, install the signed persistent agent in Recovery via
request-bound VirtioFS, authenticate and verify it in normal macOS, then restore
the requested final state. Creation never changes SIP or AMFI.

Failure preserves the exact VM and journal. `pomme create NAME --resume`
accepts only the target plus output/debug options and resumes after revalidating
the immutable plan.

## Agent and guest operations

Host-side persistent-agent credentials use the file-based login Keychain via
Apple's `Security.framework`. Target that Keychain explicitly for every query
and add, preserving the UUID service/account and the CLI's signing identity.
Do not select the Data Protection Keychain, add Keychain entitlements, silently
replace credentials, or auto-unlock the login Keychain. Keep credential tests
isolated in temporary Keychains. This Pomme policy takes precedence over generic
cross-platform Keychain recommendations.

The persistent normal role is `PommeAgent`; temporary Recovery work uses
`PommeRecoverySession`. Both use `PommeAgentProtocol` version 1 with
authentication as the first operation. Normal connections use port `505051`;
bounded Recovery sessions use `505052` and `505053`.

The protocol uses 256 KiB JSON-lines frames, 64 KiB process-stream chunks, and
32 KiB file chunks. It provides authenticated process, PTY, job, file, system,
network, access-service, and transactional maintenance operations. File transfer
has one authenticated chunk path with adjacent staging, symbolic-link defenses,
atomic commit, and exact cleanup.

```sh
pomme agent status dev
pomme agent repair dev --final-state previous
pomme exec dev -- /usr/bin/whoami
pomme exec dev --pty --user alice -- /bin/zsh
pomme jobs list dev
pomme cp ./local dev:/tmp/local
```

Agent repair is Recovery-only. Status exposes one closed `guestAgent` object:
connection state, normal/recovery role, protocol version, executable digest,
capabilities, and update state.

## Security, MDM, and interaction

SIP and AMFI own complete authenticated Recovery transactions and restore the
requested final run state after success or failure. MDM requires verified
normal-agent capabilities. UI automation remains under `pomme ui`; the TUI
renders the same closed status schema.

Recovery input needs two stable pre-event frames, exactly one event per receipt,
and two stable post-event frames. Raw screenshots are private temporary lab
artifacts and never enter source control or production diagnostics.

## Safe operation

Before any stateful live command, inspect the explicitly scoped target and
preserve its previous state unless the user requests another final state. Never
create, boot, stop, suspend, delete, modify security, enroll, or repair an
unscoped VM merely to test code.
