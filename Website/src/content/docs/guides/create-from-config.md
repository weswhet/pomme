---
title: Create VMs from a config file
description: Describe one or more VMs in a JSON, YAML, TOML, or Pkl file, check the plan, and create the VMs in one command.
---

This page shows you how to describe VMs in a config file, check the file, and
create every VM it describes with one command.

A config file names a base VM name and a list of macOS versions. Pomme creates
one VM for each version and names it `NAME-VERSION`. For example, a config
with the name `lab` and the versions `26.6.2` and `27.0` creates VMs named
`lab-26.6.2` and `lab-27.0`, based on the exact version that each selector
resolves to.

## Before you begin

- [Install Pomme](/get-started/install/).
- To use a Pkl config, install the `pkl` executable and make sure it's on
  your `PATH`. Pomme runs `pkl eval` to read Pkl files.

## Create a config file

The `pomme config init` command asks a few questions and writes a starter
config. To create a config file, follow these steps:

1. Run the following command in an interactive terminal:

   ```sh
   pomme config init --format yaml --output lab.yaml
   ```

   The `--format` flag accepts `json`, `yaml`, `toml`, or `pkl`. The default
   is `yaml`. If you omit `--output`, Pomme names the file after the base VM
   name, such as `lab.yaml`.

1. Answer the prompts. Press Return to accept the default shown for each one:

   - **Base VM name:** the prefix for every VM name. The default is `lab`.
   - **Versions separated by commas:** the macOS versions, builds, or `latest`
     to create. The default is `latest`.
   - **Disk size:** the default is `60GB`.
   - **Memory:** the default is `8GB`.
   - **Boot after creation:** `none`, `normal`, or `recovery`. The default
     answer is `none`.

Pomme doesn't replace an existing file. To overwrite one, add `--force`.

## Write a config by hand

A config uses schema version 1. The following YAML file creates two VMs, one
for each version, and shuts each one down when it's ready:

```yaml
schemaVersion: 1
name: lab
versions:
  - "26.6.2"
  - latest
boot: none
hardware:
  diskSize: 40GB
  memory: 4GB
```

The same config in TOML looks like this:

```toml
schemaVersion = 1
name = "lab"
versions = ["26.6.2", "latest"]
boot = "none"

[hardware]
diskSize = "40GB"
memory = "4GB"
```

The config supports these keys:

- `schemaVersion`: required. Must be `1`.
- `name`: required. The base VM name.
- `versions`: required. One or more macOS versions, builds, or `latest`.
  Selectors can't be empty or repeated.
- `ipswDevice`: optional. The Apple silicon model identifier used to resolve
  versions, such as `Mac16,10`.
- `hardware.diskSize` and `hardware.memory`: optional. The disk size and
  memory for every VM.
- `boot`: optional. The state after creation: `none`, `normal`, or
  `recovery`. Set it explicitly so that the rendered plan matches the result.

Pomme rejects unknown keys, so it reports a misspelled key instead of
ignoring it. For the full schema, see [Creation config file](/reference/config-file/).

:::note
A config file only creates VMs. It can't contain credentials, security
workflow controls, or mobile device management (MDM) enrollment settings, and
Pomme rejects a config that has `credentials`, `workflow`, or `mdm` keys. Run
those operations with their own commands, such as `pomme sip` and `pomme mdm`.
:::

## Check a config

Pomme offers two checks with different depths:

- To check a config's syntax and values without contacting the restore-image
  catalog, run `pomme config validate`:

  ```sh
  pomme config validate lab.yaml
  ```

  If the config is valid, the output is `Config is valid.`

- To resolve each version to an exact build and print the VMs that Pomme
  would create, run `pomme config render`:

  ```sh
  pomme config render lab.yaml
  ```

  The output lists one VM on each line with its name, macOS version, build,
  and boot state.

## Create the VMs

To create every VM in the config, run the following command:

```sh
pomme create --config lab.yaml
```

You can't combine `--config` with a VM name or with direct creation options
such as `--version`, `--memory`, or `--from-template`. Local restore images
aren't available in config files.

Before it creates anything, Pomme checks the whole batch. If two versions
resolve to the same VM name, or if a VM with one of the names already exists,
Pomme stops and creates no VMs.

After creation starts, Pomme creates each VM independently. If one VM fails,
Pomme keeps the VMs that it created successfully. To continue a failed VM, run
`pomme create VM_NAME --resume` with that VM's name. For more information, see
[Create a VM](/guides/create-vms/#resume-an-interrupted-creation).

### Create two VMs at a time

By default, Pomme creates the VMs one after another. To create them two at a
time, add `--parallel`:

```sh
pomme create --config lab.yaml --parallel
```

The flag takes no count, because Virtualization.framework runs at most two
macOS guests at once.

### Preview the batch

To run the preflight checks and print the plan without creating any VMs, add
`--dry-run`:

```sh
pomme create --config lab.yaml --dry-run
```

## What's next

- [Creation config file](/reference/config-file/)
- [Create a VM](/guides/create-vms/)
- [`pomme config` reference](/reference/cli/pomme-config/)
