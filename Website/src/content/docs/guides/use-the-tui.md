---
title: Use the terminal UI
description: Browse, start, stop, snapshot, and delete Pomme VMs from an interactive terminal UI.
---

This guide shows you how to manage your VMs from Pomme's interactive terminal
UI (TUI). The TUI lists your VMs and offers menus for the common lifecycle,
security, and snapshot operations, so you don't need to remember each command.

## Before you begin

- [Install Pomme](/get-started/install/).
- Use an interactive terminal. The TUI doesn't run when standard input or
  standard output is redirected.

## Open the terminal UI

To open the TUI, run the following command:

```sh
pomme tui
```

To open the TUI with a specific VM selected, pass its name:

```sh
pomme tui VM_NAME
```

Replace `VM_NAME` with the name of the VM.

The TUI opens on the VM dashboard, which lists the VMs that Pomme manages with
their run state and boot mode.

## Move around the dashboard

The dashboard accepts the following keys:

| Key | Action |
| --- | --- |
| Up arrow, Down arrow, `k`, `j` | Move the selection. |
| `Return` | Open the actions menu for the selected VM. |
| `r` | Refresh the VM list. |
| `c` | Create a VM. |
| `d` | Delete the selected VM. |
| `q`, `Esc` | Quit the TUI. |

## Run an action on a VM

To run an action on a VM, do the following:

1. On the dashboard, select the VM and press `Return`.
1. Select an action and press `Return`, or press the action's shortcut key.
   The following table lists the actions:

   | Action | Shortcut | Description |
   | --- | --- | --- |
   | Start Normal | `n` | Start or resume normal macOS. |
   | Boot Recovery | `b` | Start macOS Recovery. |
   | Stop | `x` | Stop the VM. |
   | Pause | `p` | Pause the running VM. |
   | Resume | `r` | Resume the paused VM. |
   | Status | `s` | Show the VM status. |
   | Inspect | `i` | Show detailed inspection output. |
   | Health | `h` | Show the VM health details. |
   | Security | `g` | Open the SIP and AMFI menu. |
   | Snapshots | `v` | Open the snapshot menu. |
   | Destroy | `d` | Delete the VM after you type its name. |
   | Back | | Return to the dashboard. |

1. Wait for the action to finish. While an operation runs, you can't cancel
   it. When it finishes, press `Return`, `q`, or `Esc` to go back, or press `r`
   to go back and refresh.

If you start a VM in a boot mode that differs from the mode it's running in,
the TUI asks you to confirm that it can stop and restart the VM.

In any menu, use the arrow keys or `j` and `k` to move, and press `q` or `Esc`
to go back.

### Change SIP or AMFI

The **Security** menu shows, turns on, and turns off System Integrity
Protection (SIP) and Apple Mobile File Integrity (AMFI). Its actions run the
same workflows as the `pomme sip` and `pomme amfi` commands. Before you use them, read
[Change SIP and AMFI](/guides/change-sip-and-amfi/).

### Manage snapshots

The **Snapshots** menu lists the VM's snapshots, newest first. From this menu,
you can create a snapshot, refresh the list, or select a snapshot to restore or
delete it. Restoring or deleting a snapshot asks you to type a confirmation.
For details about how snapshots work, see
[Save and restore snapshots](/guides/use-snapshots/).

## Create a VM from the terminal UI

To create a VM from the TUI, do the following:

1. On the dashboard, press `c`.
1. Enter a name for the VM. Use 1 to 64 characters: ASCII letters, numbers,
   periods, underscores, and hyphens.
1. Choose a restore source:
   - **Latest IPSW**: the latest signed macOS version.
   - **Version or Build**: a macOS version or build that you enter, with an
     optional Mac model override.
   - **Local Restore Image**: the path to a restore image (IPSW) on the host.
1. Enter a disk size and memory size, or accept the defaults of `60GB` and
   `8GB`.
1. Choose the state after installation: **Do Not Boot**, **Boot Normal**, or
   **Boot Recovery**.

The TUI doesn't create VMs from templates or config files. For those options,
use `pomme create`. For details, see [Create a VM](/guides/create-vms/).

## Delete a VM from the terminal UI

To delete a VM, do the following:

1. On the dashboard, select the VM and press `d`.
1. Read the bundle path that the TUI shows.
1. Type the VM name to confirm, and press `Return`.

You can't undo a deletion.

## What's next

- [Manage the VM lifecycle](/guides/manage-vm-lifecycle/)
- [`pomme tui` reference](/reference/cli/pomme-tui/)
