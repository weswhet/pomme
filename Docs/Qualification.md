# Release qualification

A stable Pomme release, such as `0.1.0`, isn't publishable until every item
below has an independently reviewed record and digest. Qualify the alpha that
you plan to promote. Alpha builds themselves aren't qualified. Raw screenshots and sensitive frame data stay in a
private temporary lab workspace and are never committed or included in product
diagnostics.

## Recovery profile matrix

Each supported OS needs 25 consecutive successful Recovery navigations in
each host state:

- unrelated application frontmost;
- host locked with display awake; and
- host locked with display asleep.

Across Tahoe and Sequoia this is 150 successful cycles. Every cycle must prove
two stable pre-event classifications, exactly one input for its receipt, two
stable post-event classifications, authenticated Recovery completion, unchanged
host pointer and frontmost application, no host window or display wake, and
verified cleanup.

Sequoia additionally requires fresh-VM proof of auxiliary-storage identity,
exclusive mutation-lock ownership, and installer-worker reaping before its
one-event profile can be accepted. Unit tests cannot set this acceptance.

## Disposable-machine matrix

A clean machine must pass creation, persistent-agent authentication, buffered
and PTY process execution, identity overrides, detached jobs, file transfer,
pause/resume, digest-verified self-update, Recovery repair, SIP/AMFI, MDM, UI,
and TUI checks. Package inspection must prove only Pomme paths and the expected
Virtualization entitlement.

The terminal-session qualification must additionally cover normal and Recovery
sessions beyond 15 minutes, detached output pumping, byte-exact replay beyond
64 KiB, reattachment after abrupt client loss, takeover, multiple concurrent
sessions, resize, Ctrl-C, Ctrl-D, `~.`, exit status, HUP/KILL termination,
pause/resume, transient VSOCK reconnect, storage-blocked retry, and exact
Recovery share/credential/workspace cleanup. No Recovery transcript or
credential may remain after the helper or boot exits.

For the Recovery transcript-exit and working-directory regressions, explicitly
start an authorized disposable `pomme-agent-*` VM in Recovery, then run:

```sh
rtk proxy python3 Tests/PommeRecoveryTerminalReplayLiveTests.py \
  --runner /absolute/path/to/signed/pomme \
  --vm pomme-agent-EXPERIMENT --iterations 10
```

This opt-in check does not boot or restart the VM. It creates finite detached
terminals without a cwd override, verifies the stable `/` cwd and exact binary
output across multiple chunks, and checks repeated and offset replay. It deletes
only its successfully verified sessions; failures retain their session IDs for
inspection. This targeted smoke check does not replace the full matrix above.

The Alpha workflow publishes each alpha as a GitHub pre-release without
qualification. A stable release and its Homebrew update happen only through the
manual Release workflow, which requires the `QUALIFIED` confirmation and an
approved deployment to the protected `pomme-release` environment. Tag pushes
don't publish. For the steps, see [Releasing Pomme](Releasing.md).
