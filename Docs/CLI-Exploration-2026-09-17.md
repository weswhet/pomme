# CLI exploration — 2026-09-17 (full option surface, live)

A sweep of the entire public command surface against live VMs, to find
defects rather than to fix them. Nothing in the CLI was changed by this pass;
the findings are filed in `Issues/2026-09-17-cli-open-issues.md`.

- **Binary under test:** `~/.local/bin/pomme` at commit `06ee394`, SHA-256
  `9885a5ad19571244a6db695fb1ef7c2ebb3bffc7b18acb1a842564ca758bc184`,
  signed Release, Developer ID Application: Wesley Whetstone (2D8XQ77EBQ).
  `pomme --version` → `pomme 0.1.0 (06ee394)`.
- **Surface:** 77 commands carrying 365 option occurrences, enumerated with
  `--experimental-dump-help` rather than by reading help text.
- **Invocations:** 402 recorded runs, each with its exact argument vector,
  combined output, and exit code.
- **Fixtures:** three disposable VMs, 4 GB memory / 40 GB disk, macOS 26.6.2
  build 25G83. `a1` from the `mdmready` template, `a2` and `a3` from `base`.
  All deleted afterwards; `pomme list` is empty.

## What was covered

Every command was invoked at least once, and every option was exercised
except the ones listed under "Not covered".

- **Help and discovery:** all 59 help pages, `help <subcommand>`,
  `agent-help`, `tools` in table/JSON/JSONL, `ui keys` in all three forms.
- **Parsing and validation, with no VM:** missing targets for 28 commands;
  `POMME_VM_NAME` handling for 25; invalid and unknown VM names; numeric and
  enum bounds for `--timeout`, `--limit`, `--count`, `--offset`, `--x`,
  `--y`, `--max-steps`, `--confidence`, `--model-timeout`, `--signal`,
  `--mode`, `--boot`, `--final-state`, `--enrollment-mode`, `--memory`,
  `--disk-size`; `--json`/`--format` conflicts; unknown commands and options.
- **Config:** validate and render for YAML, JSON, and TOML; a `.pkl` config
  (rejected for a missing `pkl` executable); a missing file; an existing file
  with an unsupported extension; `config init` refused off a TTY.
- **Create:** dry runs for `--version`, `--latest`, a cached selector,
  `--from-template`, `--config`, `--config --parallel`, `--boot recovery`;
  every mutually exclusive combination; `--resume`; two real creates from
  templates.
- **Lifecycle:** `start`, `start --mode recovery`, `stop`, `stop --force`,
  `restart`, `pause`, `resume`, `delete --force`, deletion refusals for a
  running and for a missing VM.
- **Guest execution:** `exec` with `--cwd`, `--env`, `-e`, `--user`, `--uid`,
  `--group`, `--gid`, `--timeout`, `--detach`, `--stdin`, `--guest-stdin`,
  `--guest-stdout`, `--guest-stderr`, `--pty` refusals, exit-code
  propagation, stderr routing, and every documented conflict; `shell` as an
  expression, with `--cwd`, and `--detach`.
- **Jobs and sessions:** `jobs list/inspect/logs/wait/kill` including
  `--signal` and unknown IDs; `sessions list/inspect/logs/terminate/delete`,
  `--from-offset` including past the transcript end, `--follow` (blocks, as
  designed), and `attach` refused off a TTY.
- **Files:** `cp` in both directions, into a guest directory and a host
  directory, overwriting, both-host and both-guest refusals, a 1 MiB
  byte-identical round trip; `cat` with `--offset`, `--count`, the 32 KiB
  limit, a directory, a missing file, and a relative path.
- **UI:** `type` positional, `--text`, `--text-env`, `--replace`; `key`,
  `key-sequence`, `--vm`, an unsupported key; `click`; `screenshot`;
  `ui ai settings` reporting its bridge as unavailable.
- **Snapshots:** create from a running and from a paused VM, duplicate name,
  invalid name, list in table and JSONL, restore with drift and `--force`,
  delete, and a create refused in Recovery.
- **Security and services:** `sip status` and `amfi status` (each a ~3 minute
  Recovery round trip ending in `finalState: previous`), `remote-login`
  status/enable/disable, `screen-sharing` status/enable.
- **Agent:** `agent status` in normal and Recovery roles, `agent repair` on a
  broken VM.
- **Multi-VM:** `list`, `status`, and `inspect` across two VMs in table, JSON,
  and JSONL. This closes the JSONL-with-a-non-empty-inventory gap left open
  by the 2026-09-14 run: `list --format jsonl` and `status a1 a2 --format
  jsonl` each print exactly one object per VM.

## Verified working

Everything above behaved correctly except the fifteen findings. Worth calling
out because they were previously suspect or are load-bearing:

- The 2026-09-15 fixes all held under live use: subcommand usage on thrown
  validation errors, `pomme --version`, per-element JSONL, `ui type`
  positional text, screenshot path validation, `pause`/`resume`/`stop`
  wording with no-op detection, the `delete` bundle path, single-print
  `inspect`, device-identifier validation, plain-language config decode
  errors, unknown-key rejection, host-side `cp` path errors, the specific
  guest exec and file messages, and the guest login environment.
- Guest exec identity: `--user pomme` yields `pomme`, `--uid 0` yields `0`,
  `--group staff` yields `staff`, `--gid 20` yields `20`.
- A 1 MiB file survives a host → guest → host round trip byte-identically.
- Exit codes propagate from the guest (`exit 7` → 7) and a foreground timeout
  exits 124.
- `config render --format json` writes clean JSON to stdout and its planner
  log to stderr, so the output is machine-readable.
- Two failures are correct behavior with accurate messages, unchanged since
  2026-09-14: `remote-login enable` reports that Full Disk Access is
  required, and `screen-sharing` reports that the guest agent does not
  support it.

## Not covered

- `mdm` enrollment against a real server. Only the profile-unavailable path
  was exercised.
- `sip`/`amfi` `enable`/`disable` mutations, each a multi-minute workflow
  with its own retained-transaction semantics.
- `ipsw download` of a real image, and `template create` performing a full
  restore. Both were exercised only through their validation and error paths.
- TTY paths: `tui`, `config init`, `sessions attach`, `exec --pty`
  interactively. Checked only for their non-TTY refusals.
- `.pkl` configs end to end, since `pkl` is not installed on this host.

## Findings

Fifteen issues, filed in `Issues/2026-09-17-cli-open-issues.md`:

| # | Severity | Summary |
|---|---|---|
| 1 | High | A VM can reach a state where every `start` lands in the Recovery picker while `status` says `boot=normal`; the agent never connects and `agent repair` refuses |
| 2 | Medium | Guest commands fail rather than wait while the agent connects, after `create` and for minutes after a Recovery round trip |
| 3 | Medium | `exec --timeout` says the job is still running and to find it with `jobs list`; it is killed and never listed |
| 4 | Medium | `status` always reports `jobs=0` and its JSON has no `jobs` field |
| 5 | Low | `restart` prints only `OK stopped` |
| 6 | Low | `exec` on a paused VM reports `vsock setsockopt failed: Bad file descriptor` |
| 7 | Low | Unknown job IDs, exited sessions, and guest redirection paths still give the generic guest message |
| 8 | Low | A read-only guest path is reported as `Permission denied` |
| 9 | Low | 38 positional arguments have no help text |
| 10 | Low | `agent status` and `agent repair` ignore `POMME_VM_NAME` |
| 11 | Low | Option validation exits 1 in five places and 64 everywhere else |
| 12 | Low | `ui click` accepts out-of-range coordinates and reports `OK` |
| 13 | Low | The first screenshot after boot fails until input wakes the display |
| 14 | Low | `agent repair --final-state` accepts only `previous` |
| 15 | Low | `create --resume` reports success for a VM with nothing to resume |

Issue 1 cost two of the three VMs. `a3` was created specifically to reduce it
to a deterministic sequence and survived all four candidate sequences, so the
trigger is still unknown; the issue records exactly what each VM went through
and how the failed state presents.

## Environment note

While probing `template delete`'s refusal paths, this run deleted the `base`
template (`pomme template delete base --force` on a template that was not in
use returns `OK deleted template base`). That was an unintended change to the
host's templates, not a defect in the CLI. The `mdmready` template is intact,
and the cached `UniversalMac_26.6.2_25G83_Restore.ipsw` is still present, so
`base` can be rebuilt with `pomme template create base --restore-image
<cached ipsw>`.
