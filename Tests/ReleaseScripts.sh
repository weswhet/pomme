#!/usr/bin/env bash
# Offline checks for the release planning, notes, formula, and secret scripts.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plan="$repo_root/Scripts/plan-release.sh"
notes="$repo_root/Scripts/release-notes.sh"
formula="$repo_root/Scripts/render-homebrew-formula.sh"
secrets="$repo_root/Scripts/configure-release-secrets.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/pomme-release-scripts.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failures=0
check() {
  local name="$1"
  shift
  if "$@"; then echo "ok - $name"; else echo "not ok - $name" >&2; failures=$((failures + 1)); fi
}
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
value() { sed -n "s/^$1=//p" <<<"$2"; }

# A scratch repository with the files that the scripts read.
git_repo="$work/repo"
mkdir -p "$git_repo/Config" "$git_repo/Sources" "$git_repo/Website"
cd "$git_repo"
git init -q -b main
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false
git config tag.gpgsign false
set_version() { printf 'PRODUCT_NAME = pomme\nMARKETING_VERSION = %s\n' "$1" > Config/Shared.xcconfig; }
commit_file() { mkdir -p "$(dirname "$1")"; echo "$RANDOM" >> "$1"; git add -A; git commit -q -m "$2"; }
set_version 0.1.0
commit_file Sources/main.swift "Add the CLI"

out="$("$plan" alpha --commit HEAD)"
check "first alpha publishes" [ "$(value publish "$out")" = true ]
check "first alpha is alpha.1" [ "$(value version "$out")" = 0.1.0-alpha.1 ]
check "first alpha has no previous tag" [ -z "$(value previous_tag "$out")" ]
check "first alpha notes" contains "$("$notes" alpha --version 0.1.0-alpha.1 --commit HEAD)" "This is the first alpha build."
git tag v0.1.0-alpha.1

out="$("$plan" alpha --commit HEAD)"
check "tagged commit doesn't publish again" [ "$(value publish "$out")" = false ]
check "tagged commit names its alpha" contains "$(value reason "$out")" "v0.1.0-alpha.1 already includes"
check "--force doesn't republish a tagged commit" [ "$(value publish "$("$plan" alpha --commit HEAD --force)")" = false ]

commit_file Website/index.md "Update the site"
commit_file Tests/unit.swift "Add a test"
commit_file README.md "Edit the README"
out="$("$plan" alpha --commit HEAD)"
check "docs and tests alone don't publish" [ "$(value publish "$out")" = false ]
check "docs-only reason" contains "$(value reason "$out")" "Only documentation or tests changed since v0.1.0-alpha.1"
out="$("$plan" alpha --commit HEAD --force)"
check "--force publishes docs-only changes" [ "$(value publish "$out")" = true ]

git mv Sources/main.swift Tests/moved.swift
git commit -q -m "Move a source file into Tests"
check "moving a source file out publishes" [ "$(value publish "$("$plan" alpha --commit HEAD)")" = true ]

commit_file Sources/feature.swift "Add a feature"
out="$("$plan" alpha --commit HEAD)"
check "source change publishes" [ "$(value publish "$out")" = true ]
check "second alpha is alpha.2" [ "$(value tag "$out")" = v0.1.0-alpha.2 ]
check "previous tag is alpha.1" [ "$(value previous_tag "$out")" = v0.1.0-alpha.1 ]
check "full commit" [ "$(value commit "$out")" = "$(git rev-parse HEAD)" ]
alpha_notes="$("$notes" alpha --version 0.1.0-alpha.2 --commit HEAD --previous-tag v0.1.0-alpha.1)"
check "alpha notes list changes" contains "$alpha_notes" "### Changes since v0.1.0-alpha.1"
check "alpha notes include a commit" contains "$alpha_notes" "- Add a feature ([\`"
check "alpha notes exclude older commits" lacks "$alpha_notes" "Add the CLI"
check "alpha notes have no Homebrew step" lacks "$alpha_notes" "brew install"
check "alpha notes download the tarball" contains "$alpha_notes" "releases/download/v0.1.0-alpha.2/pomme-0.1.0-alpha.2-arm64.tar.gz"
older="$(git rev-parse HEAD~1)"
git tag v0.1.0-alpha.2

# Numbers are compared as numbers, not text.
commit_file Sources/feature.swift "Change the feature"
git tag v0.1.0-alpha.9
commit_file Sources/feature.swift "Change the feature again"
git tag v0.1.0-alpha.10
commit_file Sources/feature.swift "Change it once more"
check "alpha after alpha.10 is alpha.11" [ "$(value version "$("$plan" alpha --commit HEAD)")" = 0.1.0-alpha.11 ]
out="$("$plan" alpha --commit "$older")"
check "an older commit than the newest alpha doesn't publish" [ "$(value publish "$out")" = false ]

# Stable promotion.
check "stable rejects a non-alpha tag" bash -c "! '$plan' stable --alpha v0.1.0 2>/dev/null"
check "stable rejects a missing tag" bash -c "! '$plan' stable --alpha v0.1.0-alpha.99 2>/dev/null"
out="$("$plan" stable --alpha v0.1.0-alpha.9)"
check "stable version" [ "$(value version "$out")" = 0.1.0 ]
check "stable tag" [ "$(value tag "$out")" = v0.1.0 ]
check "stable commit is the alpha's" [ "$(value commit "$out")" = "$(git rev-parse 'v0.1.0-alpha.9^{commit}')" ]
check "first stable has no previous tag" [ -z "$(value previous_tag "$out")" ]
git checkout -q -b side HEAD~3
commit_file Sources/side.swift "Side work"
git tag v0.1.0-alpha.20
git checkout -q main
check "stable rejects an alpha that isn't on the branch" bash -c "! '$plan' stable --alpha v0.1.0-alpha.20 --branch main 2>/dev/null"

notes_file="$work/release-notes.md"
cat > "$notes_file" <<'MD'
---
title: Release notes
---

## Pomme 0.2.0 (pre-release)

Not yet.

## Pomme 0.1.0

The first release. See [the quickstart](/get-started/quickstart/).

:::caution
Back up your VMs.

Really.
:::

## Pomme 0.0.9

Older.
MD
stable_notes="$("$notes" stable --version 0.1.0 --commit v0.1.0-alpha.9 --notes-file "$notes_file")"
check "stable notes copy the section" contains "$stable_notes" "The first release."
check "stable notes stop at the next section" lacks "$stable_notes" "Older."
check "stable notes skip other versions" lacks "$stable_notes" "Not yet."
check "stable notes link to the site" contains "$stable_notes" "](https://pommevm.dev/get-started/quickstart/)"
check "stable notes convert asides" contains "$stable_notes" $'> [!WARNING]\n> Back up your VMs.\n>\n> Really.'
check "stable notes start with the section text" [ "${stable_notes%%$'\n'*}" = "The first release. See [the quickstart](https://pommevm.dev/get-started/quickstart/)." ]
check "stable notes include Homebrew" contains "$stable_notes" "brew install weswhet/tap/pomme"
check "stable notes reject a pre-release heading" bash -c "! '$notes' stable --version 0.2.0 --commit HEAD --notes-file '$notes_file' 2>/dev/null"
check "stable notes reject a missing section" bash -c "! '$notes' stable --version 0.3.0 --commit HEAD --notes-file '$notes_file' 2>/dev/null"

git tag v0.1.0 v0.1.0-alpha.9
check "alphas stop once the version is released" bash -c "! '$plan' alpha --commit HEAD 2>/dev/null"
check "stable rejects an existing release" bash -c "! '$plan' stable --alpha v0.1.0-alpha.10 2>/dev/null"
set_version 0.2.0
git add -A
git commit -q -m "Start 0.2.0"
out="$("$plan" alpha --commit HEAD)"
check "next version starts at alpha.1" [ "$(value version "$out")" = 0.2.0-alpha.1 ]
check "next version compares with the newest alpha" [ "$(value previous_tag "$out")" = v0.1.0-alpha.10 ]
commit_file Sources/next.swift "Next feature"
git tag v0.2.0-alpha.1
out="$("$plan" stable --alpha v0.2.0-alpha.1)"
check "second stable compares with the first" [ "$(value previous_tag "$out")" = v0.1.0 ]
check "stable notes link the full changelog" contains \
  "$("$notes" stable --version 0.1.0 --commit v0.2.0-alpha.1 --previous-tag v0.0.9 --notes-file "$notes_file")" \
  "compare/v0.0.9...v0.1.0"
set_version 0.2
git add -A
git commit -q -m "Bad version"
check "alpha rejects a malformed MARKETING_VERSION" bash -c "! '$plan' alpha --commit HEAD 2>/dev/null"

# The Homebrew formula.
sha="$(printf 'a%.0s' {1..64})"
rendered="$("$formula" --version 0.1.0 --sha256 "$sha")"
check "formula URL" contains "$rendered" 'url "https://github.com/weswhet/pomme/releases/download/v0.1.0/pomme-0.1.0-arm64.tar.gz"'
check "formula license" contains "$rendered" 'license "Apache-2.0"'
check "formula checks the version" contains "$rendered" 'shell_output("#{bin}/pomme --version")'
check "formula follows the latest stable release" contains "$rendered" 'strategy :github_latest'
check "formula installs shell completions" contains "$rendered" 'generate_completions_from_executable(bin/"pomme", "--generate-completion-script")'
# brew style installs its RuboCop gems on first use, so CI skips it.
if command -v brew >/dev/null 2>&1 && [[ -z "${CI:-}" ]]; then
  mkdir -p "$work/tap/Formula"
  printf '%s\n' "$rendered" > "$work/tap/Formula/pomme.rb"
  check "formula passes brew style" brew style "$work/tap/Formula/pomme.rb"
fi
check "formula rejects a bad digest" bash -c "! '$formula' --version 0.1.0 --sha256 xyz 2>/dev/null"

# The signing p12 check. LibreSSL writes one key per p12, so these cases cover
# the rejections; the accepted case needs a real two-identity export.
make_p12() {
  local name="$1" cn="$2"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$cn/OU=2D8XQ77EBQ" \
    -keyout "$work/$name.key" -out "$work/$name.crt" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$work/$name.key" -in "$work/$name.crt" \
    -passout pass:secret -out "$work/$name.p12" 2>/dev/null
}
make_p12 application 'Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)'
make_p12 development 'Apple Development: Wesley Whetstone (TETT7L297L)'
run_check() { DEVELOPER_ID_CERTIFICATE_PASSWORD="$2" "$secrets" --p12 "$work/$1.p12" --check-only 2>&1; }
out="$(run_check application secret || true)"
check "p12 without the Installer identity is rejected" contains "$out" "doesn't contain Developer ID Installer"
out="$(run_check development secret || true)"
check "p12 with another identity is rejected" contains "$out" "unexpected certificate: Apple Development"
out="$(run_check application wrong || true)"
check "p12 with the wrong password is rejected" contains "$out" "Check the password."
check "p12 is required" bash -c "! '$secrets' --check-only >/dev/null 2>&1"

if [[ "$failures" -gt 0 ]]; then
  echo "$failures release script checks failed." >&2
  exit 1
fi
echo "Release script checks passed."
