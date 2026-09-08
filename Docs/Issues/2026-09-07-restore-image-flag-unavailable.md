# Direct `create --restore-image` is advertised but always fails closed

- **Severity:** Medium
- **Status:** Resolved (2026-09-08)
- **Area:** Direct creation restore-image selection
- **Observed on:** Pomme 0.1.0 signed Release build

## Reproduction

```text
rtk pomme create pomme-agent-cli-restore-image-0907 --restore-image /tmp/missing-restore.ipsw --dry-run --format json
```

Observed result: exit 64 with:

```text
--restore-image requires a verified restore-image identity; this Pomme build cannot qualify local images.
```

The same fail-closed result occurred with a path to the cached restore image. `--version`, build selectors, and `ipsw download` successfully resolved the same images.

## Expected result

The documented direct local-image option should either qualify and use a verified local image or be omitted from the public create interface until qualification support exists.

## Impact

The option cannot create or even dry-run a plan, so callers must use the separate version resolver and download path.

## Source evidence

`LifecycleCommands.CreateCommand` explicitly throws before dry-run when `restoreImage` is supplied. The source comment states that local image identity reading is not exposed at this boundary.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/LifecycleCommands.swift`
- `Sources/PommeCLI/Operations/PommeApplication.swift`

## Confirmed cause and correction (2026-09-08)

The backend already accepts local IPSWs. Before creating a VM, it resolves the
path, loads image metadata using Virtualization, selects the Recovery profile,
checks host compatibility and resource requirements, and pins the image digest
in the durable plan. The public CLI rejects the option before reaching this
existing implementation.

The correction shares local-image qualification between CLI preflight and
backend provisioning. Dry-run can report the image's actual version, build, and
Recovery profile; execution still revalidates the image before its first VM
effect. Unknown versions retain experimental qualification rather than
inheriting a reviewed profile.

The installation path now compares the current IPSW bytes with the
restore-image digest pinned in the plan. Matching version/build metadata alone
does not detect replacement of the file after planning or before a resumed
installation. A mismatch must fail before writing VM hardware metadata or disk
state, preserving the original plan for inspection.

Apple's [VZMacOSRestoreImage documentation](https://developer.apple.com/documentation/virtualization/vzmacosrestoreimage)
describes loading local installation media and exposing its OS version, build,
and host-supported configuration. Loading requires the Virtualization
entitlement already present in Pomme's signed Release build.

## Verification (2026-09-08)

- Existing direct-creation, catalog, Recovery profile, and provisioning tests
  passed, along with the new changed-image digest regression. All three local
  parser tests passed after correcting two assertions to account for validation
  occurring during parsing.
- Canonical signed Release build and signing/entitlement checks passed.
  Installed executable SHA-256:
  `935ba14a3e0eced94d959a38043aba56c95be02f1731e63fdafb6345f04afcc7`.
- All 25 CLI integration checks passed.
- The signed CLI successfully dry-ran the cached Tahoe 26.6.0 / 25G72 IPSW,
  reporting the actual version/build, accepted profile, and canonical path. A
  symlink to that file produced the same identity and canonical path.
- Missing files, directories, and malformed IPSWs all failed with nonzero exit
  status. None used the former blanket “cannot qualify local images” rejection.
- All five real-file checks used an isolated application-support path and
  verified that it remained absent. No VM was created or started. The exact
  temporary fixtures were removed after validation.

```sh
rtk xcodebuildmcp macos test --project-path pomme.xcodeproj --scheme pomme --configuration Debug --derived-data-path /tmp/pomme-remote-login --extra-args=-only-testing:PommeCLITests/DirectLocalRestoreImageCommandTests -only-testing:PommeCLITests/RestoreImageIntegrityTests -only-testing:PommeCLITests/CreateCommandTests -only-testing:PommeCLITests/PommeRestoreImageTests -only-testing:PommeCLITests/PommeRecoveryProfileSelectorTests -only-testing:PommeCLITests/PommeProvisioningTests --output text --verbose
rtk proxy bash Scripts/build-local.sh
rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build
```

An installation initiated specifically through the newly exposed CLI option
was not run. Execution uses the existing local-image provisioning path, now
with shared qualification and an additional pre-install digest check.
