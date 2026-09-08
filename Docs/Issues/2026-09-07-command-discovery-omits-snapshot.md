# Command discovery catalogs omit the public `snapshot` command

- **Severity:** Low
- **Status:** Resolved (2026-09-08; signed executable discovery verified)
- **Area:** Help and agent discovery metadata
- **Observed on:** Pomme 0.1.0 signed Release build

## Reproduction

The executable exposes and documents the command:

```text
rtk pomme snapshot --help
rtk pomme help snapshot
```

Both exit 0 and list `create`, `list`, `restore`, and `delete`.

The discovery surfaces omit it:

```text
rtk pomme tools --format json
rtk pomme agent-help
```

The `vm`, `guest`, `security`, `access`, `config`, and `utility` groups are present, but no group includes `snapshot`. The compact agent-help inventory also has no snapshot entry. The README command block and the legacy `PommeHelp` primary command list omit it as well.

## Expected result

All public commands should appear consistently in `tools`, `agent-help`, README command inventory, and legacy help metadata.

## Impact

Agents that rely on discovery rather than probing help cannot discover snapshot functionality and may incorrectly assume it is unavailable.

## Source evidence

`CommandCatalog.groups`, `CommandCatalog.agentHelp`, `README.md`, and `Sources/PommeCLI/Support/RunnerError.swift` omit snapshot while `Sources/PommeCLI/CLI/Commands/SnapshotCommands.swift` registers it publicly.


## Resolution — 2026-09-08

Added `snapshot` to the VM discovery group, the compact agent-help VM inventory,
the README command block, and legacy primary help. Both compact agent-help
representations now list `snapshot=create|list|restore|delete`.

### Validation

- `rtk proxy bash Scripts/build-local.sh` — signed Release build/install passed,
  with exact signing identity, entitlements, and designated-requirement checks.
- `rtk proxy zsh -lc 'command -v pomme'` — `/Users/wes/.local/bin/pomme`.
- Parsed `pomme tools --format json` and asserted `snapshot` belongs to the `vm`
  group; verified it also appears in table, raw, and JSONL output.
- Asserted `pomme agent-help` contains `snapshot=create|list|restore|delete`.
- `pomme snapshot --help` and `pomme help snapshot` both exit 0 and list all four
  leaf commands. Commands were run through `rtk proxy` against the signed CLI.
- Inspected the README command block and legacy primary help source for the
  snapshot entry.
- `rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build`
  — all 22 contract checks passed.

This metadata-only fix does not require VM operations; the separate snapshot
creation failure remains tracked in its own report.
