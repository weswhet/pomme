---
title: Run commands in a VM
description: Run programs and shell commands in a running VM, in the foreground or as background jobs.
---

This guide shows you how to run programs inside a VM from the host with
`pomme exec` and `pomme shell`, and how to manage long-running commands as
background jobs. Pomme runs each command through the authenticated guest
agent, so you don't need SSH or a network connection to the guest.

## Before you begin

- Start the VM in normal macOS, and make sure that its guest agent is
  connected. `pomme status VM_NAME` shows the agent connection. For details,
  see [Manage the VM lifecycle](/guides/manage-vm-lifecycle/).
- Read [Guest agent](/concepts/guest-agent/) to understand how Pomme reaches
  the guest.

## Run a program

To run a program in the guest and wait for it to finish, use `pomme exec`.
Put the program and its arguments after `--`:

```sh
pomme exec VM_NAME -- /usr/bin/sw_vers
```

Replace `VM_NAME` with the name of the VM.

The output looks similar to the following:

```text
ProductName:		macOS
ProductVersion:		26.6.2
BuildVersion:		25G83
```

Pomme runs the program directly, without a shell, so give the full path to the
executable and pass each argument separately. Everything after `--` goes to the
guest program, so guest flags don't conflict with Pomme flags.

`pomme exec` keeps the guest's standard output and standard error separate and
writes them to the host's standard output and standard error in the order that
the guest produced them.

### Understand exit codes and limits

When the guest program exits, `pomme exec` exits with the same status, from
`0` to `255`. If a signal ends the guest program, `pomme exec` exits with
`128` plus the signal number. Pomme also uses the following exit codes:

- `124`: the command didn't finish within its time limit.
- `130`: you interrupted the command on the host, for example with
  Control+C.

By default, Pomme waits up to 60 seconds. To change the limit, pass
`--timeout SECONDS`.

A foreground command can return at most 16 MiB of output in at most 16,384
output frames. If a command exceeds either limit, Pomme reports a failure
instead of silently truncating the output. For commands with more output,
redirect the output to a guest file and copy it to the host. For details, see
[Transfer files](/guides/transfer-files/).

For the full list of exit codes, see [Exit codes](/reference/exit-codes/).

## Run a shell command

To run a shell expression, use `pomme shell` with the expression in quotes.
Pomme runs it with `/bin/sh -c`, so you can use pipes, redirection, and
variables:

```sh
pomme shell VM_NAME 'ls -l /Users | wc -l'
```

Replace `VM_NAME` with the name of the VM.

A shell expression is a one-shot command. It follows the same output, exit
code, and time limit rules as `pomme exec`.

If you run `pomme shell VM_NAME` without an expression, Pomme opens an
interactive shell instead. For details, see
[Use durable terminal sessions](/guides/use-terminal-sessions/).

## Control how the command runs

By default, the command runs as `root` in the guest. The following flags work
with both `pomme exec` and `pomme shell`:

| Flag | Effect |
| --- | --- |
| `--user USER` or `--uid UID` | Run as a guest user. Use one of the two flags, not both. |
| `--group GROUP` or `--gid GID` | Run with a guest group. Use one of the two flags, not both. |
| `--cwd PATH` | Run in an absolute guest working directory. |
| `-e`, `--env KEY=VALUE` | Set a guest environment variable. Repeat the flag for more variables. |
| `-i`, `--stdin` | Send the host's standard input to the command. |
| `--guest-stdin PATH` | Read standard input from an absolute guest file. |
| `--guest-stdout PATH` | Write standard output to an absolute guest file. |
| `--guest-stderr PATH` | Write standard error to an absolute guest file. |

The command receives the `HOME`, `USER`, `LOGNAME`, and `SHELL` environment
variables for the account it runs as. Values that you set with `--env` take
precedence. `PATH` is the guest agent's `PATH`.

For example, the following command pipes a host file into a command that runs
as a guest user in that user's home folder:

```sh
pomme exec VM_NAME --stdin --user USER_NAME --cwd /Users/USER_NAME -- /usr/bin/wc -l < notes.txt
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `USER_NAME`: the short name of a guest user account.

You can't combine `--stdin` with `--guest-stdin` or with `--detach`.

## Run a command in the background

A background job keeps running in the guest after the Pomme command returns.
Use a job for a command that takes longer than you want to wait, or that must
keep running while you do other work.

To start a background job, pass `--detach` (`-d`) to `pomme exec`, or to
`pomme shell` with an expression:

```sh
pomme exec VM_NAME --detach -- /usr/bin/sleep 30
pomme shell VM_NAME --detach 'softwareupdate --list > /tmp/updates.txt 2>&1'
```

Replace `VM_NAME` with the name of the VM.

Pomme prints the job ID. To manage the job, use the following commands:

| Command | Effect |
| --- | --- |
| `pomme jobs list VM_NAME` | List the VM's background jobs. |
| `pomme jobs inspect VM_NAME JOB_ID` | Show the job's state. |
| `pomme jobs logs VM_NAME JOB_ID` | Print the job's output. |
| `pomme jobs wait VM_NAME JOB_ID` | Wait for the job to finish. Accepts `--timeout SECONDS`. |
| `pomme jobs kill VM_NAME JOB_ID` | Send a signal to the job. |

Replace `JOB_ID` with the ID that Pomme printed when it started the job.

`pomme jobs kill` sends `TERM` by default. To send a different signal, pass
`--signal` with `KILL`, `INT`, or `HUP`:

```sh
pomme jobs kill VM_NAME JOB_ID --signal KILL
```

The guest agent keeps the job records. You can manage a job only while the
agent that started it is running, so restart the guest only after your
jobs finish.

:::note
With `--pty`, `pomme exec --detach` creates a detached terminal session instead
of a background job. For details, see
[Use durable terminal sessions](/guides/use-terminal-sessions/).
:::

## Run an interactive program

To run a program that needs a terminal, such as `top` or an editor, pass
`--pty`:

```sh
pomme exec VM_NAME --pty -- /usr/bin/top
```

Replace `VM_NAME` with the name of the VM.

A PTY command runs as a durable terminal session that you can detach from and
reattach to. It requires an interactive terminal on the host, doesn't accept
`--timeout`, and doesn't support JSON output or the `--guest-stdin`,
`--guest-stdout`, and `--guest-stderr` flags. For details, see
[Use durable terminal sessions](/guides/use-terminal-sessions/).

## What's next

- [Use durable terminal sessions](/guides/use-terminal-sessions/)
- [Transfer files](/guides/transfer-files/)
- [`pomme exec` reference](/reference/cli/pomme-exec/)
- [`pomme jobs` reference](/reference/cli/pomme-jobs/)
- [Exit codes](/reference/exit-codes/)
