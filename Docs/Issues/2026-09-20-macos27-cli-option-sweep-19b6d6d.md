# macOS 27 CLI option sweep — 19b6d6d

This records current-build evidence for the macOS 27 option sweep. It is
separate from `2026-09-20-cli-full-sweep.md`, which tested the older build
`362a799`. No Pomme source code was changed.

## Test identity and final state

- Installed binary: `/Users/wes/.local/bin/pomme`, `pomme 0.1.0 (19b6d6d)`;
  this matches repository `HEAD`. Rebuilt and reinstalled with
  `Scripts/build-local.sh`; the signed Release binary passed strict signature
  verification, and a fresh login shell resolves `pomme` to this path.
- Original disposable target: `pomme-agent-macos27-option-sweep-20260922`, macOS
  `27.0.0 (26A428)`, 40 GB disk / 4 GB RAM, in the isolated store
  `/Volumes/LACIE/pomme-macos27-private/pomme`.
- Separate resource-control target: `pomme-agent-macos27-option-sweep-8gb-20260922`,
  same macOS/build and 40 GB disk with 8 GB RAM; UUID
  `3fe93322-4422-4035-b70d-040575216863`.
- Final verified state: both VMs stopped with boot mode `none` and helper off;
  the 8 GB VM's guest agent is disconnected and automatic login is pending.
  Both VMs and their provisioning journals were retained.
- OpenMac enrollment services in `~/dev/nanohub-acme-docker` were up; MySQL
  and Step-CA were healthy. The scoped enrollment profile existed with mode
  `0600`.
- `Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme
  --no-build`: all 88 contract checks passed.

## Errors and blockers observed

### Provisioning and lifecycle

- `create` and one supported `create --resume` attempt installed macOS but
  timed out during `bootstrapNormalAgent`:
  `The guest bootstrap subprocess timed out`.
- A separate 8 GB/40 GB macOS 27 target was created as a resource-control
  experiment. Its first create process exited after the installation-to-SSH
  bootstrap transition; terminal output was unavailable, and public status
  showed the target stopped with no helper and a disconnected agent. One
  `create --resume --debug --format json` attempt then exited 1 after passing
  journal validation, runtime start, discovery, key/lease verification, and
  `keyPinned`, before failing at `bootstrapNormalAgent` with
  `The guest bootstrap subprocess timed out.` Public status confirmed it
  returned to stopped / boot `none` / helper off / agent disconnected. The
  same bootstrap timeout at 8 GB means increasing memory from 4 GB did not
  resolve this failure.
- Normal `start` and `restart` attempts returned
  `started but its guest agent did not connect within <timeout> seconds; the
  VM is still running.` The VM was force-stopped after these probes.
- A longer `start --mode normal --timeout 120 --format json --debug` also
  returned `started but its guest agent did not connect within 120 seconds;
  the VM is still running.` The helper was running, but the guest agent stayed
  disconnected. A read-only status confirmed this; `stop --force` restored and
  verified the original stopped state. No guest command was dispatched.
- `agent repair ... --final-state previous` refused the framework-provisioned
  target: Recovery agent repair is unavailable for framework-provisioned VMs;
  use `inspect` or `create --resume`.
- `start --mode recovery --timeout 1 --format json --debug` succeeded with the
  guest agent disconnected. `stop --force` then succeeded; status confirmed
  restoration to the original stopped state.

### Recovery, UI, and guest operations

- `sip status` and `amfi status` each entered Recovery but timed out observing
  `recoveryUtilities` (`lastObserved=unknown`). Both restored the prior stopped
  state. With `--debug`, each retained four pre-navigation PNGs and one
  `timeout-awaiting-recoveryUtilities` PNG. Rechecked after the workflows:
  both directories are mode `0700` and all ten PNGs are mode `0600`.
- Normal-display screenshot after a normal start failed with
  `Headless VM automation failed [code=frame_timeout,
  partialInputPossible=false]: The private framebuffer observer did not
  publish a frame before the deadline.` A screenshot-only attempt in Recovery
  failed with the same error. Neither attempt wrote an output image.
- Guest operations (`exec`, `shell`, both `cp` directions, jobs, sessions,
  UI input, Remote Login, and Screen Sharing) failed before guest dispatch:
  `No running VM helper is listening at <socket>. Start it with
  pomme start <name>.` Guest-to-host `cp` reported the same condition after
  `0 bytes`.
- The complete `ui ai settings` option set parsed, then returned the
  documented capability error: `UI AI Settings automation is unavailable in
  this build.`
- Successful normal guest commands, PTY/session/job lifecycles, file transfer,
  UI input/capture, Remote Login, and Screen Sharing remain unverified because
  the guest agent/framebuffer never became available.

### MDM and restore selection

- One bounded direct MDM attempt used the OpenMac profile, supervised mode,
  guest path, `--force`, a 1-second timeout, JSON output, and debug. It returned
  `Error: invalidJournal` in preflight, before enrollment dispatch. No MDM or
  security workflow artifacts were created; no enrollment occurred.
- `create ... --version latest --ipsw-device VirtualMac2,1 --dry-run` returned
  `No signed restore image matched latest`. `ipsw list --device VirtualMac2,1`
  showed only macOS `27.0 (26A428)` with `signed=false`, explaining why the
  signed-image selector could not resolve it.
- Pkl config initialization wrote a Pkl config, but Pkl validation/rendering
  returned `Pkl configs require the pkl executable in PATH.` JSON, YAML, and
  TOML init/validate/render paths were exercised successfully.
- Template preflight rejected a missing local IPSW, `--latest` combined with
  `--version`, and `--ipsw-device` combined with `--restore-image` with specific
  diagnostics. The valid `--provisioned --from-template` branch with an absent
  source returned `No template named pomme-option-audit-no-source exists`;
  inventories before/after confirm it created neither a provisioning VM nor a
  template. The valid provisioned-template workflow remains unverified.

## Additional option probes

The full XcodeBuildMCP `pomme` test scheme run discovered 1,113 tests and
finished with 1,114 passed, 1 failed, and 0 skipped. The failure was in the
host-only `Pomme agent process exchanges / Successful process exchanges put
bounded output before the response` test, which threw
`.guestAgentTimedOut("Pomme agent exchange")`. A focused rerun of all eight
tests in that suite passed in 9 seconds, so the full-suite timeout did not
reproduce in isolation. This is recorded as a non-reproduced unit-test error,
not as a Mac 27 guest failure. The same build emitted 53 compiler warnings,
mostly existing deprecated API and unused-result diagnostics.

The current binary accepted valid option combinations through command
validation and reached the relevant runtime gate for UI, execution, shell,
jobs, sessions, copies, snapshots, Remote Login, and Screen Sharing. Since the
VM had no running helper, those probes do not establish guest-side success.

Validation refusals observed (expected input/state gates, not classified as
product defects):

- `--json --format jsonl` returned `--json conflicts with --format jsonl`;
  `--format raw` named the supported `table`, `json`, and `jsonl` values.
- `ipsw list --limit 0` rejected the limit before catalog access;
  `ipsw download latest --device Bogus` rejected the device identifier before
  download.
- `cat --offset -1` and `cat --count -1` rejected negative byte values;
  `sessions logs --from-offset -1` rejected a negative transcript offset.
- `ui type --text ... --text-env ...` rejected the conflicting text sources
  before VM lookup; `ui screenshot --output /tmp` rejected a directory as the
  output file before VM lookup or writing.
- `tools --format json --debug` and `tools --format jsonl` both returned the
  static command/capability catalog. `status` resolved the target when
  `POMME_VM_NAME` was set and, with it unset and no positional name, returned
  `Specify a VM name or set POMME_VM_NAME.` (It did not infer the sole VM.)
- `ls --format json` succeeded as the `list` alias; `rm <missing-name>
  --force --format json` reached the not-found diagnostic without deleting
  anything. Graceful `stop` on the already-stopped target returned
  `VM is already stopped.`
- `create --latest --recovery --shutdown --dry-run` rejected the conflicting
  boot flags; `start --timeout 0` and `restart --timeout 0` rejected the
  timeout before lifecycle lookup.
- `create <target> --resume --version latest` rejected the creation option
  before resume dispatch. Non-TTY `delete`, `template delete`,
  `snapshot restore`, and `snapshot delete` without `--force` each refused to
  proceed and named the interactive-terminal/force requirement; no resource
  was removed or restored.
- Create parser gates were exercised without reading or creating configs:
  `--config` with direct `--version` returned
  `--config cannot be combined with a VM name or direct creation options.`;
  `--config ... 2 --parallel` returned `--parallel takes no value; config
  creation runs at most two VMs at once.`; direct-mode `--parallel` returned
  `--parallel is available only with --config.`
- Enum/numeric validation gates also returned specific errors before VM/UI
  dispatch: create `--boot invalid` (allowed: `none`, `normal`, `recovery`),
  start `--mode invalid`, MDM `--enrollment-mode invalid` (allowed:
  `supervised`, `unapproved`), agent repair `--final-state normal` (only
  `previous`), UI click `--x -1`, and UI AI Settings `--max-steps 0`,
  `--confidence 1.1`, and `--model-timeout 0`.
- Hidden `agent-help` printed the static command inventory. Read-only
  `agent status <target> --format json --debug` returned `ok=true` and the
  durable agent projection (`connection=disconnected`, no capabilities,
  `updateState=unavailable`); it did not contact the guest.
- `tui --help` returned the expected usage. A non-interactive `tui <target>`
  invocation stopped before opening the UI with `tui requires an interactive
  terminal.`
- Non-TTY `config init --output ... [--force]`: `config init requires an
  interactive terminal.` Under a nested PTY, `--output` wrote a valid JSON
  config; a second write without `--force` refused replacement, and
  `--force` succeeded.
- `jobs wait --timeout 0`: `--timeout must be greater than zero.`
- Exec option conflicts: `--user`/`--uid`, `--group`/`--gid`, `--stdin`/
  `--guest-stdin`, and attached `--pty` with JSON output were rejected with
  specific conflict messages. `--timeout` with an attached PTY was rejected
  as unavailable.
- `shell` with an expression plus `--pty` was rejected; a bare shell with an
  explicit timeout was rejected because interactive PTY sessions do not accept
  `--timeout`.
- Session attach rejected `--from-start` together with `--from-offset` and,
  separately, required interactive stdin/stdout. Jobs rejected a non-UUID job
  ID; unsupported `--signal NOPE` named the supported signals.
- Invalid SIP/AMFI `--final-state` values named the allowed values. MDM
  `--timeout 301` returned `--timeout must be between 1 and 300 seconds.`
- Template creation rejected a missing restore image with
  `The restore image does not exist: <path>`; the incompatible source selectors
  named the required `--latest`/`--version` and `--ipsw-device`/`--restore-image`
  combinations. Additional validation-only probes returned specific errors for
  `--from-template` without `--provisioned`, `--version` with
  `--restore-image`, an omitted restore source, `--disk-size 0GB`, and an
  invalid `--memory` value. These all failed before template creation.
- Snapshot creation on the stopped target returned
  `Snapshot creation requires a running or paused normal macOS VM.` Forced
  restore/delete of an absent snapshot named it. Forced deletion of an absent
  VM/template named the missing resource; neither was removed.

## Remaining coverage

Not verified end-to-end on this Mac 27 guest: successful create/resume,
`--parallel` execution, template clone and valid `template create
--provisioned`, successful snapshots, guest-backed UI and terminal operations,
MDM enrollment, and completed SIP/AMFI enable/disable workflows. The current
target's retained provisioning failure and disconnected helper/agent prevent
those paths from reaching the guest. This report records that limitation; it
does not treat dry-runs, parser checks, or earlier-build successes as proof of
current-build guest behavior.
