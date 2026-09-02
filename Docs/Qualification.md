# Release qualification

Pomme `0.1.0` is not publishable until every item below has an independently
reviewed record and digest. Raw screenshots and sensitive frame data stay in a
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

GitHub publication and Homebrew updates remain manual actions protected by the
`pomme-release` environment. The workflow requires the reviewed qualification
digest and an explicit publish choice; tag pushes do not publish.
