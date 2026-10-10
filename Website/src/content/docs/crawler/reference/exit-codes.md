---
title: Exit codes
description: The exit codes that Pomme returns and what each one means. Your final score for every command, in a single number.
---

The `pomme` command returns an exit code that indicates whether a command
succeeded. For commands that run a program in a guest, the exit code also
reports how that program ended. Think of it as your score, Crawler. Zero is
good. The viewers prefer the other numbers.

## Pomme exit codes

The following table describes the exit codes that Pomme itself returns.

| Code | Meaning |
| --- | --- |
| `0` | The command succeeded. |
| `1` | The command failed. The error message or the structured result describes the failure, and its error code identifies the kind of failure. For every code, see [Errors](/crawler/reference/errors/). |
| `64` | The command line is invalid. For example, a flag is unknown, a required argument is missing, or you omitted the VM name and `POMME_VM_NAME` isn't set. |
| `124` | A guest program or wait didn't finish before its `--timeout`. |
| `130` | You interrupted a foreground operation, for example by pressing Control+C. |

## Guest program exit codes

The `pomme exec` command and `pomme jobs wait` return the exit status of the
guest program, so whatever happens in the box gets reported out here:

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

:::caution[Hazard Detected: Identical Numbers]
A `1` from the guest and a `1` from Pomme look exactly alike. Crawlers who
assume they know which one they got tend to debug the wrong thing for an
entire episode. Use `--format json` when it matters.
:::

## Structured results

In JSON and JSONL output, most results carry their exit code in the
`hostExitCode` field. When a command acts on several VMs, it finishes every VM
and then exits with the code of the first failed result. For details, see
[Structured output](/crawler/reference/structured-output/). For every error
code behind a `1`, see [Errors](/crawler/reference/errors/).

## What's next

- [Run commands in a VM](/crawler/guides/run-guest-commands/)
- [Use Pomme in scripts and coding agents](/crawler/guides/script-pomme/)
- [Errors](/crawler/reference/errors/)
- [Troubleshooting](/crawler/resources/troubleshooting/)
