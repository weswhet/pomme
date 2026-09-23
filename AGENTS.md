# Pomme agent instructions

## Disposable test VM resources

For future disposable test VMs, explicitly pass `--disk-size 40GB --memory 4GB`
instead of the CLI's larger defaults. Increase resources only when the test
requires it and explain why. Keep an active before/after comparison at the same
resource settings across all measured runs. A 25GB disk failed Tahoe installation
in the September 6, 2026 lab; do not reuse that size for Tahoe install tests.

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
shell startup files or publish/notarize artifacts.

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

`Scripts/build-release-pkg.sh` is a separate packaging workflow that re-signs its
input. When packaging is requested, set `DEVELOPER_ID_APPLICATION` to the exact
certificate above, supply the verified Release products with `--products-dir`,
and repeat the signature/requirement checks on the final packaged executable.
Do not assume re-signing preserves Xcode's generated designated requirement.
Signing verification does not establish notarization or successful guest MDM
enrollment, and does not authorize publication or VM operations.
