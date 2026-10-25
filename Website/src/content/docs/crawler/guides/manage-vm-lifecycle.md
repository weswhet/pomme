---
title: Life and death of VMs
description: Check on, start, stop, restart, pause, resume, and permanently delete Pomme VMs. Mostly in that order.
---

Every VM has a life cycle, Crawler, and you control all of it. This guide
shows you how to check the state of your Pomme VMs and move them between
states: running, paused, and stopped. It also shows you how to delete a VM
that you no longer need. The viewers have skipped ahead to that part.

## Before you descend

- [Install Pomme](/crawler/get-started/install/).
- Create at least one VM. For instructions, see
  [Create a VM](/crawler/guides/create-vms/).
- Read [VM lifecycle and boot modes](/crawler/concepts/vm-lifecycle/) to
  understand VM states and boot modes.

## Choose the target VM

Every lifecycle command takes one or more VM names as positional arguments. For
example, the following command stops two VMs, one after the other:

```sh
pomme stop VM_NAME OTHER_VM_NAME
```

Replace the following:

- `VM_NAME` and `OTHER_VM_NAME`: the names of the VMs to stop.

If you omit the name, Pomme uses the value of the `POMME_VM_NAME` environment
variable. Pomme never chooses a VM for you, even when only one VM is running.
It won't guess, Crawler. Guessing is how highlight reels get made. To work
with the same VM for a whole shell session, set the variable once:

```sh
export POMME_VM_NAME=VM_NAME
pomme status
```

For details, see [Environment variables](/crawler/reference/environment-variables/).

### Act on every VM

`pomme stop`, `pomme pause`, `pomme resume`, and `pomme delete` accept
`--all` (`-a`) in place of VM names. Each command then acts on every VM that it
applies to, and ignores `POMME_VM_NAME`:

| Command | VMs that `--all` selects |
| --- | --- |
| `pomme stop --all` | Running and paused VMs. |
| `pomme pause --all` | Running VMs. |
| `pomme resume --all` | Paused VMs. |
| `pomme delete --all` | Every VM. |

If no VM matches, the command succeeds without changing anything. You can't
combine `--all` with VM names. Yes, that last row means what you think it
means. Keep reading before you try it.

## Take a head count

To see every VM that Pomme manages, run `pomme list` (or its alias, `pomme ls`):

```sh
pomme list
```

To check one or more specific VMs, use the following commands:

- `pomme status VM_NAME` shows the run state, the boot mode, and the guest
  agent connection.
- `pomme inspect VM_NAME` shows the VM configuration, health, and boot
  firmware. While the VM is running, the output also includes the guest
  capabilities.

Replace `VM_NAME` with the name of the VM.

All three commands accept `--format json` or `--format jsonl` for scripts. For
details, see [Structured output](/crawler/reference/structured-output/).

## Wake a VM

To start a stopped VM in normal macOS, run the following command:

```sh
pomme start VM_NAME
```

Replace `VM_NAME` with the name of the VM.

For a normal boot, `pomme start` waits until the guest agent connects, so that
the VM is ready for guest commands when the command returns. By default, it
waits up to 300 seconds. To change the limit, pass `--timeout SECONDS`. If the
agent doesn't connect in time, the command fails but leaves the VM running; run
`pomme status VM_NAME` to investigate.

To start the VM in macOS Recovery instead, pass `--mode recovery`:

```sh
pomme start VM_NAME --mode recovery
```

A Recovery boot doesn't wait for a guest agent.

If the VM is already running in the requested boot mode, `pomme start` reports
the running VM and doesn't start it again. If the VM is running in the other
boot mode, the command fails. Stop the VM first, and then start it in the mode
that you want.

## Put a VM down

To stop a VM, run the following command:

```sh
pomme stop VM_NAME
```

Replace `VM_NAME` with the name of the VM.

When the VM runs normal macOS and its guest agent is connected, Pomme first
asks the guest to shut itself down, and gives it up to 120 seconds to finish. A
paused VM is resumed first, because a paused guest can't shut down. In other
cases, such as a VM in Recovery, Pomme asks Virtualization.framework to stop
the VM and waits up to 30 seconds. If the VM is still running after that
window, Pomme powers it off. Polite first, then less polite. The System
respects the escalation.

Pomme reports a power-off in its output instead of presenting it as a clean
stop. No covering for you, Crawler. In structured output, the `stopMethod`
field is one of the following values:

- `guest-stopped`: the guest shut itself down.
- `forced`: Pomme powered the VM off.
- `already-stopped`: the VM wasn't running, so nothing changed.

To power the VM off immediately, without a guest shutdown, pass `--force`:

```sh
pomme stop VM_NAME --force
```

:::caution[Hazard Detected: Pulled Plug]
A forced stop is like pulling the power cord. The guest doesn't get a chance
to write unsaved data to disk. Whatever it was in the middle of saving, it
stays in the middle forever.
:::

Stopping a VM ends its [durable terminal sessions](/crawler/guides/use-terminal-sessions/).

## Restart a VM

To stop a VM and start it again in the same boot mode, run the following
command:

```sh
pomme restart VM_NAME
```

Replace `VM_NAME` with the name of the VM.

To restart into a different boot mode, pass `--mode normal` or
`--mode recovery`. The `--timeout` flag works the same way as it does for
`pomme start`.

The command output shows the stop result and then the boot result. If the stop
had to power off the VM, the output says so. In structured output, the
top-level `stopMethod` field reports how the VM stopped, and `steps` lists the
status, stop, and boot steps in order.

## Freeze and thaw

Pausing a VM freezes the guest in memory without shutting it down. To pause a
running VM, run the following command:

```sh
pomme pause VM_NAME
```

To continue running the paused VM, run the following command:

```sh
pomme resume VM_NAME
```

Replace `VM_NAME` with the name of the VM.

Durable terminal sessions stay attached to the VM while it's paused. They
don't even notice. The System is a little jealous.

## Delete a VM

Deleting a VM removes its bundle, including its disk image, from
`~/Library/Application Support/pomme`. You can't undo a deletion. This is the
part the viewers came for.

To delete a stopped VM, do the following:

1. Stop the VM:

   ```sh
   pomme stop VM_NAME
   ```

1. Delete the VM:

   ```sh
   pomme delete VM_NAME
   ```

1. When Pomme asks you to confirm, enter `y`.

Replace `VM_NAME` with the name of the VM.

`pomme rm` is an alias for `pomme delete`. The confirmation prompt requires an
interactive terminal. Without one, the command fails unless you pass
`--force`.

To delete a VM without a prompt, whether or not it's running, pass `--force`:

```sh
pomme delete VM_NAME --force
```

To delete every VM, pass `--all`. The confirmation prompt lists each VM that
the command deletes. Read the list, Crawler. All of it.

With `--force`, Pomme stops a running VM with the same shutdown sequence as
`pomme stop`, so it can power off the VM if the guest doesn't shut down in
time. Pomme then waits for the VM's helper process to exit before it removes
the bundle. If Pomme can't confirm that the VM stopped or that the helper
exited, it keeps the VM bundle and reports an error.

:::danger[Death Notice]
`pomme delete --force` deletes the VM without asking for confirmation, and
`pomme delete --all --force` deletes every VM. Check the VM names before you
run either command in a script. Crawlers who skip this check end their
episode with an empty `pomme list` and a sponsor gift of a single tissue.
:::

## Next floor

- [Save and restore snapshots](/crawler/guides/use-snapshots/)
- [Run commands in a VM](/crawler/guides/run-guest-commands/)
- [Use the terminal UI](/crawler/guides/use-the-tui/)
- [`pomme start` reference](/crawler/reference/cli/pomme-start/)
- [`pomme stop` reference](/crawler/reference/cli/pomme-stop/)
