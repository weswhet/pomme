# Full live CLI sweep — 2026-09-20

Every leaf command and every option exercised against a live host and a
disposable guest. **Nothing was fixed during this sweep**; issues are recorded
here for a later pass.

- **Binary:** `~/.local/bin/pomme` at `362a799`, signed Release,
  `Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)`.
  `pomme --version` → `pomme 0.1.0 (362a799)`.
- **Host:** macOS 27.0 (26A428), Apple M1, 16 GB.
- **Surface:** 60 leaf commands, 62 distinct options
  (`Docs/../scratch inventory`, regenerated per run).
- **Fixtures**, all 4 GB / 40 GB, macOS 26.6.2 (25G83) from the local IPSW, all
  deleted afterwards: `sweep1` (created from the IPSW), template `tpl1`, and
  `clone1` (cloned from `tpl1`, used for the security workflow).
- **Starting state:** both prior fixtures (`m27`, `m2662`) deleted; no VMs, no
  templates. **Ending state:** no VMs, no templates, no bundles on disk.
- **Coverage:** every leaf command invoked; every option exercised except
  `sessions attach`, `exec --pty` and `tui`, which need a TTY the harness does
  not provide (each was confirmed to refuse cleanly without one), and
  `create --parallel`, which needs a multi-VM config.

## Summary

Nine issues: one **High** (issue 9, `sip disable` does not complete), three
**Medium** (1, 4, 5), five **Low** (2, 3, 6, 7, 8). Seven of the nine are
message quality, exit-code or flag-reach inconsistencies rather than broken
behavior. The core paths — create, clone, guest execution, file transfer,
jobs, sessions, snapshots, UI capture and input, lifecycle — all work.

Severity: **High** feature broken, **Medium** wrong or misleading behavior,
**Low** poor message or cosmetic.

---

## Issues

### 1. `config init` cannot be used non-interactively — Medium

```
pomme config init --output <path>            -> rc 64, "config init requires an interactive terminal."
pomme config init --output <path> --force    -> rc 64, same
```

The command takes `--output` and `--force`, which only make sense for scripted
use, but refuses without a TTY and `--force` does not bypass it. Every other
interactive guard in the CLI has a non-interactive escape (`delete --force`,
`snapshot restore --force`). A scripted setup therefore cannot produce a
starter config, and must hand-write one.

`config validate` and `config render` accept a hand-written file in YAML, JSON
and TOML, so only the generator is blocked.

### 2. `jobs` and `sessions` validate their ID argument at different times — Low

```
pomme sessions inspect nope not-a-uuid   -> rc 64, "Session ID must be a UUID."
pomme jobs inspect    nope not-a-uuid    -> rc 1,  "No Pomme-owned VM named nope exists."
```

Sibling command groups with the same shape disagree on ordering: `sessions`
validates the ID before resolving the VM, `jobs` resolves the VM first. Both
answers are defensible on their own; differing between two adjacent groups
means a caller cannot predict which error it gets, and the exit codes differ
too (64 vs 1). `sessions logs` matches `sessions inspect`, so the split is
per-group, not per-command.

### 3. `shell <vm>` with no expression reports a flag the caller did not pass — Low

```
pomme shell nope     -> rc 64, "--pty requires an interactive terminal for standard input."
```

A bare `shell` opens an interactive session, so the PTY requirement is real,
but the message names `--pty` as though the caller had passed it. Compare
`exec nope`, which says `exec requires an executable path after --.` and names
the actual problem. Saying that a bare `shell` needs a terminal — and pointing
at `shell <vm> '<expression>'` for scripted use — would be actionable.

### 4. `jobs` reports a transport error where `sessions` reports the real one — Medium

```
pomme jobs inspect  <vm> 00000000-0000-0000-0000-000000000000
  -> rc 1, "Pomme agent request failed (not-found): The requested operation could not be completed."
pomme jobs logs     <vm> 00000000-0000-0000-0000-000000000000   -> same
pomme sessions inspect <vm> 00000000-0000-0000-0000-000000000000
  -> rc 1, "The terminal session was not found."
```

The `jobs` message names neither the job nor what was not found, and leaks the
agent-request layer into user-facing text. `sessions` gets this right for the
identical situation. Note `cat` and `cp` carry the same
`Pomme agent request failed (<code>):` prefix but do include the real reason
(`No such file or directory`, `/etc is a directory`), so the prefix alone is
survivable — the `jobs` case is worse because the suffix is contentless.

### 5. No display-readiness signal; a blank framebuffer is unattributable — Medium

After `restart`, the guest agent reports `connection=connected` while the
display is still black. `ui screenshot` during that window fails:

```
rc 1, "Headless VM automation failed [code=frame_invalid]: The framebuffer was blank."
```

Retrying at 15 s intervals: blank, blank, then OK from ~t+15 s onward, and
captures then run at ~0.4 s. So the rejection is *correct* — the framebuffer
genuinely is blank — but two things are missing:

1. **No readiness signal.** `status` says the agent is connected, which is the
   only "ready" indicator available, and it is connected well before the
   display is. An automation caller has nothing to poll except screenshot
   failures.
2. **`frame_invalid` is overloaded.** The same code and message mean "still
   booting", "screen asleep", and "the guest really is showing black". A
   caller cannot distinguish a transient from a steady state, and the code name
   suggests corruption rather than a legitimately blank screen.

This is the same cold-first-frame behavior recorded in
`Docs/macOS27-Findings-2026-09-19.md` §12, reproduced here on a macOS 26.6.2
guest, so it is not macOS 27-specific.

### 6. A no-op `agent repair` exits non-zero — Low

```
pomme agent repair <healthy vm>
  -> rc 1, "Nothing to repair for <vm>: agent provisioning is complete.
            Agent repair does not reconcile SIP or AMFI security transactions."
```

The message is good — it is the exit code that is questionable. "Nothing to
repair" is the expected, healthy answer, so `pomme agent repair || handle` in a
script treats a healthy VM as a failure. Compare `sessions list` with no
sessions, which is rc 0.

### 7. `restart` does not report how it stopped the guest — Low

`stop --format json` carries `stopMethod` (`guest-stopped` on a healthy guest,
after the 2026-09-18 hardening). `restart --format json` has no equivalent: its
keys are `bootMode, bundlePath, guestAgent, helperRunning, hostExitCode, name,
ok, operation, pid, pommeSocket, preservedMode, steps, vmState`, and `steps`
carries a full status payload rather than the stop decision. Since `restart`
performs a stop, the same disclosure would tell an operator whether their guest
was asked to shut down or power-cut.

### 8. `delete --force` does not cover a running VM — Low

```
pomme delete clone1 --force   -> rc 1, "Stop the VM before deleting it."
```

`--force` is documented as "delete without prompting" and does suppress the TTY
confirmation, but a running VM is refused regardless, so the flag does not make
the command usable unattended without a separate `stop`. Either `--force`
should stop the VM first, or the message should say that `--force` covers the
prompt and not the run state. The refusal itself is safe behavior; only the
flag's reach is unclear.

### 9. `sip disable` cannot complete — two attempts, two different stages — High

The only state-changing security workflow exercised in this sweep never
finished. Fixture `clone1`, a fresh macOS 26.6.2 guest cloned from template
`tpl1`, agent connected, nothing else running.

**Attempt 1** (`pomme sip disable clone1`) stopped correctly and by design:

```
Error: Creating the owner account on this verified fresh VM requires
confirmation. Run from an interactive terminal or pass --force.
```

**Attempt 2** (`--force --final-state previous`) ran ~6 minutes and got deep —
`createOwner`, `verifyOwner`, `globalAutoLoginReadback`, `loginRestrictions`,
`configureLogin`, `ownerCompletion`, `finishSetupAssistant` all receipted, then
restarted to verify automatic login and failed:

```
clone1 Normal desktop proof diagnostic: normal-agent-ps-transport.
Error: Normal agent verification failed (normal-agent-ps-transport).
```

**Attempt 3**, the exact resume the error prescribes, got *past* the desktop
proof — so that failure looks transient — reached Recovery, and failed
elsewhere after ~6 minutes:

```
Recovery navigation observation timed out
  [expected=languageEnglish, lastObserved=recoveryUtilities].
Error: Recovery display observation timed out.
```

Two observations for whoever picks this up:

- The navigation reached `recoveryUtilities` while the state machine wanted
  `languageEnglish` — it observed a *later* screen than the one it was waiting
  for, which reads like a skipped or out-of-order transition rather than a
  capture failure. Capture itself was working: the same guest navigated
  Recovery successfully during `create` minutes earlier, reaching
  `terminalVerified`.
- macOS 26.6.2/25G83 resolves to an **experimental** profile whose route is
  `.directTerminal`, while this security path appears to expect the language
  step. Worth checking whether the security workflow and creation take
  different routes for the same descriptor.

**What works correctly around the failure**, and should not be disturbed by a
fix: the transaction is retained, the run state is restored, the error names
the exact resume command, and the guest is fully usable afterwards — `status`,
`agent status` and `exec` all fine, with the agent still connected. Both
failures were clean.

Not established: whether SIP was left partially modified. `sip status` was not
re-run after the failures, and attempt 2 did create an owner account and finish
Setup Assistant on the guest, so the fixture was no longer pristine when
attempt 3 ran.

---

## Verified working

### No-VM surface

- **Help**: all 60 leaf commands respond to `--help`; root `--help` and
  `--version` fine.
- **Missing VM target**: 19 commands (`status`, `inspect`, `start`, `stop`,
  `restart`, `pause`, `resume`, `delete --force`, `agent status`, `jobs list`,
  `sessions list`, `remote-login status`, `screen-sharing status`,
  `snapshot list`, `sip status`, `amfi status`, `cat`, `cp`, `ui screenshot`)
  all return rc 1 with the identical, actionable
  `No Pomme-owned VM named nope exists. Create it with 'pomme create nope'.`
- **Omitted target**: `Specify a VM name or set POMME_VM_NAME.`, and
  `POMME_VM_NAME` is honoured by `status`, `jobs list`, `sessions list`.
- **Name validation**: empty, spaces, `../` traversal and a 300-character name
  are all rejected with the 1–64 ASCII rule named.
- **`create` validation**: `--memory 0`, `--disk-size 0`, `--version bogus`,
  `--restore-image` missing file, `--boot bogus`, `--from-template` combined
  with `--version`, and no version/image at all each fail with a specific
  message. `--memory 1GB` is rejected against the guest minimum rather than
  silently accepted.
- **Format flags**: `--format table|json|jsonl` and `--json` all work on
  `list`; `--format bogus` and `--json --format table` are both rejected,
  the latter naming the conflict.
- **`config`**: `validate`/`render` accept YAML, JSON and TOML; a config
  without `schemaVersion` and one with an unknown key are both rejected, the
  latter listing the known keys. `create --config … --dry-run` plans correctly.
- **`ipsw`**: `list` honours `--limit` and `--device`; `--limit 0`, `--limit -1`
  and `--device Bogus` are rejected. `download` validates `--device` and the
  version before transferring anything. `ipsw list --device VirtualMac2,1`
  correctly reports `signed=false` for 27.0 where the default device reports
  `signed=true`.
- **`mdm`**: missing `--profile`, bad `--enrollment-mode`, `--timeout 0` all
  rejected; fractional `--timeout 1.5` accepted.
- **`ui`**: `--x -1` rejected as a coordinate, missing `--y` named, `--text`
  with `--text-env` rejected as mutually exclusive, `screenshot` without
  `--output` named. `ui keys` lists the key vocabulary with no VM.
- **`template`**: `list` empty and in JSON; `delete` of a missing template and
  `create` with a bad name/version all specific.
- **Unknown commands**: `definitely-not-a-command` and `ui bogus` both rc 64.
- **`tui`** refuses cleanly without a TTY.
- **`exec`/`shell` options**: `--uid -1`, `--gid -1`, `--timeout 0`,
  `--timeout -5`, `--cwd relative`, `--env BADFORMAT`, `--guest-stdin relative`
  each rejected with the specific rule named; `exec` with no `--` names the
  missing executable.
- **`jobs`/`sessions` options**: `jobs kill --signal BOGUS` names the accepted
  signals (TERM, KILL, INT, HUP); `jobs wait --timeout 0` rejected;
  `sessions attach --from-start --from-offset` names the conflict;
  `sessions logs/inspect` reject a non-UUID.
- **`cat`/`cp` endpoints**: `--offset -1`, `--count -1` rejected;
  `cat` without `NAME:/path` names the expected shape; `cp` with two host paths
  and with two VM endpoints both name the one-endpoint rule.

### Live guest surface

Fixture `sweep1`, macOS 26.6.2 guest, agent connected.

- **Creation**: `create` from a local IPSW completed end to end, exit 0, agent
  connected. Recovery milestones all cleared: `requestValidated` →
  `profileAccepted` → `hostStagingPrepared` → `runtimeConstructed` →
  `sessionStarting` → `runtimeStarting` → `runtimeStarted` →
  `recoveryBootVerified` → `navigationStarted` → `terminalVerified` →
  `capabilityProbeSubmitted` → `capabilityProbeVerified` → `launcherSubmitted`.
- **State**: `status`, `inspect`, `list`, `agent status` in table, `--json` and
  `--format jsonl`.
- **`exec`**: plain, `--timeout`, `--cwd`, `--env`, `--uid`, `--gid`, `--user`,
  `--group`, `--guest-stdin`, `--guest-stdout`, `--guest-stderr`, `--stdin`
  (host pipe), `--detach`. Guest exit status propagates (`/usr/bin/false` → rc 1).
  A missing executable and `--user nosuchuser` both named.
- **`shell`**: expression form, `--cwd`, `--detach`; `exit 3` propagates rc 3.
- **`jobs`**: full lifecycle — detach, `list`, `inspect`, `logs`, `wait`
  (`--timeout` expiry returns rc 124), `kill --signal TERM`, and the job then
  shows `EXITED`.
- **`sessions`**: full lifecycle — `--detach` create, `list`, `inspect`,
  `logs`, `logs --from-offset`, `terminate` (state becomes `exited`), `delete`,
  and the listing returns to empty.
- **`cp`/`cat`**: host→guest, guest→host, **2048-byte binary roundtrip
  byte-identical**, `--offset`, `--count`, and both combined. Missing guest
  file, missing host file and a directory target all named.
- **`ui`**: `screenshot` (~0.4 s, ~1.8 MB, verified visually as real guest UI),
  `click --x --y`, `key`, `key-sequence` (both `--vm` and positional forms),
  `type --text`, `keys`. `--output` into a missing directory rejected.
- **`snapshot`**: `create` (from running, machine state 1.47 GB captured),
  `list` table and JSON, duplicate name rejected, bad name rejected, `restore
  --force` (drift warning names exactly what is and is not copied), `delete`,
  and missing-snapshot errors for both restore and delete.
- **`pause`/`resume`/`restart`**: `pause` → `paused`, `resume` → `running`,
  `restart` with `--mode normal` and `--mode recovery` both land in the
  requested mode. `stop` on a healthy guest is graceful —
  `stopMethod = guest-stopped`, ~6 s.
- **Security**: `sip status` and `amfi status` complete a full Recovery cycle
  (~3 min each) and report `cleanup: verified`; the guest is handed back
  `running` with the agent connected afterwards, so the 2026-09-18 final-state
  restoration holds. `--final-state bogus` rejected.
- **`mdm`**: a missing profile and a non-profile file are both rejected before
  any VM work.
- **`remote-login`**: `status` and `disable` work; `enable` is refused with a
  specific, correct reason (`Full Disk Access is required to change Remote
  Login.`).
- **`screen-sharing`**: all three verbs refuse with the capability reason —
  this guest agent does not advertise Screen Sharing support.
- **`ui ai settings`**: reports `unavailable in this build`, matching its own
  `--help` text.
- **`template`**: `create` from a local IPSW produced `tpl1` (macOS 26.6.2,
  25G83, 40 GB); `list` shows it in table and JSON.
- **`create --from-template`**: `--dry-run` plans correctly, and a real clone
  completed in **162 s** with the agent connected, against roughly seven
  minutes for a full IPSW restore.
- **Security guardrails**: `sip disable` on a fresh VM refuses to create an
  owner account without a TTY or `--force`, retains the transaction, restores
  the run state and names the exact resume command. See issue 8 for what
  happens after that.

---

## Notes for the fixer

- Commands whose interactive guard has no non-interactive escape:
  `config init` (issue 1). `delete` and `tui` both guard correctly —
  `delete` offers `--force`, `tui` is inherently interactive.
- `ui key <vm> <bad-key>` resolves the VM before validating the key name, so a
  bad key against a missing VM reports the VM. Reasonable ordering, noted only
  so it is not mistaken for missing validation — `ui keys` is the discovery
  path.
