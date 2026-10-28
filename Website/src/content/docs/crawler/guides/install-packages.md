---
title: Install loot (packages)
description: Drop a macOS installer package from the host into a running VM and make it stick.
---

Sponsor crates don't open themselves, Crawler. This guide shows you how to
install a macOS installer package (`.pkg`) from the host in a running VM with
`pomme install`. Pomme copies the package into the guest and runs the macOS
`installer` command there through the authenticated guest agent, so the guest
doesn't need file sharing or a network connection.

## Before you descend

- Start the VM in normal macOS, and make sure that its guest agent is
  connected. For details, see
  [Manage the VM lifecycle](/crawler/guides/manage-vm-lifecycle/).
- Have the package on the host as a flat `.pkg` file, the format that
  `pkgbuild` and `productbuild` produce.

## Install a package

To install a package, run the following command:

```sh
pomme install VM_NAME --pkg PACKAGE_PATH
```

Replace the following:

- `VM_NAME`: the name of the VM. If you omit it, Pomme uses the
  `POMME_VM_NAME` environment variable.
- `PACKAGE_PATH`: the absolute or relative path of the package on the host.

For example, the following command installs `Tool.pkg` in the VM named `dev`:

```sh
pomme install dev --pkg ./Tool.pkg
```

When the installation succeeds, the output looks similar to the following:

```text
Installed Tool.pkg in dev.
```

Pomme inspects the crate on the host before it bothers the guest. The path
must end in `.pkg`, in any letter case, and name a regular file that starts
with the header of a flat package. Pomme refuses a folder, such as an older
bundle package, and any other file. A symbolic link to a package works:
Pomme copies the file that the link points to and keeps the name of the link.

## Understand how an installation works

Here's the trick, step by step. No sleight of hand, the viewers checked.
`pomme install` takes the following steps:

1. It creates a new folder in the guest at
   `/private/var/tmp/pomme-install-ID`, where `ID` is a random identifier.
   Only `root` can read the folder.
1. It copies the package into the folder. The copy works like
   `pomme cp`: the guest verifies the file's SHA-256 digest before it commits
   the file. For details, see [Smuggle files](/crawler/guides/transfer-files/).
1. As `root`, it runs `/usr/sbin/installer -pkg PACKAGE -target /`, which
   installs the package on the guest's startup volume.
1. When the installer exits, it removes the folder and the copy of the
   package in it. It removes them after a failed installation too.

If Pomme can't remove the folder, it prints a warning with the command that
removes it, and the installation result doesn't change. Litter is a warning,
not a disqualification.

By default, Pomme waits up to 1800 seconds (30 minutes) for the installer. To
change the limit, pass `--timeout SECONDS`, up to 86400 seconds (one day):

```sh
pomme install VM_NAME --pkg PACKAGE_PATH --timeout 3600
```

The installer runs as a background job in the guest, so the 300-second limit
of `pomme exec` doesn't apply. Big crates get big clocks.

## When the crate explodes

When the installer fails, `pomme install` prints the installer's output and
an error with the code `guest-package-install-failed`, and exits with the
installer's exit status. For more detail, read the guest's installation log:

```sh
pomme exec VM_NAME -- /usr/bin/tail -n 50 /var/log/install.log
```

If the installer doesn't finish within the time limit, `pomme install` exits
with `124`. The installer might still be running in the guest, so Pomme
leaves the package in its folder and prints the installer's job ID and the
folder's path. To wait for the installer, run the following command:

```sh
pomme jobs wait VM_NAME --job JOB_ID --timeout 3600
```

After the wait reports that the job exited, remove the folder:

```sh
pomme exec VM_NAME -- /bin/rm -rf STAGING_FOLDER
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `JOB_ID`: the job ID that Pomme printed.
- `STAGING_FOLDER`: the folder that Pomme printed.

If you interrupt `pomme install` while it waits, for example with Control+C,
the installer keeps running in the guest, and the package stays in its
folder. Walking away from a ticking crate doesn't stop the timer. Use
`pomme jobs list VM_NAME` to find the job.

## Use the result in a script

With `--format json`, the result contains the following fields, in addition
to the fields that every result has:

| Field | Meaning |
| --- | --- |
| `package` | The package's filename. |
| `stagedPath` | The path of the package's copy in the guest. |
| `bytes`, `sha256` | The size and digest of the copied package. |
| `jobID` | The installer's background job ID. |
| `exitCode` | The installer's exit status. |
| `stdout`, `stderr` | The installer's output. |
| `stagingRemoved` | Whether Pomme removed the staging folder. |
| `stagingCleanupError` | Why Pomme couldn't remove the staging folder, when it couldn't. |

For the fields that every result has, see
[Structured output](/crawler/reference/structured-output/).

## Next floor

- [Smuggle files](/crawler/guides/transfer-files/)
- [Run commands in a VM](/crawler/guides/run-guest-commands/)
- [`pomme install` reference](/crawler/reference/cli/pomme-install/)
- [Exit codes](/crawler/reference/exit-codes/)
