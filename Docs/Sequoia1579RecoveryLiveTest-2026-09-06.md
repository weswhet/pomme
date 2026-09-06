# macOS 15.7.9 live test

The requested target is macOS Sequoia **15.7.9 (`24G830`)**, not the
15.6.1 restore image used for the preceding test. The user requested removal
of all macOS 15 IPSW downloads only after 15.7.9 passes.

## Installation source

`pomme ipsw download 15.7.9 --json --debug` returned
`No signed restore image matched 15.7.9.` A fresh disposable VM therefore
starts from the cached signed 15.6.1 restore and uses the guest's Software
Update service to reach the exact requested release.

Apple's catalog product `140-85388` and distribution metadata identify the
full installer as 15.7.9 / 24G830. The downloaded 15,655,958,320-byte package
passed `pkgutil --check-signature` with the Apple Software Update certificate
chain ending at Apple Root CA. However, its SHA-1
`94295f31d12db20110e7036cfc09edc8d9900b38` did not match the catalog's
`9b45bc4ef6f36decb1e7b41915956193d98d01df`. It is not used for installation.
Its SHA-256 is
`3a0d0ce4422a51b826699508a50e3f6b559cff7014daaa5b3600bbef935ecc9e`.

The authenticated guest's `softwareupdate --list` offers the exact label
`macOS Sequoia 15.7.9-24G830`, sized 2,270,102 KiB, requiring a restart.

## Fixture and test boundary

- VM: `pomme-agent-sequoia-1579-0906`.
- UUID: `ecaf1ac7-a6cf-4b58-8628-ad4cedf96643`.
- Disk: 40 GB; RAM: 4 GB.
- Signed Release executable SHA-256:
  `fce77dcf695b6740c8da395bc213b4ead347707e427bd1cb4167acc545567022`.
- Base creation completed successfully in 568.486 seconds and restored stopped
  state before the authenticated normal-guest probes.

The original provisioning plan remains immutable. Production Recovery profile
selection still uses its original restore identity. No 15.7.9 Recovery agent
installation or profile qualification was completed.

## Results

The fresh guest had no normal local user or APFS cryptographic owner. A
temporary `pomme-lab` administrator was created through a prompt-gated guest
PTY, with its password stored only in the exact VM-scoped Keychain item.
UID 501, administrator membership, enabled Secure Token, and matching APFS
Volume Owner evidence were independently verified before update authorization.
The eventual observable Software Update invocation rejected installation for
insufficient free disk space, reporting that 17.76 GB was required. The guest
remained on 15.6.1. Private password input files were opened and unlinked by
their one-shot wrappers; the VM-scoped credential remains for the retained
failed attempt.

The user then narrowed the request to direct Pomme creation from a 15.7.9 IPSW
if available. A fresh catalog query and exact `pomme create --version 15.7.9
--disk-size 40GB --memory 4GB --boot none --dry-run` both confirmed no signed
matching restore image. No new 15.7.9 VM was created. The upgrade experiment
was stopped, and no macOS 15 IPSW download was deleted because the requested
agent-install test had not passed.

Final state: the retained base VM is stopped, with boot mode none and no
helper running. Its journal, exact VM-scoped credentials, and private failure
evidence remain. The pre-existing VMs were not modified.
