# Security workflows

This document describes the SIP and AMFI workflows for Pomme-owned VMs. A
SIP mutation and AMFI LocalPolicy change use authenticated, request-bound
Recovery transactions. AMFI boot arguments are written through the authenticated
persistent agent in normal macOS. The workflow captures the VM run state first, records a durable journal before
owner or Recovery effects, and restores the requested final state only after
verification.

## Scope and qualification

The current Recovery input scope is Tahoe at English `1280x800`. The reviewed
profile in the selector is Tahoe `26.6.0` build `25G72`. Tahoe `26.6.2` builds
such as `25G83` are represented as experimental identities because they are not
in the reviewed registry. An experimental attempt is still guarded by the
exact version/build descriptor, locale, geometry, private host ABI, ownership,
profile digest, and manifest checks. An unknown or mismatched identity is never
treated as reviewed: it must satisfy the bounded experimental checks or the
attempt fails closed.

Live qualification below applies to the tested build and pinned agent. It
does not add an experimental identity to the reviewed profile registry or
establish support for every VM on that macOS version.

## Commands

SIP and AMFI each expose `status`, `enable`, and `disable` commands:

```text
pomme sip status NAME [--final-state previous|stopped|normal|recovery|paused]
pomme sip enable NAME [--final-state ...] [--force]
pomme sip disable NAME [--final-state ...] [--force]

pomme amfi status NAME [--final-state previous|stopped|normal|recovery|paused]
pomme amfi enable NAME [--final-state ...] [--force]
pomme amfi disable NAME [--final-state ...] [--force]
```

`--final-state` defaults to `previous`. `previous` means the run state
captured before the workflow began. `stopped`, `normal`, `recovery`, and
`paused` resolve to a stopped VM, a normal boot, a Recovery boot, or a paused
VM respectively. A paused target retains the boot mode that preceded the
pause. A successful result includes the resolved `finalState` and
`finalStateVerified`.

Status observes security state through Recovery and uses the same final-state
resolution. Enable and disable perform the durable mutation workflow described
below.

AMFI changes require SIP disabled before LocalPolicy or NVRAM mutation. Use
`pomme sip disable NAME` first, then `pomme amfi disable NAME`. Restore with
`pomme amfi enable NAME` before running `pomme sip enable NAME`. `--force`
does not bypass this prerequisite. Clean already-requested states and status
commands do not require a SIP change.

Disable changes LocalPolicy in Recovery, boots normal macOS to write and read
back the merged boot arguments, and performs another normal boot to verify the
effective arguments. Enable restores the exact saved boot arguments in normal
macOS first, restores LocalPolicy in Recovery, then verifies a fresh normal
boot. The original SIP state is an explicit prerequisite; AMFI does not
silently change it.

## State-first execution

The workflow observes the requested security state before owner preparation can
run. A SIP workflow reads the effective state of the current normal boot
through the authenticated persistent agent (`csrutil status`), booting normal
macOS first if needed. This is the same read that proves every SIP workflow
after its final normal boot, and it needs neither owner credentials nor a
Recovery session. AMFI state is inspected through Recovery, where the retained
transaction record is read, while the AMFI SIP prerequisite uses the same
normal-boot read. The public `status` commands still observe through Recovery.
If the observed state already matches and there is no unresolved
reconciliation, the workflow records a `noMutationVerified` receipt and
restores the final state without asking for an owner or touching Recovery
mutation inputs.

AMFI enable has an additional rule: a retained AMFI baseline makes the state
ineligible for the no-op path, even when the current disabled value appears to
match. Enabling AMFI requires that exact baseline. If AMFI is disabled and no
baseline is retained, the workflow returns `missingBaseline` before owner
preparation and never guesses at a LocalPolicy reset.

Before AMFI inspection boots Recovery, the host records `preflightIntent` with
the original VM state. A rejected prerequisite becomes `preflightRejected`
only after restoring and proving that state. This terminal record carries no
requested-security success receipt and permits a later SIP command. A crash
retains the original state and the pending preflight for the same command to
resume.

For a mutation, the journal records owner and credential progress, then a
`securityMutationIntent` before the authenticated security stages. Each stage
must return a verified receipt for the resource it owns. The VM is
then booted normally and checked by the persistent normal agent before the
workflow records `normalBootVerified` and restores the requested final state.

## Owner authorization

`--force` authorizes the fresh owner-account branch only after the VM has been
proven fresh and Pomme-owned. That branch creates the `pomme` administrator,
configures persistent automatic login, and finishes Setup Assistant. `--force`
does not bypass owner credentials, freshness or identity checks, login
restrictions, a retained transaction conflict, or a failed cleanup barrier.

An existing owner account is verification-only. Pomme checks the exact local
account, administrator membership, Secure Token, APFS local-owner identity,
startup volume identity, and password; it does not replace the account or
change its password. Existing authorization can come from both environment
variables `POMME_AUTHORIZED_USER` and `POMME_AUTHORIZED_PASSWORD`, an exact
VM-scoped credential reference in the login Keychain, or an interactive owner
prompt. Supplying only one environment variable is rejected. Password values
are passed separately to the credential boundary and are never placed in
command arguments or the durable journal. This path remains verification-only
for an existing owner and leaves the fresh-owner native completion preferences
unchanged.

Freshness is bound to the exact native stock-account baseline: the expected
account name, numeric UID, GeneratedUID, administrator membership, Secure
Token, APFS local-owner identity, and startup-volume identity. An unfamiliar
local record blocks the fresh-account decision; `--force` cannot convert an
unknown account set into a fresh VM. An unknown OS version/build remains a
guarded experimental identity when its exact profile, ownership, and host
checks pass, so lack of review alone does not create a new freshness bypass.

Fresh-account creation and automatic-login configuration use the private guest
PTY path. The PTY sends `sysadminctl` input without putting the password in the
command or journal. Before automatic login, Pomme checks FileVault status,
managed login-window preferences, the
`disablefdeautologin`/`disablefdeautomaticlogin` restrictions, and native
`sysadminctl` support. Any restriction or unsupported syntax fails closed;
Pomme does not silently enable automatic login around it.

The managed-preferences probe is limited to the exact system path
`/Library/Managed Preferences` and the exact owner path
`/Users/<owner>/Library/Managed Preferences`. Each path must be absent, or be
a readable real directory that can be enumerated; a symlink, non-directory,
or probe failure blocks the workflow. Pomme does not use a broad `/Users`
search or inspect protected Store/TCC directories as a substitute for this
proof. Native profile diagnostics provide the management proof: `profiles
status -type enrollment` must report `Enrolled via DEP: No` and `MDM enrollment:
No`, while both the system and owner configuration-profile queries must report
that no profiles are installed. Positive, unknown, or malformed output fails
closed.

The fresh-owner login command names the same verified `pomme` account as both
administrator and automatic-login target. Its private PTY answers the separate
administrator-password and target-password prompts with that owner secret.
It runs through `launchctl asuser 248` in the existing native Setup Assistant
session after verifying the stock setup identity, exact process path and start
identity, console user, matching Aqua audit session, and native manager probes.
A pristine VM still at Language Chooser uses the guarded experimental native
handoff described below; failure to establish that session stops navigation. A
retry that already has all native autologin proofs skips the setter and session
handoff.

On every normal boot, the persistent guest agent detects the product version and
build with `sw_vers` and queries the local Open Directory node for the exact
`pomme` account. It checks immediately and every two seconds while the account
or its home directory is absent. It validates the UID, GeneratedUID, and home
before maintaining preferences; it does not wait for login or a GUI session.
Recovery agents never run this task.

The agent uses bounded `sudo -n -H -u pomme /usr/bin/defaults` commands to
maintain `com.apple.SetupAssistant/LastSeenBuddyBuildVersion` as the detected
build string and `com.apple.loginwindow/MiniBuddyLaunch` as boolean `false`.
It reads and checks types before writing, skips matching values, and verifies
each changed value. The host never writes these preferences.

A root-owned private receipt binds the task to `kern.bootsessionuuid` and the
owner identity. It records waiting, running, succeeded, or failed status. A
restart resumes waiting or reuses a terminal receipt; an interrupted running
attempt becomes failed without replaying writes. A new boot permits another
attempt. Failure retains bounded diagnostics and leaves command transport
available. The authenticated `buddy.preferences.status` operation reads this
receipt without initiating maintenance.

The agent also records unified logs under subsystem
`com.github.weswhet.pomme`, category `buddy-preferences`.

Progress uses notice-level logs; failures use error-level logs. Events include
the boot UUID, daemon PID, and run ID, plus owner discovery and revalidation,
stage durations, command launcher PID and exit status, output byte counts,
recognized error categories, and typed readback results. A launcher labelled
`sudo` identifies the spawned process; it does not prove that `defaults` started.
Unknown command output is redacted. Waiting logs appear on account/home state
changes and at most once per minute while that state remains unchanged.

Fresh-owner preparation requires a successful matching receipt after owner
verification, before configuring native automatic login and system completion
markers (including `.AppleSetupDone`). It reboots, authenticates the normal
agent, and checks the new boot's receipt before continuing. Missing capability
requires an updated guest agent. Failed or mismatched receipts stop the workflow
without an automatic retry, reboot, cleanup, or security restoration.

The workflow still verifies the owner console, revalidates the owner, and closes
only the exact verified owner Setup Assistant process. It requires the full
stable desktop proof before recording `autologinVerified` or starting a security
change. Account creation, automatic login, completion markers, and Setup
Assistant closure remain workflow responsibilities.

Pomme requires native automatic-login status to report the account-bound
diagnostic `Automatic login user: pomme` (with the native timestamp prefix
when present), and `/etc/kcpassword` to exist with root ownership and mode
`600` before it writes `/var/db/.AppleSetupDone` on its fresh-owner path. That
marker is a completion marker, not proof of automatic login. Native macOS may
create it with mode `400` during a retry while the stock `_mbsetupuser` UID
`248` console, Setup Assistant process, and Aqua session remain alive; Pomme
permits that existing native session when the exact session and automatic-login
proofs pass. The Language Chooser handoff remains limited to the marker-absent
pristine path.

On fresh-owner retries, Pomme verifies empty, root-owned `0:0`, mode `0400`
`/var/db/.AppleSetupDone` and `/var/db/.AppleDiagnosticsSetupDone` markers and
absence of the pending Terms cookie. It then requires five seconds of stable
`pomme:501` console, Aqua `501`, exact-owner Dock, and no Setup Assistant,
revalidating that desktop before security mutation and recording the normal-
boot receipts. Existing-owner security branches do not require this owner
autologin or desktop-completion proof.

Desktop readiness uses fixed read-only console, Aqua, and process-list probes
with 15-second attempt deadlines inside one 120-second readiness deadline.
A timed-out probe remains failed. The loop may try again only after the exact
job has supplied an authenticated exit frame proving that it was reaped and
its output drained. It preserves the foreground runner's single SIGTERM and
uses an already-received host receipt or at most three seconds of host-side
status waiting within the original deadline. During that window, closed
temporarily unavailable connection states may be polled without replaying the
signal. Each status attempt captures one authenticated normal session, checks
its persistent role, protocol/version, creation-pinned executable digest, and
status capability, then queries the original job on that same pinned session.
The private host receipt is not accepted from an older helper or raw guest
response. A restarted daemon with no original job cannot supply cleanup proof.
A signal acknowledgement or an `exited` flag alone is insufficient; a running
status snapshot may precede the daemon's later valid reap/drain exit frame.
Cancellation, malformed or foreign-job evidence, wrong agent identity, missing
job, unresolved transport/cleanup, or insufficient remaining time stops the
workflow. A retry starts the full console/Aqua/desktop check again and
resets the five-second stability interval; it never extends the overall
deadline or retries arbitrary guest commands. Helper-side describe/status
exchanges retain their ordinary per-exchange limits and may finish after the
caller's three-second wait expires; late completion cannot authorize another
probe.

Native automatic-login refusals are classified as closed login restrictions,
including protections associated with Touch ID, Apple Pay, App Store, and
related native services. Pomme has no native-force override: `--force` cannot
turn such a refusal into an enabled result. A native account-bearing status
line alone is insufficient; the exact preference, artifact, completion-marker,
and stable desktop proofs must agree.

## Journal, retry, and conflicts

Each VM has one `SecurityWorkflowJournal.json` in its Pomme bundle, protected
by the per-VM mutation lease. The journal contains identity, operation,
requested final state, redacted credential metadata, owner facts, phase
receipts, and timestamps. It never contains the owner password.

The journal records an intent before each externally visible effect and a
verified receipt afterward. Important terminal boundaries include
`securityMutationIntent`, `securityMutationVerified`, `normalBootVerified`,
`noMutationVerified`, `restorationPending`, and `restorationComplete`.

If a process stops after an intent, rerun the same operation with the same
requested final state. A retained `autologinIntent` restarts the owner-login
sequence from native autologin and marker reconciliation, including its planned
reboot. Individual completion stages are not durable resume checkpoints.
Resume observes the guest again and reconciles a
matching `securityMutationIntent` without repeating the owner or security
write. A `restorationPending` retry uses the durable receipt booleans and only
completes restoration when the observed state is still consistent.

An unfinished journal for a different operation fails at `begin` with a
conflict before owner, Recovery, or VM effects start. Identity, operation, and
requested-final-state changes are rejected rather than rewriting the retained
request. A failed operation retains its journal and progress for inspection
and retry. A fresh-owner preparation failure leaves the VM in its failure state,
without automatically restoring its prior run state. Other security failures
may attempt to restore the run state captured at workflow start; the successful
`--final-state` target is used only after the workflow completes.
If cleanup cannot be proven complete, the workflow returns
`restorationIncomplete` and does not restore or boot the VM; inspect the VM and
repeat the retained operation only after the cleanup state is understood.

## AMFI result semantics

For AMFI, `configured` and `configuredDisabled` describe the verified
configuration requested by the policy/NVRAM transaction and its read-back.
The snapshot retains the full raw native `bputil --json` baseline and
exact NVRAM bytes, including the `lpnh` and `os_lpnh` anti-replay nonce values,
alongside an owned authenticated generation checkpoint. Each receipt records
the exact effective policy flags and exact present-or-empty NVRAM state.
Equality covers all stable identity and restorable configuration fields,
excluding only those two nonce fields because Apple rotates them when a
LocalPolicy changes ([Apple Platform Security](https://support.apple.com/en-ke/guide/security/secc745a0845/web)).
Pomme retains the raw nonce values for evidence and never replays a stale
nonce.

Staged transactions explicitly bind NVRAM effects to normal macOS. Recovery
cannot perform their NVRAM writes, and legacy Recovery-only snapshots are not
silently reinterpreted as staged transactions. `disabledConfigured` and
`enabledConfigured` retain complete resource receipts while awaiting normal
boot verification. They permit verification on retry, but never a fresh no-op.
The enabled terminal record retains restoration evidence so a crash between
guest verification and the host receipt remains idempotent.

After each normal NVRAM receipt, the host requests a native reboot through the
existing authenticated agent and verifies a changed boot identity with the same
creation-pinned executable. This commits firmware state before any subsequent
Recovery transition. A host stop/start, which can fall back to a forced stop,
is not a substitute for that proof. That rebooted session is the fresh boot on
which a disable is verified; an enable is verified on the fresh normal boot
that follows its Recovery policy stage. Verification reboots again only when
it finds a running boot it did not itself start or prove, such as a retry in a
new process.

A retained AMFI disable can resume an owned normal-NVRAM checkpoint or reapply
its configured target after owner reverification when that target was lost
across a boot. The
guest must independently match the exact owned policy and recorded NVRAM
before/target before recording another write intent. Fresh requests, foreign
NVRAM, wrong-direction phases, and terminal drift do not enter this recovery
path.

A creation-pinned Recovery agent can reject workflow status with the typed
`snapshotPending` error when a configured target has reverted to the recorded
baseline. Only a retained AMFI-disable journal at its mutation-intent or
mutation-verified boundary with an existing verified owner may enter the
compatibility retry. It independently verifies SIP disabled, re-verifies the
owner, and invokes the pinned normal stage, whose exact checkpoint validation
remains authoritative. It does not invent an observed phase or start another
Recovery policy mutation. Other inspection errors retain the failure.

The persistent agent must advertise normal AMFI workflow version 1. Each stage
rechecks its role, protocol, capabilities, and creation-pinned executable digest
on the authenticated session. Unsupported pinned agents fail explicitly; this
workflow does not replace an agent or rewrite immutable creation records.

Outside an owned authenticated transition with a matching receipt, native
`nsih`, `spih`, and `stng` fields must equal the retained baseline. A receipted
transition may advance the owned generation only to its verified effective
state; an ambiguous or unreceipted change fails closed.

Strict validation runs before any LocalPolicy or NVRAM write. Unknown native
fields, non-restorable auxiliary hashes, unsupported custom SIP masks, unmanaged
MDM state, and unknown security-mode extensions are rejected. The native
SIP-disabled profile observed on the lab build (`sip0=127`, `sip0_exists=true`,
`sip1=false`, `sip2=true`, `sip3=true`, Permissive Security) is eligible only
for exact policy preservation. It already permits custom boot arguments, so
AMFI must not rewrite its LocalPolicy or synthesize a restoration command.
Its unchanged-policy receipts must preserve the complete native policy and
generation, including nonce fields; any drift blocks the transaction. This is a guarded mutation
contract with bounded restore support; it does not claim to restore arbitrary
LocalPolicy data. A boot argument by itself is not proof that the running
kernel is enforcing the requested policy. The normal-agent check therefore
reports runtime configuration separately, and the current result keeps
`enforcementVerified` false for AMFI. Treat a successful AMFI result as
configuration evidence with the stated verification fields, not as a claim of
independent live-kernel enforcement.

SIP uses the normal agent's exact `csrutil status` read-back for its normal-boot
check. Its `enforcementVerified` field can be true only after that check and a
verified normal boot.

## Live qualification status

The complete AMFI disable/enable configuration cycle passed on a new disposable
Tahoe `26.6.2` build `25G83` VM. Disable verified the override after native guest
reboot and finished in normal macOS. Enable restored the exact retained
baseline, verified a fresh normal boot, and finished in Recovery. Both returned
`normalBootVerified`, `runtimeConfigurationVerified`, and `finalStateVerified`.
AMFI `enforcementVerified` remained false: live-kernel enforcement was not
independently tested.

The installed Release has SHA-256
`f4d3d3ef4bf22e24a5d8a3874b9ca5acb9d7bfc3f8a3060ca7aa31473a28e286`.
It was built, signed, verified, and installed through `Scripts/build-local.sh`
with the existing Developer ID identity. The VM retained normal and Recovery
agents pinned to
`793113d52aa9153c5195e7313b61814fdfbcf12d20f205fd33125fbac5c1cdcd`;
no persistent agent or immutable creation record was replaced.

Offline verification passed 709 Swift tests with no failures or skips
(`test_macos_2026-09-06T10-55-02-305Z_pid46171_223a3f7f.xcresult`),
15 CLI contract checks, and 21 installer checks. The suite includes native
reboot proof, retained checkpoint recovery, typed pending-snapshot handling,
secret isolation, exact baseline restoration, and failure-boundary coverage.

The migration resolved three observed differences from the predecessor
implementation:

- Recovery rejected the original NVRAM write. The predecessor wrote from normal
  macOS after SIP was disabled; Pomme now uses that execution environment.
- Ordinary SIP disable produced Permissive Security with `sip0=127`,
  `sip0_exists=true`, `sip1=false`, `sip2=true`, and `sip3=true`. This exact
  profile already permits custom boot arguments. Pomme preserves it with
  verified no-op policy receipts instead of rejecting it or rewriting it.
- A normal NVRAM write and immediate read-back succeeded, but the value was
  empty after host stop/start. Native guest reboot preserved the write and
  supplied changed-boot proof. The retained retry reverified the existing
  owner and used the exact guest checkpoint without another Recovery policy
  mutation or baseline capture. Its compatibility path handled the pinned
  Recovery agent's typed `snapshotPending` status rejection.

The labs also passed AMFI rejection while SIP was enabled, fresh-owner
verification, persistent automatic login, SIP disable, and normal boot
verification. Fresh-owner completion required one retained retry; that retry
reused the account and saved credential. The authoritative AMFI baseline was
a present, empty `boot-args` value. An earlier unrelated argument did not
survive the preparatory host boots, so unrelated-argument preservation has
only offline coverage in this run.

Final SIP enable passed with normal-boot SIP verification and the requested
normal final state. Final read-only checks found empty NVRAM and kernel boot
arguments, Full Security with `sip0=0` and `sip0_exists=false`, and console
user `pomme`. The normal helper and creation-pinned agent were connected after
all commands exited. Both assignment VMs and their exact owner and agent
credential items were removed. The protected `doitlive` VM matched its initial
stopped projection. The private lab artifacts were removed; the cached IPSW
and signed agent archives were preserved. Tahoe `25G83` remains a guarded
experimental identity; this qualification does not change the reviewed
profile registry.

Private owner input requires the persistent agent's `privatePTYInputVersion: 1`
describe receipt and a verified echo-disabled PTY start. Older pinned agents
are rejected before account creation. Pomme retains their original executable
and immutable creation records. PTY failures expose only fixed diagnostic
codes; native transcripts and arbitrary transport errors never become logs.
