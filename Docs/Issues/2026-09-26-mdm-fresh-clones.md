# Fresh macOS 26 and 27 CLI enrollment tests — September 26, 2026

Status: both fresh clones reproduced the helper failure. The user stopped
further VM operations; the two host MDM orchestration processes are suspended.
Final restoration and running-state checks were not completed. The user requested deleting the existing VMs,
creating fresh clones of both protected templates, testing CLI enrollment,
examining the last two weeks of enrollment changes if it fails, and leaving
failed clones running for further debugging. The primary agent performs this
work directly, without subagents.

## Runner and fixtures

The canonical signed Release build and installation passed, including signature,
entitlements, and designated-requirement checks. A fresh login shell resolved
`pomme` to `/Users/wes/.local/bin/pomme`; its version matched the source:
`pomme 0.1.0 (b1cdcc4-dirty)`. All live commands use that exact installed path.
The installed agent digest is
`84ae79b2c18c4b4fbe86225b632c68d292e2b4a220a5d22aeda1332e715a7370`.

The initial inventory contained two stopped VMs:
`pomme-agent-mdmui26-20260926a` and `pomme-agent-openmac26-20260926a`.
Both were deleted through `delete --force`, each exiting 0 with
`stopMethod` `already-stopped`. A subsequent `list --format json` returned an
empty VM array. Both protected templates remained present and unprovisioned.
The prior lab's 38 known screenshots and seven empty temporary directories were
removed after validating their exact ownership and file types.

| Fixture | Source template | Guest | Creation |
| --- | --- | --- | --- |
| `pomme-agent-mdmretry26-20260926a` | `pomme-agent-ownerloop-base26-20260922a` | 26.6.2 / `25G83` | Schema 1, Recovery agent installation |
| `pomme-agent-mdmretry27-20260926a` | `pomme-agent-base27-20260923a` | 27.0.0 / `26A428` | Schema 2, owner and SSH agent bootstrap |

Both clones have 4 GB memory and their template's 40 GB internal disk. Creation
used `--boot none` and exited 0. Each enrollment attempt starts from normal
running macOS so the workflow restores that running state on failure.

## Profiles and trust preparation

Separate profiles were generated using the corrected local NanoHUB generator:

```text
/Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-mdmretry26-20260926a.mobileconfig
/Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-mdmretry27-20260926a.mobileconfig
```

Both passed the native PKCS12 inspection (`pkcs12-inspect`, status 0). The
profiles contain private enrollment identities and remain outside this report.
No server configuration was changed.

Pomme's private enrollment path omits the root payload, so both guests received
the exact public lab root before enrollment. The System Keychain root pin
matched `32f8c08019e289d48126b80b63ecf80ad503069be79c3d84db0315e3449ee3e8`.
Both guests returned HTTPS 200 for the server version endpoint without a trust
bypass. Both reported no existing MDM enrollment. The exact guest CA staging
files were removed.

macOS 27 trust installation completed through Terminal and native System
Certificate Trust Settings approval. Earlier requests launched from the agent's
session did not complete approval; their orphaned authorization prompt was
cleared before the successful GUI-session request. Credentials passed only
through private process memory and input, never through diagnostic output.

macOS 26 creation did not provision an owner. Its owner preparation used the
existing journaled SIP workflow. The first attempt timed out verifying the
normal console after creating and verifying the owner. The exact same operation
and final-state request resumed successfully, verifying SIP disabled and normal
boot. Native owner authentication installed CA trust. SIP enable completed at
`18:39:45 UTC`, with configuration, enforcement, normal boot, and final
normal-running state verified. HTTPS still returned 200 after that restoration.

## Enrollment attempts

The macOS 27 command started at `2026-09-26T18:32:51Z`:

```sh
rtk proxy /Users/wes/.local/bin/pomme mdm pomme-agent-mdmretry27-20260926a \
  --profile /Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-mdmretry27-20260926a.mobileconfig \
  --guest-path /private/var/db/pomme-mdm-enrollment/mdmretry27.mobileconfig \
  --enrollment-mode supervised --timeout 300 --force --format json --debug
```

Its baseline recorded SIP enabled, AMFI enabled, and no retained AMFI override.
At `18:49:50 UTC`, the macOS 27 helper launched and immediately reported the
closed failure `enrollment-failed`. Its signing, signature, and entitlement
checks passed before launch. The final outer result and restoration are pending.
The equivalent macOS 26 command started
at `18:40:29 UTC`, using `pomme-agent-mdmretry26-20260926a`, its own profile, and
guest path `/private/var/db/pomme-mdm-enrollment/mdmretry26.mobileconfig`, with
the same mode, timeout, and output options.
It launched the helper at `18:56:50 UTC` and immediately reported the same
`enrollment-failed` code after successful signing and entitlement checks.

Before the macOS 26 attempt, both forms of the installed-profile observation
were checked: the helper's `env -i profiles show -output stdout-xml` and the
host workflow's explicit `-type configuration` form. Each exited 0 with zero
stderr bytes and a 181-byte valid empty plist. This checks the normal-agent
process context; it does not establish behavior inside the temporary helper.

A bounded server check following the macOS 27 helper failure found no timestamped
Caddy or NanoHUB lines since `18:47 UTC`, and no observed `/mdm` request. Database
counts showed no new device or enrollment rows since fresh-clone creation began
at `18:17 UTC`. These are bounded observations; absence of logs alone does not
prove that a request was never attempted.
A second bounded check after the macOS 26 failure, covering activity since
`18:54 UTC`, likewise found zero timestamped Caddy/NanoHUB lines and no new
device or enrollment rows since clone creation.

The helper's closed code maps to failure before its private installation XPC
calls: profile observation or construction, identity-Keychain selection or
snapshot, identity attachment, or archiving. PKCS12 import failure and dispatched
installation/approval errors use `enrollment-outcome-unknown` instead. The
current helper does not emit a safe stage receipt distinguishing those earlier
steps. Its exact root cause remains unproven.

## Code history investigation

The review covers September 12–26, including committed changes and the existing
working-tree edits. It found these relevant changes:

| Commit | Date | Change |
| --- | --- | --- |
| `0998e09` | September 12 | Agent-description parsing permits optional `terminalSessionVersion`; the temporary-helper change is a comment |
| `8f18fc3` | September 13 | Prefer normal-agent AMFI baseline observation, with the existing Recovery fallback |
| `0aa2d00` | September 13 | Recover existing owner credentials through the guest; surrounding owner preparation |
| `7c3cd2e` | September 20 | macOS 27 owner provisioning and SSH bootstrap |
| `19b6d6d` | September 20 | Carry the debug-screenshot setting into nested security workflows |

The guest enrollment implementation, private helper, profile observer, evidence
parser, and main MDM workflow have no changes in that two-week window. Existing
working-tree source edits concern the agent-repair no-op and experimental
Recovery navigation, not profile construction or identity import.

The preceding material rewrite is `b48e1d1`, September 7: **Unify MDM enrollment
and strengthen Recovery workflows**. It added the temporary helper and
installed-profile observation before import, made Keychain selection and
snapshot checks strict, removed the prior unlock/default-Keychain fallback,
and changed unknown-outcome handling. These are comparison candidates, not a
proven cause of the current failure.

The [September 7 validation report](../MDMEnrollmentValidation-2026-09-07.md)
records successful reuse of an already installed, unapproved macOS 15.7.9
profile with no helper dispatch. Its supervised upgrade stopped before
enrollment dispatch, and fresh enrollment was not qualified. That report does
not verify a fresh enrollment through the rewritten helper.

## Pending verification

The primary agent incorrectly allowed the CLI's automatic restoration to
continue after each helper failure. The user clarified that no VM operations
were to occur after failure. Both host `pomme mdm` processes were then suspended
with `SIGSTOP`, and host process inspection verified state `T` for each. They
were not terminated or resumed, and no subsequent Pomme VM command was issued.
Restoration had already begun on both VMs before this correction. Their final
guest state is not claimed as verified.

The following checks remain unperformed and are not authorized to continue
under that stop instruction:

- Complete both CLI enrollment attempts and independent guest checks.
- Preserve failed clones running with their journals intact.
- Verify final template inventory and clean only this lab's transient artifacts.
- Record exact failure stages, restoration fields, and remaining diagnosis.

No production source changes or fixes are claimed by this test record.
