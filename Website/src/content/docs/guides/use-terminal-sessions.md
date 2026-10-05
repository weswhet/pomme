---
title: Use durable terminal sessions
description: Open interactive guest shells that you can detach from, reattach to, and replay.
---

This guide shows you how to open interactive terminal sessions in a VM, detach
from them, and reattach later. A Pomme terminal session is *durable*: the guest
program keeps running when your host terminal disconnects, and Pomme keeps a
transcript of its output that you can replay.

## Before you begin

- Start the VM. For details, see
  [Manage the VM lifecycle](/guides/manage-vm-lifecycle/).
- Use an interactive host terminal. Attaching to a session requires a
  terminal for both standard input and standard output.

## Open a shell session

To open an interactive shell in the guest, run `pomme shell` without an
expression:

```sh
pomme shell VM_NAME
```

Replace `VM_NAME` with the name of the VM.

Pomme creates a session that runs `/bin/sh` as `root` and attaches your
terminal to it. To run the shell as another user, pass `--user USER_NAME`.
Other flags from [Run commands in a VM](/guides/run-guest-commands/), such as
`--cwd` and `--env`, also apply.

To run a different interactive program as a session, use `pomme exec --pty`:

```sh
pomme exec VM_NAME --pty -- /bin/zsh
```

Interactive sessions don't accept `--timeout` and don't support JSON or JSONL
output.

## Detach from a session

To detach your terminal and leave the session running, type `~.` at the start
of a line. To send a literal `~` at the start of a line, type `~~`.

If your host terminal closes or loses its connection, Pomme also detaches. It
doesn't send a signal to the guest program, which keeps running.

To create a session without attaching to it, pass `--detach` (`-d`):

```sh
pomme shell VM_NAME --detach
pomme exec VM_NAME --pty --detach -- /usr/bin/top
```

Pomme prints the new session ID.

## List and inspect sessions

To list the terminal sessions of a VM, run the following command:

```sh
pomme sessions list VM_NAME
```

To show the details of one session, run the following command:

```sh
pomme sessions inspect VM_NAME --session SESSION_ID
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `SESSION_ID`: the session ID, a UUID, from `pomme sessions list`.

## Reattach to a session

To reattach your terminal to a running session, run the following command:

```sh
pomme sessions attach VM_NAME --session SESSION_ID
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `SESSION_ID`: the ID of the session.

Only one terminal can be attached to a session at a time. If another terminal
is attached, pass `--takeover` to replace that attachment.

To replay earlier output when you attach, use one of the following flags:

- `--from-start`: replay the whole transcript from the beginning.
- `--from-offset BYTES`: replay from an exact byte offset in the transcript.

## Read a session transcript

To print a session's transcript without attaching, run the following command:

```sh
pomme sessions logs VM_NAME --session SESSION_ID
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `SESSION_ID`: the ID of the session.

By default, Pomme prints the transcript from the beginning. To start at a byte
offset, pass `--from-offset BYTES`. To keep printing new output until the
session exits or is lost, pass `--follow`.

## End a session

To end a running session, run the following command:

```sh
pomme sessions terminate VM_NAME --session SESSION_ID
```

Pomme sends `SIGHUP` to the session. If the program doesn't exit, pass
`--force` to send `SIGKILL` instead.

Replace the following:

- `VM_NAME`: the name of the VM.
- `SESSION_ID`: the ID of the session.

## Delete a session

After a session exits or is lost, its record and transcript stay on the host
until you delete them. To delete a session, run the following command:

```sh
pomme sessions delete VM_NAME --session SESSION_ID
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `SESSION_ID`: the ID of an exited or lost session.

## Understand when sessions end

Sessions survive a paused VM: they stay attached while the VM is paused and
continue after you resume it.

The following events mark a session as *lost*, because they end the guest
program:

- Stopping or restarting the VM.
- Rebooting the guest or changing its boot mode.
- Restoring a snapshot.
- An exit of the VM's helper process or of the guest agent.

In normal macOS, Pomme keeps the transcript of a lost session so that you can
read it with `pomme sessions logs` before you delete it.

### Sessions in Recovery

You can also open a shell session while the VM runs macOS Recovery. To admit
the session, Pomme navigates the Recovery screens for you. To keep screenshots
of that navigation for troubleshooting, pass `--debug`.

Recovery transcripts aren't saved to disk. Pomme discards them when the helper
process, the guest agent, or the Recovery boot ends.

:::caution
An active terminal session blocks SIP, AMFI, and other Recovery security
workflows. End the VM's sessions with `pomme sessions terminate` before you
run them. For details, see
[Change SIP and AMFI](/guides/change-sip-and-amfi/).
:::

## What's next

- [Run commands in a VM](/guides/run-guest-commands/)
- [`pomme sessions` reference](/reference/cli/pomme-sessions/)
- [`pomme shell` reference](/reference/cli/pomme-shell/)
