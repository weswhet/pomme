#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/configure-release-secrets.sh [--repo <owner/repo>] [--p12 <path>] [--skip-certificate]

Configures GitHub Actions secrets used by .github/workflows/release.yml.

By default, the script exports signing identities from the login keychain into
a temporary p12. That export may require macOS user approval, so run it from an
interactive local shell when private-key export is protected.

Environment:
  DEVELOPER_ID_CERTIFICATE_PASSWORD  Optional p12 password; generated if absent
  DEVELOPER_ID_KEYCHAIN_PASSWORD     Optional CI temp keychain password
  DEVELOPER_ID_APPLICATION           Defaults to Wesley Whetstone Developer ID Application
  DEVELOPER_ID_INSTALLER             Defaults to Wesley Whetstone Developer ID Installer
  HOMEBREW_TAP_TOKEN                 Optional; uploaded when set
USAGE
}

repo="${GITHUB_REPOSITORY:-weswhet/pomme}"
p12_path=""
skip_certificate=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      repo="$2"
      shift 2
      ;;
    --p12)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      p12_path="$2"
      shift 2
      ;;
    --skip-certificate)
      skip_certificate=1
      shift
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

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required tool not found: $1" >&2
    exit 69
  }
}

set_secret() {
  local name="$1"
  local value="$2"
  printf '%s' "$value" | gh secret set "$name" --repo "$repo" >/dev/null
  echo "Configured $name"
}

require_tool base64
require_tool gh
require_tool openssl
require_tool security

developer_id_application="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)}"
developer_id_installer="${DEVELOPER_ID_INSTALLER:-Developer ID Installer: Wesley Whetstone (2D8XQ77EBQ)}"

tmpdir=""
cleanup() {
  if [[ -n "$tmpdir" ]]; then
    rm -rf "$tmpdir"
  fi
}
trap cleanup EXIT

if [[ "$skip_certificate" -eq 0 ]]; then
  certificate_password="${DEVELOPER_ID_CERTIFICATE_PASSWORD:-$(openssl rand -base64 36 | tr -d '\n')}"
  if [[ -z "$p12_path" ]]; then
    tmpdir="$(mktemp -d /tmp/pomme-release-secrets.XXXXXX)"
    p12_path="$tmpdir/developer-id-identities.p12"
    security export -k login.keychain-db -t identities -f pkcs12 -P "$certificate_password" -o "$p12_path" >/dev/null
  fi
  [[ -f "$p12_path" ]] || {
    echo "p12 not found: $p12_path" >&2
    exit 66
  }
  base64 < "$p12_path" | gh secret set DEVELOPER_ID_CERTIFICATE_BASE64 --repo "$repo" >/dev/null
  echo "Configured DEVELOPER_ID_CERTIFICATE_BASE64"
  set_secret DEVELOPER_ID_CERTIFICATE_PASSWORD "$certificate_password"
  set_secret DEVELOPER_ID_KEYCHAIN_PASSWORD "${DEVELOPER_ID_KEYCHAIN_PASSWORD:-$(openssl rand -base64 36 | tr -d '\n')}"
fi

set_secret DEVELOPER_ID_APPLICATION "$developer_id_application"
set_secret DEVELOPER_ID_INSTALLER "$developer_id_installer"

if [[ -n "${HOMEBREW_TAP_TOKEN:-}" ]]; then
  set_secret HOMEBREW_TAP_TOKEN "$HOMEBREW_TAP_TOKEN"
else
  echo "Skipped HOMEBREW_TAP_TOKEN; set HOMEBREW_TAP_TOKEN to let releases update weswhet/homebrew-tap."
fi
