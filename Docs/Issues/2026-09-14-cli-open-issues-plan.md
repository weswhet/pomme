# Plan: resolve the High/Medium CLI issues from 2026-09-14

## Context

`Docs/Issues/2026-09-14-cli-open-issues.md` records 29 open CLI defects found
against the signed build at `8f18fc3`. This plan resolves the 12 High/Medium
ones (#1–#10, #12, #20); the 17 Low items stay open. Exploration confirmed that
none of the 12 needs a guest-agent change — #6/#7 live in the host helper, #12
in the runtime helper, the rest in the CLI — so agent pinning is not a
constraint and no protocol version is bumped.

Decisions made with the user (final):

| Topic | Decision |
|---|---|
| Scope | High + Medium only (12 issues) |
| Delivery | One commit per issue on `main`; cross-cutting changes get their own commit first |
| Validation | Unit tests + full offline suite per commit; **one** batched live pass on a single VM after all fixes |
| Docs | Code/test commits only; a final commit adds a roll-up `Docs/CLI-Fixes-<date>.md` and flips Status lines in the open-issues doc |
| #1 | `--parallel` stays a bare flag = two at once (Virtualization's two-macOS-guest cap); delete hidden `--parallel-limit`; targeted error for `--parallel <n>` |
| #2 | `exec` command args use `.postTerminator`; name only from before `--` |
| #3 | `cp` expands a directory destination to `<dir>/<basename>` host-side, both directions |
| #4/#5 | Reuse the `jobs list` line: `RUNNING <jobID> pid=<n>`; inspect adds ` outputPending=<bool>` |
| #7 | Offset past end → `Error: --from-offset N is beyond the transcript end (L bytes).`, exit 1 |
| #8 | Help/error placeholders become `NAME:/absolute/path` |
| #9 | `parsing: .unconditional` on every numeric option repo-wide + range validation where missing |
| #10 | `validateIdentifier(_:kind:)` for VM/snapshot/template/config-derived names |
| #12 | (a) all failed table results → stderr with `Error:` prefix; (b) new `pomme ui keys` subcommand; key errors name the token |
| #20 | Memory only, **no disk floor**; exact image minimum when the image is local, else a 4 GiB floor; applied to every create path, dry-run and real, including `--from-template` |

Implementation choices I resolved from the code (not user decisions): strip
nothing in the writer — instead remove the `ERROR:`/`ERROR ` prefixes at the
eight formatter sites (`PommeApplication.swift:621,967,2747,2955,2971,2990,3002`,
`CreateConfigStore.swift:403`) so the writer adds the one canonical `Error: `;
`--from-offset` becomes `Int64` with `--from-offset must not be negative.`;
`--uid/--gid` stay `UInt32` (ArgumentParser's "invalid value" is accurate);
executor rejects parallelism > 2 rather than clamping; the helper's
`terminal.logs` failure envelope gains optional `fromOffset`/`transcriptOffset`
keys (CLI↔helper channel, additive).

## Step 0 — land this plan in the repo

Copy this file verbatim to `Docs/Issues/2026-09-14-cli-open-issues-plan.md`
(plan mode prevented writing it there) and commit it alone:
"Plan the fixes for the 2026-09-14 High and Medium CLI issues".

## Commit sequence

Cross-cutting first (C1–C3), then the per-issue commits. Each commit: focused
suites + full `PommeCLITests` target green, body in the repo's prose style
ending with `Offline suite: N tests, 0 failures.` (baseline 945) and the
`Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` trailer.

### C1 — Failed table results go to stderr with `Error:` (#12a)

- `Sources/PommeCLI/CLI/Commands/CommandSupport.swift` `CLIOutputWriter.write(_:options:)` (:93-154).
  Keep the frame/foreground branches first (foreground non-zero exits are
  `ok:false` *with* stream frames and already route `error` to stderr). Guard
  the `terminal.logs` branch (:138) with `result.ok` so a failed logs result
  falls through. Fallback: `ok` → `print(text)`; else `Error: <text>` to
  `STDERR_FILENO` (multi-result: `Error: <name>: <text>`, skip the stdout
  header). Same rule in `write(payload:text:options:)` (:224-234).
  Extract an internal pure `tableText(for:) -> (fd, text)?` so it is testable.
- Remove the `ERROR` prefixes at the eight formatter sites listed above.
- Exit path unchanged (`throw ExitCode(...)` :152 prints nothing).
- Tests: `Tests/PommeCLITests/CLI/CommandSupportTests.swift` — failed fallback
  → stderr + prefix; ok → stdout; foreground payload → nil. Integration script
  `expect_failure` greps already read stderr; no change.

### C2 — Numeric options accept negatives and validate range (#9)

Add `parsing: .unconditional` to every numeric `@Option`:
- `UIUtilityCommands.swift` `--x/--y` (:172-173; add `help:` and a
  `validate()` requiring finite ≥ 0: `--x must be a finite display coordinate of zero or more.`),
  `--max-steps/--confidence/--model-timeout` (:220-222; range already in `SettingsAIRequest.parse`).
- `ConfigIPSWCommands.swift` `--limit` (:136; `validate()` already rejects < 1).
- `CommandSupport.swift` `TimeoutOptions.timeout` (:36); add `validate()` with
  the same finite > 0 guard as `value()` (ArgumentParser runs `validate()` on
  option groups — verified `OptionGroup.swift:63`).
- `LifecycleCommands.swift` start/restart `--timeout` (:360, :407); move the
  `> 0` guard from `run()` into `validate()`.
- `GuestCommands.swift` `--offset/--count` (:403-407), `--uid/--gid` (:25-32).
- `TerminalSessionCommands.swift` `--from-offset` (:54, :92) → `Int64`, validate ≥ 0, convert at :75/:101.
- Tests: new `Tests/PommeCLITests/CLI/NumericOptionTests.swift`, parameterized
  over `(command, args, expectedSubstring)` feeding `-1` to each option and
  asserting the range message via `Type.fullMessage(for:)`; positive click
  parse added to `UIUtilityCommandTests`.
- Known side effect: `--timeout --json` now reports "'--json' is invalid" and
  `exec t1 --timeout -- cmd` is an invalid value; cover `--timeout 5 -- cmd` in C6.

### C3 — Identifier validation names its kind (#10)

- `Sources/PommeCLI/Support/Utilities.swift` :675-695 → `validateIdentifier(_:kind:)`
  with `enum PommeIdentifierKind: String { vm = "VM name", snapshot = "snapshot name", template = "template name", configDerived = "config-derived VM name" }`;
  `validateVMName` stays as a wrapper.
- `RunnerError.swift`: replace `invalidVMName(String)` with
  `invalidIdentifier(kind:value:)` (no external pattern matches exist);
  description `Invalid <kind> <value>. Use 1-64 ...` — byte-identical for `.vm`
  (integration script greps `Invalid VM name invalid/name`).
- Switch call sites: `SnapshotCommands.swift:164`, `VMSnapshotStore.swift:48` → `.snapshot`;
  `TemplateCommands.swift:56,70`, `PommeTemplateStore.swift:116`,
  `PommeProvisionedTemplate.swift:38`, `PommeCore.swift:2636` → `.template`;
  `CreateConfigStore.swift:327` → `.configDerived`.
- Tests: `SnapshotCommandTests.swift:56-64` asserts the `Invalid snapshot name` prefix;
  new `Tests/PommeCLITests/Support/IdentifierValidationTests.swift` over all kinds.

### C4 — `NAME:/absolute/path` placeholders (#8)

- `GuestCommands.swift` :362, :365, :400, :422 (matches `RunnerError.swift:203`).
- Test: `CopyCommand.helpMessage()` / `CatCommand.helpMessage()` contain `NAME:/absolute/path`.

### C5 — `--parallel` is a bare two-at-a-time flag (#1)

- `LifecycleCommands.swift`: help text → "Create config members two at a time
  instead of one after another (Virtualization allows at most two macOS guests)."
  Delete `parallelLimit` (:88-89) and its uses (:124, :157, :166-168).
  In `validate()`'s `--config` branch, **before** the direct-settings guard:
  `if parallel, let name, Int(name) != nil { throw ValidationError("--parallel takes no value; config creation runs at most two VMs at once.") }`.
  `run()` :178 → `parallel ? VMCreationExecutor.maximumParallelism : 1`.
- `CreateConfigStore.swift` `VMCreationExecutor`: `static let maximumParallelism = 2`;
  guard `1...2` with "Parallel creation runs at most 2 VMs at once."
- Tests: `CreateCommandTests.swift` — `--config c.yaml --dry-run --parallel 2`
  → targeted message; bare `--parallel` validates; `--parallel-limit` → unknown
  option; existing :143 still throws. `VMCreationPlanningTests.swift` —
  `parallelism: 3` throws.

### C6 — `exec` takes the name only from before `--` (#2)

- `GuestCommands.swift:159` → `@Argument(parsing: .postTerminator, ...)`.
  Covers `--pty` (same command). `pomme exec t1 /bin/echo` without `--` now
  errors "Unexpected argument" — say so in the commit body.
- Tests: new `Tests/PommeCLITests/CLI/ExecCommandTests.swift`: `-- /bin/echo hi`
  → `name == nil`; `t1 -- ...`; `t1 -d --pty -- /bin/sh`; `t1 --timeout 5 -- cmd`;
  `t1 /bin/echo hi` throws; `t1 -- ls -la --json` keeps `--json` in the command.

### C7 — `cp` expands directory destinations (#3)

- `Sources/PommeCLI/GuestAgent/PommeAgentCLIModels.swift` `CopyRequest.parse(source:destination:)`
  (:591-595, CLI-only entry). Before `CopyEndpoint.parse` (which would strip
  the trailing slash): basename from the parsed source; guest destination
  ending in `/` → append basename; host destination ending in `/` **or** an
  existing directory (`fileExists(atPath:isDirectory:)`, relative paths
  resolved as `CopyEndpoint.parse` does) → append basename. No agent traffic
  precedes this.
- `CopyCommand` help mentions the expansion.
- Tests: `Tests/PommeCLITests/GuestAgent/PommeAgentCLIModelsTests.swift` — the
  five cases (guest `/tmp/` → `/tmp/h.txt`; host dir with and without slash;
  guest `/tmp` unchanged; explicit host file unchanged). Existing
  `PommeGuestFileTransferTests.preservesUnsafeDestinations` unaffected.

### C8 — Detached `exec` prints the job line; timeout text (#4)

- `PommeApplication.swift`: extract internal `backgroundJobText(_:includeOutputPending:)`
  (synthesize `state` from `exited`, call `jobSummary` :3007) and an internal
  pure `guestRequestText(for:payload:)` used by `guestRequestUnchecked`
  (:808-876). `.startBackground` with `result.detached == true` →
  `RUNNING <jobID> pid=<n>` (payload shape from `correlatedResultJSON`
  `PommeCore.swift:4188`). `shell -d` shares the path.
- `PommeCore.swift:4161,4164` and `PommePublicPTYRelay.swift:298`: timeout text
  → "Foreground command timed out; the guest job is still running. Run
  `pomme jobs list <vm>` to find its ID, then `pomme jobs wait` or `pomme jobs kill`."
- Tests: new `Tests/PommeCLITests/Operations/PommeApplicationGuestTextTests.swift`
  with synthetic payloads.

### C9 — `jobs inspect` prints the job line (#5)

- `guestRequestText`: `.jobStatus` → `backgroundJobText(result, includeOutputPending: true)`
  → `RUNNING <id> pid=<n> outputPending=false` / `EXITED <id> pid=<n> exit=0 outputPending=true`.
- Tests in the C8 suite (running and exited payloads).

### C10 — `sessions` honors the helper failure envelope (#6)

- `PommeApplication.swift` `terminalSessionControl` (:757-792): extract internal
  `terminalSessionText(operation:response:)`; when `response["ok"] == false`
  return `response["error"]` (fallback "The terminal session operation failed.")
  before the per-operation switch. `result(...)` already sets `ok:false`/exit 1;
  C1 renders `Error: The terminal session was not found.` on stderr.
- Tests: new `Tests/PommeCLITests/Operations/PommeTerminalSessionTextTests.swift`
  — failure envelopes for inspect/list/logs; success summary unchanged.

### C11 — `sessions logs` past the end names the range (#7)

- `PommeDurableTerminalSession.swift`: add `PommeDurableTerminalError.offsetBeyondEnd(offset:length:)`;
  `validatedCursor` (:507-510) throws it (offset == length still passes).
- `PommeCore.swift` `terminalSessionControlResponse` `"terminal.logs"` (:3688-3691):
  catch it and return `{"ok":false,"error":..., "hostExitCode":1, "fromOffset":N, "transcriptOffset":L}`.
- `terminalSessionText` (C10): for `terminal.logs` failures with both numbers →
  `--from-offset N is beyond the transcript end (L bytes).`
- `SessionsLogsCommand.run` unchanged (the writer's `ExitCode(1)` ends the loop).
- Tests: `PommeDurableTerminalSessionTests.swift` — `logs(from: length)` empty,
  `logs(from: length+1)` throws the new case; text suite — exact message.

### C12 — `pomme ui keys` and key errors that name the token (#12b)

- `Sources/PommeCLI/UIAutomation/HeadlessInputModels.swift` `HostDisplayKey`:
  one static `namedKeys` table (all cases of `lookup` :128-183) and
  `modifierPrefixes` (:185-195); rewrite `lookup` to consult them (identical
  behavior; `+`→`-` normalization kept); expose `vocabulary` for the CLI.
- `UIUtilityCommands.swift`: new `UIKeysCommand` (`keys`, no VM argument,
  `GlobalOptions`): table = named keys with aliases, modifier prefixes with
  aliases, a line for single characters, a line for chaining/`+`; `--format json`
  via `CLIOutputWriter.write(payload:text:options:)`. Register in
  `UICommand.subcommands` (:9), `CommandCatalog.groups` (:309), `agentHelp` (:319).
- `PommeRuntimeUIController.swift` :79 → "Unsupported key '<key>'. Run `pomme ui keys` for the supported names.";
  :89-94 → "... '<name>' at index <i> of the key sequence ...". Text still
  travels as `payload["error"]` through `uiUnchecked` (:888-896); C1 prefixes it.
- Tests: new `Tests/PommeCLITests/UIAutomation/HostDisplayKeyVocabularyTests.swift`
  (every name/alias/prefix resolves; `cmd+shift+t` == `cmd-shift-t`; names
  unique; bogus → nil); `PommeRuntimeUIControllerTests.validatesKeysBeforeDispatch`
  asserts the new wording and an index for `["shift","a"]`;
  `UIUtilityCommandTests` parses `UIKeysCommand` and finds `keys` in help/agentHelp.
  Integration script: `ui keys` table and JSON checks.
- Docs: README `ui` example block gains `pomme ui keys`; `Docs/Architecture.md:81` lists `keys` (local, no helper route).

### C13 — Create enforces the guest memory minimum (#20; memory only)

- `RunnerError.swift`: `memoryBelowProvisionalFloor(requested:minimum:)` —
  "The configured RAM X is below the provisional guest minimum 4.29 GB. The
  restore image's exact minimum is enforced once the image is present; no
  supported image needs less."
- `PommeCore.swift`:
  - `PommeLocalRestoreImageIdentity` gains `minimumMemoryBytes` (set in
    `qualifyRestoreImage` :2127-2139, its only constructor).
  - `validateMemorySize` (:2153) becomes internal, taking `minimumGuestMemory: UInt64?`.
  - `provisionalGuestMemoryFloorBytes = 4_294_967_296`; `validateProvisionalMemoryFloor(_:)`
    (host VZ min/max, then the floor).
  - `cachedRestoreImageURL(for:in:)` factored out of `downloadFirmware`
    (:4678-4697: same file name + `fileSize == filesize` rule); `downloadFirmware`
    uses it. Never downloads.
  - `dryRunMemoryCheck(memoryBytes:source:vmName:)` with
    `source ∈ {localImage(path), firmware(IPSWMEFirmware), template(manifest)}`:
    floor first (offline, fast); then if an image is local (given path / cached
    IPSW / `manifest.restoreImagePath` still a regular file) load it and apply
    the exact minimum; else log "Memory check is provisional: the restore image
    is not present locally, so only the 4 GiB floor was applied." Returns
    `{minimumBytes, provisional}` for the payload.
  - Real creates: call `validateProvisionalMemoryFloor` in `createProvisioningPayload`
    (:1850-1875) before `prepareProvisioning` (i.e. before any download); the
    later exact check is a superset. Covers direct, config, and template
    (template real creates previously had no guest minimum — note in the body).
- `LifecycleCommands.swift`: run the floor at the top of `CreateCommand.run()`
  after `validateVMName`; direct dry-run (:227-262) and template dry-run
  (:289-314) call `dryRunMemoryCheck` and add `memoryMinimum: {bytes, provisional}`
  to the payload.
- `CreateConfigStore.swift`: `VMCreationExecutionDependencies` gains
  `dryRunPreflight` (default `{ _ in [:] }` so existing tests compile);
  `execute`'s dry-run loop becomes async and merges the preflight payload or
  returns an `ok:false` result in `install`'s failure shape.
- Tests: new `Tests/PommeCLITests/CLI/CreateMemoryPreflightTests.swift`
  (floor rejects 512 MiB / accepts 4 GiB; `cachedRestoreImageURL` hit/miss/
  fallback name; template with missing image → provisional; 512 MiB throws
  before touching the source); `VMCreationPlanningTests` — injected failing
  preflight → `ok:false`, zero installs. Integration script: dry-run with a
  missing `--restore-image` and `--memory 512MB` fails on the floor first.
- README create section: one sentence on the floor/exact check.

## Verification

Per commit (offline, via XcodeBuildMCP on scheme `pomme`):
`-only-testing:PommeCLITests/<Suite>` for the suites named in each commit, then
the full `PommeCLITests` target for the "Offline suite" line. Run
`Tests/PommeIdentifierAudit.sh` after C3 and C12 (new identifiers).

After C13:
1. `rtk proxy bash Scripts/build-local.sh` (signed Release → `~/.local/bin/pomme`);
   record the SHA-256.
2. `Tests/PommeCLIIntegrationTests.sh --runner ~/.local/bin/pomme --no-build`
   with the new checks (C5 `--parallel 2`, C2 `ui click --x -1`, C3 snapshot
   name, C6 `POMME_VM_NAME=invalid/name pomme exec -- /bin/echo` proving the
   name came from the env, C12 `ui keys`, C13 floor).
3. No-VM repros against the signed binary: #1, #2 (parse), #8 (`--help`), #9,
   #10, #20 (`--from-template mdmready --memory 512MB --dry-run`; `--version
   latest --memory 512MB --dry-run`; `--memory 4GB` variants exit 0 with
   `memoryMinimum` in `--json`).
4. One live session — `pomme create t1 --from-template mdmready --memory 4GB`
   (40 GB inherited; per memory, 4 GB/40 GB, check for orphaned VZ services first):
   - #6: `sessions inspect t1 00000000-...` → stdout empty, stderr `Error: The terminal session was not found.`, exit 1.
   - #7: PTY session via `exec -d --pty --json -- /bin/sh -c "sleep 120"`; `logs --from-offset 999999` → range error; `--from-offset <length>` → empty, exit 0; `--from-offset 0` unchanged; terminate.
   - #4: `exec t1 -d -- /bin/sleep 30` → `RUNNING <id> pid=<n>`; `shell t1 -d 'sleep 30'` same shape; `exec --timeout 1 -- /bin/sleep 5` → exit 124 and the new sentence.
   - #5: `jobs inspect` running and, after `jobs wait`, exited lines; `jobs kill` on an unknown UUID → `Error:` on stderr.
   - #3: `cp h.txt t1:/tmp/` → `Copied 6 bytes.` and `cat t1:/tmp/h.txt` → `hello`; `cp t1:/tmp/h.txt out/` and `... out` → `out/h.txt`; explicit file path still works.
   - #12: `ui keys` (table + JSON); `ui key t1 bogus-key` → `Error: Unsupported key 'bogus-key'. Run \`pomme ui keys\`...`; `ui key-sequence t1 shift a` → index 0 named; `ui key t1 cmd+shift+t` and `key-sequence t1 left right` exit 0.
   - #2: `POMME_VM_NAME=t1 pomme exec -- /bin/echo hi` → `hi`.
   - #9/#10 against the live VM once each (`ui click --x -1`, `snapshot create t1 "bad/snap"`).
   - `pomme delete t1 --force`.
5. Final docs commit: `Docs/CLI-Fixes-2026-09-<date>.md` (one section per issue:
   cause, change, live evidence, Validation list) and flip each resolved
   issue's Status in `Docs/Issues/2026-09-14-cli-open-issues.md` to
   `Resolved (<date>; <commit>)`, leaving the 17 Low items and the header
   note accurate.

## Deferred (out of scope, noted for the Low pass)

`cp`/`cat` never consult `POMME_VM_NAME`; a guest directory destination given
without a trailing slash still fails with the receipt wording (#17); the
`raw`/`jsonl` formats (#26); the root-usage bug for `run()`-thrown
`ValidationError`s (#24) — the new C5 message is thrown from `validate()`, so
it keeps the `create` usage line and is not affected.
