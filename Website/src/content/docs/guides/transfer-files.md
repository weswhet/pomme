---
title: Transfer files
description: Copy files between the host and a VM, and read guest files from the host.
---

This guide shows you how to copy files between the host and a VM with
`pomme cp`, and how to read part of a guest file with `pomme cat`. Both
commands use the authenticated guest agent, so the guest doesn't need file
sharing or a network connection.

## Before you begin

- Start the VM in normal macOS, and make sure that its guest agent is
  connected. For details, see
  [Manage the VM lifecycle](/guides/manage-vm-lifecycle/).

## Name a guest file

A guest file is written as the VM name, a colon, and an absolute guest path:

```text
VM_NAME:/absolute/guest/path
```

A host file is an ordinary absolute or relative path on the host.

## Copy a file to the VM

To copy a host file into the guest, run the following command:

```sh
pomme cp HOST_PATH VM_NAME:GUEST_PATH
```

Replace the following:

- `HOST_PATH`: the path of a regular file on the host.
- `VM_NAME`: the name of the VM.
- `GUEST_PATH`: the absolute destination path in the guest.

For example, the following command copies `input.txt` to `/tmp/input.txt` in
the VM named `dev`:

```sh
pomme cp ./input.txt dev:/tmp/input.txt
```

If the destination ends in `/`, Pomme treats it as a folder and keeps the
source filename. For example, `dev:/tmp/` becomes `dev:/tmp/input.txt`.

## Copy a file from the VM

To copy a guest file to the host, reverse the arguments:

```sh
pomme cp VM_NAME:GUEST_PATH HOST_PATH
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `GUEST_PATH`: the absolute path of the file in the guest.
- `HOST_PATH`: the destination path on the host. Its parent folder must exist.

If `HOST_PATH` ends in `/` or names an existing host folder, Pomme keeps the
guest filename.

## Understand how copies work

`pomme cp` copies one regular file at a time. It has the following limits:

- One endpoint must be on the host and the other in the guest. You can't copy
  from one VM to another, or from host to host.
- The source must be a regular file. Folders and symbolic links aren't
  supported. To copy a folder, create an archive with `tar` or `ditto`, copy
  the archive, and extract it on the other side.
- Pomme refuses to follow symbolic links on the way to the destination.

Pomme writes the file to a temporary staging file next to the destination, and
moves it into place only after the whole file arrives. When you copy to the
guest, the guest verifies the file's SHA-256 digest before it commits the
file. If the source file changes during the copy, the copy fails. An
interrupted or failed copy doesn't leave a partial file at the destination.

When the copy finishes, Pomme prints the number of bytes that it copied.

## Read part of a guest file

To print a guest file from the host without copying it, use `pomme cat`:

```sh
pomme cat VM_NAME:GUEST_PATH
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `GUEST_PATH`: the absolute path of the file in the guest.

`pomme cat` reads a single chunk of at most 32 KiB. To read a different part of
the file, use the following flags:

- `--offset BYTES`: start reading at this byte offset. The default is `0`.
- `--count BYTES`: read at most this many bytes, from `0` to `32768`.

With `--format json`, the output contains the data in the `dataBase64` field,
the number of bytes read in `bytes`, and an `eof` field that's `true` when the
read reached the end of the file. To read a larger file, copy it to the host
with `pomme cp`.

## What's next

- [Run commands in a VM](/guides/run-guest-commands/)
- [`pomme cp` reference](/reference/cli/pomme-cp/)
- [`pomme cat` reference](/reference/cli/pomme-cat/)
