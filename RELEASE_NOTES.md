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
