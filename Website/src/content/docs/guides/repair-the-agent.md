---
title: Check and repair the guest agent
description: Inspect the Pomme guest agent in a VM and reinstall it through Recovery when it's missing or broken.
---

This guide shows you how to check the health of a VM's guest agent and how to
repair it. Most Pomme commands that work inside the guest, such as
`pomme exec`, `pomme cp`, and the security workflows, need a connected,
verified agent.

For background on what the agent does, see
[Guest agent](/concepts/guest-agent/).

## Before you begin

- Make sure that the VM exists. To list your VMs, run `pomme list`.
- Build and install the Pomme command-line tool that you want to use. A repair
  compares the guest agent with the host tool that runs the command.

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
:::

## Understand pinned agent artifacts

Each VM's creation plan pins the exact signed agent executable, by SHA-256
digest, that Pomme installed. The local build script keeps every signed build
in an append-only store under
`~/Library/Application Support/pomme/AgentArtifacts/sha256`. When a repair or a
resumed creation reinstalls the agent through Recovery after you rebuild the
host command-line tool, Pomme uses the original pinned artifact, not the new build. If the
pinned artifact is missing or altered, the repair fails and changes nothing.

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
