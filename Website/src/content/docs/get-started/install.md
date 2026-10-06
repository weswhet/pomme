---
title: Install Pomme
description: Build, sign, and install the Pomme command-line tool from source.
---

This page shows you how to build Pomme from source, install it, and confirm
that your shell runs the installed executable.

:::note
Pomme is pre-release software at version 0.1.0. It isn't published: there is
no Homebrew formula or installer package. Build Pomme from source to use it.
:::

## Before you begin

- Check that your Mac meets the
  [system requirements](/get-started/requirements/), including a full Xcode
  installation and the project's Developer ID Application certificate.
- Clone the Pomme repository.

## Build and install

The `Scripts/build-local.sh` script builds a signed Release executable and
installs it. To build and install Pomme, follow these steps:

1. In a terminal, go to the root of the Pomme repository.
1. Run the build script as your normal user. Don't use `sudo`.

   ```sh
   bash Scripts/build-local.sh
   ```

   The script does the following:

   - Builds the `arm64` Release configuration with `xcodebuild`.
   - Signs the executable with the project's Developer ID certificate, the
     `com.github.weswhet.pomme` signing identifier, Hardened Runtime, and a
     secure timestamp.
   - Verifies the signature, and checks that the only entitlement is
     `com.apple.security.virtualization`.
   - If a `pomme` executable is already installed, checks that the new build
     has the same designated requirement before it replaces the old one.
   - Keeps a copy of each signed executable, indexed by its SHA-256 digest, so
     that an interrupted VM creation can resume with the exact agent it
     started with.
   - Copies the executable to `~/.local/bin/pomme` in one atomic step.

   If any check fails, the script stops and leaves the installed executable
   unchanged.

To install to a different directory, pass an absolute path with
`--install-dir`:

```sh
bash Scripts/build-local.sh --install-dir INSTALL_DIRECTORY
```

Replace `INSTALL_DIRECTORY` with the absolute path of the directory that
receives the `pomme` executable.

## Add the install directory to your PATH

If `~/.local/bin` isn't on your `PATH`, the script prints a reminder. To add
it for zsh, add the following line to `~/.zprofile`, and then open a new
terminal window:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Verify the installation

To confirm that your shell runs the executable you just installed, follow these
steps:

1. Check which executable your shell finds:

   ```sh
   command -v pomme
   ```

   The output is the path of the installed executable:

   ```text
   /Users/USERNAME/.local/bin/pomme
   ```

1. Check the version:

   ```sh
   pomme --version
   ```

   The output shows the version and the commit that the executable was built
   from:

   ```text
   pomme 0.1.0 (e1f331d)
   ```

1. Optional: list the available commands:

   ```sh
   pomme --help
   ```

## Keep Keychain access across rebuilds

Pomme stores each VM's agent credential in your login Keychain. macOS grants
Keychain access based on the executable's code-signing designated requirement,
not on its file hash. As long as each build uses the same signing identifier,
team, and certificate, a rebuilt `pomme` keeps access to the Keychain items
that earlier builds created.

For this reason, don't substitute an ad hoc, Apple Development, or unsigned
build for the installed executable. The Debug build configuration is signed ad
hoc and can't read the credentials of existing VMs.

## About package installs

The repository can also produce an installer package. A package install places
the host executable at `/usr/local/bin/pomme`. Inside each guest, the agent is
installed at `/usr/local/libexec/pomme` and runs under the launchd label
`com.github.weswhet.pomme.agent`. The package isn't published for the 0.1.0
release.

## Uninstall Pomme

To remove the `pomme` executable, delete it:

```sh
rm ~/.local/bin/pomme
```

Removing the executable doesn't delete your VMs, templates, or restore images.
Pomme stores them in `~/Library/Application Support/pomme`. For the layout of
that directory, see [Files and paths](/reference/files-and-paths/).

:::danger
Deleting `~/Library/Application Support/pomme` permanently deletes every
Pomme VM, template, snapshot, and downloaded restore image. To remove
individual VMs, use `pomme delete` instead.
:::

## What's next

- [Quickstart: create your first VM](/get-started/quickstart/)
- [Files and paths](/reference/files-and-paths/)
- [Troubleshooting](/resources/troubleshooting/)
