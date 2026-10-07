---
title: Release notes
description: Changes in each version of Pomme.
---

This page lists changes in each version of Pomme, newest first.

## Pomme 0.1.0 (pre-release)

Pomme 0.1.0 is a development build. It isn't published: a `v0.1.0` tag and
package publication require green CI, independent review of the Tahoe and
Sequoia live qualification matrices, and a clean disposable-VM qualification.
For details, see [Supported macOS versions](/concepts/os-qualification/).

Pomme 0.1.0 begins with an independent history and its own host, control,
guest agent, Recovery, packaging, and state identity.

### Features

- The `pomme` command creates and controls Pomme-owned macOS VMs. Normal macOS
  runs the persistent, authenticated Pomme guest agent. Bounded Recovery
  workflows use an expiring, request-bound Pomme Recovery session. Both speak
  PommeAgentProtocol version 1, and the host helper speaks PommeControlProtocol
  version 1.
- `pomme mdm VM --profile FILE` enrolls a VM in MDM from any state. It creates
  a missing VM, resumes incomplete creation, finishes a retained standalone SIP
  or AMFI operation, and then enrolls. You can repeat the command safely after
  any failure.
  - `--dry-run` reports the plan without changing the VM.
  - `--final-security disabled` keeps the SIP and AMFI changes that enrollment
    made.
  - When only the profile's own certificate payloads validate the MDM server,
    Pomme installs them as a separate
    `com.github.weswhet.pomme.mdm-trust.*` configuration profile.
- `pomme agent update VM` replaces the guest agent in a running VM with the
  agent from the host's `pomme` build. It doesn't use Recovery or restart the
  guest. SIP, AMFI, and MDM workflows accept the updated agent. For details, see
  [Update the agent](/guides/repair-the-agent/#update-the-agent).
- VMs start faster. launchd no longer throttles the guest agent's CPU and disk
  access, which during boot delayed the agent by up to 22 seconds. Because
  `pomme start` waits for the agent, it now returns about 9 seconds after it
  begins. Programs that `pomme exec` runs are no longer throttled either. An
  existing VM gets this change after you update its agent and restart the VM.
- Most commands accept `--progress auto|plain|off` to control the progress
  display on standard error.

### Command-line syntax

A command takes at most one kind of positional value: the VM, or the file or
endpoint that it acts on. Every other value is a named flag:

- The `pomme jobs` commands that act on one job take its ID with `--job`, and
  the `pomme sessions` commands that act on one session take its ID with
  `--session`. For example, `pomme jobs logs dev --job JOB_ID`.
- `pomme snapshot create`, `restore`, and `delete` require the snapshot name
  with `--snapshot`. For example,
  `pomme snapshot create dev --snapshot clean`.
- `pomme shell` only opens a durable shell session, attached or with
  `--detach`. It keeps the user, group, working directory, and environment
  flags, and no longer accepts `--timeout`, `--stdin`, `--pty`,
  `--guest-stdin`, `--guest-stdout`, or `--guest-stderr`. To run a one-shot
  shell expression, use `pomme exec VM -- /bin/sh -c 'EXPRESSION'`.
- The `pomme ui` commands that act on a VM name it with `--vm`, which falls
  back to `POMME_VM_NAME`. `pomme ui key` takes the key with `--key`,
  `pomme ui type` takes exactly one of `--text` or `--text-env`, and
  `pomme ui key-sequence` takes its keys after `--`. For example,
  `pomme ui key-sequence --vm dev -- down return`.
- The unavailable `pomme ui ai settings` command is removed, and
  `pomme tools` no longer reports `uiCapabilities.settingsAI`.
- The `pomme tools` and `pomme agent-help` JSON output starts at
  `schemaVersion` 1.

### New flags

- `pomme stop`, `pomme pause`, `pomme resume`, and `pomme delete` accept
  `--all` (`-a`) in place of VM names. Each acts on the VMs that it applies
  to: `stop` on running and paused VMs, `pause` on running VMs, `resume` on
  paused VMs, and `delete` on every VM. For details, see
  [Act on every VM](/guides/manage-vm-lifecycle/#act-on-every-vm).
- Every `--force` flag also accepts `-f`.

### Compatibility

- The MDM enrollment journal is now schema 6. Pomme reads schema 3–5 journals
  with `--final-security restore` and rewrites them as schema 6 on their next
  update.

:::caution
An older Pomme can't read a schema 6 journal. Finish any retained MDM work
before you downgrade Pomme.
:::
