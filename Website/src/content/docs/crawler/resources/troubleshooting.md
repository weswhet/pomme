---
title: You died (troubleshooting)
description: The most popular ways Crawlers die while they create, run, and change Pomme VMs, and how to come back from each one.
---

You died, Crawler. Congratulations. The viewers loved it. This page lists
common problems with Pomme, what causes them, and how to fix them, so that you
can come back and die more creatively next time. Error messages appear exactly as
Pomme prints them. Uppercase words such as `NAME` and `SIZE` stand for values
that differ on your system.

Before you troubleshoot, make sure that you're running the build you expect.
The System has seen too many Crawlers debug the wrong executable for an hour:

```sh
pomme --version
```

For more detail about any failing command, run it again with `--debug`. It's
the replay camera. Use it.

## Read an error

When a command fails, Pomme prints what happened, the next step when there is
one, and an error code with a link to its entry in [Errors](/crawler/reference/errors/):

```text
Error: No Pomme-owned VM named NAME exists. Create it with `pomme create NAME` or run `pomme list`.
Error code: vm-not-found. For help, see https://pommevm.dev/reference/errors/#vm-not-found
```

The sections on this page name the error code for each symptom. With
`--format json`, the same code is in the result's `errorCode` field. Every
death gets a label. The System is very organized about death.

## Report a problem

If an error doesn't explain itself, or the error code's entry says that Pomme
hit a failure that it doesn't expect, collect a bug report:

```sh
pomme bug-report NAME
```

The command writes one Markdown file in the current directory with the Pomme
version, this Mac's macOS version, model, memory, and free disk space, the last
error, and, for the VM that you name, its `pomme inspect` output, the end of
its current and previous helper logs, and recent guest logs. Omit `NAME` to
use the VM from the last error. Pomme replaces your home directory with `~` and
withholds lines that mention a token, password, or secret. Review the file,
then attach it to a [new issue](https://github.com/weswhet/pomme/issues/new?template=bug_report.yml).
Pomme never uploads it for you.

:::note[Incident Report Filed]
The bug report stays on your Mac until you choose to attach it. Review it
first anyway. The System trusts the redaction. The System also trusts you to
read things, and look how that's going.
:::

## Collect Pomme's logs

Every run is recorded, Crawler. The System insists. Pomme writes to this
Mac's unified log under the subsystem `com.github.weswhet.pomme`. The log
records when each command starts and ends, with its exit code and duration,
and the progress steps, warnings, and errors that Pomme reports. Each error
record includes its error code. To watch the replay of what Pomme did before
you died, run the following command on the host:

```sh
log show --last 1h --info --debug --predicate 'subsystem == "com.github.weswhet.pomme"'
```

To narrow the output to one area, add a category to the predicate:

```sh
log show --last 1h --info --debug --predicate 'subsystem == "com.github.weswhet.pomme" AND category == "recovery"'
```

Pomme uses the following categories. Think of them as camera angles:

| Category | Records |
| --- | --- |
| `cli` | Command start and end, diagnostics, warnings, and reported errors. |
| `provisioning` | Creation, provisioning phases, and the provisioning journal. |
| `recovery` | Recovery boots and Recovery sessions. |
| `experimental-recovery` | `pomme create --experimental-recovery`. |
| `runtime` | VM start, stop, pause, resume, and boot mode. |
| `helper` | The helper processes that run each VM. |
| `security` | SIP, AMFI, owner preparation, and MDM workflows. |
| `guest-agent` | The host's connection to the guest agent. |
| `bootstrap` | Guest agent bootstrap and installation. |
| `process` | External programs that Pomme runs. |
| `ipsw` | Restore image downloads and verification. |
| `template` | Templates and clones. |
| `firmware` | `pomme firmware` and boot firmware repair. |
| `ui` | UI automation in the guest. |

macOS keeps notices and errors, and Pomme records its diagnostics and progress
steps as notices, so they're kept even when a command is interrupted. macOS
keeps info messages only for a short time and doesn't store debug messages. The
highlight reel is permanent; the bloopers aren't. For the most detail, stream
the log in another Terminal window while you reproduce the problem:

```sh
log stream --level debug --predicate 'subsystem == "com.github.weswhet.pomme"'
```

:::caution[Sponsor Notice: No Secrets on Camera]
Pomme doesn't write passwords, agent tokens, or other credentials to the
unified log. As a safeguard, it replaces the value of any field named like a
password, token, or credential with `<redacted>`, and shortens long strings of
letters and digits, such as digests, to their first eight characters. The log
does include VM names and file paths, so review it before you attach it to an
issue.
:::

The host's log doesn't include records from inside the VM. The guest agent
writes to the guest's own unified log under the same subsystem. To read it from
the host, run `pomme log NAME`. For details, see
[View guest agent logs](/crawler/guides/view-guest-logs/).

## Installing and updating Pomme

Deaths that happen before you even enter the dungeon. Impressive, honestly.

### The install script won't replace the installed executable

The install script stops with a message like the following:

```text
pomme install: /Users/USERNAME/.local/bin/pomme isn't signed like Pomme's releases. Pomme's Keychain items trust only Pomme's Developer ID signature, so the installer won't replace it. To replace it, delete it first.
```

The `pomme` executable in the install directory doesn't have Pomme's
Developer ID signature. For example, it's a Debug build. Keychain items that
such a build created stay tied to it. If you don't
need that build, delete it, and then run the install script again. To keep it,
install the release in another directory with `--install-dir`. The installer
refuses on purpose: replacing it would strand those Keychain items.

### `pomme update` reports a build from source

`pomme update` stops with the following message:

```text
Error: This pomme was built from source, so `pomme update` can't replace it. To update it, pull the newest source and run `bash Scripts/build-local.sh`.
```

Only published releases update themselves. To update a build from source, pull
the newest source and run the build script again. To switch to releases
instead, use the [install script](/crawler/get-started/install/#install-with-the-install-script).
Your homemade build is lovely, Crawler. It just doesn't do self-service.

## Selecting a VM

Deaths caused by pointing at the wrong thing, or at nothing at all.

### A command asks for a VM name

**Symptom:** A command fails with the following error:

```text
Error: Specify a VM name or set POMME_VM_NAME.
```

**Cause:** You omitted the VM name, and the `POMME_VM_NAME` environment
variable isn't set. Pomme never picks a VM for you, even if only one VM is
running. It refuses to guess. The System respects that. Guessing is how
Crawlers end up deleting the wrong box.

**Resolution:** Pass the VM name as the first argument, or set
`POMME_VM_NAME`. For details, see
[Environment variables](/crawler/reference/environment-variables/).

### Pomme can't find a VM

**Symptom:** A command fails with the following error:

```text
Error: No Pomme-owned VM named NAME exists. Create it with `pomme create NAME` or run `pomme list`.
```

**Error code:** [`vm-not-found`](/crawler/reference/errors/#vm-not-found)

**Cause:** No VM with that name exists in Pomme's storage. Pomme manages only
VMs that it created; it doesn't discover VMs that other tools created.

**Resolution:** Run `pomme list` to see the names of your VMs, and check the
spelling. Typos are the leading cause of death on this floor. The viewers
never get tired of them.

### A name is rejected

**Symptom:** Pomme reports an invalid VM, template, or snapshot name:

```text
Invalid VM name NAME. Use 1-64 ASCII letters, numbers, dots, underscores, or hyphens, starting with a letter or number.
```

**Error code:** [`invalid-request`](/crawler/reference/errors/#invalid-request)

**Resolution:** Choose a name that follows the rule in the message.

## Creating VMs

Deaths during the build phase. These are long, slow deaths, which the
sponsors adore.

### Creation stopped partway

**Symptom:** `pomme create` fails after it starts installing, and reports that
a step failed, with its reason:

```text
Error: Installing macOS failed for NAME: the disk is out of space (VZErrorDomain 8). The VM and journal were retained.
```

**Error code:** [`provisioning-phase-failed`](/crawler/reference/errors/#provisioning-phase-failed).
The result's `causes` give the underlying error, such as
[`host-disk-full`](/crawler/reference/errors/#host-disk-full).

**Cause:** Creation is a journaled workflow. When a phase fails after an
external effect, Pomme keeps the VM and its journal exactly as they were so
that you can inspect and resume them.

**Resolution:**

1. To see what happened, run the command again with `--debug`, or run
   `pomme inspect NAME`.
2. To continue from the first unfinished step, run the following command:

   ```sh
   pomme create NAME --resume
   ```

   `--resume` accepts only the VM name and the output and debug flags.

For details, see [Durable creation and journals](/crawler/concepts/durable-creation/).

:::tip[Extra Life Available]
A failed creation isn't a total loss. Pomme kept your progress, so `--resume`
picks up where you fell over. Reward for reading this far: a Bronze Patience
Box. It's empty. Patience was the reward.
:::

### Recovery navigation stops

**Symptom:** A command fails while Pomme navigates the macOS Recovery screens.
Commands that navigate Recovery include `pomme create`, `pomme agent repair`,
the SIP, AMFI, and MDM changes that need Recovery, and `pomme shell` on a VM
that runs Recovery.

**Cause:** Pomme stops navigating when a Recovery screen is unexpected or
doesn't settle. It keeps the VM and its journal so that you can inspect the
failure and resume.

**Resolution:**

1. Run the same command again with `--debug`. Before each navigation action,
   Pomme saves a full-resolution PNG screenshot, and it prints the directory
   and file names to standard error.
1. Review the screenshots to find the screen that Pomme didn't expect.
1. When you no longer need the screenshots, delete the directory that Pomme
   printed.

Each attempt saves its screenshots in its own private `pomme-recovery-debug-…`
directory in the host's temporary directory. Pomme doesn't delete them, even
after a successful run. Capture stops before Pomme types a Terminal command, so
the screenshots don't show command text or output. A failed capture prints a
warning and doesn't stop navigation.

If Recovery shows no screen at all after you installed a macOS update in the
guest, see
[A guest update hangs and the VM has less memory](#a-guest-update-hangs-and-the-vm-has-less-memory).

:::caution[Hazard Detected: Evidence Left Behind]
Full-resolution screenshots can show identifiers from the guest. Keep them out
of your source repository, and delete them when you're done. Crawlers who
commit their debug screenshots get a very public kind of fame.
:::

### There isn't enough free space to create a VM

**Symptom:** `pomme create`, `pomme create --dry-run`, or
`pomme template create` stops before it downloads or writes anything:

```text
Error: There isn't enough free space to create NAME. It needs SIZE on the volume that holds `~/Library/Application Support/pomme/VMs/NAME.bundle`: SIZE to download the restore image and about 35 GB for the installed macOS system. Only SIZE is available. Pomme didn't download or create anything.
Free at least SIZE on that volume, then retry. Run `pomme list` to find VMs that you no longer need, and delete them with `pomme delete NAME`.
Error code: host-disk-space-insufficient. For help, see https://pommevm.dev/reference/errors/#host-disk-space-insufficient
```

**Error code:** [`host-disk-space-insufficient`](/crawler/reference/errors/#host-disk-space-insufficient)

**Cause:** Before it starts, Pomme compares the free space on each volume that
creation uses, including space that macOS can reclaim, with what the creation
needs:

- The part of the restore image that isn't downloaded yet. A cached image
  needs nothing.
- About 35 GB for the installed macOS system, or the disk size if it's
  smaller.
- For a VM cloned from a template, about 5 GB for the clone's own changes, and
  the template's full size if its volume can't clone files.

For `pomme create --config`, Pomme adds up every VM in the batch.

**Resolution:** Free at least the amount that the message names, then run the
command again. To see the check without creating anything, run
`pomme create NAME --dry-run --format json` and read its `diskSpace` field.
Your inventory is full, Crawler. Drop some loot.

### The requested memory is too small

**Symptom:** `pomme create` or `pomme create --dry-run` fails with a message
like the following:

```text
The configured RAM SIZE is below the provisional guest minimum SIZE. The restore image's exact minimum is enforced once the image is present; no supported image needs less.
```

**Cause:** Every create path requires at least 4 GiB of guest memory. When the
restore image is already on the host, Pomme also enforces the image's own
minimum.

**Resolution:** Pass `--memory 4GB` or more. The dungeon has a minimum
height requirement for this ride.

### A size value is rejected

**Symptom:** Pomme rejects a disk or memory size:

```text
--disk-size requires a positive size such as 60GB, 8192MB, or a raw byte count. Got VALUE.
```

**Resolution:** Give a positive size with a unit, such as `40GB`.

### macOS installation fails on a small disk

**Symptom:** Installing macOS Tahoe fails during the restore.

**Cause:** The virtual disk is too small for the installation. A 25 GB disk
failed a Tahoe installation in testing.

**Resolution:** Create the VM or template with `--disk-size 40GB` or larger.
VMs cloned from a template inherit the template's disk size, so a cramped
template makes cramped clones forever. Choose generously.

### Pomme warns that a macOS version is experimental

**Symptom:** Creation prints a warning like one of the following:

```text
Warning: Recovery support for macOS VERSION (BUILD) is experimental. Creation will attempt the observed-screen navigation and stop if it does not match.
```

```text
Warning: macOS VERSION (BUILD) has not been qualified for Recovery automation; creation will attempt it with observed-screen checks.
```

**Cause:** The restore image's version and build aren't in Pomme's reviewed
Recovery profile list. Pomme still attempts creation, with all of its
identity, locale, display, and ownership checks.

**Resolution:** No action is needed. This isn't a death, Crawler, just a
warning sign with a skull on it. If Recovery shows a screen that Pomme
doesn't expect, navigation stops and Pomme keeps the VM and journal. For
details, see [Supported macOS versions](/crawler/concepts/os-qualification/).

A VM cloned from a provisioned template that kept its agent credential doesn't
boot Recovery, so its creation doesn't print the first warning.

### A provisioned template's clone installs its agent through Recovery

**Symptom:** `pomme template create --provisioned` or `pomme create` prints a
warning like one of the following:

```text
Warning: Pomme couldn't keep the provisioning VM's agent credential for this template, so VMs cloned from it will install the Pomme agent through Recovery: REASON.
```

```text
Warning: The template's agent credential is no longer in your login Keychain, so Pomme installs the agent through Recovery.
```

**Cause:** A VM cloned from a provisioned template gets its agent in normal
macOS only when Pomme kept the template's agent credential in your login
Keychain. Pomme couldn't keep it when it created the template, or the item no
longer exists, for example because you deleted the template. The shortcut key
is gone, so it's the long way round.

**Resolution:** `pomme create` continues through Recovery, as it did before
Pomme kept the credential, so you don't need to do anything. To create clones
without Recovery again, unlock your login Keychain. Then create the template
again with `pomme template create --provisioned`.

### A config file is rejected

**Symptom:** `pomme create --config` or `pomme config validate` fails with an
unsupported key:

```text
Unsupported create-config key 'KEY'. Regenerate the config with `pomme config init`.
```

**Cause:** The config uses a key from an older schema, such as `restore`,
`replaceExisting`, or `failureCleanup`.

**Resolution:** Generate a new starter file with `pomme config init` and copy
your values into it. For the current schema, see
[Creation config file](/crawler/reference/config-file/).

Create configs also can't contain credentials, security workflow controls, or
MDM enrollment. Pomme rejects these sections with one of the following
messages:

```text
Create configs cannot contain credentials. Use the explicit Pomme security operation.
Create configs cannot contain workflow controls. Use --boot for the final state.
Create configs cannot contain MDM enrollment. Use the explicit Pomme MDM operation.
```

Remove the section, and run the matching command after creation. Secrets
and security changes don't go in the config file. The System is firm on this.

### A Pkl config fails to load

**Symptom:** A `.pkl` config fails with the following error:

```text
Pkl configs require the pkl executable in PATH.
```

**Resolution:** Install the Pkl command-line tool and make sure that `pkl` is
on your `PATH`, or use a JSON, YAML, or TOML config instead.

### A third VM doesn't start

**Symptom:** Starting or creating another macOS VM fails while two others are
running.

**Cause:** Virtualization.framework runs at most two macOS guests at the same
time. For the same reason, `pomme create --config --parallel` creates at most
two VMs at once.

**Resolution:** Stop or pause one of the running VMs, then try again. Two
macOS guests at once is the limit. The System didn't make this rule, but it
enjoys watching Crawlers discover it.

## Starting and stopping VMs

Deaths at the door. Some going in, some coming out.

### `pomme stop` reports a forced stop

**Symptom:** `pomme stop` prints the following:

```text
OK stopped (forced; the guest did not shut itself down)
```

**Cause:** Pomme asked the guest to shut down, but the guest didn't finish
within the time limit, so Pomme powered the VM off. A stop that isn't clean is
always reported.

**Resolution:** If this happens repeatedly, check whether a program in the
guest blocks shutdown. To power off immediately on purpose, use
`pomme stop NAME --force`. For details, see
[Manage the VM lifecycle](/crawler/guides/manage-vm-lifecycle/).

### The VM helper doesn't start

**Symptom:** Starting a VM fails with one of the following errors:

```text
The VM helper exited during startup with status STATUS. See LOG_PATH.
Timed out waiting for VM helper pid PID to open its control socket. See LOG_PATH.
```

**Error code:** [`helper-start-failed`](/crawler/reference/errors/#helper-start-failed)
or [`helper-start-timed-out`](/crawler/reference/errors/#helper-start-timed-out)

**Resolution:** Read the log file that the message names. It contains the
helper's own error. When a helper starts, Pomme keeps the previous helper's
log as `pomme-helper.previous.log` in the same directory. To collect both logs
for a bug report, run `pomme bug-report NAME`.

### `pomme start` refuses a VM in the other boot mode

**Symptom:** `pomme start` fails with an error like the following:

```text
Error: NAME is already paused in recovery boot mode. Stop it before starting normal boot mode.
```

**Error code:** [`vm-paused-other-mode`](/crawler/reference/errors/#vm-paused-other-mode)
or [`vm-running-other-mode`](/crawler/reference/errors/#vm-running-other-mode)

**Cause:** The VM is running or paused in the other boot mode. `pomme start`
resumes a paused VM only in the boot mode that it was paused in.

**Resolution:** Run `pomme stop NAME`, then start the VM in the boot mode that
you want.

### `pomme delete` keeps the VM

**Symptom:** `pomme delete NAME --force` fails with the following error, and
the VM still exists:

```text
Refusing VM deletion because its helper did not exit after stopping.
```

**Cause:** Pomme deletes a VM only after it confirms that the VM stopped and
its helper process exited. If Pomme can't confirm either, it keeps the VM. It
won't delete something that might still be alive. The viewers find this
deeply disappointing.

**Resolution:** Run `pomme status NAME`, wait for the VM to stop, and then run
the delete command again.

### `pomme delete` says the VM doesn't match its records

**Symptom:** `pomme delete NAME` fails with the following error, and the VM
still exists:

```text
Error: The VM isn't the exact Pomme-owned VM that its provisioning journal names. It might have been moved, copied, or replaced.
```

**Cause:** Pomme removes a VM's Keychain items only when the VM's provisioning
records prove which VM the bundle is. These records don't match the bundle.
Pomme won't guess whose secrets those are.

**Resolution:** `pomme delete NAME --force` removes the bundle and keeps the
VM's Keychain items, which you can remove in Keychain Access. If you moved
the bundle, move it back instead.

### A command needs a terminal

**Symptom:** A command fails in a script or CI job with one of the following
errors:

```text
Deletion requires an interactive terminal. Pass -f/--force to delete without prompting.
Repair requires an interactive terminal. Pass -f/--force to repair without prompting.
tui requires an interactive terminal.
--pty requires an interactive terminal for standard input and output.
An attached shell requires an interactive terminal for standard input and output.
```

**Resolution:** For deletion and `pomme firmware repair`, add `--force`. For
terminal programs, create a
detached session with `pomme exec --pty --detach` or `pomme shell --detach`
instead. For details, see
[Use Pomme in scripts and coding agents](/crawler/guides/script-pomme/).

## Updating macOS in a VM

Deaths caused by a software update, which is the System's favorite kind of
irony.

### A guest update hangs and the VM has less memory

**Symptom:** You install a macOS update in a VM that runs macOS 26 or earlier,
such as macOS 26.7 or 15.8, and one or more of the following happens:

- The guest restarts to install the update and then never shows its desktop
  again. After you stop and start the VM, it still runs the earlier macOS
  version.
- The guest has about 1.75 GB of usable memory, whatever memory size the VM
  has.
- Recovery doesn't start, so a command that uses Recovery, such as
  `pomme sip disable`, fails.

Before each Recovery boot of such a VM, Pomme prints this warning. The System
also prints it, mostly so that it can say it warned you:

```text
NAME has boot firmware mBoot-20457.1.29 from a guest update. If the VM runs macOS 26 or earlier, Recovery can't start with it. Stop the VM and run `pomme firmware repair NAME`. See https://pommevm.dev/resources/troubleshooting/#a-guest-update-hangs-and-the-vm-has-less-memory
```

**Cause:** The update installs the macOS 27 boot firmware in the VM's
auxiliary storage. Under that firmware, macOS 26 and earlier can use only
about 1.75 GB of memory, the first boot of the updated system doesn't finish,
and Recovery, which runs from memory, doesn't start. The problem is in the
macOS update, not in Pomme: other apps that run macOS VMs with
Virtualization.framework report the same behavior. For once, the trap wasn't
built by the System, and it's a little jealous.

**Resolution:**

1. If the VM stopped responding after the update restarted it, turn it off:

   ```sh
   pomme stop NAME --force
   ```

1. Start the VM in normal macOS. It starts the macOS version that it ran
   before the update.

   ```sh
   pomme start NAME
   ```

1. Check the VM's boot firmware:

   ```sh
   pomme firmware inspect NAME
   ```

   For an affected VM, the output looks like the following:

   ```text
   status: incompatible-update
   active: mBoot-20457.1.29 (slot B)
   previous: mBoot-18000.161.10 (slot A)
   guest: macOS 26.6.2, 1.75 GB of 4 GB memory usable
   diagnosis: affected
   This firmware leaves the guest about 1.75 GB of memory, so a macOS update can't finish and Recovery can't start. Stop the VM with `pomme stop NAME`, then run `pomme firmware repair NAME`. See https://pommevm.dev/resources/troubleshooting/#a-guest-update-hangs-and-the-vm-has-less-memory
   ```

   If the diagnosis is `not-affected`, the VM doesn't have this problem, and
   the viewers go back to their snacks.

1. If the diagnosis is `affected`, stop the VM and restore the firmware that
   the VM was installed with. Pomme asks you to confirm; to skip the
   question, add `--force`.

   ```sh
   pomme stop NAME
   pomme firmware repair NAME
   ```

1. Start the VM. It has all of its memory, and Recovery starts again. To
   install the macOS update, run Software Update in the guest again.

Replace `NAME` with the name of the VM.

`pomme firmware repair` changes only the active firmware slot of the
`AuxiliaryStorage` file in the VM bundle. First, it saves a copy of the whole
file in the bundle's `FirmwareBackups` folder. To undo the repair, stop the VM
and copy that backup over `AuxiliaryStorage`. When the VM's firmware doesn't
need a repair, the command changes nothing. `pomme inspect` also reports the
VM's boot firmware, and it suggests `pomme firmware inspect` when the firmware
looks affected.

:::caution[Hazard Detected: Wrong Patient]
Don't repair a VM that you upgraded to macOS 27 in the guest: macOS 27 needs
the firmware that the upgrade installed. While such a VM runs,
`pomme firmware inspect` reports `not-affected`. Crawlers who "repair" a
healthy macOS 27 VM get to learn about backups the hard way.
:::

## Guest agent

Deaths involving the little helper inside the box, which is usually innocent.

### The guest agent isn't connected

**Symptom:** A guest command fails with the following error:

```text
PommeAgent is not connected on port 505051. A guest that is still booting connects on its own; `pomme status` reports when it does.
```

**Error code:** [`guest-agent-unavailable`](/crawler/reference/errors/#guest-agent-unavailable)

**Cause:** The VM is still booting, the VM is in Recovery, or the agent isn't
running in the guest.

**Resolution:**

1. Wait for the guest to finish booting, and then run `pomme status NAME`.
2. If the agent still doesn't connect, run `pomme agent status NAME`.
3. If the agent is missing or broken, run `pomme agent repair NAME`.

For details, see [Check, update, and repair the guest agent](/crawler/guides/repair-the-agent/).
Most of the time, step 1 fixes it. Waiting is a valid strategy, Crawler. It's
just bad television.

### A guest command doesn't exist

**Symptom:** `pomme exec` fails with an error like the following:

```text
Error: The command doesn't exist in the guest. No such executable: /usr/local/bin/tool.
```

**Error code:** [`guest-command-not-found`](/crawler/reference/errors/#guest-command-not-found)

**Cause:** No executable exists at that path in the guest.

**Resolution:** Give the full path of an executable that exists in the guest.
To check a path, run `pomme exec NAME -- /bin/ls -l PATH`.

### The agent update doesn't finish

**Symptom:** `pomme agent update` fails with one of the following errors:

```text
The guest could not install the new Pomme agent; the previous agent is still installed. Update mode exited with status STATUS.
The updated Pomme agent in NAME did not connect with digest DIGEST (observed OBSERVED). It is installed and takes effect on the next restart: `pomme restart NAME`, then rerun `pomme agent update NAME`.
```

**Cause:** In the first case, the guest rejected or couldn't install the new
executable, and the previous agent keeps running unchanged. In the second
case, the new agent is installed but didn't reconnect before the command
stopped waiting.

**Resolution:**

- If the previous agent is still installed, run `pomme agent update NAME`
  again. If it fails again, check the agent with `pomme agent status NAME`.
- If the new agent is installed but didn't connect, run
  `pomme restart NAME`, and then run `pomme agent update NAME` again. The
  second run records the new agent without copying it again.

### The agent update reports running jobs or sessions

**Symptom:** `pomme agent update` fails with the following error, followed by
one line for each running job or session:

```text
NAME has running background jobs or terminal sessions that the restarted agent could no longer manage. Let them finish or stop them, then rerun `pomme agent update NAME`.
```

**Cause:** The update restarts the guest agent, and the restarted agent can't
manage the jobs and sessions that the old agent started.

**Resolution:** Let the listed jobs and sessions finish, or run the command
shown next to each one to stop it. Then run `pomme agent update NAME` again.

### The agent update reports a retained operation

**Symptom:** `pomme agent update` fails with one of the following errors:

```text
NAME has a retained security operation pinned to its current agent. Finish it before updating the agent.
NAME has a retained MDM enrollment operation pinned to its current agent. Finish it before updating the agent.
```

**Cause:** An unfinished SIP, AMFI, or MDM operation is pinned to the agent
that was running when it started. Pomme doesn't replace that agent until the
operation finishes.

**Resolution:** Finish the operation by repeating its original command, and
then run `pomme agent update NAME`.

### The login Keychain is locked

**Symptom:** A command fails with one of the following errors:

```text
Your login Keychain is locked, so Pomme can't use the VM's agent credential: REASON (OSStatus STATUS).
Your login Keychain is locked: REASON (OSStatus STATUS).
```

**Error code:** [`keychain-error`](/crawler/reference/errors/#keychain-error)

**Cause:** Pomme keeps the guest agent credential and owner credentials in your
login Keychain, and it never unlocks the Keychain for you.

**Resolution:** Unlock your login Keychain, for example by signing in to the
host's desktop session, and run the command again.

:::note[System Notice: The System Will Not Pick Locks]
Pomme never unlocks your Keychain and never asks for your host password. That
part is up to you. The System could probably find a way around it, but it's
contractually forbidden, and frankly, so are you.
:::

## Security workflows

Deaths in the SIP, AMFI, and owner-credential wing. Tread carefully: this is
the part of the dungeon where the guardrails are real.

### A security command asks for owner credentials

**Symptom:** A SIP, AMFI, or MDM command fails with the following error:

```text
Owner credentials are required. Set both POMME_AUTHORIZED_USER and POMME_AUTHORIZED_PASSWORD, restore the exact VM-scoped Keychain item, or run from an interactive terminal.
```

**Resolution:** Provide the owner's credentials. For details, see
[Change SIP and AMFI](/crawler/guides/change-sip-and-amfi/#provide-owner-authorization).

### Another security operation owns the VM

**Symptom:** A SIP or AMFI command fails with one of the following errors:

```text
Another unfinished Pomme security operation owns this VM.
An earlier SIP or AMFI operation on this VM is unfinished. Repeat its original command before you start another operation.
```

**Error code:** [`security-operation-pending`](/crawler/reference/errors/#security-operation-pending)

**Cause:** An earlier SIP or AMFI operation on this VM didn't finish. Pomme
keeps its journal and won't start a different operation until it finishes.

**Resolution:** Repeat the original command, with the same action and the same
`--final-state`, to resume it. Then run the new command.

### Restoration is incomplete

**Symptom:** A security command fails with the following error:

```text
VM state restoration is incomplete. The account, credentials, and security journal were retained; repeat the same command after inspecting the VM.
```

**Error code:** [`security-restoration-incomplete`](/crawler/reference/errors/#security-restoration-incomplete)

**Cause:** Pomme couldn't prove that cleanup finished, so it didn't boot or
restore the VM.

**Resolution:** Run `pomme status NAME` and `pomme inspect NAME` to understand
the VM's state, and then repeat the same command.

### AMFI requires SIP to be off

**Symptom:** An AMFI command fails with the following error:

```text
Changing AMFI requires SIP to be off while Pomme writes and verifies boot arguments. Run `pomme sip disable NAME` first, and restore AMFI before you turn SIP on again.
```

**Error code:** [`amfi-requires-sip-disabled`](/crawler/reference/errors/#amfi-requires-sip-disabled)

**Resolution:** Run `pomme sip disable NAME` before `pomme amfi disable NAME`.
To restore, run `pomme amfi enable NAME` before `pomme sip enable NAME`.

:::caution[Death Notice: Wrong Door Order]
Crawlers who turn SIP back on before they restore AMFI get this error and a
very confused audience. Order matters in both directions: SIP off first, AMFI
restored first.
:::

### A terminal session blocks a security workflow

**Symptom:** A SIP or AMFI command fails with the following error:

```text
Recovery security workflows are unavailable while a terminal session is active. Terminate it first.
```

**Error code:** [`vm-state-invalid`](/crawler/reference/errors/#vm-state-invalid)

**Resolution:** List the sessions with `pomme sessions list NAME`, end each
active one with `pomme sessions terminate NAME --session SESSION_ID`, and run the
command again. For details, see
[Use durable terminal sessions](/crawler/guides/use-terminal-sessions/).

## MDM enrollment

Deaths by paperwork. The slowest, most bureaucratic deaths in the dungeon.

### The host can't validate the MDM server

**Symptom:** `pomme mdm` stops before it changes the VM:

```text
Neither Apple's roots nor the profile's certificates validate the MDM server. Fix the profile, or pass --skip-server-preflight if the guest already trusts it.
```

**Cause:** The host reached the MDM server, but neither Apple's root
certificates nor the certificate payloads in the profile validate the server's
certificate.

**Resolution:** Add the server's CA certificate to the profile as a certificate
payload. If the guest already trusts the server, add `--skip-server-preflight`.
Only skip the check when the guest really does trust the server. The check
runs before Pomme changes the VM, which is the cheapest possible place to die.

### An enrollment request conflicts with retained work

**Symptom:** `pomme mdm` fails with the following error:

```text
An unfinished MDM enrollment uses a different profile, --enrollment-mode, or --final-security. Repeat it with its original values.
```

**Resolution:** Repeat the earlier command with its original profile,
`--enrollment-mode`, and `--final-security` values to finish it.

### macOS 27 enrolls but never receives push commands

**Symptom:** `pomme mdm` succeeds on a macOS 27 VM, but the MDM server never
receives `TokenUpdate`, and commands that it pushes never arrive. The result's
`pushIdentity` field isn't `prepared`.

**Cause:** macOS 27 skips its `keystore-init` boot task when it starts from a VM
disk, so the guest can't create the identity that Apple's push service needs.
The Pomme agent runs the task itself, but only while SIP is off.
The System confirms that "enrolled" and "reachable" are different words. It
checked.

**Resolution:** `pushIdentity` in the `pomme mdm` result shows what to do:

- If it's `skipped`, SIP is on. Turn it off with `pomme sip disable VM_NAME`.
- If it's `agentUpdateRequired`, update the agent with
  `pomme agent update VM_NAME`.
- If it's `pending`, `failed`, or `unavailable`, restart the VM with
  `pomme restart VM_NAME`, and then repeat the `pomme mdm` command. It reports
  the agent's status again without reinstalling the profile.

For details, see
[Receive push commands on macOS 27](/crawler/guides/enroll-in-mdm/#receive-push-commands-on-macos-27).

### Enrollment mode can't be downgraded

**Symptom:** `pomme mdm` fails with the following error:

```text
Unapproved mode cannot downgrade an approved or supervised enrollment.
```

**Resolution:** Keep the default `supervised` mode, or create a new VM for an
unapproved enrollment.

For more MDM behavior, see [Enroll a VM in MDM](/crawler/guides/enroll-in-mdm/).

## Remote access

Deaths while trying to peek into the box from outside.

### Screen Sharing is unavailable

**Symptom:** A `pomme screen-sharing` command fails with the following error:

```text
Screen Sharing is unavailable through Pomme because this guest agent does not support it. Configure it in the guest’s Sharing settings instead.
```

**Cause:** The guest agent doesn't advertise the `ui.screenSharing`
capability.

**Resolution:** Turn on Screen Sharing in the guest's System Settings. For
details, see
[Turn on Remote Login and Screen Sharing](/crawler/guides/enable-remote-access/).

:::tip[New Achievement! Professional Survivor]
You read the entire death catalog, Crawler. You now know more ways to fail
than most Crawlers discover in a season. Reward: a Silver Hindsight Box. It
contains this page, printed out.
:::

## Next floor

- [Errors](/crawler/reference/errors/)
- [Exit codes](/crawler/reference/exit-codes/)
- [Command-line reference](/crawler/reference/cli/)
- [Glossary](/crawler/resources/glossary/)
