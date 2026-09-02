# Pomme project agents

The primary agent owns routing, integration, and final verification. Each
specialist owns behavior rather than an arbitrary directory boundary and must
read `.codex/skills/pomme-cli/SKILL.md` before acting.

| Agent | Boundary | Access |
| --- | --- | --- |
| `pomme-cli-config` | root syntax, config formats, IPSW/profile preflight, durable create planning | write |
| `pomme-vm-control` | VM/helper lifecycle, local control protocol and runtime status | write |
| `pomme-guest-transport` | guest protocol, authentication, process/jobs/files/update | write |
| `pomme-recovery-security` | evidence-based Recovery, SIP/AMFI and credential review | read-only |
| `pomme-mdm-access` | MDM and access services | write |
| `pomme-interaction` | TUI, UI automation, display and Recovery profile interaction | write |
| `pomme-lab-operator` | primary-authorized disposable experiments only | live lab |

No specialist may operate a VM unless the primary assignment explicitly scopes
that operation. Only the primary may assign the lab operator. A directly spawned
specialist may use at most one nested read-only explorer limited to the assigned
subsystem; that explorer cannot edit, operate VMs, delegate, or spawn.

## Shared-file leases

Before editing a shared router, `PommeBootstrap.swift`, `PommeCore.swift`,
`PommeApplication.swift`, `PommeEnvironment.swift`, shared control/support code,
or a cross-domain test, acquire an atomic per-path lease.

Normalize and bytewise-sort repository-relative paths. For each path, atomically
create `.codex/agent-locks/<lowercase-sha256>.lock/` and atomically publish a
`lease.toml` containing owner, task, the complete path list, and UTC acquisition
time. Reject paths outside the repository, `..`, and symbolic-link aliases. An
existing directory is contention. On partial acquisition, release only the
directories acquired by that attempt and do not edit any requested path.

Leases never expire. The owner removes its exact metadata file and then the
empty lock directory. The primary may clear an abandoned lease only after
confirming the owner stopped and inspecting the metadata. Never recursively
delete the lock root.

## Handoff

Every specialist reports its assigned behavior boundary, changed files, exact
test/check commands and results, lease actions or contention, security and
compatibility decisions, unverified behavior, remaining risks, and recommended
owner for outstanding integration. Verbose diagnostics must redact credentials,
tokens, profiles, request bodies, private data, and sensitive frame content.

## Disposable lab

Lab names match `pomme-agent-<purpose>-<unique-suffix>`. Inventory first;
pre-existing machines, including matching names, are out of scope. The operator
may mutate and delete only a machine created in the current assignment and must
fail closed if host capacity would require changing another VM.

Generate credentials ephemerally, store references in Keychain, and remove the
exact items during cleanup. Temporary artifacts live in one assignment-specific
directory and are deleted as individually known files followed by `rmdir` of the
empty directory. Unexpected entries, symbolic links, or cleanup failure stop
cleanup expansion and are reported exactly. Raw screenshots and sensitive
frames never enter the repository or product diagnostics.
