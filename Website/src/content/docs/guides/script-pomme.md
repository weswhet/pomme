---
title: Use Pomme in scripts and coding agents
description: Run Pomme non-interactively with structured output, stable exit codes, and resumable commands.
---

This guide shows you how to call Pomme from shell scripts, CI jobs, and coding
agents. It covers machine-readable output, exit codes, command discovery, and
how to run commands without interactive prompts.

## Before you begin

- Install Pomme. For details, see
  [Install Pomme](/get-started/install/).
- To follow the examples, install [jq](https://jqlang.org/), a command-line
  JSON processor.

## Request structured output

Most commands accept `--format` with one of the following values:

| Value | Output |
| --- | --- |
| `table` | Human-readable text. This is the default. |
| `json` | One JSON object. |
| `jsonl` | One JSON object per line. For list commands, each item is its own line. |

`--json` is a shorthand for `--format json`.

For example, to print the names of running VMs, run the following:

```sh
pomme list --json | jq -r '.vms[] | select(.vmState == "running") | .name'
```

To print each installed template with its macOS version and build, run the
following:

```sh
pomme template list --json \
  | jq -r '.templates[] | "\(.name)\t\(.version)\t\(.build)"'
```

With `--format jsonl`, `pomme list` writes one VM per line, which works well
with line-oriented tools:

```sh
pomme list --format jsonl | jq -r '.name'
```

Result objects include `ok`, which is `true` on success, and most include
`hostExitCode`, the exit status that the command returns. When a command acts
on several VMs, JSON output wraps the per-VM results:

```json
{
  "ok": true,
  "results": [
    { "name": "dev-a", "ok": true, "vmState": "stopped", "hostExitCode": 0 },
    { "name": "dev-b", "ok": true, "vmState": "running", "hostExitCode": 0 }
  ]
}
```

For the fields that each command returns, see
[Structured output](/reference/structured-output/).

## Check exit codes

Test the exit status of every command. Pomme uses the following conventions:

- `0` means success.
- `1` means the command failed. Pomme prints `Error:` and a message to
  standard error. In this case, standard output doesn't contain a JSON result,
  even with `--format json`.
- `64` means the arguments were invalid, for example a missing VM name.
- For `pomme exec`, a guest program's exit code passes through. A program
  ended by a signal returns `128` plus the signal number, a foreground timeout
  returns `124`, and an interrupted foreground command returns `130`.

For the full list, see [Exit codes](/reference/exit-codes/).

The following example stops a script when a VM doesn't exist:

```sh
if ! pomme status "$VM" --json > status.json; then
  echo "Pomme could not read the status of $VM" >&2
  exit 1
fi
```

## Set a default VM

Commands that take an optional VM name use the `POMME_VM_NAME` environment
variable when you omit the name. Pomme never picks a VM for you, even if only
one VM is running.

```sh
export POMME_VM_NAME=dev
pomme status
pomme exec -- /usr/bin/sw_vers
```

For details, see [Environment variables](/reference/environment-variables/).

## Avoid interactive prompts

Some commands ask for confirmation in a terminal. When standard input isn't a
terminal, these commands fail instead of waiting. Add `--force` to confirm in
advance:

| Command | Effect of `--force` |
| --- | --- |
| `pomme delete`, `pomme rm` | Deletes without prompting, and stops a running VM first. |
| `pomme template delete` | Deletes the template without prompting. |
| `pomme snapshot delete` | Deletes the snapshot without prompting. |
| `pomme snapshot restore` | Restores without prompting and accepts recorded drift. |
| `pomme sip`, `pomme amfi`, `pomme mdm` | Allows creating the owner account on a verified fresh VM. |

Without `--force` and without a terminal, a deletion fails with the following
error:

```text
Deletion requires an interactive terminal. Pass --force to delete without prompting.
```

:::caution
`--force` skips the confirmation that protects you from deleting the wrong VM,
template, or snapshot. In scripts, build names from trusted values and check
them before you pass them to a deleting command.
:::

The following commands always need a terminal and don't have a
non-interactive form: `pomme tui`, `pomme config init`, `pomme shell` without
`--detach`, `pomme exec --pty`, and `pomme sessions attach`. To run a
terminal program from a script, create a detached session with
`pomme exec --pty --detach` and read its output with `pomme sessions logs`. For
details, see [Use durable terminal sessions](/guides/use-terminal-sessions/).

For owner credentials in security workflows, set both `POMME_AUTHORIZED_USER`
and `POMME_AUTHORIZED_PASSWORD`, or store the VM-scoped credential in your
login Keychain. For details, see
[Change SIP and AMFI](/guides/change-sip-and-amfi/#provide-owner-authorization).

## Repeat commands to resume work

Pomme's long-running workflows are journaled. If one stops partway, run the
same command again to continue from the first unfinished step:

| Workflow | How to resume |
| --- | --- |
| VM creation | `pomme create VM_NAME --resume` |
| SIP or AMFI change | Repeat the same `enable` or `disable` command with the same `--final-state`. |
| MDM enrollment | Repeat the same `pomme mdm` command with the same profile, `--enrollment-mode`, and `--final-security`. |

Commands whose request is already satisfied don't change the VM. For example,
`pomme agent repair` exits with status `0` when the agent is already healthy,
and `pomme agent update` exits with status `0` and reports `"updated": false`
when the agent already matches the host build.
This makes it safe to retry these commands in automation.

## Discover commands

Two commands describe the command-line tool without needing a VM:

- `pomme tools` lists the command groups and the UI automation capabilities
  of this build.
- `pomme agent-help` prints a compact command inventory for coding agents.

Both accept `--format table|json|jsonl`. Their JSON output is the same; with
`--format jsonl`, they write one command group per line:

```sh
pomme tools --format jsonl
```

```text
{"name":"vm","commands":["create","list|ls","start","stop","restart","pause","resume","delete|rm","status","inspect","snapshot","template"]}
{"name":"agent","commands":["agent status","agent repair","agent update"]}
{"name":"guest","commands":["exec","shell","log","jobs","sessions","cp","cat"]}
...
```

Give a coding agent the output of `pomme agent-help` so that it knows which
commands exist, then let it read `pomme help COMMAND` for details.

## What's next

- [Structured output](/reference/structured-output/)
- [Exit codes](/reference/exit-codes/)
- [Command-line reference](/reference/cli/)
