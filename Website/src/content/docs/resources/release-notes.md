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

### Compatibility

- The MDM enrollment journal is now schema 6. Pomme reads schema 3–5 journals
  with `--final-security restore` and rewrites them as schema 6 on their next
  update.

:::caution
An older Pomme can't read a schema 6 journal. Finish any retained MDM work
before you downgrade Pomme.
:::
