#!/usr/bin/env bash
# Set up the GitHub environments, secrets, and Homebrew deploy key that the
# Alpha and Release workflows use. Run it once, and again to rotate keys.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/configure-release-secrets.sh --p12 FILE [--repo OWNER/REPO] [--skip-homebrew] [--check-only]

Configures GitHub for .github/workflows/alpha.yml and release.yml:

1. Checks that FILE holds exactly two identities: Developer ID Application
   and Developer ID Installer for team 2D8XQ77EBQ.
2. Creates or updates two environments, each limited to the main branch:
     pomme-signing  holds the signing identities for alpha and stable builds.
     pomme-release  waits for your approval before a stable release publishes.
3. Stores FILE and its password as pomme-signing secrets.
4. Creates a deploy key with write access to weswhet/homebrew-tap, replacing
   an earlier one, and stores its private key as a pomme-release secret.

Scripts/export-signing-identities.swift exports both identities from the login
keychain and runs this script for you. To create FILE by hand instead, open
Keychain Access, select both Developer ID certificates under My Certificates
in the login keychain, choose File > Export Items, and save a .p12 file with a
password. Delete FILE when the script finishes.

The script reads the password from DEVELOPER_ID_CERTIFICATE_PASSWORD, or asks
for it. --check-only checks FILE and changes nothing on GitHub.
USAGE
}

fail() { echo "configure-release-secrets: $*" >&2; exit 65; }

repo="${GITHUB_REPOSITORY:-weswhet/pomme}"
tap_repo="weswhet/homebrew-tap"
p12_path=""
skip_homebrew=0
check_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--p12)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      if [[ "$1" == --repo ]]; then repo="$2"; else p12_path="$2"; fi
      shift 2 ;;
    --skip-homebrew) skip_homebrew=1; shift ;;
    --check-only) check_only=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unsupported argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
[[ -n "$p12_path" ]] || { usage >&2; exit 64; }
[[ -f "$p12_path" ]] || fail "p12 file not found: $p12_path"

readonly application_identity='Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)'
readonly installer_identity='Developer ID Installer: Wesley Whetstone (2D8XQ77EBQ)'
# macOS's LibreSSL reads the legacy encryption that Keychain exports use.
readonly openssl=/usr/bin/openssl

if [[ -z "${DEVELOPER_ID_CERTIFICATE_PASSWORD:-}" ]]; then
  [[ -t 0 ]] || fail 'set DEVELOPER_ID_CERTIFICATE_PASSWORD, or run the script in a terminal.'
  read -r -s -p "Password for $(basename "$p12_path"): " DEVELOPER_ID_CERTIFICATE_PASSWORD
  echo
fi
export DEVELOPER_ID_CERTIFICATE_PASSWORD

# Check what the p12 holds without printing any key material.
info="$("$openssl" pkcs12 -in "$p12_path" -info -noout -passin env:DEVELOPER_ID_CERTIFICATE_PASSWORD 2>&1)" ||
  fail "couldn't read $p12_path. Check the password."
key_count="$(grep -c 'Keybag' <<<"$info" || true)"
subjects="$("$openssl" pkcs12 -in "$p12_path" -nokeys -passin env:DEVELOPER_ID_CERTIFICATE_PASSWORD 2>/dev/null |
  sed -n 's#^subject=.*/CN=\([^/]*\).*#\1#p')"
has_application=0
has_installer=0
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  case "$name" in
    "$application_identity") has_application=1 ;;
    "$installer_identity") has_installer=1 ;;
    "Developer ID Certification Authority"|"Apple Root CA"*) ;;
    *) fail "$p12_path contains an unexpected certificate: $name. Export only the two Developer ID identities." ;;
  esac
done <<<"$subjects"
[[ "$has_application" -eq 1 ]] || fail "$p12_path doesn't contain $application_identity."
[[ "$has_installer" -eq 1 ]] || fail "$p12_path doesn't contain $installer_identity."
[[ "$key_count" -eq 2 ]] || fail "$p12_path contains $key_count private keys; it must contain exactly 2."
echo "Checked $p12_path: it contains the Developer ID Application and Installer identities."
[[ "$check_only" -eq 0 ]] || exit 0

for tool in gh base64 ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
gh auth status >/dev/null 2>&1 || fail 'sign in to GitHub first with: gh auth login'

# Limit an environment's deployments to the main branch.
restrict_to_main() {
  local environment="$1" policies id name
  policies="$(gh api "repos/$repo/environments/$environment/deployment-branch-policies" \
    --jq '.branch_policies[] | "\(.id) \(.type):\(.name)"')"
  while read -r id name; do
    [[ -n "$id" && "$name" != "branch:main" ]] || continue
    gh api -X DELETE "repos/$repo/environments/$environment/deployment-branch-policies/$id" >/dev/null
  done <<<"$policies"
  grep -q ' branch:main$' <<<"$policies" ||
    gh api -X POST "repos/$repo/environments/$environment/deployment-branch-policies" \
      -f name=main -f type=branch >/dev/null
}

user_id="$(gh api user --jq .id)"
gh api -X PUT "repos/$repo/environments/pomme-signing" --input - >/dev/null <<JSON
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
restrict_to_main pomme-signing
echo "Configured the pomme-signing environment (main branch only)."
gh api -X PUT "repos/$repo/environments/pomme-release" --input - >/dev/null <<JSON
{
  "reviewers": [{"type": "User", "id": $user_id}],
  "prevent_self_review": false,
  "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}
}
JSON
restrict_to_main pomme-release
echo "Configured the pomme-release environment (main branch only, your approval required)."

base64 < "$p12_path" | gh secret set DEVELOPER_ID_CERTIFICATE_BASE64 --env pomme-signing --repo "$repo"
printf '%s' "$DEVELOPER_ID_CERTIFICATE_PASSWORD" |
  gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD --env pomme-signing --repo "$repo"

if [[ "$skip_homebrew" -eq 0 ]]; then
  title="pomme release workflow"
  key_dir="$(mktemp -d "${TMPDIR:-/tmp}/pomme-tap-key.XXXXXX")"
  trap 'rm -rf "$key_dir"' EXIT
  ssh-keygen -q -t ed25519 -N '' -C "$title" -f "$key_dir/key"
  while read -r id; do
    [[ -n "$id" ]] || continue
    gh api -X DELETE "repos/$tap_repo/keys/$id" >/dev/null
  done < <(gh api "repos/$tap_repo/keys" --jq ".[] | select(.title == \"$title\") | .id")
  gh api -X POST "repos/$tap_repo/keys" -f title="$title" -f key="$(cat "$key_dir/key.pub")" \
    -F read_only=false >/dev/null
  gh secret set HOMEBREW_TAP_DEPLOY_KEY --env pomme-release --repo "$repo" < "$key_dir/key"
  echo "Created a write deploy key on $tap_repo for stable releases."
else
  echo "Skipped the Homebrew deploy key; stable releases will fail at the Homebrew step."
fi
echo "Done. Delete $p12_path now."
