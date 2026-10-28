---
title: Release notes
description: Changes in each version of Pomme.
---

This page lists changes in each version of Pomme, newest first.

## Pomme 0.5.0 (pre-release)

### Features

- `pomme install VM_NAME --pkg PATH` installs a flat macOS installer package
  from the host in a running VM. Pomme copies the package into a new
  root-only folder in the guest, runs `/usr/sbin/installer` as `root` with the
  startup volume as the target, and removes the copy afterwards. Pomme
  waits up to 30 minutes for the installer unless you pass `--timeout`. If
  the wait ends first, the installer keeps running in the guest and Pomme
  leaves the copy in place. A failed installation prints the installer's output, reports
  `guest-package-install-failed`, and exits with the installer's status. For
  details, see [Install packages](/guides/install-packages/).

### Fixes

- In `pomme shell` and `pomme exec --pty`, Backspace now erases characters
  on the screen after you switch to another user, for example with
  `su - pomme`. The guest terminal had no `TERM`, so zsh redrew each erased
  character as a space. Pomme now sets `TERM` to the host's terminal type
  when macOS includes a description of it, and to `xterm-256color`
  otherwise. To choose a different type, pass `--env TERM=VALUE`. For
  details, see [Run guest commands](/guides/run-guest-commands/).

## Pomme 0.4.1

Pomme 0.4.1 fixes failures in `pomme amfi enable`, `pomme amfi disable`,
`pomme create`, and `pomme template create --provisioned`. Like 0.4.0, it's
beta software, and it was released before the release qualification matrices
for Tahoe and Sequoia ran. For what qualification covers, see
[Supported macOS versions](/concepts/os-qualification/#release-qualification).
To update, run `pomme update`.

### Fixes

- `pomme amfi disable` no longer fails with `security-operation-pending` when
  you run it again after `pomme amfi enable` and a SIP change. Pomme required
  the boot policy to match the one it saw when it finished enabling AMFI, byte
  for byte, but `pomme sip enable` and `pomme sip disable` rewrite the policy.
  Pomme now recognizes a finished enable from its own record and the unchanged
  boot arguments. To finish an operation that already stopped with this error,
  update Pomme and run the command that the error suggests, such as `pomme
  amfi disable NAME --final-state previous`. The VM keeps its earlier agent
  until the operation finishes, so if the command then fails with
  `security-change-unverified`, run it again.
- `pomme amfi enable` and `pomme amfi disable` no longer fail with
  `security-change-unverified` when they continue a few seconds after they
  restart the VM. Right after a boot, `diskutil` can return incomplete
  information about the startup volume, so the guest now repeats its read-only
  checks for up to 15 seconds before it refuses.
- `pomme create` no longer fails with `provisioning-phase-failed` when
  installing the Pomme agent in Recovery takes longer than 5 seconds, for
  example on a busy host. The installation now gets 30 seconds.
- `pomme template create --provisioned`, `pomme sip disable`, and the other
  commands that create the owner account wait up to 30 seconds for macOS to
  report the new account as a volume owner, as intended. A retry limit ended
  the wait after about 3 seconds, and a provisioned macOS 26.6.2 template
  failed with "Pomme couldn't parse the guest's report of the startup
  volume's owners." When that report still doesn't parse, the unified log
  now records its layout but leaves out identifiers and other values that
  could identify an account.

## Pomme 0.4.0

Pomme 0.4.0 writes its diagnostics to the host's unified log, and makes
`pomme sip disable` and the other commands that leave Recovery faster. A stop
from Recovery now takes under a second when the Pomme agent in Recovery is
connected, instead of 30 seconds. `pomme sip disable`, `pomme amfi disable`,
and `pomme mdm` no longer ask before they create the owner account on a fresh
VM. Like 0.3.0, it's beta software, and it was released before the release
qualification matrices for Tahoe and Sequoia ran. For what qualification
covers, see
[Supported macOS versions](/concepts/os-qualification/#release-qualification).
To update, run `pomme update`.

### Features

- Pomme writes its diagnostics to the host's unified log under the subsystem
  `com.github.weswhet.pomme`, so you can read what a failed command did after
  its Terminal window is closed. The log records each command's start and
  end, progress steps, warnings, and reported errors with their error codes,
  and leaves out passwords, tokens, and other secrets. For the commands that
  read it, see
  [Collect Pomme's logs](/resources/troubleshooting/#collect-pommes-logs).

### Fixes

- `pomme sip disable`, `pomme amfi disable`, and `pomme mdm` no longer ask
  before they create the `pomme` owner account on a verified fresh VM, such as
  a macOS 26 VM that `pomme create` made. Pomme creates an owner only on a VM
  that nobody has set up, so the question added nothing. `-f` and `--force`
  are still accepted but have no effect, and the
  `security-confirmation-required` error is gone.
- `pomme create --experimental-recovery` no longer prints "Pomme couldn't
  record the agent installation attempt" for macOS 27 VMs. The message was
  harmless: creation still verified the agent and finished.
- `pomme restart` no longer fails with "No running VM helper is listening"
  when it stops a running VM. The start could find the stopped VM's helper
  before it finished exiting. `pomme start` right after `pomme stop` had the
  same problem.
- For a VM created with `--experimental-recovery`, `pomme restart --mode
  recovery` and the commands that boot Recovery, such as `pomme sip disable`,
  let the guest shut itself down in a few seconds before the Recovery boot,
  instead of waiting up to 30 seconds and then powering it off.
- A stop from Recovery no longer waits 30 seconds before it powers the VM
  off. When the Pomme agent in Recovery is connected, as it always is for a
  VM created with `--experimental-recovery`, Pomme runs `sync` in the guest
  first and then powers the VM off. `pomme stop`, `pomme restart`, and the
  commands that leave Recovery, such as `pomme sip disable`, finish up to
  30 seconds sooner.

## Pomme 0.3.0

Pomme 0.3.0 boots macOS Recovery only for changes that macOS allows nowhere
else, and does everything else in normal macOS through the guest agent. Status
checks, AMFI changes, and new clones of provisioned templates no longer boot
Recovery, and a typical `pomme mdm` enrollment boots it once instead of five
times. It also adds an experimental way to reach Recovery without navigating
its screens, and a repair for VMs that a guest update left short of memory.
Like 0.2.3, it's beta software, and it was released before the release
qualification matrices for Tahoe and Sequoia ran. For what qualification
covers, see
[Supported macOS versions](/concepts/os-qualification/#release-qualification).
To update, run `pomme update`.

### Features

- `pomme create --experimental-recovery` prepares the new VM's Recovery image
  on the host with an embedded agent that starts on its own, so Pomme reaches
  a Recovery terminal without navigating Recovery's screens. Pomme keeps the
  original image for normal boots and switches images only while the VM is
  stopped. The prepared image's seal is broken, though SIP and AMFI don't
  change, and a macOS update in the guest returns the VM to the standard
  Recovery route. The flag works with direct creation and config batches, and
  `--resume` keeps the choice. For details, see
  [Try experimental image preparation](/guides/create-vms/#try-experimental-image-preparation).
- `pomme firmware inspect` and `pomme firmware repair` find and fix a VM that
  a macOS 26.7 or 15.8 update in the guest left with about 1.75 GB of memory,
  an update that never finishes, and a Recovery that doesn't start. The update
  installs the macOS 27 boot firmware, and the repair restores the firmware
  that the VM was installed with, after it saves a backup. `pomme inspect` now
  reports a VM's boot firmware, and Pomme warns before it boots such a VM into
  Recovery. For details, see
  [A guest update hangs and the VM has less memory](/resources/troubleshooting/#a-guest-update-hangs-and-the-vm-has-less-memory).

### Changes

- `pomme sip status` and `pomme amfi status` read the configuration through the
  guest agent in normal macOS from any starting state. A stopped, paused, or
  Recovery VM starts normal macOS for the check instead of Recovery, and then
  returns to the state that `--final-state` requests. JSON output reports
  `"source": "normalAgent"`. For details, see
  [Check the current status](/guides/change-sip-and-amfi/#check-the-current-status).
- `pomme amfi disable` and `pomme amfi enable` don't boot Recovery on a VM
  whose SIP you turned off with `pomme sip disable`, because that boot policy
  already allows custom boot arguments. Pomme changes the LocalPolicy in
  Recovery only for a different boot policy. This needs a guest agent from
  this release; run `pomme agent update VM_NAME` to update an existing VM.
- `pomme mdm` reads AMFI through the guest agent before and during
  enrollment, so turning off SIP is the only step that boots Recovery.
- A VM cloned from a template that you create with
  `pomme template create --provisioned` gets its agent in normal macOS instead
  of Recovery. The template keeps its agent's credential in your login
  Keychain, and `pomme template list` reports it in `agentCredentialRetained`.
  Clones of templates created with an earlier release still use Recovery. For
  details, see [Use templates](/guides/use-templates/#how-clones-get-their-agent).
- `pomme create --resume` and `pomme agent repair` first check whether normal
  macOS can prove an agent that an interrupted installation already put in
  place, and boot Recovery only when it can't.
- Hosts and guests on macOS 27 or later use first-boot provisioning instead of
  a Recovery agent installation, as long as the guest is no newer than the
  host. Before, only macOS 27 guests did.
- On a macOS build that Recovery automation doesn't support, only
  `pomme sip disable` is refused up front. `pomme sip enable`, status checks,
  and AMFI changes on the standard boot policy run there.
- `--final-state previous` leaves a VM that was paused in Recovery stopped,
  instead of booting Recovery only to pause it again. If Pomme can't reach a
  requested final state after a Recovery session, it no longer boots Recovery
  again on the way back.
- The progress spinner on an interactive terminal spells `pomme` in lowercase
  letters, one letter at a time. It draws each letter one dot at a time in its
  own color and then replaces it with the next, which starts beside the dot
  where the last one ended. The spinner is one column wider than before.
  `--progress plain` output is unchanged.

### Fixes

- Creating a VM from a template no longer fails with "A host operation
  failed" when the restore image that the template came from has since been
  removed from the Mac. A clone copies the template's installed disk and
  doesn't need the image.
- The guest agent's AMFI status read in normal macOS could time out after
  5 seconds just after the guest started, so Pomme used Recovery instead. It
  now has the same time limit as the other AMFI operations.

## Pomme 0.2.3

Pomme 0.2.3 fixes macOS 27 VM creation and lets `pomme delete --force` delete
a VM whose provisioning records don't match. Like 0.2.2, it's beta software,
and it was released before the release qualification matrices for Tahoe and
Sequoia ran. For what qualification covers, see
[Supported macOS versions](/concepts/os-qualification/#release-qualification).
To update, run `pomme update`.

### Fixes

- Creating a macOS 27 VM no longer fails right after the guest restarts with
  "Pomme couldn't pass the owner's credential to a guest command." The
  guest's directory service can take more than 5 seconds to check the
  owner's password just after it starts, and Pomme stopped waiting at 5
  seconds. It now waits up to 30 seconds.
- `pomme delete NAME --force` deletes a VM whose provisioning records don't
  match its bundle, such as a bundle that was moved or copied. Before, it
  stopped with `provisioning-ownership-mismatch`, and the error's hint
  suggested the same command. Pomme removes only the bundle and keeps the
  VM's Keychain items, because it can't prove which items are the VM's. JSON
  output reports this in the new `credentialsRetained` field. For details, see
  [Deleting a VM](/concepts/vm-lifecycle/#deleting-a-vm).

## Pomme 0.2.2

Pomme 0.2.2 lets an MDM-enrolled VM on macOS 27 receive push commands.
Like 0.2.1, it's beta software, and it was released before the release
qualification matrices for Tahoe and Sequoia ran. For what qualification
covers, see
[Supported macOS versions](/concepts/os-qualification/#release-qualification).
To update, run `pomme update`.

### Fixes

- On macOS 27, an MDM-enrolled VM can receive push commands. macOS 27 skips
  a boot task in a VM, so the guest couldn't create its push identity and never
  sent `TokenUpdate`. The Pomme agent now runs that task at every startup, and
  `pomme mdm` leaves SIP off on macOS 27, which the task needs. The result
  reports `pushIdentity`. For details, see
  [Receive push commands on macOS 27](/guides/enroll-in-mdm/#receive-push-commands-on-macos-27).

## Pomme 0.2.1

Pomme 0.2.1 gives every error a stable code, adds `pomme bug-report`, and
checks free space before it creates a VM. Like 0.2.0, it's beta software, and
it was released before the release qualification matrices for Tahoe and
Sequoia ran. For what qualification covers, see
[Supported macOS versions](/concepts/os-qualification/#release-qualification).
To update, run `pomme update`.

### Features

- Every error now has a stable code, such as `vm-not-found`. Pomme prints it
  after the message, with a link to its entry on the new
  [Errors](/reference/errors/) page, which describes each code's cause and
  resolution.
- `pomme bug-report [NAME]` collects the Pomme version, this Mac's details,
  the last error, and a VM's inspect output, helper logs, and guest logs into
  one redacted Markdown file to attach to an issue. It never uploads anything.
- In JSON and JSONL output, every failed result has `errorCode`, `hint`, and
  `causes` fields. For details, see
  [Structured output](/reference/structured-output/#errors).
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
  could download and install for a long time before it ran out of space. A
  dry run reports the check in its `diskSpace` field.

## Pomme 0.2.0

Pomme 0.2.0 fixes `pomme start` on a paused VM and redraws the progress
spinner. Like 0.1.0, it's beta software, and it was released before the
release qualification matrices for Tahoe and Sequoia ran. For what
qualification covers, see
[Supported macOS versions](/concepts/os-qualification/#release-qualification).
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
[Supported macOS versions](/concepts/os-qualification/#release-qualification).
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
  [Update the agent](/guides/repair-the-agent/#update-the-agent).
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
  [Digest pinning](/concepts/guest-agent/#digest-pinning).
- Pomme publishes signed releases. To install the newest release, run
  `brew install weswhet/tap/pomme` or
  `curl -fsSL https://pommevm.dev/install.pl | perl`. To install the newest
  alpha, run `curl -fsSL https://pommevm.dev/install.pl | POMME_CHANNEL=alpha perl`.
  For details, see
  [Install Pomme](/get-started/install/).
- `pomme update` updates Pomme the way that you installed it: with
  `brew upgrade` for Homebrew, and with the install script otherwise.
  `pomme update --check` reports whether an update is available. For details,
  see [Update Pomme](/get-started/install/#update-pomme).
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
