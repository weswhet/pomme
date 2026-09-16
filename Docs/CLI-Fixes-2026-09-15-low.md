# CLI fixes — 2026-09-15 (Low issues)

Follow-up to `Issues/2026-09-14-cli-open-issues.md`, executed against the plan
in `Issues/2026-09-14-cli-open-issues-low-plan.md`. The seventeen Low issues
(#11, #13–#19, #21–#29) are resolved. Together with `CLI-Fixes-2026-09-15.md`,
every issue in the open-issues document is now closed. Each fix landed as its
own commit with unit tests and a green offline suite, and the whole set was
then validated once against a live VM.

- **Binary validated:** `~/.local/bin/pomme` at `5fb246d`, SHA-256
  `00b51805cfb082955a739deb6579f2523e0bdcad7fd3a8d073d96f540e655bf0`, signed
  Release, Developer ID Application: Wesley Whetstone (2D8XQ77EBQ).
  `pomme --version` → `pomme 0.1.0 (5fb246d)`.
- **Fixture:** one VM `t1` cloned from the `mdmready` template (macOS 26.6.2
  build 25G83, 40 GB disk, 4 GB memory). Its agent digest is `00b51805…`,
  the same build, so the guest-side fixes (#15, #16, #17) were in effect.
  Deleted afterwards.
- **Offline suite:** 1014 tests, 0 failures (from 972 at `b53478a`).
- **Integration script:** 88 CLI contract checks passed (from 61).
  `Tests/LocalBuildInstall.sh` (21 checks) and `Tests/PackagingIdentity.sh`
  pass with the embedded Info.plist section; the build script's
  designated-requirement comparison accepted the new binary.
- **Guest-side reach:** #15, #16, and the guest half of #17 change the guest
  agent. They reach only VMs created after this build is installed. Existing
  VMs keep their pinned agent; `agent repair` reinstalls that same digest.

Issue numbers below are the open-issues document's.

## 24. Usage lines lose the subcommand — `92986b8`

ArgumentParser attaches the subcommand usage only to errors raised while
parsing. The bootstrap now parses and runs the command itself and renders a
`ValidationError` thrown from `run()` in ArgumentParser's exact shape, using
the subcommand's usage and help path. Every other error still goes through
`PommeCLI.exit(withError:)`.

No VM: `status` → `Usage: pomme status [<names> ...] …` and `See 'pomme
status --help'`; `delete t1` (no TTY) → `Usage: pomme delete [<names> ...]
[--force] …`; `tui` → `Usage: pomme tui [<name>]`; `config init` → `Usage:
pomme config init …`; `cat /tmp/x` → `Usage: pomme cat <path> …`. All exit 64.

## 25. `pomme --version` — `80413b1`

The executable carries an Info.plist section (`Config/pomme-Info.plist`,
`CREATE_INFOPLIST_SECTION_IN_BINARY`) with the marketing version and a
`PommeGitCommit` that `Scripts/build-local.sh` sets from `git describe
--always --dirty`. Other builds report `unknown`. A lone `--version` is
answered before parsing, so `create --version` keeps its option meaning.
`CFBundleIdentifier` equals the signing identifier. The hard-coded
`PommeHelp` page is gone; `RunnerError.usage`, its one remaining user, now
points at `pomme --help`.

No VM: `pomme --version` → `pomme 0.1.0 (5fb246d)`; `create x --version` →
`Missing value for '--version <version>'`, exit 64.

## 26. `--format raw` — `1c8bf13`

`raw` is removed on purpose, since it rendered exactly like `table`. `jsonl`
now prints one object per element for list-shaped commands: `list`, `config
render`, `ipsw list`, `template list`, `snapshot list`, `tools`, `sessions
list`, and `jobs list`. An empty collection prints nothing, and a failure
envelope is still printed whole. `ui keys` prints each key and modifier
prefix tagged with `kind`.

No VM: `list --format raw` → `Please provide one of 'table', 'json' or
'jsonl'.`, exit 64; `list --format jsonl` with no VMs → empty stdout, exit 0;
`ipsw list --format jsonl --limit 2` → two lines. Live: `jobs list t1 --format
jsonl` with two detached jobs → two lines; `sessions list t1 --format jsonl` →
one line per session (four, two of them carried over from the template).

## 14 and 28. Option help and `config render` wording — `5c55852`

`ui type --replace` and the nine `ui ai settings` options now have help text
that gives their defaults. `--mode` is typed as `SettingsAIMode`, so help
lists `values: suggest, step, loop`. `config render`'s abstract now reads
*Resolve a config's versions and print the creation plan.*, making clear
that `--format` is the presentation format.

#28 needed no code change. `config render --format` has not accepted `toml`
since 0.1.0; only `config init --format` names config formats. The 2026-09-12
record's "JSON/YAML/TOML" described the config *input* formats, which are all
still accepted.

## 29. Positional text for `ui type` — `0f6f341`

`ui type [<vm>] <text>` works like `ui key`. `--text` and `--text-env`
remain, and exactly one form is allowed. With `--text` or `--text-env` the
positional list may hold only the VM name.

No VM: `POMME_VM_NAME=invalid/name pomme ui type hi` → `Invalid VM name
invalid/name`, which shows `hi` was taken as text. Live: `ui type t1 hi` →
`OK`.

## 13. Screenshot output path — `0ee2066`

`ui screenshot` checks `--output` at parse time: the parent must be an
existing directory and the leaf must not be a directory.

No VM: `--output /nonexistentdir/s.png` → `No such directory:
/nonexistentdir`; `--output /tmp` → `/tmp is a directory; give a file path.`;
both exit 64 before any VM lookup. Live: `ui screenshot t1 --output
/tmp/s.png` → `OK`, 1.3 MB PNG written.

## 11. Missing snapshot — `5257596`

The manifest loader treated any failed `lstat` as an unsafe entry. An
absent path now throws `snapshotNotFound`. An existing link or non-directory
is still reported as unsafe.

Live: `snapshot delete t1 nosnap --force` and `snapshot restore t1 nosnap
--force` → `Error: No snapshot named nosnap exists for t1.`, exit 1.

## 22. `delete` bundle path — `01c72dc`

The destroy payload never set `bundlePath`, which the table text reads (the
issue's diagnosis was wrong). The payload now carries it.

Live: `delete t1 --force` → `OK destroyed name=t1 bundle=/Users/wes/Library/
Application Support/pomme/VMs/t1.bundle`.

## 23. `inspect` repetition — `3c9b512`

The inspect text reads `pommeSocket:` from its real key. The health text no
longer prints `vmState:`/`bootMode:`, which its payload never carried. The
combined view prints the guest agent line only once; the standalone health
view keeps its own.

Live: `inspect t1` → one `guestAgent` line, `pommeSocket: /var/folders/…/
pomme-1480ff53dadb2dae.sock`, one `vmState: running` and one `bootMode:
normal`, then `health: healthy`, `check.helper: ok`, `check.guestAgent: ok`,
and `capabilities: …`.

## 21. `pause`/`resume`/`stop` output — `282fb77`

The runtime's lifecycle calls return whether they reached the framework, and
the helper's reply carries that as `changed`, an additive JSON field. A reply
from an older helper without `changed` counts as a change.

Live: `pause` → `OK paused`, again → `VM is already paused.` (JSON:
`"changed":false,"response":"VM is already paused."`); `resume` → `OK
resumed`, again → `VM is already running.`; `stop` → `OK stopped`, again →
`VM is already stopped.`; after `start`, `stop --force` → `OK stopped
(forced)`, again → `VM is already stopped.`.

## 27. Device identifiers — `3b9a99c`

`--device` (`ipsw list`/`download`), `--ipsw-device` (`create`, `template
create`), and a config's `ipswDevice` must match `^[A-Za-z]+[0-9]+,[0-9]+$`.
A catalog 404 is `Unknown device identifier <id>.` and any other status is
`The restore-image catalog request failed with HTTP N.`. The byte download
keeps its own message.

No VM: `ipsw list --device Bogus` → `--device must be an Apple model
identifier such as Mac16,10.`, exit 64; `ipsw list --device Bogus1,1` and
`ipsw download latest --device Bogus1,1` → `Unknown device identifier
Bogus1,1.`, exit 1.

## 18. Config decode failures — `9974081`

Loading maps each decode failure to a sentence prefixed with the config path.
A missing key or wrong type names the dotted key path. A YAML or TOML syntax
error gives its line and column, and invalid JSON gives the parser's detail.
Schema errors carry no position.

No VM: a tab-indented YAML file → `Config is not valid YAML at line 2,
column 1: found a tab character that violates indentation`; truncated JSON →
`Config is not valid JSON: Unexpected end of file`; `schemaVersion = = 1` →
`Config is not valid TOML at line 1, column 17: …`; `"boot":"bogus"` →
`Config key 'boot' is invalid: Cannot initialize BootMode from invalid String
value bogus`. The integration script checks `missing required key
'schemaVersion'`. The issue's `names: [x]` repro now hits #19 first.

## 19. Unknown config keys — `2153aee`

The root, `hardware`, `credentials`, `workflow`, and `mdm` levels declare
their keys and reject any other before decoding. The regeneration message for
`restore`, `replaceExisting`, and `failureCleanup` still comes first.

No VM: `hardware.memroy` → `Config key 'hardware.memroy' is not recognized.
Known keys: diskSize, memory.`; the `names: [x]` file → `Config key 'names'
is not recognized. Known keys: boot, credentials, hardware, …`. Exit 1.

## 17a. Host-side `cp` paths — `a66ffd2`

Parsing a copy now checks host paths before any agent traffic. A source must
exist, be a regular file, not be a symbolic link, and be readable. A
destination's parent must exist. A failed authenticated agent operation now
carries the helper's `Pomme agent request failed (<code>): <message>`
instead of the generic sentence.

No VM: `cp /nonexistent.txt t1:/tmp/x` → `Host file /nonexistent.txt does not
exist.`; `cp /tmp t1:/tmp/x` → `Host path /tmp is a symbolic link; give the
file it points to.`; `cp t1:/etc/hosts /nodir/x` → `Host directory /nodir does
not exist.`.

## 16 and 17b. Guest failure messages — `dfb4f86`

`PommeAgentOperationError.described(inner, message:)` carries the existing
wire code with a specific message. No wire code was added. The agent checks
the executable and working directory before `posix_spawn`, names an unknown
user, uid, or group, and diagnoses a failed file open by walking the path
again with `lstat`. The verified-parent walk itself is unchanged.

Live:

- `exec t1 -- /nonexistent/bin` → `(not-found): No such executable: /nonexistent/bin`
- `exec t1 --cwd /nonexistent -- /bin/pwd` → `(not-found): No such working directory: /nonexistent`
- `exec t1 --user nosuchuser -- /bin/id` → `(not-found): No such guest user: nosuchuser`
- `cp h.txt t1:/nodir/x` → `(not-found): No such file or directory: /nodir`
- `cat t1:/nonexistent` → `(not-found): No such file or directory: /nonexistent`
- `cat t1:/tmp` → `(invalid-operation): /tmp is a directory`
- `cp t1:/nonexistent ./out.txt` → `Guest file transfer failed after 0 bytes: … (not-found): No such file or directory: /nonexistent`

Each is prefixed `Error: Pomme agent request failed`, exit 1. The happy paths
`cp h.txt t1:/tmp/h.txt` → `Copied 6 bytes.` and `cat t1:/tmp/h.txt` →
`hello` still work.

## 15. Guest login environment — `5fb246d`

Every spawned process starts from the agent's environment, adds `HOME`,
`USER`, `LOGNAME`, and `SHELL` from the passwd record of the account it runs
as, and then applies the request's environment. `PATH` is untouched.
`Docs/Protocols.md` and the README document this.

Live: `shell t1 'echo $HOME'` → `/var/root`; `exec t1 --user pomme -- /bin/sh
-c 'echo $HOME $USER $LOGNAME $SHELL'` → `/Users/pomme pomme pomme /bin/zsh`;
`exec t1 --env HOME=/x -- /bin/sh -c 'echo $HOME $USER'` → `/x root`.

## Observed during the pass

- Right after `start t1`, the first guest request (`shell t1 'echo $HOME'`)
  failed with `Timed out waiting for agent operation Pomme agent exchange.`.
  The next eleven requests, over about a minute, failed with `PommeAgent is
  not connected on port 505051.`, even though `status` and `inspect` reported
  the agent connected. It recovered without intervention, and every later
  request succeeded, including the same `shell` command. It did not recur
  after the second `start`, and the helper log was empty. It is not tied to
  these fixes, and it is not investigated here.
- `Tests/PommeIdentifierAudit.sh` failed on `Docs/SecurityWorkflows.md:323,325`,
  which carried the retired product name. Those lines predated this work
  (`303a005`); they were reworded afterwards in `cd412cd` and the audit passes.
- Three private `AnyCodingKey` copies remain in the security and terminal
  files; migrating them is a separate cleanup.
