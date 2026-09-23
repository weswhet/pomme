#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/Scripts/build-local.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/pomme-local-build-test.XXXXXX")"
work="$(rtk proxy realpath "$work")"
old_path="$PATH"
mock_bin="$work/bin"
derived="$work/derived"
install_dir="$work/install"
destination="$install_dir/pomme"
export POMME_APP_SUPPORT_DIR="$work/app-support"

cleanup() {
  local path
  [[ -d "$work" ]] || return 0
  while IFS= read -r -d '' path; do rm -f -- "$path"; done < <(find "$work" -type f -print0)
  while IFS= read -r -d '' path; do rm -f -- "$path"; done < <(find "$work" -type l -print0)
  while IFS= read -r -d '' path; do rmdir "$path" 2>/dev/null || true; done < <(find "$work" -depth -type d -print0)
}
trap cleanup EXIT

mkdir -p "$mock_bin"

cat > "$mock_bin/xcrun" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && "$1" == --find && "$2" == xcodebuild ]] || exit 2
[[ "${MOCK_XCODE_DISCOVERY_FAILURE:-0}" != 1 ]] || exit 1
printf '%s/xcodebuild\n' "${BASH_SOURCE[0]%/*}"
MOCK

cat > "$mock_bin/xcodebuild" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

has() { local wanted="$1" arg; shift; for arg in "$@"; do [[ "$arg" == "$wanted" ]] && return 0; done; return 1; }
pair() { local key="$1" value="$2"; shift 2; while [[ $# -ge 2 ]]; do [[ "$1" == "$key" && "$2" == "$value" ]] && return 0; shift; done; return 1; }
for required in build 'CODE_SIGN_IDENTITY=Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)' \
  'DEVELOPMENT_TEAM=2D8XQ77EBQ' 'CODE_SIGN_STYLE=Manual' 'CODE_SIGNING_ALLOWED=YES' \
  'CODE_SIGNING_REQUIRED=YES' 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO' \
  'ENABLE_HARDENED_RUNTIME=YES' \
  'OTHER_CODE_SIGN_FLAGS=--identifier com.github.weswhet.pomme --timestamp'; do
  has "$required" "$@" || { echo "missing native build argument: $required" >&2; exit 2; }
done
pair -project "$MOCK_REPO_ROOT/pomme.xcodeproj" "$@" &&
  pair -scheme pomme "$@" && pair -configuration Release "$@" &&
  pair -arch arm64 "$@" && pair -sdk macosx "$@" || exit 2
commit_found=0
for arg in "$@"; do
  [[ "$arg" != CODE_SIGN_ENTITLEMENTS=* ]] || exit 2
  if [[ "$arg" == POMME_GIT_COMMIT=?* ]]; then commit_found=1; fi
done
[[ "$commit_found" == 1 ]] || exit 2

if [[ "${MOCK_BUILD_FAILURE:-0}" == 1 ]]; then
  echo 'mock build failure' >&2
  exit 1
fi

derived=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -derivedDataPath ]]; then
    [[ $# -ge 2 ]] || exit 2
    derived="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$derived" ]] || { echo 'mock build did not receive -derivedDataPath' >&2; exit 2; }
runner="$derived/Build/Products/Release/pomme"
mkdir -p "${runner%/*}"
printf '%s' "${MOCK_PRODUCT_CONTENT:-built}" > "$runner"
chmod 0755 "$runner"
MOCK

cat > "$mock_bin/codesign" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

has() { local wanted="$1" arg; shift; for arg in "$@"; do [[ "$arg" == "$wanted" ]] && return 0; done; return 1; }
target="${!#}"
base_requirement='anchor apple generic and identifier "com.github.weswhet.pomme" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2D8XQ77EBQ"'

if has --verify "$@"; then
  for arg in "$@"; do
    if [[ "$arg" == --test-requirement=* && "${arg#--test-requirement=}" != "=$base_requirement" ]]; then
      echo 'mock saw an unexpected test requirement' >&2
      exit 2
    fi
  done
  if [[ "${MOCK_CODESIGN_VERIFY_FAILURE:-0}" == 1 ]]; then
    echo 'mock signature verification failure' >&2
    exit 1
  fi
  exit 0
fi

if has --verbose=4 "$@"; then
  printf 'Executable=%s\n' "$target"
  printf 'Identifier=com.github.weswhet.pomme\n'
  printf 'Format=Mach-O thin\n'
  printf 'CodeDirectory flags=0x10000(runtime)\n'
  printf 'Authority=Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)\n'
  printf 'Authority=Developer ID Certification Authority\n'
  printf 'Authority=Apple Root CA\n'
  printf 'Timestamp=Sep 4, 2026 at 12:00:00 PM\n'
  printf 'TeamIdentifier=2D8XQ77EBQ\n'
fi

if has --entitlements "$@"; then
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
XML
fi

if has --requirements "$@"; then
  requirement="$base_requirement"
  if [[ -n "${MOCK_DERIVED_DATA_PATH:-}" && "$target" == "$MOCK_DERIVED_DATA_PATH/"* ]]; then
    requirement="${MOCK_NEW_REQUIREMENT:-$base_requirement}"
  fi
  printf 'designated => %s\n' "$requirement"
fi
MOCK

chmod 0755 "$mock_bin/xcrun" "$mock_bin/xcodebuild" "$mock_bin/codesign"
export PATH="$mock_bin:$old_path"
export MOCK_REPO_ROOT="$repo_root"
export MOCK_DERIVED_DATA_PATH="$derived"

checks=0
failures=0
pass() { checks=$((checks + 1)); printf 'ok %d - %s\n' "$checks" "$1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf 'not ok %d - %s\n' "$checks" "$1" >&2; }

expect_success() {
  local label="$1"
  shift
  if "$@" >"$work/stdout" 2>"$work/stderr"; then pass "$label"; else fail "$label"; sed -n '1,80p' "$work/stderr" >&2; fi
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$work/stdout" 2>"$work/stderr"; then fail "$label"; else pass "$label"; fi
}

assert_bytes() {
  local label="$1" path="$2" expected="$3" actual=''
  if [[ -f "$path" && ! -L "$path" ]]; then actual="$(<"$path")"; fi
  if [[ "$actual" == "$expected" ]]; then pass "$label"; else fail "$label (unexpected installed bytes)"; fi
}

expect_success 'help succeeds' bash "$script" --help
expect_failure 'invalid flag fails' bash "$script" --not-a-real-option

export MOCK_PRODUCT_CONTENT=first
unset MOCK_BUILD_FAILURE MOCK_CODESIGN_VERIFY_FAILURE MOCK_NEW_REQUIREMENT MOCK_XCODE_DISCOVERY_FAILURE
expect_success 'explicit paths install a signed build' bash "$script" --derived-data-path "$derived" --install-dir "$install_dir"
assert_bytes 'initial install has first build' "$destination" first
first_digest="$(rtk proxy sh -c 'printf %s "$1" | shasum -a 256 | awk "{print \$1}"' sh first)"
first_artifact="$work/app-support/AgentArtifacts/sha256/$first_digest/pomme-agent"
if [[ -f "$first_artifact" && ! -L "$first_artifact" ]]; then
  pass 'initial build archives the new Pomme agent'
else
  fail 'initial build archives the new Pomme agent'
fi

export MOCK_PRODUCT_CONTENT=second
expect_success 'compatible build replaces the installed CLI' bash "$script" --derived-data-path "$derived" --install-dir "$install_dir"
assert_bytes 'replacement has second build' "$destination" second
export MOCK_XCODE_DISCOVERY_FAILURE=1
expect_failure 'missing native Xcode tool is reported' bash "$script" --derived-data-path "$derived" --install-dir "$install_dir"
unset MOCK_XCODE_DISCOVERY_FAILURE
assert_bytes 'Xcode discovery failure preserves installed bytes' "$destination" second
second_digest="$(rtk proxy sh -c 'printf %s "$1" | shasum -a 256 | awk "{print \$1}"' sh second)"
second_artifact="$work/app-support/AgentArtifacts/sha256/$second_digest/pomme-agent"
if [[ -f "$second_artifact" && ! -L "$second_artifact" ]]; then
  pass 'replacement archives the new Pomme agent'
else
  fail 'replacement archives the new Pomme agent'
fi
expect_success 'archiving an existing digest reuses it' bash "$repo_root/Scripts/archive-agent.sh" \
  --source "$destination" --store-root "$work/app-support"
expect_failure 'a mismatched expected digest is rejected' bash "$repo_root/Scripts/archive-agent.sh" \
  --source "$destination" --store-root "$work/app-support" --expected-sha256 "$first_digest"

rtk proxy chmod 0775 "$destination"
expect_failure 'group-writable source is rejected' bash "$repo_root/Scripts/archive-agent.sh" \
  --source "$destination" --store-root "$work/app-support"
rtk proxy chmod 0707 "$destination"
expect_failure 'world-writable source is rejected' bash "$repo_root/Scripts/archive-agent.sh" \
  --source "$destination" --store-root "$work/app-support"
rtk proxy chmod 0755 "$destination"

rtk proxy chmod 0755 "$second_artifact"
rtk proxy sh -c 'printf %s corrupt > "$1"' sh "$second_artifact"
expect_failure 'a corrupt existing digest is never overwritten' bash "$repo_root/Scripts/archive-agent.sh" \
  --source "$destination" --store-root "$work/app-support"
assert_bytes 'corrupt archive remains unchanged' "$second_artifact" corrupt

export MOCK_PRODUCT_CONTENT=failed-build
export MOCK_BUILD_FAILURE=1
expect_failure 'build failure is reported' bash "$script" --derived-data-path "$derived" --install-dir "$install_dir"
unset MOCK_BUILD_FAILURE
assert_bytes 'build failure preserves installed bytes' "$destination" second

export MOCK_PRODUCT_CONTENT=bad-signature
export MOCK_CODESIGN_VERIFY_FAILURE=1
expect_failure 'signature validation failure is reported' bash "$script" --derived-data-path "$derived" --install-dir "$install_dir"
unset MOCK_CODESIGN_VERIFY_FAILURE
assert_bytes 'signature failure preserves installed bytes' "$destination" second

export MOCK_PRODUCT_CONTENT=changed-requirement
export MOCK_NEW_REQUIREMENT='anchor apple generic and identifier "com.github.weswhet.pomme.changed"'
expect_failure 'changed designated requirement blocks replacement' bash "$script" --derived-data-path "$derived" --install-dir "$install_dir"
unset MOCK_NEW_REQUIREMENT
assert_bytes 'requirement mismatch preserves installed bytes' "$destination" second

symlink_target="$work/symlink-target"
symlink_install="$work/symlink-install"
mkdir -p "$symlink_install"
printf '%s' protected > "$symlink_target"
ln -s "$symlink_target" "$symlink_install/pomme"
expect_failure 'symlink install destination is rejected' bash "$script" --install-dir "$symlink_install"

if [[ $failures -ne 0 ]]; then
  printf '%d of %d local build/install checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf 'all %d local build/install checks passed\n' "$checks"
