#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/Scripts/validate-package.sh"
work_dir="$(mktemp -d /tmp/pomme-packaging-identity.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

payload="$work_dir/payload"
mkdir -p "$payload/usr/local/bin"
printf '#!/bin/sh\nexit 0\n' > "$payload/usr/local/bin/pomme"
chmod 0755 "$payload/usr/local/bin/pomme"

run_validator() {
  bash "$validator" \
    --payload-root "$payload" \
    --entitlements "$repo_root/Config/pomme.entitlements" \
    "$@"
}

run_validator

# Any foreign executable or guest path in the host package is a hard failure.
printf '#!/bin/sh\nexit 0\n' > "$payload/usr/local/bin/foreign-cli"
chmod 0755 "$payload/usr/local/bin/foreign-cli"
if run_validator >/dev/null 2>&1; then
  echo "validator accepted a foreign host executable" >&2
  exit 1
fi
rm -f "$payload/usr/local/bin/foreign-cli"

mkdir -p "$payload/usr/local/libexec"
if run_validator >/dev/null 2>&1; then
  echo "validator accepted a guest directory in the host package" >&2
  exit 1
fi
rmdir "$payload/usr/local/libexec"

mkdir -p "$payload/usr/local/libexec"
printf '#!/bin/sh\nexit 0\n' > "$payload/usr/local/libexec/pomme"
chmod 0755 "$payload/usr/local/libexec/pomme"
if run_validator >/dev/null 2>&1; then
  echo "validator accepted a guest service in the host package" >&2
  exit 1
fi
rm -f "$payload/usr/local/libexec/pomme"
rmdir "$payload/usr/local/libexec"

tar_root="$work_dir/tar-root"
mkdir -p "$tar_root"
cp "$payload/usr/local/bin/pomme" "$tar_root/pomme"
tar -C "$tar_root" -czf "$work_dir/pomme.tar.gz" pomme
run_validator --tarball "$work_dir/pomme.tar.gz"

printf 'foreign\n' > "$tar_root/foreign-cli"
tar -C "$tar_root" -czf "$work_dir/foreign.tar.gz" pomme foreign-cli
if run_validator --tarball "$work_dir/foreign.tar.gz" >/dev/null 2>&1; then
  echo "validator accepted a foreign tarball entry" >&2
  exit 1
fi

bad_entitlements="$work_dir/bad.entitlements"
sed 's/<true\/>/<false\/>/' \
  "$repo_root/Config/pomme.entitlements" > "$bad_entitlements"
if bash "$validator" --payload-root "$payload" --entitlements "$bad_entitlements" >/dev/null 2>&1; then
  echo "validator accepted a package without Virtualization entitlement" >&2
  exit 1
fi

echo "Packaging identity checks passed."
