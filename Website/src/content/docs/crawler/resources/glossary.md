---
title: Dungeon dictionary (glossary)
description: The words the System uses at you, defined, so that you stop nodding along and pretending.
---

This glossary defines terms that have a specific meaning in Pomme. The System
uses these words constantly and assumes you know them, Crawler. You don't. That's
fine. Nobody does at first. The viewers enjoy the blank stare, but the System is
contractually obligated to explain.

## A

**AMFI**

Apple Mobile File Integrity, the macOS subsystem that enforces code-signing
policy. Pomme changes AMFI through a VM's LocalPolicy and boot arguments.
See [Change SIP and AMFI](/crawler/guides/change-sip-and-amfi/). It's a
protection, not an obstacle, which is why the System makes you work to turn it
off.

**Automatic login**

A macOS setting that signs a user in at startup without a password prompt.
Pomme turns it on for the `pomme` owner account when it prepares a fresh VM
for a security workflow.

## B

**Background helper**

The per-VM host process that runs a VM through Virtualization.framework. The
`pomme` command talks to it through a Unix socket. Also called the *helper*.
It does all the heavy lifting and never gets a fan segment.

**Boot mode**

How a VM starts: `normal` starts macOS, and `recovery` starts macOS Recovery.
After creation, `none` leaves the VM stopped. Choose wisely, or at least
choose.

## D

**Durable terminal session**

An interactive shell or program in a guest pseudo-terminal that keeps
running when you detach. You can reattach later and replay its output. See
[Use durable terminal sessions](/crawler/guides/use-terminal-sessions/).
Unlike Crawlers, these survive when you walk away.

## E

**Executable digest**

The SHA-256 hash of a guest agent executable. Pomme pins each VM to the
digest it installed, or to the digest that `pomme agent update` last
installed, and verifies it on every connection. No disguises get past the door.

**Experimental attempt**

Creation or Recovery navigation for a macOS version or build that has no
reviewed Recovery profile. Pomme allows it with a warning. The System
calls this "bold." See
[Supported macOS versions](/crawler/concepts/os-qualification/).

## F

**Final state**

The run state that a workflow leaves a VM in when it finishes, such as
`previous`, `stopped`, or `normal`. Security commands take it as
`--final-state`.

**First-boot provisioning**

The macOS 27 Virtualization feature that creates a user account and turns on
services the first time a guest starts. Pomme uses it to install the guest
agent when both the host and the guest run macOS 27.

## G

**Guest**

The macOS installation that runs inside a VM. In jokes, "the box."

**Guest agent**

The Pomme service that runs in a guest and carries out host requests, such
as running programs and transferring files. See
[Guest agent](/crawler/concepts/guest-agent/).

## H

**Host**

The Apple silicon Mac that runs Pomme and its VMs. The arena, basically.

## J

**Journal**

A file in a VM bundle where Pomme records each step of a long-running
workflow before and after it happens. Pomme uses journals to resume creation
and security workflows safely. See
[Durable creation and journals](/crawler/concepts/durable-creation/). It's
the dungeon's black box recorder, and it's why a death mid-workflow is usually
a second life instead of a funeral.

## L

**LocalPolicy**

The per-installation security policy that controls how an Apple silicon Mac
or VM starts macOS, including its SIP and AMFI
settings.

## M

**MDM**

Mobile device management. Pomme can enroll a VM with a configuration profile
from an MDM server. See [Enroll a VM in MDM](/crawler/guides/enroll-in-mdm/).

## O

**Owner account**

The `pomme` administrator account that Pomme creates in a fresh VM when a
security workflow needs one. Pomme stores its generated password in the
host's login Keychain. Not on a sticky note. The System checked.

## P

**Provisioned template**

A template that already contains the owner account, with SIP turned off and
the AMFI override on. VMs cloned from it can start MDM enrollment
immediately. See [Use templates](/crawler/guides/use-templates/). It
arrives pre-softened, so the clones skip straight to the paperwork.

## R

**Recovery**

The macOS Recovery environment. Pomme uses it to install the guest agent and
to change SIP and AMFI.

**Recovery session**

A temporary, authenticated Pomme service that runs in Recovery for one
request and is removed when the request ends. In and out. No loitering.

**Restore image**

An IPSW file that contains a macOS release for Apple silicon. Pomme installs
macOS in a VM from a restore image.

**Reviewed profile**

A Recovery navigation profile that has passed Pomme's review for one exact
macOS version and build.

## S

**SIP**

System Integrity Protection, the macOS feature that protects system files
and processes. See [Change SIP and AMFI](/crawler/guides/change-sip-and-amfi/).
The dungeon's load-bearing wall. Knock it down only on purpose.

**Snapshot**

A named copy of a VM's saved machine state that you can restore later. See
[Save and restore snapshots](/crawler/guides/use-snapshots/). A save point.
Not a backup. The System will keep saying this until it sticks.

## T

**Template**

An installed macOS disk image, auxiliary storage, and hardware model that
Pomme clones to create VMs quickly. See [Use templates](/crawler/guides/use-templates/).

## V

**VM bundle**

The directory in Pomme's data directory that holds one VM's disk image,
identity, metadata, and journals. See [Files and paths](/crawler/reference/files-and-paths/).

**VSOCK**

The virtual socket transport between a host and a VM. The guest agent and
Recovery session listen on VSOCK ports. The secret tunnel between the arena
and the box.

:::tip[New Achievement! Fluent in System]
You read the whole dictionary, Crawler. You can now understand roughly half of
what the System says. Reward: a Bronze Vocabulary Box. It contains the word
"idempotent," which you'll never use correctly.
:::
