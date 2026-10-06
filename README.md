# Pomme

Pomme is a command-line tool for creating and controlling macOS virtual
machines (VMs) on Mac computers with Apple silicon. It's built with Swift and
Virtualization.framework, and it manages only the VMs that it creates in
`~/Library/Application Support/pomme`.

For guides and the complete command-line reference, see the documentation at
<https://pommevm.dev>.

> [!WARNING]
> Pomme is beta software. Commands, flags, output formats, and behavior can
> change or break from one release to the next. If you use Pomme in scripts,
> read the [release notes](https://pommevm.dev/resources/release-notes/)
> before you update.

## Features

With Pomme, you can do the following:

- Create macOS VMs from a restore image or from a template. Creation is
  journaled, so you can resume it after an interruption.
- Run programs, open shell sessions that survive a disconnect, and copy files.
  An authenticated guest agent does this work, so you don't need SSH or a
  network connection to the guest.
- Save and restore named snapshots of a VM's machine state.
- Turn System Integrity Protection (SIP) and Apple Mobile File Integrity (AMFI)
  on and off, and enroll VMs in mobile device management (MDM). If one of these
  workflows fails, you can run the same command again to resume it.
- Send keys, text, and clicks to the guest display and capture screenshots, in
  normal macOS and in Recovery.
- Get JSON or JSONL output and documented exit codes for scripts and coding
  agents.

## Requirements

- A Mac with Apple silicon.
- macOS 15 or later. Some features, such as first-boot provisioning of macOS 27
  guests, need a macOS 27 host.
- To build Pomme: Xcode 27 or later and the project's Developer ID Application
  certificate.

For memory, disk, and Keychain requirements, see
[System requirements](https://pommevm.dev/get-started/requirements/).

## Install Pomme

Pomme doesn't publish an installer package or a Homebrew formula yet. To use
Pomme, build it from source:

1. Clone the repository:

   ```sh
   git clone https://github.com/weswhet/pomme.git
   cd pomme
   ```

1. Build, sign, and install the `pomme` executable:

   ```sh
   bash Scripts/build-local.sh
   ```

   The script builds a Release executable, signs it with the project's
   Developer ID Application certificate, verifies the signature, and installs
   it at `~/.local/bin/pomme`. If any step fails, it leaves the installed
   executable unchanged.

1. Make sure that `~/.local/bin` is on your `PATH`, and then check the
   version:

   ```sh
   pomme --version
   ```

For other install locations and Keychain details, see
[Install Pomme](https://pommevm.dev/get-started/install/).

## Get started

The following steps create a template, clone a VM from it, and run commands in
the guest:

1. Restore macOS into a template. This is the slow step: the restore takes
   about four minutes, plus the time to download the restore image.

   ```sh
   pomme template create base --latest --disk-size 40GB
   ```

1. Clone a VM named `dev` from the template. Pomme installs and verifies the
   guest agent and leaves the VM running.

   ```sh
   pomme create dev --from-template base --memory 4GB
   ```

1. Run a program in the guest, and then open an interactive shell:

   ```sh
   pomme exec dev -- /usr/bin/sw_vers
   pomme shell dev
   ```

   To leave the shell, type `exit`.

1. When you're done, stop and delete the VM:

   ```sh
   pomme stop dev
   pomme delete dev
   ```

For each step in more detail, see
[Quickstart: create your first VM](https://pommevm.dev/get-started/quickstart/).

## Documentation

The documentation at <https://pommevm.dev> covers guides, concepts,
troubleshooting, and a complete command-line reference. In a terminal, run
`pomme --help` or `pomme help COMMAND`. For coding agents, `pomme agent-help`
prints a compact command inventory.

## Develop Pomme

To run the offline test suite, which needs neither the signing certificate nor
a VM, run the following command from the repository root:

```sh
xcodebuild test \
  -project pomme.xcodeproj \
  -scheme pomme \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

To check the public command-line contract of an installed build, run the
following command:

```sh
Tests/PommeCLIIntegrationTests.sh --no-build --runner ~/.local/bin/pomme
```

The documentation site's source is in [Website](Website/README.md). For its
style rules and build commands, see
[Website/CONTRIBUTING.md](Website/CONTRIBUTING.md).

The following documents describe Pomme's design:

- [Architecture](Docs/Architecture.md)
- [Security workflows](Docs/SecurityWorkflows.md)
- [Protocol contracts](Docs/Protocols.md)
- [Qualification and publication gates](Docs/Qualification.md)

## License

Pomme is licensed under the [Apache License 2.0](LICENSE).
