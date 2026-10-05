---
title: Key names
description: The key names, modifier prefixes, and aliases that Pomme accepts for guest keyboard input.
---

The `pomme ui key` and `pomme ui key-sequence` commands accept the key names on
this page. To print the same list from the installed `pomme` command, run
`pomme ui keys`.

## Named keys

| Key | Aliases |
| --- | --- |
| `return` | `enter` |
| `tab` | |
| `shift-tab` | |
| `space` | |
| `escape` | `esc` |
| `delete` | `backspace` |
| `forward-delete` | |
| `home` | |
| `end` | |
| `page-up` | |
| `page-down` | |
| `left` | |
| `right` | |
| `up` | |
| `down` | |
| `f1` through `f12` | |
| `command-space` | `cmd-space` |

## Modifier prefixes

Add a modifier by putting its prefix in front of a key name or character.

| Prefix | Aliases |
| --- | --- |
| `command-` | `cmd-` |
| `control-` | `ctrl-` |
| `option-` | `opt-`, `alt-` |
| `shift-` | |

## Rules

- **Characters**: any single character on a US keyboard is a valid key. An
  uppercase letter or a shifted symbol, such as `T` or `?`, implies the Shift
  key.
- **Chaining**: modifier prefixes chain from left to right, for example
  `cmd-shift-t`.
- **Separator**: you can use `+` instead of `-`, for example `cmd+shift+t`.
- **Scan codes**: Pomme doesn't accept numeric HID scan codes, and it doesn't
  expose separate key-down and key-up commands.

## Examples

The following commands press Control+F2, press Command+Shift+T, and then press
the Left arrow and Right arrow keys in order:

```sh
pomme ui key --vm VM_NAME --key ctrl-f2
pomme ui key --vm VM_NAME --key cmd+shift+t
pomme ui key-sequence --vm VM_NAME -- left right
```

Replace `VM_NAME` with the name of the VM.

## What's next

- [Automate the guest display](/guides/automate-the-display/)
- [`pomme ui` reference](/reference/cli/pomme-ui/)
