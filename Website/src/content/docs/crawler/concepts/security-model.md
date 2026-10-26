---
title: Security workflows
description: How Pomme changes SIP and AMFI, prepares the owner account, journals its progress, and enrolls VMs in MDM, with the System narrating and the warnings fully intact.
---

This is the floor with the locked doors, Crawler. Some tasks require lowering
a VM's security settings. For example, MDM enrollment and certain testing
tasks need System Integrity Protection (SIP) or Apple Mobile File Integrity
(AMFI) turned off. Pomme treats each of these changes as a transaction: it
records what it's about to do, verifies every result, and returns the VM to
the state you asked for. This page explains how those transactions work and
what Pomme needs from you to run them.

`pomme create` never changes SIP or AMFI. Security changes happen only when
you run `pomme sip`, `pomme amfi`, or `pomme mdm`, or when you create a
provisioned template.

The System's personal opinion: lowering a guest's protections is a serious
act, and Pomme treats it that way. The jokes on this floor are for
decoration. The rules aren't.

`pomme create --experimental-recovery` changes the Recovery image separately
from these settings: it clears the image's APFS System role and breaks its seal
to embed an agent that starts automatically. Pomme selects that modified image
for Recovery boots and restores the original image for normal boots, while the
VM is stopped. SIP and AMFI stay unchanged. The embedded agent has its own
credential, so the copy in the Recovery image can't authenticate as the guest
agent. See
[Try experimental image preparation](/crawler/guides/create-vms/#try-experimental-image-preparation)
for the experiment's limitations.

## Where each change happens

macOS allows each setting to change only in a specific environment, so a
workflow can involve more than one boot. Pomme boots Recovery only for the
changes that macOS allows nowhere else, and does everything else in normal
macOS through the guest agent. The basement is for emergencies, Crawler, not
for sightseeing:

- **SIP** turns off in Recovery, through an authenticated, request-bound
  Recovery session. It turns back on in normal macOS: the guest agent runs
  `csrutil clear` as the volume owner, and Pomme reboots the guest to apply
  it. VMs whose guest agent predates this turn SIP on in Recovery instead.
- **AMFI** has two parts. The boot-argument part is written through the
  authenticated normal agent in normal macOS, while SIP is off. The
  LocalPolicy part must allow custom boot arguments. The boot policy that
  `csrutil disable` leaves already does, so the guest agent only records it in
  normal macOS. A VM with a different boot policy changes it in Recovery
  through an authenticated Recovery session.
- **Status checks** for SIP and AMFI read the configuration through the guest
  agent in normal macOS. Pomme starts normal macOS for the check when the VM
  isn't running it.

Because of this split, the order of operations matters:

- To turn AMFI off, turn SIP off first, and then turn AMFI off.
- To restore AMFI, restore it before you turn SIP back on.

:::caution[Hazard Detected: Wrong Door Order]
SIP off comes before AMFI off. AMFI back on comes before SIP back on. No flag
changes that order. Crawlers who try to skip ahead simply
get stopped, which is the least dramatic outcome possible.
:::

AMFI enable restores the exact configuration that Pomme saved when it turned
AMFI off. If AMFI is off and Pomme has no saved configuration for it, the
workflow stops with the
[`amfi-baseline-missing`](/crawler/reference/errors/#amfi-baseline-missing) error
rather than guessing at a reset.

## Look before you leap

Every security workflow observes the current setting before it does anything
else. If the setting already matches your request and no earlier operation is
unfinished, Pomme records that no change was needed and returns the VM to its
final state. Status commands and these no-op requests never ask for, or send,
the owner account's password.

## The owner account

Changing SIP or AMFI requires an administrator account in the guest. Pomme
calls this account the owner, and it handles the owner in one of two ways.

### Fresh VMs

If the VM is proven to be fresh and Pomme-owned, Pomme creates the owner
itself, without asking. It creates a `pomme` administrator account, turns on persistent
automatic login for it, and completes Setup Assistant. Pomme generates the
password, stores it in your login Keychain, and never prints it. Not even for
the viewers. They've asked.

Pomme decides that a VM is fresh only when its local accounts exactly match
the stock accounts of a newly installed macOS. An unfamiliar account blocks
the decision, so Pomme never adds an account to a guest that someone has set
up. Because the account only completes a VM that Pomme itself created, Pomme
doesn't ask you to confirm it.

### Existing owners

If the VM already has an owner, Pomme only verifies it. It checks the account,
its administrator membership, its Secure Token, and its password, and it never
replaces the account or changes the password. Pomme gets the owner's
credentials from one of the following sources:

- Both the `POMME_AUTHORIZED_USER` and `POMME_AUTHORIZED_PASSWORD` environment
  variables. Setting only one of them is an error.
- A credential in your login Keychain that's scoped to this VM.
- An interactive prompt.

Pomme passes the password only to the component that checks it. The password
never appears in command arguments or in the journal.

### Automatic-login restrictions

Before it turns on automatic login, Pomme checks for conditions under which
macOS refuses automatic login, such as FileVault, managed login-window
preferences, and protections tied to Touch ID, Apple Pay, and the App Store.
If any restriction applies, the workflow stops. Pomme has no override for
these restrictions.

## Final state

When a workflow succeeds, Pomme returns the VM to the run state that you
choose with `--final-state`:

| Value | Final state |
| --- | --- |
| `previous` (default) | The run state that Pomme captured before the workflow began. A VM that was paused in Recovery ends stopped instead of booting Recovery only to be paused again. |
| `stopped` | Stopped. |
| `normal` | Running in normal macOS. |
| `recovery` | Running in Recovery. |
| `paused` | Paused, keeping the boot mode it had before the pause. |

A successful result reports the resolved `finalState` and whether Pomme
verified it in `finalStateVerified`.

If a workflow fails while preparing a fresh owner, Pomme leaves the VM in the
state where it failed so that you can inspect it. Other failures return the VM
to the run state captured at the start when Pomme can prove that doing so is
safe.

## The security journal

Each VM has one security journal, `SecurityWorkflowJournal.json`, in its
bundle. The journal records the operation, the requested final state, the
owner facts that Pomme verified, and a receipt for every completed step. It
never contains the owner's password.

Pomme writes an intent to the journal before each change that's visible
outside the host, and a verified receipt after it. This makes interrupted
workflows safe to continue:

- **To resume**, repeat the same command with the same `--final-state`. Pomme
  observes the guest again and continues without repeating a change that it
  already made.
- **A different operation conflicts.** If an unfinished journal belongs to a
  different operation, a new workflow fails before it changes anything. Pomme
  doesn't rewrite a retained request with a new one.
- **Incomplete cleanup stops the workflow.** If Pomme can't prove that a step
  cleaned up after itself, it reports `restorationIncomplete` and doesn't boot
  or restore the VM. Inspect the VM before you repeat the operation.

:::danger[Death Notice]
When Pomme reports `restorationIncomplete`, it stops on purpose. Inspect the
VM before you repeat the operation. Crawlers who mash the same command again
without looking are how the System fills its blooper reel.
:::

Active terminal sessions also block Recovery security workflows until you
end them with `pomme sessions terminate`.

## MDM enrollment

`pomme mdm` enrolls a VM in a mobile device management (MDM) server with a
configuration profile that you provide. It works from any VM state: it creates
the VM if it doesn't exist, finishes an incomplete creation or a retained SIP
or AMFI operation, turns off only the security settings that enrollment needs,
and enrolls. After enrollment, it restores the original SIP and AMFI settings,
unless you ask it to leave them off with `--final-security disabled`. On
macOS 27, it restores AMFI but leaves SIP off, because the guest needs SIP off
to receive MDM push commands. For details, see
[Receive push commands on macOS 27](/crawler/guides/enroll-in-mdm/#receive-push-commands-on-macos-27).

Enrollment is supervised and user approved by default. The
`--enrollment-mode unapproved` flag selects enrollment without approval or
supervision. Pomme uses a profile-based enrollment flow. It isn't Apple User
Enrollment or Automated Device Enrollment.

Each step keeps its own journal. To resume after a failure, repeat the same
command with the same profile, mode, and `--final-security` value. For
details, see [Enroll a VM in MDM](/crawler/guides/enroll-in-mdm/).

:::tip[New Achievement! Paperwork Survivor]
You read about journals, final states, and enrollment modes without fleeing.
Reward: a Gold Bureaucracy Box. It contains a form requesting a different box.
:::

## Provisioned templates

A template created with `pomme template create --provisioned` captures a
prepared `pomme` owner with automatic login, with SIP turned off and the AMFI
override turned on. Every VM cloned from it inherits that security posture, so
it can run MDM enrollment as its first command without another security
change. The owner's password isn't stored in the template.

Pomme keeps the credential of the guest agent installed in the template in a
login Keychain item that belongs to the template, and deletes it with the
template. A clone's agent authenticates with that credential only until Pomme
replaces the agent with the clone's pinned agent and a credential of the
clone's own. Shared keys are for the first night only, Crawler. For details,
see [Use templates](/crawler/guides/use-templates/).

## Next floor

- Change SIP and AMFI in
  [Change SIP and AMFI](/crawler/guides/change-sip-and-amfi/).
- Enroll a VM in [Enroll a VM in MDM](/crawler/guides/enroll-in-mdm/).
- Set credentials for unattended runs with
  [Environment variables](/crawler/reference/environment-variables/).
- Learn which macOS versions Recovery automation supports in
  [Supported macOS versions](/crawler/concepts/os-qualification/).
