---
title: Manage restore images
description: List the macOS restore images available for your Mac, download them ahead of time, and create VMs from local image files.
---

This page shows you how to find the macOS restore images (IPSW files) that
you can install, download them before you need them, and create a VM from a
local image file.

Pomme looks up restore images in the public ipsw.me catalog for an Apple
silicon Mac model. By default, it uses your Mac's own model identifier.

## Before you begin

- [Install Pomme](/get-started/install/).
- Make sure that the host has internet access.

## List available restore images

To list the restore images for your Mac's model, run the following command:

```sh
pomme ipsw list --limit 5
```

The output shows the macOS version, the build, and whether Apple still signs
the image:

```text
27.0.1	26A434	signed=true
27.0	26A428	signed=true
26.6.2	25G83	signed=true
26.6.1	25G76	signed=true
26.6	25G72	signed=true
```

The `--limit` flag sets the maximum number of results. Omit it to list every
image in the catalog for the model.

To list images for a different Apple silicon model, add `--device`:

```sh
pomme ipsw list --device MODEL_IDENTIFIER
```

Replace `MODEL_IDENTIFIER` with an Apple model identifier, such as
`Mac16,10`.

With `--format json`, each image also includes its size in bytes and its
download URL.

## Download a restore image

Pomme downloads the image it needs when you create a VM or a template. To
download an image ahead of time, run the following command:

```sh
pomme ipsw download SELECTION
```

Replace `SELECTION` with a macOS version such as `26.6.2`, a build such as
`25G83`, or `latest`.

Keep the following in mind:

- Pomme refuses to download an image that Apple no longer signs.
- If a download is interrupted, running the same command again continues
  from where it stopped.
- If the complete image is already cached, Pomme uses it and doesn't
  download it again.

When the download finishes, Pomme prints the path of the image file.

To download an image for a different model, add
`--device MODEL_IDENTIFIER`.

## Where restore images are stored

Pomme caches downloaded images in the following directory:

```text
~/Library/Application Support/pomme/RestoreImages
```

Both `pomme ipsw download` and the creation commands use this cache. To free
disk space, you can delete image files from this directory. Pomme downloads an
image again the next time it needs one. For the rest of Pomme's storage
layout, see [Files and paths](/reference/files-and-paths/).

## Create a VM from a local restore image

If you have an IPSW file somewhere else on disk, pass its path to
`--restore-image`:

```sh
pomme create VM_NAME --restore-image IPSW_PATH
```

Replace the following:

- `VM_NAME`: the name of the new VM.
- `IPSW_PATH`: the path of the `.ipsw` file.

You can also use `--restore-image` with `pomme template create`. You can't use
it in a config file. For more information, see
[Create a VM](/guides/create-vms/).

## What's next

- [Create a VM](/guides/create-vms/)
- [Use templates](/guides/use-templates/)
- [Supported macOS versions](/concepts/os-qualification/)
- [`pomme ipsw` reference](/reference/cli/pomme-ipsw/)
