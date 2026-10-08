# Pomme agent instructions

## Disposable test VM resources

For future disposable test VMs, explicitly pass `--disk-size 40GB --memory 4GB`
instead of the CLI's larger defaults. Increase resources only when the test
requires it and explain why. Keep an active before/after comparison at the same
resource settings across all measured runs. A 25GB disk failed Tahoe installation
in the September 6, 2026 lab; do not reuse that size for Tahoe install tests.

## Protected base-OS templates

Keep these two unprovisioned, internal-drive templates as permanent test bases:

| macOS | Pomme template name | Version/build | Disk |
| --- | --- | --- | --- |
| 26 | `pomme-agent-ownerloop-base26-20260922a` | 26.6.2 / 25G83 | 40 GB |
| 27 | `pomme-agent-base27-20260923a` | 27.0 / 26A428 | 40 GB |

They are restored base OS images only: no owner account, Pomme guest agent,
Keychain credential, security override, or provisioning journal. They are inert
template bundles after installation, not running VMs; there is no additional
shutdown step. Verify them with `rtk pomme template list --format json`, not
`pomme list`. Never delete, replace, provision, or use either template as a live
test target, including for disk-space cleanup. Do not run
`pomme template delete` on them unless the user explicitly revokes this
preservation rule.

For disposable tests, create a separate VM clone with
`pomme create VM --from-template NAME --memory 4GB --boot none`; the template
supplies the 40 GB disk. The clone may install its own agent and be deleted
when the test is complete, but the source template must remain unchanged. Do
not add `--provisioned` to these templates:
that would create an owner and change the security posture. Keep both templates
and all future clones on the internal drive, not an external volume.

## Build and sign consistently

Run commands from the Pomme repository root and prefix shell commands with `rtk`.
Use native Xcode command-line tooling for builds and tests. For any CLI that will access real Pomme Keychain
items, use the signed Release workflow below, including during local development.
The project's Debug configuration is ad-hoc signed and is not a replacement for
the credential-bearing CLI.

Keep these identities consistent across builds:

- Signing certificate: `Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)`.
- Development team: `2D8XQ77EBQ`.
- Code-signing identifier: `com.github.weswhet.pomme`.
- Entitlements: `Config/pomme.entitlements` (Virtualization only).
- Hardened Runtime enabled; no injected `get-task-allow` entitlement.

### Canonical local build and install

Requires full Xcode and the named certificate with its private key
available to codesign. If the identity is missing, locked, expired, or ambiguous,
stop and report it; never substitute ad-hoc signing, Apple Development, another
team, or disabled signing. Do not export keys or alter Keychain permissions to
make a build pass.

Run this from the repository root as your normal user (no `sudo`):

```sh
rtk proxy bash Scripts/build-local.sh
```

[Scripts/build-local.sh](Scripts/build-local.sh) builds and signs through native
`xcodebuild` with explicit Release/arm64 settings, the certificate/team above,
the fixed signing identifier, Hardened Runtime, and a secure timestamp. It checks
the signature and exact entitlements before atomically installing the signed
bytes to `~/.local/bin/pomme`. If an installed CLI exists, its designated
requirement must match the new build's before replacement. Build/signature or
compatibility failures leave the installed CLI unchanged.

### Mandatory signed runner before testing

Before **any** Pomme test (unit, integration, CLI, or live VM), build and
install the current source with `rtk proxy bash Scripts/build-local.sh`.
Confirm the install succeeded, the signed Release still passes the script's
signature and entitlement checks, a fresh login shell resolves `pomme` to
`/Users/wes/.local/bin/pomme`, and that executable reports the expected source
commit with `--version`. If any check fails, stop; do not test a stale,
Debug/ad-hoc, DerivedData, or alternate-path executable.

Every test that launches the Pomme CLI must use the exact installed path
`/Users/wes/.local/bin/pomme`, including live VM tests and CLI integration
tests. Pass that path explicitly as the integration runner; do not rely on a
different `pomme` found on `PATH`. Native `xcodebuild test` runs its own test
bundle, not the installed CLI, so it may run only after this signed-install
gate and must not be described as a test of the installed executable.

Before replacement, the script retains both signed executables in the
append-only `~/Library/Application Support/pomme/AgentArtifacts/sha256` store.
Recovery installation can therefore resume using the exact agent digest pinned
by an existing VM's journal while the host CLI receives fixes. The resolver
rechecks ownership, signature, inode, and digest; never rewrite a journal or
substitute the current build's digest.

To retain a previously preserved signed Pomme build explicitly, use
`rtk proxy bash Scripts/archive-agent.sh --source /absolute/path/to/pomme
--expected-sha256 DIGEST` (on one line). This only adds a verified artifact; it
does not modify any VM or credential. Do not garbage-collect pinned artifacts
without proving that no retained VM journal needs them.

The default build directory is
`~/Library/Developer/Xcode/DerivedData/pomme-local-signed`.
`--derived-data-path DIR` and `--install-dir DIR` accept absolute paths for isolated
verification; they do not change the signing identity. The script does not modify
shell startup files or publish artifacts.

Keep `~/.local/bin` on the shell PATH. On this host it is already configured in
both `~/.zprofile` and `~/.zshrc`; do not append duplicate entries. Verify command
resolution after installation in a fresh login shell:

```sh
rtk proxy zsh -lc 'command -v pomme'
rtk pomme --help
```

Run `rtk proxy bash Tests/LocalBuildInstall.sh` for offline installer regression
tests. Use `rtk proxy xcodebuild -help` when updating the build command for a new
Xcode version. Do not substitute an unsigned or ad-hoc artifact if it fails.

### Keychain continuity

Persistent agent credentials use the user's file-based login Keychain through
Apple's `Security.framework` (`SecItem*` with explicit `SecKeychain` targeting).
Do not opt into the Data Protection Keychain or add Keychain access-group
entitlements. Keep the UUID-scoped service and agent account unchanged. Require
the login Keychain to be unlocked; do not auto-unlock it, read host passwords,
or grant access to compiler/interpreter binaries. Tests use isolated temporary
Keychains, never real Pomme credentials.

Keychain continuity depends on compatible designated requirements, not an
unchanging executable hash or filename. Preserve the signing identifier, team,
signing channel, and Keychain service/account names. A renewed certificate may
remain compatible; review the requirements before changing certificates rather
than pinning a build's CDHash. See [Apple's code signing update guidance](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
and [TN3127: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Do not delete/recreate credentials, broaden ACLs, or reset the Keychain to hide a
signing mismatch. Items previously authorized for an ad-hoc or different identity
may still need explicit user authorization; this workflow does not migrate them.

`Scripts/build-release-pkg.sh` is a separate packaging workflow that re-signs a
copy of its input and checks the same identifier, team, certificate, Hardened
Runtime, timestamp, entitlements, and designated requirement as
`Scripts/build-local.sh`. The Alpha and Release workflows run it in CI; see
[Docs/Releasing.md](Docs/Releasing.md). When local packaging is requested, set
`DEVELOPER_ID_APPLICATION` to the exact certificate above and supply the
verified Release products with `--products-dir`. Re-signing doesn't preserve
Xcode's generated designated requirement, so the script states Xcode's
requirement explicitly and checks its exact text; `build-local.sh` refuses to
replace an installed CLI whose requirement text differs. Pomme doesn't notarize
its packages. Signing verification does not establish successful guest MDM
enrollment, and does not authorize publication or VM operations.

## Releases

A push to `main` that passes CI publishes a signed alpha pre-release, and it
also redeploys https://pommevm.dev. Treat a push to `main` as a public release.
Don't push to `main`, run the Alpha or Release workflow, approve a
`pomme-release` deployment, create or delete release tags, or run
`Scripts/configure-release-secrets.sh` unless the user asks for that action.
Never export signing identities yourself; the user exports them.

Pomme follows [Semantic Versioning](https://semver.org/). When you raise
`MARKETING_VERSION` after a stable release, choose the patch, minor, or major
bump from what the next release will contain, as step 7 of "Stable releases"
in [Docs/Releasing.md](Docs/Releasing.md) describes. Never lower it after one
of its alphas publishes.

The site serves `Website/public/install.pl` at https://pommevm.dev/install.pl,
and `pomme update` runs that script with `/usr/bin/perl` for every release
install that Homebrew doesn't manage. It's a Perl program that uses only core
modules, so that it runs with the Perl that macOS includes. A push that changes the script therefore changes how every
such installation updates. Before you change it, run
`rtk proxy bash Tests/InstallScript.sh --runner /Users/wes/.local/bin/pomme`.

## Keep the documentation site current

Every change to the public CLI must update the documentation site in
`Website/` in the same change. That includes adding, removing, or renaming a
command or subcommand; changing an argument, flag, default, accepted value, or
help text; and changing the output fields, messages, or exit behavior that
users or scripts rely on. Don't leave the site to a follow-up change.

1. Build and install the signed CLI with `rtk proxy bash Scripts/build-local.sh`,
   and confirm that `/Users/wes/.local/bin/pomme --version` reports the current
   source.
2. Regenerate the command-line reference from that executable with
   `cd Website && rtk proxy npm run reference`. Never edit
   `Website/src/content/docs/reference/cli/` by hand. When a new flag applies
   to most commands, add it to `commonFlagDescriptions` and to the common-flags
   table in `Website/scripts/generate-cli-reference.mjs` so that it isn't
   repeated on every page.
3. Update the hand-written pages that describe the changed behavior. Search
   `Website/src/content/docs` for the command name and check the related
   guide and concept pages, `resources/troubleshooting.md`,
   `guides/script-pomme.md`, and `resources/release-notes.md`.
4. When you add a subcommand, add it to `CommandCatalog` in
   `Sources/PommeCLI/CLI/Commands/UIUtilityCommands.swift` so that
   `pomme tools` and `pomme agent-help` list it.
5. Follow `Website/CONTRIBUTING.md`. Run `rtk proxy npm run build` and
   `rtk proxy npm run lint:style` from `Website/`, and don't add new Vale
   errors or warnings to the pages that you change.
6. Describe only behavior that you verified against the source or the
   installed CLI.
