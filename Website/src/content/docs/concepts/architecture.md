---
title: Architecture
description: How the Pomme command-line tool, its per-VM helper, and the guest agent work together to create and control macOS virtual machines.
---

Pomme is a command-line tool that creates and controls macOS virtual machines
(VMs) on Apple silicon through Apple's Virtualization.framework. This page
describes the parts that make up Pomme, how they communicate, and which
machines Pomme is willing to manage.

## Components

Pomme has four components. Two run on the host, the Mac that runs Pomme, and
two run in the guest, the copy of macOS inside a VM.

### Command-line tool

The `pomme` executable that you run on the host. It validates your request,
reads and writes the VM's bundle, and talks to the helper and the guest agent.

### VM helper

A background host process that owns one running VM. The helper keeps the VM
running after the command that started it exits. It also delivers keyboard and
pointer input to the VM and captures its display. The command-line tool talks
to the helper through a private Unix domain socket.

### Guest agent

`PommeAgent` is a persistent service that runs in normal macOS inside the
guest. Pomme installs it while it creates the VM. The agent runs guest
programs, transfers files, reads unified logs, and carries out the
normal-macOS parts of security and management workflows. For details, see
[Guest agent](/concepts/guest-agent/).

### Recovery session

`PommeRecoverySession` is a temporary service that Pomme starts in macOS
Recovery for one bounded task, such as changing System Integrity Protection
(SIP) or repairing the guest agent. It uses a short-lived credential, and Pomme
removes it before the VM moves to its requested final state.

## How the components communicate

The following diagram shows the connections between the components:

```text
 Host (your Mac)                          Guest (macOS in the VM)
┌──────────────────────────┐            ┌──────────────────────────────┐
│ pomme command-line tool  │            │ Normal macOS                 │
│            │             │            │   PommeAgent (persistent)    │
│            │ Unix socket │   VSOCK    │                              │
│            ▼             │◀──────────▶│ macOS Recovery               │
│ VM helper (one per VM)   │            │   PommeRecoverySession       │
│   display and input ─────┼───────────▶│   (temporary, one task)      │
└──────────────────────────┘            └──────────────────────────────┘
```

The command-line tool sends requests to the VM helper over a Unix domain
socket. The helper reaches the guest over VSOCK, a virtual socket between the
host and the VM that doesn't use the guest's network. In normal macOS, the
helper connects to the persistent guest agent. In Recovery, it connects to a
temporary Recovery session instead. Separately, the helper sends keyboard and
pointer input directly to the VM and reads its display, which works even when
no agent is running.

Pomme uses two independently versioned protocols:

- **`PommeControlProtocol` version 1** connects the command-line tool to the
  VM helper. Messages are bounded JSON lines. Before it sends a request, the
  command-line tool checks the helper's identity by its socket path, process
  ID, and process start time.
- **`PommeAgentProtocol` version 1** connects the host to the guest agent and
  to Recovery sessions. Every connection must authenticate with an
  HMAC-SHA256 challenge before it can perform any other operation. Each
  operation is gated by a capability that the agent advertises, and Pomme
  never assumes that an operation is allowed because of the VM's current boot
  mode.

Both protocols bound every message. A single protocol frame is at most
256 KiB, and process output and terminal data travel in chunks of at most
64 KiB. Large command output and file transfers are split into many chunks
rather than truncated silently.

## Ownership boundary

Pomme manages only the VMs and templates that it creates in its own
directory, `~/Library/Application Support/pomme`. It
doesn't discover, inspect, adopt, or migrate virtual machines, credentials,
sockets, or services that belong to another product.

A bundle counts as Pomme-owned only when its ownership record, VM identifier,
journal binding, and integrity reference all validate. If any of them fail to
validate, Pomme refuses to act on the bundle. For the directory layout, see
[Files and paths](/reference/files-and-paths/).

Pomme also never chooses a VM on your behalf. You name the VM in each command
or set `POMME_VM_NAME`. Pomme doesn't pick a VM because it's the only one
running. For details, see
[Environment variables](/reference/environment-variables/).

## What's next

- Learn how VMs move between states in
  [VM lifecycle and boot modes](/concepts/vm-lifecycle/).
- Learn what happens when Pomme creates a VM in
  [Durable creation and journals](/concepts/durable-creation/).
- Learn about the persistent service inside the guest in
  [Guest agent](/concepts/guest-agent/).
- Look up unfamiliar terms in the [Glossary](/resources/glossary/).
