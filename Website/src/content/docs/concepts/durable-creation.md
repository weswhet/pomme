---
title: Durable creation and journals
description: How Pomme plans, journals, and resumes VM creation so that an interrupted create never loses or silently changes a VM.
---

Creating a Pomme VM is a provisioning workflow, not only a macOS
installation. Pomme installs macOS, installs and verifies its guest agent, and
leaves the VM in the state you asked for. Because these steps take minutes and
change a real machine, Pomme records them in a journal so that it can stop
safely at any point and continue later with `pomme create --resume`.

## The creation plan

Before Pomme changes anything, it resolves and verifies everything the new VM
depends on:

- The exact restore image, including its macOS version and build.
- The English locale and the `1280×800` display geometry that automated
  Recovery navigation requires.
- The Recovery profile for that macOS build, either a reviewed profile or an
  experimental attempt. For details, see
  [Supported macOS versions](/concepts/os-qualification/).
- The identity of the signed guest agent, pinned by its SHA-256 digest.
- At least 4 GiB of guest memory, and the restore image's own minimum when the
  image is already on disk.

Pomme records these choices as an immutable plan. Every later step, including a
resume, is checked against the plan. If you run `pomme create --dry-run`, Pomme
resolves and prints the plan without creating anything.

## Creation phases

Pomme journals an intent before each phase that has an external effect and
records a verified receipt after it. A new VM goes through the following
phases:

1. **Install macOS.** Pomme restores the image to a new disk, or clones a
   template, and binds the VM to its restore image, build, locale, display,
   and agent identities.
2. **Install the guest agent.** Pomme uses one of two routes, described in the
   next section.
3. **Verify the agent.** Pomme boots normal macOS, authenticates to the agent,
   and checks that the agent's executable digest and capabilities match the
   plan.
4. **Restore the final state.** Pomme leaves the VM running in normal macOS,
   stops it, or restarts it in Recovery, as requested with `--boot`.

On the Recovery route, the freshly installed image boots directly into
Recovery. The verification boot in phase 3 is the guest's first normal boot.
No normal boot comes before Recovery.

Creation never changes System Integrity Protection (SIP) or AMFI. Those are
separate, explicit workflows. For details, see
[Security workflows](/concepts/security-model/).

## Agent installation routes

Pomme installs the guest agent through one of two routes:

- **First-boot provisioning.** When both the host and a fresh guest run
  macOS 27, Pomme uses Apple's first-boot provisioning in Virtualization.framework
  to create the `pomme` account, turn on automatic login, and temporarily turn
  on Remote Login. Pomme finds the guest through its DHCP lease, pins the
  guest's SSH host key on first connection, and installs the signed agent over
  SSH. After it verifies the agent and the owner account, Pomme turns Remote
  Login off. The generated account password stays in the host's login
  Keychain.
- **Recovery installation.** Older hosts, older guests, VMs cloned from a
  provisioned template, and VMs with an existing journal from an earlier
  release use this route. Pomme boots the new VM into Recovery and installs
  the agent through a temporary, read-only VirtioFS share that's bound to one
  request.

Both routes end in the same verification and final-state phases.

## Failure and resume

If a phase fails, or you interrupt Pomme, the VM and its journal stay exactly
as they were. Pomme doesn't delete the VM, and it doesn't boot the VM to undo
partial work.

To continue, run `pomme create VM_NAME --resume`. Resume first revalidates the
immutable plan, the VM's ownership, the recorded digests, and the pending
intent, and then continues from the first phase without a verified receipt.
Resume accepts only the VM name and the output and debug flags, because every
other choice is already fixed in the plan.

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
can't satisfy an older journal.

A template created with `--provisioned` also captures a prepared `pomme` owner
account and a security posture that's ready for MDM enrollment. For details,
see [Use templates](/guides/use-templates/).

## Pinned agent artifacts

A VM's journal pins the exact guest agent executable by its SHA-256 digest.
When you rebuild and install the host `pomme` command with the local build script, the
script also stores each signed executable in the append-only
`AgentArtifacts/sha256` directory under `~/Library/Application Support/pomme`.

This store lets a resumed Recovery installation use the exact agent that the
journal pinned, even after the host `pomme` command has changed. Pomme doesn't rewrite the
plan or substitute the current build's digest. If the pinned artifact is
missing or doesn't match its digest, the workflow stops instead of guessing.

## What's next

- Create your first VMs in [Create a VM](/guides/create-vms/).
- Speed up creation with [Use templates](/guides/use-templates/).
- Learn about the agent that creation installs in
  [Guest agent](/concepts/guest-agent/).
- Find the journal and artifact locations in
  [Files and paths](/reference/files-and-paths/).
