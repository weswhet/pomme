# Pomme 0.1.0

Pomme begins with an independent root history and a Pomme-only host, control,
guest-agent, Recovery, packaging, and state identity.

The `pomme` CLI creates and controls Pomme-owned macOS virtual machines. Normal
macOS uses the persistent authenticated Pomme agent; bounded Recovery workflows
use an expiring, request-bound Pomme Recovery session. Both speak
PommeAgentProtocol v1. The host helper speaks PommeControlProtocol v1.

Release publication remains disabled. A `v0.1.0` tag and package publication
require green CI, independent review of the Tahoe and Sequoia live qualification
matrices, and the clean disposable-VM qualification described in
`Docs/Qualification.md`.

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
