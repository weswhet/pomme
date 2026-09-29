---
title: Guest agent
description: What the Pomme guest agent does, how the host authenticates to it, and how Pomme keeps the agent's identity pinned.
---

The guest agent is the Pomme service that runs inside a VM's copy of macOS.
Almost every command that works inside the guest, from running a program to
changing security settings, goes through an authenticated connection to the
agent. This page describes the agent's two roles, what it enables, how its
credential is stored, and how Pomme verifies that the agent is the one it
installed.

## Agent roles

The agent has two roles, one for each boot mode:

- **Normal agent.** In normal macOS, the persistent `PommeAgent` service runs
  from `/usr/local/libexec/pomme` under the launchd label
  `com.github.weswhet.pomme.agent`. Pomme installs it while it creates the VM,
  and it starts on every normal boot.
- **Recovery session.** In macOS Recovery, Pomme starts a temporary
  `PommeRecoverySession` for one bounded task. It authenticates with a
  short-lived credential, and Pomme removes it when the task ends.

Both roles speak `PommeAgentProtocol` version 1 over VSOCK. Each role
advertises an explicit set of capabilities, and Pomme checks for the
capability that an operation needs instead of inferring it from the boot mode.
For example, the Recovery terminal role can run terminal sessions but can't
transfer files or start other processes.

## What the agent enables

The normal agent is required for the following features:

- Running programs and shells with `pomme exec` and `pomme shell`, including
  background jobs and durable terminal sessions.
- Copying and reading files with `pomme cp` and `pomme cat`.
- Reading Pomme's unified log records with `pomme log`.
- The normal-macOS stages of SIP, AMFI, and MDM workflows.
- Turning Remote Login and Screen Sharing on and off.
- A graceful guest shutdown when you stop the VM.

Features that use the VM's display, such as `pomme ui` and automatic Recovery
navigation, don't need an agent. They work through the VM helper on the host.

## Credentials and the login Keychain

The normal agent and the host share a persistent credential. In the guest, it's
stored in the private file `/private/var/db/pomme/agent.token`. On the
host, Pomme keeps its copy in your file-based login Keychain, in an item
scoped to the VM's UUID. Every connection must prove that it knows the
credential by answering an HMAC-SHA256 challenge before it can do anything
else.

Pomme requires your login Keychain to be unlocked. It never unlocks the
Keychain for you, never reads your host password, and never changes the
Keychain item's access control list. If the Keychain is locked, commands that
need the agent fail until you unlock it.

Access to the Keychain item depends on the signing identity of the `pomme`
executable. Builds made with the documented signing workflow keep the same
identity, so a rebuilt `pomme` command keeps its access. An executable signed with a
different identity might ask you to authorize access to the item again.

## Agent status

To see the agent's state, run `pomme agent status VM_NAME`. The same
`guestAgent` object also appears in `pomme status` and `pomme inspect`
output. It contains the following fields:

| Field | Description |
| --- | --- |
| `connection` | The host's connection to the agent: `connected`, `connecting`, `disconnected`, `unavailable`, or `failed`. |
| `role` | The agent role for the current boot: `normal` or `recovery`. |
| `protocolVersion` | The agent protocol version, or `null` when no agent is connected. |
| `executableDigest` | The SHA-256 digest of the running agent executable, or `null` when no agent is connected. |
| `capabilities` | The operations that the connected agent advertises. |
| `updateState` | The agent's update state. It's `unavailable` when no agent is connected. |

## Digest pinning

When Pomme creates a VM, it records the SHA-256 digest of the agent that it
installs. Workflows that depend on the agent, such as security changes and MDM
enrollment, check that the connected agent has this pinned digest, the
expected protocol version, and the capabilities that the workflow needs. If the
agent doesn't match, the workflow stops before it makes a change.

Installing a new host `pomme` command doesn't upgrade the agent in existing VMs, and it
doesn't add new capabilities or log events to them. A workflow that needs a
capability that an older agent lacks reports that the agent must be updated.

## Repair

If the normal agent is missing, damaged, or out of date, `pomme agent repair`
reinstalls it through Recovery and then returns the VM to its previous state.
If provisioning is complete and the connected agent already has the required
protocol and capabilities, and its digest matches the host `pomme` command, repair reports
that the agent is healthy and makes no changes. For details, see
[Check and repair the guest agent](/guides/repair-the-agent/).

## Guest process environment

Programs that the agent starts run as root by default, or as the user or UID
that you request with `--user` or `--uid`. Each program inherits the agent's
environment, with the following variables set from the account that the
program runs as:

- `HOME`
- `USER`
- `LOGNAME`
- `SHELL`

`PATH` stays as the agent's value. Values that you pass with `--env` override
any of these variables.

## Owner account maintenance

On every normal boot, the agent looks for the `pomme` owner account. When the
account exists and its identity checks pass, the agent sets two Setup
Assistant preferences for it so that Setup Assistant doesn't reappear for
that account after a macOS update. The agent records its progress in the unified log under
the `buddy-preferences` category. Recovery sessions never run this task.

## Logging

The agent writes unified log records under the subsystem
`com.github.weswhet.pomme`. To read them from the host without opening the
guest, use `pomme log`. For details, see
[View guest agent logs](/guides/view-guest-logs/).

## What's next

- Check or reinstall the agent in
  [Check and repair the guest agent](/guides/repair-the-agent/).
- Learn how the agent is installed in
  [Durable creation and journals](/concepts/durable-creation/).
- Run programs through the agent in
  [Run commands in a VM](/guides/run-guest-commands/).
