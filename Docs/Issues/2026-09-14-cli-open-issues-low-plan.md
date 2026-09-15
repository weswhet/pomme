# Plan: resolve the Low CLI issues from 2026-09-14

## Context

`Docs/Issues/2026-09-14-cli-open-issues.md` listed 29 defects; the 12 High and
Medium ones were fixed on 2026-09-15 (`Docs/CLI-Fixes-2026-09-15.md`). This
plan covers the 17 remaining **Low** issues: #11, #13–#19, #21–#29. Facts were
re-verified against `5ebd40f`, so line numbers below are current.

Three of the seventeen (#15, #16, #17c) are guest-agent changes. A guest-side
fix reaches only VMs created after the new host build is installed (template
clones pin the running executable's digest, `PommeCore.swift:2042`; `agent
repair` reinstalls the pinned digest; there is no `agent update`). Existing VMs
keep their agent. The plan's live pass creates a fresh `t1`, so it covers them.

Decisions made with the user (final):

| Topic | Decision |
|---|---|
| Delivery | Same as the previous pass: one commit per issue on `main` (cross-cutting first), unit tests + full offline suite per commit, one batched live VM pass at the end, one final docs commit |
| #26 | Remove `raw` from `--format`; `jsonl` emits one JSON object per element for list-shaped commands |
| #15 | Guest processes get `HOME`, `USER`, `LOGNAME`, `SHELL` from the passwd record of the effective user; explicit `--env` wins; `PATH` untouched |
| #19 | Reject unknown config keys with the dotted path and the known keys named |
| #25 | `pomme --version` prints `pomme 0.1.0 (5ebd40f)` (`-dirty` suffix when built from a dirty tree; `unknown` when not built via `Scripts/build-local.sh`) |
| #16/#17 | Reuse the existing wire codes (`not-found`, `invalid-operation`, `operation-failed`); carry a specific message in the existing `Failure.message` field. No new codes, no allowlist change |
| #29 | `ui type` accepts `[<vm>] <text>` positionally via `UIPositionalTargetResolver.singleAction`, keeping `--text`/`--text-env` as explicit, mutually exclusive forms |

Choices resolved from the code (not user decisions): #24 and #25's runtime
half are solved together by giving `PommeBootstrap` its own parse/run/catch
loop instead of `PommeCLI.main` — ArgumentParser's `CommandConfiguration(version:)`
is deliberately **not** used because its built-in `--version` check runs on the
decode-failure path (`CommandParser.swift:226`) and would hijack `pomme create
--version` with a missing value; #25's build half uses Xcode's documented
`CREATE_INFOPLIST_SECTION_IN_BINARY` for command-line tools; #13 rejects a
missing parent directory rather than creating it (the issue's stated
expectation); #18 gives line/column only for syntax errors (Yams' schema
`DecodingError`s carry no mark); #28 needs no code, only help text and a Status
note; #14 and #28 share one commit (help text only).

## Step 0 — land this plan

Write this file to `Docs/Issues/2026-09-14-cli-open-issues-low-plan.md` and
commit it alone. **No implementation until asked.**

## Commit sequence

Each commit: focused suites + full `PommeCLITests` green, prose body ending
`Offline suite: N tests, 0 failures.` (baseline 972), attribution trailer.

### L1 — Subcommand usage for errors thrown from run() (#24)

- `Sources/PommeCLI/CLI/PommeBootstrap.swift:43`: replace `await PommeCLI.main(publicArguments)` with:
  1. `let command: ParsableCommand` from `PommeCLI.parseAsRoot(arguments)` inside its own `do/catch { PommeCLI.exit(withError:) }` (parse-time errors already carry the right stack).
  2. Run it (`AsyncParsableCommand` vs `ParsableCommand`).
  3. `catch let error as ValidationError`: print ArgumentParser's exact shape — `Error: <message>`, then `PommeCLI.usageString(for: type(of: command))` (public, resolves the full stack → `Usage: pomme status [<name>] …`), then `  See '<path> --help' for more information.` where `<path>` is the command words from the usage line — to stderr, exit 64. Empty-message `ValidationError` prints usage only, as AP does.
  4. Any other error → `PommeCLI.exit(withError:)` (unchanged for `CleanExit`, `ExitCode`, `RunnerError`; `.other` prints no usage, verified `MessageInfo.swift:126,169`).
- Put the renderer in an internal `PommeBootstrap.validationFailureText(_:command:)` so it is testable.
- Tests: new `Tests/PommeCLITests/CLI/PommeBootstrapTests.swift` — for `StatusCommand`, `DeleteCommand`, `TUICommand`, `ConfigInitCommand` the rendered text starts with `Error: …`, contains `Usage: pomme status`/`pomme delete`/… (built from `PommeCLI.usageString(for:)`), and ends with the `See 'pomme delete --help'` line; a `RunnerError` path is untouched.
- Integration: `expect_failure` for `status` (no name, no env) and `delete missing` (non-TTY) grep stderr for `Usage: pomme status` / `Usage: pomme delete` and `--force`.
- Risk: byte-for-byte parity with AP's format matters for scripts; the test pins it.

### L2 — `pomme --version` with an embedded build identity (#25)

- `Config/pomme-Info.plist` (new, checked in): `CFBundleIdentifier com.github.weswhet.pomme` (must equal the signing identifier so the designated requirement is unchanged), `CFBundleName pomme`, `CFBundleShortVersionString $(MARKETING_VERSION)`, `CFBundleVersion $(CURRENT_PROJECT_VERSION)`, `PommeGitCommit $(POMME_GIT_COMMIT)`.
- `pomme.xcodeproj/project.pbxproj` tool target (Debug `:223`, Release `:244`, where `GENERATE_INFOPLIST_FILE = NO` lives): add `INFOPLIST_FILE = Config/pomme-Info.plist` and `CREATE_INFOPLIST_SECTION_IN_BINARY = YES`. Not in `Shared.xcconfig` (the test bundle generates its own plist). `Config/Shared.xcconfig`: `POMME_GIT_COMMIT = unknown`.
- `Scripts/build-local.sh`: add `POMME_GIT_COMMIT=$(git describe --always --dirty 2>/dev/null || echo unknown)` to the existing `--extra-args` build settings. `Makefile`/`build-release-pkg.sh` keep deriving the pkg version from the xcconfig (unchanged).
- `Sources/PommeCLI/Support/PommeBuildInfo.swift` (new): `init(dictionary:)` reading `CFBundleShortVersionString` and `PommeGitCommit` (missing/empty/unexpanded `$(…)` → `unknown`), `static let current = PommeBuildInfo(dictionary: Bundle.main.infoDictionary ?? [:])`, `versionLine` = `pomme <version> (<commit>)`.
- `PommeBootstrap`: before parsing, `if arguments == ["--version"] { print(PommeBuildInfo.current.versionLine); exit(0) }`. Add a `discussion:` to `PommeCLI`'s configuration mentioning `pomme --version`.
- Delete the dead `PommeHelp`/`PommeHelpPage` blob (`RunnerError.swift:171-215`, hard-codes `pomme 0.1.0`, unreferenced).
- Tests: `PommeBuildInfoTests` — dictionary → line; missing keys → `pomme unknown (unknown)`; `$(POMME_GIT_COMMIT)` literal → `unknown`. (The test bundle compiles `Sources/PommeCLI` directly, so `Bundle.main` there has no section; the real binary is asserted by the integration script.)
- Integration: `pomme --version` matches `^pomme <MARKETING_VERSION from Config/Shared.xcconfig> \(.+\)$`; `pomme create --version` (missing value) still reports `Missing value for '--version <version>'`.
- Post-build: run `Tests/LocalBuildInstall.sh` and `Tests/PackagingIdentity.sh` — the embedded plist changes the binary; the designated requirement must still match.
- Risk: codesign derives the identifier from `CFBundleIdentifier` when a plist is present; keeping it equal to the current identifier keeps Keychain continuity (AGENTS.md).

### L3 — Drop `raw`; per-element `jsonl` (#26)

- `CommandSupport.swift:6-12` `CLIOutputFormat` → `table, json, jsonl`; help `:19` → "Output format: table, json, or jsonl."; every `case .table, .raw` (`:116`, `:286`, `GuestCommands.swift:71-76`, `TerminalSessionCommands.swift:65-70`) → `.table`; `agent-help` `UIUtilityCommands.swift:352` drops `raw`.
- `write(payload:text:options:)` gains `jsonlCollection: String? = nil`; for `.jsonl` with a key present, emit one `jsonLine` per element of `payload[key]` (zero lines for an empty collection), else the whole payload. Callers: `list` (`vms`, `LifecycleCommands.swift:368`), `config render` (`vms`, `ConfigIPSWCommands.swift:119`), `ipsw list` (`firmwares`, `:167`), `template list` (`templates`, `TemplateCommands.swift:145`), `snapshot list` (`snapshots`, `SnapshotCommands.swift:220`), `tools` (`groups`, `UIUtilityCommands.swift:315`), `ui keys` (emit `namedKeys` then `modifierPrefixes`, each element tagged `"kind": "key"|"modifier"`, `:196`).
- `PommeOperationResult` gains `jsonlCollectionKeyPath: [String]?`; `terminalSessionList` sets `["sessions"]`, `jobList` sets `["result","jobs"]`; `write(_ results:)`'s `.jsonl` branch splits when set. `status`/`inspect` already emit one object per VM.
- Tests: `CommandSupportTests` — a pure `jsonlLines(payload:collection:)` returns one line per element, `[]` for empty, the whole payload when the key is absent; `GlobalOptions.parse(["--format","raw"])` throws.
- Integration: `list --format jsonl` with an empty inventory → empty stdout, exit 0; `ui keys --format jsonl` → every line parses as JSON with `kind`; `list --format raw` → rejected naming `'table', 'json' or 'jsonl'`.

### L4 — Help text for every option; `config render` wording (#14, #28)

- `UIUtilityCommands.swift:99` (`--replace`) and `:256-264` (nine `ui ai settings` options) get `help:` with defaults stated. `SettingsAIMode` (`SettingsAIModels.swift:13-23`) becomes `CaseIterable, ExpressibleByArgument`; `--mode` becomes `SettingsAIMode = .suggest` so AP lists `suggest, step, loop`; keep `SettingsAIMode.parse` for the JSON payload path.
- `ConfigRenderCommand` (`ConfigIPSWCommands.swift:101-120`): abstract → "Resolve a config's versions and print the creation plan." so `--format` is unmistakably the presentation format. `--config` help already names input formats. No code change for TOML.
- Tests: `UIUtilityCommandTests` — `UIAISettingsCommand.helpMessage()` contains `suggest, step, loop` and no option line lacks a description; `ConfigRenderCommand.helpMessage()` contains "creation plan".
- Integration: extend the existing `ui ai settings --help` check to grep `suggest, step, loop`.

### L5 — `ui type` accepts positional text (#29)

- `UITypeCommand` (`UIUtilityCommands.swift:94-128`): `@Argument var arguments: [String] = []` with help `[VM name] text. Uses POMME_VM_NAME when the VM name is omitted.`; `validate()`: exactly one of (positional text, `--text`, `--text-env`); with `--text`/`--text-env` the positional list may hold only the VM name. `singleAction(:43)` learns the placeholder word `text` for action `"type"`.
- Tests: parse `["t1","hi"]`, `["hi"]` with env target, `["t1","--text","hi"]`, and the three conflicting forms; add `UITypeCommand` to `UIUtilityCommandTests` (none exists today).
- Integration: `env POMME_VM_NAME=invalid/name pomme ui type hi` → `Invalid VM name invalid/name` (proves the positional is text, not a VM name).

### L6 — Validate the screenshot output path before capture (#13)

- `UIScreenshotCommand` (`UIUtilityCommands.swift:222-241`) gains `validate()`: absolutize with `PommeCore.absoluteHostPath`; parent must exist and be a directory → `ValidationError("No such directory: /nonexistentdir")`; leaf must not be a directory → `ValidationError("<path> is a directory; give a file path.")`. Same uid and filesystem as the helper (`PommeCore.swift:3566-3581`), so the check is authoritative; helper-side checks stay.
- Tests: `UIUtilityCommandTests` with a temp directory (valid path passes; missing parent and directory leaf throw the exact messages).
- Integration: `ui screenshot missing --output /nonexistentdir/s.png` → exit 64, `No such directory: /nonexistentdir` (validate runs before VM lookup).

### L7 — Missing snapshot is "not found", not "unsafe" (#11)

- `VMSnapshotStore.swift`: `loadManifest(at:)` (`:220`) first `lstat`s; `ENOENT` → new `RunnerError.snapshotNotFound(vm:name:)` → `No snapshot named nosnap exists for t1.` (VM name from the bundle's root name); every other failure keeps `Unsafe snapshot directory …` from `requireDirectory` (`:296-301`). Covers `delete` and `restore`.
- Tests: `VMSnapshotStoreTests` — delete and restore of an absent name throw `snapshotNotFound` with that text; the existing unsafe-link test (`:157`) still gets "Unsafe".
- Live: `snapshot delete t1 nosnap --force`, `snapshot restore t1 nosnap --force`.

### L8 — `delete` reports the bundle path (#22)

- `PommeCore.destroyVMPayload` (`:1594-1616`) adds `"bundlePath": reference.bundle.rootURL.path` (the key was never set; the diagnosis in the issue was wrong). The TUI detail pane already lists `bundlePath`.
- Tests: `VMDestroySafetyTests` — a temp app-support root with a stopped bundle directory: payload carries `bundlePath` and the directory is gone.
- Live: `delete t1 --force` → `OK destroyed name=t1 bundle=/…/t1.bundle`.

### L9 — `inspect` prints each field once (#23)

- `PommeApplication.swift`: `formatInspect` (`:2960-2975`) prints `pommeSocket:` from the `pommeSocket` key (drop the never-populated `controlSocket` label); `formatHealth` (`:2977-2990`) and `formatCapabilities` (`:2992-3000`) take `includeGuestAgent: Bool = true`; `detailedInspect` (`:568-599`) passes `false` and drops the health payload's `vmState`/`bootMode` lines (the health payload never carried them, `PommeCore.swift:1535-1551`). The TUI health view (`PommeTUI.swift:341`) keeps its guestAgent line.
- Make the three formatters internal; tests: new `PommeInspectTextTests` with synthetic payloads — `guestAgent` appears once, `pommeSocket:` carries the path, no empty `vmState:`/`bootMode:` lines, `check.*` and `capabilities:` present.
- Live: `inspect t1` visual check.

### L10 — `pause`/`resume`/`stop` say what happened (#21)

- `VMRuntime.pause/resume/stop` (`VMRuntime.swift:215-225, 200-211`) return `Bool` (whether the framework call happened); `PommeCore.runtimeControlResponse` lifecycle branch (`:3708-3720`) adds `"changed": Bool` (additive JSON).
- `PommeApplication.pause/resume/stop` (`:287-326`) text from `changed`: `OK paused` / `VM is already paused.`, `OK resumed` / `VM is already running.`, `OK stopped` (`OK stopped (forced)` with `--force`) / the existing `VM is already stopped.`; also set `payload["response"]` for the TUI. Extract `lifecycleText(operation:changed:force:)`.
- Tests: pure `lifecycleText` cases; pure reply-builder test for `changed`; `VMPauseResumeTransitionTests` unchanged.
- Live: pause ×2, resume ×2, stop ×2, `stop --force`.

### L11 — Device identifiers are validated; catalog errors are named (#27)

- New `IPSWDeviceIdentifier.validate(_:)` (`^[A-Za-z]+[0-9]+,[0-9]+$`) used by `ipsw list`/`ipsw download` `--device`, `create`/`template create` `--ipsw-device`, and `CreateConfigStore.validate` for `ipswDevice` → `--device must be an Apple model identifier such as Mac16,10.` (config: `ipswDevice must be …`).
- `PommeCore.fetchIPSWMEDevice` (`:4739-4759`): 404 → `RunnerError.unknownDeviceIdentifier(id)` → `Unknown device identifier Bogus1,1.`; other non-2xx → `RunnerError.catalogRequestFailed(statusCode:)` → `The restore-image catalog request failed with HTTP N.`; `downloadFailed` stays for the byte download (`:4847`). Put the status→error mapping in a pure internal `catalogFailure(statusCode:identifier:)`.
- Tests: regex accept/reject table; `catalogFailure` 404 vs 500.
- Integration: `ipsw list --device Bogus` → exit 64 with the shape message (no network). No-VM repro (network): `ipsw list --device Bogus1,1` → `Unknown device identifier Bogus1,1.`

### L12 — Config decode failures in plain words (#18)

- `CreateConfigStore.load` (`:125-158`) wraps each decoder in `catch let error as DecodingError` → `RunnerError.configDecoding(path:message:)` rendered `<path>: <message>`, via a pure `ConfigDecodingMessage.describe(_:)`:
  `keyNotFound` → `Config is missing required key 'hardware.memory'.` (codingPath + key); `typeMismatch`/`valueNotFound` → `Config key 'hardware.memory' must be a string.` (type names mapped: string, integer, true or false, list, mapping); `dataCorrupted` whose `underlyingError` is a Yams `YamlError` with a `Mark` → `Config is not valid YAML at line L, column C: <problem>`; `TOMLDecodingError.invalidSyntax(line:column:message:)` → the TOML equivalent; JSON → `Config is not valid JSON: <debugDescription>`; `dataCorrupted` wrapping a `RunnerError` (Yams wraps foreign errors, `Decoder.swift:140-165`) → that error's own message (needed by L13).
- Tests: `VMCreationPlanningTests` — missing `schemaVersion` (yaml/json/toml), `hardware.memory: 4` (type), YAML with a tab-indented syntax error (line/column present), malformed JSON, malformed TOML; none contain `CodingKeys(`.
- Integration: `config validate cfgbad.yaml` → exit 1, stderr contains `missing required key 'schemaVersion'`, not `CodingKeys`.

### L13 — Unknown config keys are rejected (#19)

- New `Sources/PommeCLI/Support/StrictDecoding.swift`: internal `AnyCodingKey` and `rejectUnknownKeys(_ container:allowed:path:)` throwing `RunnerError.hostCommandFailed("Config key 'hardware.memroy' is not recognized. Known keys: diskSize, memory.")`. (The three private `AnyCodingKey` copies — `PommeTerminalSessionModels.swift:1079`, `PommeSecurityWorkflowJournal.swift:1362`, `PommeOwnerCredentialStore.swift:539` — are left alone; migrating them is a separate cleanup.)
- `VMCreationConfigV1`, `Hardware`, `Credentials`, `Workflow`, `MDM` (`CreateConfigStore.swift:7-60`): explicit `CodingKeys: String, CodingKey, CaseIterable` and a custom `init(from:)` that calls `rejectUnknownKeys` before decoding; encoding stays synthesized. `rejectUnsupportedShape` (`:226-236`) stays so `restore`/`replaceExisting`/`failureCleanup` keep their "regenerate" message (its test at `:31-47` still passes).
- Tests: unknown top-level key and `hardware.memroy` in yaml/json/toml assert the exact message; the round-trip test (`:6`) still passes.
- Integration: `config validate goodbogus.yaml` → exit 1, `Config key 'bogusKey' is not recognized`.

### L14 — Host-side file errors say what is wrong (#17a, #17b)

- `CopyRequest.parse`/`validatedEndpoint` (`PommeAgentCLIModels.swift:641-646`): a **host source** must exist, be a regular file (symlinks rejected, matching the transfer's `O_NOFOLLOW`), and be readable → `RunnerError.hostFileUnavailable(path:reason:)` → `Host file /nonexistent.txt does not exist.` / `Host path /tmp is a directory, not a file.` / `Host file … is not readable.` / `… is a symbolic link.`; a **host destination**'s parent must exist → `Host directory /x does not exist.` Runs before any agent traffic.
- `PommeGuestFileTransfer.upload` (`:49-50`) and `download` (`:101`): the host-side `openRegular`/`createAdjacentStage` `invalidRequest` (TOCTOU backstop) is re-thrown as `hostFileUnavailable` instead of "envelope is invalid".
- `PommeApplication.performAuthenticatedAgentOperation` (`:1811-1836`): on failure throw `RunnerError.hostCommandFailed(response["error"] as? String ?? "The authenticated PommeAgent operation did not complete.")` so the helper's `Pomme agent request failed (<code>): <message>` reaches the operator. All 14 call sites become more specific; the MDM poll at `:1846` swallows errors and is unaffected. Extract a pure `authenticatedOperationFailure(response:)` for the test.
- Tests: `PommeAgentCLIModelsTests` — the five host-path cases; `PommeApplicationGuestTextTests` — `authenticatedOperationFailure` with and without `error`.
- Integration: `cp /nonexistent.txt missing:/tmp/x` → exit 1, `Host file /nonexistent.txt does not exist.` (fails before VM lookup).

### L15 — Guest failures carry a specific message (#16, guest half of #17)

- `PommeAgentOperationError` (`PommeAgent.swift:925-928`) gains `indirect case described(PommeAgentOperationError, message: String)`; `PommeAgentConnection.operationFailure` (`:96-118`) unwraps it: code from the inner case, message from the string (existing `Failure` redaction applies: a path containing token/password/secret collapses to the generic sentence — accepted). Existing `throws: PommeAgentOperationError.self` assertions are unaffected.
- `PommeProcess.spawn` pre-checks before `posix_spawn` (`:1436-1440`, where `ENOENT` is ambiguous): `access(path, X_OK)` → `described(.notFound, "No such executable: /nonexistent/bin")` or `described(.io, "Executable is not permitted: …")`; `stat(cwd)` → `described(.notFound, "No such working directory: /nonexistent")` or `described(.invalid, "… is not a directory")`. For identity-helper launches (`:1518-1560`, no message channel) the same checks run in the parent first. `PommePrivilege.resolve` (`:1094`) → `described(.notFound, "No such guest user: nosuchuser")` (and the uid/group variants).
- File transactions: `PommeAgentFileTransaction.openRegular`/`withVerifiedParent`/`createAdjacentStage` (`PommeAgentInstall.swift:819-934`) throw a new `PommeAgentFileTransaction.Failure { missing(path), notRegular(path, isDirectory), permission(path), unsafe(path) }` instead of `PommeAgentProtocol.Error.invalidRequest`; the guest `mapFileTransactionError` (`PommeAgent.swift:672-678`) maps `missing → described(.notFound, "No such file or directory: /nonexistent")`, `notRegular → described(.invalid, "/tmp is a directory")`, `permission → described(.io, "Permission denied: …")`, `unsafe → described(.invalid, "… is not a regular file path")`. Audit every other caller of those helpers (the Recovery installer, `PommeAgentPathWalkerTests`) and keep `invalidRequest` where an envelope is genuinely being validated.
- Result for the operator: `Error: Pomme agent request failed (not-found): No such executable: /nonexistent/bin`, `(not-found): No such working directory: /nonexistent`, `(not-found): No such guest user: nosuchuser`, `cat t1:/tmp` → `(invalid-operation): /tmp is a directory`.
- Tests: `PommeAgentExecutionOptionsTests` — missing executable, missing cwd, unknown user each yield `described` with the path/user in the message; `PommeAgentSessionFailureTests` — `operationFailure(.described(.notFound, …))` → `("not-found", message)` and the rendered `Pomme agent request failed (not-found): …`; `PommeGuestFileTransferTests`/`PommeAgentPathWalkerTests` — missing vs directory vs symlink map to the three failures.
- Live (fresh VM): the three `exec` repros and `cp h.txt t1:/nodir/x`, `cat t1:/nonexistent`, `cat t1:/tmp`.

### L16 — Guest processes get a login-like environment (#15)

- Lift `passwdRecord(uid:)` and the HOME/SHELL/USER/LOGNAME derivation from `PommeTerminalService.swift:540-566, 713-718` into an internal `PommeGuestIdentityEnvironment.defaults(for uid: uid_t) -> [String: String]` (GuestInternal); `PommeTerminalService` uses it.
- `PommeProcess.Options.mergedEnvironment()` (`PommeAgent.swift:1186-1193`): daemon env → overlay `defaults(for:)` of the effective uid (resolved identity, else `geteuid()`, root by default) → overlay the request's `environment` (explicit `--env` wins). `validateEnvironment` unchanged. `Docs/Protocols.md` and README's guest section state the four variables.
- Tests: `defaults(for: getuid())` equals `getpwuid` fields; `PommeAgentExecutionOptionsTests` launches `/bin/sh -c 'echo $LOGNAME'` and compares to `getpwuid(geteuid())` (derived, not inherited); an explicit `--env HOME=/x` still wins.
- Live (fresh VM): `shell t1 'echo $HOME'` → `/var/root`; `exec t1 --user pomme -- /bin/sh -c 'echo $HOME $USER'` → `/Users/pomme pomme`.

## Verification

Per commit: `xcodebuildmcp macos test` scheme `pomme` with the suites named
above, then the full `PommeCLITests` target for the "Offline suite" line;
`Tests/PommeIdentifierAudit.sh` after L2, L13, L15.

After L16:
1. `rtk proxy bash Scripts/build-local.sh`; record the SHA-256 and the `pomme --version` line. Run `Tests/LocalBuildInstall.sh` and `Tests/PackagingIdentity.sh` (Info.plist section touches signing).
2. `Tests/PommeCLIIntegrationTests.sh --runner ~/.local/bin/pomme --no-build` with the new checks from L1–L6, L11–L14 (≈14 additions).
3. No-VM repros against the signed binary: #24 (`status`, `delete t1`, `tui`, `config init`), #25, #26 (`list --format raw|jsonl`), #14/#28 (`--help`), #29 (parse), #13, #18, #19, #27 (network), #17a.
4. One live session, `pomme create t1 --from-template mdmready --memory 4GB` (installs the new agent): #15, #16, #17 (guest cases), #21, #22, #23, #11, plus `ui type t1 hi`, `ui screenshot t1 --output /tmp/s.png` (happy path), `sessions list`/`jobs list --format jsonl` with two entries (#26). `delete t1 --force` closes with the #22 line.
5. Docs commit: `Docs/CLI-Fixes-2026-09-<date>.md` (one section per issue: cause, change, live evidence) and flip the 17 Status lines in the open-issues doc to `Resolved (<date>; <commit>)`; #28's line notes the 09-12 record described input formats.

## Risks and follow-ups

- Guest-side commits (L15, L16) do not reach existing VMs; the roll-up must say so. Helper-side changes (L10, L14) take effect after a VM's helper restarts.
- `AnyCodingKey` duplication remains in three security files after L13 — candidate for a later cleanup commit.
- Removing `raw` (L3) is a documented-format removal; the commit body names it as deliberate.
