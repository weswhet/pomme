---
title: Enroll a VM in MDM
description: Use one resumable command to take a Pomme VM from any state to a verified MDM enrollment.
---

This guide shows you how to enroll a Pomme VM in a mobile device management
(MDM) server with an enrollment profile. The `pomme mdm` command works from any
VM state: it creates the VM if it doesn't exist, finishes any incomplete work,
prepares only the security changes that enrollment needs, enrolls, and then
restores the VM.

`pomme mdm` uses Pomme's profile-based enrollment flow. It doesn't implement
Apple User Enrollment or Automated Device Enrollment.

## Before you begin

- Get an MDM enrollment profile (a `.mobileconfig` file) from your MDM server
  and save it on the host.
- If the VM doesn't exist yet, decide how to create it. Creating from a
  template avoids restoring macOS again. For details, see
  [Use templates](/guides/use-templates/).
- End any active terminal sessions in the VM. Recovery security
  workflows don't start while a terminal session is active.
- If the VM has an owner account, make its credentials available. For details,
  see [Provide owner authorization](/guides/change-sip-and-amfi/#provide-owner-authorization).

## Preview the enrollment plan

Before you change anything, see what Pomme would do:

```sh
pomme mdm VM_NAME --profile PROFILE_PATH --dry-run
```

Replace the following:

- `VM_NAME`: the name of the VM to enroll.
- `PROFILE_PATH`: the host path to the enrollment profile.

The dry run reports the detected VM state, the planned steps, and any blockers
or warnings, without changing the VM.

## Enroll a VM

To enroll a VM, run the following command:

```sh
pomme mdm VM_NAME --profile PROFILE_PATH
```

Replace the following:

- `VM_NAME`: the name of the VM to enroll.
- `PROFILE_PATH`: the host path to the enrollment profile.

Pomme works out what's missing from the VM's retained state and runs only
those steps, in order, under one exclusive lease on the VM:

1. Creates the VM if it doesn't exist.
2. Resumes an incomplete creation, which installs and verifies the guest
   agent.
3. Finishes a retained `pomme sip` or `pomme amfi` operation, using that
   operation's own action and final state.
4. Enrolls the VM: boots normal macOS, verifies the pinned guest agent, reads
   the System Integrity Protection (SIP) and Apple Mobile File Integrity (AMFI)
   settings, turns off only what enrollment needs, installs
   the profile, and verifies the result.

By default, Pomme then restores the original SIP and AMFI settings and the VM's
original run state.

If the VM has no owner account, the SIP step creates the `pomme` owner. Pomme
asks you to confirm first; to confirm without a prompt, add `--force`.

## Create the VM as part of enrollment

If the VM doesn't exist, add creation flags to the `pomme mdm` command. Pomme
ignores these flags when the VM already exists and reports a
`creationOptionsIgnored` warning.

For example, to clone a new VM from a template and enroll it in one command,
run the following:

```sh
pomme mdm VM_NAME --profile PROFILE_PATH \
  --from-template TEMPLATE_NAME --memory 4GB --force
```

Replace the following:

- `VM_NAME`: the name of the VM to create and enroll.
- `PROFILE_PATH`: the host path to the enrollment profile.
- `TEMPLATE_NAME`: the name of an installed template.

You can use one of the following sources to create the VM:

- `--from-template TEMPLATE_NAME`: clone an installed template. The template
  supplies the disk size.
- `--version VERSION` or `--latest`: install a macOS version or build.
- `--restore-image PATH`: install from a local IPSW file.

You can also set `--memory` (default `8GB`), `--disk-size` (default `60GB`),
and `--boot`, which accepts `normal` (the default) or `none`.

:::note
To enroll without any security changes, clone from a template that you created with
`pomme template create ... --provisioned`. Its clones already have an owner
account, SIP turned off, and the AMFI override on, so enrollment is their first
step and needs no security change. For details, see
[Use templates](/guides/use-templates/).
:::

## Choose the enrollment mode

Pomme supports the following enrollment modes:

| Mode | Result |
| --- | --- |
| `supervised` | Supervised, user-approved enrollment. This is the default. |
| `unapproved` | Enrollment without user approval or supervision. |

To request enrollment without approval, add `--enrollment-mode unapproved`:

```sh
pomme mdm VM_NAME --profile PROFILE_PATH --enrollment-mode unapproved
```

To upgrade an existing unapproved enrollment to supervised, run `pomme mdm`
again with the same profile and the default mode. Pomme reuses a matching
enrollment and avoids security changes when the request is already satisfied.

Pomme rejects the following requests:

- A profile or server that conflicts with the installed enrollment.
- A downgrade from an approved or supervised enrollment to `unapproved`.

## Keep SIP and AMFI off after enrollment

By default (`--final-security restore`), Pomme turns SIP and AMFI back on if
enrollment turned them off. To leave the settings that enrollment turned off
switched off, add `--final-security disabled`:

```sh
pomme mdm VM_NAME --profile PROFILE_PATH --final-security disabled
```

Settings that enrollment didn't change stay as they were. To turn the settings
back on later, restore AMFI first and then SIP:

```sh
pomme amfi enable VM_NAME
pomme sip enable VM_NAME
```

## Understand the server trust check

Before Pomme touches the VM, the host checks the MDM server named in the
profile:

- If the host reaches the server and neither Apple's root certificates nor the
  certificate payloads in the profile validate it, a command that could still
  install the profile stops with the following error:

  ```text
  Neither Apple's roots nor the profile's certificates validate the MDM server. Fix the profile, or pass --skip-server-preflight if the guest already trusts it.
  ```

  If the guest already trusts the server, add `--skip-server-preflight` to
  skip this host check.
- If the host can't reach the server, Pomme only warns. The guest checks the
  server again before it enrolls.

If only the certificates in the profile validate the server, Pomme first
installs those certificates as a separate configuration profile with the
identifier `com.github.weswhet.pomme.mdm-trust.PROFILE_UUID`, where
`PROFILE_UUID` is the UUID of your enrollment profile. This lets a server with
a private certificate authority work without manual trust setup.

The trust profile stays installed after enrollment. To remove it when you no
longer need it, run the following command in the guest:

```sh
pomme exec VM_NAME -- /usr/bin/profiles remove \
  -identifier com.github.weswhet.pomme.mdm-trust.PROFILE_UUID
```

Replace the following:

- `VM_NAME`: the name of the VM.
- `PROFILE_UUID`: the UUID of the enrollment profile.

## Set the guest staging path

Pomme copies the profile into the guest before it installs it. To choose the
temporary guest location, add `--guest-path` with an absolute guest path:

```sh
pomme mdm VM_NAME --profile PROFILE_PATH --guest-path GUEST_PATH
```

Replace `GUEST_PATH` with an absolute path in the guest.

## Resume after a failure

Each step keeps its own journal. If a step fails, Pomme exits with a nonzero
status and keeps the current SIP and AMFI settings, the VM's run state, the
staged files, and the journals. It doesn't poll for enrollment or clean up
automatically.

To resume, repeat the same command with the same profile, `--enrollment-mode`,
and `--final-security` values. If you change any of them while an enrollment is
unfinished, Pomme stops with the following error:

```text
An unfinished MDM enrollment uses a different profile, --enrollment-mode, or --final-security. Repeat it with its original values.
```

After you rebuild and install Pomme, you can repeat the same command to inspect
and continue retained work. Each enrollment attempt stages its helper from the
current host command-line tool, so a fix to guest enrollment doesn't require replacing the
persistent guest agent.

Some states can't be resumed safely. In these cases, Pomme stops before any
change and names the blocker. The following are examples:

- First-boot provisioning was dispatched without a receipt. Recreate the VM.
- The VM's pinned guest agent lacks the capabilities that MDM requires.
  Recreate the VM with a current Pomme build.
- An enrollment outcome is unknown. Pomme doesn't repeat the installation
  without evidence.

## Read structured output

With `--format json`, the result includes the following fields:

| Field | Description |
| --- | --- |
| `steps` | Each step that ran, with its status. |
| `result.readiness` | The detected state, the planned steps, blockers, and warnings. |
| `result.serverTrust` | The result of the MDM server trust check. |
| `result.failureStage` | The guest stage that failed, when the enrollment helper reports it. |
| `result.diagnostics` | Elapsed times, numeric status codes, and Keychain status flags from the helper. Diagnostics never include profile contents or credentials. |
| `result.failureStatePreserved` | On failure, whether Pomme kept the failure state for inspection. |
| `result.retryAllowed` | On failure, whether repeating the command can continue the work. |

To include more detailed enrollment diagnostics, add `--debug`:

```sh
pomme mdm VM_NAME --profile PROFILE_PATH --debug --format json
```

For the general output format, see
[Structured output](/reference/structured-output/).

## Downgrade considerations

Pomme records MDM enrollment in a schema 6 journal. Pomme reads older schema 3
through 5 journals with `--final-security restore` and rewrites them as schema
6 on their next update. An older Pomme build can't read a schema 6 journal, so
finish retained MDM work before you downgrade Pomme.

## What's next

- [Change SIP and AMFI](/guides/change-sip-and-amfi/)
- [Use templates](/guides/use-templates/)
- [`pomme mdm` reference](/reference/cli/pomme-mdm/)
- [Troubleshooting](/resources/troubleshooting/)
