# Pomme CLI option and combination test plan — 2026-09-07

This plan records the public Pomme CLI commands exercised during the disposable VM audit. Commands were run from the repository root through the signed Release runner, with shell commands prefixed by rtk as required.

## Test environment

- Runner: /Users/wes/.local/bin/pomme
- Build: Pomme 0.1.0, Developer ID Application: Wesley Whetstone (2D8XQ77EBQ), team 2D8XQ77EBQ, identifier com.github.weswhet.pomme, Hardened Runtime, exact Virtualization entitlement
- Signed agent digest: 69e8e1dc46bb32c47817dc4a2211896f74344c357ea79b6f00657e9851e1a2b1
- VMs were created after removing the prior Pomme VM inventory. Each used --disk-size 40GB --memory 4GB.
- Tahoe VM: pomme-agent-cli-tahoe-0907, macOS 26.6.0 / 25G72, qualified Recovery profile
- Sequoia VM: pomme-agent-cli-sequoia-0907, macOS 15.6.1 / 24G90, experimental Recovery profile
- No source files were changed. The only test input retained in the repository is [CLIFlagTestConfig-2026-09-07.yaml](CLIFlagTestConfig-2026-09-07.yaml).

A PASS means the command completed or rejected input according to the documented contract. A FAIL means an advertised operation returned an incorrect result, an unsupported-operation error, or a misleading success. A BLOCKED result means the command could not reach its meaningful path because a prerequisite or environment capability was unavailable; the reason is recorded.

## Cleanup and VM creation

| Command vector | Result | Evidence |
|---|---|---|
| rtk pomme list --format json | PASS | Found the six pre-existing VMs before cleanup. |
| rtk pomme stop pomme-agent-sequoia-1579-final-0906 --format json | PASS | Stopped the only running pre-existing VM. |
| rtk pomme delete --force --format json <old VM names> | PASS | Deleted the remaining pre-existing VMs after the running VM was stopped. |
| rtk pomme list --format json | PASS | Returned {"vms":[],"ok":true}; no VM bundles remained. |
| rtk pomme create pomme-agent-cli-tahoe-0907 --version 26.6.0 --disk-size 40GB --memory 4GB --boot none --format json --debug | PASS | Provisioned Tahoe successfully; final state stopped; disk 40GB and memory 4GB. |
| rtk pomme create pomme-agent-cli-sequoia-0907 --version 15.6.1 --ipsw-device Mac14,2 --disk-size 40GB --memory 4GB --boot none --format json --debug | PASS | Provisioned Sequoia successfully with the experimental observed-screen Recovery profile; final state stopped; disk 40GB and memory 4GB. |

## Help and discovery

The following help commands all exited 0 and rendered their documented usage. Nested help was also run for every public leaf.

| Command | Result |
|---|---|
| rtk pomme | PASS |
| rtk pomme -h | PASS |
| rtk pomme tools | PASS |
| rtk pomme tools --format json | PASS |
| rtk pomme agent-help | PASS |
| rtk pomme help tools | PASS |
| rtk pomme help agent-help | PASS |
| rtk pomme help snapshot | PASS |
| rtk pomme help remote-login | PASS |
| rtk pomme help ui | PASS |
| rtk pomme help ipsw | PASS |
| rtk pomme help agent repair | PASS |
| rtk pomme --version | PASS — expected rejection; no --version option is advertised |
| rtk pomme create --help; list --help; ls --help; start --help; stop --help; restart --help | PASS |
| rtk pomme pause --help; resume --help; delete --help; rm --help; status --help; inspect --help; exec --help; shell --help | PASS |
| rtk pomme jobs --help; jobs list --help; jobs inspect --help; jobs logs --help; jobs wait --help; jobs kill --help | PASS |
| rtk pomme cp --help; cat --help; agent --help; agent status --help; agent repair --help | PASS |
| rtk pomme sip --help; sip status --help; sip enable --help; sip disable --help | PASS |
| rtk pomme amfi --help; amfi status --help; amfi enable --help; amfi disable --help; mdm --help | PASS |
| rtk pomme remote-login --help; remote-login status --help; remote-login enable --help; remote-login disable --help | PASS |
| rtk pomme screen-sharing --help; screen-sharing status --help; screen-sharing enable --help; screen-sharing disable --help | PASS |
| rtk pomme snapshot --help; snapshot create --help; snapshot list --help; snapshot restore --help; snapshot delete --help | PASS |
| rtk pomme config --help; config init --help; config validate --help; config render --help | PASS |
| rtk pomme ipsw --help; ipsw list --help; ipsw download --help | PASS |
| rtk pomme ui --help; ui type --help; ui key --help; ui key-sequence --help; ui click --help; ui screenshot --help; ui ai --help; ui ai settings --help | PASS |
| rtk pomme tui --help | PASS |

The help surface exposes snapshot, while tools, agent-help, README command inventory, and legacy help metadata omit it. This is recorded in [command-discovery-omits-snapshot.md](Issues/2026-09-07-command-discovery-omits-snapshot.md).

## Create and configuration options

| Command vector | Result | Evidence |
|---|---|---|
| rtk pomme create <name> --version 26.6.0 --disk-size 40GB --memory 4GB --boot none --dry-run --format json | PASS | Tahoe profile and 40GB/4GB plan resolved. |
| Same create dry-run vector with --boot normal | PASS | Normal final-state plan resolved. |
| Same create dry-run vector with --boot recovery | PASS | Recovery final-state plan resolved. |
| rtk pomme create <name> --version 25G72 --ipsw-device Mac14,2 --disk-size 40GB --memory 4GB --boot none --dry-run --format json | PASS | Build selector resolved 26.6.0 / 25G72. |
| rtk pomme create <name> --version latest --disk-size 40GB --memory 4GB --dry-run --format json | PASS | Resolved the latest listed image, 26.6.2 / 25G83, with the experimental warning. |
| The valid create dry-run vector with --format raw | PASS | Raw plan text emitted. |
| The valid create dry-run vector with --format jsonl | PASS | JSONL plan emitted. |
| The valid create dry-run vector with --json | PASS | JSON equivalent emitted. |
| rtk pomme create <name> --restore-image /tmp/missing-restore.ipsw --dry-run --format json | FAIL | Exit 64: the advertised local-image option always fails closed because this build cannot qualify local images. See [restore-image-flag-unavailable.md](Issues/2026-09-07-restore-image-flag-unavailable.md). |
| rtk pomme create <name> --version 26.6.0 --disk-size 0GB --memory 0GB --dry-run | FAIL | Exit 0 and a successful plan with zero resources. See [create-dry-run-accepts-zero-resources.md](Issues/2026-09-07-create-dry-run-accepts-zero-resources.md). |
| Direct create with no name | PASS | Exit 64 with direct-name validation. |
| Direct create with an invalid --boot value | PASS | Exit 64 with enum validation. |
| Direct create with --parallel | PASS | Exit 64 because parallel mode is config-only. |
| Direct create with --parallel-limit 2 | PASS | Exit 64 because parallel mode is config-only. |
| rtk pomme create nonexistent --resume --version 26.6.0 | PASS | Exit 64 because --resume accepts only the VM name and output/debug options. |
| rtk pomme create nonexistent --resume --boot normal | PASS | Exit 64 for the same contract. |
| rtk pomme create nonexistent --resume --format json | PASS | Exit 1 for the missing VM, after valid resume parsing. |
| Create with --version and --restore-image together | PASS | Exit 64 with mutually exclusive source validation. |
| Create with --config plus a direct name/options | PASS | Exit 64 with config/direct-mode conflict validation. |
| Direct create with --output | PASS | Exit 64 because direct create has no output-path option. |
| rtk pomme config validate Docs/CLIFlagTestConfig-2026-09-07.yaml | PASS | YAML validated in table output. |
| Config validate with --format json, jsonl, raw, and --debug | PASS | All output variants worked. |
| rtk pomme config render Docs/CLIFlagTestConfig-2026-09-07.yaml --format json | PASS | Rendered Tahoe and experimental Sequoia plans with 40GB/4GB resources. |
| Config render with --format jsonl, raw, and --debug | PASS | All output variants worked. |
| rtk pomme create --config Docs/CLIFlagTestConfig-2026-09-07.yaml --dry-run --format json | PASS | Both version plans rendered without creating VMs. |
| Same config create with --parallel --parallel-limit 2 --format jsonl --debug | PASS | Both plans completed through the concurrent dry-run path. |
| Config create with --parallel-limit 0 | PASS | Exit 64 with greater-than-zero validation. |
| Config validate/render with a missing file | PASS | Exit 1 with missing-config failure. |
| rtk pomme config init --format invalid | PASS | Exit 64 with format enum validation. |
| Config validate with --output and config create with --output | PASS | Both rejected as unsupported option combinations. |
| rtk pomme config init --format yaml --output /tmp/pomme-cli-init-0907.yaml | PASS | Interactive prompts accepted name, version, 40GB, 4GB, and boot none; file was written. |
| Same config init without --force over the existing path | PASS | Exit 64 and refused replacement. |
| Same config init with --force | PASS | Replaced the existing file successfully. |
| Interactive config init for JSON, TOML, and Pkl outputs | PASS | All three files were generated. |
| Config validate/render for YAML, JSON, and TOML generated files | PASS | All six operations passed. |
| Config validate/render for generated Pkl | BLOCKED | Exit 1 because pkl is not installed on the host. |
| rtk pomme config init --json | PASS | Exit 64; config init has no global JSON flag. |

## Listing, status, inspection, and lifecycle

| Command | Result | Evidence |
|---|---|---|
| rtk pomme list | PASS | Table inventory rendered. |
| rtk pomme ls --json | PASS | Alias and JSON output rendered. |
| rtk pomme list --format jsonl | PASS | JSONL inventory rendered. |
| rtk pomme list --format raw | PASS | Raw inventory rendered. |
| rtk pomme list --json --format json --debug | PASS | Equivalent JSON and debug output rendered. |
| rtk pomme list --json --format table | PASS | Exit 64 with JSON/table conflict validation. |
| rtk pomme list --format invalid | PASS | Exit 64 with format validation. |
| rtk pomme status <both VMs> --format jsonl | PASS | Status returned for both stopped VMs. |
| rtk pomme inspect <both VMs> --format jsonl | PASS | Inspection returned top-level success and stopped-state health details. |
| status and inspect with POMME_VM_NAME and an omitted target | PASS | Environment target resolution worked. |
| rtk pomme agent status <both VMs> | PASS | Both stopped VMs returned protocol and disconnected-agent data. |
| rtk pomme agent status <both VMs> --format jsonl | PASS | JSONL output worked. |
| rtk pomme agent repair pomme-agent-cli-tahoe-0907 --final-state previous --format json --debug | FAIL | Exit 1 with Pomme provisioning journal has an invalid phase transition after the retained SIP failure. |
| rtk pomme agent repair pomme-agent-cli-sequoia-0907 --final-state previous --format json --debug | FAIL | Exit 1 with the same invalid provisioning phase error on a clean VM. |
| status with a missing VM | PASS | Exit 64 with target validation. |
| agent status with multiple names | PASS | Exit 64 because the command accepts one target. |
| Tahoe start --mode normal --timeout 120 --format json --debug | PASS | VM reached running normal mode and authenticated agent connection. |
| Tahoe pause --format json --debug | PASS | VM reached paused state. |
| Tahoe resume --format json --debug | PASS | VM returned to running state. |
| Tahoe restart --mode normal --timeout 120 --format json --debug | PASS | Stop/start sequence completed and ended in running normal mode. |
| Tahoe stop --force --format json --debug | PASS | Force stop completed. |
| Tahoe start --mode recovery --timeout 120 --format json --debug | PASS | Recovery mode started with the recovery role. |
| Recovery status, inspect, and agent status | PASS | Read-only recovery state returned as documented. |
| Recovery exec and jobs list | BLOCKED | Exit 1 because the recovery agent does not expose normal process/job operations. |
| Recovery UI key and click | PASS | Recovery display input completed. |
| Recovery screenshot immediately after recovery start | FAIL | Exit 1 with blank framebuffer; retry after five seconds passed. |
| Recovery screenshot after framebuffer settled | PASS | 1280x800 PNG returned. |
| Tahoe graceful stop from recovery | PASS | VM returned to stopped state. |
| Tahoe start normal after Recovery, followed by status after agent settle | PASS | Normal agent reconnected after the expected startup delay. |
| Sequoia start --mode normal --timeout 120 --format json --debug | PASS | Normal Sequoia agent connected. |
| Sequoia cat/exec probes while running | FAIL | cat reached the agent and failed unsupported; exec itself passed when run after cat completed. |
| Sequoia restart --mode recovery --timeout 120 --format json --debug | PASS | Recovery restart stop/start sequence completed. |
| Sequoia graceful stop from recovery | PASS | Command eventually completed and status showed stopped. |
| rtk pomme tui <VM> in a noninteractive terminal | PASS | Exit 64 with the documented interactive-terminal requirement. |

## Guest exec and shell

| Command vector | Result | Evidence |
|---|---|---|
| exec <Tahoe> -- /usr/bin/whoami | PASS | Root output. |
| exec with --format json, jsonl, raw, and --json using echo probes | PASS | All output modes worked. |
| printf attached-stdin through exec --stdin --format json -- /bin/cat | PASS | Input was returned exactly. |
| exec --guest-stdin /dev/null -- /usr/bin/wc -c | PASS | Guest-file stdin path was accepted and returned zero input. |
| exec --guest-stdout /tmp/pomme-cli-exec-stdout-0907 and --guest-stderr /tmp/pomme-cli-exec-stderr-0907 | FAIL | Commands exited 0 and streamed output, but the requested guest files were absent afterward. |
| exec --cwd /tmp -- /bin/pwd | FAIL | Returned / instead of /tmp. |
| exec --env FOO=bar -- /bin/sh -c printf probe | FAIL | Returned an empty variable. Repeatable environment plus cwd returned ::/ instead of the requested values. |
| exec --user root, --uid 0, --group wheel, and --gid 0 | FAIL | Each exited 1 with structured invalid-operation. |
| exec --timeout 5 -- /bin/echo timeout | PASS | Completed within the timeout. |
| exec --timeout 0 | PASS | Exit 64 with timeout validation. |
| exec --timeout=-1 | PASS | Exit 64 with timeout validation. |
| exec --timeout -1 | PASS | Exit 64; parser treated the negative token as a missing option value. |
| exec --timeout 0.01 -- /bin/sleep 1 | PASS | Exit 124 with foreground timeout; the detached process was later observed exited. |
| exec with no command after -- | PASS | Exit 1 with the documented executable-required error. |
| exec with a relative cwd/env/redirection path | PASS | Exit 64 with absolute-path or environment validation. |
| exec --user root --uid 0 | PASS | Exit 64 with identity conflict validation. |
| exec --group wheel --gid 0 | PASS | Exit 64 with group conflict validation. |
| exec --stdin --detach | PASS | Exit 64 with stdin/detach conflict. |
| exec --stdin --guest-stdin /dev/null | PASS | Exit 64 with stdin redirection conflict. |
| exec --pty --detach | PASS | Exit 64 with PTY/detach conflict. |
| exec --pty with JSON/JSONL output | PASS | Exit 64 with PTY output-format conflict. |
| exec --pty with guest redirections | PASS | Exit 64 with PTY/redirection conflict. |
| exec --pty --timeout 5 --format raw -- /bin/sh -c printf pty-marker | FAIL | Exit 0 but returned only OK; child output was absent. See [pty-output-missing.md](Issues/2026-09-07-pty-output-missing.md). |
| shell <Tahoe> printf probe with default, JSON, JSONL, and raw output | PASS | Explicit shell expressions worked in all tested output modes. |
| shell with --cwd /tmp and --env FOO=bar | FAIL | Returned ::/; context options were not applied. |
| shell --user root | FAIL | Exit 1 with invalid-operation. |
| Piped stdin through shell --stdin <VM> cat | PASS | Input was returned. |
| shell --timeout 0.01 sleep probe | PASS | Exit 124 with structured timeout. |
| shell --detach --format json sleep probe | PASS | Detached job was created. |
| shell with POMME_VM_NAME and one expression | PASS | Omitted target resolved for an explicit expression. |
| shell with no arguments or malformed argument counts | PASS | Exit 64 with usage validation. |
| shell --pty/detach, PTY/redirection, identity conflict, and invalid-timeout combinations | PASS | All documented conflicts rejected. |
| Bare interactive shell using the implicit PTY | FAIL | Returned OK without the shell’s marker, matching explicit PTY behavior. |

The guest execution failures are detailed in [guest-execution-options-not-applied.md](Issues/2026-09-07-guest-execution-options-not-applied.md).

## Background jobs

| Command | Result | Evidence |
|---|---|---|
| exec --detach sleep/echo probe | PASS | Created a background job. |
| jobs list --format json | FAIL | Exit 1 with unsupported-operation. |
| jobs ls --json | FAIL | Exit 1 with unsupported-operation. |
| jobs list --format jsonl | FAIL | Exit 1 with unsupported-operation. |
| jobs inspect <completed job> --format json | PASS | Returned exited true, exitCode 0, and detached output frame. |
| jobs logs <completed job> --format json | FAIL | Exit 1 with unsupported-operation. |
| jobs wait <completed job> --format json | FAIL | Exit 1 with unsupported-operation. |
| jobs wait <job> --timeout 0 | PASS | Exit 64 with timeout validation. |
| jobs kill <missing job> --signal TERM | PASS | Exit 1 with invalid-operation/not-found behavior. |
| jobs kill live jobs with TERM, KILL, INT, and HUP | PASS | All returned signalled true; later inspection showed eventual exit. |
| jobs kill with an invalid signal | PASS | Exit 1 with signal validation. |

See [job-management-unsupported.md](Issues/2026-09-07-job-management-unsupported.md).

## File commands

| Command | Result | Evidence |
|---|---|---|
| cp /etc/hosts <VM>:/tmp/pomme-cli-hosts-0907 --format json | FAIL | Exit 1 with unsupported-operation. |
| cat <VM>:/etc/hosts --format json on a running clean Sequoia VM | FAIL | Exit 1 with invalid-operation even for an existing file. |
| cat with JSONL/raw/count/offset variants | FAIL | Reached the same unsupported/invalid operation path. |
| cp host-to-host and guest-to-guest | PASS | Exit 64 with endpoint validation. |
| cp/cat with relative endpoints or paths | PASS | Exit 64 with endpoint/path validation. |

See [file-transfer-unsupported.md](Issues/2026-09-07-file-transfer-unsupported.md).

## UI input, screenshots, and AI

| Command vector | Result | Evidence |
|---|---|---|
| ui screenshot <Tahoe> --output /tmp/pomme-cli-shot-0907.png --format json --debug | PASS | Returned 1280x800 screenshot and wrote the output path. |
| ui screenshot <Tahoe> --output /tmp/pomme-cli-shot-0907-raw.png --format raw | PASS | Raw screenshot written; both images reported 1280x800. |
| ui key return and ui key cmd+shift+t | PASS | Key inputs completed. |
| ui key-sequence left right return --format jsonl | PASS | Sequence completed. |
| ui click x=1 y=1 | PASS | Click completed. |
| ui click x=-1 y=-1 and x=1000000 y=1000000 | PASS | Inputs completed with delivered coordinates clamped to the 1280x800 display bounds. |
| ui type --text, --replace, and --text-env | PASS | Text input and environment text source completed with expected character counts. |
| ui click/type/screenshot with POMME_VM_NAME and omitted target | PASS | Unambiguous omitted-target forms resolved. |
| ui key with an unsupported key name | PASS | Exit 1 with unsupported-key validation. |
| ui key --timeout 0.01 | PASS | Exit 1 with input_timeout. |
| ui type without text, with both text sources, and key-sequence without keys | PASS | Required-input validation rejected each case. |
| ui click with a missing axis, screenshot without --output, and invalid UI format combinations | PASS | Validation rejected each case. |
| ui key return with POMME_VM_NAME and omitted target | FAIL | Parser treated return as the optional VM name and reported missing key. |
| ui key-sequence with POMME_VM_NAME and one positional key | FAIL | Parser treated the first key as the VM name. |
| ui ai with POMME_VM_NAME and one positional goal | FAIL | Parser reported missing goal. |
| ui ai <VM> Open Keyboard settings with suggest, step, and loop modes plus every documented option | FAIL | Each reached the direct bridge and returned settings-ai unavailable. |
| ui ai with zero steps, confidence 2, model timeout 0, or invalid mode | PASS | Validation rejected invalid values. |

See [ui-ai-and-omitted-target.md](Issues/2026-09-07-ui-ai-and-omitted-target.md).

## Access and security

| Command | Result | Evidence |
|---|---|---|
| remote-login status in table, JSONL, raw, and debug forms | PASS | Initial state reported Remote Login Off. |
| remote-login enable --json --debug | FAIL | Exit 0 reported enabled true. |
| remote-login status after enable | FAIL | Still reported Remote Login Off. |
| remote-login disable --format jsonl | PASS | Exit 0 reported enabled false. |
| remote-login status through POMME_VM_NAME | PASS | Omitted target resolved and reported Off. |
| screen-sharing status, enable, and disable | FAIL | All exited 1 with unsupported-operation. See [screen-sharing-unsupported.md](Issues/2026-09-07-screen-sharing-unsupported.md). |
| sip status --final-state stopped --format json --debug | PASS | Recovery authenticated, verified SIP enabled, cleaned all temporary artifacts, and ended stopped. |
| sip enable --force --final-state stopped --format json --debug | PASS | Verified no-op because SIP was already enabled; cleanup and final stopped state were verified. |
| sip disable --force --final-state stopped --format json --debug | FAIL | Failed at native automatic-login/Setup Assistant completion verification and retained phase autologinIntent. |
| amfi status Tahoe --final-state stopped --format json --debug | PASS | Verified amfiDisabled false, no active boot argument, and stopped final state. |
| amfi enable Tahoe --force --final-state stopped | BLOCKED | Retained SIP transaction owns the VM. |
| amfi disable Tahoe --force --final-state stopped | BLOCKED | Retained SIP transaction owns the VM. |
| amfi status Sequoia --final-state stopped --format json --debug | FAIL | Recovery capability proof failed after three marker attempts; cleanup stopped the VM. |
| mdm without --profile | PASS | Exit 64 with required-option validation. |
| mdm with missing profile, unapproved mode, guest path, force, timeout 1, JSON, and debug | BLOCKED | Exit 1: MDM profile unavailable; no authorized profile was available for live enrollment. |
| mdm with supervised mode via POMME_VM_NAME and --timeout 0.1 | FAIL | Exit 1 with the internal one-to-300-second timeout error; this also confirmed omitted-target parsing before any profile mutation. |
| mdm --timeout 0 | PASS | Exit 64 with CLI timeout validation. |
| mdm --timeout 0.1 | FAIL | Exit 1 with internal “Unknown control command: mdm timeout must be between 1 and 300 seconds” instead of argument validation. |
| mdm with invalid enrollment mode or output format | PASS | Exit 64 with enum/format validation. |
| sip/amfi/mdm invalid final-state or invalid option combinations | PASS | Parser rejected values outside each command’s documented enum. |

See [security-workflow-retained-after-sip-failure.md](Issues/2026-09-07-security-workflow-retained-after-sip-failure.md), [agent-repair-invalid-phase.md](Issues/2026-09-07-agent-repair-invalid-phase.md), [sequoia-recovery-capability-probe.md](Issues/2026-09-07-sequoia-recovery-capability-probe.md), and [mdm-fractional-timeout-validation.md](Issues/2026-09-07-mdm-fractional-timeout-validation.md).

## Snapshots

| Command | Result | Evidence |
|---|---|---|
| snapshot list in table, JSON, JSONL, raw, and debug forms | PASS | Empty snapshot inventory rendered. |
| snapshot list with POMME_VM_NAME | PASS | Omitted target resolved. |
| snapshot create <Tahoe> cli-snap-0907 --format json --debug | FAIL | Exit 1: missing regular MachineState.vzvmsave artifact. |
| snapshot create with POMME_VM_NAME | FAIL | Same missing-artifact result. |
| snapshot restore/delete for a missing snapshot without --force | PASS | Exit 64 with noninteractive confirmation requirement. |
| snapshot restore/delete for a missing snapshot with --force | PASS | Exit 1 with unsafe/missing snapshot directory. |
| snapshot restore/delete with invalid format | PASS | Exit 64 with format validation. |

See [snapshot-create-missing-machine-state.md](Issues/2026-09-07-snapshot-create-missing-machine-state.md). Successful restore/delete could not be reached because snapshot creation failed.

## IPSW commands

| Command | Result | Evidence |
|---|---|---|
| ipsw list | PASS | Full signed firmware table rendered. |
| ipsw list --format json --debug | PASS | Structured firmware inventory rendered. |
| ipsw list --device Mac14,2 --format jsonl | PASS | Device-specific inventory rendered. |
| ipsw list --limit 1 --format raw | PASS | One image rendered. |
| ipsw list --limit 0 | PASS | Exit 64 with positive-limit validation. |
| ipsw list --device NotADevice | PASS | Exit 1 with the observed HTTP 404 for an invalid device. |
| ipsw download 26.6.0 --device Mac14,2 --format json --debug | PASS | Cached signed image resolved to the local restore-image path. |
| ipsw download 99.99.99 --device Mac14,2 --format json | PASS | Exit 1 with no signed image match. |

## Test completion and cleanup

The repository integration contract script passed all 22 checks:

~~~text
rtk proxy bash Tests/PommeCLIIntegrationTests.sh --runner /Users/wes/.local/bin/pomme --no-build
all 22 Pomme CLI contract checks passed
~~~

The following host checks also passed during the run:

- Canonical signed Release build and install through Scripts/build-local.sh.
- Signature, designated requirement, team, Hardened Runtime, timestamp, and exact entitlement verification.
- Test VMs stayed at 40GB disk and 4GB memory.
- No source fixes were applied.

Final cleanup completed: both VMs were verified stopped, Sequoia was removed through the rm alias, Tahoe was removed through delete, `rtk pomme list --format json --debug` returned `{"vms":[],"ok":true}`, and no VM bundles remained under the Pomme VM store.
