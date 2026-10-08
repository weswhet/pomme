#!/usr/bin/env bash
# Offline checks for Website/public/install.pl, the Perl installer. Each case
# serves a release from a local directory through
# POMME_DOWNLOAD_URL and POMME_API_URL.
#
# The cases that install need a pomme with Pomme's Developer ID signature.
# Pass one with --runner; without it, or when it isn't signed that way, only
# the cases that must fail run.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/Website/public/install.pl"
runner=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner) runner="$2"; shift 2 ;;
    *) echo "Usage: Tests/InstallScript.sh [--runner SIGNED_POMME]" >&2; exit 64 ;;
  esac
done

readonly requirement='anchor apple generic and identifier "com.github.weswhet.pomme" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2D8XQ77EBQ"'
work="$(mktemp -d "${TMPDIR:-/tmp}/pomme-install-script.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "ok - $1"; }
fail() { echo "not ok - $1" >&2; failures=$((failures + 1)); }
check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

extra_env=()
# Runs the installer with a fake release and records its output and status.
install() {
  set +e
  env POMME_DOWNLOAD_URL="file://$work/download" POMME_API_URL="file://$work/api" \
    POMME_VERSION= POMME_INSTALL_DIR= POMME_CHANNEL= POMME_PACKAGE= ${extra_env[@]+"${extra_env[@]}"} \
    /usr/bin/perl "$installer" "$@" > "$work/out" 2>&1
  status=$?
  set -e
}
output_has() { grep -Fq -- "$1" "$work/out"; }
expect_failure() {
  local name="$1" message="$2"
  shift 2
  install "$@"
  if [[ $status -ne 0 ]] && output_has "$message"; then pass "$name"; else
    fail "$name"
    sed 's/^/    /' "$work/out" >&2
  fi
}
expect_success() {
  local name="$1"
  shift
  install "$@"
  if [[ $status -eq 0 ]]; then pass "$name"; else
    fail "$name"
    sed 's/^/    /' "$work/out" >&2
  fi
}

# Publishes EXECUTABLE as the pomme in release VERSION's tarball.
publish() {
  local version="$1" executable="$2" release="$work/download/v$1"
  rm -rf "$release" "$work/payload"
  mkdir -p "$release" "$work/payload"
  cp "$executable" "$work/payload/pomme"
  COPYFILE_DISABLE=1 tar -C "$work/payload" -czf "$release/pomme-$version-arm64.tar.gz" pomme
  (cd "$release" && shasum -a 256 "pomme-$version-arm64.tar.gz" > SHA256SUMS)
}

ad_hoc="$work/ad-hoc-pomme"
cp /usr/bin/true "$ad_hoc"
codesign --force --sign - "$ad_hoc" 2>/dev/null

check "Perl compiles the installer" /usr/bin/perl -wc "$installer"
expect_success "help" --help
check "help lists the options" output_has "--install-dir DIR"
# `curl ... | perl` reads the program from standard input, and options follow
# `perl -`.
check "help works when piped to perl -" \
  bash -c '/usr/bin/perl - --help < "$1" | grep -Fq -- "--install-dir DIR"' _ "$installer"
# Piped to sh by mistake, the installer explains how to run it, in any sh.
for shell in /bin/sh /bin/bash /bin/dash /bin/zsh; do
  [[ -x "$shell" ]] || continue
  check "piped to $shell, it says to use perl" \
    bash -c '! "$1" < "$2" > /dev/null 2> "$3" && grep -Fq "| perl" "$3" && [[ $(wc -l < "$3") -eq 1 ]]' \
    _ "$shell" "$installer" "$work/sh-err"
done
extra_env=(POMME_PACKAGE=1)
expect_failure "POMME_PACKAGE=1 is --package" "takes no --install-dir" --install-dir "$work/bin"
extra_env=()
expect_failure "rejects an unknown option" "Unknown option: --bogus" --bogus
expect_failure "rejects --package with --install-dir" "takes no --install-dir" --package --install-dir "$work/bin"
expect_failure "rejects a relative install directory" "needs an absolute path" --install-dir bin
expect_failure "rejects a malformed version" "isn't a Pomme version" --version '1.0;rm'
expect_failure "reports a missing release" "Couldn't download pomme-9.9.9-arm64.tar.gz" \
  --version 9.9.9 --install-dir "$work/bin"
check "a failed install creates nothing" test ! -e "$work/bin"

publish 1.0.0 "$ad_hoc"
expect_failure "rejects pomme without the Developer ID signature" "doesn't have Pomme's Developer ID signature" \
  --version 1.0.0 --install-dir "$work/bin"
check "a rejected download installs nothing" test ! -e "$work/bin/pomme"

printf '%s  pomme-1.0.0-arm64.tar.gz\n' "$(printf '0%.0s' {1..64})" > "$work/download/v1.0.0/SHA256SUMS"
expect_failure "rejects a tarball that doesn't match SHA256SUMS" "doesn't match its SHA-256 digest" \
  --version 1.0.0 --install-dir "$work/bin"
printf '%s  other.tar.gz\n' "$(printf '0%.0s' {1..64})" > "$work/download/v1.0.0/SHA256SUMS"
expect_failure "rejects a tarball missing from SHA256SUMS" "SHA256SUMS has no digest" \
  --version 1.0.0 --install-dir "$work/bin"

mkdir -p "$work/api/releases"
expect_failure "reports an unreachable release list" "Couldn't reach GitHub" --install-dir "$work/bin"

mkdir -p "$work/linked"
ln -s "$ad_hoc" "$work/linked/pomme"
expect_failure "refuses to replace a symbolic link" "is a symbolic link" --version 1.0.0 --install-dir "$work/linked"

mkdir -p "$work/other"
cp "$ad_hoc" "$work/other/pomme"
expect_failure "refuses to replace a differently signed pomme" "won't replace it" --version 1.0.0 --install-dir "$work/other"
check "the differently signed pomme is unchanged" cmp -s "$ad_hoc" "$work/other/pomme"

if [[ -n "$runner" ]] && codesign --verify --strict --test-requirement="=$requirement" "$runner" 2>/dev/null; then
  version="$("$runner" --version | awk '{ print $2 }')"
  publish "$version" "$runner"

  expect_success "installs a signed release" --version "$version" --install-dir "$work/bin"
  check "the installed pomme is the release's" cmp -s "$runner" "$work/bin/pomme"
  check "the installed pomme keeps its signature" \
    codesign --verify --strict --test-requirement="=$requirement" "$work/bin/pomme"
  check "the installed pomme is mode 755" [ "$(stat -f '%Lp' "$work/bin/pomme")" = 755 ]
  check "the install leaves no staged file" [ -z "$(find "$work/bin" -name '.pomme-install.*')" ]
  check "the install reports the version" output_has "Installed pomme $version at $work/bin/pomme."
  check "the install explains PATH" output_has "isn't in your PATH"

  inode="$(stat -f '%i' "$work/bin/pomme")"
  expect_success "replaces a signed pomme" --version "v$version" --install-dir "$work/bin"
  check "a replacement writes a new file" [ "$(stat -f '%i' "$work/bin/pomme")" != "$inode" ]

  printf '{"tag_name": "v%s", "body": null}\n' "$version" > "$work/api/releases/latest"
  expect_success "installs the newest release by default" --install-dir "$work/latest"
  check "the newest release is installed" cmp -s "$runner" "$work/latest/pomme"

  rm -rf "$work/api/releases"
  printf '[{"tag_name": "v%s", "prerelease": true}]\n' "$version" > "$work/api/releases"
  expect_success "installs the newest alpha with --alpha" --alpha --install-dir "$work/alpha"
  check "the newest alpha is installed" cmp -s "$runner" "$work/alpha/pomme"
  extra_env=(POMME_CHANNEL=alpha POMME_INSTALL_DIR="$work/alpha-env")
  expect_success "installs the newest alpha with POMME_CHANNEL=alpha"
  extra_env=()
  check "POMME_CHANNEL=alpha installs the newest alpha" cmp -s "$runner" "$work/alpha-env/pomme"

  publish 9.9.9 "$runner"
  expect_failure "rejects a pomme that reports another version" "instead of version 9.9.9" \
    --version 9.9.9 --install-dir "$work/mismatch"
  check "a mismatched version installs nothing" test ! -e "$work/mismatch/pomme"
else
  echo "skip - the install cases need --runner with a pomme signed by Pomme's Developer ID"
fi

if [[ $failures -ne 0 ]]; then
  echo "$failures install script check(s) failed." >&2
  exit 1
fi
echo "All install script checks passed."
