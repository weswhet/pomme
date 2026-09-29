---
title: "Quickstart: create your first VM"
description: Create a template, clone a VM from it, run commands in the guest, and clean up.
---

In this quickstart, you create a macOS template, clone a VM from it, run
commands inside the guest, copy a file into it, and then remove everything you
created.

## Before you begin

- [Install Pomme](/get-started/install/), and confirm that
  `pomme --version` works.
- Make sure that your login Keychain is unlocked.
- Make sure that the host has internet access and enough free disk space for
  a restore image of about 20 GB plus the VM disks that you create.

## Create a template

Restoring a macOS image is the slowest part of creating a VM. A template does
that work once so that later VMs can clone it instead of restoring again.

To create a template from the latest signed macOS version, run the following
command:

```sh
pomme template create base --latest --disk-size 40GB
```

Pomme downloads the restore image, if it isn't already cached, and restores it
into the template. The restore itself takes about four minutes for a 20 GB
image, plus the time to download the image.

Every VM that you clone from this template gets a 40 GB disk.

## Create a VM from the template

To clone a VM named `dev` from the template, run the following command:

```sh
pomme create dev --from-template base --memory 4GB
```

Pomme clones the template's disk, installs and verifies the Pomme guest agent,
and leaves the VM running in normal macOS. Pomme records each creation step
in a journal. If creation is interrupted, you can continue it with
`pomme create dev --resume`.

To check the VM's state, run the following command:

```sh
pomme status dev
```

## Run a command in the guest

To run a program in the guest and print its output, use `pomme exec`. Put the
program and its arguments after `--`:

```sh
pomme exec dev -- /usr/bin/sw_vers
```

The output is the guest's macOS version:

```text
ProductName:		macOS
ProductVersion:		26.6.2
BuildVersion:		25G83
```

Your version and build depend on the restore image that you installed.

## Open a shell in the guest

To open an interactive shell in the guest, run the following command:

```sh
pomme shell dev
```

The shell runs as `root` by default. To leave the shell, type `exit`. To
detach and leave the shell running, type `~.` at the start of a line. For more
about detached shells, see
[Use durable terminal sessions](/guides/use-terminal-sessions/).

## Copy a file into the guest

To copy a file from the host into the guest and read it back, follow these
steps:

1. Create a file on the host:

   ```sh
   echo "Hello from the host" > hello.txt
   ```

1. Copy the file into the guest's `/tmp` directory:

   ```sh
   pomme cp hello.txt dev:/tmp/hello.txt
   ```

1. Read the file from the guest:

   ```sh
   pomme cat dev:/tmp/hello.txt
   ```

   The output is the file's contents:

   ```text
   Hello from the host
   ```

## Clean up

To avoid using host disk space and memory, remove the resources that you
created in this quickstart.

1. Stop the VM:

   ```sh
   pomme stop dev
   ```

   Pomme asks the guest to shut down and waits for it. If the guest doesn't
   shut down in time, Pomme powers it off and says so.

1. Delete the VM:

   ```sh
   pomme delete dev
   ```

   Pomme asks you to confirm the deletion.

1. Optional: if you don't plan to create more VMs from the template, delete it:

   ```sh
   pomme template delete base
   ```

1. Delete the local test file:

   ```sh
   rm hello.txt
   ```

:::caution
Deleting a VM or a template can't be undone.
:::

## What's next

- [Create a VM](/guides/create-vms/)
- [Use templates](/guides/use-templates/)
- [Run commands in a VM](/guides/run-guest-commands/)
- [Architecture](/concepts/architecture/)
