# Files that remain accessible in Recovery

Research date: October 18, 2026. Pomme source: `e2b1d1fe34d1b449c5828f4db45d626d0179bd7f`.

The `POMME_LAB_*` hooks that this note uses were removed from the CLI on
October 20, 2026. The sources that contained them are retained under the
evidence root in
`ExperimentalCreation-2026-10-20/pre-review-fixes-snapshot/`.

Persistent files can be made accessible while Recovery runs. The strongest
existing path in Pomme is the installed macOS Data volume. A persistent VirtioFS
share or a separate virtual disk would give Recovery files independent of that
volume. None of these requires embedding files in Apple's BaseSystem image.

The live follow-up below confirmed that a marker folder on the backing APFS
Recovery volume survives two Recovery reboots on macOS 26.6.2. It is available
automatically at `/private/tmp/Recovery`. That volume is distinct from the
BaseSystem filesystem mounted at `/`. Preservation through OS updates and the
same behavior on macOS 27 remain untested.

The follow-up [boot and custom-payload investigation](RecoveryBootInjection-2026-10-18.md)
has now booted a modified BaseSystem with its APFS role cleared to NONE on
26.6.2, confirmed a unique marker at `/`, and observed SIP still enabled.
`diskutil` reported the live root with no specific role and `Sealed: Broken`,
despite `mount` printing `sealed`. A newly added launchd job was present at the
live root but was not discovered and produced no output. Replacing only the
arguments of the existing `com.apple.DumpPanicRecoveryOS` job did execute the
custom script automatically at boot, with parent PID 1 and exit status zero.
A second reboot repeated that execution without further image edits or manual
job bootstrap. The disposable clone was deleted and both protected templates
remained intact. A bounded resident Pomme Recovery mode is now implemented
and has authenticated automatically from an embedded Recovery image before
any UI or terminal request. TERM/reconnect and automatic startup on a second
Recovery boot also passed for 26.6.2 (`25G83`), with Recovery terminal authority. macOS 27 behavior and update retention remain unverified. This later result extends the
original backing-volume persistence experiment recorded below.

## Scope and method

The initial static investigation used `ipsw` 3.1.734 and Hopper on local Apple
restore images and the host's Virtualization framework. BaseSystem copies were
extracted, decrypted, and mounted read-only. Guest executables were inspected,
never run on the host. That initial pass changed no Pomme executable, VM, template,
credential, or security setting. The later live experiment is recorded
separately below; its result applies to the guest version actually tested.

| Source | Build | VM identity | BaseSystem archive |
| --- | --- | --- | --- |
| macOS 26.6.2 IPSW | `25G83` | `vma2macosap` | `022-22048-093.dmg.aea` |
| macOS 27.0.1 IPSW | `26A434` | `vma2macosap` | `022-20292-678.dmg.aea` |
| Host Virtualization framework | macOS 27.0, `26A428` | arm64e dyld cache | Not applicable |

The macOS 27 image inspected here is 27.0.1, not the protected 27.0 template.

## Why ordinary Recovery paths do not persist

Both images contain `/usr/libexec/rc.temporaryDataVolume.sh`. Its relevant
startup path is identical in the two builds:

- Lines 43–49 unmount previous tmpfs mounts and create a fresh tmpfs filesystem
  at `/System/Volumes/Data`.
- Line 51 copies `/System/Library/Templates/Data` into that temporary filesystem.
- Line 67 mounts another tmpfs filesystem at `/Volumes`.
- Lines 69–72 describe and invoke `prebootensurer`, which copies Recovery boot
  objects into a temporary Preboot filesystem.

The template's `/private/etc/rc.cdrom.sh` also remounts `/` read-only at line 16.
Therefore, Recovery's writable Data filesystem is not the installed macOS Data
volume. Files written into its `/var`, temporary directories, or unmounted
directories under `/Volumes` are not durable. A real disk or host share mounted
under `/Volumes` has its own backing storage and is a different case.

Changing `bs_data_size` changes temporary capacity; it does not add persistence.

## The physical Recovery volume has a separate mount path

Static disassembly of 27.0.1 `prebootensurer` found code that resolves an APFS
Recovery volume by role and boot identity, then mounts it at
`/private/tmp/Recovery`. The path string is at `0x1000051e4`; the relevant mount
flow is at `0x100002684` through `0x100002708`. The code includes a promoted-image
path and a direct-mount fallback. This establishes a concrete path to investigate,
not proof that every VM Recovery boot reaches it or that the mount is writable.

The helper at `0x1000029fc` creates the temporary Preboot filesystem and copies
the source tree recursively using FTS and `copyfile`. It has explicit path
filters and `FTS_SKIP` branches. This is a broad filtered copy, not just a
whitelist of individual boot files; the exact filters active for the Recovery
invocation were not fully resolved.

These static findings made a dedicated payload directory on the backing
Recovery volume a plausible experiment. The live follow-up verified both access
at the physical-volume mount and inclusion in the temporary copy on 26.6.2.
Writing only to the temporary Preboot copy would not make the files persistent.

The separate `bs-data-tasks` executable also contains a path that mounts the
installed Data volume at `/Volumes/Data`, including locked-volume handling.
Pomme's own resolver discovers and validates the actual mount instead of
assuming this fixed name.

## Options for Pomme

| Option | Evidence and limitation | Assessment |
| --- | --- | --- |
| Store files on installed macOS Data | Pomme already identifies and mounts the System/Data volume group from Recovery and writes its installed agent there. An encrypted, locked volume would need unlocking. Access depends on that volume remaining intact. | First option for files that belong to the VM. |
| Keep a host directory shared through VirtioFS | Both Recovery images contain `mount_virtiofs`. Pomme already uses a read-only VirtioFS mount to deliver its Recovery launcher. Current staging is deliberately temporary. | Smallest extension for host-maintained tools and payloads. Reattach and mount it on each Recovery boot. |
| Attach a separate persistent disk image | Apple exposes virtual block devices backed by disk-image files. Pomme currently configures one disk. Recovery enumeration and mounting of a second disk have not been tested here. | Strong candidate when files must remain available despite problems with the installed Data volume. |
| Add a separate APFS volume to the guest disk | A plausible persistent storage location without another virtual device. Not tested here; adds volume selection and lifecycle work. | Candidate if everything must travel inside the existing `Disk.img`. |
| Place files beside BaseSystem on the physical Recovery volume | A marker folder survived two Recovery reboots on 26.6.2 and was available automatically at `/private/tmp/Recovery`. Update retention and macOS 27 remain unverified. | Verified for the tested reboot sequence; a useful basis for further payload work. |
| Rebuild BaseSystem with custom files | A role-NONE copy booted through the standard Recovery direct-image path on 26.6.2 and exposed a unique root marker with SIP enabled. The live APFS seal was broken. | Modified-image boot is verified for this disposable test. Existing-job argument replacement also ran a custom script automatically. Automatic execution repeated on a second boot. A full agent, other builds, and update retention remain unverified. See the follow-up investigation. |

Apple documents [directory sharing](https://developer.apple.com/documentation/virtualization/shared-directories),
[virtual block devices](https://developer.apple.com/documentation/virtualization/vzvirtioblockdeviceconfiguration),
and the [Recovery start option](https://developer.apple.com/documentation/virtualization/vzmacosvirtualmachinestartoptions).
Those APIs alone do not promise automatic mounting in Recovery. Apple's
[LocalPolicy description](https://support.apple.com/en-ca/guide/security/secc745a0845/web)
also explains pairing between macOS and recoveryOS; it is not a guarantee that
arbitrary adjacent files will be retained. Asahi's original
[partition-layout research](https://asahilinux.org/docs/platform/stock-partition-layout/)
provides useful context for the distinction between Recovery volumes and their
BaseSystem images, but is not a test of these Pomme guests.

Relevant source locations:

- `Sources/PommeCLI/GuestInternal/PommeRecoveryDataVolume.swift:38`: selects and
  mounts the installed Data volume, then validates its mount under `/Volumes`.
- `Sources/PommeCLI/GuestInternal/PommeAgentInstall.swift:208`: uses the mounted
  Data volume for persistent agent installation.
- `Sources/PommeCLI/Security/PommeRecoveryVirtioFSBootstrap.swift:151`: probes
  and mounts a read-only VirtioFS share, then copies the temporary launcher.
- `Sources/PommeCLI/VM/PommeRecoveryTerminalAdmission.swift:358`: clears the
  bootstrap share and removes host staging after authentication.
- `Sources/PommeCLI/CLI/PommeCore.swift:4699`: configures `storageDevices = [block]`.
- `Sources/PommeCLI/GuestInternal/PommeAgent.swift:98`: Recovery capabilities
  omit the persistent agent's generic file-transfer operations.

These are implementation findings, not a claim that Pomme currently has a public
persistent Recovery-files feature. Availability of files also does not imply
automatic execution of an agent or script after a Recovery boot.

## Apple automation hooks found with Hopper

Both images contain `automation_trampoline`, `attach_automation_image`,
`create_automation_image_overlay`, and a launch daemon that runs the trampoline
at load. The helpers include references to automation bundles, image overlays,
and `etc/rc.automation.d`.

Hopper analysis of the 27.0.1 trampoline establishes a security gate before
bundle loading:

- The entrypoint starts at `0x100001898`. The code parses the
  `com.apple.automation` boot argument; the small parser callback is at
  `0x100003dbc`.
- In BaseSystem, the gate reads `internal-use-only-unit` from
  `IODeviceTree:/chosen` at `0x100001c8c` onward.
- The `--insecure` fallback at `0x100001d3c` checks
  `os_variant_has_internal_content` and
  `os_variant_allows_internal_security_policies`.
- The rejection path at `0x100001d6c` reports that automation is not allowed by
  security policies.

This is evidence of Apple's internal automation infrastructure, not an ordinary
VM extension point. The 26.6.2 binary contains the same relevant gate strings;
its control flow was not separately decompiled. No attempt was made to change
these conditions, modify AMFI, or run an automation bundle.

The host framework also contains `base-system-path`, but its inspected reference
at `0x22611fcb4` is inside `variable_in_system_list`, a string-classification
function. It does not establish a custom Recovery-image or persistent-overlay
API. The inspected `VZMacOSVirtualMachineStartOptions` interface exposes the
Recovery boot selection, with no discovered payload-path option.

## Reproduce the static inspection

Use a new temporary output directory. For the 27.0.1 image, the essential
commands are:

```sh
rtk proxy ipsw extract --pattern '^022-20292-678.dmg.aea$' --flat \
  --output /absolute/research-dir /absolute/UniversalMac_27.0.1_26A434_Restore.ipsw
rtk proxy ipsw fw aea /absolute/research-dir/26A434__MacOS/022-20292-678.dmg.aea \
  --output /absolute/research-dir
rtk proxy hdiutil attach -readonly -nobrowse \
  -mountpoint /absolute/research-dir/recovery27 \
  /absolute/research-dir/022-20292-678.dmg
```

`ipsw --flat` still creates the build directory shown above. Copy the trampoline
out of the mounted image before loading it with the Hopper skill's loader script.
Detach the extracted image after inspection. The host reports `hdiutil attach`
as deprecated, although these read-only mounts succeeded.

The inspected 27.0.1 `automation_trampoline` SHA-256 is
`2c53239fe81c8b96d9cd7926b7693f23a3d1064823d9a93594c311af93dfc709`.

## Live marker experiment

The marker survived two complete stop/start cycles into Recovery. Both boots
mounted the backing volume automatically; no manual mount, remount, SIP or AMFI
change, boot-policy change, or Apple boot-file replacement was needed.

The test used a new clone named `pomme-agent-recovery-marker26-20261018a`, UUID
`4e43fb14-dc12-4672-aeb7-67c851ecd5af`, from the protected
`pomme-agent-ownerloop-base26-20260922a` template. The guest was macOS 26.6.2
(`25G83`) with a 40 GB disk and 4 GB RAM throughout the experiment. The source
template was not used as a live VM.

The canonical signed Release build/install passed before testing. Every CLI
invocation used `~/.local/bin/pomme`, version `0.2.3 (e2b1d1f)`, with
SHA-256 `5efd00934c7dd35f27f2d4751df27d64f1dadb6bbf8703c8a7bf4df3013654ee`.
The installed executable remained unchanged across the checks. Concurrent
source edits from another task were not built into this experiment.

The backing volume was:

- Device: `disk3s3`, APFS role `Recovery`, internal and writable.
- Volume UUID: `B1BDD924-A320-4D42-ADF1-2D6080C5F345`, unchanged across all checks.
- Reported mount: `/System/Volumes/Data/private/tmp/Recovery`, accessible through
  `/private/tmp/Recovery` in the Recovery shell.
- Separate from the sealed BaseSystem root observed at `disk5s1`.

The only custom Recovery-volume content was a dedicated marker folder outside
the Apple boot-object directories:

```text
/private/tmp/Recovery/pomme-marker-20261018a/marker.txt
```

The file contained the following nonsecret marker followed by one newline:

```text
POMME_RECOVERY_MARKER_20261019_C1B789DD-DD9B-4966-9EC9-B57C65C253B5
```

The guest shell created the folder with `mkdir`, then wrote the marker using
`printf '%s\n' "$marker" > /private/tmp/Recovery/pomme-marker-20261018a/marker.txt`.
The volume check used `diskutil info /private/tmp/Recovery`, which reported
`Volume Read-Only: No`.

Recovery's `/sbin/sha256 -q` measured the actual file in each boot. All three
digests matched the independent host calculation:

```text
79b4944941251c77709df6c9adb65fdaae668527bf84d9c12db48dc7253ad412
```

| Check | Pomme Recovery boot generation | Marker and hash | Temporary Preboot-root copy |
| --- | --- | --- | --- |
| Initial write and readback | `e70dac07-aeda-4185-8aa4-32bd82561d12` | Matched | Absent |
| First Recovery reboot | `ea3ff777-7f57-4e85-bedb-9bb9e001334c` | Matched | Present |
| Second Recovery reboot | `a84094d4-9e0e-40c4-8fe0-b1d8f506dd71` | Matched | Present |

The boot generations are Pomme runtime identifiers, not guest kernel boot UUIDs.

The checks used detached Recovery PTY commands and captured each transcript
before stopping the VM. The reboots used `pomme stop` followed by
`pomme start --mode recovery`; Recovery required Pomme's forced stop fallback.
The marker was not recreated between checks. Its appearance in the temporary
Preboot copy after reboot is consistent with the startup copying behavior found
in the static investigation.

The first attempted source was the macOS 27 template. Creation failed before
cloning because the template's recorded 27.0 (`26A428`) IPSW was absent.
`loadProvisioningInput` checks that historical image before taking the template
clone branch. An explicit 40 GB retry failed for the same reason; disk size was
not the cause. The macOS 26 template's recorded IPSW was available, so the live
experiment used that template instead. Neither template was changed to work
around this issue.

After the checks, the disposable clones were deleted through Pomme's ordinary
deletion path, with `credentialsRetained: false`. The final VM list was empty.
Both protected templates remained unchanged and unprovisioned. Test screenshot
directories and temporary lab artifacts were removed; the marker disappeared
with the disposable disk. This note retains the experiment's compact evidence.

## Agent and launchd feasibility

The marker result supports storing a signed Pomme executable and a launchd plist
in a dedicated directory on the backing Recovery volume. It does not establish
that the executable can run from that location or that launchd discovers the
plist after reboot. Neither was tested in the marker experiment.

A read-only follow-up inspected the 26.6.2 (`25G83`) BaseSystem with `ipsw`.
The extracted `/sbin/launchd` SHA-256 was
`fe9a1562d360e15c86937153586ca8778ee72bd95de423415ec780ebde9c0102`.
The filesystem and embedded launchd configuration showed:

- `/Library` is a symlink to `System/Volumes/Data/Library`. Its
  `LaunchDaemons` directory comes from the empty
  `/System/Library/Templates/Data/Library/LaunchDaemons` directory. The startup
  script recreates that Data filesystem as tmpfs on each Recovery boot.
- The embedded configuration's `Bootstrap.Paths` lists
  `/System/Library/LaunchDaemons`, `/Library/Apple/System/Library/LaunchDaemons`,
  the OS and App Cryptex `System/Library/LaunchDaemons` directories, and
  `/private/var/db/ManagedConfigurationFiles/BackgroundTaskServices/LaunchDaemons`.
  It does not list `/private/tmp/Recovery` or arbitrary subdirectories there.
- The embedded boot tasks include `rc.temporaryDataVolume`, marked to run in
  BaseSystem. The inspected startup scripts do not load a custom Recovery-volume
  plist. Apple's automation trampoline remains subject to the gates described
  above.

This is evidence against assuming automatic loading from our marker directory,
not proof that every possible startup extension has been ruled out. Apple's
[launchd startup guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
also distinguishes the standard daemon directories from explicit loading.
Copying a `Library/LaunchDaemons` tree onto a separate mounted volume does not
make it the running system's `/Library/LaunchDaemons`.

A practical prototype could retain the signed binary and plist on the backing
volume, then use Pomme's existing Recovery bootstrap once per boot to validate
them, establish fresh authentication, and explicitly load the job with
`launchctl bootstrap system <plist>`. Launchd could then supervise it during that
boot. `RunAtLoad` starts a job when loaded; `KeepAlive` supervises a loaded job.
Neither setting supplies the missing step that loads its plist after reboot.
This host-assisted design would still require Pomme to load the job on each
Recovery boot. The modified-image experiment below demonstrates a different
startup path by changing an existing job's arguments. Manual launchd loading
in Recovery remains untested in this investigation.

Pomme would also need a separate service lifecycle:

- `PommeAgentInstall.swift` writes the normal agent, its token, and its plist
  beneath the resolved installed macOS Data volume. Its plist uses `--role normal`;
  its custom-path checks do not allow the backing Recovery mount.
- `PommeAgentDaemon.swift` binds Recovery operations to a VM, session, request,
  and expiration. It consumes and unlinks the temporary credential file. The
  terminal variant permits reconnection within a boot but exposes terminal
  capabilities, not a general persistent Recovery service. The current Recovery
  role also does not retry an unavailable host listener. A launchd restart could
  therefore find its token already consumed and its workspace removed. A
  supervised service needs authentication and startup retry behavior that remain
  valid across process restarts within the boot.
- `PommeRecoveryVirtioFSBootstrap.swift` already verifies the executable's
  signature and digest. `PommeNormalBootstrapInstaller.swift` already uses
  `launchctl bootstrap`, `kickstart`, and `print` for normal macOS. These are
  reusable mechanisms, not an existing persistent Recovery implementation.

That read-only feasibility follow-up did not operate a new VM. The later
[custom-image investigation](RecoveryBootInjection-2026-10-18.md) has since
booted a role-NONE image with a custom root marker. A one-shot `RunAtLoad` job
was inserted into that image's startup paths. Its first boot confirmed the
new plist and script hashes at `/`, but the service was not found and its output
marker was absent. No manual launchd bootstrap was used. A cached launchd
configuration is a hypothesis, not an established explanation. The subsequent
user-requested test changed only the existing `com.apple.DumpPanicRecoveryOS`
job's `ProgramArguments` to invoke the marker script, retaining its label and
other keys. Its first boot succeeded: the custom nonce was written with parent
PID 1, and launchd reported `/bin/sh`, the custom script argument, one run, and
exit status zero. SIP remained enabled and the launchd cache hash was unchanged.
This demonstrates automatic execution through that existing job without manual
bootstrap; the full cache/discovery mechanism remains unresolved. A second
reboot of the unchanged image repeated execution with a fresh output timestamp,
parent PID 1, one run, and exit status zero; SIP remained enabled. No manual
bootstrap occurred between boots. The exact disposable clone was deleted with
`credentialsRetained:false`, its owned temporary/debug files were removed, and
both protected 40 GB unprovisioned templates were verified intact. These results
proved building blocks for a resident service at the end of the marker-only
phase. The later embedded-agent result below extends that evidence.

## Remaining checks

This proves marker-file persistence and automatic availability for the tested
26.6.2 Recovery reboot sequence. It does not establish retention through an OS
update, disk erase, restore, or Recovery repair. A normal macOS boot between
Recovery sessions, macOS 27, large payloads, executables, and automatic execution
were not tested. A persistent executable
would still need its own signature, launch, and authentication validation.

Any additional live test must use a separate disposable clone and the signed
Release install gate. Preserve both protected templates.


## Resident-agent implementation follow-up

The research worktree now has an explicit resident Recovery lab mode. Both
host and guest require `POMME_LAB_RECOVERY_RESIDENT_VM` and
`POMME_LAB_RECOVERY_RESIDENT_SESSION`, with an exact disposable VM name and
canonical session UUID. The guest additionally requires the hidden
`--resident-recovery-lab` argument, fixed executable and token paths under
`/pomme-recovery-agent`, a matching executable digest and VM/session bindings,
Recovery role, and port `505053`. It rejects request-file, operation, and expiry
arguments. The host uses the VM's existing credential and skips the ordinary
temporary bootstrap share and UI admission for a fresh resident runtime.

The agent preserves its lab token, retries the host listener, and remains
restricted to Recovery terminal authority. It does not run normal macOS
maintenance. Standard request-bound Recovery behavior remains unchanged. The
embedded job retains the existing Recovery label and filters while using normal
agent lifecycle settings: `RunAtLoad`, `KeepAlive`, a five-second throttle, and
`Interactive` process type.

The canonical signed gate passed for runner SHA-256
`994b4286e75561ef60cd1fd4edfda5a0cda760c51e55169cdf42b7f7c0a441a8`, source
`e2b1d1f-dirty`, and focused native tests across four suites passed. Actual embedded-agent startup and host authentication are now verified before
any UI or terminal request. TERM/reconnect supervision and a second Recovery
boot also passed; these remain research-only results for 26.6.2 (`25G83`). See the
[boot investigation](RecoveryBootInjection-2026-10-18.md) for the precise gates
and argument shape.


Resident-image preparation also requires ownership to be enabled on the
verified copied mount. This run initially reported UID/GID 99 despite `chown`;
`diskutil enableOwnership <copied-mount>` and reapplying ownership yielded
`root:wheel`, directory mode `0700`, executable `0555`, and token `0400`.
The role-clearing target was derived from the copied attachment rather than
hardcoded. Final conversion and read-only verification completed before the successful
initial resident boot. All 211 CLI contract checks passed with the
exact signed runner above on October 19, 2026 Pacific (October 20 UTC).


The first embedded-agent boot on `pomme-agent-recovery-embed26-20261020a` began
at `2026-10-20T04:54:51Z`. Status reported authenticated Recovery protocol 1
before UI or exec access, with no temporary bootstrap share. The first resident
terminal confirmed `/pomme-recovery-agent/pomme` running as PID 54 with parent
PID 1, launchd keepalive/run-at-load settings, and a five-second minimum runtime.
The signed executable digest, root ownership and modes, retained token, and
fixed VM/session binding matched the prepared image. SIP remained enabled;
the role-NONE root had a broken seal. The image digest and detailed identities
are recorded in the boot investigation. TERM then caused launchd to replace
PID 54 with PID 251, with two runs and terminating signal 15; the new process
authenticated before another exec request. A second Recovery boot started at
`2026-10-20T04:58:08Z` and authenticated at `04:58:59Z`, before terminal proof.
Its boot generation was `14b6c614-f7e0-409d-b161-be2499fc6845`; PID 54 again had
parent PID 1, with the same signed digest, flags, environment, asset modes, and
retained token. SIP remained enabled. This demonstrates two-boot automatic
startup and TERM recovery under narrow Recovery terminal authority.

The [resident lab evidence summary](<~/Library/Application Support/pomme/Research/RecoveryBoot-2026-10-18/evidence/EmbeddedAgent-2026-10-20/resident-recovery-lab.md>)
is archived. The assigned clone was deleted with `credentialsRetained:false`,
the final VM list was empty, and both protected 40 GB templates remained
unprovisioned with `securityDisabled:false`. Filesystem artifact cleanup also completed: the assignment directory
`/private/tmp/pomme-recovery-embed26-20261020a` and both exact debug screenshot
directories were verified absent. Companion `terminal-output.txt` is preserved
beside the evidence summary. Token contents were never printed or included in
evidence.

The shared runner was conditionally restored from experimental digest `994b…`
to prior SHA-256
`4ec979c49db1d6854edf15072e8528f12e6588054a52d5150be3cd832776c9d6`, with its
signature, identity, Hardened Runtime, designated requirement, and entitlements
verified. No Pomme commands ran after restoration; the experimental build remains
archived. The detailed report links the restoration record.


## Offline preparation follow-up

A new research-only checkpoint stages the pinned signed agent and VM-scoped
credential immediately after installation or cloning, before the provisioning
workflow's first normal/Recovery guest boot. The hidden all-or-none offline
triple selects the exact disposable VM, private nonsymlink staging directory,
and canonical session. Successful staging deliberately throws an error so the
journal records an incomplete install effect, not completed creation. It
preserves reservations and rejects mismatched existing files; its manifest
contains no token.

The offline gate is distinct from the resident VM/session pair used at boot.
An image wrapper verifies payload hashes and creates the root-owned executable
and token under `/var/run/pomme-recovery-agent` before execing the narrow
Recovery agent. The plist replaces the existing Recovery job in place, keeping
its label and boot filters. The strict guest gate accepts complete image or
runtime path pairs, never mixed paths. No public CLI interface was added.

The signed runner is SHA-256
`a94cb03bf10dcb438560973f884512eee589be4864ca8e18376de5e284c62274`, source
`e2b1d1f-dirty`. Five focused native suites passed with 62 case records, and
211 CLI contract checks passed on identical production source before a
test-only fixture correction. Offline preparation has now produced an
authenticated resident Recovery agent on the new clone's first-ever Recovery
boot, before any exec or UI request. TERM recovery and a second Recovery boot
also passed; this is separate from the earlier resident-agent boots. See the boot investigation's offline section for exact
environment names and staging behavior.


The offline clone `pomme-agent-recovery-offline26-20261020a` used 40 GB disk and
4 GB RAM. Its intentional checkpoint stopped before any boot. Host-only image
preparation cleared the copied BaseSystem role to NONE without sudo, preserved
the existing plist inode during replacement, and verified the converted image
read-only before detaching all host mounts. The final image digest and exact
VM/session identities are recorded in the boot investigation.

At 22:48 PDT on October 19, 2026, the first Recovery boot authenticated protocol
1 before any exec or UI request; the clone had received no UI interaction.
This verifies the offline first-boot path for the 26.6.2 (`25G83`) template
clone. Terminal/launchd proof, TERM recovery, and a second boot also passed.
The clone has been deleted and exact filesystem cleanup completed.
Durable creation remains intentionally incomplete, and fresh-IPSW or macOS 27
creation is not qualified by this result.


The offline terminal proof confirmed PID 54/parent PID 1 and root-owned runtime
files under `/var/run/pomme-recovery-agent`, with directory/binary/token modes
`0700`/`0555`/`0400` and the approved digest. TERM caused launchd to restart the
agent as PID 270/parent PID 1, with two runs and signal 15; status reauthenticated
before another exec. A fresh second Recovery boot authenticated before terminal
access and again showed PID 54/parent PID 1, the same digest, modes, and launchd
settings. SIP stayed enabled while the APFS root seal was broken. No UI
navigation occurred.

The [offline lab summary](<~/Library/Application Support/pomme/Research/RecoveryBoot-2026-10-18/evidence/OfflineRecovery-2026-10-20/offline-recovery-lab.md>)
preserves the evidence without token contents. The clone was deleted with
`credentialsRetained:false`, the final VM list was empty, and both protected
40 GB unprovisioned templates remained unchanged with `securityDisabled:false`.
Filesystem artifact cleanup completed: assigned staging files, including the
token, and image artifacts were individually removed, followed by their empty
directories. `/private/tmp/pomme-recovery-offline26-20261020a` was absent, with
no matching attachment in `hdiutil info`. Companion `terminal-output.txt` is
preserved beside the evidence summary. The prior signed `4ec979…c9d6`
runner was restored and its signing properties verified; no Pomme commands or
tests ran afterward. The boot investigation links the restoration record.
