---
title: System requirements
description: Hardware, software, and resource requirements for running Pomme and building it from source.
---

This page lists what you need on your Mac to run Pomme and to build it from
source.

## Host hardware

Pomme runs only on a Mac with Apple silicon. The `pomme` executable is built
for the `arm64` architecture, and Virtualization.framework can run macOS guests
only on Apple silicon.

## Host operating system

Pomme requires macOS 15 or later on the host.

The host version affects how Pomme installs its guest agent:

- On a macOS 27 host that creates a fresh macOS 27 guest, Pomme uses Apple's
  first-boot provisioning to create the guest's `pomme` account and installs
  the agent over SSH.
- On older hosts, with older guests, and with templates that already have an
  owner account, Pomme installs the agent through macOS Recovery.

For details, see [Durable creation and journals](/concepts/durable-creation/).

## Guest operating system

Pomme can attempt to install any restore image that Apple signs for your Mac
model. Some macOS versions are reviewed, and other versions are treated as
experimental attempts. For the current list, see
[Supported macOS versions](/concepts/os-qualification/).

## Memory and disk

Each VM uses its own memory and disk space. Keep the following limits in mind
when you size your VMs:

- **Guest memory:** Every VM needs at least 4 GiB of memory. If the restore
  image declares a higher minimum, Pomme applies that minimum instead. The
  default is `8GB`.
- **Disk size:** The default virtual disk size is `60GB`. A VM cloned from a
  template inherits the template's disk size.
- **Running guests:** Virtualization.framework runs at most two macOS guests
  at the same time.

For short-lived test VMs on a host with 16 GB of memory, use
`--memory 4GB --disk-size 40GB`. Increase these values only when the workload
needs more.

:::caution
A 25 GB disk is too small to install macOS Tahoe. Use at least `40GB` for
Tahoe guests.
:::

## Keychain

Pomme stores each VM's agent credential and generated owner password in your
login Keychain. The login Keychain must be unlocked when you run Pomme. Pomme
doesn't unlock the Keychain for you and doesn't read your host password.

## Network access

Pomme downloads restore images from Apple's servers and looks up available
versions in the public restore-image catalog. The host needs internet access
unless you create VMs from a local restore image or an installed template.

## Requirements for building from source

To build and install Pomme from source, you also need:

- A full installation of Xcode 27 or later. Pomme builds against the macOS 27
  SDK, and the Command Line Tools package alone isn't enough.
- The Developer ID Application certificate that the project is configured to
  sign with, including its private key, in your Keychain.

For the build procedure, see [Install Pomme](/get-started/install/).

## What's next

- [Install Pomme](/get-started/install/)
- [Quickstart: create your first VM](/get-started/quickstart/)
- [Supported macOS versions](/concepts/os-qualification/)
