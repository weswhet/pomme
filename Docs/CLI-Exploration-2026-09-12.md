# Pomme CLI exploration — 2026-09-12

Exploration-only run of `/Users/wes/.local/bin/pomme` (build from `0998e09`). Nothing was fixed. Every subcommand and flag was run with valid input, invalid input, and missing input where possible. Full command logs are in the session scratchpad.

## Setup

- Existing VM: `pomme-agent-terminal-live-20260909` (macOS 26.6.0, 40GB/4GB, running). Only read-only commands, guest exec/shell/jobs/sessions/cp/cat were run against it.
- Disposable VMs made from the cached `UniversalMac_26.6.2_25G83_Restore.ipsw`, using the smallest resources that worked: `ptiny` (1GB/4GB), `ptest` (25GB/4GB, then 40GB/4GB). All were deleted at the end.
- Commands that need an interactive TTY (`tui`, `config init`, `sessions attach`, `--pty`, prompts) were only checked for their non-TTY errors.

## Worked as expected

`list/ls` in all formats, `status`/`inspect` for one or several VMs, `POMME_VM_NAME` on most commands, `ipsw list`, `create --dry-run` validation, `config validate/render` (JSON/YAML/TOML), `exec` (cwd, env, user/uid/gid/group, stdin, guest stdio redirection, timeout, exit codes, 200KB output), `shell` expressions, detached jobs (`inspect --json`, `wait`, `logs`, `kill`), `shell -d` / `exec -d --pty` sessions (`list`, `inspect`, `logs`, `terminate`, `delete`), `cp` both directions (3MB round trip byte-identical), `cat --offset/--count`, `start`/`restart` normal and recovery, `pause`/`resume`/`stop`/`stop --force`, `snapshot create/list/restore --force/delete --force`, `delete --force`, `ui type/click/key`, argument-parser enum and required-argument errors.

## Failures

Severity: **H** = feature broken, **M** = wrong behavior or misleading result, **L** = poor error message or cosmetic.

### Provisioning and lifecycle

1. **M — `start`/`restart` return before the guest agent is connected.** `start ptest --json` returned `"ok":true` in a few seconds with `"guestAgent":{"connection":"disconnected"}`, even though `--timeout` (default 300) is described as the agent readiness timeout. Guest commands run immediately afterwards fail with `PommeAgent is not connected on port 505051.` *(Correction 2026-09-13: the agent does connect roughly 10 s later — verified on a fresh VM by polling `status` — so this is a readiness-wait bug, not a broken agent. The original run never waited, and its "agent never connects" conclusion was wrong.)*
2. **M — `start --mode recovery` reports success the same way** without any readiness wait.
3. **M — `create --boot normal` leaves the VM stopped.** After a successful create, `list` shows `ptest stopped none`.
4. **M — Disk minimums aren't checked; install fails with an unexplained error.** `--disk-size 1GB` and `--disk-size 25GB` pass validation (dry-run too). Install then fails with `provisioning phase install failed [code=virtualization.10007]` and leaves a broken VM. Nothing in the bundle explains the cause. The same command at 40GB succeeded. `create --resume` repeats the same failure.
5. **M — Dry-run accepts memory the real create rejects.** `create --dry-run ptest --disk-size 1GB --memory 512MB` prints `Would create ptest (disk 1GB, memory 512MB…)`. The real create fails with `The configured RAM 536.9 MB is below the guest minimum 4.29 GB.`
6. **M — Dry-run with an existing VM name says it would create it.** `create --dry-run pomme-agent-terminal-live-20260909 --version latest` → `Would create pomme-agent-terminal-live-20260909 …`.
7. **M — `start` hides the real failure.** `start ptiny` → `The VM helper exited during startup with status 1. See …/pomme-helper.log`. The log shows the actual cause: `The number of virtual machines exceeds the limit.`
8. **L — Failed-provisioning VMs look healthy in listings.** `ptiny`/`ptest` show `stopped none` in `list`. `agent status ptest` prints `OK agent=disconnected` with exit 0.
9. **L — Several state commands print nothing.** `pause`, `resume` (including repeats on an already paused or running VM) and `stop` print an empty line, while `start` prints `OK boot mode=normal` and `stop` on a stopped VM prints `VM is already stopped.`
10. **L — `delete` output has an empty bundle.** `OK destroyed name=ptest bundle=`.

### create / config

11. **H — `--parallel <n>` is rejected.** Help says `--parallel` "Accepts an optional limit". `create --config cfg.yaml --dry-run --parallel 3` → `--config cannot be combined with a VM name or direct creation options.` Bare `--parallel` works.
12. **L — Config errors show raw Swift decoder text.** A missing key gives `DecodingError.keyNotFound: Key 'versions' not found in keyed decoding container. Debug description: No value associated with key CodingKeys(stringValue: "versions", intValue: nil)…`.
13. **L — Unknown config keys are silently accepted.** A config with `bogusKey: 1` → `Config is valid.`

### exec / shell

14. **M — `POMME_VM_NAME` doesn't work for `exec` before `--`.** Help says "Uses POMME_VM_NAME when omitted before --". `POMME_VM_NAME=<vm> pomme exec -- /bin/echo hi` → `Error: Invalid VM name /bin/echo.`
15. **M — Detached exec doesn't print its job ID.** `exec <vm> -d -- /bin/sleep 30` prints only `OK`; the ID appears only in `--json`. The foreground timeout message also says to "inspect the returned job ID", but no ID is printed.
16. **L — Guest failures give a generic message.** A missing executable, `--cwd /nonexistent`, `--user nosuchuser`, or `--guest-stdin /nonexistent` all give `Pomme agent request failed (operation-failed|invalid-operation): The requested operation could not be completed.`
17. **L — `$HOME` is empty in `shell`.** `shell <vm> 'echo $HOME'` prints an empty line.

### jobs

18. **M — `jobs inspect` shows no job details.** It prints only `OK`; state, pid and exit code appear only in `--json`.
19. **M — Foreground jobs have IDs but no logs.** Taking `jobID` from `exec --json -- /bin/echo jobout`: `jobs inspect` → `OK`, while `jobs logs` and `jobs wait` → `Pomme agent request failed (invalid-operation)…`.
20. **L — Killing an exited job gives a vague error.** `invalid-operation: The requested operation could not be completed.` An unknown UUID gives `not-found: The requested operation could not be completed.`

### sessions

21. **M — `sessions inspect` for a missing or deleted session prints `offset=`** with exit 1 and no error message.
22. **M — Reading past the end of a transcript reports a helper error.** `sessions logs <vm> <id> --from-offset 999999` → `The VM helper returned an invalid response: Invalid terminal output.`
23. **L — `sessions terminate` on an exited session is vague.** Plain: `not-found`. With `--force`: `operation-failed: The requested operation could not be completed.`

### cp / cat

24. **M — Help shows the endpoint as `vm:/absolute/path`, but `vm` is read as a VM name.** `cat vm:/tmp/x` → `No Pomme-owned VM named vm exists.` The actual form is `<vmname>:/path`.
25. **M — Copying to a guest directory with a trailing slash gives an alarming error.** `cp h.txt <vm>:/tmp/` → `Guest file transfer failed after 6 bytes: … Guest commit did not return a verified receipt; the destination may have changed.`
26. **L — Host path errors say `Pomme agent request envelope is invalid.`** This covers a missing host source file, a host directory as source, and a missing host destination directory.
27. **L — Guest path errors say `The authenticated PommeAgent operation did not complete.`** This covers `cat` of a missing file or a directory, and `cp` into a missing guest directory.

### ui

28. **H — `ui screenshot` doesn't work.** On the running existing VM: `Headless VM automation failed [code=frame_timeout…]: The private framebuffer observer did not publish a frame before the deadline.` On the running `ptest`: `code=frame_invalid … The framebuffer was blank.` No file was written.
29. **M — `ui key-sequence ptest shift a` → `Unsupported direct VM key.`** There's no `Error:` prefix and no list of valid key names. `ui key <vm> bogus-key` behaves the same.
30. **L — `ui screenshot --output /nonexistentdir/s.png`** doesn't check the output path first; it fails with the frame timeout instead.
31. **L — `ui ai settings` options have no help text** (`--mode`, `--max-steps`, `--confidence`, …).

### snapshot / mdm / sip / amfi

32. **M — An invalid snapshot name is reported as an invalid VM name.** `snapshot create <vm> "bad/snap"` → `Invalid VM name bad/snap.`
33. **L — Deleting a missing snapshot says the directory is unsafe.** `snapshot delete <vm> nosnap --force` → `Unsafe snapshot directory nosnap.`
34. **L — `mdm` path errors are vague.** `--profile /nonexistent.mobileconfig` → `The MDM profile is unavailable.` A text file as the profile, or a relative `--guest-path`, → `MDM enrollment evidence is malformed.` The relative guest path is not validated the way `exec` validates paths.
35. **Note — `sip status` / `amfi status` are blocked on 26.6.2 VMs.** Even the read-only status command fails with `require Pomme's reviewed macOS Tahoe 26.6.0 (25G72) restore profile`. It also logs a "Recovery bootstrap milestone" first. Enable/disable was not tested for that reason.
36. **Note — `screen-sharing status`** reports the current agent doesn't support it (as documented). Enable/disable was not tested.

### Argument parsing / general

37. **M — Negative numbers are reported as "Missing value".** `--limit -1`, `--timeout -5`, `--offset -1`, `ui click --x -1` → `Missing value for '--limit <limit>'`.
38. **L — Usage lines lose the subcommand.** Errors raised after parsing print `Usage: pomme <subcommand> / See 'pomme --help'` instead of that subcommand's usage. Examples: `status` without a name, `create --dry-run testvm` without a version, `--timeout 0`, `cat`/`cp` endpoint errors, `sessions … bogus`, `delete`/`snapshot restore` non-TTY, `config init`, `tui`, `--json --format table`.
39. **L — `--format jsonl` prints the same single JSON object as `--format json`** for `list`, `status` and `exec`; there is no one-record-per-line output. `--format raw` is identical to `table` for `list`.
40. **L — `inspect` output repeats itself.** The `guestAgent` line appears three times, and there's an empty `controlSocket:` plus a second block with empty `vmState:`/`bootMode:`.
41. **L — An unknown `--device` reports a download failure.** `ipsw list --device Bogus1,1` (and `ipsw download latest --device Bogus1,1`) → `The restore image download failed with HTTP 404.`
42. **L — There is no `--version` flag** for the tool itself (`Unknown option '--version'`).

## Side effects left behind

- On the existing VM: `/tmp/pomme-out.txt`, `/tmp/pomme-err.txt`, `/tmp/h.txt`, `/tmp/big.bin`, and a few exited jobs/sessions in `jobs list` / `sessions list`.
- All disposable VMs (`ptiny`, `ptest`) were deleted; `pomme list` shows only the original VM.
