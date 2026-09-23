# AMFI status cannot pass the Recovery capability probe on the Sequoia profile

- **Severity:** Medium
- **Status:** Resolved — unqualified security profiles reject before Recovery effects
- **Area:** Recovery security operations on experimental profiles
- **Observed on:** Pomme 0.1.0 signed Release build; Sequoia 15.6.1 / 24G90 VM, 40GB disk, 4GB memory

## Reproduction

```text
rtk pomme amfi status pomme-agent-cli-sequoia-0907 --final-state stopped --format json --debug
```

Recovery boot and terminal verification completed. The capability probe then failed after three marker-proof attempts:

```text
Recovery Terminal marker proof [attempt=1, terminalWindow=true, exactMarker=false, freshPromptAfterMarker=false].
Recovery Terminal marker proof [attempt=2, terminalWindow=true, exactMarker=false, freshPromptAfterMarker=false].
Recovery Terminal marker proof [attempt=3, terminalWindow=true, exactMarker=false, freshPromptAfterMarker=false].
pomme-agent-cli-sequoia-0907 Recovery bootstrap milestone: capabilityProbeRejected.
Error: Recovery Terminal capability proof failed.
```

Exit code was 1. Cleanup completed and the VM was stopped with no retained security journal. The equivalent AMFI status command passed on the qualified Tahoe profile.

## Expected result

An advertised supported command should either complete on the created Sequoia profile or reject the profile during selection with a clear qualification limitation before starting Recovery.

## Impact

The Sequoia VM can be created using observed-screen checks but cannot be used for Recovery security operations that require the stricter capability proof.

## Source evidence

The create path marks Sequoia 15.6.1 / 24G90 as `experimental` and warns that Recovery automation is not qualified. The security command nevertheless enters the Recovery workflow and fails during capability probing.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/LifecycleCommands.swift`
- `Sources/PommeCLI/Config/PommeRecoveryProfile.swift`
- `Sources/PommeCLI/Security/PommeRecoveryIntegration.swift`


## Resolution

SIP and AMFI now require the existing reviewed Recovery profile evidence. An experimental or pending profile is rejected with an explicit qualification limitation before one-shot credential issuance, staging, runtime construction, or Recovery boot. This applies to status, enable, and disable.

Security mutations perform the same qualification check before creating or reopening the security workflow journal. The guard uses the immutable, owned provisioning plan; successful experimental creation does not promote a profile into reviewed security support. The existing exact build, manifest, locale, geometry, host ABI, and ownership requirements remain in force.

Experimental creation, resume, and agent installation retain their existing observed-screen path. No Sequoia profile was promoted to reviewed status and the capability-proof checks were not relaxed.

## Verification

Xcode ran 58 focused tests: all passed, with zero failures or skips. Suites covered the security preflight and qualification helper, live Recovery integration, profile selector, Core Recovery provisioning, durable provisioning, and VM creation planning. The new effect-order test exercises all six SIP/AMFI actions on Sequoia evidence and proves only read-only identity/executable/profile resolution is reached. A separate test proves experimental agent installation still reaches its injected credential boundary. Existing tests verify experimental planning and evidence remain supported.

The canonical signed Release build/install passed identity, designated-requirement and entitlement verification. Installed SHA-256: `309353a733244d81b199652e465c455008eab00e3120d64c3fc6049825175eec`. A fresh login shell resolves `/Users/wes/.local/bin/pomme`; all 31 CLI integration checks passed against it. `git diff --check` passed.

The mutation preflight ordering before journal creation was verified by source review; the offline effect-order regression runs the live adapter through injected boundaries, not the full concrete `runLive` VM path. Any pre-existing security journal on an experimental VM remains untouched and requires separate reconciliation; this change does not rewrite or discard it.

No live VM was booted or modified for this fix. The original Sequoia failure remains evidence that security operations are unqualified; the fix implements the report's early-rejection alternative rather than claiming that Sequoia capability probing now succeeds.
