---
title: Environment variables
description: Environment variables that change how Pomme selects VMs, authorizes security workflows, stores data, and checks for updates.
---

The `pomme` command reads the following environment variables.

| Variable | Description |
| --- | --- |
| `POMME_VM_NAME` | The VM that a command acts on when you omit the VM name. |
| `POMME_AUTHORIZED_USER` | The existing guest owner account that authorizes a SIP or AMFI change. |
| `POMME_AUTHORIZED_PASSWORD` | The password for `POMME_AUTHORIZED_USER`. |
| `POMME_APP_SUPPORT_DIR` | An alternative directory for Pomme's host data. |
| `POMME_NO_UPDATE_CHECK` | Any value other than `0` turns off the daily check for a newer Pomme release. For details, see [Update notices](/get-started/install/#update-notices). |
| `CI` | Any value turns off the daily update check, as `POMME_NO_UPDATE_CHECK` does. |
| `NO_COLOR` | When set, turns off color in the progress display. For details, see [Control the progress display](/guides/script-pomme/#control-the-progress-display). |

## POMME_VM_NAME

Sets the default VM for commands that accept an optional VM name, such as
`pomme status`, `pomme exec`, and `pomme sessions list`, and for the `pomme ui`
commands that take `--vm`. A name that you pass on the command line always
takes precedence.

```sh
export POMME_VM_NAME=dev
pomme status
pomme exec -- /usr/bin/sw_vers
```

Pomme never selects a VM on its own, even if only one VM is running. If you
omit the name and `POMME_VM_NAME` isn't set, the command fails with the
following message and exit code `64`:

```text
Error: Specify a VM name or set POMME_VM_NAME.
```

## POMME_AUTHORIZED_USER and POMME_AUTHORIZED_PASSWORD

Authorize a SIP or AMFI change on a VM that already has an owner account,
including the security changes that `pomme mdm` makes before it enrolls.
Set both variables. If you set only one, Pomme rejects the command.

Pomme passes the password to its credential boundary separately. It never puts
the password in command arguments or in a workflow journal.

:::caution
Environment variables can be visible to other processes that run as your user,
and shells can save them in history. Prefer the interactive prompt or the
Keychain credential that Pomme stores for the VM. If you use these variables,
set them only for the one command, and don't export them in a shell profile.
:::

For details, see [Security workflows](/concepts/security-model/).

## POMME_APP_SUPPORT_DIR

Replaces `~/Library/Application Support/pomme` as the directory where Pomme
stores VMs, templates, restore images, and other host data. Pomme ignores an
empty value.

This variable is intended for isolated testing. VMs and templates in one data
directory are invisible to commands that use another, so a VM that you create
with this variable set doesn't appear in `pomme list` without it.

## Variables named by flags

Some flags take the name of an environment variable instead of a value:

- `pomme ui type --text-env VARIABLE` types the value of `VARIABLE` into the
  guest. Use it to keep secrets out of the command line and shell history.

## What's next

- [Files and paths](/reference/files-and-paths/)
- [Command-line reference](/reference/cli/)
