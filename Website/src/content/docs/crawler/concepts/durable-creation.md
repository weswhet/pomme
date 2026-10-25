---
title: Durable creation
description: How Pomme plans, journals, and resumes VM creation so that an interrupted create never loses or quietly changes a VM, no matter how hard the viewers root for it.
---

Creating a Pomme VM is a provisioning workflow, not only a macOS
installation. Pomme installs macOS, installs and verifies its guest agent, and
leaves the VM in the state you asked for. Because these steps take minutes and
change a real machine, Pomme records them in a journal so that it can stop
safely at any point and continue later with `pomme create --resume`.

In other words, Crawler, tripping over the power cable mid-create isn't the
dramatic finale the audience hoped for.

## The battle plan

Before Pomme changes anything, it resolves and verifies everything the new VM
depends on:

- The exact restore image, including its macOS version and build.
- The English locale and the `1280×800` display geometry that automated
  Recovery navigation requires.
- The Recovery profile for that macOS build, either a reviewed profile or an
  experimental attempt. For details, see
  [Supported macOS versions](/crawler/concepts/os-qualification/).
- The identity of the signed guest agent, pinned by its SHA-256 digest.
- Whether creation uses experimental Recovery preparation, with a fixed
  Recovery session identity when selected.
- At least 4 GiB of guest memory, and the restore image's own minimum when the
  image is already on disk.
- Enough free space for the rest of the restore image download and the
  installed system, checked before anything is downloaded or written.

Pomme records these choices as an immutable plan. Every later step, including a
resume, is checked against the plan. If you run `pomme create --dry-run`, Pomme
resolves and prints the plan without creating anything. A rehearsal. The
viewers hate rehearsals.

## Creation phases

Pomme journals an intent before each phase that has an external effect and
records a verified receipt after it. A new VM goes through the following
phases:

1. **Install macOS.** Pomme restores the image to a new disk, or clones a
   template, and binds the VM to its restore image, build, locale, display,
   and agent identities.
2. **Install the guest agent.** Pomme uses one of three routes, described in
   the next section.
3. **Verify the agent.** Pomme boots normal macOS, authenticates to the agent,
   and checks that the agent's executable digest and capabilities match the
   plan.
4. **Restore the final state.** Pomme leaves the VM running in normal macOS,
   stops it, or restarts it in Recovery, as requested with `--boot`.

On the usual Recovery route, the freshly installed image boots directly into
Recovery. The verification boot in phase 3 is the guest's first normal boot.
No normal boot comes before Recovery.

Creation never changes System Integrity Protection (SIP) or AMFI. Those are
separate, explicit workflows. For details, see
[Security workflows](/crawler/concepts/security-model/).

## Agent installation routes

Pomme installs the guest agent through one of three routes:

- **First-boot provisioning.** When the host and a fresh guest both run
  macOS 27 or later, and the guest is no newer than the host, Pomme uses
  Apple's first-boot provisioning in Virtualization.framework
  to create the `pomme` account, turn on automatic login, and temporarily turn
  on Remote Login. Pomme finds the guest through its DHCP lease, pins the
  guest's SSH host key on first connection, and installs the signed agent over
  SSH. After it verifies the agent and the owner account, Pomme turns Remote
  Login off. The generated account password stays in the host's login
  Keychain.
- **Template agent.** VMs cloned from a provisioned template that kept its
  agent credential use this route. The clone's disk already contains the
  agent that Pomme installed when it captured the template. Pomme boots normal
  macOS, authenticates that agent with the template's credential, replaces it
  with the pinned agent, and gives it a credential of the clone's own, without
  booting Recovery. Hand-me-down companion, fresh dog tags. For details, see
  [Use templates](/crawler/guides/use-templates/#how-clones-get-their-agent).
- **Recovery installation.** Older hosts, older guests, VMs cloned from a
  provisioned template that didn't keep its agent credential, and VMs with an
  existing journal from an earlier release use this route. Pomme boots the new
  VM into Recovery and installs the agent through a temporary, read-only
  VirtioFS share that's bound to one request.

All three routes end in the same verification and final-state phases.

## Recovery image preparation

`pomme create --experimental-recovery` prepares the stopped VM's Recovery
image on the host and embeds an agent that launchd starts automatically. It
retains both the original and prepared images. When a boot needs the other
image, Pomme switches them while the VM is stopped: the prepared image for
Recovery, and the original for normal macOS. Pomme can connect to Recovery
without navigating its screens, including on later Recovery boots.
Agent installation still uses a temporary, read-only share bound to one request.
The embedded agent has its own credential in your login Keychain, separate from
the guest agent's.
Creation requires a fresh restore image or a template with an unmodified
Recovery image. Templates containing an already modified Recovery image aren't
supported; Pomme doesn't reuse their embedded agent credentials.

For eligible macOS 27 hosts and guests, first-boot provisioning and SSH checks
still establish that the owner is ready before Recovery installs the agent.
Normal agent, owner, and desktop verification remain required, and Remote Login
is off when creation completes.

The plan fixes this strategy and its Recovery session identity. Resume uses
those recorded choices; it doesn't accept `--experimental-recovery` or switch an existing
plan to a different strategy. Creation without the flag is unchanged.

The prepared Recovery image has its APFS System role cleared and its seal
broken. Normal boots use the original image, and SIP and AMFI stay unchanged.
After a macOS update replaces the guest's Recovery image, Pomme uses the
standard Recovery route. For usage and limitations, see
[Try experimental image preparation](/crawler/guides/create-vms/#try-experimental-image-preparation).

## Failure and resume

If a phase fails, or you interrupt Pomme, the VM and its journal stay exactly
as they were. Pomme doesn't delete the VM, and it doesn't boot the VM to undo
partial work.

To continue, run `pomme create VM_NAME --resume`. Resume first revalidates the
immutable plan, the VM's ownership, the recorded digests, and the pending
intent, and then continues from the first phase without a verified receipt.
Resume accepts only the VM name and the output and debug flags, because every
other choice is already fixed in the plan. No changing your loadout mid-fight.

An agent installation can fail after the guest already received its agent,
for example when only Recovery's cleanup fails. When an earlier attempt sent
the VM's credential to the guest, resume first boots normal macOS and waits up
to 150 seconds for that agent. If the agent authenticates with the VM's own
credential and reports the pinned digest, Pomme records the installation and
doesn't boot Recovery. Otherwise, it stops the VM and installs the agent
through Recovery, as before. Pomme makes this check once for each attempt that
sent the credential. `pomme agent repair` makes the same check. Checking
whether the job is already done: the System calls it cheating, the sponsors
call it efficiency.

:::tip[New Achievement! Back From the Brink]
You resumed an interrupted creation instead of starting over. Reward: a Silver
Persistence Box. It contains a receipt. A verified one, naturally.
:::

## Templates

Restoring a macOS image is the slowest part of creation. A template lets you
do it once and reuse the result.

`pomme template create` performs only the installation phase and stores the
result in the `Templates` directory. A template holds the disk image,
auxiliary storage, hardware model, and a manifest that records the restore
image digest and disk size. It has no agent, credential, or journal.

`pomme create --from-template` runs the same journaled phases, but its install
phase clones the template's files with the APFS `clonefile` call. Clones are
copy-on-write, so they're fast and initially use almost no extra disk space.
Each clone gets a fresh machine identifier and UUID, so VMs cloned from the same
template have distinct identities and can run at the same time. The plan pins
the template's restore image digest, and the install phase verifies the
manifest against it, so a template that was replaced after the plan was made
can't satisfy an older journal. No body doubles allowed.

A template created with `--provisioned` also captures a prepared `pomme` owner
account, a security posture that's ready for MDM enrollment, and the installed
agent, whose credential Pomme keeps in a login Keychain item that belongs to
the template. For details, see [Use templates](/crawler/guides/use-templates/).

## Pinned agent artifacts

A VM's journal pins the exact guest agent executable by its SHA-256 digest.
Before Pomme creates a VM, it copies that executable into the append-only
`AgentArtifacts/sha256` directory under `~/Library/Application Support/pomme`.
The local build script also stores each signed build there. If Pomme can't
keep the copy, it warns you and creates the VM anyway.

This store lets a resumed installation, through Recovery or from a template,
use the exact agent that the journal pinned, even after the host `pomme`
command has changed. Pomme doesn't rewrite the
plan or substitute the current build's digest. If the pinned artifact is
missing or doesn't match its digest, the workflow stops instead of guessing.
The System, for the record, would have guessed. This is why the System isn't
allowed to write journals.

## Next floor

- Create your first VMs in [Create a VM](/crawler/guides/create-vms/).
- Speed up creation with [Use templates](/crawler/guides/use-templates/).
- Learn about the agent that creation installs in
  [Guest agent](/crawler/concepts/guest-agent/).
- Find the journal and artifact locations in
  [Files and paths](/crawler/reference/files-and-paths/).
