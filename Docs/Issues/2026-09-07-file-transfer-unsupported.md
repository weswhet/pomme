# Public `cp` and `cat` file transfers are unsupported by the guest agent

- **Severity:** High
- **Status:** Resolved (2026-09-08; focused regressions and signed CLI live verification)
- **Area:** Guest file transfer
- **Observed on:** Pomme 0.1.0 signed Release build; normal VMs with the agent connected

## Reproduction

```text
rtk pomme cp /etc/hosts pomme-agent-cli-tahoe-0907:/tmp/pomme-cli-hosts-0907 --format json --debug
```

Observed result: exit 1 with `Pomme agent request failed (unsupported-operation)`.

The failure is also present for a read of an existing guest file on a clean VM:

```text
rtk pomme cat pomme-agent-cli-sequoia-0907:/etc/hosts --format json --debug
```

Observed result:

```json
{"ok":false,"error":"Pomme agent request failed (invalid-operation): The requested operation could not be completed.","name":"pomme-agent-cli-sequoia-0907","hostExitCode":1}
```

Endpoint validation works: host-to-host and guest-to-guest endpoints are rejected with the documented validation error, while a valid host/guest pair reaches the agent and fails there.

## Expected result

`cp` should transfer a regular file in either host-to-guest or guest-to-host direction, and `cat` should read an existing absolute guest path with the requested offset and count.

## Impact

The public file-transfer commands cannot move or read guest files. This blocks the advertised generic transfer path independently of MDM’s separate authenticated transfer implementation.

## Source evidence

The CLI models send `file.transfer` for `cp` and a path-based `file.read` payload for `cat`. The normal `PommeAgent` dispatch has `file.open`, `file.read`, `file.write`, and related transaction cases, but no `file.transfer` case; its `file.read` implementation expects a previously opened `fileID`, not the path/offset/count payload sent by `CatRequest`.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/GuestCommands.swift`
- `Sources/PommeCLI/GuestAgent/PommeAgentCLIModels.swift`
- `Sources/PommeCLI/GuestInternal/PommeAgent.swift`


## Resolution — 2026-09-08

Public copy and cat requests are now orchestrated on the host through the
existing authenticated file-handle protocol. Host paths and the logical
`file.transfer` request are no longer forwarded to the guest.

- Upload: validate/open the regular host source, open a guest adjacent stage,
  write chunks of at most 32 KiB, check source stability, and verify the guest's
  byte-count/SHA-256 commit receipt.
- Download: open the guest file, read bounded chunks into an adjacent host stage,
  close the guest handle, synchronize the stage, and atomically publish it.
- Cat: open the file, seek to the requested offset, read the requested bounded
  count, and close the handle. Raw/table output preserves exact bytes with no
  extra newline; JSON carries Base64 bytes, count, offset, and EOF. The existing
  32 KiB per-cat-request bound remains in effect.
- macOS `/etc` paths work on both the host and previously installed agents.
  Guest `/etc` and `/private/etc` paths use the verified Data-volume spelling
  because older agents' Foundation normalization rewrites `/private/etc` back
  to their unrecognized `/etc` alias. The no-follow component walker still
  validates the actual path; arbitrary ancestor symlinks remain rejected.

The shared file transaction now refuses nonregular destinations and opens
nonblocking before rejecting FIFO sources. Commit hashing is incremental.
Failed guest commits retain retryable cleanup records until the exact stage
can be removed. A publication/retirement race reports that the destination
may have changed and preserves the unexpected retired entry instead of
reporting a pre-publication failure or deleting it.

### Automated validation

- `rtk proxy bash Scripts/build-local.sh` — final signed Release build/install
  passed with the required Developer ID identity, exact entitlements, compatible
  designated requirement, and artifact retention.
- Final host executable SHA-256:
  `b729e19d12051e11fbfb45d148b13fb94dc5a189351f8a14a59eb773c889c1d9`.
- `rtk proxy zsh -lc 'command -v pomme'` — `/Users/wes/.local/bin/pomme`.
- `rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build`
  — all 22 checks passed.
- `rtk xcodebuildmcp macos test --project-path /Users/wes/dev/pomme/pomme.xcodeproj --scheme pomme --configuration Debug --derived-data-path /Users/wes/Library/Developer/XcodeBuildMCP/workspaces/pomme-repair-tests/DerivedData --extra-args '-only-testing:PommeCLITests/PommeGuestFileTransferTests' '-only-testing:PommeCLITests/PommeFileCommitRecoveryTests' '-only-testing:PommeCLITests/PommeAgentOperationsTests' '-only-testing:PommeCLITests/PommeAgentPathWalkerTests' '-only-testing:PommeCLITests/PommeAgentTests' --verbose --output text`
  — 36 tests passed, 0 failed, 0 skipped, including parameterized cases.
- Result bundle:
  `~/Library/Developer/XcodeBuildMCP/workspaces/pomme-64d67e0299b1/result-bundles/test_macos_2026-09-08T14-52-42-398Z_pid67736_324759f2.xcresult`.

The new transfer tests invoke the real `PommeAgent.perform` implementation,
covering empty files, 32 KiB and multi-chunk binary files, replacement, offset
reads, EOF, malformed receipts, failed writes/reads, cleanup failure/retry,
symlinks, FIFO rejection, and preservation of directory destinations. The
commit-recovery tests reproduce a deterministic publication race and a moved
staging parent, and verify that cleanup remains addressable by the original ID.
These tests use private temporary files without real VM credentials.

### Live validation

Created only the disposable VM `pomme-agent-files-0908-a6d54e`, UUID
`bda5721a-ff6b-42f1-936b-38e5ace2d457`, after verifying the inventory was empty.
Creation used macOS 26.6.0 (25G72), `--disk-size 40GB --memory 4GB --boot none`.
The original invoking signed archive and guest digest remained pinned to
`c8dda3e9095dbf154cac29c75bf7bdc96c44f45743b9fee1d3c5a35024975267`;
no provisioning journal or guest identity was rewritten. Final public-command
tests used the final host build above, proving compatibility with that guest.

| Check | Result |
|---|---|
| 196,608-byte binary upload and download | Exact byte comparison and SHA-256 match |
| Zero-byte upload and download | Exact empty files |
| Replace existing regular guest and host destinations | Exact replacement contents |
| Cat offset 65,530 / count 50, raw and JSON | Exact requested bytes, including chunk-boundary range |
| `rtk pomme cp /etc/hosts pomme-agent-files-0908-a6d54e:/tmp/final-etc-hosts --format json --debug` | Success, 365 bytes |
| `rtk pomme cat pomme-agent-files-0908-a6d54e:/etc/hosts --offset 0 --count 80 --format json --debug` | Success, 80 expected bytes |
| Same `/etc/hosts` read in raw format | Exact comparison with canonical guest path |
| `/private/etc/hosts` read | Success |
| Missing guest files | Nonzero failure, no successful transfer result |
| Host symlink source | Rejected before transfer |
| Host symlink destination | Rejected; underlying target unchanged |

The final successful checks ran sequentially; an earlier concurrent attempt
correctly returned `VM_MUTATION_IN_PROGRESS`. No SIP, AMFI, MDM, or access-service
settings were changed.

All known guest test files and the exact private host artifact directory were
removed and empty-directory removal was verified. The disposable VM is retained
stopped (`bootMode=none`, helper not running) for subsequent issue validation;
its UUID-scoped credential remains with it. No secret was inspected or manually
changed.
