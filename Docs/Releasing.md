# Releasing Pomme

This document describes how Pomme's alpha and stable releases are built,
signed, and published, and the steps a maintainer takes for each.

## Release channels

| Channel | Tag | How it starts | Where it's published |
| --- | --- | --- | --- |
| Alpha | `v0.1.0-alpha.3` | Automatically, after CI passes on `main` | GitHub pre-release |
| Stable | `v0.1.0` | Manually, by promoting a qualified alpha | GitHub release marked **Latest**, and the `weswhet/tap/pomme` Homebrew formula |

`MARKETING_VERSION` in `Config/Shared.xcconfig` is the version of the next
stable release. Alphas count up toward it: `0.1.0-alpha.1`, `0.1.0-alpha.2`,
and so on, until `0.1.0` ships.

## What a release contains

Each release, alpha or stable, has these assets:

- `pomme-VERSION-arm64.tar.gz`: the `pomme` executable.
- `pomme-VERSION-arm64.pkg`: an installer package, signed with the Developer
  ID Installer certificate, that installs `/usr/local/bin/pomme`.
- `pomme-VERSION-arm64.dSYM.zip`: the debug symbols. Release builds strip the
  executable, so a crash report shows function names only with the dSYM.
- `SHA256SUMS`: the SHA-256 digest of each of the other assets.

The executable is signed exactly as `Scripts/build-local.sh` signs it: the
Developer ID Application certificate, the `com.github.weswhet.pomme`
identifier, Hardened Runtime, a secure timestamp, and only the Virtualization
entitlement. Re-signing with `codesign` would generate a different designated
requirement than Xcode does, so `Scripts/build-release-pkg.sh` states Xcode's
requirement explicitly and checks its exact text. The requirement is therefore
identical: Keychain items that a locally built `pomme` created keep working,
and `Scripts/build-local.sh` can replace a release with a local build.

The executable's Info.plist section has `PommeDistribution` set to `release`.
`pomme update` and its update check act only on such builds. Every other build
reports `source`.

Each asset except `SHA256SUMS` has a GitHub build provenance attestation.
Anyone can check that an asset came from this repository's workflow:

```sh
gh attestation verify pomme-0.1.0-arm64.tar.gz --repo weswhet/pomme
```

`pomme --version` prints the release version and commit, such as
`pomme 0.1.0-alpha.3 (9122520)`.

Pomme isn't notarized, so Gatekeeper blocks a copy that a web browser
downloads. Homebrew, `curl`, and `gh release download` don't mark their
downloads for Gatekeeper checks, so their copies run.

## How users install and update

| Method | What it installs | Source |
| --- | --- | --- |
| `brew install weswhet/tap/pomme` | The newest stable release | `Formula/pomme.rb` in `weswhet/homebrew-tap`, which the Release workflow renders with `Scripts/render-homebrew-formula.sh` |
| `curl -fsSL https://pommevm.dev/install.pl \| perl` | The newest stable release, or with `POMME_CHANNEL=alpha` the newest alpha | `Website/public/install.pl`, which the site publishes |
| `curl -fsSL https://pommevm.dev/install.pl \| POMME_PACKAGE=1 perl` | The installer package | The same script |

The formula is a formula, not a cask, because Homebrew quarantines a cask's
download, and Gatekeeper blocks the unnotarized executable. A formula installs
the signed bytes unchanged, generates shell completions, and has a `livecheck`
that follows the latest stable release.

The install script is a Perl program, so it needs only the `/usr/bin/perl` that
macOS includes. Piped to Perl, it takes options from environment variables, or
after `perl -`, because Perl reads anything before the program as its own
options. Piped to `sh` by mistake, it prints the Perl command and stops. It
checks the tarball against `SHA256SUMS`, checks Pomme's
Developer ID requirement and the reported version, and installs atomically in
`~/.local/bin`. It won't replace a `pomme` that doesn't satisfy the requirement.
`Tests/InstallScript.sh` tests it against a release served from a local
directory. CI runs the cases that must fail, and the build workflow runs every
case against the signed release executable.

`pomme update` follows Codex's updater: it never replaces its own executable.
It runs `brew upgrade weswhet/tap/pomme` for a Homebrew install and the install
script, downloaded from `https://pommevm.dev/install.pl` and run with
`/usr/bin/perl`, for any other release install. Because `pomme update` runs the
published script, a change to `Website/public/install.pl` reaches every installation as soon as the site
deploys from `main`. Test the script with `Tests/InstallScript.sh --runner` and
a signed `pomme` before you push it.

An installed alpha follows the newest alpha or stable release, and a stable
release follows stable releases. Homebrew installs follow the tap's formula. A
release build checks for a newer version about once a day in a detached
background process, and an interactive command shows a one-line notice. The
check never runs for JSON output, without a terminal, or when `CI` or
`POMME_NO_UPDATE_CHECK` is set.

VM creation copies the executable that it pins as the VM's agent into
`AgentArtifacts/sha256`. Updates, including a plain `brew upgrade`, therefore
never remove the agent that a repair or a resumed creation needs.

## How the workflows fit together

- `.github/workflows/build-release.yml` builds one commit on the `xcode-27`
  runner, signs and packages it with `Scripts/build-release-pkg.sh`, checks
  that `--version` matches, runs the command-line contract tests against the
  signed executable, attests the assets, and uploads them as a workflow
  artifact. It never publishes anything.
- `.github/workflows/alpha.yml` plans an alpha with
  `Scripts/plan-release.sh alpha`, calls the build workflow, and publishes the
  pre-release with notes from `Scripts/release-notes.sh alpha`.
- `.github/workflows/release.yml` plans a stable release with
  `Scripts/plan-release.sh stable`, calls the build workflow, waits for your
  approval, publishes the release, and updates the Homebrew formula.

The job that signs has the signing identities but can't write to the
repository. The job that publishes can write to the repository but never sees
the signing identities or runs the build. `Tests/ReleaseScripts.sh` tests the
planning, notes, formula, and secret-checking scripts in CI.

Two GitHub environments hold the secrets. Only the `main` branch can deploy to
either one.

| Environment | Secrets | Protection |
| --- | --- | --- |
| `pomme-signing` | `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD` | `main` only |
| `pomme-release` | `HOMEBREW_TAP_DEPLOY_KEY` | `main` only, and a required reviewer approves each deployment |

## Set up release signing

You need to do this once, and again when a certificate is renewed. It needs the
Developer ID Application and Developer ID Installer certificates, with their
private keys, in your login keychain.

1. From the repository root, run the export script in a terminal:

   ```sh
   Scripts/export-signing-identities.swift
   ```

   The script finds the two identities in your login keychain, and checks that
   exactly one valid identity of each kind exists. It exports them, with their
   private keys, as a `.p12` with a random password in a private temporary
   directory. macOS asks for your login keychain password once for each
   private key. Choose **Allow**, not **Always Allow**, so that the Swift
   interpreter doesn't keep access to the keys.

   The script then runs `Scripts/configure-release-secrets.sh` with the
   `.p12`, and deletes the `.p12` when that script finishes. The setup script
   refuses a file that holds anything other than the two Developer ID
   identities. Then it does the following:

   - Creates or updates the `pomme-signing` and `pomme-release` environments.
     You become the required reviewer for `pomme-release`.
   - Stores the `.p12` and its password in `pomme-signing`.
   - Creates a deploy key with write access to `weswhet/homebrew-tap`,
     replacing the one from an earlier run, and stores its private key in
     `pomme-release`.

The export script passes its other options to the setup script. To check the
export without changing anything on GitHub, add `--check-only`. To see which
identities the script would export, without exporting anything, add `--list`.

To export the `.p12` without running the setup script, add `--output FILE`.
The script asks for the file's password. Then run
`bash Scripts/configure-release-secrets.sh --p12 FILE`, and delete the file.

## Alpha releases

The Alpha workflow runs each time CI completes on `main`. It publishes the
next alpha when all of the following are true:

- CI passed for a push to `main` in this repository.
- No alpha includes the commit yet. If CI for an older commit finishes after
  a newer alpha, the workflow doesn't publish the older one.
- Something besides documentation and tests changed since the previous alpha.
  Changes only to `Website/`, `Docs/`, `Tests/`, Markdown files, `LICENSE`,
  or `.github/workflows/ci.yml` don't produce an alpha.

Alphas publish one at a time, so each gets the next number. The release notes
list the commits since the previous alpha.

To publish an alpha of the current `main` by hand, such as after a
documentation-only change, run the workflow with `force`:

```sh
gh workflow run Alpha --ref main -f force=true
```

After a stable release, alphas fail until you raise `MARKETING_VERSION`. See
step 7 of the next procedure.

## Stable releases

A stable release promotes one alpha. The Release workflow rebuilds that
alpha's commit with the stable version, because the version is part of the
executable, and runs every check again.

1. Choose the alpha to promote, such as `v0.1.0-alpha.7`.
1. Qualify that alpha as [Release qualification](Qualification.md) describes.
1. On `main`, finish the version's section of
   `Website/src/content/docs/resources/release-notes.md`. Change its heading
   to exactly `## Pomme 0.1.0`, without `(pre-release)`, and describe the
   release as published. The workflow refuses a release without that heading,
   and it copies the section into the GitHub release.
1. Start the Release workflow:

   ```sh
   gh workflow run Release --ref main -f alpha=v0.1.0-alpha.7 -f qualification=QUALIFIED
   ```

   The workflow checks that the alpha is a published pre-release on `main`,
   that its `MARKETING_VERSION` matches, and that the stable tag doesn't exist
   yet. Its plan summary shows the release notes.

1. When the build finishes, review the plan summary, and approve the
   `pomme-release` deployment on the workflow run's page.
1. Confirm that the release is published with `v0.1.0` marked **Latest**, and
   that `weswhet/homebrew-tap` has the new `Formula/pomme.rb`.
1. Raise `MARKETING_VERSION` in `Config/Shared.xcconfig`, such as to `0.2.0`,
   and add a `## Pomme 0.2.0 (pre-release)` section to the release notes.
   Commit and push both. Alphas of the new version start with this push.

If the Homebrew step fails after the GitHub release is published, rerun the
failed job. It continues when the published release has the same artifacts.
