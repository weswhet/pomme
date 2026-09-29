---
title: Automate the guest display
description: Send keys, text, and clicks to a Pomme VM's display and capture screenshots, in normal macOS or Recovery.
---

This guide shows you how to drive a VM's display from the host: press keys,
type text, click at coordinates, and capture screenshots. The `pomme ui`
commands deliver input directly through the VM's virtual keyboard and pointer
and read its framebuffer, so they work in normal macOS and in Recovery without
a guest agent.

These commands don't open a host window, move the host pointer, or change the
frontmost app on the host.

## Before you begin

- Start the VM. For example, to start it in Recovery, run
  `pomme start VM_NAME --mode recovery`.
- Don't send manual input while Pomme is provisioning the VM automatically,
  for example during `pomme create` or a SIP change. Automatic provisioning
  owns an exclusive lease on the VM's display, and manual input can disrupt
  its navigation.
- Run one `pomme ui` command at a time for each VM. If another display
  operation is in progress, the command fails with
  `A direct VM UI operation is already in progress.`

## Capture a screenshot

To see what's on the guest display, save a screenshot to a PNG file on the
host:

```sh
pomme ui screenshot VM_NAME --output OUTPUT_PATH
```

Replace the following:

- `VM_NAME`: the name of your VM.
- `OUTPUT_PATH`: the host file to write, for example
  `/private/tmp/pomme-lab/screen.png`. The parent directory must already
  exist, and the path can't be a directory or a symbolic link.

:::caution
Screenshots can show private information from the guest, especially in
Recovery. Save them in a private temporary directory outside your source
repository, and delete them when you're done.
:::

## Press a key

To press one key or key combination, run `pomme ui key`:

```sh
pomme ui key VM_NAME return
pomme ui key VM_NAME cmd-shift-t
pomme ui key VM_NAME ctrl-f2
```

Replace `VM_NAME` with the name of your VM.

Modifier prefixes chain from left to right, and you can use `+` in place of
`-`. For example, `cmd+shift+t` is the same as `cmd-shift-t`. To list the key
names, modifiers, and aliases that Pomme accepts, run `pomme ui keys`, or see
[Key names](/reference/key-names/).

Pomme doesn't accept numeric HID scan codes.

## Press a sequence of keys

To press several keys in order, run `pomme ui key-sequence`:

```sh
pomme ui key-sequence VM_NAME down down return
```

Replace `VM_NAME` with the name of your VM.

If you set `POMME_VM_NAME` and omit the VM name, Pomme can't always tell
whether the first value is a VM name or a key. In that case, name the VM with
`--vm`:

```sh
pomme ui key-sequence --vm VM_NAME left right
```

## Type text

To type text into the focused field, run `pomme ui type`. Supply the text in
exactly one of the following ways:

- As a positional argument:

  ```sh
  pomme ui type VM_NAME 'hello world'
  ```

- With `--text`:

  ```sh
  pomme ui type VM_NAME --text '/usr/bin/id -u'
  ```

- With `--text-env`, which reads the text from a host environment variable:

  ```sh
  pomme ui type VM_NAME --text-env VARIABLE_NAME
  ```

Replace the following:

- `VM_NAME`: the name of your VM.
- `VARIABLE_NAME`: the name of an environment variable that contains the text.

Use `--text-env` for secrets such as passwords, so that the value doesn't
appear in your command line or shell history. If the variable isn't set, the
command fails before it types anything.

Pomme types any single character on a US keyboard. An uppercase letter or a
shifted symbol implies Shift.

To replace the contents of the focused field instead of adding to them, add
`--replace`. Pomme presses Command-A before it types.

## Click a point on the display

To click a point on the guest display, give its coordinates in points, measured
from the top-left corner:

```sh
pomme ui click VM_NAME --x 640 --y 400
```

Replace `VM_NAME` with the name of your VM. Coordinates must be zero or
greater. Pomme VMs use a 1280 × 800 display.

To find coordinates, capture a screenshot first and measure the element's
position.

## Set a time limit

Each `pomme ui` command that talks to a VM accepts `--timeout` in seconds. For
example:

```sh
pomme ui screenshot VM_NAME --output OUTPUT_PATH --timeout 30
```

## About guided automation

`pomme ui ai settings` is reserved for guided System Settings automation. It's
unavailable in this build because it needs a guest accessibility bridge. To
automate System Settings, use explicit `ui key`, `ui type`, `ui click`, and
`ui screenshot` commands.

## What's next

- [Key names](/reference/key-names/)
- [`pomme ui` reference](/reference/cli/pomme-ui/)
- [Use Pomme in scripts and coding agents](/guides/script-pomme/)
