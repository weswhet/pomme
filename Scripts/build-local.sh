#!/usr/bin/env bash
# Build, sign, verify, and atomically install the local credential-bearing CLI.
set -euo pipefail

usage() {
  echo 'Usage: Scripts/build-local.sh [--derived-data-path DIR] [--install-dir DIR]'
  echo 'Defaults: signed Release build; install to ~/.local/bin/pomme.'
}

fail() { echo "pomme local build: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$HOME/Library/Developer/XcodeBuildMCP/workspaces/pomme-local-signed/DerivedData"
install_dir="$HOME/.local/bin"
archive_script="$repo_root/Scripts/archive-agent.sh"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data-path|--install-dir)
      [[ $# -ge 2 && -n "$2" && "$2" == /* ]] || fail "$1 requires an absolute directory path."
      if [[ "$1" == --derived-data-path ]]; then derived_data="$2"; else install_dir="$2"; fi
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "Unknown option: $1" ;;
  esac
done

readonly signing_identity='Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)'
readonly team_id='2D8XQ77EBQ'
readonly identifier='com.github.weswhet.pomme'
readonly requirement='anchor apple generic and identifier "com.github.weswhet.pomme" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2D8XQ77EBQ"'
runner="$derived_data/Build/Products/Release/pomme"
destination="$install_dir/pomme"
[[ ! -L "$install_dir" && ! -L "$destination" ]] || fail 'Refusing a symlink install directory or destination.'
[[ ! -e "$destination" || -f "$destination" ]] || fail 'The install destination is not a regular file.'

for dependency in rtk xcodebuildmcp codesign plutil bash; do
  command -v "$dependency" >/dev/null || fail "Required tool is unavailable: $dependency"
done
[[ -x "$archive_script" ]] || fail 'The signed-agent archive script is unavailable.'

has_line() {
  local lines=$'\n'"$1"$'\n'
  [[ "$lines" == *$'\n'"$2"$'\n'* ]]
}

verify_signature() {
  local binary="$1" details entitlements
  rtk proxy codesign --verify --strict --verbose=2 --test-requirement="=$requirement" "$binary"
  details="$(rtk proxy codesign --display --verbose=4 "$binary" 2>&1)"
  has_line "$details" "Identifier=$identifier" || fail 'Unexpected code-signing identifier.'
  has_line "$details" "TeamIdentifier=$team_id" || fail 'Unexpected signing team.'
  has_line "$details" "Authority=$signing_identity" || fail 'Unexpected signing certificate.'
  [[ "$details" == *'runtime)'* ]] || fail 'Hardened Runtime is missing.'
  [[ "$details" == *$'\nTimestamp='* ]] || fail 'A secure signing timestamp is missing.'
  entitlements="$(rtk proxy codesign --display --entitlements - --xml "$binary" 2>/dev/null |
    rtk proxy plutil -convert json -o - -- -)"
  [[ "$entitlements" == '{"com.apple.security.virtualization":true}' ]] ||
    fail 'The signature must contain only the Virtualization entitlement.'
}

designated_requirement() {
  local output value
  output="$(rtk proxy codesign --display --requirements - "$1" 2>&1)"
  value="$(rtk proxy sed -n 's/^designated => //p' <<< "$output")"
  [[ -n "$value" ]] || fail 'The executable has no designated requirement.'
  printf '%s\n' "$value"
}

cd "$repo_root"
git_commit="$(git describe --always --dirty 2>/dev/null || echo unknown)"
# Xcode signs the target using its Release entitlement configuration. Do not
# apply a global entitlement path to Swift package dependency targets.
rtk proxy xcodebuildmcp macos build \
  --project-path "$repo_root/pomme.xcodeproj" \
  --scheme pomme --configuration Release --arch arm64 \
  --derived-data-path "$derived_data" \
  --extra-args \
    "CODE_SIGN_IDENTITY=$signing_identity" \
    "DEVELOPMENT_TEAM=$team_id" \
    'CODE_SIGN_STYLE=Manual' \
    'CODE_SIGNING_ALLOWED=YES' \
    'CODE_SIGNING_REQUIRED=YES' \
    'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO' \
    'ENABLE_HARDENED_RUNTIME=YES' \
    "OTHER_CODE_SIGN_FLAGS=--identifier $identifier --timestamp" \
    "POMME_GIT_COMMIT=$git_commit" \
  --verbose --output text

[[ -f "$runner" && -x "$runner" && ! -L "$runner" ]] || fail 'The build did not produce a regular executable.'
verify_signature "$runner"
new_requirement="$(designated_requirement "$runner")"
if [[ -e "$destination" ]]; then
  rtk proxy codesign --verify --strict "$destination"
  old_requirement="$(designated_requirement "$destination")"
  [[ "$new_requirement" == "$old_requirement" ]] ||
    fail 'The installed CLI has a different designated requirement; review Keychain compatibility before replacement.'
fi

# Keep both sides of an atomic install available for immutable provisioning
# plans.  The archive script performs its own signature, ownership, inode, and
# digest checks and never replaces an existing digest entry.
if [[ -e "$destination" ]]; then
  rtk proxy bash "$archive_script" --source "$destination"
fi
rtk proxy bash "$archive_script" --source "$runner"

rtk proxy mkdir -p "$install_dir"
staged="$(rtk proxy mktemp "$install_dir/.pomme-install.XXXXXX")"
cleanup() { if [[ -n "$staged" ]]; then rtk proxy rm -f -- "$staged"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rtk proxy install -m 0755 "$runner" "$staged"
rtk proxy cmp -s "$runner" "$staged" || fail 'The staged executable differs from the signed build.'
verify_signature "$staged"
rtk proxy mv -f "$staged" "$destination"
staged=''
rtk proxy codesign --verify --strict --verbose=2 "$destination"
echo "Installed signed Pomme: $destination"
case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) echo "Add $install_dir to your shell PATH before invoking pomme by name." ;;
esac
