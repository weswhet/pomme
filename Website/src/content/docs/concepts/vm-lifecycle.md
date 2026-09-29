---
title: VM lifecycle and boot modes
description: The states a Pomme VM can be in, the two boot modes, and what happens when you start, stop, pause, restart, or delete a VM.
---

A Pomme VM is always in one of a small number of run states, and a running VM
is booted in one of two modes. This page explains those states and modes, how
the lifecycle commands move a VM between them, and how each transition affects
work that's running in the guest.

## Run states

A VM is in one of the following run states:

- **Stopped**: the VM isn't running and no helper process is attached to it.
- **Running in normal macOS**: the guest has booted its regular startup
  volume. The persistent guest agent connects, so you can run guest programs,
  transfer files, and use terminal sessions.
- **Running in Recovery**: the guest has booted macOS Recovery. Only the
  bounded Recovery workflows are available, such as security changes, agent
  repair, and Recovery terminal sessions.
- **Paused**: the VM is suspended in memory. A paused VM remembers the boot
  mode it was paused in and returns to that mode when you resume it.

To see the current state of a VM, run `pomme status VM_NAME`. For
configuration and guest agent details, run `pomme inspect VM_NAME`.

## Boot modes

A running VM uses one of two boot modes:

- `normal`: the guest boots macOS from its startup volume. This is the
  default mode for `pomme start`.
- `recovery`: the guest boots macOS Recovery. To start a VM in this mode, run
  `pomme start VM_NAME --mode recovery`.

When you create a VM, you also choose the state that it's left in after
creation. The `--boot` flag accepts three values:

- `normal` (the default): the VM stays running in normal macOS after Pomme
  verifies the guest agent. This is the same boot that proved the agent works.
- `none`: Pomme shuts the guest down through the agent and stops the VM. The
  `--shutdown` flag is a shorter way to request this state.
- `recovery`: Pomme restarts the VM in Recovery. The `--recovery` flag is a
  shorter way to request this state.

## The VM helper

Each running VM is owned by a background helper process on the host. The
helper starts when the VM starts and keeps running after the command that
started it exits, so the VM continues to run while you use other commands.
Commands such as `pomme exec` and `pomme ui` reach the VM through its helper.
When the VM stops, its helper exits.

Virtualization.framework runs at most two macOS guests at the same time. This
limit also applies to parallel creation from a config file, which creates at
most two VMs at once.

## Stopping a VM

`pomme stop` prefers to let macOS shut itself down cleanly, because the
framework's stop request alone behaves like a power button that macOS can
take a minute or more to act on. The stop sequence works as follows:

1. If the VM is paused, Pomme resumes it first. A paused guest can't shut
   itself down.
2. If the VM is running normal macOS and the guest agent is connected, Pomme
   asks the guest to shut down and then sends the framework's stop request.
   The guest has up to 120 seconds to power off.
3. In every other case, including a VM running in Recovery, Pomme sends only
   the framework's stop request and waits up to 30 seconds.
4. If the VM is still running when the wait ends, the helper stops the VM
   outright.

Pomme reports how each stop ended, so an unclean stop is never silent. In
structured output, the `stopMethod` field has one of the following values:

| Value | Meaning |
| --- | --- |
| `guest-stopped` | The guest powered itself off. |
| `forced` | Pomme stopped the VM outright, like pulling a power cord. |
| `already-stopped` | The VM was already stopped, so nothing changed. |

`pomme stop --force` skips the graceful sequence, including resuming a paused
VM, and stops the VM outright. It always reports `forced`.

:::caution
A forced stop can leave the guest's file systems in an inconsistent state,
the same as removing power from a physical Mac. Use `--force` only when a
graceful stop doesn't finish.
:::

## Restarting, pausing, and resuming

`pomme restart` stops the VM with the same sequence as `pomme stop` and then
starts it again. The VM restarts in the boot mode it was running in, unless
you choose a different one with `--mode`. If the stop had to be forced, the
restart output shows that result before the boot result.

`pomme pause` suspends a running VM in memory, and `pomme resume` continues it
in the same boot mode. `pomme start` also resumes a paused VM.

## Deleting a VM

`pomme delete` removes a VM's bundle, including its disk image. Without
`--force`, the VM must already be stopped, and Pomme asks you to confirm.

`pomme delete --force` skips the confirmation. If the VM is running, Pomme
stops it with the normal stop sequence, waits for the helper to exit, and
verifies the exit before it removes the bundle. If Pomme can't confirm the
stop or the helper's exit, it keeps the bundle.

## Effect on terminal sessions

Durable terminal sessions are tied to one boot of one VM. The lifecycle
commands affect them as follows:

- **Pause and resume** keep live sessions attached. You can keep using them
  after the VM resumes.
- **Stop, restart, a guest reboot, a boot-mode change, and a snapshot restore**
  mark every session on that VM as lost. The transcripts of normal-macOS
  sessions stay available so you can read and delete them. Recovery
  transcripts exist only for the life of the Recovery boot.

Active terminal sessions also block Recovery security workflows until you
end them with `pomme sessions terminate`. For details, see
[Use durable terminal sessions](/guides/use-terminal-sessions/).

## What's next

- Start, stop, and delete VMs in
  [Manage the VM lifecycle](/guides/manage-vm-lifecycle/).
- Learn what happens before a new VM first reaches a run state in
  [Durable creation and journals](/concepts/durable-creation/).
- Learn how security workflows use Recovery in
  [Security workflows](/concepts/security-model/).
