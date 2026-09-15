# Open CLI issues after the 2026-09-14 exploration

- **Status:** All issues are resolved as of 2026-09-15. The twelve High and
  Medium issues (#1–#10, #12, #20) are recorded in `../CLI-Fixes-2026-09-15.md`,
  and the seventeen Low issues in `../CLI-Fixes-2026-09-15-low.md`.
- **Binary under test:** `~/.local/bin/pomme` at commit `8f18fc3`, SHA-256
  `2ecacdebbf25bc96435c25e464f8c5473198ec37c1f6c8e441cc053b4f0e818f`,
  signed Release, Developer ID Application: Wesley Whetstone (2D8XQ77EBQ).
- **Fixture:** one VM `t1` cloned from the provisioned `mdmready` template
  (macOS 26.6.2 build 25G83, 40 GB disk, 8 GB memory, SIP disabled, AMFI
  override active, owner `pomme` with automatic login). Deleted afterwards.
- **Prior record:** `Docs/CLI-Exploration-2026-09-12.md`. Each issue keeps that
  document's number as `(#n)` so the two can be diffed.
- **Summary record for this run:** `Docs/CLI-Exploration-2026-09-14.md`.

Severity: **High** feature broken, **Medium** wrong or misleading behavior,
**Low** poor message or cosmetic.

Fixed since 2026-09-12 and therefore absent below: `start`/`restart` agent
readiness (#1, #2), `ui screenshot` (#28), `sip status` and `amfi status` on
26.6.2 (#35), and `create` leaving the VM stopped (#3, did not reproduce).

---

## 1. `--parallel <n>` is rejected together with `--config` (#11)

- **Severity:** High
- **Status:** Resolved (2026-09-15; b772ee6)
- **Area:** `create`
- **Source:** `Sources/PommeCLI/CLI/Commands/LifecycleCommands.swift:135`

### Reproduction

```sh
pomme config validate good.yaml          # Config is valid.
pomme create --config good.yaml --dry-run --parallel 2
```

`good.yaml`:

```yaml
schemaVersion: 1
name: cfgtest
versions: [26.6.2]
hardware:
  diskSize: 40GB
  memory: 4GB
boot: none
```

Observed, exit 64:

```text
Error: --config cannot be combined with a VM name or direct creation options.
Usage: pomme create [<options>] [<name>]
```

Bare `--parallel` with no value is accepted: `pomme create --config good.yaml
--dry-run --parallel` runs the planner and prints
`Would create cfgtest-26.6.2 from macOS 26.6.2 (25G83).`

### Expected result

`pomme create --help` documents `--parallel` as accepting an optional limit,
and a parallel limit is only meaningful for a multi-VM config run. The value
form should be accepted with `--config`.

### Impact

The only way to bound concurrency for a config-driven creation is to omit the
limit entirely, which is the opposite of what the flag is for. On a 16 GB host
an unbounded run is the case most likely to need a limit.

### Likely cause

The validation treats `--parallel` with an attached value as a "direct creation
option" and rejects the combination before the planner sees it. The bare flag
takes a different branch and is not classified that way.

---

## 2. `POMME_VM_NAME` is not honored by `exec` before `--` (#14)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; 7a690dc)
- **Area:** `exec`
- **Source:** `Sources/PommeCLI/CLI/Commands/GuestCommands.swift:149`

### Reproduction

```sh
POMME_VM_NAME=t1 pomme exec -- /bin/echo hi
```

Observed, exit 1:

```text
Error: Invalid VM name /bin/echo. Use 1-64 ASCII letters, numbers, dots,
underscores, or hyphens, starting with a letter or number.
```

`pomme exec t1 -- /bin/echo hi` works and prints `hi`.

### Expected result

The argument's own help text reads `VM name. Uses POMME_VM_NAME when omitted
before --.` With the variable set and the name omitted, the first token after
`--` must be treated as the executable, not the VM name.

### Impact

The documented environment-variable workflow does not work for the most common
guest command. Scripts that set `POMME_VM_NAME` once must still repeat the name
on every `exec`.

---

## 3. `cp` into a directory path fails with a data-integrity sounding error (#25)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; f76f7bd)
- **Area:** `cp`

### Reproduction

```sh
echo hello > h.txt
pomme cp h.txt t1:/tmp/
```

Observed, exit 1:

```text
Error: Guest file transfer failed after 6 bytes: The VM helper returned an
invalid response: Guest commit did not return a verified receipt; the
destination may have changed. The authenticated PommeAgent operation did not
complete.
```

The same copy to an explicit file path succeeds:
`pomme cp h.txt t1:/tmp/h.txt` prints `Copied 6 bytes.`

### Expected result

Either expand a trailing-slash destination to `<dir>/<basename>` the way `cp`
does, or refuse it up front with a message naming the real problem, for example
`Destination must be a file path, not a directory.`

### Impact

The wording states that the destination may have changed and that a commit
receipt could not be verified, which reads like guest-side corruption. The
actual cause is a malformed destination argument. An operator has no way to
tell those apart from the message.

---

## 4. Detached `exec` does not print its job ID (#15)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; 023ca2f)
- **Area:** `exec`, `jobs`

### Reproduction

```sh
pomme exec t1 -d -- /bin/sleep 30
```

Observed, exit 0, complete output: `OK`

```sh
pomme exec t1 -d --json -- /bin/sleep 20
```

Observed:

```json
{"hostExitCode":0,"streamFrames":[],"name":"t1",
 "requestID":"186c308d-8860-443a-be11-50c9e419a860",
 "result":{"detached":true,"jobID":"3b6be917-cfda-4eee-b73b-c99db830d685",
           "exited":false,"pid":699},
 "ok":true}
```

### Expected result

The table form should print the job ID, since every other `jobs` subcommand
requires it as a positional argument. The foreground timeout message also tells
the operator to "inspect the returned job ID", which is never printed.

### Impact

A detached job cannot be inspected, waited on, or killed without re-parsing
`--json` and reaching into the nested `result` object. `jobs list` is the only
other way to recover the ID, and it cannot distinguish two concurrent jobs
started from the same command line.

---

## 5. `jobs inspect` prints only `OK` (#18)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; 023ca2f)
- **Area:** `jobs`

### Reproduction

```sh
pomme jobs inspect t1 82fae8e3-a80b-4a2d-8838-c6e86db92123
```

Observed, exit 0, complete output: `OK`

With `--json`:

```json
{"name":"t1","result":{"outputPending":false,"pid":689,"exited":false,
 "jobID":"82fae8e3-a80b-4a2d-8838-c6e86db92123"},"ok":true,
 "requestID":"7812b1cf-...","streamFrames":[],"hostExitCode":0}
```

### Expected result

The table form should render state, pid, exit code, and output-pending, the way
`jobs list` already renders `RUNNING <id> pid=<n>`.

### Impact

The default output of an inspection command carries no information at all.

### Related

`jobs list` and `jobs wait` behave correctly. `jobs wait` on a still-running job
with `--timeout 2` exits 124 with `Timed out waiting for the background job.`,
and `jobs kill` on an unknown UUID exits 1 with a `not-found` agent error.

---

## 6. `sessions inspect` of a missing session prints `offset=` (#21)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; 9e397e6)
- **Area:** `sessions`

### Reproduction

```sh
pomme sessions inspect t1 00000000-0000-0000-0000-000000000000
```

Observed, exit 1, complete output:

```text
offset=
```

### Expected result

A message naming the missing session, as `sessions terminate` already does:
`The terminal session was not found.`

### Impact

A nonzero exit with a fragment of a formatter's output gives no indication of
what went wrong, and `offset=` looks like a truncated success line.

---

## 7. Reading past the end of a transcript reports an invalid helper response (#22)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; 9e397e6)
- **Area:** `sessions`

### Reproduction

```sh
pomme exec t1 -d --pty --json -- /bin/sh -c "sleep 60"   # yields sessionID
pomme sessions logs t1 <sessionID> --from-offset 999999
```

Observed, exit 1:

```text
Error: The VM helper returned an invalid response: Invalid terminal output.
```

Reading from offset 0 on the same session succeeds and returns empty output.

### Expected result

An offset beyond the transcript end is an ordinary condition. It should return
empty output, or refuse with a message naming the valid range.

### Impact

The message attributes an operator input error to a malformed helper response,
which points investigation at the transport rather than the argument.

---

## 8. `cat vm:/path` reads `vm` as a VM name (#24)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; 253c98c)
- **Area:** `cat`, `cp`
- **Source:** `Sources/PommeCLI/CLI/Commands/GuestCommands.swift:362,365,400`

### Reproduction

```sh
pomme cat vm:/tmp/x
```

Observed, exit 1:

```text
Error: No Pomme-owned VM named vm exists. Create it with `pomme create vm` or
run `pomme list`.
```

### Expected result

The argument help reads `vm:/absolute/path endpoint.` and `Host path or
vm:/absolute/path endpoint.`, in which `vm` is meant as a placeholder. The real
syntax is `<vmname>:/path`. Either the help should use `<name>:/absolute/path`,
or the literal prefix should be accepted.

### Impact

Following the help text verbatim produces an error naming a VM the operator
never referred to.

---

## 9. Negative option values are reported as a missing value (#37)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; d3197bd)
- **Area:** argument parsing, all commands with numeric options

### Reproduction

```sh
pomme ui click --x -1 t1
```

Observed, exit 64:

```text
Error: Missing value for '--x <x>'
Help:  --x <x>
Usage: pomme ui click [<name>] --x <x> --y <y> [--timeout <timeout>] ...
```

The 2026-09-12 run saw the same shape for `--limit -1`, `--timeout -5`, and
`--offset -1`.

### Expected result

Either accept the negative value and reject it in validation with a message
naming the allowed range, or report that the value is invalid. The value is
present; it is being consumed as an option token because it starts with `-`.

### Impact

The diagnostic points at the wrong problem, and there is no documented way to
pass a negative value even where one might be legitimate.

---

## 10. Invalid snapshot names are reported as invalid VM names (#32)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; d89a3be)
- **Area:** `snapshot`
- **Source:** `Sources/PommeCLI/CLI/Commands/SnapshotCommands.swift:164`

### Reproduction

```sh
pomme snapshot create t1 "bad/snap"
```

Observed, exit 1:

```text
Error: Invalid VM name bad/snap. Use 1-64 ASCII letters, numbers, dots,
underscores, or hyphens, starting with a letter or number.
```

### Expected result

`Invalid snapshot name bad/snap.` with the same character rules.

### Impact

The operator supplied a valid VM name and an invalid snapshot name, and the
error blames the VM name. The cause is that snapshot names are validated by
reusing `validateVMName`, whose message is hard-coded to say "VM name".

---

## 11. Deleting a missing snapshot reports an unsafe directory (#33)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 5257596)
- **Area:** `snapshot`
- **Source:** `Sources/PommeCLI/VM/VMSnapshotStore.swift:299`

### Reproduction

```sh
pomme snapshot delete t1 nosnap --force
```

Observed, exit 1:

```text
Error: Unsafe snapshot directory nosnap.
```

### Expected result

`No snapshot named nosnap exists for t1.`

### Impact

"Unsafe" suggests a security or integrity problem with an existing artifact
rather than a name that was never created. The safety check that produces the
message cannot distinguish absent from unsafe.

---

## 12. UI key errors have no prefix and no list of valid keys (#29)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; 60ecf25)
- **Area:** `ui`
- **Source:** `Sources/PommeCLI/UIAutomation/PommeRuntimeUIController.swift:79,92`

### Reproduction

```sh
pomme ui key t1 bogus-key
pomme ui key-sequence t1 shift a
```

Both observed, exit 1, complete output:

```text
Unsupported direct VM key.
```

### Expected result

An `Error:` prefix consistent with every other failure, the rejected token
named, and the supported key vocabulary listed or referenced. `shift a` is a
plausible modifier-plus-key form and its rejection gives no hint of the correct
spelling.

### Impact

There is no way to discover the valid key names from the CLI. `ui
key-sequence --help` does not enumerate them either.

---

## 13. A bad screenshot output directory is not validated before capture (#30)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 0ee2066)
- **Area:** `ui`

### Reproduction

```sh
pomme ui screenshot t1 --output /nonexistentdir/s.png
```

Observed, exit 1:

```text
You can't save the file "nonexistentdir" because the volume "Macintosh HD" is
read only.
```

A valid path works: `--output /tmp/shot.png` exits 0, prints `OK`, and writes a
1.3 MB PNG.

### Expected result

Validate the output path before capturing, and report
`No such directory: /nonexistentdir`.

### Impact

The message is a raw Foundation error that misattributes the cause to a
read-only volume. The capture work is performed and then discarded.

### Note

The 2026-09-12 run recorded a `frame_timeout` here instead. The underlying gap,
that the output path is never checked first, is unchanged; the symptom moved
when the framebuffer capture was fixed.

---

## 14. `ui ai settings` options have no help text (#31)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 5c55852)
- **Area:** `ui ai`

### Reproduction

```sh
pomme ui ai settings --help
```

Observed:

```text
OPTIONS:
  --mode <mode>           (default: suggest)
  --max-steps <max-steps> (default: 8)
```

### Expected result

Each option needs a description. `--mode` in particular has no discoverable
value vocabulary.

### Impact

The command's own overview says it is "Currently unavailable without a guest
accessibility bridge", so this is low priority, but the options are
undocumented if it becomes available.

---

## 15. `$HOME` is empty in `shell` (#17)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 5fb246d)
- **Area:** `shell`

### Reproduction

```sh
pomme shell t1 'echo $HOME'
```

Observed, exit 0, one empty line.

### Expected result

The owner's home directory, or documentation that the guest shell runs with a
deliberately minimal environment.

### Impact

Commands that depend on `$HOME`, including most tool installers and anything
resolving `~`, silently operate on the wrong path instead of failing.

---

## 16. Guest execution failures share one generic message (#16)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; dfb4f86)
- **Area:** `exec`

### Reproduction and observed output

```sh
pomme exec t1 -- /nonexistent/bin
# Pomme agent request failed (operation-failed): The requested operation could not be completed.

pomme exec t1 --cwd /nonexistent -- /bin/pwd
# Pomme agent request failed (operation-failed): The requested operation could not be completed.

pomme exec t1 --user nosuchuser -- /bin/id
# Pomme agent request failed (invalid-operation): The requested operation could not be completed.
```

All exit 1.

### Expected result

Distinct causes should be distinguishable: missing executable, missing working
directory, unknown user. The closed-vocabulary failure code is the only signal,
and it collapses the first two.

### Impact

Diagnosing a failing `exec` requires bisecting the arguments by hand.

---

## 17. Guest and host path errors in `cp`/`cat` are generic (#26, #27)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; a66ffd2, dfb4f86)
- **Area:** `cp`, `cat`
- **Source:** `Sources/PommeCLI/GuestAgent/PommeAgentProtocol.swift:160`

### Reproduction and observed output

```sh
pomme cp /nonexistent.txt t1:/tmp/x
# Error: Pomme agent request envelope is invalid.

pomme cp h.txt t1:/nodir/x
# Error: The authenticated PommeAgent operation did not complete.

pomme cat t1:/nonexistent
# Error: The authenticated PommeAgent operation did not complete.

pomme cat t1:/tmp --offset 0 --count 10        # /tmp is a directory
# Error: The authenticated PommeAgent operation did not complete.
```

All exit 1.

### Expected result

A missing host source file is a host-side condition that should be reported as
such, not as a malformed agent envelope. Missing guest paths and guest
directories should be named.

### Impact

"Envelope is invalid" points at protocol corruption when the real cause is a
typo in a host path.

---

## 18. Config decode failures expose raw Swift error text (#12)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 9974081)
- **Area:** `config`

### Reproduction

```sh
printf 'names: [x]\n' > cfgbad.yaml
pomme config validate cfgbad.yaml
pomme config render cfgbad.yaml --format json
```

Both observed, exit 1:

```text
Error: DecodingError.keyNotFound: Key 'schemaVersion' not found in keyed
decoding container. Debug description: No value associated with key
CodingKeys(stringValue: "schemaVersion", intValue: nil) ("schemaVersion").
```

A config with `schemaVersion` but no `name` produces the same shape for `name`.

### Expected result

`Config is missing required key 'schemaVersion'.`, ideally with the file and
line.

### Impact

`CodingKeys(stringValue:intValue:)` is an implementation detail. The message is
also duplicated: the key name appears three times.

---

## 19. Unknown config keys are silently accepted (#13)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 2153aee)
- **Area:** `config`

### Reproduction

```yaml
schemaVersion: 1
name: cfgtest
versions: [26.6.2]
hardware:
  diskSize: 40GB
  memory: 4GB
boot: none
bogusKey: 1
```

```sh
pomme config validate goodbogus.yaml
```

Observed, exit 0: `Config is valid.`

### Expected result

Reject unknown keys, or warn and name them.

### Impact

A misspelled key is silently ignored, so a config can validate while omitting
the setting the operator intended. Combined with issue 18, the same file gives
a hard error for a missing key and no signal at all for a misspelled one.

---

## 20. Dry-run accepts resource sizes the real create rejects (#5)

- **Severity:** Medium
- **Status:** Resolved (2026-09-15; b666146)
- **Area:** `create`

### Reproduction

```sh
pomme create --dry-run dtest --version latest --memory 512MB --disk-size 1GB
```

Observed, exit 0:

```text
[...] dtest Warning: macOS 27.0 (26A428) has not been qualified for Recovery
automation; creation will attempt it with observed-screen checks.
Would create dtest (disk 1GB, memory 512MB, boot normal).
```

The 2026-09-12 run recorded the real create failing with `The configured RAM
536.9 MB is below the guest minimum 4.29 GB.`, and a 1 GB or 25 GB disk failing
the install with `provisioning phase install failed [code=virtualization.10007]`
after several minutes.

### Expected result

Dry-run should apply the same minimum checks as the real create. It is the only
mechanism for validating a creation request cheaply.

### Impact

The dry-run's purpose is to catch exactly these mistakes before a long restore.
A caller who validates with `--dry-run` still loses minutes to a failure that
leaves a broken VM behind.

### Note

The Recovery qualification warning for macOS 27.0 is correct behavior and is
recorded here only because it appears in the same output.

---

## 21. `pause`, `resume`, and `stop` print nothing (#9)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 282fb77)
- **Area:** lifecycle

### Reproduction and observed output

```sh
pomme pause t1     # exit 0, empty
pomme pause t1     # exit 0, empty  (already paused)
pomme resume t1    # exit 0, empty
pomme resume t1    # exit 0, empty  (already running)
pomme stop t1      # exit 0, empty
pomme stop t1      # exit 0, "VM is already stopped."
pomme stop t1 --force  # exit 0, empty
```

By contrast `start` prints `OK boot mode=normal` and `restart` prints `OK boot
mode=normal`.

### Expected result

A confirmation line consistent with `start`, and a distinct message for a
no-op, as `stop` alone already does for an already-stopped VM.

### Impact

Silence is indistinguishable from a command that did nothing, and repeating
`pause` on a paused VM cannot be told apart from pausing a running one.

---

## 22. `delete` reports an empty bundle path (#10)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 01c72dc)
- **Area:** `delete`
- **Source:** `Sources/PommeCLI/Operations/PommeApplication.swift:565`

### Reproduction

```sh
pomme delete t1 --force
```

Observed, exit 0:

```text
OK destroyed name=t1 bundle=
```

### Expected result

The bundle path that was removed, which the format string clearly intends to
print.

### Impact

The line advertises a field it never fills. The payload's `bundlePath` is empty
by the time the text is formatted, most likely because the destroy result is
built after the bundle record is cleared.

---

## 23. `inspect` output repeats itself (#40)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 3c9b512)
- **Area:** `inspect`

### Reproduction

```sh
pomme inspect t1
```

Observed, exit 0, abridged:

```text
bundle: /Users/wes/Library/Application Support/pomme/VMs/t1.bundle
controlSocket:
helperRunning: true
vmState: running
bootMode: normal
guestAgent connection=connected role=normal protocol=1 digest=2ecacdeb... update=unknown
metadata.buildVersion: 25G83
...
health: healthy
vmState:
bootMode:
guestAgent connection=connected role=normal protocol=1 digest=2ecacdeb... update=unknown
check.helper: ok
check.guestAgent: ok
guestAgent connection=connected role=normal protocol=1 digest=2ecacdeb... update=unknown
```

### Expected result

Each field once. `controlSocket:` should carry the socket path or be omitted,
and the second `vmState:`/`bootMode:` pair should not be emitted empty.

### Impact

Three identical `guestAgent` lines and two empty state fields make the output
hard to read and hard to parse with `grep`.

---

## 24. Usage lines lose the subcommand (#38)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 92986b8)
- **Area:** argument parsing
- **Source:** `Sources/PommeCLI/CLI/Commands/SnapshotCommands.swift:200`,
  `Sources/PommeCLI/CLI/Commands/TemplateCommands.swift:163`

### Reproduction and observed output

```sh
pomme status
# Error: Specify a VM name or set POMME_VM_NAME.
# Usage: pomme <subcommand>

pomme delete t1
# Error: Deletion requires an interactive terminal. Pass --force to delete without prompting.
# Usage: pomme <subcommand>

pomme tui
# Error: tui requires an interactive terminal.
# Usage: pomme <subcommand>

pomme config init
# Error: config init requires an interactive terminal.
# Usage: pomme <subcommand>
```

All exit 64. Errors raised during parsing keep their subcommand usage correctly,
for example `pomme jobs inspect t1` prints
`Usage: pomme jobs inspect [<name>] <job-id> ...`.

### Expected result

The failing subcommand's usage line.

### Impact

The usage line points back to the top-level command list rather than the
command the operator ran, so it does not show the flag that would fix the
error, for example `--force`.

### Likely cause

These are `ValidationError`s thrown from `run()` or a `validate()` that is
reached after subcommand resolution has been discarded, so the parser prints
the root usage.

---

## 25. No `--version` flag (#42)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 80413b1)
- **Area:** top level

### Reproduction

```sh
pomme --version
```

Observed, exit 64:

```text
Error: Unknown option '--version'
Usage: pomme <subcommand>
```

### Expected result

The marketing version and ideally the build or commit, matching
`MARKETING_VERSION` in `Config/Shared.xcconfig`.

### Impact

There is no way to identify an installed binary from the CLI. Bug reports
cannot state which build they came from, and scripts cannot gate on version.
The only identifier available today is a SHA-256 of the executable.

---

## 26. `--format raw` is identical to `table` (#39)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 1c8bf13)
- **Area:** output formatting

### Reproduction

```sh
pomme list --format raw
# NAME	STATE	MODE

pomme list --format jsonl
# {"vms":[],"ok":true}
```

### Expected result

`raw` should differ from `table` or be removed from the accepted values.
`jsonl` should emit one record per line; with an empty inventory it is
indistinguishable from `json`, so this part remains unconfirmed on this run.

### Impact

A documented output format has no distinct behavior, which is misleading in
`--help`.

### Note

The 2026-09-12 run reported `jsonl` printing a single object for `list`,
`status`, and `exec`. Re-test with two or more VMs to confirm.

---

## 27. Unknown `--device` reports a download failure (#41)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 3b9a99c)
- **Area:** `ipsw`

### Reproduction

```sh
pomme ipsw list --device Bogus1,1
pomme ipsw download latest --device Bogus1,1
```

Both observed, exit 1:

```text
Error: The restore image download failed with HTTP 404.
```

`pomme ipsw list` without `--device` works and lists 27.0 (26A428) and older.

### Expected result

An unrecognized device identifier should be named as such before any network
request, or the 404 should be translated to
`Unknown device identifier Bogus1,1.`

### Impact

A typo in a device identifier looks like a network or Apple CDN outage.
Reporting a listing operation as a "download" failure compounds it.

---

## 28. `config render --format toml` is rejected (new)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 5c55852); no code change: `config render --format` has not taken `toml` since 0.1.0 (only `config init --format` names config formats), and the 2026-09-12 record described config input formats
- **Area:** `config`

### Reproduction

```sh
pomme config render good.yaml --format toml
```

Observed, exit 64:

```text
Error: The value 'toml' is invalid for '--format <format>'. Please provide one
of 'table', 'json', 'jsonl' or 'raw'.
```

### Expected result

Unclear. The 2026-09-12 run recorded `config validate/render` working in
"JSON/YAML/TOML", so either that capability was removed deliberately or the
earlier record was describing input formats rather than `--format` values.

### Impact

Low on its own; recorded because it is a behavior difference from the previous
exploration and should be reconciled with the documentation.

---

## 29. `ui type` requires `--text` rather than a positional argument (new)

- **Severity:** Low
- **Status:** Resolved (2026-09-15; 0f6f341)
- **Area:** `ui`
- **Source:** `Sources/PommeCLI/CLI/Commands/UIUtilityCommands.swift:104`

### Reproduction

```sh
pomme ui type t1 "hi"
```

Observed, exit 64:

```text
Error: Choose exactly one of --text or --text-env.
Usage: pomme ui type [<name>] [--text <text>] [--text-env <text-env>] ...
```

`pomme ui type t1 --text hi` is the working form.

### Expected result

Consistent with the usage line, which is correct. Recorded only because the
2026-09-12 exploration used the positional form, so this is a behavior change.

### Impact

The error names the right fix, so impact is limited to stale documentation and
muscle memory. The extra positional `"hi"` is silently ignored rather than
reported as an unexpected argument.

---

## Verified working on this build

`list` (table, json, jsonl, raw), `status`, `inspect`, `exec` including exit
code propagation, working directory, environment, and detached mode, `shell`,
`jobs list`/`wait`/`kill`, `sessions list`/`inspect`/`logs`/`terminate`/`delete`
for a live session, `cp` in both directions with a byte-identical round trip,
`cat`, `snapshot create`/`list`/`restore --force`/`delete --force` including the
drift warning, `ui screenshot`/`click`/`type`, `start`, `stop`, `stop --force`,
`restart`, `pause`, `resume`, `start --mode recovery`, `delete --force`,
`template list`/`create`/`delete` error paths, `ipsw list`, `agent status`,
`remote-login status`, `sip status`, and `amfi status`.

Two failures are correct behavior with accurate messages and are not defects:
`remote-login enable` reports `Full Disk Access is required to change Remote
Login.`, and `screen-sharing status` reports `Screen Sharing is unavailable
through Pomme because this guest agent does not support it.`

## Not covered

- `mdm` enrollment. It needs a reachable MDM server, and a dispatched attempt
  leaves a terminal journal that blocks re-enrollment on the same VM.
- `sip` and `amfi` `enable`/`disable` mutations. Each is a multi-minute
  workflow, exercised separately on 2026-09-13 and 2026-09-14.
- `tui`, `config init`, `sessions attach`, and `--pty` interactive paths. These
  require a TTY and were checked only for their non-TTY refusals.
- `ipsw download` of a real image, and `cp` of a large file.
- `jsonl` with a non-empty inventory, needed to confirm issue 26.
