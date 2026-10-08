---
title: Check, update, and repair the guest agent
description: Inspect the Pomme guest agent in a VM, update it to the host's Pomme build, and reinstall it through Recovery when it's missing or broken.
---

This guide shows you how to check the health of a VM's guest agent, update it
to the agent in your host's `pomme` build, and repair it. Most Pomme commands
that work inside the guest, such as `pomme exec`, `pomme cp`, and the security
workflows, need a connected, verified agent.

For background on what the agent does, see
[Guest agent](/concepts/guest-agent/).

## Before you begin

- Make sure that the VM exists. To list your VMs, run `pomme list`.
- Build and install the Pomme command-line tool that you want to use. An
  update installs the agent from the host tool that runs the command, and a
  repair compares the guest agent with that tool.

## Check the agent status

To see the agent's status, run the following command:

```sh
pomme agent status VM_NAME
```

Replace `VM_NAME` with the name of your VM.

The command reads the VM's status without changing the guest. The table output
shows the connection state and the agent's role. For the full set of fields,
use JSON output:

```sh
pomme agent status VM_NAME --format json
```

The output looks similar to the following:

```json
{
  "ok": true,
  "name": "dev",
  "guestAgent": {
    "connection": "connected",
    "role": "normal",
    "protocolVersion": 1,
    "executableDigest": "0000000000000000000000000000000000000000000000000000000000000000",
    "capabilities": ["agent.describe", "agent.health", "process.start"],
    "updateState": "current"
  },
  "hostExitCode": 0
}
```

The `guestAgent` object has the following fields:

| Field | Description |
| --- | --- |
| `connection` | `connected` when the host has an authenticated agent session, otherwise `disconnected`. |
| `role` | `normal` for the persistent agent in normal macOS, or `recovery` for the temporary Recovery session. |
| `protocolVersion` | The `PommeAgentProtocol` version that the agent speaks. |
| `executableDigest` | The SHA-256 digest of the agent executable. |
| `capabilities` | The operations that the agent advertises. |
| `updateState` | One of `unknown`, `current`, `updating`, `required`, `failed`, or `unavailable`. |

A stopped VM reports `disconnected`. A guest that's still booting connects on
its own; `pomme status VM_NAME` reports when it does.

## Update the agent

Installing a new `pomme` command on the host doesn't change the agent in your
existing VMs. To give a VM the agent from your current host build, with its
new capabilities and log events, update the agent in place. An update doesn't
boot Recovery or restart the guest.

Before you update, make sure that the following conditions are met:

- Pomme created the VM.
- The VM is running normal macOS, and its agent is connected.
- The VM has no unfinished SIP, AMFI, or MDM operation. To finish one, repeat
  its original command.
- The VM has no running background jobs or terminal sessions. To check, run
  `pomme jobs list VM_NAME` and `pomme sessions list VM_NAME`.

The agent restarts during an update, and the restarted agent doesn't know
about the background jobs and terminal sessions that the old agent started.
Their programs would keep running, but `pomme jobs` and `pomme sessions` could
no longer wait for, attach to, or stop them. For that reason, an update that
finds running jobs or sessions changes nothing and lists the command that stops
each one.

To update the agent, run the following command:

```sh
pomme agent update VM_NAME
```

Replace `VM_NAME` with the name of your VM.

Pomme copies the host's signed `pomme` executable into the guest, installs it
as the agent, restarts the agent, and waits for it to reconnect with the
SHA-256 digest of the new executable. The output looks similar to the following:

```text
Updated the Pomme agent in dev to 0123456789ab.
```

Copying the executable takes most of the time, usually less than a minute.

The restarted agent runs with the launchd settings that the guest loaded when
it started. When an update also changes those settings, they take effect the
next time that the guest starts. To apply them right away, restart the VM:

```sh
pomme restart VM_NAME
```

If the agent already matches the host build, the command makes no change and
reports that the agent is current. JSON output reports `"updated": false`, and
the command exits with status `0`, so you can run it again safely:

```sh
pomme agent update VM_NAME --format json
```

```json
{
  "ok": true,
  "name": "dev",
  "updated": false,
  "previousExecutableDigest": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "executableDigest": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "hostExitCode": 0
}
```

After a successful update, Pomme records the new digest for the VM. SIP, AMFI,
and MDM workflows then accept the updated agent. For details, see
[Digest pinning](/concepts/guest-agent/#digest-pinning).

If the new agent doesn't reconnect in time, the command fails and tells you
that the agent is installed but not yet running. Restart the VM with
`pomme restart VM_NAME`, and then run `pomme agent update VM_NAME` again to
record the new agent.

## Repair the agent

To repair the agent, run the following command:

```sh
pomme agent repair VM_NAME
```

Replace `VM_NAME` with the name of your VM.

Pomme first checks whether a repair is needed. If provisioning is complete and
the connected normal agent has the required protocol, the required
capabilities, and the same SHA-256 digest as the host command-line tool, Pomme reports that
the agent is already healthy and exits with status `0`. It doesn't change the
VM or its provisioning journal:

```text
Pomme agent is already healthy for VM_NAME.
```

Otherwise, Pomme installs the agent through Recovery. It records the repair in
the VM's provisioning journal before it starts, boots Recovery, installs the
agent, and then returns the VM to the state it was in before the command.
`--final-state` accepts only `previous`, which is the default.

If agent provisioning is complete but the agent isn't healthy for another
reason, the repair reports that it has nothing to repair:

```text
Nothing to repair for VM_NAME: agent provisioning is complete. Agent repair does not reconcile SIP or AMFI security transactions.
```

To resume an unfinished SIP or AMFI transaction, repeat its original command
instead. For details, see
[Change SIP and AMFI](/guides/change-sip-and-amfi/#resume-an-interrupted-change).

:::note
Recovery repair isn't available for VMs that macOS 27 first-boot provisioning
created. For those VMs, the command reports the following:

```text
Recovery agent repair is unavailable for framework-provisioned VMs. Use `pomme inspect NAME` for diagnosis or `pomme create NAME --resume` to resume incomplete creation.
```

To bring the agent in one of those VMs up to date while it's running, use
`pomme agent update` instead.
:::

## Understand pinned agent artifacts

Each VM's creation plan pins the exact signed agent executable, by SHA-256
digest, that Pomme installed. When Pomme creates a VM, it keeps a copy of that
executable in an append-only store under
`~/Library/Application Support/pomme/AgentArtifacts/sha256`, and the local
build script adds every signed build to the same store. When a repair or a
resumed creation reinstalls the agent through Recovery after you update or
rebuild Pomme, Pomme uses the original pinned artifact, not the new version. If
the pinned artifact is missing or altered, the repair fails and changes
nothing.

A repair that reinstalls the agent therefore undoes an earlier
`pomme agent update`: the VM gets the agent that it was created with, and
Pomme stops accepting the updated digest. To return to your current host build
after such a repair, run `pomme agent update VM_NAME` again.

## Capture Recovery screenshots for debugging

To keep screenshots of each automatic Recovery navigation step, add `--debug`:

```sh
pomme agent repair VM_NAME --debug
```

Pomme prints the private directory and the saved file names to standard
error. Delete the directory when you no longer need it, because the
screenshots can show local identifiers.

## What's next

- [Guest agent](/concepts/guest-agent/)
- [Durable creation and journals](/concepts/durable-creation/)
- [`pomme agent` reference](/reference/cli/pomme-agent/)
- [Troubleshooting](/resources/troubleshooting/)
