#!/usr/bin/env bash
set -euo pipefail

# The host installer intentionally has one payload path. The guest service
# uses a separate, source-owned runtime contract and is never installed by the
# host package; keeping the identities here makes accidental extra aliases
# visible during release validation.
readonly PACKAGE_BINARY_PATH="/usr/local/bin/pomme"
readonly GUEST_SERVICE_PATH="/usr/local/libexec/pomme"
readonly LAUNCHD_LABEL="com.github.weswhet.pomme.agent"
readonly PRIVATE_STATE_PATH="/private/var/db/pomme/agent.token"
readonly BUNDLE_IDENTIFIER="com.github.weswhet.pomme"
readonly VIRTUALIZATION_ENTITLEMENT="com.apple.security.virtualization"

usage() {
  cat <<'USAGE'
Usage: Scripts/validate-package.sh --payload-root <dir> [options]

Validates the Pomme package payload and release artifacts.

Options:
  --payload-root <dir>   Staged pkg root; must contain only /usr/local/bin/pomme
  --entitlements <file>  Entitlements plist to inspect (default: Config/pomme.entitlements)
  --runner <file>        Signed runner whose entitlements must include Virtualization
  --pkg <file>           Built pkg whose payload paths must be inspected
  --tarball <file>       Built tarball whose entries must contain only pomme
  --help                 Show this help
USAGE
}

fail() {
  echo "Package validation failed: $*" >&2
  exit 70
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
payload_root=""
entitlements="$repo_root/Config/pomme.entitlements"
runner=""
pkg=""
tarball=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --payload-root)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      payload_root="$2"
      shift 2
      ;;
    --entitlements)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      entitlements="$2"
      shift 2
      ;;
    --runner)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      runner="$2"
      shift 2
      ;;
    --pkg)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      pkg="$2"
      shift 2
      ;;
    --tarball)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      tarball="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unsupported argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

[[ -n "$payload_root" ]] || { usage >&2; exit 64; }
[[ -d "$payload_root" ]] || fail "payload root is not a directory: $payload_root"
[[ -f "$entitlements" ]] || fail "entitlements plist is missing: $entitlements"

payload_root="$(cd "$payload_root" && pwd)"
expected_payload_binary="$payload_root$PACKAGE_BINARY_PATH"

validate_entitlements_file() {
  local plist="$1"
  local value=""

  if [[ -x /usr/libexec/PlistBuddy ]]; then
    value="$(/usr/libexec/PlistBuddy -c "Print :$VIRTUALIZATION_ENTITLEMENT" "$plist" 2>/dev/null || true)"
    [[ "$value" == "true" ]] || fail "$plist does not grant $VIRTUALIZATION_ENTITLEMENT"
  else
    value="$(awk '
      /<key>com\.apple\.security\.virtualization<\/key>/ {
        if (getline nextLine > 0 && nextLine ~ /<true[[:space:]]*\/>/) { print "true" }
      }
    ' "$plist")"
    [[ "$value" == "true" ]] || fail "$plist does not grant $VIRTUALIZATION_ENTITLEMENT"
  fi
}

validate_payload_root() {
  local path
  local found=0

  [[ -f "$expected_payload_binary" ]] || fail "missing payload binary: $PACKAGE_BINARY_PATH"
  [[ ! -L "$expected_payload_binary" ]] || fail "payload binary must be a regular file: $PACKAGE_BINARY_PATH"
  [[ -x "$expected_payload_binary" ]] || fail "payload binary is not executable: $PACKAGE_BINARY_PATH"

  while IFS= read -r -d '' path; do
    [[ "$path" == "$payload_root" ]] && continue
    case "$path" in
      "$payload_root/usr"|"$payload_root/usr/local"|"$payload_root/usr/local/bin")
        ;;
      "$expected_payload_binary")
        found=1
        ;;
      *)
        fail "unexpected payload path: ${path#"$payload_root"} (only $PACKAGE_BINARY_PATH is allowed)"
        ;;
    esac
  done < <(find "$payload_root" -print0)

  [[ "$found" -eq 1 ]] || fail "payload does not contain $PACKAGE_BINARY_PATH"
}

validate_signed_runner() {
  local signed_entitlements
  local forbidden

  [[ -x "$runner" ]] || fail "signed runner is missing or not executable: $runner"
  command -v codesign >/dev/null 2>&1 || fail "codesign is required to validate signed runner entitlements"
  signed_entitlements="$(codesign -d --entitlements :- "$runner" 2>/dev/null)" || \
    fail "could not inspect signed runner entitlements: $runner"
  grep -Fq "$VIRTUALIZATION_ENTITLEMENT" <<<"$signed_entitlements" || \
    fail "signed runner is missing $VIRTUALIZATION_ENTITLEMENT"
  for forbidden in \
    com.apple.private.managedclient.DMCEnrollment \
    com.apple.private.managedclient.configurationprofiles \
    com.apple.private.managedclient.mdmclient-private; do
    ! grep -Fq "$forbidden" <<<"$signed_entitlements" || \
      fail "host runner unexpectedly carries guest-only entitlement: $forbidden"
  done
}

validate_pkg_payload() {
  local path
  local normalized
  local leaf
  local target
  local found=0
  local payload_files

  [[ -f "$pkg" ]] || fail "pkg artifact is missing: $pkg"
  command -v pkgutil >/dev/null 2>&1 || fail "pkgutil is required to inspect pkg payload: $pkg"
  payload_files="$(pkgutil --payload-files "$pkg" 2>/dev/null)" || \
    fail "could not inspect pkg payload: $pkg"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    normalized="${path#./}"
    normalized="${normalized%/}"
    # pkgutil includes the archive root and the binary's parent directories.
    [[ -z "$normalized" || "$normalized" == "." ]] && continue
    leaf="${normalized##*/}"
    if [[ "$leaf" == ._* ]]; then
      # AppleDouble entries describe a sibling's extended attributes. Permit
      # metadata only for the same paths permitted as ordinary payload entries.
      target="${leaf#._}"
      if [[ "$normalized" == */* ]]; then
        target="${normalized%/*}/$target"
      fi
      case "$target" in
        usr|usr/local|usr/local/bin|usr/local/bin/pomme) continue ;;
        *) fail "unexpected pkg payload metadata: $path (only $PACKAGE_BINARY_PATH is allowed)" ;;
      esac
    fi
    case "$normalized" in
      usr|usr/local|usr/local/bin) ;;
      usr/local/bin/pomme) found=1 ;;
      *) fail "unexpected pkg payload path: $path (only $PACKAGE_BINARY_PATH is allowed)" ;;
    esac
  done <<<"$payload_files"
  [[ "$found" -eq 1 ]] || fail "pkg payload does not contain $PACKAGE_BINARY_PATH"
}

validate_tarball() {
  local entry
  local normalized
  local found=0

  [[ -f "$tarball" ]] || fail "tarball artifact is missing: $tarball"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    normalized="${entry#./}"
    case "$normalized" in
      pomme)
        found=1
        ;;
      *)
        fail "unexpected tarball entry: $entry (only pomme is allowed)"
        ;;
    esac
  done < <(tar -tzf "$tarball")
  [[ "$found" -eq 1 ]] || fail "tarball does not contain the pomme executable"
}

validate_entitlements_file "$entitlements"
validate_payload_root
[[ -z "$runner" ]] || validate_signed_runner
[[ -z "$pkg" ]] || validate_pkg_payload
[[ -z "$tarball" ]] || validate_tarball

echo "Validated Pomme package identity ($BUNDLE_IDENTIFIER): $PACKAGE_BINARY_PATH"
echo "Runtime contract: $GUEST_SERVICE_PATH, $LAUNCHD_LABEL, $PRIVATE_STATE_PATH"
