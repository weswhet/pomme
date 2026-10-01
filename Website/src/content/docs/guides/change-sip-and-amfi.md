---
title: Change SIP and AMFI
description: Check, turn off, and restore System Integrity Protection and Apple Mobile File Integrity in a Pomme VM.
---

This guide shows you how to check and change System Integrity Protection (SIP)
and Apple Mobile File Integrity (AMFI) in a Pomme-owned VM. Pomme performs each
change as a journaled transaction, verifies the result on a fresh normal boot,
and then returns the VM to the state that you request.

For background on the design of these workflows, see
[Security workflows](/concepts/security-model/).

:::caution
Turning off SIP or AMFI removes macOS protections inside the guest. Use these
commands only on VMs that you use for testing, and restore both settings when
you no longer need them off.
:::

## Before you begin

- [Create a VM](/guides/create-vms/) and make sure that its guest agent is
  healthy. To check, run `pomme agent status VM_NAME`. For details, see
  [Check and repair the guest agent](/guides/repair-the-agent/).
- End any active terminal sessions in the VM. Recovery security
  workflows don't start while a terminal session is active. For details, see
  [Use durable terminal sessions](/guides/use-terminal-sessions/).
- Decide how Pomme authorizes the owner account. For details, see
  [Provide owner authorization](#provide-owner-authorization).

## Check the current status

To see whether SIP or AMFI is on, run the `status` command:

```sh
pomme sip status VM_NAME
pomme amfi status VM_NAME
```

Replace `VM_NAME` with the name of your VM.

When the VM is already running normal macOS and the final state is `previous`
(the default) or `normal`, status commands read the configuration through the
guest agent and the VM doesn't restart. In every other case, or when the agent
can't provide a verified answer, the status command observes the guest through
Recovery, so the VM restarts during the check. When the check finishes, Pomme
returns the VM to the state it was in before the command. Status commands never
ask for or transmit an owner password.

## Choose the final VM state

Every SIP and AMFI command accepts `--final-state`, which sets the state that
Pomme leaves the VM in after a successful run. The following values are
supported:

| Value | Final state |
| --- | --- |
| `previous` | The run state captured before the command started. This is the default. |
| `stopped` | The VM is stopped. |
| `normal` | The VM runs normal macOS. |
| `recovery` | The VM runs Recovery. |
| `paused` | The VM is paused. A paused VM keeps the boot mode it had before the pause. |

A successful result reports the resolved `finalState` and whether Pomme
verified it (`finalStateVerified`).

If a command fails, Pomme doesn't apply `--final-state`. Depending on the
failure, Pomme either restores the state captured at the start, leaves the VM
in its failure state for inspection, or reports that restoration is
incomplete.

## Turn off SIP and AMFI

AMFI changes require SIP to be off, so you turn off SIP first. The `--force`
flag doesn't bypass this order.

To turn off SIP and then AMFI, follow these steps:

1. Turn off SIP:

   ```sh
   pomme sip disable VM_NAME
   ```

2. Turn off AMFI:

   ```sh
   pomme amfi disable VM_NAME
   ```

Replace `VM_NAME` with the name of your VM.

To turn off AMFI, Pomme changes the LocalPolicy in Recovery, boots normal
macOS to write and read back the boot arguments, and then boots normally again
to verify the effective arguments. If SIP is still on, the AMFI command stops
with the following error:

```text
AMFI changes require SIP disabled while boot arguments are written and verified. Run pomme sip disable <vm> first; restore AMFI before re-enabling SIP.
```

If the guest already has the requested setting, Pomme records the result
without making a change and without asking for owner credentials.

## Restore AMFI and SIP

Restore the settings in the reverse order: AMFI first, then SIP.

To restore AMFI and then SIP, follow these steps:

1. Restore AMFI:

   ```sh
   pomme amfi enable VM_NAME
   ```

2. Turn on SIP:

   ```sh
   pomme sip enable VM_NAME
   ```

Replace `VM_NAME` with the name of your VM.

Turning SIP on doesn't boot Recovery. The guest agent runs `csrutil clear` in
normal macOS with the owner's credentials, and Pomme then restarts the guest
and checks `csrutil status` on the new boot. A VM created with an earlier Pomme
release, whose guest agent can't run `csrutil clear`, turns SIP on in Recovery
instead.

`pomme amfi enable` restores the exact AMFI configuration that Pomme saved when
it turned AMFI off. If AMFI is off but Pomme has no saved configuration, for
example because AMFI was turned off outside Pomme, the command stops before it
changes anything and reports the `missingBaseline` error:

```text
AMFI enable requires the exact recorded baseline. No guessed LocalPolicy reset was attempted.
```

## Provide owner authorization

Changing SIP or AMFI requires an owner account in the guest. How Pomme gets
authorization depends on whether the VM already has an owner.

### Fresh VMs without an owner

On a VM that Pomme verifies as fresh and Pomme-owned, the workflow can create
the owner account for you. It creates a `pomme` administrator, turns on
automatic login for that account, and finishes Setup Assistant.

Pomme asks you to confirm before it creates the account. To confirm without a
prompt, for example in a script, add `--force`:

```sh
pomme sip disable VM_NAME --force
```

If you run the command without a terminal and without `--force`, it stops with
the following error:

```text
Creating the owner account on this verified fresh VM requires confirmation. Run from an interactive terminal or pass --force.
```

:::caution
`--force` only confirms creating the owner on a verified fresh VM. It doesn't
override owner credentials, freshness or identity checks, native login
restrictions, an unfinished transaction, or a failed cleanup step. If macOS
refuses automatic login, for example because of Touch ID, Apple Pay, or App
Store protections, the workflow stops and `--force` can't change that.
:::

### VMs with an existing owner

Pomme verifies an existing owner account but never replaces it or changes its
password. Pomme accepts the owner's credentials from one of the following
sources:

- Both of the `POMME_AUTHORIZED_USER` and `POMME_AUTHORIZED_PASSWORD`
  environment variables. If you set only one of them, Pomme rejects the
  request.
- The VM-scoped owner credential that Pomme stores in your login Keychain.
- An interactive prompt, when you run the command in a terminal.

For example, to supply the credentials through the environment, run the
following:

```sh
POMME_AUTHORIZED_USER=OWNER_NAME \
POMME_AUTHORIZED_PASSWORD="$(security find-generic-password -s MY_ITEM -w)" \
  pomme sip disable VM_NAME
```

Replace the following:

- `OWNER_NAME`: the short name of the guest's owner account.
- `MY_ITEM`: the name of a Keychain item where you keep the password. You can
  use any other secret source that doesn't put the password in your shell
  history.
- `VM_NAME`: the name of your VM.

Pomme passes the password to its credential boundary separately. It never
places the password in command arguments or in the durable journal.

If Pomme finds no credentials, the command stops with the following error:

```text
Owner credentials are required. Set both POMME_AUTHORIZED_USER and POMME_AUTHORIZED_PASSWORD, restore the exact VM-scoped Keychain item, or run from an interactive terminal.
```

## Resume an interrupted change

Pomme records each step of a SIP or AMFI change in a per-VM journal. If a
change stops partway, for example because the host restarted, the journal and
the VM are kept.

To resume, repeat the same command with the same `--final-state` value. For
example, if this command was interrupted:

```sh
pomme sip disable VM_NAME --final-state stopped
```

Run exactly the same command again. Pomme observes the guest, reconciles the
retained journal, and continues without repeating an owner or security write
that already happened.

You can't change the requested action or final state of a retained operation.
Pomme rejects a different request instead of rewriting the journal.

If you start a different operation while one is unfinished, Pomme stops before
it changes anything:

```text
Another unfinished Pomme security operation owns this VM.
```

Finish the original operation first by repeating its command.

If Pomme can't prove that cleanup finished, it reports `restorationIncomplete`
and doesn't boot or restore the VM:

```text
VM state restoration is incomplete. The account, credentials, and security journal were retained; repeat the same command after inspecting the VM.
```

## Capture Recovery screenshots for debugging

To keep screenshots of each automatic Recovery navigation step, add `--debug`:

```sh
pomme sip disable VM_NAME --debug
```

Pomme prints the private directory and the saved file names to standard
error. The screenshots stay after the command finishes, whether it succeeds or
fails. Because full-resolution screenshots can show local identifiers, delete
the directory when you no longer need it.

## What's next

- [Enroll a VM in MDM](/guides/enroll-in-mdm/), which turns off only the
  security settings that enrollment needs.
- [Security workflows](/concepts/security-model/)
- [`pomme sip` reference](/reference/cli/pomme-sip/)
- [`pomme amfi` reference](/reference/cli/pomme-amfi/)
- [Troubleshooting](/resources/troubleshooting/)
