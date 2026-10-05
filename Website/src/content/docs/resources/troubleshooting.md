---
title: Troubleshooting
description: Symptoms, causes, and fixes for common problems when you create, run, and change Pomme VMs.
---

This page lists common problems with Pomme, what causes them, and how to fix
them. Error messages appear exactly as Pomme prints them. Uppercase words such
as `NAME` and `SIZE` stand for values that differ on your system.

Before you troubleshoot, make sure that you're running the build you expect:

```sh
pomme --version
```

For more detail about any failing command, run it again with `--debug`.

## Selecting a VM

### A command asks for a VM name

**Symptom:** A command fails with the following error:

```text
Error: Specify a VM name or set POMME_VM_NAME.
```

**Cause:** You omitted the VM name, and the `POMME_VM_NAME` environment
variable isn't set. Pomme never picks a VM for you, even if only one VM is
running.

**Resolution:** Pass the VM name as the first argument, or set
`POMME_VM_NAME`. For details, see
[Environment variables](/reference/environment-variables/).

### Pomme can't find a VM

**Symptom:** A command fails with the following error:

```text
Error: No Pomme-owned VM named NAME exists. Create it with `pomme create NAME` or run `pomme list`.
```

**Cause:** No VM with that name exists in Pomme's storage. Pomme manages only
VMs that it created; it doesn't discover VMs that other tools created.

**Resolution:** Run `pomme list` to see the names of your VMs, and check the
spelling.

### A name is rejected

**Symptom:** Pomme reports an invalid VM, template, or snapshot name:

```text
Invalid VM name NAME. Use 1-64 ASCII letters, numbers, dots, underscores, or hyphens, starting with a letter or number.
```

**Resolution:** Choose a name that follows the rule in the message.

## Creating VMs

### Creation stopped partway

**Symptom:** `pomme create` fails after it starts installing, and reports that
a phase failed:

```text
NAME provisioning phase PHASE failed; the VM and journal were retained.
```

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

For details, see [Durable creation and journals](/concepts/durable-creation/).

### The requested memory is too small

**Symptom:** `pomme create` or `pomme create --dry-run` fails with a message
like the following:

```text
The configured RAM SIZE is below the provisional guest minimum SIZE. The restore image's exact minimum is enforced once the image is present; no supported image needs less.
```

**Cause:** Every create path requires at least 4 GiB of guest memory. When the
restore image is already on the host, Pomme also enforces the image's own
minimum.

**Resolution:** Pass `--memory 4GB` or more.

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
VMs cloned from a template inherit the template's disk size.

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

**Resolution:** No action is needed. If Recovery shows a screen that Pomme
doesn't expect, navigation stops and Pomme keeps the VM and journal. For
details, see [Supported macOS versions](/concepts/os-qualification/).

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
[Creation config file](/reference/config-file/).

Create configs also can't contain credentials, security workflow controls, or
MDM enrollment. Pomme rejects these sections with one of the following
messages:

```text
Create configs cannot contain credentials. Use the explicit Pomme security operation.
Create configs cannot contain workflow controls. Use --boot for the final state.
Create configs cannot contain MDM enrollment. Use the explicit Pomme MDM operation.
```

Remove the section, and run the matching command after creation.

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

**Resolution:** Stop or pause one of the running VMs, then try again.

## Starting and stopping VMs

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
[Manage the VM lifecycle](/guides/manage-vm-lifecycle/).

### The VM helper doesn't start

**Symptom:** Starting a VM fails with one of the following errors:

```text
The VM helper exited during startup with status STATUS. See LOG_PATH.
Timed out waiting for VM helper pid PID to open its control socket. See LOG_PATH.
```

**Resolution:** Read the log file that the message names. It contains the
helper's own error.

### `pomme delete` keeps the VM

**Symptom:** `pomme delete NAME --force` fails with the following error, and
the VM still exists:

```text
Refusing VM deletion because its helper did not exit after stopping.
```

**Cause:** Pomme deletes a VM only after it confirms that the VM stopped and
its helper process exited. If Pomme can't confirm either, it keeps the VM.

**Resolution:** Run `pomme status NAME`, wait for the VM to stop, and then run
the delete command again.

### A command needs a terminal

**Symptom:** A command fails in a script or CI job with one of the following
errors:

```text
Deletion requires an interactive terminal. Pass -f/--force to delete without prompting.
tui requires an interactive terminal.
--pty requires an interactive terminal for standard input and output.
```

**Resolution:** For deletion, add `--force`. For terminal programs, create a
detached session with `pomme exec --pty --detach` instead. For details, see
[Use Pomme in scripts and coding agents](/guides/script-pomme/).

## Guest agent

### The guest agent isn't connected

**Symptom:** A guest command fails with the following error:

```text
PommeAgent is not connected on port 505051. A guest that is still booting connects on its own; `pomme status` reports when it does.
```

**Cause:** The VM is still booting, the VM is in Recovery, or the agent isn't
running in the guest.

**Resolution:**

1. Wait for the guest to finish booting, and then run `pomme status NAME`.
2. If the agent still doesn't connect, run `pomme agent status NAME`.
3. If the agent is missing or broken, run `pomme agent repair NAME`.

For details, see [Check, update, and repair the guest agent](/guides/repair-the-agent/).

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
Pomme agent credential Keychain is locked (Security status STATUS).
Pomme owner credential Keychain is locked.
```

**Cause:** Pomme keeps the guest agent credential and owner credentials in your
login Keychain, and it never unlocks the Keychain for you.

**Resolution:** Unlock your login Keychain, for example by signing in to the
host's desktop session, and run the command again.

## Security workflows

### A security command asks for owner credentials

**Symptom:** A SIP, AMFI, or MDM command fails with the following error:

```text
Owner credentials are required. Set both POMME_AUTHORIZED_USER and POMME_AUTHORIZED_PASSWORD, restore the exact VM-scoped Keychain item, or run from an interactive terminal.
```

**Resolution:** Provide the owner's credentials. For details, see
[Change SIP and AMFI](/guides/change-sip-and-amfi/#provide-owner-authorization).

### Another security operation owns the VM

**Symptom:** A SIP or AMFI command fails with one of the following errors:

```text
Another unfinished Pomme security operation owns this VM.
A security transaction remains unresolved; repeat its original command before starting another operation.
```

**Cause:** An earlier SIP or AMFI operation on this VM didn't finish. Pomme
keeps its journal and won't start a different operation until it finishes.

**Resolution:** Repeat the original command, with the same action and the same
`--final-state`, to resume it. Then run the new command.

### Restoration is incomplete

**Symptom:** A security command fails with the following error:

```text
VM state restoration is incomplete. The account, credentials, and security journal were retained; repeat the same command after inspecting the VM.
```

**Cause:** Pomme couldn't prove that cleanup finished, so it didn't boot or
restore the VM.

**Resolution:** Run `pomme status NAME` and `pomme inspect NAME` to understand
the VM's state, and then repeat the same command.

### AMFI requires SIP to be off

**Symptom:** An AMFI command fails with the following error:

```text
AMFI changes require SIP disabled while boot arguments are written and verified. Run pomme sip disable <vm> first; restore AMFI before re-enabling SIP.
```

**Resolution:** Run `pomme sip disable NAME` before `pomme amfi disable NAME`.
To restore, run `pomme amfi enable NAME` before `pomme sip enable NAME`.

### A terminal session blocks a security workflow

**Symptom:** A SIP or AMFI command fails with the following error:

```text
Recovery security workflows are unavailable while a terminal session is active. Terminate it first.
```

**Resolution:** List the sessions with `pomme sessions list NAME`, end each
active one with `pomme sessions terminate NAME --session SESSION_ID`, and run the
command again. For details, see
[Use durable terminal sessions](/guides/use-terminal-sessions/).

## MDM enrollment

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

### An enrollment request conflicts with retained work

**Symptom:** `pomme mdm` fails with the following error:

```text
An unfinished MDM enrollment uses a different profile, --enrollment-mode, or --final-security. Repeat it with its original values.
```

**Resolution:** Repeat the earlier command with its original profile,
`--enrollment-mode`, and `--final-security` values to finish it.

### Enrollment mode can't be downgraded

**Symptom:** `pomme mdm` fails with the following error:

```text
Unapproved mode cannot downgrade an approved or supervised enrollment.
```

**Resolution:** Keep the default `supervised` mode, or create a new VM for an
unapproved enrollment.

For more MDM behavior, see [Enroll a VM in MDM](/guides/enroll-in-mdm/).

## Remote access

### Screen Sharing is unavailable

**Symptom:** A `pomme screen-sharing` command fails with the following error:

```text
Screen Sharing is unavailable through Pomme because this guest agent does not support it. Configure it in the guest’s Sharing settings instead.
```

**Cause:** The guest agent doesn't advertise the `ui.screenSharing`
capability.

**Resolution:** Turn on Screen Sharing in the guest's System Settings. For
details, see
[Turn on Remote Login and Screen Sharing](/guides/enable-remote-access/).

## What's next

- [Exit codes](/reference/exit-codes/)
- [Command-line reference](/reference/cli/)
- [Glossary](/resources/glossary/)
