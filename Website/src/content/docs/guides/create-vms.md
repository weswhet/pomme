---
title: Create a VM
description: Create a Pomme VM from a macOS version, a local restore image, or a template, and resume an interrupted creation.
---

This page shows you how to create a Pomme VM, choose the macOS version and
resources it uses, choose the state it's left in, and resume a creation that
was interrupted.

Creating a VM is more than installing macOS. Pomme also installs its guest
agent, verifies it, and records each step in a journal so that an interrupted
creation can continue safely. For how this works, see
[Durable creation and journals](/concepts/durable-creation/).

## Before you begin

- [Install Pomme](/get-started/install/).
- Make sure that your login Keychain is unlocked.
- Choose a VM name. A name must meet these rules:
  - It's 1 to 64 characters long.
  - It uses only ASCII letters, digits, periods (`.`), underscores (`_`), and
    hyphens (`-`).
  - It starts with a letter or a digit.

## Choose a macOS source

Each VM is created from one of three sources. Use only one source in each
command.

### Create a VM from a macOS version

To create a VM from the latest signed macOS version, run the following
command:

```sh
pomme create VM_NAME --latest
```

To create a VM from a specific macOS version or build, use `--version`:

```sh
pomme create VM_NAME --version VERSION
```

Replace the following:

- `VM_NAME`: the name of the new VM.
- `VERSION`: a macOS version such as `26.6.2`, a build such as `25G83`, or
  `latest`.

Pomme resolves the version for your Mac's model identifier. To resolve it for
a different Apple silicon model, add `--ipsw-device MODEL_IDENTIFIER`, for
example `--ipsw-device Mac16,10`. You can use `--ipsw-device` only with
`--version` or `--latest`.

To see which versions are available, run `pomme ipsw list`. For more
information, see [Manage restore images](/guides/manage-restore-images/).

### Create a VM from a local restore image

If you already have a restore image (IPSW) file, create the VM from it
directly:

```sh
pomme create VM_NAME --restore-image IPSW_PATH
```

Replace `IPSW_PATH` with the path of the `.ipsw` file.

You can't combine `--restore-image` with `--version`. You also can't use it in
a config file.

### Create a VM from a template

If you create many VMs from the same macOS version, restore the image once
into a template, and then clone VMs from it:

```sh
pomme create VM_NAME --from-template TEMPLATE_NAME
```

Replace `TEMPLATE_NAME` with the name of an installed template.

You can't combine `--from-template` with `--version`, `--latest`,
`--restore-image`, or `--ipsw-device`. For details, see
[Use templates](/guides/use-templates/).

## Set memory and disk size

By default, a VM gets `8GB` of memory and a `60GB` disk. To change them, use
`--memory` and `--disk-size`:

```sh
pomme create VM_NAME --latest --memory 4GB --disk-size 40GB
```

Keep the following in mind:

- Every VM needs at least 4 GiB of memory. When the restore image is already
  on the host, Pomme also applies the image's own minimum.
- A VM cloned from a template inherits the template's disk size.
- A 25 GB disk is too small to install macOS Tahoe.

## Choose the state after creation

By default, creation ends with the VM running normal macOS and its agent
verified. To leave the VM in a different state, use one of the following
options:

| Option | Result |
| --- | --- |
| `--boot normal` | The VM keeps running in normal macOS. This is the default. |
| `--boot none` or `--shutdown` | Pomme shuts the VM down after the agent is installed and verified. |
| `--boot recovery` or `--recovery` | Pomme restarts the VM in Recovery. |

For example, to create a VM and shut it down when it's ready, run the
following command:

```sh
pomme create VM_NAME --version 26.6.2 --shutdown
```

## Preview a creation

To check what Pomme would create without creating anything, add `--dry-run`:

```sh
pomme create VM_NAME --latest --memory 4GB --dry-run
```

Pomme resolves the restore image, applies the same checks as a real creation,
and prints the plan. A dry run still rejects a memory size below 4 GiB.

## What happens during creation

Before Pomme changes anything, it resolves and verifies the following:

- The exact macOS version and build of the restore image.
- The English locale and the `1280×800` display size that Pomme's Recovery
  automation expects.
- The Recovery navigation profile for that build. For more information, see
  [Supported macOS versions](/concepts/os-qualification/).
- The identity of the signed guest agent to install.

Pomme then installs macOS and installs its guest agent. How the agent is
installed depends on the host and guest:

- **macOS 27 host with a fresh macOS 27 guest:** Pomme uses Apple's
  first-boot provisioning to create the `pomme` account, turn on automatic
  login, and temporarily turn on Remote Login. Pomme finds the guest's address
  through its DHCP lease, pins the guest's SSH host key on first connection,
  and installs the agent over SSH. After it verifies the agent and the owner
  account, Pomme turns Remote Login off.
- **Other hosts and guests:** Pomme boots the new VM into Recovery and
  installs the agent from there.

The generated password for the `pomme` account stays in your login Keychain.
Creation never changes System Integrity Protection (SIP) or AMFI.

## Resume an interrupted creation

If creation stops after it has changed anything, Pomme keeps the VM and its
journal unchanged. To continue from the first unfinished step, run
the following command:

```sh
pomme create VM_NAME --resume
```

With `--resume`, you can pass only the VM name and output or debug options,
such as `--format` and `--debug`. Pomme revalidates the original plan and
reuses the settings recorded when creation started.

If you rebuilt Pomme since the creation started, resume still installs the
exact agent build that the journal pins. If that agent build is missing or
altered, resume stops rather than substituting a different one.

## Keep Recovery screenshots for debugging

To keep a screenshot of the guest display before each automatic Recovery
navigation step, add `--debug`:

```sh
pomme create VM_NAME --resume --debug
```

Pomme prints the directory and file names of the screenshots to standard
error. Each Recovery attempt uses its own `pomme-recovery-debug-…` directory
in the host's temporary directory. Pomme doesn't delete these screenshots.

:::caution
Full-resolution screenshots can show local identifiers. Delete the printed
directory when you no longer need it.
:::

## Get structured output

To get machine-readable results, add `--format json` or `--format jsonl`:

```sh
pomme create VM_NAME --from-template TEMPLATE_NAME --format json
```

For the output schema, see [Structured output](/reference/structured-output/).

## What's next

- [Use templates](/guides/use-templates/)
- [Create VMs from a config file](/guides/create-from-config/)
- [Manage the VM lifecycle](/guides/manage-vm-lifecycle/)
- [`pomme create` reference](/reference/cli/pomme-create/)
