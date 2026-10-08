# Pomme 0.1.0

Pomme begins with an independent root history and a Pomme-only host, control,
guest-agent, Recovery, packaging, and state identity.

The `pomme` CLI creates and controls Pomme-owned macOS virtual machines. Normal
macOS uses the persistent authenticated Pomme agent; bounded Recovery workflows
use an expiring, request-bound Pomme Recovery session. Both speak
PommeAgentProtocol v1. The host helper speaks PommeControlProtocol v1.

Each push to `main` that passes CI publishes a signed alpha. A `v0.1.0` tag and
stable package publication require green CI, independent review of the Tahoe
and Sequoia live qualification matrices, and the clean disposable-VM
qualification described in `Docs/Qualification.md`.

## Install and update

`brew install weswhet/tap/pomme` installs stable releases, and
`curl -fsSL https://pommevm.dev/install.pl | perl` installs a release, or with
`POMME_CHANNEL=alpha` the newest alpha, in `~/.local/bin`. The install script,
a Perl program that runs with macOS's `/usr/bin/perl`, checks the
tarball against `SHA256SUMS` and Pomme's Developer ID requirement, and it won't
replace a differently signed `pomme`. `POMME_PACKAGE=1` installs the signed
installer package instead.

`pomme update` updates a release the way it was installed, like Codex's
updater: `brew upgrade weswhet/tap/pomme` for Homebrew, and the published
install script otherwise. `--check` only reports. A build from source reports
that it must be rebuilt. Release builds, marked by `PommeDistribution` in
their Info.plist, check for a newer version about once a day in a detached
process and print a one-line notice after an interactive table-output command;
`CI` and `POMME_NO_UPDATE_CHECK` turn the check off.

VM creation now copies the executable it pins into `AgentArtifacts/sha256`, so
Recovery repair and resumed creation keep working after any update, including
a plain `brew upgrade`.

Release packaging states Xcode's designated requirement explicitly. A
`codesign` re-sign otherwise produced different requirement text, which made
`Scripts/build-local.sh` refuse to replace a release.

## Faster VM start

The guest agent's LaunchDaemon now sets `ProcessType` to `Interactive`.
Without it, launchd throttled the agent's CPU and I/O, which during boot
delayed the agent by up to 22 seconds, and `pomme start` waits for the agent.
`pomme start` now returns about 9 seconds after it begins, and programs that
`pomme exec` runs are no longer throttled. An existing VM gets the change after
`pomme agent update VM` and a guest restart.

`pomme start` also checks for the agent every 50 ms instead of every 500 ms,
and for its VM helper every 20 ms instead of every 100 ms.

Release builds now strip the executable's symbol table and keep a dSYM. The
executable is half its previous size, so `pomme agent update` copies it into a
VM in about half the time.

After the agent hashes its executable and matches its pinned digest, it records
its kernel-validated CDHash in `/private/var/db/pomme/agent-verified-code`.
Later starts with an enforced signature and the same CDHash skip reading the
executable.

## MDM from any state

`pomme mdm VM --profile FILE` now creates a missing VM, resumes incomplete
creation, finishes a retained standalone SIP/AMFI operation, and then enrolls,
repeating safely after any failure. `--dry-run` reports the plan,
`--final-security disabled` keeps the SIP/AMFI changes enrollment made, and
certificate payloads from the profile are installed as a separate
`com.github.weswhet.pomme.mdm-trust.*` profile when only they validate the MDM
server.

The MDM enrollment journal is now schema 6. Schema 3–5 journals are read
with `--final-security restore` and rewritten as schema 6 on their next
update; an older Pomme cannot read a schema-6 journal, so finish retained MDM
work before downgrading.
