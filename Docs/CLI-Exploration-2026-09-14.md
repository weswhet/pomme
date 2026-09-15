# Pomme CLI exploration — 2026-09-14

Testing only; nothing was fixed. Binary under test: `~/.local/bin/pomme` at
`8f18fc3`, SHA-256 `2ecacdebbf25bc96435c25e464f8c5473198ec37c1f6c8e441cc053b4f0e818f`.
Starting point was the failure list in `CLI-Exploration-2026-09-12.md`; every
numbered item below carries that document's number so the two can be compared.

Fixture: one VM `t1` cloned from the provisioned `mdmready` template (macOS
26.6.2, 40 GB, SIP disabled, AMFI override on, owner `pomme`). It was deleted
at the end; `pomme list` is empty. The `base` and `mdmready` templates and the
cached IPSW were left in place.

Severity: **H** feature broken, **M** wrong or misleading behavior, **L** poor
message or cosmetic.

## Fixed since 2026-09-12

- **#1, #2 — `start`/`restart` now wait for the guest agent.** `exec`
  immediately after `start` and after `restart` both succeeded. Recovery-mode
  start reports `boot mode=recovery` and correctly shows the agent
  disconnected, which is expected in Recovery.
- **#28 — `ui screenshot` works.** Wrote a 1.3 MB PNG from a running desktop.
- **#35 — `sip status` and `amfi status` work on 26.6.2.** Both returned
  verified results (`sipDisabled: true`, `amfiDisabled: true`) with cleanup
  verified and the run state restored.
- **#3 — did not reproduce.** The default `create` finished with the VM
  running normal (`finalState: normalRunning`).

## Still present

### Argument parsing and output

1. **L — no `--version` flag (#42).** `pomme --version` → `Unknown option`.
2. **L — usage lines lose the subcommand (#38).** `pomme status`,
   `pomme delete t1`, `pomme tui`, `pomme config init` all print
   `Usage: pomme <subcommand>` instead of that subcommand's usage.
3. **L — `--format raw` is identical to `table` (#39)** for `list`.
4. **M — negative numbers are reported as a missing value (#37).**
   `pomme ui click --x -1` → `Missing value for '--x <x>'`.

### Config

5. **L — decode failures expose raw Swift text (#12).**
   `Error: DecodingError.keyNotFound: Key 'schemaVersion' not found in keyed
   decoding container...` for both `config validate` and `config render`.
6. **L — unknown config keys are silently accepted (#13).** A config with
   `bogusKey: 1` still reports `Config is valid.`
7. **H — `--parallel <n>` is rejected with `--config` (#11).**
   `create --config good.yaml --dry-run --parallel 2` →
   `--config cannot be combined with a VM name or direct creation options.`
   Bare `--parallel` works.
8. **M — dry-run accepts sizes the real create rejects (#5).**
   `create --dry-run dtest --version latest --memory 512MB --disk-size 1GB`
   prints `Would create dtest (disk 1GB, memory 512MB, boot normal).`

### Guest execution

9. **M — `POMME_VM_NAME` is not honored by `exec` before `--` (#14).**
   `POMME_VM_NAME=t1 pomme exec -- /bin/echo hi` → `Invalid VM name /bin/echo.`
10. **L — `$HOME` is empty in `shell` (#17).** `pomme shell t1 'echo $HOME'`
    prints an empty line.
11. **L — guest failures are generic (#16).** A missing executable,
    `--cwd /nonexistent`, and `--user nosuchuser` all give
    `Pomme agent request failed (operation-failed|invalid-operation)`.
12. **M — detached `exec` prints only `OK` (#15).** The job ID appears only in
    `--json`, nested under `result`, not at the top level.
13. **M — `jobs inspect` prints only `OK` (#18).** State, pid, and exit code
    appear only with `--json`.

### Sessions

14. **M — `sessions inspect` of a missing session prints `offset=` (#21)** with
    exit 1 and no error message.
15. **M — reading past the end of a transcript reports a helper error (#22).**
    `sessions logs t1 <id> --from-offset 999999` →
    `The VM helper returned an invalid response: Invalid terminal output.`

### File transfer

16. **M — `cp` to a directory with a trailing slash gives an alarming error
    (#25).** `cp h.txt t1:/tmp/` →
    `Guest commit did not return a verified receipt; the destination may have
    changed.` The file is not copied.
17. **L — host path errors say the envelope is invalid (#26).**
    `cp /nonexistent.txt t1:/tmp/x` → `Pomme agent request envelope is invalid.`
18. **L — guest path errors are generic (#27).** `cat t1:/nonexistent`,
    `cat` of a directory, and `cp` into a missing guest directory all give
    `The authenticated PommeAgent operation did not complete.`
19. **M — `cat vm:/path` reads `vm` as a VM name (#24).** Help still shows the
    endpoint as `vm:/absolute/path`; the real form is `<vmname>:/path`.

### UI

20. **M — key errors have no `Error:` prefix and no list of valid keys (#29).**
    `ui key t1 bogus-key` and `ui key-sequence t1 shift a` both print only
    `Unsupported direct VM key.`
21. **L — a bad screenshot output directory gives a confusing message (#30).**
    `ui screenshot t1 --output /nonexistentdir/s.png` →
    `You can't save the file "nonexistentdir" because the volume "Macintosh HD"
    is read only.` The path is never validated first. (Text differs from the
    2026-09-12 run, which reported a frame timeout.)
22. **L — `ui ai settings` options have no help text (#31).** `--mode` and
    `--max-steps` show only their defaults.

### Lifecycle and snapshots

23. **L — `pause`, `resume`, and `stop` print nothing (#9),** including repeats
    on an already paused, running, or stopped VM. Only `stop` on an
    already-stopped VM prints `VM is already stopped.`
24. **M — an invalid snapshot name is reported as an invalid VM name (#32).**
    `snapshot create t1 "bad/snap"` → `Invalid VM name bad/snap.`
25. **L — deleting a missing snapshot says the directory is unsafe (#33).**
    `snapshot delete t1 nosnap --force` → `Unsafe snapshot directory nosnap.`
26. **L — `delete` output has an empty bundle (#10).**
    `OK destroyed name=t1 bundle=`
27. **L — `inspect` output repeats itself (#40).** The `guestAgent` line appears
    three times, `controlSocket:` is empty, and a second block prints empty
    `vmState:` and `bootMode:`.

## New observations

28. **L — `config render --format toml` is rejected.** Only `table`, `json`,
    `jsonl`, and `raw` are accepted. The 2026-09-12 run recorded TOML rendering
    as working, so this is a behavior change rather than a regression in a
    known-broken area.
29. **L — `ui type` requires `--text`.** `pomme ui type t1 "hi"` →
    `Choose exactly one of --text or --text-env.` The earlier run used a
    positional form.

## Behaved correctly

`list` in all formats, `status`, `inspect`, `exec` (exit codes, cwd, stdin,
detached), `shell`, `jobs list/kill/wait` (a real timeout returns 124),
`sessions list/inspect/logs/terminate/delete` for a live session, `cp` both
directions with a byte-identical round trip, `cat`, `snapshot
create/list/restore --force/delete --force` including the drift warning,
`ui screenshot/click/type`, `start`/`stop`/`restart`/`pause`/`resume`,
`start --mode recovery`, `delete --force`, `template list/create/delete`
error paths, `ipsw list`, `agent status`, `remote-login status`, `sip status`,
`amfi status`.

`remote-login enable` fails with
`Full Disk Access is required to change Remote Login.` and `screen-sharing
status` with `Screen Sharing is unavailable through Pomme because this guest
agent does not support it.` Both are accurate, documented limitations with
clear messages, not defects.

## Not covered

- `mdm` enrollment: needs a reachable MDM server, and a dispatched attempt
  leaves a terminal journal that blocks re-enrollment on the same VM.
- `sip`/`amfi` `enable`/`disable` mutations: each is a multi-minute workflow
  already exercised separately on 2026-09-13 and 2026-09-14.
- `tui`, `config init`, `sessions attach`, and `--pty` interactive paths: they
  require a TTY and were only checked for their non-TTY refusals.
- `ipsw download` of a real image, and large-file `cp`.
