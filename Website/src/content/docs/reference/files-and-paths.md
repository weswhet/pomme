---
title: Files and paths
description: Where Pomme stores its executable, VMs, templates, credentials, and guest components.
---

This page lists the files and directories that Pomme creates on the host and
in each guest.

## Host executable

| Path | Description |
| --- | --- |
| `~/.local/bin/pomme` | The executable installed by a local source build. |
| `/usr/local/bin/pomme` | The executable installed by the Pomme package. |

## Host data directory

Pomme stores its data in `~/Library/Application Support/pomme`. To use a
different directory, set [`POMME_APP_SUPPORT_DIR`](/reference/environment-variables/#pomme_app_support_dir).

| Path | Description |
| --- | --- |
| `VMs/NAME.bundle` | One bundle for each VM. |
| `Templates/NAME.bundle` | One bundle for each template. |
| `RestoreImages/` | Downloaded restore images (IPSW files). |
| `AgentArtifacts/sha256/` | An append-only store of signed Pomme executables, keyed by SHA-256 digest. Recovery installation uses it to find the exact agent that a VM's journal pins. |
| `TerminalSessions/` | Transcripts and metadata for durable terminal sessions in normal macOS. |
| `Runtime/` | Runtime state for running VM helpers. |
| `RecoveryStaging/`, `RecoveryTerminalBootstrap/` | Temporary, request-bound files that Pomme shares with a VM in Recovery. |

:::danger
Deleting a VM bundle or the data directory deletes those VMs permanently.
Use `pomme delete` and `pomme template delete` instead of removing files. Pomme
manages only bundles that it created in this directory, and it doesn't adopt
bundles that you copy in from elsewhere.
:::

### VM bundle contents

Each `VMs/NAME.bundle` directory contains the following files:

| File | Description |
| --- | --- |
| `Disk.img` | The VM's disk image. |
| `AuxiliaryStorage` | The VM's auxiliary storage, which holds its NVRAM. |
| `HardwareModel`, `MachineIdentifier` | The VM's hardware identity. |
| `Metadata.json` | Pomme's record of the VM: macOS version and build, sizes, agent identity, provisioning route, and template. |
| `SecurityWorkflowJournal.json` | The journal for SIP and AMFI workflows. It never contains the owner password. |
| `MDMEnrollmentJournal.json` | The journal for MDM enrollment. |
| `SaveFile.vzvmsave` | The saved machine state, when present. |
| `Snapshots/` | Named saved-state snapshots. |
| `pomme-helper.log` | The log of the VM's background helper process. |
| `.pomme/` | The VM's creation journal and its signing key. After `pomme agent update`, it also holds the signed record of the updated agent's digest. |

Treat these files as internal. Their formats can change between Pomme
versions.

## Other host locations

| Location | Description |
| --- | --- |
| Login Keychain | Each VM's guest agent credential and owner password, stored under a service name that starts with `com.github.weswhet.pomme.vm` and is scoped to the VM's UUID. The Keychain must be unlocked. |
| `$TMPDIR/pomme-*.sock` | The Unix socket for each VM's background helper. |
| `$TMPDIR/pomme-recovery-debug-*` | Screenshots that `--debug` keeps for each automatic Recovery navigation. Pomme doesn't delete them. |

## Guest paths

Pomme installs the following files in each guest's normal macOS:

| Path | Description |
| --- | --- |
| `/usr/local/libexec/pomme` | The guest agent executable. |
| `/Library/LaunchDaemons/com.github.weswhet.pomme.agent.plist` | The launchd job for the guest agent, with the label `com.github.weswhet.pomme.agent`. |
| `/private/var/db/pomme/agent.token` | The guest agent's private credential. |

The guest agent writes to the unified log under the subsystem
`com.github.weswhet.pomme`. To read those logs from the host, see
[View guest agent logs](/guides/view-guest-logs/).

## What's next

- [Architecture](/concepts/architecture/)
- [Guest agent](/concepts/guest-agent/)
- [Environment variables](/reference/environment-variables/)
