---
title: Spawn a VM
description: Summon a Pomme VM from a macOS version, a local restore image, or a template, and pick up a creation that collapsed halfway through.
---

Congratulations, Crawler. You've reached the spawning room. This page shows you
how to create a Pomme VM, choose the macOS version and resources it uses,
choose the state it's left in, and resume a creation that was interrupted.

Creating a VM is more than installing macOS. Pomme also installs its guest
agent, verifies it, and records each step in a journal so that an interrupted
creation can continue safely. The viewers find journals boring. The System
finds them deeply relaxing. For how this works, see
[Durable creation and journals](/crawler/concepts/durable-creation/).

## Before you descend

The System requires the following before it unlocks this room:

- [Install Pomme](/crawler/get-started/install/).
- Make sure that your login Keychain is unlocked.
- Choose a VM name. A name must meet these rules:
  - It's 1 to 64 characters long.
  - It uses only ASCII letters, digits, periods (`.`), underscores (`_`), and
    hyphens (`-`).
  - It starts with a letter or a digit.

No emoji. The System has seen what Crawlers name things.

## Choose a macOS source

Each VM is created from one of three sources. Use only one source in each
command. Picking two doesn't get you a bonus VM. It gets you an error.

### From a macOS version

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
information, see [Manage restore images](/crawler/guides/manage-restore-images/).

### From a local restore image

If you already have a restore image (IPSW) file, create the VM from it
directly:

```sh
pomme create VM_NAME --restore-image IPSW_PATH
```

Replace `IPSW_PATH` with the path of the `.ipsw` file.

You can't combine `--restore-image` with `--version`. You also can't use it in
a config file.

### From a template

If you create many VMs from the same macOS version, restore the image once
into a template, and then clone VMs from it. Efficient. Disappointing for
ratings, but efficient.

```sh
pomme create VM_NAME --from-template TEMPLATE_NAME
```

Replace `TEMPLATE_NAME` with the name of an installed template.

You can't combine `--from-template` with `--version`, `--latest`,
`--restore-image`, or `--ipsw-device`. For details, see
[Use templates](/crawler/guides/use-templates/).

## Pick your stats

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
- The disk image grows as the guest writes to it, so creation doesn't reserve
  the whole disk size. Before it downloads or writes anything, Pomme checks
  that the volume that holds your VMs has room for the rest of the restore
  image download and about 35 GB for the installed system, or the disk size
  if it's smaller. A clone of a template needs about 5 GB, and
  `--experimental-recovery` adds about 5 GB. If there isn't
  enough space, creation stops with the
  [`host-disk-space-insufficient`](/crawler/reference/errors/#host-disk-space-insufficient)
  error and changes nothing. The System checks your pockets before the ride,
  not halfway down the drop.

:::caution[Hazard Detected: Undersized Disk]
Crawlers who give macOS Tahoe a 25 GB disk get a failed install and a very
entertained audience. Give it more room than that.
:::

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

## Rehearse first

To check what Pomme would create without creating anything, add `--dry-run`:

```sh
pomme create VM_NAME --latest --memory 4GB --dry-run
```

Pomme resolves the restore image, applies the same checks as a real creation,
and prints the plan. A dry run still rejects a memory size below 4 GiB, and
it rejects a creation that wouldn't fit on the volume. With `--format json`,
the `diskSpace` field shows the space that each volume needs and has. The
rehearsal has standards too, Crawler.

## What happens during creation

Before Pomme changes anything, it resolves and verifies the following:

- The exact macOS version and build of the restore image.
- The English locale and the `1280×800` display size that Pomme's Recovery
  automation expects.
- The Recovery navigation profile for that build. For more information, see
  [Supported macOS versions](/crawler/concepts/os-qualification/).
- The identity of the signed guest agent to install.

Pomme then installs macOS and installs its guest agent. How the agent is
installed depends on the host and guest:

- **macOS 27 or later host and fresh guest, with the guest no newer than the
  host:** Pomme uses Apple's
  first-boot provisioning to create the `pomme` account, turn on automatic
  login, and temporarily turn on Remote Login. Pomme finds the guest's address
  through its DHCP lease, pins the guest's SSH host key on first connection,
  and installs the agent over SSH. After it verifies the agent and the owner
  account, Pomme turns Remote Login off.
- **Other hosts and guests:** Pomme boots the new VM into Recovery and
  installs the agent from there.

The generated password for the `pomme` account stays in your login Keychain.
Creation never changes System Integrity Protection (SIP) or AMFI. If you want
those dropped, that's a separate room with its own warnings.

## Try experimental image preparation

Use a fresh restore image or a template with an unmodified Recovery image.
Templates containing an already modified Recovery image aren't supported.

To prepare the Recovery image on the host before booting Recovery, add
`--experimental-recovery` when you create the VM:

```sh
pomme create VM_NAME --latest --memory 4GB --disk-size 40GB --experimental-recovery
```

Pomme keeps the original Recovery image and prepares a modified copy with an
agent that starts automatically. While the VM is stopped, Pomme selects the
modified image for Recovery boots and restores the original for normal boots.
Initial agent startup and later Recovery terminal connections don't require
navigating the Recovery screens. Without this flag, creation keeps its usual
behavior.

On eligible macOS 27 hosts and guests, Pomme still uses Apple's first-boot
provisioning and SSH checks to prepare and verify the owner account. It then
installs the guest agent through Recovery. Creation still verifies the normal
agent, owner account, and desktop, and turns Remote Login off before it finishes.

Read the fine print, Crawler. The sponsors certainly didn't:

- The embedded agent has its own credential, which can't authenticate as the
  VM's guest agent. Your login Keychain keeps it, and the prepared image
  contains a copy. The VM's bundle keeps that image, and the guest's disk holds
  it while Recovery is selected. `pomme delete` removes the credential with the
  VM's other credentials.
- Pomme attaches the VM's disk on the host only to switch images, such as on
  the first Recovery boot after normal boots. That start takes longer, because
  Pomme copies a Recovery image of more than 1 GB. Bring a snack.
- The VM keeps both images, so creation needs about 5 GB more free space.
- The modified image replaces the Recovery job that saves panic reports
  (`com.apple.DumpPanicRecoveryOS`), so the VM's Recovery doesn't save them.
  Crash quietly.
- Restoring a snapshot can't switch images, because that would change the disk
  under the saved state. If the VM last booted Recovery, start it in normal
  macOS and stop it before you restore a snapshot.
- A macOS update in the guest changes the Recovery image as soon as the update
  is prepared, before it's installed. Pomme detects the change on the next
  Recovery boot, stops using the embedded agent, and uses the standard
  Recovery route from then on, which navigates the Recovery screens. Normal
  boots aren't affected.

:::caution
The modified Recovery image has its APFS System role cleared and its seal
broken. Normal boots use the original image. This experiment doesn't change
SIP or AMFI.
:::

The journal records this choice. To resume, use `pomme create VM_NAME --resume`
without `--experimental-recovery`. You can't switch an existing creation to this method.

## Resume an interrupted creation

Things collapse, Crawler. Power blinks, lids close, someone trips on a cable
for the audience's amusement. If creation stops after it has changed anything,
Pomme keeps the VM and its journal unchanged. To continue from the first
unfinished step, run the following command:

```sh
pomme create VM_NAME --resume
```

With `--resume`, you can pass only the VM name and output or debug options,
such as `--format` and `--debug`. Pomme revalidates the original plan and
reuses the settings recorded when creation started.

If you rebuilt Pomme since the creation started, resume still installs the
exact agent build that the journal pins. If that agent build is missing or
altered, resume stops rather than substituting a different one.

:::tip[New Achievement! Back From the Brink]
You resumed a creation instead of deleting it and starting over in a panic.
Reward: a Silver Persistence Box. It contains a journal. It's blank. Write
in it.
:::

## Keep Recovery screenshots for debugging

To keep a screenshot of the guest display before each automatic Recovery
navigation step, add `--debug`:

```sh
pomme create VM_NAME --resume --debug
```

Pomme prints the directory and file names of the screenshots to standard
error. Each Recovery attempt uses its own `pomme-recovery-debug-…` directory
in the host's temporary directory. Pomme doesn't delete these screenshots.

:::caution[Hazard Detected: Souvenir Photos]
Full-resolution screenshots can show local identifiers. Delete the printed
directory when you no longer need it. The System doesn't clean up after you.
That's not in the contract.
:::

## Get structured output

To get machine-readable results, add `--format json` or `--format jsonl`:

```sh
pomme create VM_NAME --from-template TEMPLATE_NAME --format json
```

For the output schema, see [Structured output](/crawler/reference/structured-output/).

## Next floor

- [Use templates](/crawler/guides/use-templates/)
- [Create VMs from a config file](/crawler/guides/create-from-config/)
- [Manage the VM lifecycle](/crawler/guides/manage-vm-lifecycle/)
- [`pomme create` reference](/crawler/reference/cli/pomme-create/)
