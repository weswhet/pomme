# macOS 27 pomme VM: MDM enrolls but never sends TokenUpdate — October 14, 2026

Status: **LaunchDaemon workaround verified through MDM command acknowledgment
on a disposable macOS 27.0 guest.**
The original failing macOS 27.0 VM could not create the BAA reference key that
`apsd` needed. Its saved logs confirm failure to resolve system keybag handle -6. The skipped `keystore-init`
boot task is strongly supported as the underlying mechanism. A custom
LaunchDaemon running `applekeystored --init` with SIP disabled loaded the
system keychain and was followed by successful BAA identity acquisition.
Removing the job and cold-booting restored the BAA failure at the same SIP and
owner state. Reinstating the job in that same boot restored BAA identity again,
isolating the initializer's effect. NanoHUB received `TokenUpdate`, and the
guest acknowledged a pushed `DeviceInformation` command. After an explicit
cold stop/start with the job retained, initialization succeeded again and a
second pushed command was acknowledged. The repair has not been tested on 27.2.

## Implemented in Pomme

The LaunchDaemon workaround is now built into Pomme. The changes aren't
committed yet. They were verified live on 27.0 and 26.6.2 (see below).

- **Guest agent:** the persistent Pomme agent runs
  `/usr/libexec/applekeystored --init` once per boot
  (`Sources/PommeCLI/GuestInternal/PommeKeystoreInitMaintenance.swift`). It
  runs only when all of these hold:
  - The guest is macOS 27 or later.
  - `statfs("/")` reports `MNT_LOCAL` without `MNT_REMOVABLE`, which is
    launchd's own skip condition.
  - `security.mac.amfi.launch_constraints_enforced` isn't 1.
- **Boot receipt:** the agent writes it to
  `/private/var/db/pomme/keystore-init.json`, keyed by the boot session UUID,
  so a restarted agent never runs the initializer twice in one boot. The new
  read-only agent operation `keystore.init.status` reports it.
- **`pomme mdm`:** on a macOS 27 guest, `--final-security restore` re-enables
  AMFI but leaves SIP disabled. This is recorded in the schema 7 journal field
  `sipRetainedForPushIdentity`. The result reports `pushIdentity`
  (`prepared`, `skipped`, `failed`, `pending`, `agentUpdateRequired`,
  `unavailable`, or `notRequired`).
- **Warnings:**
  - `--dry-run` warns with `sipKeptForPushIdentity`.
  - `pomme sip enable` warns on an enrolled macOS 27 VM.

**Live verification, 2026-10-14** (signed build of `79ba5a1-dirty`, 4 GB
memory, 40 GB disk from the protected templates):

| Guest | `pomme mdm` result | Server and push |
| --- | --- | --- |
| `pomme-agent-pushfix27-20261014a`, 27.0 (26A428), UDID `AB4FAD05-3F06-5A31-BD55-A438FE0B92D4` | Succeeded on the first run, with the `sipKeptForPushIdentity` warning. `pushIdentity: prepared`, `sipRetainedForPushIdentity: true`, SIP disabled, AMFI enabled. | `TokenUpdate` at 21:25:03Z, 6 s after `Authenticate`. `DeviceInformation` was pushed and acknowledged within 21:28:15Z. After `pomme stop` and `pomme start`, the receipt showed `succeeded` for the new boot, and a second push was acknowledged within 21:29:23Z. |
| `pomme-agent-pushfix26-20261014a`, 26.6.2 (25G83), UDID `E478897A-445D-566A-826D-B3A09B59CEFF` | Succeeded. `pushIdentity: notRequired`, SIP and AMFI restored, receipt `skipped` / `unaffected-os`. | `TokenUpdate` arrived. A pushed `DeviceInformation` was acknowledged within 21:54:51Z. |

The 26 control first failed twice at `installRecoveryAgent` with
`recovery_session.cleanup_failed` (VZErrorDomain 4). The cause was
Virtualization.framework's limit of two concurrent macOS guests, because two
other VMs were running. After one of them stopped, the resumed command
succeeded. Pomme's error doesn't name that limit.

What remains is 27.2. On 27.2, the 2026-10-14 UI-enrollment test (build
26B5112a, SIP enabled) still skipped `keystore-init` and sent no `TokenUpdate`,
so Apple hasn't fixed it there. The repair hasn't been tested on 27.2 because
Pomme can't yet finish creating a 27.2 VM: automatic login is refused, and a
pre-release Terms screen isn't handled.

## Summary

A macOS 27.0 pomme VM enrolled in NanoHUB but never sent a `TokenUpdate`, so
the server cannot push to it. Inside the guest, `apsd` never obtained a system
push token. Its logs show repeated failures to create a Secure Enclave key
(`errKCInteractionNotAllowed`, -25308) and "Connected on 0 interfaces".

A macOS 26.6.2 VM, enrolled the same way against the same server minutes later,
sent `TokenUpdate` and acknowledged a pushed `DeviceInformation` command within
a second. The server, APNs certificate, public TLS and Tailscale path are
therefore working. The fault is on the macOS 27 guest side.

Before the initializer experiment, NanoHUB's history showed that none of the
six macOS 27 VMs enrolled against it from September 27 through October 14
sent `TokenUpdate`. Every macOS 26 and 15 VM did. The repaired experimental
guest below is the first verified macOS 27 success in this investigation.

**Next focus:** test the workaround on 27.2 and determine whether a narrower
security change can permit initialization. The user authorized guest security
changes for this experiment.

## Follow-up investigation

The saved logs establish the immediate failure: `apsd` cannot create its BAA
push-identity reference key, so it does not connect and has no public token for
`mdmclient` to send in `TokenUpdate`. The software keystore fails to resolve
system keybag handle -6 during that operation. This is earlier than MDM command
handling and does not require a server-side enrollment change to explain it.

The skipped `keystore-init` boot task is strongly supported as the explanation
for the missing system keybag: the embedded task configuration, launchd
condition, and software-keystore lookup agree with the saved runtime failure.
The live initializer experiment below now links restoration of the task's
effect to successful BAA identity acquisition and push-driven MDM operation.
The evidence does not establish that every macOS 27
installation is affected.

### Live initializer experiment

The disposable guest `pomme-agent-keystore-init-20261014a` was cloned from the
protected macOS 27 base template with a 40 GB disk and 4 GB memory, on the
internal drive. It runs macOS 27.0 build 26A428. The signed Pomme CLI was built
from current source at `79ba5a1` before testing. The protected template was not
modified. Wes separately reports that 27.2 still has the enrollment symptom;
this experiment does not yet establish its mechanism or repair on 27.2.

A temporary root LaunchDaemon, `com.pomme.lab.keystore-init-20261014a`, invokes
the original `/usr/libexec/applekeystored --init` with `RunAtLoad=true`. Its
plist is owned by `root:wheel` with mode `0644`.

| Phase | Observation |
| --- | --- |
| SIP enabled, empty boot arguments | The custom job was killed during spawn after 2 ms, with `OS_REASON_CODESIGNING` and an enforcing AMFI launch-constraint violation: `c[1]p[1]m[1]e[1]`, launch type 0. The initializer did not execute. Launching through a custom LaunchDaemon alone did not satisfy the constraint. |
| SIP disabled through Pomme's Recovery flow; AMFI boot arguments unchanged | The flow also created an owner. At the next boot, the custom job exited 0 and `security.mac.amfi.launch_constraints_enforced` reported 0. |
| Initializer execution, 12:43:45 PDT | `early_boot_init` ran; `AppleVPKeyStore` reported `cmd: 18, booted_from: 1, result: 0`; the initializer loaded the OD access token as the system keychain and returned 0. |
| BAA retry, 12:43:51 PDT | About six seconds later, `apsd` obtained BAA certificates and reported an identity available to connect. Earlier attempts in that same boot had failed with -25308 and no identity. |
| Cold boot without the custom job, 12:46:48–12:46:55 PDT | The plist was absent, with SIP and owner state unchanged. The built-in `keystore-init` task was skipped again. Despite a cached production BAA token, `apsd` repeatedly failed to obtain a BAA certificate and reported no identity. |
| Reinstall and bootstrap the identical job in that boot, 12:47:55–12:48:14 PDT | Without changing security settings or owner state and without rebooting, the initializer loaded the OD access token as the system keychain and exited 0. `apsd` then obtained BAA certificates and reported an available identity. |
| MDM enrollment, 19:58:55 UTC (12:58:55 PDT) | NanoHUB received two `Authenticate` messages and `TokenUpdate` for `E76628FD-90D5-5B00-991F-5C6F048BBFB5`, serial `ZXPJ3737GN`. The guest's `IOPlatformUUID` matched this UDID, and its profile status reported user-approved MDM enrollment against the expected server. |
| Pushed command, 20:02:52–20:02:53 UTC | NanoHUB accepted `DeviceInformation` command `pomme-keystore-init-20261014a-e2db24ad-2e9d-450f-8321-e992e6ea3dcc` with HTTP 200. The guest retrieved it in the same second and acknowledged it at 20:02:53. |
| Cold stop/start with the job retained, 13:03:42–13:03:44 PDT | `apsd` initially reported no identity. The job then loaded the OD access token, reported `booted_from: 1` and result 0, and exited 0. BAA identity became available again; MDM remained user approved. |
| Pushed command after that cold boot, 20:04:33 UTC | `DeviceInformation` command `pomme-keystore-init-20261014a-67f6183a-54d2-4e1c-98b3-a063a8ede1bd` was queued, retrieved, and acknowledged within the same second. |

The within-boot transition materially strengthens the proposed mechanism.
The first phase changed both SIP state and owner provisioning, but the
cold-boot control retained both and reproduced the failure without the job.
Cached credentials did not preserve a working identity across that boot. The
identical job repaired BAA acquisition in the failed boot without another
security, owner, or boot change. This isolates initialization as the effective
intervention for this guest. MDM enrollment used
`--force --final-security restore` and completed with SIP disabled, matching
the pre-enrollment experiment state. Launch-constraint enforcement reported 0,
and the custom job's last exit code was 0. The enrollment flow temporarily
changed AMFI settings, but the final active and configured boot arguments were
empty and the AMFI override was inactive (`amfiDisabled=false`). The subsequent
cold boot and second pushed-command acknowledgment verify the job's effect
across boots. The disposable VM is stopped and retained with the job
installed, SIP disabled, empty boot arguments, and approved MDM. Restoring SIP after
repair and long-term identity renewal have not been tested.

#### Tested LaunchDaemon configuration

This is a manual lab workaround, not an implemented Pomme feature. It requires
the tested guest's SIP-disabled state; the same job failed with SIP enabled.
The repair phases did not add an AMFI boot override. That observation does not
establish the state of every AMFI enforcement mechanism.

The guest file is
`/Library/LaunchDaemons/com.pomme.lab.keystore-init-20261014a.plist`, owned by
`root:wheel`, mode `0644`. Its tested contents are:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.pomme.lab.keystore-init-20261014a</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/libexec/applekeystored</string>
    <string>--init</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/var/tmp/pomme-keystore-init-20261014a.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/var/tmp/pomme-keystore-init-20261014a.stderr.log</string>
</dict>
</plist>
```

The same-boot repair loaded this file into launchd's system domain with
`launchctl bootstrap system /Library/LaunchDaemons/com.pomme.lab.keystore-init-20261014a.plist`.
The initializer exits after loading the keychain; `KeepAlive` is false. The
no-job cold-boot failure shows that one successful run did not permanently
repair the boot-time mapping in this guest.

Static analysis provides a possible explanation for the launch failure:
trust-cache category 1 can impose a self constraint requiring launch type 1
(`SYSTEM_SERVICE`), whereas the custom job logged type 0 (`NONE`). The absence
of embedded executable constraints therefore does not establish that the
executable is unconstrained. The inspected enforcement policy checks
`CSR_ALLOW_UNRESTRICTED_FS` (`csr_check(0x2)`); the generic
`amfi_enforce_launch_constraints=0` boot argument falls through to that policy
rather than independently forcing enforcement off. These are static findings,
not separate tested security configurations.

Sanitized text artifacts remain outside the repository in
`/private/tmp/pomme-agent-keystore-init-20261014a.UGmGQl/`:

| Artifact | Relevant evidence |
| --- | --- |
| `pomme-keystore-init-after-20261014a.txt` | Lines 2005–2009: enforcing launch constraint, code-signing exit, and 2 ms runtime. |
| `pomme-keystore-init-sip-only-20261014a.txt` | Line 39: job exit 0. Line 119: launch-constraint enforcement 0. |
| `pomme-keystore-init-sip-after-run-20261014a.txt` | Lines 78–92: BAA failure before initialization. Lines 105–110: successful system-keychain initialization. Lines 131–139: BAA success, available identity, and nonce signing. |
| `pomme-keystore-init-nojob-coldboot-20261014a.txt` | Line 24: built-in task skipped. Lines 37–74: repeated BAA failure and no identity after the cold boot without the job. |
| `pomme-keystore-init-sameboot-after-20261014a.txt` | Line 29: job exit 0. Lines 166–167: system-keychain initialization succeeds in the failed control boot. |
| `pomme-keystore-init-sameboot-settle-20261014a.txt` | Lines 5–10: BAA certificates obtained and identity available after the same-boot intervention. |
| `server-mdm-verification.txt` | Lines 1–3: matched guest authentication and `TokenUpdate`. Lines 4–8: first `DeviceInformation` push, retrieval, and acknowledgment. Lines 9–13: second push and acknowledgment after the cold boot. |
| `pomme-keystore-init-persistence-boot-20261014a.txt` | Lines 81–96: no identity before initialization. Lines 98–109: successful booted-volume mapping, initialization, and BAA identity after the cold stop/start. |
| `pomme-keystore-init-final-state-20261014a.txt` | Lines 32–35: SIP disabled, launch-constraint enforcement 0, and user-approved MDM. Line 74: job exit 0. |

### Confirmed observations

- On the original failing 27.0 guest, a clean boot with SIP and AMFI restored still showed
  `[Event: keystore-init] Skipping boot-task` and the push-identity failure.
- `AppleVPKeyStore` logs `cant get bagid -6 8`, followed by
  `_operation_ref_key_create = -2` and `e00002e2`. The corresponding `apsd`
  sequence uses the System Keychain, fails reference-key creation and BAA
  identity acquisition, and does not connect.
- The owner keybag (-501) installation succeeds (`make system … = 0`), and
  the bag later unlocks successfully. The -6 lookup still fails afterward. This is evidence against
  treating the failure as just a locked owner keybag; it does **not** mean that
  no keybags are registered.
- The 26.6.2 control maps a volume UUID to bag -5 with `booted_from: 1`, obtains
  BAA certificates, and sends `TokenUpdate`. Both versions can use the BAA path;
  the evidence does not establish that macOS 27 newly requires it.

| Candidate explanation | Current assessment |
| --- | --- |
| Missing system-keybag mapping blocks BAA reference-key creation | Supported by the saved failure sequence. |
| Skipping `keystore-init` causes that missing mapping | Supported by static evidence, no-job cold-boot regression, same-boot repair at unchanged SIP and owner state, and successful push-driven MDM after repair. |
| Owner keybag simply remains locked | Weakened by successful owner-bag unlock followed by another -6 failure. |
| SIP/AMFI must currently be disabled for the failure | Contradicted by the restored-security boot; a lasting effect of earlier changes has not been excluded by that observation alone. |
| Pomme provisioning or this template is the sole cause | Weakened by independent reports, but no local clean-install control has established this. |
| Every macOS 27 installation has the same failure | Not established. |

### Static inspection and workaround limits

Static inspection of launchd found a branch at
`0x100042444`–`0x100042494` that reads
`LimitLoadToBootingExternalVolume`, calls `statfs("/")`, and compares masked
flags (`0x1200`) with `0x1000`: `MNT_LOCAL` is `0x1000`, and
`MNT_REMOVABLE` is `0x200`. The extracted launchd binary embeds a
`keystore-init` task dictionary with
`LimitLoadToBootingExternalVolume=true`, `PerformAfterUserspaceReboot=true`, and
`ProgramArguments` invoking `applekeystored --init`. The guest logs that task
being skipped. The guest's exact `statfs` flags were not retained, and a macOS 26
launchd binary comparison has not established when this condition was added.

In `AppleVPKeyStore`, `_keybag_for_handle` at
`0xfffffe000897aa60`–`0xfffffe000897ab54` resolves -6 through
`_fv_get_booted_from_volume_uuid` and `_keybag_for_uuid_and_handle`.
`_refkey_bagid_generate` at `0xfffffe0008a06084`–`0xfffffe0008a06108` uses that
lookup for -6. This connects the failed system-handle lookup to the booted
volume mapping needed by reference-key creation.

In a VM, `DeviceIdentityIsSupported` (`dsc/DeviceIdentity`,
`0x1c7d1f998`) returns the result of `libavp_guest_has_host_key`.
`apsd`'s `albertIdentitySupported` negates device-identity support on its VM
branch. A VM that advertises the host key therefore selects BAA in the normal
provider path, even though creating its BAA reference key still depends on the
guest's keybag.

In `apsd`, the inspected methods include `albertIdentitySupported` at
`0x100024654`, `baaPushIdentityEnabled` at `0x100024690`, and
`forcedProviderDefault` at `0x100024984`. The latter reads
`APSForceIdentityProvider`, but its only identified callsite,
`sub_1000e1998`, belongs to the Multi provider path. The non-Multi selection at
`0x10005f4c4`–`0x10005f4e8` selects the certificate-manager or BAA provider
using `albertIdentitySupported`, not the BAA support flag. The same selection
appears at `0x1000d3cec`–`0x1000d3d18`. Turning a BAA flag off or setting the
force-provider preference alone is therefore **not an established workaround**.

The private Virtualization selector `_setStrongIdentityEnabled:` is **not a
viable direct workaround in the current Pomme build**. The setter on
`VZMacPlatformConfiguration` checks entitlement bit 1 at `0x225fd2c54`–
`0x225fd2c60`; without it, the path reaches `Base::assertion_trap` and `brk`
at `0x225fd2ca0`–`0x225fd2ca4`. `VirtualizationEntitlements::from_connection`
sets bits 0 and 1 for `com.apple.private.virtualization` at
`0x22616bf80`–`0x22616bf94`, whereas the standard
`com.apple.security.virtualization` entitlement sets only bit 0 at
`0x22616bf98`–`0x22616bfa8`. Pomme has only the standard entitlement. Calling
the setter would hit this guard; adding private entitlements is not a proposed
fix. Its downstream effect on successful push registration remains untested.

### Independent report

A [firsthand Apple Developer Forums report](https://developer.apple.com/forums/thread/840500)
describes the same key-generation errors in macOS 27 VMs with Jamf and Fleet,
including a guest that fails before MDM enrollment. Apple DTS says it is
investigating; the thread references FB23918943, FB24136873, and FB24608345.
A participant reports that 27.0.1 still fails. That is a participant's result,
not official confirmation of the affected versions or the keybag mechanism.
This independent reproduction weakens a Pomme-specific explanation but does
not prove the proposed `keystore-init` cause.

### Evidence provenance

Existing local scratch artifacts are under
`/private/tmp/claude-501/-Users-wes-dev-pomme/81fdacfa-bc2e-483b-8da8-a3ee0b0c07d9/scratchpad/`:

| Artifact | Relevant evidence |
| --- | --- |
| `vm27-kernel-identity.log` | Line 45: task skipped. Lines 133–135: -6 lookup and reference-key failure. Lines 216–221: owner bag installation succeeds (`make system … = 0`). Lines 287–291: successful owner unlock followed by another -6 failure. |
| `aks-boot-pomme-agent-public26-20261014a.log` | Lines 17–26: volume UUID mapped to -5 with `booted_from: 1`. |
| `vm27-apsd-boot.log` | Lines 2640–2653: System Keychain use, reference-key creation failure, BAA failure, and no connection. |
| `launchd27.bin.strings` | Lines 3695–3706: embedded `keystore-init` task configuration. |
| `launchd.full.s` | Lines 74222–74244: external-volume condition at the addresses above. |
| `kc/27.0/vpks.s` | Lines 8317–8377: -6 lookup through booted-volume UUID. Lines 165246–165283: reference-key bag lookup. |
| `vz.full.s` | Private setter entitlement guard and entitlement-bit mapping at the addresses above. |
| `apsd.full.s` | Provider-selection branches and preference-reader addresses above. |

`apsd`, launchd, CryptoTokenKit, and DeviceIdentity were inspected from the host
running 27.0 build 26A428. `AppleVPKeyStore` came from VM kernelcaches in Pomme's
cached restore images. Inspection used `ipsw` and `otool`. Hopper's CLI
AppleEvent transport stalled; no successful Hopper disassembly has been
obtained. A modal dialog was suspected, not established as the cause.

### Remaining checks

1. Compare the macOS 26 launchd task dictionary and preserve the failing
   guest's exact filesystem flags to complete the version and runtime comparison.
2. Test the same initializer intervention on 27.2. On 27.0, BAA identity
   creation, `TokenUpdate`, and pushed commands succeeded with SIP disabled,
   including after a cold stop/start. A narrower security change, restoration
   of SIP after repair, and long-term identity renewal remain unverified.
3. Compare a freshly installed, manually configured guest before enrollment
   with the retained guest. Keep the protected templates unchanged.
4. Check 27.0.1 independently. The previously inspected `AppleVPKeyStore` was
   byte-identical to 27.0, but that alone does not establish its runtime behavior
   or the launchd task configuration.

## Environment

The NanoHUB server moved from wesM1 to cwwk on 2026-10-14, just before these
runs. Device traffic flows: guest → `https://mdm.weswhetst.one/mdm` (Caddy on
the RackNerd VPS, Let's Encrypt cert) → Tailscale → `tailscale serve` on cwwk
(100.106.93.66:9004) → NanoHUB container on `127.0.0.1:9004`.

| Item | macOS 27 run | macOS 26 control |
| --- | --- | --- |
| VM name | `pomme-agent-public27-20261014a` | `pomme-agent-public26-20261014a` |
| Template | `pomme-agent-base27-20260923a` (27.0, 26A428) | `pomme-agent-ownerloop-base26-20260922a` (26.6.2, 25G83) |
| Profile | `~/dev/nanohub-acme-docker/local/profiles/pomme-agent-public27-20261014a.mobileconfig` | `…/pomme-agent-public26-20261014a.mobileconfig` |
| Device UDID | `FCDC7115-9F30-53F7-AE1C-5B7AAFFC6F04` | `3D693A3C-7AE9-5730-9814-FDC93C115F2F` |
| Serial | `ZP4PR5Q3G9` | `ZVXQPPDY0Q` |
| Memory | 4 GB | 4 GB |
| Outcome | Enrolled, no `TokenUpdate` | Enrolled, `TokenUpdate`, push acknowledged |

- **pomme build:** 0.2.1 (`41734da-dirty`) at `/Users/wes/.local/bin/pomme`. It
  includes `e1f331d`; the repo `HEAD` is `79ba5a1`, two commits ahead.
- **Command used:** `pomme mdm <name> --profile <file> --from-template
  <template> --memory 4GB --force`, defaults otherwise (supervised enrollment,
  `--final-security restore`).
- **Profiles:** made by `scripts/create-tiddly-profile.sh`. Each has a software
  PKCS#12 identity from the lab step-ca, the lab root CA, and an MDM payload
  with `SignMessage=true` and APNs topic
  `com.apple.mgmt.External.80fac23a-bb6d-48e0-b107-a7eb58cd1e95`. There's no
  ACME or attestation payload, because VMs don't support Managed Device
  Attestation.

## macOS 27 timeline

The first attempt failed during creation. The resumed run enrolled, but `apsd`
never produced a token. Times are UTC, and guest logs are in PDT (UTC−7).

| Time (UTC) | Event |
| --- | --- |
| ~16:24 | Waited about 10 more minutes after pomme finished; still no `TokenUpdate`. VM then stopped and retained. |
| ~16:13–16:15 | `pomme status`: VM running, guest agent connected. `profiles status -type enrollment`: "MDM enrollment: Yes (User Approved)", server `https://mdm.weswhetst.one/mdm`. |
| ~16:13 | Pomme finished `OK mdm steps=resumeProvisioning,enroll` (about 1,078 s) after restoring AMFI and SIP. |
| 16:12:18–16:12:21 | After a reboot: an idle command poll, then `GetBootstrapToken`. The guest logged "Bootstrap Token provided by MDM failed to verify". |
| 16:08:53 | `SetBootstrapToken` and an idle command poll ("no command"). |
| 16:07:53–16:08:02 | First contact with NanoHUB: `Authenticate` (cert associated, enrollment new), a second `Authenticate`, `GetBootstrapToken`. **No `TokenUpdate`.** |
| ~15:58–16:07 | Resumed run: SIP off, then AMFI off over two Recovery passes (boot-args written and macOS restarted), then "Enrolling in MDM" and "Waiting for MDM enrollment". |
| ~15:56 | First attempt failed at "Starting macOS" (72 s): "Pomme couldn't pass the owner's credential to a guest command through a private terminal", `provisioning-phase-failed`. Rerunning the same command resumed it. |

The device row exists in NanoHUB's `devices` table (updated 16:07:54), but
`enrollments` has no row for this UDID. NanoHUB only creates that row on
`TokenUpdate`.

## Evidence

The guest's push service never gets a token, so `mdmclient` has nothing to send
in `TokenUpdate`.

**mdmclient** asks `apsd` for the token and gets null every time:

```
mdmclient [com.apple.apsd:connection] <private> asked for publicToken, got (null)
mdmclient [com.apple.apsd:connection] <private> Delivering publicToken from apsd: (null)
```

**apsd** never connects to Apple's push service and has no stored token:

```
apsd [com.apple.apsd:courier] APSSystemTokenInfo no token info found in keychain
apsd [com.apple.apsd:courier] <private> topicManager <private> requested to send filter. Connected on 0 interfaces.
apsd [com.apple.apsd:daemon] Do we need to enable the courier? needToken NO  _hasEnabledCouriers YES
```

**apsd error counts, 15-minute window covering several boots (most frequent
first):**

| Count | Error |
| --- | --- |
| 311 | `connectionServer` Unrecognized token received from \<private> |
| 132 | `preference` Preferences may have changed |
| 36 | `security:seckey` SecKeyCreateRandomKey\_ios failed: -25308 "Failed to generate keypair" (errKCInteractionNotAllowed) |
| 36 | `CryptoTokenKit:sepkey` (apsd) unable to generate key: error e00002e2 (-536870174), ACL includes `ock(true)` |
| 24 | `connectionServer` Unable to bootstrap\_look\_up connection port … Permission denied |
| 6 | `daemon` Unexpected connection from logged out uid |
| 6 | `User Defaults` Disabling saving preferences … because home directory is inaccessible |
| 5 | APSConnection created with a mach port that sandbox hasn't allowlisted |

The SEP key failures happened at 09:01 and 09:05 PDT (earlier boots during
SIP/AMFI changes), not only on the final boot.

**Network is not the problem.** From inside the guest,
`nc -z -G 5 1-courier.push.apple.com 5223` succeeded.

**mdmclient also logged** `Assertion Failed` at `CPKeychainItems.mm:1258` and
`:1272` on every boot, plus "Unable to verify Bootstrap Token". Check whether
these appear on macOS 26 too before treating them as related.

Commands used:

```sh
pomme exec <vm> -- /usr/bin/log show --last 15m --predicate 'process == "apsd" AND messageType == error' --style compact
pomme exec <vm> -- /usr/bin/log show --last 40m --predicate '(process == "mdmclient" AND eventMessage CONTAINS[c] "token")' --style compact
ssh plex 'sudo docker logs --since 1h NANOHUB_nanohub_acme_mysql 2>&1 | grep <UDID>'
```

## macOS 26 control run

The macOS 26.6.2 VM passed every step the macOS 27 VM failed, using the same
server, pomme build, profile generator and flags.

- `pomme mdm` ran clean on the first try in about 21 minutes. That included the
  same SIP-off and two-pass AMFI-off sequence, with no owner-credential failure.
- NanoHUB logged `Authenticate` ×2, `GetBootstrapToken` and **`TokenUpdate`**
  from `3D693A3C-…`.
- At 16:37:06 UTC, `DeviceInformation` was queued through
  `PUT /api/v1/nanomdm/enqueue/<UDID>`. APNs accepted the push and returned an
  apns-id. The device fetched the command and replied `Acknowledged` in the
  same second.
- Reported: DeviceName "Apple Virtual Machine 1", OSVersion 26.6.2,
  `IsSupervised = true`.

**Before the initializer experiment, no macOS 27 VM had sent `TokenUpdate` to
this server.** The original NanoHUB query showed that its
`devices` table held 13 devices. All 6 on macOS 27.0 authenticated but had no
`enrollments` row. All 7 on macOS 26.x or 15.7.9 had one. The 27 VMs include
the Sept 29 clones that `Docs/Issues/2026-09-29-mdm-single-command.md` lists as
"enrolled". That doc checked profile install and approval, but its push test
(supervised commands) ran only on macOS 26. The problem is not new, and the
server move didn't cause it.

| Created (UTC) | UDID | Serial | macOS | TokenUpdate |
| --- | --- | --- | --- | --- |
| 2026-10-14 16:36 | `3D693A3C-7AE9-5730-9814-FDC93C115F2F` | ZVXQPPDY0Q | 26.6.2 | yes |
| 2026-10-14 16:07 | `FCDC7115-9F30-53F7-AE1C-5B7AAFFC6F04` | ZP4PR5Q3G9 | 27.0 | **no** |
| 2026-09-29 05:40 | `E3AB5383-AAEA-5EA9-9029-B1FB252B8D10` | ZDT22JGRW0 | 26.6.2 | yes |
| 2026-09-29 05:02 | `45B1B1B9-1839-5EA2-B1A1-AAA6590285F3` | ZWNV5N95DY | 27.0 | **no** |
| 2026-09-29 04:26 | `2D2E92DB-843A-56A5-A8E3-60D6C0D3132B` | Z6VNVLW03P | 27.0 | **no** |
| 2026-09-29 03:59 | `FD7EE8A8-718F-597B-AB11-20260B965DAD` | ZWX9F34KJ4 | 27.0 | **no** |
| 2026-09-29 03:46 | `5F9FFFA4-BEB4-55B2-BB6D-6F16CAD19D5B` | ZJLR21QYY1 | 27.0 | **no** |
| 2026-09-28 06:36 | `E1EEA4D3-7EBE-57B8-87F0-B4125F9386F1` | Z6M9HD5PH3 | 26.6.2 | yes |
| 2026-09-28 05:17 | `8A867955-C61A-5EF1-993E-505D43C8F941` | ZDFWWD7H37 | 26.6.2 | yes |
| 2026-09-27 01:05 | `41ACD27A-14A7-5261-9B7D-6C6FDF373BA6` | ZRCJ99Q5GV | 27.0 | **no** |
| 2026-09-26 17:18 | `4648DEC4-1622-5EB2-9483-5B6A1C05FA26` | Z4MRRDQHQ0 | 26.6.2 | yes |
| 2026-09-07 06:39 | `CC22CDAD-7D63-51B6-A396-928A6BA5389C` | ZTVGCWGY57 | 15.7.9 | yes |
| 2026-08-31 08:44 | `FC8375DB-BBD4-5883-9A21-00F6F15EC11F` | Z465DHM3WP | 26.6 | yes |

## Original hypotheses

The following hypotheses and proposed checks preserve the initial investigation
record. See Follow-up investigation above for the current evidence and remaining
uncertainty; these hypotheses are not all resolved.

1. **macOS 27 `apsd` needs an SEP key the virtual SEP or keybag won't issue.**
   The failure is `SecKeyCreateRandomKey` → -25308 `errKCInteractionNotAllowed`
   with an access control that includes `ock(true)`. That points to a key that
   needs the keybag unlocked. If macOS 27 moved the push identity to an
   SEP-bound key and Virtualization.framework guests can't satisfy it, every
   macOS 27 VM would fail, which matches 6 of 6. Test: a stock macOS 27 VM with
   no pomme provisioning, set up by hand with a password login.
2. **Pomme's owner and auto-login setup leaves the system keybag locked from
   `apsd`'s point of view.** Pomme creates the owner through OpenDirectory, sets
   auto-login and writes Setup Assistant markers. The guest logged "Unexpected
   connection from logged out uid" and "home directory is inaccessible". If
   macOS 27 ties `apsd`'s first key creation to a real first unlock, an
   auto-login path that skips it could block it. This fits 6 of 6 too, because
   every 27 VM went through the same provisioning. Test: in the existing 27 VM,
   log out and log in with the owner password at the console, then check
   whether `apsd` gets a token.
3. **SIP/AMFI changes break key creation on macOS 27.** The SEP errors seen
   were timed (09:01 and 09:05 PDT) during the SIP/AMFI reboot cycle. It hasn't
   been checked whether they continue after SIP and AMFI were restored. The 26
   VM went through the same cycle and worked, so this is weaker. Test: look for
   `SecKeyCreateRandomKey` failures after the final restored boot, and on a 27
   VM that never had SIP or AMFI changed.
4. **Something specific to template `pomme-agent-base27-20260923a`.** All 6 VMs
   on 27.0 may come from one template, for example a stale keybag or `apsd`
   state cloned into every copy. Test: build a fresh 27 template, or install
   with `--latest`, and repeat.

Unlikely: the server, network or profile. The guest reaches
`1-courier.push.apple.com:5223`, the same profile generator and server worked
for 26, and the old LAN server showed the same 27 failure before the move.

## Original next steps

These were the initial proposed checks. Some were subsequently performed, as
recorded above. VM states below describe the initial investigation, not a fresh
status check. Follow the repository signed-install and disposable-VM rules
before running any new tests.

1. **Check the current state of the retained 27 VM** (stopped; start it with
   `pomme start pomme-agent-public27-20261014a`). See whether `apsd` still fails
   after the final restored boot:

   ```sh
   pomme exec pomme-agent-public27-20261014a -- /usr/bin/log show --last 10m --predicate 'process == "apsd" AND (eventMessage CONTAINS "SecKeyCreateRandomKey" OR eventMessage CONTAINS "Connected on")' --style compact
   pomme exec pomme-agent-public27-20261014a -- /System/Library/PrivateFrameworks/ApplePushService.framework/apsctl status
   ```

2. **Run the same queries on the working 26 VM**
   (`pomme-agent-public26-20261014a`, enrolled and running). If it shows the
   same SEP key errors and still gets a token, those errors are noise.
3. **Test hypothesis 2:** in the 27 VM, log out, then log in at the console with
   the owner password (not auto-login). Then `sudo killall apsd` and watch
   NanoHUB for `TokenUpdate`:

   ```sh
   ssh plex 'sudo docker logs -f --since 1m NANOHUB_nanohub_acme_mysql 2>&1 | grep -E "FCDC7115.*msg=TokenUpdate"'
   ```

4. **Test hypothesis 1:** create a macOS 27 VM without pomme's owner
   provisioning, finish Setup Assistant by hand with a password, and check
   `apsctl status` for a token before any MDM. If it has no token, the problem
   is macOS 27 in Virtualization.framework, not pomme. That would be worth a
   Feedback Assistant report.
5. **Test hypothesis 4:** repeat with a fresh 27 template
   (`pomme template create`) or `--latest` if a newer 27 build exists.
6. **Fix the record:** update `Docs/Issues/2026-09-29-mdm-single-command.md` to
   say the macOS 27 runs installed and approved MDM but never sent
   `TokenUpdate`, so push-driven commands can't reach them.

**How to check a result:** enqueue a command and confirm it's `Acknowledged`
within seconds. The API listens on cwwk's loopback, with Basic auth user
`nanohub` and the password in `NANOHUB_API_KEY` in
`/opt/nanohub-acme-docker/.env`.

```sh
ssh plex
curl -u nanohub:$KEY -X PUT --data-binary @DeviceInformation.plist http://127.0.0.1:9004/api/v1/nanomdm/enqueue/<UDID>
```

**Profiles:** one per VM; never reuse. On the Mac, open a tunnel to step-ca
first: `ssh -f -N -L 9443:127.0.0.1:9443 plex`. Then run
`~/dev/nanohub-acme-docker/scripts/create-tiddly-profile.sh <vm-name>`.
`MDM_SERVER_URL` in `.env` already points profiles at the public URL.
