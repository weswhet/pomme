---
title: Structured output
description: How Pomme formats table, JSON, and JSONL output, and which fields every result contains.
---

Most `pomme` commands can print their results as a human-readable table, as a
single JSON document, or as JSON Lines (JSONL). Use structured output when you
call Pomme from a script, a CI job, or a coding agent.

## Select an output format

To select a format, pass `--format` with one of the following values:

| Value | Output |
| --- | --- |
| `table` | Human-readable text. This is the default. |
| `json` | One JSON document on standard output. |
| `jsonl` | One JSON object per line on standard output. |

The `--json` flag is shorthand for `--format json`. If you pass `--json`
together with a different `--format` value, Pomme rejects the command with a
usage error.

The `pomme log` command uses `text` instead of `table` for its human-readable
format. The `pomme config init` command uses `--format` to choose the config
file format instead of the output format.

## Result fields

Structured results contain the following common fields:

| Field | Type | Description |
| --- | --- | --- |
| `ok` | Boolean | `true` if the operation succeeded. Every result contains this field. |
| `hostExitCode` | Integer | The exit code that `pomme` returns for this result. Most results contain this field; `pomme list` doesn't. For details, see [Exit codes](/reference/exit-codes/). |
| `name` | String | The VM name, when the result applies to one VM. |

The remaining fields depend on the command. For example, `pomme list` returns
a `vms` array, and `pomme template list` returns a `templates` array. To see a
command's fields, run it with `--json` and inspect the result.

## JSON output

With `--format json`, a command that produces one result prints one JSON
object:

```json
{"ok":true,"hostExitCode":0,"templates":[{"name":"base","version":"26.6.2","build":"25G83","diskSize":42949672960,"provisioned":false}]}
```

A command that acts on several VMs, such as `pomme stop dev test`, prints one
object that wraps the individual results:

```json
{"ok":false,"results":[{"ok":true,"hostExitCode":0,"name":"dev"},{"ok":false,"hostExitCode":1,"name":"test"}]}
```

The top-level `ok` field is `true` only if every result succeeded.

## JSONL output

With `--format jsonl`, Pomme prints each object on its own line. For
list-shaped results, such as `pomme list`, `pomme template list`, and
`pomme tools`, Pomme prints one line for each element of the list instead of
one line for the whole result. An empty list prints nothing.

If a list command fails, Pomme prints the failure result as a single line.

JSONL output works well with line-oriented tools. For example, the following
command prints the name and state of every VM:

```sh
pomme list --format jsonl | jq -r '"\(.name) \(.vmState)"'
```

## Errors

When an operation fails, its result has `"ok": false` and a nonzero
`hostExitCode`, and `pomme` exits with that code.

:::caution
Some errors occur before Pomme starts an operation, for example when a flag is
invalid or when the named VM doesn't exist. For these errors, Pomme prints an
`Error:` message to standard error and doesn't print a JSON result, even if you
passed `--json`. Always check the exit code before you parse standard output.
:::

## Diagnostics

Structured output goes to standard output. Diagnostics, progress messages,
and the paths of retained debug screenshots go to standard error, so they
don't mix with the JSON that you parse. Pomme doesn't add `--debug`
screenshot details to table, JSON, or JSONL output.

## Guest program output

For `pomme exec` and `pomme shell` in table format, Pomme writes the guest
program's standard output and standard error to the matching host streams,
byte for byte. Pomme doesn't merge the two streams or add text to them.

## What's next

- [Use Pomme in scripts and coding agents](/guides/script-pomme/)
- [Exit codes](/reference/exit-codes/)
- [Command-line reference](/reference/cli/)
