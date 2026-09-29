---
title: Save and restore snapshots
description: Capture a running VM's machine state as a named snapshot, and restore, list, or delete snapshots.
---

This guide shows you how to save the machine state of a running VM as a named
snapshot, and how to restore it later. Restoring a snapshot returns the guest's
memory and device state to the moment you saved it.

## Before you begin

- Make sure that the VM runs normal macOS and is running or paused. You can't
  create a snapshot of a stopped VM or of a VM in Recovery. For instructions,
  see [Manage the VM lifecycle](/guides/manage-vm-lifecycle/).
- Finish any SIP or AMFI operation on the VM. Snapshots are unavailable while
  a security operation is in progress. For details, see
  [Change SIP and AMFI](/guides/change-sip-and-amfi/).

## Understand what a snapshot contains

A Pomme snapshot is a saved-state snapshot. It stores the VM's machine state
only: the guest's memory and device state. It doesn't copy the VM's disk image
(`Disk.img`) or its auxiliary storage.

When you create a snapshot, Pomme records fingerprints of the disk image, the
auxiliary storage, and the VM's identity and configuration. When you restore
the snapshot, Pomme compares them with the VM's current files. Any difference
is called *drift*:

- A change to the disk image (`disk`) or auxiliary storage
  (`auxiliaryStorage`) is expected after the guest writes to its disk. You can
  accept this drift when you restore.
- A change to the VM's identity or configuration (`vmUUID`, `configuration`,
  `hardwareModel`, or `machineIdentifier`) always blocks the restore.

:::caution
Restored memory doesn't match a disk that changed after the snapshot. After a
restore with disk drift, the guest might see stale or inconsistent file system
state. Use snapshots for short-lived experiments, not as backups.
:::

## Create a snapshot

To create a snapshot, run the following command:

```sh
pomme snapshot create VM_NAME SNAPSHOT_NAME
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `SNAPSHOT_NAME`: a name for the snapshot. Use 1 to 64 characters: ASCII
  letters, numbers, periods, underscores, and hyphens. The first character must
  be a letter or number.

If the VM is running, Pomme pauses it, saves the machine state, and then
resumes it. If the VM is already paused, it stays paused. If you set
`POMME_VM_NAME`, you can omit `VM_NAME` and pass only the snapshot name.

## List snapshots

To list the snapshots of a VM, newest first, run the following command:

```sh
pomme snapshot list VM_NAME
```

Replace `VM_NAME` with the name of the VM.

The output shows each snapshot's creation time, the state the VM was in when
you saved it, any recorded drift, and the size of the saved machine state.

## Restore a snapshot

To restore a snapshot, do the following:

1. Make sure that the VM is running normal macOS, is paused, or is stopped.
   You can't restore a snapshot while the VM is in Recovery.
1. Run the following command:

   ```sh
   pomme snapshot restore VM_NAME SNAPSHOT_NAME
   ```

   Replace the following:

   - `VM_NAME`: the name of the VM.
   - `SNAPSHOT_NAME`: the name of the snapshot to restore.

1. If Pomme reports drift, read the warning. Pomme lists the kinds of drift that
   it found.
1. When Pomme asks you to confirm, enter `y`.

After the restore, the VM is paused. To continue running it, run
`pomme resume VM_NAME`.

If the VM was running when you started the restore, Pomme saves its current
machine state first. If the restore fails, Pomme uses that saved state to put
the VM back the way it was.

Restoring a snapshot ends the VM's
[durable terminal sessions](/guides/use-terminal-sessions/). Their normal-boot
transcripts remain available for inspection.

### Restore without a prompt

The confirmation prompt requires an interactive terminal. To restore from a
script, pass `--force`:

```sh
pomme snapshot restore VM_NAME SNAPSHOT_NAME --force
```

`--force` skips the prompt and accepts disk and auxiliary storage drift. It
doesn't override identity or configuration drift.

## Delete a snapshot

To delete a snapshot, do the following:

1. Run the following command:

   ```sh
   pomme snapshot delete VM_NAME SNAPSHOT_NAME
   ```

   Replace the following:

   - `VM_NAME`: the name of the VM.
   - `SNAPSHOT_NAME`: the name of the snapshot to delete.

1. When Pomme asks you to confirm, enter `y`.

You can't undo a deletion. To delete without a prompt, pass `--force`.

## What's next

- [Manage the VM lifecycle](/guides/manage-vm-lifecycle/)
- [VM lifecycle and boot modes](/concepts/vm-lifecycle/)
- [`pomme snapshot` reference](/reference/cli/pomme-snapshot/)
