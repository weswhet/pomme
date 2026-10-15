---
title: Patch notes (release notes)
description: Every balance change, bug fix, and new trap in each version of Pomme.
---

Patch notes, Crawler! This page lists changes in each version of Pomme,
newest first. The System reads these so that it knows which old tricks stopped
working. You should too. The entries below are the official record, so the
System has been told to keep its commentary out of them. It's taking this
personally.

## Pomme 0.2.2

Pomme 0.2.2 lets an MDM-enrolled VM on macOS 27 receive push commands.
Like 0.2.1, it's beta software, and it was released before the release
qualification matrices for Tahoe and Sequoia ran. For what qualification
covers, see
[Supported macOS versions](/crawler/concepts/os-qualification/#release-qualification).
To update, run `pomme update`.

### Fixes

- On macOS 27, an MDM-enrolled VM can receive push commands. macOS 27 skips
  a boot task in a VM, so the guest couldn't create its push identity and never
  sent `TokenUpdate`. The Pomme agent now runs that task at every startup, and
  `pomme mdm` leaves SIP off on macOS 27, which the task needs. The result
  reports `pushIdentity`. For details, see
  [Receive push commands on macOS 27](/crawler/guides/enroll-in-mdm/#receive-push-commands-on-macos-27).

## Pomme 0.2.1

Pomme 0.2.1 gives every error a stable code, adds `pomme bug-report`, and
checks free space before it creates a VM. Like 0.2.0, it's beta software, and
it was released before the release qualification matrices for Tahoe and
Sequoia ran. For what qualification covers, see
[Supported macOS versions](/crawler/concepts/os-qualification/#release-qualification).
To update, run `pomme update`.

### Features

- Every error now has a stable code, such as `vm-not-found`. Pomme prints it
  after the message, with a link to its entry on the new
  [Errors](/crawler/reference/errors/) page, which describes each code's cause and
  resolution.
- `pomme bug-report [NAME]` collects the Pomme version, this Mac's details,
  the last error, and a VM's inspect output, helper logs, and guest logs into
  one redacted Markdown file to attach to an issue. It never uploads anything.
- In JSON and JSONL output, every failed result has `errorCode`, `hint`, and
  `causes` fields. For details, see
  [Structured output](/crawler/reference/structured-output/#errors).
- The documentation site has a Crawler mode: the switch next to the theme
  selector retells the guides in the voice of a sarcastic game-show System.
  Its facts, commands, and examples match the normal pages, and pages that it
  doesn't retell show their normal text.

### Changes

- Error messages say what happened, give the operating-system or framework
  reason when there is one, and name the next step. For example, a guest
  command that doesn't exist reports the missing path instead of "The
  requested operation could not be completed," and a failed creation phase
  names the phase and its cause.
- With `--format json` or `--format jsonl`, an error that stops a command
  before it starts an operation, such as a VM that doesn't exist, now prints
  a failed result on standard output. Before, standard output stayed empty.
- A command that acts on several VMs, such as `pomme stop a b`, finishes every
  VM when one of them fails, and reports each failure in that VM's result.
  Before, it stopped at the first error.
- When a VM helper starts, Pomme keeps the previous helper's log as
  `pomme-helper.previous.log` instead of erasing it. Each log starts with the
  Pomme version, the host's macOS version, and the boot mode, and it records
  every failed request with its error code.
- `pomme log --last` and other flags report the flag and the rule that a value
  broke, instead of an unknown control command.
- `pomme create` and `pomme template create` check free space before they
  download or write anything, and stop with the `host-disk-space-insufficient`
  error when a volume doesn't have room for the rest of the restore image and
  the installed system. A config batch is checked as a whole. Before, creation
  could download and install for a long time before it ran out of space, which
  the audience enjoyed far more than you did. A dry run reports the check in
  its `diskSpace` field.

## Pomme 0.2.0

Pomme 0.2.0 fixes `pomme start` on a paused VM and redraws the progress
spinner. Like 0.1.0, it's beta software, and it was released before the
release qualification matrices for Tahoe and Sequoia ran. For what
qualification covers, see
[Supported macOS versions](/crawler/concepts/os-qualification/#release-qualification).
To update, run `pomme update`.

### Fixes

- `pomme start` now resumes a paused VM, as its help describes. Before, it
  left the VM paused, waited for the guest agent until `--timeout` elapsed,
  and then reported that the agent didn't connect. Its JSON output includes
  `"resumed": true` when it resumed the VM. If the VM is paused in the other
  boot mode, `start` reports that it's paused instead of running.

### Changes

- The progress line on an interactive terminal shows a square spinner whose
  dots fill in and empty as they swirl around it, in a new color each lap.
  The elapsed time now appears right after the spinner, ahead of the VM name
  and the current step. The spinner also advances at a steady rate; before,
  macOS could delay its timer and skip frames. `--progress plain` output is
  unchanged.

## Pomme 0.1.0

Pomme 0.1.0 is the first release of Pomme. It's beta software, and it was
released before the release qualification matrices for Tahoe and Sequoia were
complete. For what qualification covers, see
[Supported macOS versions](/crawler/concepts/os-qualification/#release-qualification).
Each change to the `main` branch that passes CI also publishes an alpha, such
as `0.1.0-alpha.3`.

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
  [Update the agent](/crawler/guides/repair-the-agent/#update-the-agent).
- VMs start faster. launchd no longer throttles the guest agent's CPU and disk
  access, which during boot delayed the agent by up to 22 seconds. Because
  `pomme start` waits for the agent, it now returns about 9 seconds after it
  begins. Programs that `pomme exec` runs are no longer throttled either. An
  existing VM gets this change after you update its agent and restart the VM.
- `pomme start` checks for the agent every 50 milliseconds instead of every
  half second, so it returns sooner after the agent connects.
- Release builds strip the symbol table from the `pomme` executable, which
  halves its size. `pomme agent update` copies the smaller executable into a
  VM in about half the time.
- After the agent verifies the digest of its executable once, later starts
  check the code directory hash that the kernel validated instead of reading
  the whole executable again. For details, see
  [Digest pinning](/crawler/concepts/guest-agent/#digest-pinning).
- Pomme publishes signed releases. To install the newest release, run
  `brew install weswhet/tap/pomme` or
  `curl -fsSL https://pommevm.dev/install.pl | perl`. To install the newest
  alpha, run `curl -fsSL https://pommevm.dev/install.pl | POMME_CHANNEL=alpha perl`.
  For details, see
  [Install Pomme](/crawler/get-started/install/).
- `pomme update` updates Pomme the way that you installed it: with
  `brew upgrade` for Homebrew, and with the install script otherwise.
  `pomme update --check` reports whether an update is available. For details,
  see [Update Pomme](/crawler/get-started/install/#update-pomme).
- About once a day, a release build checks for a newer version in the
  background, and an interactive command prints a notice when one is
  available. The check never runs for JSON output, without a terminal, or when
  you set `CI` or `POMME_NO_UPDATE_CHECK`.
- VM creation keeps a copy of the agent executable that it pins, so
  `pomme agent repair` and `pomme create --resume` can still install that
  agent after you update Pomme.
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
  [Act on every VM](/crawler/guides/manage-vm-lifecycle/#act-on-every-vm).
- Every `--force` flag also accepts `-f`.

### Compatibility

- The MDM enrollment journal is now schema 6. Pomme reads schema 3–5 journals
  with `--final-security restore` and rewrites them as schema 6 on their next
  update.

:::caution
An older Pomme can't read a schema 6 journal. Finish any retained MDM work
before you downgrade Pomme.
:::
