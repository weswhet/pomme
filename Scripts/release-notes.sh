#!/usr/bin/env bash
# Write the GitHub release notes for an alpha or stable release to standard
# output. Tests/ReleaseScripts.sh covers it offline.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/release-notes.sh alpha --version VERSION --commit COMMIT [--previous-tag TAG]
       Scripts/release-notes.sh stable --version VERSION --commit COMMIT [--previous-tag TAG]
                                [--notes-file FILE]

alpha   Lists the commits since the previous alpha.
stable  Copies the "## Pomme VERSION" section of the site's release notes
        (default Website/src/content/docs/resources/release-notes.md). The
        heading must match exactly, so a "(pre-release)" heading fails.
USAGE
}

fail() { echo "release-notes: $*" >&2; exit 65; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="${GITHUB_REPOSITORY:-weswhet/pomme}"
site="https://pommevm.dev"
max_commits=50

[[ $# -ge 1 ]] || { usage >&2; exit 64; }
mode="$1"
shift
version=""
commit=""
previous_tag=""
notes_file="$repo_root/Website/src/content/docs/resources/release-notes.md"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|--commit|--previous-tag|--notes-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      case "$1" in
        --version) version="$2" ;;
        --commit) commit="$2" ;;
        --previous-tag) previous_tag="$2" ;;
        --notes-file) notes_file="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ "$mode" == alpha || "$mode" == stable ]] || { usage >&2; exit 64; }
[[ -n "$version" && -n "$commit" ]] || { usage >&2; exit 64; }
[[ "$version" != *[!A-Za-z0-9._-]* ]] || fail "invalid version: $version"
commit="$(git rev-parse -q --verify "$commit^{commit}")" || fail "unknown commit: $commit"
short="$(git rev-parse --short "$commit")"
tag="v$version"
download="https://github.com/$repo/releases/download/$tag"
tarball="pomme-$version-arm64.tar.gz"

# Converts the site's Markdown to GitHub's: root-relative links point at the
# site, and Starlight asides become GitHub alerts.
github_markdown() {
  awk -v site="$site" '
    /^:::(note|tip|caution|danger)[[:space:]]*$/ {
      kind = substr($0, 4)
      sub(/[[:space:]]+$/, "", kind)
      alert = (kind == "note") ? "NOTE" : (kind == "tip") ? "TIP" : (kind == "caution") ? "WARNING" : "CAUTION"
      print "> [!" alert "]"
      inside = 1
      next
    }
    inside && /^:::[[:space:]]*$/ { inside = 0; next }
    {
      line = $0
      gsub(/\]\(\//, "](" site "/", line)
      if (inside) { print (line == "" ? ">" : "> " line) } else { print line }
    }
  '
}

print_commits() {
  local range="$previous_tag..$commit" count
  count="$(git rev-list --count --no-merges "$range")"
  git log --no-merges --format="- %s ([\`%h\`](https://github.com/$repo/commit/%H))" \
    --max-count="$max_commits" "$range"
  if (( count > max_commits )); then
    echo "- And $((count - max_commits)) more. See the [full comparison](https://github.com/$repo/compare/$previous_tag...$tag)."
  fi
}

if [[ "$mode" == alpha ]]; then
  cat <<NOTES
An automatic alpha build of [\`$short\`](https://github.com/$repo/commit/$commit) on \`main\`.

> [!WARNING]
> Alpha builds aren't qualified for release. Commands, flags, output formats,
> and behavior can change or break from one build to the next.

NOTES
  if [[ -n "$previous_tag" ]]; then
    echo "### Changes since $previous_tag"
    echo
    print_commits
  else
    echo "This is the first alpha build."
  fi
else
  [[ -f "$notes_file" ]] || fail "release notes file is missing: $notes_file"
  heading="## Pomme $version"
  grep -qx "$heading" "$notes_file" ||
    fail "$notes_file has no '$heading' section. Finish the release notes, and remove any '(pre-release)' suffix from the heading."
  section="$(awk -v heading="$heading" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$notes_file" | github_markdown)"
  # Trim the blank lines that surround the section.
  section="$(printf '%s\n' "$section" | sed -e '/./,$!d')"
  printf '%s\n' "$section" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
  echo
  echo "For the complete notes and the documentation, see <$site/resources/release-notes/>."
  if [[ -n "$previous_tag" ]]; then
    echo
    echo "**Full changelog:** https://github.com/$repo/compare/$previous_tag...$tag"
  fi
fi

cat <<NOTES

### Install

NOTES
if [[ "$mode" == stable ]]; then
  cat <<NOTES
Install with [Homebrew](https://brew.sh):

\`\`\`sh
brew install weswhet/tap/pomme
\`\`\`

Or download the executable:

NOTES
fi
cat <<NOTES
\`\`\`sh
curl -fLO $download/$tarball
curl -fLO $download/SHA256SUMS
shasum -a 256 --check --ignore-missing SHA256SUMS
gh attestation verify $tarball --repo $repo
tar -xzf $tarball
mkdir -p ~/.local/bin
install -m 0755 pomme ~/.local/bin/pomme
\`\`\`

Download with \`curl\` or \`gh release download\`, not a web browser. Pomme is
signed with a Developer ID certificate but isn't notarized, so Gatekeeper blocks
a copy that a browser downloads.
NOTES
