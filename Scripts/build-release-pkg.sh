#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'Usage: Scripts/build-release-pkg.sh [--version <version>] [--dist-dir <dir>] [--products-dir <dir>] [--notarize]'
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${VERSION:-}"
dist_dir="${DIST_DIR:-$repo_root/dist}"
products_dir=""
notarize=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --dist-dir) dist_dir="$2"; shift 2 ;;
    --products-dir) products_dir="$2"; shift 2 ;;
    --notarize) notarize=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ -n "$version" ]] || version="$(git -C "$repo_root" describe --tags --always --dirty | sed 's/^v//')"
[[ "$version" != *[!A-Za-z0-9._-]* ]] || { echo "Invalid version: $version" >&2; exit 64; }
: "${DEVELOPER_ID_APPLICATION:?Developer ID Application signing is required}"

build_root="$repo_root/build/release-package"
derived="$build_root/DerivedData"
payload="$build_root/payload"
tar_root="$build_root/tarball"
mkdir -p "$dist_dir"
dist_dir="$(cd "$dist_dir" && pwd)"
rm -rf "$build_root"
mkdir -p "$build_root" "$payload/usr/local/bin" "$tar_root"

if [[ -z "$products_dir" ]]; then
  xcodebuild -project "$repo_root/pomme.xcodeproj" -scheme pomme -configuration Release \
    -arch arm64 -derivedDataPath "$derived" build
  products_dir="$derived/Build/Products/Release"
else
  products_dir="$(cd "$products_dir" && pwd)"
fi
runner="$products_dir/pomme"
[[ -x "$runner" ]]

/usr/bin/codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
  --identifier com.github.weswhet.pomme \
  --entitlements "$repo_root/Config/pomme.entitlements" "$runner"
/usr/bin/codesign --verify --strict --verbose=2 "$runner"

install -m 0755 "$runner" "$payload/usr/local/bin/pomme"
install -m 0755 "$runner" "$tar_root/pomme"
pkg="$dist_dir/pomme-$version-arm64.pkg"
tarball="$dist_dir/pomme-$version-arm64.tar.gz"
unsigned="$build_root/pomme.pkg"

bash "$repo_root/Scripts/validate-package.sh" \
  --payload-root "$payload" \
  --entitlements "$repo_root/Config/pomme.entitlements" \
  --runner "$runner"
COPYFILE_DISABLE=1 tar -C "$tar_root" -czf "$tarball" pomme
pkgbuild --root "$payload" --identifier com.github.weswhet.pomme --version "$version" \
  --install-location / --scripts "$repo_root/Scripts/package" "$unsigned"
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
  productsign --timestamp --sign "$DEVELOPER_ID_INSTALLER" "$unsigned" "$pkg"
else
  mv "$unsigned" "$pkg"
fi

bash "$repo_root/Scripts/validate-package.sh" \
  --payload-root "$payload" \
  --entitlements "$repo_root/Config/pomme.entitlements" \
  --runner "$runner" \
  --pkg "$pkg" \
  --tarball "$tarball"

notarized=0
if [[ "$notarize" -eq 1 ]]; then
  if [[ -n "${APPLE_API_PRIVATE_KEY_PATH:-}" && -f "${APPLE_API_PRIVATE_KEY_PATH:-}" \
        && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]; then
    if xcrun notarytool submit "$pkg" --key "$APPLE_API_PRIVATE_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --wait \
        && xcrun stapler staple "$pkg"; then
      notarized=1
    else
      echo "WARNING: notarization failed; publishing signed-but-unnotarized artifacts." >&2
    fi
  else
    echo "WARNING: notarization credentials are unavailable; publishing signed-but-unnotarized artifacts." >&2
  fi
fi
if [[ "$notarized" -eq 0 ]]; then
  mv "$pkg" "$dist_dir/pomme-$version-arm64-signed-unnotarized.pkg"
  mv "$tarball" "$dist_dir/pomme-$version-arm64-signed-unnotarized.tar.gz"
  pkg="$dist_dir/pomme-$version-arm64-signed-unnotarized.pkg"
  tarball="$dist_dir/pomme-$version-arm64-signed-unnotarized.tar.gz"
fi
(cd "$dist_dir" && shasum -a 256 "$(basename "$pkg")" "$(basename "$tarball")" > SHA256SUMS)
echo "Built $pkg"
echo "Built $tarball"
