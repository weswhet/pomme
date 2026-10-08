#!/usr/bin/env bash
# Build, sign, verify, and package a Pomme release: the executable as a
# tarball and an installer package, its dSYM, and SHA256SUMS.
set -euo pipefail

usage() {
  echo 'Usage: Scripts/build-release-pkg.sh [--version <version>] [--dist-dir <dir>] [--products-dir <dir>]'
}

fail() { echo "build-release-pkg: $*" >&2; exit 70; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${VERSION:-}"
dist_dir="${DIST_DIR:-$repo_root/dist}"
products_dir=""
built_here=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --dist-dir) dist_dir="$2"; shift 2 ;;
    --products-dir) products_dir="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ -n "$version" ]] || version="$(git -C "$repo_root" describe --tags --always --dirty | sed 's/^v//')"
[[ "$version" != *[!A-Za-z0-9._-]* ]] || { echo "Invalid version: $version" >&2; exit 64; }
: "${DEVELOPER_ID_APPLICATION:?Developer ID Application signing is required}"

# The identity that Scripts/build-local.sh signs with. Keychain items that
# the installed CLI creates depend on this designated requirement.
readonly team_id='2D8XQ77EBQ'
readonly identifier='com.github.weswhet.pomme'
readonly requirement='anchor apple generic and identifier "com.github.weswhet.pomme" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2D8XQ77EBQ"'
# The designated requirement that Xcode gives Scripts/build-local.sh builds.
# Re-signing with codesign would generate a different one, and build-local.sh
# refuses to replace an installed pomme whose requirement differs, so a
# release states Xcode's requirement explicitly. codesign prints it with
# /* exists */ comments.
readonly designated='anchor apple generic and identifier "com.github.weswhet.pomme" and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2D8XQ77EBQ")'

build_root="$repo_root/build/release-package"
derived="$build_root/DerivedData"
payload="$build_root/payload"
tar_root="$build_root/tarball"
mkdir -p "$dist_dir"
dist_dir="$(cd "$dist_dir" && pwd)"
rm -rf "$build_root"
mkdir -p "$build_root" "$payload/usr/local/bin" "$tar_root"

if [[ -z "$products_dir" ]]; then
  commit="$(git -C "$repo_root" describe --always --dirty 2>/dev/null || echo unknown)"
  xcodebuild -project "$repo_root/pomme.xcodeproj" -scheme pomme -configuration Release \
    -arch arm64 -sdk macosx -derivedDataPath "$derived" build \
    "MARKETING_VERSION=$version" "POMME_GIT_COMMIT=$commit" "POMME_DISTRIBUTION=release"
  products_dir="$derived/Build/Products/Release"
  built_here=1
else
  products_dir="$(cd "$products_dir" && pwd)"
fi
dsym="$products_dir/pomme.dSYM"
[[ -f "$products_dir/pomme" && -x "$products_dir/pomme" && ! -L "$products_dir/pomme" ]] ||
  fail "the build did not produce a regular executable: $products_dir/pomme"
# Sign a copy, so that --products-dir input stays unchanged.
runner="$build_root/pomme"
install -m 0755 "$products_dir/pomme" "$runner"

/usr/bin/codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
  --identifier "$identifier" --requirements "=designated => $designated" \
  --entitlements "$repo_root/Config/pomme.entitlements" "$runner"

has_line() {
  local lines=$'\n'"$1"$'\n'
  [[ "$lines" == *$'\n'"$2"$'\n'* ]]
}

# The same checks as Scripts/build-local.sh, and the designated requirement
# must be exactly Xcode's.
verify_signature() {
  local binary="$1" details entitlements
  /usr/bin/codesign --verify --strict --verbose=2 --test-requirement="=$requirement" "$binary"
  details="$(/usr/bin/codesign --display --verbose=4 "$binary" 2>&1)"
  has_line "$details" "Identifier=$identifier" || fail 'unexpected code-signing identifier.'
  has_line "$details" "TeamIdentifier=$team_id" || fail 'unexpected signing team.'
  has_line "$details" "Authority=$DEVELOPER_ID_APPLICATION" || fail 'unexpected signing certificate.'
  [[ "$details" == *'runtime)'* ]] || fail 'Hardened Runtime is missing.'
  [[ "$details" == *$'\nTimestamp='* ]] || fail 'a secure signing timestamp is missing.'
  [[ "$(/usr/bin/codesign --display --requirements - "$binary" 2>&1 | sed -n 's/^designated => //p')" == \
    "${designated// exists/ /* exists */}" ]] || fail "the designated requirement isn't Xcode's."
  entitlements="$(/usr/bin/codesign --display --entitlements - --xml "$binary" 2>/dev/null |
    /usr/bin/plutil -convert json -o - -- -)"
  [[ "$entitlements" == '{"com.apple.security.virtualization":true}' ]] ||
    fail 'the signature must contain only the Virtualization entitlement.'
}
verify_signature "$runner"

install -m 0755 "$runner" "$payload/usr/local/bin/pomme"
install -m 0755 "$runner" "$tar_root/pomme"
verify_signature "$tar_root/pomme"
pkg="$dist_dir/pomme-$version-arm64.pkg"
tarball="$dist_dir/pomme-$version-arm64.tar.gz"
dsym_zip="$dist_dir/pomme-$version-arm64.dSYM.zip"
unsigned="$build_root/pomme.pkg"
rm -f "$pkg" "$tarball" "$dsym_zip" "$dist_dir/SHA256SUMS"

bash "$repo_root/Scripts/validate-package.sh" \
  --payload-root "$payload" \
  --entitlements "$repo_root/Config/pomme.entitlements" \
  --runner "$runner"
COPYFILE_DISABLE=1 tar -C "$tar_root" -czf "$tarball" pomme
pkgbuild --root "$payload" --identifier com.github.weswhet.pomme --version "$version" \
  --install-location / --scripts "$repo_root/Scripts/package" "$unsigned"
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
  productsign --timestamp --sign "$DEVELOPER_ID_INSTALLER" "$unsigned" "$pkg"
  pkg_signature="$(pkgutil --check-signature "$pkg")" ||
    fail "the package signature doesn't verify."
  [[ "$pkg_signature" == *"$DEVELOPER_ID_INSTALLER"* ]] ||
    fail "the package isn't signed by $DEVELOPER_ID_INSTALLER."
else
  mv "$unsigned" "$pkg"
fi

bash "$repo_root/Scripts/validate-package.sh" \
  --payload-root "$payload" \
  --entitlements "$repo_root/Config/pomme.entitlements" \
  --runner "$runner" \
  --pkg "$pkg" \
  --tarball "$tarball"

assets=("$(basename "$pkg")" "$(basename "$tarball")")
# Release builds strip the executable, so its dSYM is the only way to
# symbolicate a crash report. Its UUID must match the executable's.
if [[ -d "$dsym" ]]; then
  binary_uuid="$(dwarfdump --uuid "$runner" | awk '{print $2}')"
  dsym_uuid="$(dwarfdump --uuid "$dsym" | awk '{print $2}')"
  [[ -n "$binary_uuid" && "$binary_uuid" == "$dsym_uuid" ]] ||
    fail "the dSYM's UUID ($dsym_uuid) doesn't match the executable's ($binary_uuid)."
  ditto -c -k --keepParent "$dsym" "$dsym_zip"
  assets+=("$(basename "$dsym_zip")")
elif [[ "$built_here" -eq 1 ]]; then
  fail "the Release build didn't produce a dSYM at $dsym."
else
  echo "warning: no dSYM at $dsym; the release won't include one." >&2
fi

(cd "$dist_dir" && shasum -a 256 "${assets[@]}" > SHA256SUMS)
for asset in "${assets[@]}"; do echo "Built $dist_dir/$asset"; done
