# UI AI bridge is unavailable and several omitted-target forms are positionally ambiguous

- **Severity:** Medium
- **Status:** Resolved (2026-09-08; target parsing fixed and AI unavailability exposed before dispatch)
- **Area:** `ui ai` and `POMME_VM_NAME` target resolution
- **Observed on:** Pomme 0.1.0 signed Release build; normal Tahoe VM

## UI AI reproduction

This is the historical reproduction. The current command spelling is `pomme ui ai settings [VM] GOAL`.

```text
rtk pomme ui ai pomme-agent-cli-tahoe-0907 'Open Keyboard settings' --mode suggest --max-steps 1 --confidence 0.5 --model-timeout 1 --deterministic-fallback --no-open --settings-url 'x-apple.systempreferences:com.apple.Keyboard-Settings.extension' --until-text Keyboard --screenshot-output /tmp/pomme-cli-ai-0907 --timeout 5 --format json --debug
```

The command parsed every option and exited 1 with:

```text
guest-ui settings-ai is unavailable through the direct Virtualization UI bridge.
```

The `step` and `loop` modes produced the same result. Invalid mode, zero steps, confidence outside 0...1, and zero model timeout were rejected as expected.

## Omitted-target reproduction

With `POMME_VM_NAME=pomme-agent-cli-tahoe-0907`:

```text
rtk proxy env POMME_VM_NAME=pomme-agent-cli-tahoe-0907 /Users/wes/.local/bin/pomme ui key return --format json
```

Observed result: exit 64, `Missing expected argument <key>`. The positional parser treated `return` as the optional VM name. A one-argument key sequence similarly treated the first key as the name, and a one-argument AI goal was reported as missing its goal.

Other omitted-target forms, including `ui click`, `ui type`, and `ui screenshot`, resolved successfully when their required option/arguments made the target unambiguous.

## Expected result

The advertised AI settings action should either use an available bridge or fail during capability discovery. Every command documented as accepting `POMME_VM_NAME` should resolve a single positional action argument consistently when the target is omitted.

## Impact

UI AI automation is unavailable, and callers using the environment target cannot reliably invoke positional-only UI actions.

## Source evidence

The control router returns the explicit unavailable error for `guest-ui settings-ai`. The UI command structs place the optional name before required positional values, which creates the observed ambiguity when the environment supplies the target.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/UIUtilityCommands.swift`
- `Sources/PommeCLI/Control/ControlProtocol.swift`

## Resolution

`ui key` and `ui ai settings` now resolve one positional value as the action using `POMME_VM_NAME`, and two positional values as explicit VM plus action. Explicit targets override the environment. A single `ui key-sequence` key also uses the environment target.

Key sequences accept `--vm VM` to select the target explicitly. Without an environment target, the existing positional VM plus keys form remains supported. With an environment target and multiple values, a first value that cannot be a display key remains an explicit VM name. If the first value could be both a VM name and a key, the command rejects with guidance to use `--vm`; it never guesses which guest should receive input. Modifier combinations that cannot be VM names can use the environment target unambiguously.

Examples:

```sh
rtk proxy env POMME_VM_NAME=dev pomme ui key return
rtk proxy env POMME_VM_NAME=dev pomme ui key-sequence return
rtk pomme ui key-sequence --vm dev return right
rtk proxy env POMME_VM_NAME=dev pomme ui ai settings 'Open Keyboard settings'
```

The AI bridge is still unavailable. `tools --format json` and VM capability output now expose `uiCapabilities.settingsAI.available: false` with an actionable reason. AI help and `agent-help` also state the limitation. All AI modes reject before application VM lookup, mutation leases, control dispatch, or screenshot output creation. The control parser and runtime retain the same rejection as defense in depth. Existing AI option validation remains in place.

## Validation

- Xcode: all 13 tests passed across `UIUtilityCommandTests`, `PommeUICapabilitiesTests`, and `PommeUIControlRoutingTests`, covering positional resolution, ambiguity, option bounds, capability discovery, pre-lookup rejection, and direct UI routing.
- All 47 public CLI integration checks passed. New checks cover omitted key/sequence targets, ambiguous sequences, machine-readable discovery, help, and suggest/step/loop rejection with every originally reported valid option and no screenshot output effects.
- Canonical signed Release build and installation passed signature, exact entitlement, and designated-requirement checks. Fresh login shell resolves `/Users/wes/.local/bin/pomme`; SHA-256 is `f667e8f8d793d6ef1f4f2296ad6346c26654a8f6b8ac0d4aff6d0eae40d58fab`.
- No live VM input was needed for this host parser/capability change. These checks do not claim an operational AI accessibility bridge.
