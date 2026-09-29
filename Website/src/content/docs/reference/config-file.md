---
title: Creation config file
description: The schema for the config files that Pomme reads when it creates VMs from a config.
---

A creation config file describes one or more VMs that `pomme create --config`
creates in a single batch. This page describes every field that the file can
contain. For a task-oriented introduction, see
[Create VMs from a config file](/guides/create-from-config/).

## File formats

Pomme reads the same schema from four formats. It chooses the parser from the
file extension:

| Extension | Format |
| --- | --- |
| `.json` | JSON |
| `.yaml`, `.yml` | YAML |
| `.toml` | TOML |
| `.pkl` | Pkl. Pomme evaluates the file with `pkl eval --format json`, so the `pkl` executable must be on your `PATH`. |

To create a starter file interactively, run `pomme config init`.

## Example

The following YAML file creates two VMs: one from the `latest` selector and
one for macOS 26.6.2:

```yaml
schemaVersion: 1
name: lab
versions:
  - latest
  - 26.6.2
hardware:
  diskSize: 40GB
  memory: 4GB
boot: none
```

The same config in TOML:

```toml
schemaVersion = 1
name = "lab"
versions = ["latest", "26.6.2"]
boot = "none"

[hardware]
diskSize = "40GB"
memory = "4GB"
```

## Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `schemaVersion` | Integer | Yes | The schema version. Must be `1`. |
| `name` | String | Yes | The base name for the VMs that the config creates. It follows the [VM name rules](#vm-names). |
| `versions` | Array of strings | Yes | One or more macOS selectors. Each selector is a version such as `26.6.2`, a build such as `25G83`, or `latest`. Pomme creates one VM for each selector. |
| `ipswDevice` | String | No | The Apple silicon Mac model identifier, such as `Mac16,10`, that Pomme uses to resolve `versions`. Defaults to the host's model. |
| `hardware` | Object | No | The VM hardware. See [hardware](#hardware-object). |
| `boot` | String | No | The state that each VM is left in after creation: `normal`, `recovery`, or `none`. |

### `hardware` object

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `diskSize` | String | `60GB` | The virtual disk size. |
| `memory` | String | `8GB` | The guest memory size. Must be at least 4 GiB. |

Sizes are a positive number followed by an optional unit: `B`, `K`, `M`, `G`,
or `T`, optionally followed by `B` or `iB`, in any letter case. All units are
binary, so `40GB` and `40GiB` both mean 40 × 1024³ bytes.

### `boot` values

| Value | Result |
| --- | --- |
| `normal` | The VM keeps running in normal macOS after Pomme verifies its guest agent. |
| `none` | Pomme shuts the VM down after it verifies the guest agent. |
| `recovery` | Pomme restarts the VM in Recovery. |

:::note
Set `boot` explicitly. The starter file from `pomme config init` always sets
it, and an explicit value makes the plan that `pomme config render` prints
match what `pomme create --config` does.
:::

## VM names

Each selector in `versions` creates a VM named `NAME-VERSION`, where `NAME` is
the config's `name` and `VERSION` is the macOS version that the selector
resolves to. For example, with `name: lab`, the selector `latest` might create
a VM named `lab-26.6.2`.

Both `name` and each generated name must follow these rules:

- Contain 1–64 characters.
- Contain only ASCII letters, digits, periods (`.`), underscores (`_`), and
  hyphens (`-`).
- Start with a letter or digit.

Selectors in `versions` can't be empty or repeated, and two selectors can't
resolve to the same VM name. If any generated name matches an existing VM,
Pomme rejects the whole config before it creates anything.

## Validation

Pomme rejects a config that contains a key it doesn't define, at any level, so
a misspelled key causes an error instead of having no effect.

Creation configs describe only VM provisioning. Pomme rejects the following keys from
older config versions with an error that names the replacement:

| Key | Replacement |
| --- | --- |
| `credentials` | The explicit security commands, such as `pomme sip`. |
| `workflow` | The `boot` field or the `--boot` flag. |
| `mdm` | The `pomme mdm` command. |
| `restore`, `replaceExisting`, `failureCleanup` | None. Regenerate the file with `pomme config init`. |

To check a config, use these commands:

- `pomme config validate FILE` checks the schema without contacting any
  server.
- `pomme config render FILE` also resolves each selector to an exact macOS
  version and build, and prints the VM names and creation plan.

## What's next

- [Create VMs from a config file](/guides/create-from-config/)
- [`pomme create` reference](/reference/cli/pomme-create/)
- [`pomme config` reference](/reference/cli/pomme-config/)
