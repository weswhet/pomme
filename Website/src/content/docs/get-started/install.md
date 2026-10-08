---
title: Install Pomme
description: Install the Pomme command-line tool with Homebrew, the install script, or the installer package, keep it up to date, or build it from source.
---

This page shows you how to install Pomme, keep it up to date, and confirm that
your shell runs the installed executable.

Pomme publishes two kinds of builds:

- **Stable releases**, such as `0.1.0`, which Homebrew, the install script, and
  the installer package install by default.
- **Alphas**, such as `0.1.0-alpha.3`. Each change to Pomme's `main` branch
  that passes CI publishes one.

Choose an install method:

| Method | Installs | Location | Updates with |
| --- | --- | --- | --- |
| [Homebrew](#install-with-homebrew) | Stable releases | Homebrew's `bin` directory | `pomme update` or `brew upgrade` |
| [Install script](#install-with-the-install-script) | Stable releases or alphas | `~/.local/bin/pomme` | `pomme update` |
| [Installer package](#install-the-installer-package) | Stable releases or alphas | `/usr/local/bin/pomme` | `pomme update` |
| [Source](#build-from-source) | Your checkout | `~/.local/bin/pomme` | Rebuilding |

:::note
Pomme 0.1.0 isn't released yet, so Homebrew has no formula and the install
script has no stable release to install. Until the 0.1.0 release, install an
alpha with the install script, or build Pomme from source.
:::

## Before you begin

Check that your Mac meets the
[system requirements](/get-started/requirements/): a Mac with Apple silicon
and macOS 15 or later. Building from source also needs Xcode and the
project's signing certificate.

## Install with Homebrew

To install the newest stable release with Homebrew, run the following command:

```sh
brew install weswhet/tap/pomme
```

Homebrew installs `pomme` and its shell completions for zsh, bash, and fish.
The formula installs only stable releases.

## Install with the install script

The install script is a Perl program that runs with the Perl that macOS
includes at `/usr/bin/perl`. To install the newest stable release in
`~/.local/bin`, run the following command:

```sh
curl -fsSL https://pommevm.dev/install.pl | perl
```

To install the newest alpha instead, set `POMME_CHANNEL` to `alpha`:

```sh
curl -fsSL https://pommevm.dev/install.pl | POMME_CHANNEL=alpha perl
```

The script does the following:

- Downloads the release's `pomme-VERSION-arm64.tar.gz` and `SHA256SUMS` files
  from GitHub, and checks the tarball against the digest in `SHA256SUMS`.
- Checks that the `pomme` executable has Pomme's Developer ID signature and
  reports the expected version.
- Copies the executable to `~/.local/bin/pomme` in one atomic step.

The script doesn't replace a `pomme` executable that isn't signed like Pomme's
releases, such as a Debug build. Pomme's Keychain items trust only Pomme's
Developer ID signature. To replace such an executable, delete it first. The
script doesn't change your shell startup files. If `~/.local/bin` isn't on
your `PATH`, the script prints the line to add. For details, see
[Add the install directory to your PATH](#add-the-install-directory-to-your-path).

Each option has an environment variable, which you set before `perl`. To pass
an option on the command line instead, put it after `perl -`, such as
`perl - --alpha`. Perl treats anything before the `-` as one of its own
options. The script accepts the following options:

| Environment variable | Option | Description |
| --- | --- | --- |
| `POMME_VERSION=VERSION` | `--version VERSION` | Installs this version, such as `0.1.0-alpha.3`. Use it to return to an earlier version. |
| `POMME_CHANNEL=alpha` | `--alpha` | Installs the newest alpha or stable release, whichever is newer. |
| `POMME_INSTALL_DIR=DIRECTORY` | `--install-dir DIRECTORY` | Installs `pomme` in this directory, which must be an absolute path. The default is `~/.local/bin`. |
| `POMME_PACKAGE=1` | `--package` | Installs with the installer package instead. For details, see the next section. |

To read the script before you run it, download it first:

```sh
curl -fsSL https://pommevm.dev/install.pl -o install.pl
perl install.pl --help
```

## Install the installer package

The installer package installs `pomme` at `/usr/local/bin/pomme` and needs
your administrator password. To download, check, and install the package,
run the following command:

```sh
curl -fsSL https://pommevm.dev/install.pl | POMME_PACKAGE=1 perl
```

The script checks the package against the digest in `SHA256SUMS`, checks its
Developer ID Installer signature, and then runs `sudo installer`. To install an
alpha, also set `POMME_CHANNEL=alpha`.

:::caution
Pomme isn't notarized, so Gatekeeper blocks a package or executable that you
download with a web browser. Download releases with the install script,
Homebrew, `curl`, or `gh release download` instead. These tools don't mark
their downloads for Gatekeeper checks.
:::

To check that a downloaded release file came from Pomme's release workflow,
use `gh`, the GitHub command-line tool:

```sh
gh attestation verify pomme-VERSION-arm64.tar.gz --repo weswhet/pomme
```

## Build from source

The `Scripts/build-local.sh` script builds a signed Release executable and
installs it. To build and install Pomme, follow these steps:

1. Clone the Pomme repository, and go to its root directory:

   ```sh
   git clone https://github.com/weswhet/pomme.git
   cd pomme
   ```

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

A build from source can't update itself. To update it, pull the newest source
and run the build script again.

## Add the install directory to your PATH

If `~/.local/bin` isn't on your `PATH`, the install script and the build script
print a reminder. To add it for zsh, add the following line to `~/.zprofile`,
and then open a new terminal window:

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

   The output is the path of the installed executable, such as the following:

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
   pomme 0.1.0-alpha.3 (9122520)
   ```

1. Optional: list the available commands:

   ```sh
   pomme --help
   ```

## Update Pomme

To update Pomme to the newest release, run the following command:

```sh
pomme update
```

Pomme updates the same way that you installed it:

| Install method | What `pomme update` runs |
| --- | --- |
| Homebrew | `brew upgrade weswhet/tap/pomme`. |
| Install script | The install script, for the new version and the directory that holds your `pomme`. |
| Installer package | The install script with `--package`, which asks for your administrator password. |
| Source | Nothing. The command reports that you need to rebuild Pomme instead. |

An installed alpha updates to the newest alpha or stable release, whichever is
newer. A stable release updates only to newer stable releases. After the
update, Pomme runs the new executable and checks that it reports the new
version.

`pomme update` updates only the `pomme` command on your Mac. To give an
existing VM the agent from the new version, see
[Update the agent](/guides/repair-the-agent/#update-the-agent).

### Check for an update

To check for an update without installing it, run the following command:

```sh
pomme update --check
```

The output looks similar to the following:

```text
Pomme 0.1.0-alpha.5 is available. You have 0.1.0-alpha.3. To update, run `pomme update`.
Release notes: https://github.com/weswhet/pomme/releases/tag/v0.1.0-alpha.5
```

With `--format json`, the command reports the following fields:

| Field | Description |
| --- | --- |
| `installedVersion` | The installed version. After an update, the new version. |
| `latestVersion` | The newest version that this installation can update to. |
| `updateAvailable` | `true` when `latestVersion` is newer than `installedVersion`. |
| `installMethod` | `homebrew`, `standalone` for the install script, or `package`. |
| `channel` | `alpha` when the installation follows alphas, otherwise `stable`. |
| `updated` | `true` when the command installed a new version. |
| `updateCommand` | When an update is available, the command that installs it. |
| `previousVersion` | After an update, the version that the update replaced. |

### Update notices

About once a day, a release build of Pomme checks for a newer version. When one
is available, an interactive command prints a notice on standard error after it
finishes:

```text
Pomme 0.1.0-alpha.5 is available. You have 0.1.0-alpha.3. To update, run `pomme update`.
```

The check never delays a command. It runs in a separate background process,
and its result appears after a later command. Pomme shows the notice at most
once a day for each new version.

Pomme skips the check and the notice in the following cases, so scripts and
coding agents never see them:

- Standard error isn't a terminal.
- The command prints JSON or JSONL output.
- The `CI` environment variable exists.
- You built Pomme from source.

To turn off the check, set `POMME_NO_UPDATE_CHECK` to `1`. Pomme keeps the
result of the check in
`~/Library/Caches/com.github.weswhet.pomme/update-check.json`.

## Keep Keychain access across updates

Pomme stores each VM's agent credential in your login Keychain. macOS grants
Keychain access based on the executable's code-signing designated requirement,
not on its file hash. Pomme's releases, Homebrew's copy, and local builds all
use the same signing identifier, team, and certificate, so an updated or
rebuilt `pomme` keeps access to the Keychain items that earlier versions
created.

For this reason, don't substitute an ad hoc, Apple Development, or unsigned
build for the installed executable. The Debug build configuration is signed ad
hoc and can't read the credentials of existing VMs.

## Uninstall Pomme

To remove the `pomme` executable, run the command for your install method:

| Install method | Command |
| --- | --- |
| Homebrew | `brew uninstall pomme` |
| Install script or source | `rm ~/.local/bin/pomme` |
| Installer package | `sudo rm /usr/local/bin/pomme`, and then `sudo pkgutil --forget com.github.weswhet.pomme` |

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
