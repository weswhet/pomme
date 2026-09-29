---
title: Use templates
description: Restore macOS once into a template, clone VMs from it, and build provisioned templates for MDM testing.
---

This page shows you how to create templates, clone VMs from them, and manage
the templates installed on your Mac.

Restoring a macOS image takes several minutes: about four minutes for a 20 GB
image. A template holds the result of that restore so that new VMs can clone it
instead of restoring the image again. Cloning the disk is nearly instant;
Pomme still boots each clone to install and verify its guest agent.

## About templates

A template contains only the following:

- The restored disk image.
- The VM's auxiliary storage.
- The hardware model.
- A manifest that records the restore image's digest and the disk size.

A standard template has no guest agent, credential, owner account, or
journal. When you create a VM from a template, Pomme clones the disk image and
auxiliary storage with APFS copy-on-write, under a new machine identifier and
UUID. Each clone therefore has its own identity, and clones from the same
template can run at the same time.

After cloning, Pomme runs the same journaled agent installation and
verification as any other creation. For details, see
[Durable creation and journals](/concepts/durable-creation/).

## Before you begin

- [Install Pomme](/get-started/install/).
- Choose a template name. Template names follow the same rules as VM names:
  1 to 64 ASCII letters, digits, periods, underscores, and hyphens, starting
  with a letter or a digit.

## Create a template

To create a template, run `pomme template create` with a macOS source:

```sh
pomme template create TEMPLATE_NAME --latest --disk-size 40GB
```

Replace `TEMPLATE_NAME` with the name of the new template.

Instead of `--latest`, you can use `--version VERSION` or
`--restore-image IPSW_PATH`, as described in
[Create a VM](/guides/create-vms/#choose-a-macos-source).

Choose the disk size carefully: every VM that you clone from the template
inherits it. The default is `60GB`.

The `--memory` flag sets the guest memory used only while Pomme restores the
image. The default is `4GB`. It doesn't affect VMs cloned from the template.

## Create a VM from a template

To clone a VM from a template, run the following command:

```sh
pomme create VM_NAME --from-template TEMPLATE_NAME --memory 4GB
```

Replace the following:

- `VM_NAME`: the name of the new VM.
- `TEMPLATE_NAME`: the name of an installed template.

You set the VM's memory when you create it. You can't set a different disk
size, because the clone uses the template's disk.

The creation plan pins the template's restore image digest. If the template is
replaced before an interrupted creation resumes, the resume fails instead of
using the new template.

## List templates

To list installed templates, run the following command:

```sh
pomme template list
```

The output looks similar to the following:

```text
NAME        VERSION  BUILD   DISK  OWNER  SECURITY
base        26.6.2   25G83   40GB  -      default
mdm-ready   26.6.2   25G83   40GB  pomme  sip-off,amfi-off
```

The `OWNER` column shows the owner account of a provisioned template, or `-`
for a standard template. The `SECURITY` column shows `sip-off,amfi-off` for a
template captured with System Integrity Protection (SIP) turned off and the
AMFI override on, or `default` otherwise.

## Create a provisioned template

Creating the owner account that an authenticated workflow such as mobile
device management (MDM) enrollment needs is another slow step. A provisioned template captures that
work too, so that a VM cloned from it can run MDM enrollment as its first
command.

To create a provisioned template, add `--provisioned`:

```sh
pomme template create mdm-ready --latest --disk-size 40GB --provisioned
```

To build a provisioned template from an existing standard template instead of
restoring the image again, add `--from-template`:

```sh
pomme template create mdm-ready --from-template base --provisioned
```

You can use `--from-template` only with `--provisioned`.

Pomme builds a temporary VM, prepares the `pomme` owner account with automatic
login, turns off SIP, turns on the AMFI override, and captures the result as
the template.

:::caution
Every VM cloned from a provisioned template starts with SIP turned off and the
AMFI override turned on. Use provisioned templates only for test VMs that
need this security posture, such as MDM enrollment tests.
:::

To enroll a VM cloned from a provisioned template, run the following commands:

```sh
pomme create lab --from-template mdm-ready
pomme mdm lab --profile enroll.mobileconfig
```

For more information, see [Enroll a VM in MDM](/guides/enroll-in-mdm/).

### How clones get the owner password

The template doesn't store the owner's password, and Pomme never prints it.
Because each clone has its own VM UUID, the Keychain item from the VM that the
template was captured from can't follow the clone. Instead, the root guest
agent recovers the password from the clone's own `/etc/kcpassword` file.
Pomme adopts the password for the clone after it proves the account's
administrator membership, Secure Token, and APFS ownership. You don't need to
know the password.

## Delete a template

To delete a template, run the following command:

```sh
pomme template delete TEMPLATE_NAME
```

Pomme asks you to confirm. To skip the confirmation, add `--force`.

:::caution
Deleting a template can't be undone. Finish any interrupted creation that
uses the template before you delete it.
:::

## What's next

- [Create a VM](/guides/create-vms/)
- [Enroll a VM in MDM](/guides/enroll-in-mdm/)
- [`pomme template` reference](/reference/cli/pomme-template/)
