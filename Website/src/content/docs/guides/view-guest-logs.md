---
title: View guest agent logs
description: Read and stream the Pomme guest agent's unified log records from a running VM.
---

This guide shows you how to read the log records that the Pomme guest agent
writes inside a VM. Use these logs to see what the agent did, for example while
you diagnose a failed workflow. You don't need to open a shell in the guest:
`pomme log` queries the guest's unified log through the authenticated agent.

## Before you begin

- Start the VM in normal macOS, and make sure that its guest agent is
  connected. For details, see
  [Manage the VM lifecycle](/guides/manage-vm-lifecycle/).

:::note
The logs come from the guest agent that's installed in the VM. Installing a
newer `pomme` command on the host doesn't upgrade an existing guest agent, so
it doesn't add log events to an older agent. To update the agent, see
[Check and repair the guest agent](/guides/repair-the-agent/).
:::

## Show recent log records

To show the agent's log records from the last 10 minutes, run the following
command:

```sh
pomme log VM_NAME
```

Replace `VM_NAME` with the name of the VM.

Pomme shows records from the `com.github.weswhet.pomme` subsystem at the `info`
level and higher.

To show a different time window, pass `--last` with a positive number followed
by `s` (seconds), `m` (minutes), `h` (hours), or `d` (days). To show every
record since the guest last started, pass `--last boot`:

```sh
pomme log VM_NAME --last 1h
pomme log VM_NAME --last boot
```

A large query can take a while. By default, Pomme waits up to 60 seconds for
the query. To allow more time, pass `--timeout SECONDS`, up to `300`.

## Stream new log records

To print new records as the agent writes them, pass `--follow`:

```sh
pomme log VM_NAME --follow
```

Pomme streams records until you press Control+C. You can't combine
`--follow` with `--last`, `--timeout`, or `--format json`.

## Filter log records

To show only some records, use the following flags:

- `--category CATEGORY`: show only records from this exact category. Repeat
  the flag to include more categories.
- `--level LEVEL`: set the minimum level. The values are `default`, `info`, and
  `debug`. The default is `info`. Use `debug` to include debug records.

For example, the following command shows an hour of records about Setup
Assistant preferences, including debug records:

```sh
pomme log VM_NAME --last 1h --category buddy-preferences --level debug
```

The guest agent writes records in the following categories:

| Category | Records about |
| --- | --- |
| `buddy-preferences` | Maintenance of the owner account's Setup Assistant preferences on each normal boot, including progress, failures, and read-back results. |
| `guest-serve-loop` | Timing of requests that the agent reads, handles, and answers. |
| `signal-boundary` | Timing of process signal and status handling. |
| `desktop-start-boundary` | Timing of the desktop readiness checks that security workflows run. |
| `actor-start-boundary` | Timing of guest process launches. |
| `actor-status-boundary` | Timing of guest process status checks. |

The timing categories are diagnostic traces. They help locate where a request
stopped making progress, but they don't explain why on their own.

## Get structured log output

By default, `pomme log` prints text. To process records in a script, pass
`--format jsonl` to get one JSON object per line, or `--format json` to get one
JSON document. `--json` is the same as `--format json`. When you use
`--follow`, use `--format jsonl`:

```sh
pomme log VM_NAME --follow --level debug --format jsonl
```

For details, see [Structured output](/reference/structured-output/).

## What's next

- [Guest agent](/concepts/guest-agent/)
- [Troubleshooting](/resources/troubleshooting/)
- [`pomme log` reference](/reference/cli/pomme-log/)
