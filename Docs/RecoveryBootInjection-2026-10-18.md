# Recovery boot and custom payload investigation

Research dates: October 18–19, 2026. This follows the
[Recovery file-persistence experiment](RecoveryFilePersistence-2026-10-18.md).

The `POMME_LAB_*` hooks that this note uses were removed from the CLI on
October 20, 2026. The sources that contained them are retained under the
evidence root in
`ExperimentalCreation-2026-10-20/pre-review-fixes-snapshot/`.

A modified Recovery image has booted on the disposable macOS 26.6.2 VM with
SIP enabled. Clearing the copied BaseSystem APFS volume role to NONE allowed
the live root to expose a unique custom marker. `diskutil apfs list` identified
that root as having no specific role and `Sealed: Broken`; the `sealed` label
in `mount` output did not establish an intact seal. Automatic launchd execution is also demonstrated: a new job label was not
discovered, but replacing the arguments of an existing job ran the custom
script at boot and again after a second reboot without further image edits or
manual job bootstrap. These are proven building blocks. A resident Pomme Recovery lab mode is now
implemented and has authenticated to the host automatically from an embedded
Recovery image before any UI or terminal request, restarted and reauthenticated
after TERM, and authenticated automatically after a second Recovery boot.

MobileDevice contains overlay machinery, and the kernel contains a separate
policy-gated `BaseSystem.rooted.dmg` selector. Standard VZ Recovery uses the
direct-image path instead. The role-NONE experiment follows a different APFS
mount branch on that path; simply adding a rooted filename has no demonstrated
effect. No SIP, AMFI, NVRAM, or boot-policy change was required for the confirmed
marker boot. This result does not establish arbitrary image acceptance,
behavior on other OS builds, or retention through updates.

## Evidence and versions

| Component | Actual binary inspected | Purpose |
| --- | --- | --- |
| VM kernel | macOS 26.6.2, `25G83`, `kernelcache.release.vma2`, extracted `com.apple.kernel` | Image selection and root authentication |
| Recovery userspace | BaseSystem `022-22048-093.dmg.aea` from the same IPSW | `csrutil`, `launchd`, boot scripts, staging helpers |
| Host installer | macOS 27.0, `26A428`, ARM64e `VirtualizationInstallation` XPC service | Restore options supplied by Virtualization.framework |
| Host restore engine | Same host, ARM64e `MobileDevice` framework | Overlay requests and file transfer |
| Earlier automation trace | macOS 27.0.1, `26A434` | Internal automation-policy gates |

The kernel identifies itself as `xnu-12377.161.14~5/RELEASE_ARM64_VMAPPLE`,
Darwin 25.6.0, with UUID `B2455C4B-781C-3F38-8CA0-DD11CF317C15`.
Addresses below refer to the named binary, not a runtime slide.

Apple's public XNU source at commit
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea` (`xnu-12377.1.9`) supplies names and
context. It is not the exact source release of this guest. The decisive bit
test, filenames, flag propagation, and authentication branch were also checked
in the actual VM kernel with `ipsw` and Hopper.

## Custom BaseSystem selection

The selector is inlined inside the procedure Hopper labels
`sub_fffffe000a18b9ec`. The relevant sequence is:

1. Check whether the initially mounted root reports APFS volume-group support.
   On arm64 the BaseSystem pivot defaults on, except for single-user boot;
   `-bsdmgroot` and `-nobsdmgroot` affect selection but do not remove the
   volume-group prerequisite.
2. Mount Recovery and resolve the boot-object path or Preboot UUID.
3. Read CSR bit 8 at `0xfffffe000a18c8d8`. The branch at
   `0xfffffe000a18c944` skips the first rooted-image search when that bit is clear.
4. Search the boot-object firmware directory for
   `arm64eBaseSystem.rooted.dmg`, followed by `arm64eBaseSystem.dmg`.
   The fallback searches `/System/Volumes/Recovery/<Preboot UUID>/` for
   `BaseSystem.rooted.dmg`, followed by `BaseSystem.dmg`.
5. Successful rooted-image branches at `0xfffffe000a18cda8` and
   `0xfffffe000a18cdbc` set the rooted and skip-verification flags.
6. Call the image pivot at `0xfffffe000a18cbd4`.

The `bsdmgpath` boot argument is read after a candidate has been found. It is
not, by itself, an authentication exception. The filename route may avoid
needing that argument, provided the initial-root and policy conditions hold.
See Apple's [BaseSystem selector](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/bsd_init.c).

The actual pivot starts at `0xfffffe000a2a3b78`. It mounts the image read-only,
then issues `FSIOC_KERNEL_ROOTAUTH` at `0xfffffe000a2a3e5c`. If authentication
fails, the branches at `0xfffffe000a2a3e74` and `0xfffffe000a2a3e78` permit
continuation for the rooted or skip-verification flags. The normal branch does
not have that exception. This matches Apple's
[image-pivot implementation](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/imageboot.c).

The direct `root-dmg`/`auth-root-dmg` imageboot path runs earlier and is a
separate path. The live probe below confirmed that Pomme's Recovery boot uses
that direct path and starts from a standalone BaseSystem filesystem. It does
not use the later volume-group-dependent rooted-image discovery path.

The direct path was then traced in the actual 25G83 binary. `_bsd_init` calls
`imageboot_setup_new` (`0xfffffe000a2a4c18`) at `0xfffffe000a18c6b4`. It parses
`-rootdmg-ramdisk`, reads `root-dmg`, reads the image into memory, passes it to
`di_root_ramfile_buf` at `0xfffffe000a2a5234`, and calls `vfs_mountroot` at
`0xfffffe000a2a5308`. This helper has no CSR-bit-8 check or read of the CSR
configuration global. The preceding generic root-authentication ioctl is
skipped when imageboot recognizes the file URL. The APFS trace below finds a
separate mount-time check, so the generic ioctl skip is not evidence that the
direct path accepts arbitrary images. The alternate selector's CSR exception
must not be assumed to apply to standard Recovery.

## APFS verification on the direct Recovery path

The exact 25G83 APFS fileset entry has source version `2811.160.7.0.4`.
In `_apfs_vfsop_mount`, the sequence at `0xfffffe0009915748` checks for a virtual
container, the APFS volume role equal to SYSTEM (`1`), and the `already_rooted` state before
calling `_handle_basesystem_rootmount` at `0xfffffe0009915778`.

That handler requires the BaseSystem sealed flag. The branch at
`0xfffffe0009916fd4` leads to `BASESYSTEM IS NOT SEALED!` and `_panic` at
`0xfffffe000a53ae88` when the flag is absent. The panic target was confirmed
against the exact kernel's symbol table. For a sealed volume, it calls
`_import_iboot_forwarded_roothash(1)`, which obtains
`base-system-volume-auth-blob` from `/chosen/secure-boot-hashes` through
`DT_property`. A missing blob leads to `_bsd_boot_to_recovery`.

The handler then calls `_authenticate_root_hash` with volume type 3 and strict
mode. It compares the imported authentication data with the APFS integrity
metadata, including the root hash. A required strict check that fails returns
to Recovery. `_is_root_hash_authentication_required` consults CSR masks `0x10`
and `0x800`; it does not consult `CSR_ALLOW_ANY_RECOVERY_OS` (`0x100`). On the
non-AppleInternal Release path, BaseSystem type 3 requires authentication. The
`0x800` exception belongs to another volume type, not this BaseSystem case.

This is concrete evidence against accepting an arbitrarily modified BaseSystem
under the observed policy. It does not yet establish how firmware authenticates
or selects the forwarded blob, or prove that every alternate boot workflow is
excluded. Raw evidence is retained with the research artifacts.

The corresponding mBoot trace finds a registered `base-system-roothash-path`
option, defaulting to
`/usr/standalone/firmware/base_system_root_hash.img4` at `0x70070928`.
`sub_700834a8` uses this selector to look up `system-volume-auth-blob` in the
boot-object/manifest table through `sub_700b699c`; it does not derive the value
from candidate BaseSystem filesystem bytes there. Separately, `sub_7006cfe0`
passes the output key `base-system-volume-auth-blob` through its property
construction path. These are distinct lookup and output keys.

The table has structural magic and bounds checks, and `sub_700b6bc0` assembles
`secure-boot-hashes` from manifest fields. This supports a manifest-backed
source, but the cryptographic verification of that metadata and a fallback
lookup in `sub_70083564` remain outside the completed trace. Registration of
the root-hash path does not establish an ordinary VZ caller's ability to
override it.

## APFS role-NONE candidate

A follow-up trace identifies the volume field above as `apfs_role`, read at
superblock offset `0x3c4`. The comparison at `0xfffffe0009915760` requires
SYSTEM (`1`); NONE (`0`) instead branches to the ordinary virtual-APFS mount
path. A role-NONE copy therefore avoids this particular call to
`_handle_basesystem_rootmount` in the inspected code.

The generic mount call loads argument `x4` from a stack slot initialized to
zero. `_handle_mount` branches over its direct authenticated-mount block when
that argument is zero. A nonzero `apfs_revert_to_xid` takes a separate revert
path that handles integrity metadata and can call `_authapfs_seal_break`
before reaching `_handle_mount` with the same zero argument. These local
branches make a role-NONE image a concrete candidate for a disposable test;
they do not establish that the complete boot process accepts it.

Apple's [APFS reference](https://developer.apple.com/support/apple-file-system/Apple-File-System-Reference.pdf)
defines these role values and requires a sealed volume to have the SYSTEM
role. Changing the role therefore leaves the documented sealed-volume
conditions. Firmware selection, other mount checks, and usable Recovery
startup must be measured separately. A second live Recovery boot below
confirmed the custom marker at the root of the role-NONE image with SIP enabled.
The first post-swap boot reached Recovery Utilities and Terminal even though
Pomme returned no PTY session ID. This evidence also says nothing about HFS image
acceptance.

The disassembly and argument-flow evidence are preserved as
`evidence/apfs-role-gate-and-generic-mount-evidence.md` in the research directory.

## How Recovery requests the policy flag

The actual 25G83 `csrutil` provides more than a kernel-only theoretical switch:

| Location | Observed behavior |
| --- | --- |
| `0x100004bac` | Parse `--without` on the enable path |
| `0x100024b00` | Option table entry for `basesystem` |
| `0x100004990` | Dispatch that option to `setRecoveryVerificationRequired:` |
| `0x100003bc0` | Invert the protection boolean and set CSR mask `0x100` |
| `0x100003ce4` | Reject restrictive firmware-security levels for this CSR configuration |
| `0x1000041d0` | Commit configuration using authenticated boot-policy operations |
| `0x100004664` | Call `bootpolicy_update_sip_flags` |

Thus `csrutil enable --without basesystem` is a parser-supported candidate to
request this setting. It is not a verified Pomme command sequence. The tool
labels partial configurations unsupported, checks the Recovery environment and
pairing, authenticates security changes, and chooses a compatible permissive
firmware-security level. Those operations were inspected, not executed.

`CSR_ALLOW_ANY_RECOVERY_OS` is bit 8. XNU's ordinary `CSR_DISABLE_FLAGS` does
not include it, so a generic SIP-disabled result is insufficient evidence.
Apple's [CSR definitions](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/csr.h)
and [LocalPolicy documentation](https://support.apple.com/en-ca/guide/security/secc745a0845/web)
also distinguish CSR policy from boot-argument filtering. Successful flag
configuration would still need verification in the actual Recovery kernel.

The AppleInternal CSR bit is not a simple alternative. In the exact kernel's
initialization routine at `0xfffffe000a54ab50`, the path reads `lp-sip0` from
`/chosen/asmb`, then checks `/chosen/internal-use-only-unit` and
`/chosen/manifest-properties/iuos`. If neither internal marker is true, it
unconditionally clears CSR bit `0x10` at `0xfffffe000a54acb8`, even if the
loaded policy requested it. With an internal marker, it preserves an explicit
policy or defaults the bit on when `lp-sip0` is absent. The actual `_csr_check`
honors the bit only after this initialization.

Although `csrutil` can request AppleInternal policy and offers `--no-internal`
to clear it, this does not remove the kernel's marker gate. The live probes
have not established the values of those two markers.

## Restore-time overlays

MobileDevice contains real overlay transfer machinery. This is stronger evidence
than the existence of a suggestive string, but it is not exposed by the VZ
installer path inspected here.

- `_AMRestoreCreateDefaultOptions` at `0x13a3f8` creates fresh fixed defaults
  without overlay-root arrays.
- `_thr_AMRestorableDevicePrepareOptions` at `0xc4f2c` reads `RootToInstall`,
  `OverlayRootsToInstall`, and several Cryptex overlay keys from the supplied
  options dictionary. `append_root_paths_from_options` at `0xc9434` accepts
  a path string or array. A preprocessing path constructs a `root_util merge`
  command.
- `_handleAsyncDataRequestMessage` at `0x125218` dispatches overlay requests by
  key or index. `_handleDataRequestMessage` at `0x12cb30` also dispatches root
  and overlay-root requests.
- `_handleOverlayRootDataRequest` at `0x1329d8` resolves the supplied key and
  requested index. `_sendOverlayRootDataToPort` at `0x124b98` opens the host
  path and transfers a directory or supported archive/image representation.
- No signature check or internal-device predicate was found in this bounded
  host transfer chain. That does not establish acceptance by the guest restore
  process or by subsequent boot verification.

In the ARM64e VZ installer service, `-[Installer startInstallation]` at
`0x100002be4` takes those defaults and adds a fixed set of restore, extraction,
personalization, partitioning, and progress-related settings. It does not add
overlay-root arrays. The restore callback at `0x100003724` handles status,
progress, device state, and errors; it is not a payload callback.

The separate `Restore.plist` read at `0x13a610` selects a system restore image
through `SystemRestoreImages` or `SystemRestoreImagesByTarget`. The inspected
path does not import arbitrary overlay options from that plist. Adding an
archive to a copied IPSW, or adding an overlay key to `Restore.plist`, therefore
has no demonstrated effect through the current VZ installer.

The Recovery-specific options also have confirmed consumers:

| Option | Actual consumer and effect |
| --- | --- |
| `RecoveryOSOverlayRootsToInstall` | Dispatch at `0x12e47c`; image resolver at `0x265e84` requires `PersonalizedRecoveryOSBundlePath` and calls the image modification helper |
| `RecoveryOSBaseSystemOverlayRootsToInstall` | `_handleBootObjectRequest` reads it at `0x134b58` and calls the modification helper at `0x134be4` with the component name `macOS Base System` |

`_AMRestoreInsertRootsToDmgAndCreatePath` at `0x13ce0c` performs actual image
modification. It uses `hdiutil convert` to create writable `tmpOS.dmg`, expands
archive roots with `tar` or accepts directory roots, resizes and mounts the
image, copies content with `copyfile`, detaches, and produces `finalOS.dmg` in
UDZO format. The BaseSystem branch invokes `__AMRestoreMountBaseSystemImage`
with a shadow image. At `0x13de7c`, the helper uses `hdiutil attach -agent hdid
-nobrowse -readwrite -mountroot <destination> -shadow <shadow> <tmpOS.dmg>`.
The final conversion at `0x13dff4` includes `-shadow <shadow>` to merge those
writes into the UDZO output. No re-signing, signature-validation, or digest-generation
call was found in this bounded helper. Later restore and boot checks remain
separate and unresolved.

The exported `AMRestorableDeviceCopyRestoreOptionsFromDocument` at `0xbb8e0`
returns `FlattenedSettings` from `.pr2` documents or `RestoreOptions` from `.pr`
documents without visible filtering of these keys. Together with exported
`AMRestorableDeviceRestoreWithError`, this establishes a private MobileDevice
options route in principle. It is not the VZ installer used by Pomme, and no
restore using these options was attempted.

## What this means for a persistent Recovery agent

The earlier live test established storage persistence on the backing Recovery
volume. The modified-BaseSystem experiment subsequently established automatic
startup through an existing launchd job. Placing a launchd plist beside
BaseSystem alone does not insert it into Recovery's boot filesystem.

The 25G83 `launchd` reads an embedded `__TEXT,__config` configuration at
`0x10004eecc`. Its bootstrap paths include `/System/Library/LaunchDaemons` and
several Apple/Cryptex-managed paths. No startup search of arbitrary adjacent
Recovery folders was found. The role-NONE BaseSystem has a verified custom
root marker and a verified automatically executed shell script. The first
added-job test found the files at `/`
but no registered service. Replacing an existing job's arguments subsequently
ran the custom script automatically, as recorded below.

The generic service-property parser at `0x100008210` recognizes `RunAtLoad`,
`KeepAlive`, `Disabled`, and optional boot-mode and variant filters. No generic
`DisabledInBaseSystem` or `EnableInBaseSystem` key was found. The separate
`PerformInBaseSystem` boot-task gate must not be applied to ordinary service
plists. Admission requires a nonempty label and valid program definition;
ownership and permission failures can also reject an import. The exact uid/mode
predicate was not recovered. `OnDemand` is explicitly a no-op.

No mandatory Apple-team check was found in this plist admission chain. There
are BTM denial and successful-spawn trust paths, so parser acceptance alone
does not establish that a Pomme executable will run. The `RunAtLoad` key was
verified in the parser and subsequently exercised by the successful live
one-shot job across two Recovery boots.

The stock writable Data environment is recreated from
`/System/Library/Templates/Data` on every Recovery boot. The `rc_script_wrapper`
allows fixed early-boot scripts. Optional diagnostic overrides are absent from
the stock template. `rc.trampoline` is absent, and its compiled launchd task
lacks `PerformInBaseSystem`; the task gate skips it in BaseSystem. The
`launchd_automation` argument affects automation crash handling rather than
supplying a payload path. Apple's separate `automation_trampoline` mechanism
has the internal-policy gates recorded in the earlier report.

Pomme's existing temporary Recovery session also needs lifecycle work before it
can serve as a permanent daemon: its request and token are deliberately bounded
to one session. A bootable custom image alone would not make that session
restart-safe or give it persistent authentication.

## Hopper workspace

The relevant files are open as separate Hopper documents:

| Document | Starting point |
| --- | --- |
| `kernel_vma2_25G83` | `0xfffffe000a18c944`, rooted-image gate; `0xfffffe000a2a3b78`, pivot |
| `apfs_25G83` | Exact guest APFS fileset entry, for mount-time verification analysis |
| `mBoot_vma2_25G83_arm64_analysis` | `0x700b8854`, firmware root-image boot-argument assembly |
| `AVPBooter_vmapple2_26A428_arm64_analysis` | Stock VM firmware; analysis-only ARM64 Mach-O wrapper |
| `AVPBooter_vresearch1_26A428_arm64_analysis` | Research firmware variant; analysis-only ARM64 Mach-O wrapper |
| `csrutil_25G83` | `0x100003bc0`, Recovery-verification flag setter |
| `bputil_25G83` | Boot-policy utility retained for further analysis |
| `launchd_25G83` | `0x10004eecc`, embedded boot configuration |
| `prebootensurer_25G83` | Recovery mount and temporary Preboot staging |
| `bs-early-tasks_25G83` | BaseSystem early tasks |
| `bs-data-tasks_25G83` | BaseSystem Data tasks |
| `rc_script_wrapper_25G83` | `0x10000050c`, early-boot context and fixed script paths |
| `VirtualizationInstallation_26A428_arm64e` | `0x100002be4`, restore options |
| `Virtualization-27` | VZ installer and VM boot interfaces |
| `MobileDevice_26A428_arm64e` | `0x1329d8`, overlay request handling |
| `automation_trampoline_26A434` | `0x100001c8c`, internal-device gate |

The older `VirtualizationInstallation-27` document came from a universal file.
Use the explicitly thinned ARM64e document for the addresses in this report.
No binary patches or user-document annotations were made.

The mBoot document uses an analysis-only Mach-O container because the RAW
loader's AArch64 shortcut decoded the payload incorrectly in this installation.
The decompressed payload is unchanged at file offset `0x1000`; its virtual base
is `0x7006c000`, taken from payload offset `0x300`. This wrapper is an analysis
artifact, not a bootable firmware replacement.

The two AVPBooter documents also use analysis-only Mach-O wrappers, with
synthetic addresses. Their bytes after wrapper offset `0x1000` exactly match
the original raw payloads; the original hashes and wrapper provenance are
recorded with the artifacts. These wrappers are not bootable firmware images.
Both databases were saved and added to the index after format and payload
verification.

A seventeenth, thinned ARM64e Virtualization VM-service database was also saved
and indexed. Its callback source path and architecture were verified; MCP
`list_documents` and `current_document` verification was unavailable for this
addition. It does not have the same MCP verification evidence as the earlier
documents.

The 17 research databases and their source binaries are saved outside the
repository at:

```text
~/Library/Application Support/pomme/Research/RecoveryBoot-2026-10-18/
```

`hopper-index.json` records each binary's source, SHA-256, and saved database.
The unrelated existing `mdmclient` document was left untouched. The incorrectly
decoded temporary RAW mBoot document was closed; use the ARM64 analysis document.

## Live boot-path probe

A fresh disposable clone, `pomme-agent-recovery-bootprobe26-20261018b`, ran
26.6.2 (`25G83`) with a 40 GB disk and 4 GB RAM. Its UUID was
`51580c14-5485-44e1-a639-1f33f050423b`. The canonical signed build/install gate
passed first; the exact installed runner reported `0.2.3 (e2b1d1f-dirty)`.
Unrelated working-tree changes were preserved, and this run did not edit source.

Read-only Recovery observations:

- `kern.bootargs` used `-rootdmg-ramdisk` and
  `root-dmg=file:///<UUID>/boot/.../usr/standalone/firmware/arm64eBaseSystem.dmg`,
  followed by `-noprogress`.
- `/` was sealed, read-only `disk5s1`, named `macOS Base System`, in its own
  approximately 1.6 GB container. This was not the installed System/Data volume
  group.
- Device-tree `boot-objects-path` identified the UUID-scoped boot directory.
- Filtered kernel output reported BaseSystem with boot mode `recoveryos`.
  Normal System/Data/Preboot volumes and the backing Recovery volume were
  mounted later; `prebootensurer` handled the Recovery mount.

This resolves the selector question for the tested standard Recovery boot.
Image verification on the direct path must be considered separately from the
rooted-image discovery branch. No custom image, NVRAM, SIP, AMFI, or boot-policy
change was made in this probe.

The `/chosen` filter did not emit `lp-sip0`; this is not a measurement of the
effective CSR bit mask. A separate `csrutil status` was not captured before
the diagnostic session closed.

Cleanup deleted the disposable clone with `credentialsRetained:false` and
removed its exact temporary files and screenshots. Both protected templates
remained unchanged and unprovisioned. Unrelated VMs were not operated.

## Live modified-image marker experiment

A second disposable 26.6.2 clone,
`pomme-agent-recovery-imageprobe26-20261018c`, UUID
`e17a13eb-5b86-47e0-be32-f427cc33082a`, used the same 40 GB disk and 4 GB RAM.
The canonical signed-build gate passed before the test. Its single baseline
Recovery boot produced a working terminal, and `csrutil status` reported SIP
enabled. `bputil` was absent from this Recovery environment.

The backing image was:

```text
/private/tmp/Recovery/D5E1DB49-1391-4A2A-A359-7A55E143AAB0/usr/standalone/firmware/arm64eBaseSystem.dmg
```

The test retained a byte-matching backup, converted a copy to writable format,
mounted it with a shadow file, and added only
`/pomme-recovery-image-probe/marker.txt`, containing
`POMME_RECOVERY_IMAGE_PROBE_20261018C` followed by a newline. Conversion to UDZO
merged the shadow. A fresh read-only attachment verified the marker before the
backing image was replaced. The replacement hash matched the prepared copy.

| Image | Bytes | SHA-256 |
| --- | ---: | --- |
| Original | 1,562,348,679 | `eeda386b1fb66a313cadef26e3e7ee06643d4d5ea8b3330a411a118ac7d14ed3` |
| Modified | 1,156,023,989 | `ce1d0922ea9bb627903a5b63b742347a4ebeb4c14c994c2007d345f0eafedec5` |

There was one modified-image restart. Pomme accepted the start request and
reported the VM and Recovery helper running, but terminal admission failed
after approximately four minutes with `helper-protocol-error`: the terminal
creation response had no session ID. Scoped diagnostics reported navigation
timeout (`expected=startupOptions`, `lastObserved=none`), screenshot capture
failure, and a disconnected guest Recovery agent.

No post-restart guest output, root-marker observation, or live panic evidence
was obtained. This establishes successful image construction and a failed
Recovery-readiness probe. It does **not** establish that the modified image
booted, that the marker was visible at `/`, or that Apple's verification was
the cause of failure. A successful VZ start response is insufficient evidence
of a successful guest boot.

Companion verification files were left unchanged. No CSR, SIP, AMFI, NVRAM,
or boot-policy setting was changed. Cleanup stopped and deleted only this
clone, with `credentialsRetained:false`, and removed its exact debug and
temporary paths. Both protected templates remained 40 GB, unprovisioned, with
security overrides disabled and no retained agent credential. A redacted
readiness diagnostic is preserved under the research directory's
`evidence/live-image-probe/`.

## Validation still required

The standard Recovery boot path is observed. Acceptance of modified image
content remains a separate boundary from opening or repacking the DMG. The
private ROM property test establishes API access, but the stock-ROM and PL011
live controls below passed configuration validation but failed during
`VZVirtualMachine.start`, before guest startup, with an internal Virtualization
error. Their cause remains unknown. The role-NONE post-swap boot reached
Recovery Utilities and Terminal, but Pomme returned no PTY session ID.
A second Recovery boot directly confirmed the custom root marker with SIP
enabled. This establishes boot acceptance of that modified image; it does not
by itself establish a resident Recovery agent. The later existing-job test
also demonstrates automatic launchd script execution across two boots.
The restore-original control was not completed; direct custom-root proof
superseded it before the disposable clone was deleted. Modified firmware and
a full embedded Pomme Recovery agent remain unverified.

The alternate rooted-image pivot could also be investigated as a different
boot workflow. A booted marker must precede a one-shot marker-writing launch
daemon. Image selection, script execution, reboot persistence, and policy
effects are separate outcomes to measure. Neither macOS 27 guest behavior nor
retention through OS updates is established by these 26.6.2 guest experiments.

## Pomme integration boundaries

Current restore construction in `PommeCore.installProvisioningVM` and
`createTemplatePayload` passes the pinned original IPSW URL to
`VZMacOSInstaller`. The immutable image SHA-256 is checked before restore.
An experimental restore-options adapter belongs at those construction points;
it should preserve the pinned source identity and record any separate overlay.

`VMRuntime.startRecovery` sets only `startUpFromMacOSRecovery = true`. Pomme's
existing production private Virtualization ABI checks cover display/input.
The dedicated research worktree now adds separate checked ROM and PL011 UART
experiments, described below. They do not expose restore-option overrides or
establish a usable custom boot route.

`PommeAgentRecoveryInstaller` installs the persistent agent onto the mounted
macOS Data volume for normal boot. Its name identifies where the installer
runs, not where the installed agent runs. The runtime Recovery terminal
admission path stages a one-time Recovery agent through VirtioFS, authenticates
it, and removes staging. Neither is a resident Recovery installation.

## Private Virtualization API follow-up

The private surfaces were inspected as well as the public interfaces. On host
build 26A428, `VZMacOSRestoreImage` has an `_restoreOptions` ivar, but no observed
accessor or code references. Restore-image loading and installation IPC carry
the file path and sandbox extension. The service constructs its options
internally. The ivar is therefore not evidence of a usable dictionary override.

`VZMacAuxiliaryStorage` does have private NVRAM setters. Its
`_setDataValue:stringValue:forNVRAMVariableNamed:error:` implementation at
`0x225fcc578` traps unless the process's Virtualization entitlement mask passes
`& 0x12` at `0x225fcc5d4`. `com.apple.private.virtualization` contributes bit
`0x2`, and `com.apple.private.virtualization.security-research` contributes
`0x10`; Pomme's current `com.apple.security.virtualization` entitlement is a
different bit (`0x4`) and does not satisfy this gate. The internal variable classifier
includes `base-system-path` and `boot-args`, but that does not establish that
Recovery will accept a custom image selected by either variable.

The private macOS boot loader exposes `_setROMURL:` at `0x225f3f2c4`, with
Objective-C encoding `v24@0:8@16`; its getter is `_romURL` (lowercase), encoding
`@16@0:8`. It is not a macOS boot-arguments property. That setter validates a
file URL and stores it; no entitlement check was found there or in
`_bootLoaderForConfiguration:` at `0x225f3ecd4`.

With a non-nil URL, the builder opens the file read-only and constructs an
`AvpBooter` file-descriptor variant. With nil, it selects the bundled-version
variant. VM-service serialization distinguishes `custom_rom_file_descriptor`
from `avp_booter_specification`; its firmware configuration consumes
`bootloader_rom` and `rom_binary`. Thus the custom URL routes an FD past the
bundled-version resolver. Static inspection did not trace final firmware
consumption or establish acceptance of arbitrary bytes.

The stock resolver uses framework resources such as `AVPBooter.vmapple2.bin`.
On this host, Virtualization is version `308.1.7`; that resource is 334,960 bytes,
SHA-256 `6d010540a047ec71a54cb96565171f8f2e0e191dd5dbef2403f3863409afa845`.
This is a firmware input, not a BaseSystem DMG or kernelcache selector.

A separate signed Objective-C helper verified the setter/getter round trip and
public `NSCopying` preservation using that unchanged stock ROM. It used the
required Developer ID identity, team `2D8XQ77EBQ`, identifier
`com.github.weswhet.pomme`, Hardened Runtime, and only the existing
`com.apple.security.virtualization` entitlement. No VM was instantiated, and
the helper did not access VM bundles or credentials. Its initial metadata check
rejected the incorrectly capitalized `_ROMURL` before any private call; the
corrected probe passed. The evidence retains both runs under the research directory's
`rom-api-probe/`, including source, the signed helper, and signature logs.

This establishes a callable private interface under Pomme's signing profile.
The subsequent live stock-ROM control passed configuration validation but
failed during `VZVirtualMachine.start`, before guest startup, as recorded below. Modified-ROM behavior remains untested. No signing entitlements or host
security settings were changed.


## Implemented worktree experiments and validation

The dedicated worktree `~/dev/pomme-recovery-research-20261018`, branch
`research/recovery-boot-20261018`, implements two independent process-scoped
experiments in `PommeRecoveryROMExperiment` and `PommeRecoveryUARTExperiment`.
They apply only when constructing a new Recovery runtime. An already running
helper cannot consume new environment settings; each control requires a fresh
helper. Neither experiment adds a public CLI flag or persists settings in a VM
configuration.

| Experiment | Required environment variables |
| --- | --- |
| ROM | `POMME_LAB_RECOVERY_ROM_PATH`, `POMME_LAB_RECOVERY_ROM_SHA256`, `POMME_LAB_RECOVERY_ROM_VM` |
| UART | `POMME_LAB_RECOVERY_UART_PATH`, `POMME_LAB_RECOVERY_UART_VM` |

Each group is all-or-none. Its VM value must match the exact resolved target
name, which must start with `pomme-agent-` and have a nonempty suffix. Normal
and installer configurations reject enabled experiments. Inactive paths make
no private calls. The common configuration builder logs the scoped path and,
for ROM, digest before VM construction.

ROM admission requires an absolute, readable, nonempty regular file no larger
than 16 MiB, opened without following a leaf symlink. The supplied digest must
contain exactly 64 hexadecimal characters and match the file's SHA-256.
The code checks `_setROMURL:` and `_romURL` ABI encodings before calling them,
then verifies the URL round trip. Virtualization opens the URL later: this
check does not eliminate that time-of-check/time-of-use gap. The lab must keep
the ROM file unchanged through startup.

UART admission checks `_VZPL011SerialPortConfiguration`, its direct superclass
`VZSerialPortConfiguration`, the `init` encoding `@16@0:8`, and the
`serialPortType` encoding `q16@0:8` and return value `1`. Only after those checks
and initialization does it create a new absolute capture path with exclusive,
no-follow, write-only flags and mode `0600`. The parent directory must exist.
A public `VZFileHandleSerialPortAttachment` retains the output handle; its read
handle is nil. The experiment supplies no guest input and logs no captured
contents. UART can run with the default ROM, independently of the ROM gate.

The canonical signed build/install gate passed for source `e2b1d1f-dirty`.
The installed `~/.local/bin/pomme` had SHA-256
`c9da58f643652ba54e18d4287b1d6bdebe80aa78cd409a892a27e1a0ab795f91`, the required
Developer ID identity and team, and only `com.apple.security.virtualization`.
All seven focused native tests in `PommeRecoveryROMExperimentTests` and
`PommeRecoveryUARTExperimentTests` passed (`TEST SUCCEEDED`). These were native
`xcodebuild` test-bundle tests, not tests of the installed executable. Build,
signing, runner, and result-bundle details are preserved in
`worktree-build.json` in the research directory.

## Live default, UART, and stock-ROM controls

The disposable target `pomme-agent-recovery-rom26-20261019a` first completed a
default Recovery boot and opened an actual terminal. It reported the direct
`-rootdmg-ramdisk root-dmg=file:///.../arm64eBaseSystem.dmg` boot path, a sealed,
read-only APFS root, and `System Integrity Protection status: enabled.`

The two experiments then ran separately:

| Control | Observed result |
| --- | --- |
| Default ROM plus PL011 UART only | `helper-start-failed`; the helper logged the capture path, then `VZErrorDomain` code `1`, `Internal Virtualization error`, during `VZVirtualMachine.start`, before guest startup. The capture file existed and contained zero bytes. |
| Unchanged stock ROM override only, no UART | `helper-start-failed`; the helper logged the ROM path and matching digest, then the same `VZErrorDomain` code `1` error during `VZVirtualMachine.start`, before guest startup. |

The ROM input was the 334,960-byte `AVPBooter.vmapple2.bin` with SHA-256
`6d010540a047ec71a54cb96565171f8f2e0e191dd5dbef2403f3863409afa845`; its size and
digest were unchanged after the failed start. Both controls passed configuration
construction and validation; they failed during `VZVirtualMachine.start`, before
guest startup. Service unified logs did not establish a cause, and there is no
evidence attributing these failures to an entitlement rejection. They establish
neither custom-ROM boot support nor useful PL011 output. The
zero-byte capture contains no guest panic evidence and cannot explain the
earlier modified-DMG failure. Retaining the empty capture file after failure is
intentional. Exclusive creation requires a new capture path for each retry.

Sanitized control observations are preserved in
`evidence/live-rom-uart-controls-20261019a.txt` and the corresponding `.json`
in the research directory. The role-NONE observations follow. The disposable
clone was subsequently deleted; final cleanup evidence is recorded below.


## Live role-NONE image experiment

The same owned disposable clone, `pomme-agent-recovery-rom26-20261019a`, used
40 GB disk and 4 GB RAM for this test. The image copy attached as `disk6`, with
physical store `disk6s1` and APFS volume `disk7s1`. The active Recovery root was
the separate `disk5s1`; the role change targeted the copied image volume.

Guest command usage confirmed `diskutil apfs changeVolumeRole <volume> clear`
as the role-clearing form; `0` was ignored. An initial whole-device request
failed with `-69628` without changing the role. The corrected request against
`disk7s1` succeeded. The copy was converted to UDZO with SHA-256
`7fb01366c01ff83a3f87ca2517fa0a4e361a34ffc59cd357c10473569d5d6885`.
A fresh read-only attachment confirmed the marker and no role line in the
volume information. The backing replacement had the same hash. Companion
verification files and security policy were unchanged.

The post-swap helper (PID `19209`) started at `14:03:40Z`, after the backing
replacement at `14:02:55Z` and after the preparation boot stopped. Its logs
show a Recovery Utilities screenshot at `14:05:17Z`, successful Terminal
marker proof at `14:05:30Z`, and the bootstrap phase at `14:05:38Z` on
October 19, 2026. These are positive observations of Recovery GUI and Terminal
startup after the swap. The Terminal marker proof is navigation/bootstrap
evidence, not confirmation of the custom filesystem marker.

A bounded Pomme terminal-admission request nevertheless returned no PTY session
ID, and its guest-agent status was disconnected. That result must not be
interpreted as proof that Recovery failed to boot. Source review found no
quick-exit session-ID race. The missing-ID error can mask an underlying helper
error; its exact cause here remains unknown. Holding the later PTY open does
not prove that a race was fixed.

A second Recovery boot, using a held PTY, directly read
`/pomme-recovery-role-none/marker.txt` and returned
`POMME_ROLE_NONE_MARKER_20261019A_6A5B3D01`. Its boot generation was
`ccd170d7-13e4-4387-8de9-1cd963e6b545`. SIP remained enabled, `/` was
`/dev/disk5s1` was read-only, and the boot arguments retained the standard
`-rootdmg-ramdisk root-dmg=...` path. Although `mount` printed `sealed`, the
explicit `diskutil apfs list` result identified `disk5s1` at `/` as `(No specific
role)` with `Sealed: Broken`. The mount label must not be read as proof of an
intact APFS seal. The unique marker at `/`
establishes that this boot exposed the modified filesystem; fallback to an
unmodified stock image does not explain that observation. The earlier missing
PTY session ID was therefore misleading as a boot-readiness indicator.

The clone's original image was retrieved directly and measured as
1,562,348,679 bytes, SHA-256
`eeda386b1fb66a313cadef26e3e7ee06643d4d5ea8b3330a411a118ac7d14ed3`.

A one-shot launchd variant has been built, verified through a fresh read-only
attachment, and installed as the backing image. It is 1,155,715,770 bytes with
SHA-256 `a44a7c7e9584bfdcd7eb0e5d92c2508c98f81329bb5aff85fa8a39bde1c98ffd`.
Its job uses `RunAtLoad` to invoke the marker-writing script without manual
bootstrap or `KeepAlive`. The script uses shell builtin `printf`; its SHA-256
is `a56124786cc1db79a13c28b993f365b3bdf410a13a475971dc8f790d8d891d61`.
The plist SHA-256 is
`cdc92fb60772697c5014a00fafe89cf49f8afaec05f742906e7854a612ba341f`.
Recovery hashing uses `/sbin/sha256 -q`; `base64`, `shasum`, and `openssl`
were not the verified transfer/hash tools. The first launchd-variant boot completed with the result below. The new job
was not discovered. The later existing-job variant did execute the payload;
a resident Pomme agent remains unverified.

Evidence is archived under `evidence/live-role-none-20261019a/`, including
`booted-marker.txt`, `root-and-original-image.txt`,
`launchd-image-verification.txt`, `recovery-autostart.sh`, and
`recovery-autostart.plist`.

The attempted normal-boot restoration control timed out after 90 seconds and
was not completed. Direct proof of the custom root and repeated automatic
script execution superseded that control before the disposable clone was
deleted. The original image was not restored onto the disposable disk before
deletion.


## Launchd discovery and existing-job experiment

The first launchd-variant boot had generation
`01c1d8e0-e09a-4ca9-888f-25b6a61a4bd8`. The new plist and script were present at
the live root with the exact expected hashes, but launchd reported the service
not found and the output marker did not exist. This separates image delivery
from job discovery: the image booted with the files, but the added job did not
run. Evidence is archived as `new-job-not-discovered.txt` and
`new-job-present-at-root.txt` under `evidence/live-role-none-20261019a/`.

The guest has `/System/Library/xpc/launchd.plist`, SHA-256
`06423687bdc61200e3e309e162e08724401df3957bf8cebf1fef5945df8f93e9`, and an
adjacent `.sig` file. A cached launchd configuration is a hypothesis for why a
new plist was not discovered; the presence of these files does not establish
that cause.

At the user's request, the subsequent test modified arguments of an existing job,
`com.apple.DumpPanicRecoveryOS`. It was already registered with `RunAtLoad=true`,
one recorded run, exit status zero, `KeepAlive` containing `Crashed=true`, and
no `Program` key. The experiment changes only `ProgramArguments` from
`[/usr/libexec/DumpPanicRecoveryOS]` to
`[/bin/sh, /pomme-recovery-role-none/autostart.sh]`. The label and every other
key are retained, including the existing `KeepAlive` setting.

| Artifact | SHA-256 |
| --- | --- |
| Original existing-job plist | `0d7e487cf49ba70310878cb25a1540668eb30c9659098f553aea42abfc3b35f8` |
| Replacement existing-job plist | `2c929488af49db6a841dae9c1fcb63b872512fe279d758f13106a51f911b5a34` |
| Existing-job variant DMG | `30ba47da8b8d66a2a37d8c0a5c1839282929c79a9476e1d629f62aab80c214e7` |

The DMG is 1,155,575,801 bytes. A fresh read-only attachment verified the change
and unchanged launchd cache; the installed backing image matched the prepared
hash. The first boot succeeded in executing the script automatically, as
recorded below. Preparation and installation evidence are under
`evidence/live-role-none-20261019a/existing-job/` in `preparation.txt`,
`verified-and-installed.txt`, and `outcome.json`.

The first existing-job boot had generation
`c703da7b-385c-4bd8-aea7-3e19207295d9`. The root plist hash matched
`2c929488af49db6a841dae9c1fcb63b872512fe279d758f13106a51f911b5a34`, and the
script hash matched
`a56124786cc1db79a13c28b993f365b3bdf410a13a475971dc8f790d8d891d61`.
The output marker contained `POMME_RECOVERY_LAUNCHD_20261019A_82C41F9B`, UTC
`2026-10-20T04:10:28Z`, and `parent_pid=1`.

`launchctl print system/com.apple.DumpPanicRecoveryOS` showed program `/bin/sh`,
arguments pointing to `/pomme-recovery-role-none/autostart.sh`, one run, and
last exit status zero. SIP remained enabled. No manual job bootstrap was used.
The launchd cache hash was unchanged: runtime evidence therefore establishes
that the changed arguments of this existing job were read despite the
unchanged cache. The complete cache/discovery mechanism remains unresolved.

The observed result answers the user's existing-job question for this 26.6.2
image: replacing only that registered job's arguments ran the custom script
automatically at boot. It does not establish discovery of new labels, a full
persistent Pomme agent, macOS 27 behavior, or retention through updates.
Evidence is in `existing-job/first-boot-autostart.txt` and the updated
`existing-job/outcome.json` under the same evidence directory.

A second boot of the same image succeeded with generation
`c648b0b6-b888-4b3f-9dff-4b968b958265`. The output marker had a new UTC timestamp,
`2026-10-20T04:13:33Z`, compared with `04:10:28Z` on the first boot, and again
reported `parent_pid=1`. The changed plist and script hashes matched, launchd
reported one run and exit status zero, and SIP remained enabled. There were no
further image edits or manual job bootstrap between these boots. This verifies
repeated automatic execution, not merely persistence of an earlier output
file. Evidence is in `existing-job/second-boot-autostart.txt` and the updated
`existing-job/outcome.json`.

## Final lab cleanup and limits

The exact disposable clone was stopped and deleted with
`credentialsRetained:false`. Cleanup removed 45 owned PNG files from nine debug
directories and 11 known assignment temporary files, then removed the empty
directories. Both protected 40 GB unprovisioned templates were verified intact.
Evidence is preserved as `cleanup.json`, `delete-result.json`, and
`protected-templates-after.json` in the role-NONE evidence directory.

The proven building blocks are custom-image boot and repeated automatic
execution through an existing launchd job on this 26.6.2 guest. At the end of
that marker-only phase, a Pomme agent had not been embedded or tested; the later
resident-agent result below extends this evidence. New-job discovery, the complete launchd
cache mechanism, macOS 27 compatibility, and retention through OS updates
remain unresolved. SIP enabled did not mean the modified APFS root retained a
valid seal: `diskutil` reported `Sealed: Broken` despite `mount` displaying
`sealed`.

After the tests and clone cleanup, the prior signed shared runner was restored
from its verified artifact, SHA-256
`4ec979c49db1d6854edf15072e8528f12e6588054a52d5150be3cd832776c9d6`.
Its designated requirement matched the experimental build; Developer ID,
team, identifier, Hardened Runtime, signature, and Virtualization-only
entitlements were verified before replacement. The experimental signed build
remains in the artifact store. See `runner-restoration.json` in the research
directory. No Pomme tests ran after restoring the prior runner.


## Resident Pomme Recovery experiment

Following the marker-script proof, the research worktree implements a bounded
resident Recovery mode. The actual embedded Pomme binary has now started through launchd and
authenticated to the host before any UI or terminal request. TERM/reconnect
and second-boot verification have also passed. This remains a research-only
26.6.2 (`25G83`) result with Recovery terminal authority. The earlier marker experiment
and its cleanup remain separate completed results.

The host requires both `POMME_LAB_RECOVERY_RESIDENT_VM` and
`POMME_LAB_RECOVERY_RESIDENT_SESSION`. The VM value must exactly match the
resolved disposable `pomme-agent-*` target, and the session must be a canonical
lowercase UUID. The mode is admitted only for a fresh Recovery runtime;
normal and installer configurations reject it. It suppresses the ordinary
temporary bootstrap share and UI terminal admission, attaches the Recovery
runtime listener on port `505053`, and uses that disposable VM's existing
Keychain credential with an exact VM UUID and fixed session UUID binding.
No VM configuration is persisted, and an existing helper must be restarted to
consume the environment.

The guest's hidden `--resident-recovery-lab <vm-name>` argument requires both
matching environment keys, including the same canonical session value supplied
by `--session-id`. Either environment key alone triggers strict validation and
fails closed. The executable must be `/pomme-recovery-agent/pomme`, the token
must be `/pomme-recovery-agent/agent.token`, the role must be `recovery`, and the
port must be `505053`. `--vm-id`, `--session-id`, and `--expected-sha256` are
required. Caller-supplied expiry, request-file, and operation arguments are
rejected. The intended argument shape is:

```text
/pomme-recovery-agent/pomme --pomme-agent 505053 --role recovery
  --token-file /pomme-recovery-agent/agent.token
  --expected-sha256 <embedded-executable-sha256>
  --vm-id <canonical-vm-uuid> --session-id <canonical-session-uuid>
  --resident-recovery-lab <exact-disposable-vm-name>
```

This remains a Recovery agent with terminal-only authority. It uses the
existing `terminal.session` restriction and narrow describe, health, and
terminal operations; it does not acquire normal-agent maintenance or security
mutation authority. The explicit resident mode preserves the token across
process restarts, retains VM/session-bound credentials, retries an unavailable
host listener, and reconnects after disconnect. Only strictly validated
resident options skip request-workspace cleanup. Ordinary request-bound
Recovery retains its token consumption, expiry, cleanup, and fail-fast listener
behavior. Normal Buddy and keystore maintenance remain disabled in Recovery.

The embedded launchd job uses the normal agent's lifecycle settings:
`RunAtLoad=true`, `KeepAlive=true`, `ThrottleInterval=5`, and
`ProcessType=Interactive`. The existing Recovery job label and filters are
retained rather than relying on discovery of a new label. Both resident
environment values are included in the job. These settings describe the
experiment's launchd configuration. Initial startup, restart supervision after TERM, and automatic startup on a
second Recovery boot are now verified.

The canonical signed build/install gate passed for source `e2b1d1f-dirty` and
runner SHA-256
`994b4286e75561ef60cd1fd4edfda5a0cda760c51e55169cdf42b7f7c0a441a8`.
Focused native tests across four suites passed, covering the resident gates
and existing daemon/Recovery behavior. These were native test-bundle results,
not proof of the embedded executable running in Recovery. No new public CLI
flag or signing entitlement was added. The signed runner installed for this
new phase supersedes the earlier phase's recorded runner restoration.


Resident-image preparation on October 19, 2026 Pacific (October 20 UTC) found
that the copied mount had ownership disabled: new files reported UID/GID 99
even after `chown`. On that verified copied mount only,
`diskutil enableOwnership <copied-mount>` followed by reapplying ownership
produced actual `root:wheel` metadata. The agent directory was mode `0700`,
the executable `0555`, and the token `0400`. Enabling and verifying ownership
on the copy is therefore a prerequisite before accepting the image's credential
permissions; a successful `chown` command alone was insufficient.

The APFS role was cleared on the volume derived from that attachment
(`disk7s1` in this run), not a hardcoded device. The plist and assets were
verified. UDZO conversion and fresh read-only verification completed before the
successful initial resident-agent boot recorded below. All 211 CLI contract checks
also passed using the exact installed runner with SHA-256
`994b4286e75561ef60cd1fd4edfda5a0cda760c51e55169cdf42b7f7c0a441a8`.


### First embedded-agent boot

The disposable VM `pomme-agent-recovery-embed26-20261020a` has UUID
`b253ed11-e8ca-4597-a660-824c333fb543` and lab session
`968c813a-5206-4796-9e2b-5a352756f793`. The final UDZO image SHA-256 is
`19c0f8be92e6218b40d9e502100fce6a236235e651779df45665f1d08345e106`.
After stopping the old helper, the fresh Recovery boot began at
`2026-10-20T04:54:51Z` with both resident environment values enabled. The host
log confirmed fixed session binding and no temporary bootstrap share.

Both VM status and agent status reported authenticated Recovery protocol 1
**before any UI or exec request**. At `2026-10-20T04:55:55Z`, the first resident
terminal confirmed launchd's program `/pomme-recovery-agent/pomme`, PID 54,
parent PID 1, `keepalive|runatload`, and minimum runtime 5. Environment,
arguments, and plist matched the intended resident configuration. The executable
matched signed SHA-256
`994b4286e75561ef60cd1fd4edfda5a0cda760c51e55169cdf42b7f7c0a441a8`; ownership
and modes matched the prepared root-owned files, and the token remained present.
The root had no APFS role and a broken seal; SIP remained enabled.

This demonstrates automatic startup and authenticated operation of the actual
embedded Pomme Recovery agent under its narrow terminal authority. The
subsequent restart and second-boot checks also passed, as recorded below.

### Restart and second-boot verification

TERM was acknowledged at `2026-10-20T04:56:30Z`. Agent status authenticated
again before a new exec request. At `04:56:53Z`, launchd reported two runs,
last terminating signal `Terminated: 15`, and new PID 251 instead of PID 54.
Its parent remained PID 1, and the environment and keepalive/run-at-load
settings were unchanged. This verifies launchd restart and authenticated
reconnection of the resident agent, not merely continued service by the old
process.

A fresh Recovery helper started at `2026-10-20T04:58:08Z`, again logging no
temporary bootstrap share. Authenticated agent status was observed at
`04:58:59Z`, before terminal proof at `04:59:00Z`. The new boot generation was
`14b6c614-f7e0-409d-b161-be2499fc6845`. The resident agent was PID 54 with parent
PID 1; its signed executable digest, launchd flags and environment, root asset
modes, and retained token matched the first boot. SIP remained enabled.

These observations establish automatic resident-agent startup across two
Recovery boots and recovery from TERM on the tested 26.6.2 (`25G83`) image.
They do not extend the agent beyond its Recovery terminal authority or qualify
other guest builds, update retention, or a production installation workflow.
The evidence summary is archived at
[evidence/EmbeddedAgent-2026-10-20/resident-recovery-lab.md](<~/Library/Application Support/pomme/Research/RecoveryBoot-2026-10-18/evidence/EmbeddedAgent-2026-10-20/resident-recovery-lab.md>).
The assigned clone was deleted with `credentialsRetained:false`; the final VM
list was empty. Both protected templates remained present, 40 GB,
unprovisioned, and `securityDisabled:false`. Filesystem artifact cleanup also completed: the assignment directory
`/private/tmp/pomme-recovery-embed26-20261020a` and both exact debug screenshot
directories were verified absent. The companion `terminal-output.txt` is
preserved beside the evidence summary. Token contents were never printed or
included in evidence.

After verifying the installed runner still matched the experimental digest,
the parent restored the prior signed runner with SHA-256
`4ec979c49db1d6854edf15072e8528f12e6588054a52d5150be3cd832776c9d6`.
Signature, identity, Hardened Runtime, designated requirement, and entitlements
were verified. No Pomme commands ran after restoration. The experimental
`994b4286e75561ef60cd1fd4edfda5a0cda760c51e55169cdf42b7f7c0a441a8` build
remains archived. See the phase's
[runner-restoration.json](<~/Library/Application Support/pomme/Research/RecoveryBoot-2026-10-18/EmbeddedAgent-2026-10-20/runner-restoration.json>).


## Offline preparation before the first guest boot

The research worktree now implements an offline staging checkpoint immediately
after the install effect. Its first-boot live result is now verified: the
embedded resident agent authenticated before any exec or UI request. This is a
separate experiment from the completed resident-agent boots above.

The hidden host triple `POMME_LAB_RECOVERY_OFFLINE_VM`,
`POMME_LAB_RECOVERY_OFFLINE_DIRECTORY`, and
`POMME_LAB_RECOVERY_OFFLINE_SESSION` is all-or-none. It requires the exact
nonempty disposable `pomme-agent-*` target, a canonical session UUID, and an
absolute, user-owned private staging directory without symlink components.
Admission precedes the install effect. After successful install or template
clone, the hook resolves the pinned signed agent artifact, obtains the VM's
UUID-scoped provisioning credential, and stages the binary, token, and a
secret-free manifest. It then throws an intentional checkpoint error so the
journal remains incomplete at installation rather than reporting creation
success or proceeding to normal/Recovery guest boot.

Staging preserves `reservation.toml`, rejects unexpected entries and symlinks,
and allows reentry only when existing outputs match exactly. The binary is
mode `0555`, token `0400`, and manifest `0600`. The manifest records target,
VM UUID, session UUID, disk path, and executable digest, never token contents.
Credential access remains in the signed CLI; no journal rewriting or public
CLI flag was added.

The offline triple controls host preparation. The separate resident pair
`POMME_LAB_RECOVERY_RESIDENT_VM` and `POMME_LAB_RECOVERY_RESIDENT_SESSION`
still controls actual Recovery runtime admission and the embedded guest's
identity. The strict resident parser now accepts either the original complete
image executable/token pair or the complete pair under
`/var/run/pomme-recovery-agent`; mixed pairs are rejected.

The staged `/bin/sh` wrapper is intended to run as root from
`/pomme-recovery-payload/autostart.sh`. It checks for symlinks, verifies payload
SHA-256 with Recovery's `/sbin/sha256 -q`, copies the immutable image payload
into a private root-owned `/var/run/pomme-recovery-agent` directory, sets binary
and token permissions, verifies the staged binary, and execs the real Recovery
agent with exact digest and VM/session arguments. This separates host-side
image copying from guest-side root ownership. The generated plist replaces
the existing `com.apple.DumpPanicRecoveryOS` job in place, retaining its label,
`recoveryos`/`diagnostics` boot-mode filter, and false pressured-exit/transaction
settings, with the tested keepalive/run-at-load lifecycle settings and both
resident environment values. It does not rely on discovery of a new job label.

The canonical signed gate passed for source `e2b1d1f-dirty`, runner SHA-256
`a94cb03bf10dcb438560973f884512eee589be4864ca8e18376de5e284c62274`.
Five focused native suites passed with 62 case records. All 211 CLI contract
checks passed on the preceding build with identical production source; the
subsequent change only corrected the test staging fixture to use literal
`/private/tmp` rather than a Foundation-normalized path containing an ancestor
symlink. These checks preceded the successful first-boot live result below. Terminal/launchd proof, TERM recovery, and second-boot authentication also
passed. The clone has been deleted and exact filesystem cleanup completed.


### Offline first-boot authentication

The exact disposable clone `pomme-agent-recovery-offline26-20261020a`, UUID
`35110c4c-7bca-433f-9da4-6c5b1ca60037`, used a 40 GB disk and 4 GB RAM with lab
session `1faca51e-ab1d-48c5-af71-f54251d4c042`. The checkpoint left
`helperRunning:false` before any guest boot. The host attached only this
clone's raw disk, copied BaseSystem, and cleared the copy's APFS role from
SYSTEM to NONE without sudo. The existing plist was changed in place while
preserving inode `1152921500311942498`.

Payload permissions and hashes were verified, then the image was converted to
UDZO and verified again through a fresh read-only attachment. The final backing
image SHA-256 was
`379b524e1d7eb4f3084806901e365ed11d53df3139c22d0982c88f6e1b7bda4b`.
All host attachments were detached before the clone's first-ever Recovery boot,
which enabled only the resident environment pair.

At 22:48 PDT on October 19, 2026, Recovery protocol 1 was connected and
authenticated before any exec or UI request. No UI interaction had occurred at
all in this new clone. This verifies offline preparation followed by automatic
first-boot authentication for the tested 26.6.2 (`25G83`) template clone.
Terminal root/launchd proof, TERM recovery, and second-boot verification also
passed, as detailed below. Normal durable creation remains intentionally incomplete;
this does not qualify fresh-IPSW creation, macOS 27, or a production workflow.


### Offline restart, repeat boot, and cleanup

The first terminal proof found the resident agent at PID 54 with parent PID 1.
Its `/var/run/pomme-recovery-agent` stage was root-owned: directory `0700`,
executable `0555`, and token `0400`. The executable matched approved SHA-256
`a94cb03bf10dcb438560973f884512eee589be4864ca8e18376de5e284c62274`.
Launchd showed RunAtLoad, KeepAlive, Interactive process type, and five-second
minimum runtime. SIP was enabled while the root had no specific APFS role and
a broken seal.

After TERM was acknowledged, status reauthenticated before the next exec.
Launchd reported two runs, last terminating signal 15, and replacement PID 270
with parent PID 1 and the same flags and environment. A fresh second Recovery
boot also authenticated before terminal access, then confirmed PID 54/parent
PID 1, the pinned digest, root-owned runtime modes, launchd settings, and SIP
enabled. No UI navigation occurred in this experiment. These results verify
host-only preparation before the first boot, automatic startup on two Recovery
boots, and supervised restart of the narrow Recovery terminal agent.

The [offline lab evidence summary](<~/Library/Application Support/pomme/Research/RecoveryBoot-2026-10-18/evidence/OfflineRecovery-2026-10-20/offline-recovery-lab.md>)
records the observations without token contents. The exact clone was deleted
with `credentialsRetained:false`, the final VM list was empty, and both
protected 40 GB templates remained unprovisioned with `securityDisabled:false`.
Exact filesystem artifact cleanup completed. Assigned staging files, including
the token and reservation, shadow, prepared UDZO, and working image were
individually removed, followed by the empty staging, image-work, and root
directories. `/private/tmp/pomme-recovery-offline26-20261020a` was verified absent,
and `hdiutil info` showed no matching attachment. The companion
[terminal-output.txt](<~/Library/Application Support/pomme/Research/RecoveryBoot-2026-10-18/evidence/OfflineRecovery-2026-10-20/terminal-output.txt>)
is preserved beside the evidence summary.

The prior signed runner, SHA-256
`4ec979c49db1d6854edf15072e8528f12e6588054a52d5150be3cd832776c9d6`, was restored
with signature, identity, Hardened Runtime, entitlements, and designated
requirement verified. See
[runner-restoration.json](<~/Library/Application Support/pomme/Research/RecoveryBoot-2026-10-18/OfflineRecovery-2026-10-20/runner-restoration.json>).
No further Pomme commands or tests ran after restoration. This remains a
research prototype for a 26.6.2 (`25G83`) template clone, with deliberately
incomplete durable creation and a broken APFS seal despite SIP being enabled;
fresh-IPSW creation, macOS 27, and production qualification remain untested.
