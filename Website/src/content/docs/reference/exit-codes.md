---
title: Exit codes
description: The exit codes that Pomme returns and what each one means.
---

The `pomme` command returns an exit code that indicates whether a command
succeeded. For commands that run a program in a guest, the exit code also
reports how that program ended.

## Pomme exit codes

The following table describes the exit codes that Pomme itself returns.

| Code | Meaning |
| --- | --- |
| `0` | The command succeeded. |
| `1` | The command failed. The error message or the structured result describes the failure. |
| `64` | The command line is invalid. For example, a flag is unknown, a required argument is missing, or you omitted the VM name and `POMME_VM_NAME` isn't set. |
| `124` | A guest program or wait didn't finish before its `--timeout`. |
| `130` | You interrupted a foreground operation, for example by pressing Control+C. |

## Guest program exit codes

The `pomme exec` command and `pomme jobs wait` return the exit status of the
guest program:

| Guest result | Host exit code |
| --- | --- |
| The program exited with status `N` (0–255). | `N` |
| A signal `N` (1–127) ended the program. | `128 + N`. For example, `SIGKILL` (9) produces `137`. |
| The program didn't finish before `--timeout`. | `124` |
| You interrupted the foreground command. | `130` |

Because guest exit codes pass through unchanged, a guest program that exits
with `1` or `64` produces the same code as a Pomme failure. To tell them apart,
use `--format json` and inspect the result. A timeout or interruption isn't a
successful launch, even though the guest program might have started.

## Structured results

In JSON and JSONL output, most results carry their exit code in the
`hostExitCode` field. When a command acts on several VMs, `pomme` exits with the
code of the first failed result. For details, see
[Structured output](/reference/structured-output/).

## What's next

- [Run commands in a VM](/guides/run-guest-commands/)
- [Use Pomme in scripts and coding agents](/guides/script-pomme/)
- [Troubleshooting](/resources/troubleshooting/)
