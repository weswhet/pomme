# Guest execution options are accepted but not applied

- **Severity:** High
- **Status:** Resolved (2026-09-08)
- **Area:** `exec` and `shell` process launch
- **Observed on:** Pomme 0.1.0 signed Release build; normal Tahoe 26.6.0 / 25G72 VM with the authenticated agent connected

## Reproduction

```text
rtk pomme exec pomme-agent-cli-tahoe-0907 --cwd /tmp -- /bin/pwd
```

The command exited 0 and returned `/` (`Lwo=` in the JSON stream frame), although the requested working directory was `/tmp`.

```text
rtk pomme exec pomme-agent-cli-tahoe-0907 --env FOO=bar -- /bin/sh -c 'printf "%s\\n" "$FOO"'
```

The command exited 0 and returned an empty line. A combined repeatable-environment and working-directory probe returned `::/\\n`, showing neither the environment entries nor the requested directory reached the child.

```text
rtk pomme exec pomme-agent-cli-tahoe-0907 --guest-stdout /tmp/pomme-cli-exec-stdout-0907 -- /bin/echo redirected
rtk pomme exec pomme-agent-cli-tahoe-0907 --guest-stderr /tmp/pomme-cli-exec-stderr-0907 -- /bin/sh -c 'echo redirected-error >&2'
```

Both commands exited 0 and streamed their output, but the requested guest files did not exist when checked afterward from the guest.

Each of the following also reached the agent and exited 1 with the same structured `invalid-operation` response, including values that should work for a root agent:

```text
rtk pomme exec pomme-agent-cli-tahoe-0907 --user root -- /usr/bin/whoami
rtk pomme exec pomme-agent-cli-tahoe-0907 --uid 0 -- /usr/bin/whoami
rtk pomme exec pomme-agent-cli-tahoe-0907 --group wheel -- /usr/bin/id
rtk pomme exec pomme-agent-cli-tahoe-0907 --gid 0 -- /usr/bin/id
```

## Expected result

The child process should receive the requested current directory, environment entries, identity, and guest file descriptors. Successful command completion should imply that requested redirections were established, or the command should fail with a direct diagnostic.

## Impact

Scripts can receive exit code 0 while running with different execution context or without the requested redirections. Identity options are advertised but unusable through the normal guest agent.

## Original source evidence

`GuestExecutionOptions` and `GuestCommandRequest.agentPayload` serialize all of these fields. The normal agent then calls `PommeProcess.spawn` with only `path`, `arguments`, the resolved identity, and `pty`. `PommeProcess.spawn` has no cwd, environment, or redirection parameters, creates only its own standard pipes, and invokes `posix_spawn` with the inherited `environ`. Identity transitions are routed through `/usr/bin/sudo`.

Relevant files:

- `Sources/PommeCLI/CLI/Commands/GuestCommands.swift`
- `Sources/PommeCLI/GuestAgent/PommeAgentCLIModels.swift`
- `Sources/PommeCLI/GuestInternal/PommeAgent.swift`

## Implementation

The agent now validates and applies cwd, environment overrides, and guest stdin,
stdout, and stderr paths before registering a job. Ordinary launches use
`posix_spawn` file actions and an explicit environment. These settings do not
change the long-lived agent's cwd or environment.

Identity lookup now retries `getgrouplist` with a real buffer. On Darwin, the
original zero-length probe returned success with a zero count, which rejected
valid accounts. Identity launches use a private entry point in the signed
Pomme executable. It starts with an empty environment, initializes the account's
groups with Darwin `initgroups`, sets gid and uid, then applies cwd and opens
redirections with the target account's permissions. Requested environment values
travel over a private descriptor and remain literal. A separate status descriptor
reports setup failures before the agent registers a job. A request matching the
agent's current uid, gid, and supplementary groups does not need the helper.
Darwin group IDs retain their bit patterns across signed API arguments, including
the `nobody` account's group ID `4294967294`.

## Verification

The final focused XcodeBuildMCP Debug run passed all 12 tests in
`PommeAgentExecutionOptionsTests`, `PommeAgentProcessExchangeTests`, and
`PommeAgentPTYTests`. The new regressions exercise real child cwd and environment,
all three redirections, preserved streaming on unredirected descriptors, invalid
requests and failed opens without job insertion, valid account group lookup,
and concurrent launches without parent cwd/environment changes. Follow-up tests
cover current-identity launches from a non-root process, `nobody` identity
resolution, and the helper status protocol's premature EOF and failure cases.
Another 33 model, foreground-execution, protocol, and session-failure tests passed.

```text
rtk xcodebuildmcp macos test --project-path pomme.xcodeproj --scheme pomme --configuration Debug --derived-data-path /tmp/pomme-exec-options-derived --extra-args=-only-testing:PommeCLITests/PommeAgentExecutionOptionsTests --extra-args=-only-testing:PommeCLITests/PommeAgentProcessExchangeTests --extra-args=-only-testing:PommeCLITests/PommeAgentPTYTests --output text --verbose
rtk proxy bash Scripts/build-local.sh
rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build
```

The final canonical signed Release build passed its signature,
designated-requirement, and entitlement checks; all 22 CLI contract checks passed
again against that installed build. Its SHA-256 is
`dbce0926dd266d0a0592110e11c1c0956dc5161fdc116a3ec72ceaba7c53916f`.

### Live verification

Created the disposable VM `pomme-agent-exec-0908-b7e64d`, UUID
`3daa936d-b43a-404b-a4ef-dc8e10c6e09c`, with Tahoe 26.6.0 / 25G72, a 40GB disk,
and 4GB memory. The host and guest build used for this matrix had SHA-256
`4ef6739ae806f79f4d78bb5d3580b8bbedf3433ae01001922ddb39b3c23788f7`.

| Check | Result |
| --- | --- |
| `--cwd /tmp` | `/private/tmp`, the canonical directory path, instead of `/` |
| Literal environment value and repeated key | Exact `literal$HOME` value; final repeated value wins |
| Ordinary stdout, stderr, and exit 7 | Both byte streams and exit status preserved |
| Guest stdin, stdout, and stderr together | Exact output files reflected all 17 input bytes |
| Named root/wheel and numeric uid/gid 0 | Exact uid/gid `0` / `0` |
| Named daemon and numeric uid/gid 1 | Exact uid/gid `1` / `1` |
| Daemon with cwd and literal environment together | Exact `1\n/private/tmp\nliteral$HOME\n` |
| Missing cwd, stdin, or output parent; unknown user | Failed before the target marker was created |
| Daemon redirect into a root-only directory | Failed before the target marker was created |

An initial validation-script failure came from using nonexistent
`/usr/bin/test`; the macOS executable is `/bin/test`. The corrected full matrix
passed. Live failure checks used target-marker absence; automated tests verify
no job insertion without relying on the separately reported public jobs issue.

The final source adds the reviewed current-identity, signed group-ID, and helper
handshake fixes after the live build. Those deltas passed the final 12-test run
and signed build; they were not installed into the retained guest. In particular,
`nobody` resolution is covered offline rather than claimed as a live launch.

Known host and guest test artifacts were removed by exact path, with empty
directories verified by `rmdir`. The new VM and the earlier file-transfer VM
remain stopped and retained. Their pinned provisioning identities and credentials
were preserved.
