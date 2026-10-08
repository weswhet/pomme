---
title: Supported macOS versions
description: Which macOS versions Pomme has reviewed for automated Recovery navigation, how it handles other versions, and what release qualification requires.
---

Pomme automates macOS Recovery by reading the VM's display and sending one
keyboard or pointer input at a time. That automation depends on the exact
screens that a macOS build shows, so Pomme distinguishes between builds it has
reviewed and builds it attempts experimentally. This page explains the
difference and what it means for the VMs you create.

## Reviewed and experimental builds

Each macOS restore image maps to a Recovery profile, which describes the
screens and inputs that Recovery navigation expects for that build:

- **Reviewed.** The Tahoe profile for macOS 26.6.0, build `25G72`, is the only
  reviewed profile.
- **Experimental.** Any other syntactically valid version and build can be
  attempted. This includes Sequoia, other Tahoe builds such as 26.6.2 build
  `25G83`, and macOS 27. Pomme binds the attempt to the actual restore version
  and build and records it in the VM's journal. An experimental profile makes
  no claim of review.

Pomme doesn't refuse a build because it hasn't been reviewed. Instead, it
records the actual version and build of the restore image and warns you when
that combination isn't qualified.

## Checks that always apply

Whether a build is reviewed or experimental, the following checks still
apply, and a failure stops the attempt before it has an effect:

- The guest uses the English locale.
- The guest display is exactly `1280×800`.
- The host's Virtualization.framework exposes the private display and input
  interfaces that Pomme expects.
- The profile, VM ownership, session authentication, and launcher checks pass.

## How experimental navigation stays safe

An experimental attempt follows the same screen-by-screen trace as a reviewed
profile. Before and after every single input, Pomme waits for two matching,
stable captures of the display and classifies the screen. If Pomme detects an
unexpected screen, or can't confirm that an input was delivered, it stops
navigation.

A failed phase keeps the VM and its journal so that you can diagnose it and
resume. To capture the screens that Pomme saw, repeat the command with
`--debug`, which keeps a screenshot from before each automatic Recovery input.
For details, see [Troubleshooting](/resources/troubleshooting/).

:::note
A successful experimental run shows that one attempt worked on your host. It
doesn't qualify that macOS build for release, and it doesn't add the build to
the reviewed profiles.
:::

## macOS 27 hosts and guests

When both the host and a fresh guest run macOS 27, Pomme installs its agent
through Apple's first-boot provisioning instead of Recovery. Security
workflows and agent repair still use Recovery navigation, so the same
reviewed and experimental rules apply to them. For details, see
[Durable creation and journals](/concepts/durable-creation/).

## Release qualification

Release qualification is the independently reviewed evidence that a stable
release works. Pomme 0.1.0 was released before its qualification was complete.
Qualification is separate from permission to try a new macOS version. It
requires the following evidence:

- **Recovery profile matrix.** For each supported OS, 25 consecutive
  successful Recovery navigations in each of three host states: another app in
  front, the host locked with its display awake, and the host locked with its
  display asleep. Across Tahoe and Sequoia, that's 150 cycles. Each cycle must
  leave the host pointer and front app unchanged, open no host window, and not
  wake the display.
- **Disposable-machine matrix.** A clean machine must pass creation, agent
  authentication, process execution, background jobs, file transfer, pause and
  resume, agent update and repair, SIP, AMFI, MDM, display automation, and the
  terminal UI.
- **Terminal-session qualification.** Long-running sessions, byte-exact
  replay, reattachment and takeover, signals, and complete cleanup of Recovery
  sessions.

## What's next

- Create a VM with a specific macOS version in
  [Create a VM](/guides/create-vms/).
- Find available restore images in
  [Manage restore images](/guides/manage-restore-images/).
- Learn how creation uses Recovery in
  [Durable creation and journals](/concepts/durable-creation/).
