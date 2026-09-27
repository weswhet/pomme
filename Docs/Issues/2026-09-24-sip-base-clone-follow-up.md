# SIP workflows on base-template clones — 2026-09-24

The signed Release CLI (`b1cdcc4-dirty`) was tested on disposable internal-drive
clones of the protected macOS 26.6.2/25G83 and 27.0/26A428 base templates.
Each clone used its template's 40 GB disk and 4 GB memory. The source templates
remained unprovisioned and unchanged.

## macOS 26

Authenticated baseline status reported SIP enabled. The first
`sip disable --force --final-state previous` prepared the owner and Setup
Assistant, then failed before SIP mutation at normal desktop proof with
`normal-agent-console-transport` (`agentOtherTimeout`). It retained
`sipDisable/autologinIntent` and restored the VM stopped. One exact matching
resume passed desktop proof, entered authenticated Recovery, and completed SIP
disable. The command reported configuration, normal boot, runtime,
enforcement, and stopped-final-state verification. Independent `sip status`
confirmed `sipDisabled=true`, `sipEnabled=false`, and `verified=true`.

`sip enable --final-state previous` then completed with the same verification
fields. Independent status confirmed SIP enabled and the VM stopped. The clone
used provisioning journal schema 1.

Deletion removed the VM bundle but left the SIP-created owner Keychain item at
the clone's UUID-scoped service and `pomme` account. The exact item was removed
and its absence verified. Source review found that deletion reads an owner
credential reference from the schema 2 provisioning journal, but does not read
the security workflow journal where schema 1 SIP preparation stores its owner
reference. This credential cleanup gap remains open; see
`PommeCore.destroyVMPayload` and `PommeSecurityLiveOwnerPreparation.prepareFresh`.

## macOS 27

Provisioning created the owner. Baseline `sip status` and the first
`sip disable --force --final-state previous` both timed out before Terminal:
the Recovery profile expected a language chooser after the Startup Options
Return, but observed Recovery Utilities. Disable retained
`sipDisable/securityMutationIntent`, and the VM was restored stopped. No SIP
mutation receipt was recorded.

The exact 27.0/26A428 Recovery route now accepts two stable Utilities frames
at that checkpoint and advances to the existing Utilities menu event without
another chooser input. Focused Recovery navigation/profile tests and all 114
CLI integration checks passed after the signed build. The exact retained
`sip disable --final-state previous` resume reached Terminal and completed all
configuration, normal boot, runtime, enforcement, and stopped-final-state
checks. Independent status confirmed SIP disabled. SIP enable completed, and
independent status confirmed SIP enabled and the VM stopped. The 27 clone's
bundle and UUID-scoped Keychain service were absent after deletion.

All disposable VMs and private diagnostic artifacts from this run were removed.
The final VM inventory was empty; both protected templates remained
unprovisioned, 40 GB, and `securityDisabled=false`.
