---
title: Open the side doors
description: Check and change Remote Login and Screen Sharing in a running Pomme VM through its guest agent, and remember to close them again.
---

Every dungeon has side doors, Crawler. This guide shows you how to check, turn
on, and turn off Remote Login (SSH) and Screen Sharing in a Pomme VM. Pomme
makes these changes through the authenticated guest agent, so the VM must be
running normal macOS.

## Before you descend

The System requires the following before it unlocks this room:

- Start the VM in normal macOS. For details, see
  [Manage the VM lifecycle](/crawler/guides/manage-vm-lifecycle/).
- Make sure that the guest agent is connected. To check, run
  `pomme agent status VM_NAME`. For details, see
  [Check, update, and repair the guest agent](/crawler/guides/repair-the-agent/).

## Check the SSH door

To see whether Remote Login is on, run the following command:

```sh
pomme remote-login status VM_NAME
```

Replace `VM_NAME` with the name of your VM.

The command runs `/usr/sbin/systemsetup -getremotelogin` in the guest and
prints its output.

## Open or close the SSH door

To turn on Remote Login, run the following command:

```sh
pomme remote-login enable VM_NAME
```

To turn it off, run the following command:

```sh
pomme remote-login disable VM_NAME
```

Replace `VM_NAME` with the name of your VM.

The guest agent changes the setting and then reads it back. If the observed
setting doesn't match the request, the command fails. No "probably worked"
here. The System doesn't hand out participation trophies.

:::caution[Hazard Detected: Open Door]
Remote Login lets guest accounts sign in to the VM over the network. Turn it off when you no longer need it. A door that you forgot about is a door that
anyone on the network can try.
:::

## Walk in over SSH

Pomme doesn't report the guest's IP address. To find it, ask the guest:

```sh
pomme exec VM_NAME -- /usr/sbin/ipconfig getifaddr en0
```

Replace `VM_NAME` with the name of your VM. If the command prints nothing, the
guest's primary network interface might have a different name. To list all
interfaces, run `pomme exec VM_NAME -- /sbin/ifconfig`.

Then connect from the host with an account that exists in the guest:

```sh
ssh USER_NAME@GUEST_ADDRESS
```

Replace the following:

- `USER_NAME`: the short name of a guest account that has a password.
- `GUEST_ADDRESS`: the address that the previous command printed.

For most tasks, you don't need SSH. To run commands and copy files through the
authenticated guest agent instead, see
[Run commands in a VM](/crawler/guides/run-guest-commands/) and
[Transfer files](/crawler/guides/transfer-files/). The front door was open the
whole time, Crawler.

:::tip[New Achievement! Side Entrance]
You reached the guest over SSH. The viewers were hoping for a lockout.
Reward: a Bronze Doorstop Box. It contains a doorstop.
:::

## Manage Screen Sharing

Pomme exposes the following Screen Sharing commands:

```sh
pomme screen-sharing status VM_NAME
pomme screen-sharing enable VM_NAME
pomme screen-sharing disable VM_NAME
```

Replace `VM_NAME` with the name of your VM.

Before it sends the request, Pomme authenticates the persistent guest agent
and checks that it advertises the `ui.screenSharing` capability. If the agent
doesn't, the command fails with the following error:

```text
Screen Sharing is unavailable through Pomme because this guest agent does not support it. Configure it in the guest’s Sharing settings instead.
```

:::note[System Notice: Locked Door]
The guest agent in Pomme 0.1.0 doesn't advertise the `ui.screenSharing`
capability, so these commands return the preceding error. To turn on Screen
Sharing, open **System Settings > General > Sharing** in the guest.
:::

To see the capabilities that a VM's agent advertises, run
`pomme agent status VM_NAME --format json` and read the
`guestAgent.capabilities` array.

## Next floor

- [Run commands in a VM](/crawler/guides/run-guest-commands/)
- [Automate the guest display](/crawler/guides/automate-the-display/)
- [`pomme remote-login` reference](/crawler/reference/cli/pomme-remote-login/)
- [`pomme screen-sharing` reference](/crawler/reference/cli/pomme-screen-sharing/)
