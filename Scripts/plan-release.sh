#!/usr/bin/env bash
# Decide the version, tag, and commit of an alpha or stable release. The
# Alpha and Release workflows run this and append its output to
# $GITHUB_OUTPUT. Tests/ReleaseScripts.sh covers it offline.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/plan-release.sh alpha --commit COMMIT [--force]
       Scripts/plan-release.sh stable --alpha TAG [--branch REF]

alpha   Plans the next alpha of MARKETING_VERSION at COMMIT. Prints publish,
        reason, version, tag, commit, and previous_tag. publish is false when
        an alpha already includes COMMIT, or when only documentation and
        tests changed since the previous alpha (unless --force).
stable  Plans the promotion of alpha TAG, which must be on REF (default
        HEAD). Prints version, tag, commit, alpha_tag, and previous_tag.
USAGE
}

fail() { echo "plan-release: $*" >&2; exit 65; }

semver='[0-9]+\.[0-9]+\.[0-9]+'

# The version that the next stable release will have, from the commit's
# Config/Shared.xcconfig.
marketing_version() {
  local value
  value="$(git show "$1:Config/Shared.xcconfig" | sed -n -E 's/^MARKETING_VERSION = ([^[:space:]]+)$/\1/p')"
  [[ "$value" =~ ^${semver}$ ]] || fail "MARKETING_VERSION at $1 isn't MAJOR.MINOR.PATCH: '$value'"
  printf '%s\n' "$value"
}

tag_exists() { git rev-parse -q --verify "refs/tags/$1" >/dev/null; }

# Paths that can't change the released executable or its packages.
is_release_neutral() {
  case "$1" in
    Website/*|Docs/*|Tests/*|.codex/*|.claude/*|*.md|LICENSE|.gitignore|.github/workflows/ci.yml) return 0 ;;
    *) return 1 ;;
  esac
}

plan_alpha() {
  local commit="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --commit) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; commit="$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) usage >&2; exit 64 ;;
    esac
  done
  [[ -n "$commit" ]] || { usage >&2; exit 64; }
  commit="$(git rev-parse -q --verify "$commit^{commit}")" || fail "unknown commit: $commit"

  local base
  base="$(marketing_version "$commit")"
  tag_exists "v$base" &&
    fail "Pomme $base is already released. Raise MARKETING_VERSION in Config/Shared.xcconfig to start the next version's alphas."

  local previous_tag=""
  previous_tag="$(git describe --tags --abbrev=0 --match 'v*-alpha.*' "$commit" 2>/dev/null)" || previous_tag=""

  local publish=true reason="" containing
  containing="$(git tag --contains "$commit" --list 'v*-alpha.*')"
  containing="${containing%%$'\n'*}"
  if [[ -n "$containing" ]]; then
    publish=false
    reason="$containing already includes $commit."
  elif [[ -n "$previous_tag" && "$force" -eq 0 ]]; then
    local path changed=0
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      is_release_neutral "$path" || { changed=1; break; }
    done < <(git diff --no-renames --name-only "$previous_tag" "$commit")
    if [[ "$changed" -eq 0 ]]; then
      publish=false
      reason="Only documentation or tests changed since $previous_tag."
    fi
  fi

  local number=0 tag n
  while IFS= read -r tag; do
    n="${tag#"v$base-alpha."}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if (( 10#$n > number )); then number=$((10#$n)); fi
  done < <(git tag --list "v$base-alpha.*")
  number=$((number + 1))

  [[ -n "$reason" ]] || reason="Publishing alpha $number of $base."
  printf 'publish=%s\n' "$publish"
  printf 'reason=%s\n' "$reason"
  printf 'version=%s\n' "$base-alpha.$number"
  printf 'tag=%s\n' "v$base-alpha.$number"
  printf 'commit=%s\n' "$commit"
  printf 'previous_tag=%s\n' "$previous_tag"
}

plan_stable() {
  local alpha_tag="" branch=HEAD
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --alpha) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; alpha_tag="$2"; shift 2 ;;
      --branch) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; branch="$2"; shift 2 ;;
      *) usage >&2; exit 64 ;;
    esac
  done
  [[ -n "$alpha_tag" ]] || { usage >&2; exit 64; }
  [[ "$alpha_tag" =~ ^v(${semver})-alpha\.[0-9]+$ ]] ||
    fail "'$alpha_tag' isn't an alpha tag, such as v0.1.0-alpha.3."
  local version="${BASH_REMATCH[1]}"
  tag_exists "$alpha_tag" || fail "alpha tag $alpha_tag doesn't exist."

  local commit
  commit="$(git rev-parse --verify "$alpha_tag^{commit}")"
  git merge-base --is-ancestor "$commit" "$branch" ||
    fail "$alpha_tag isn't on $branch."
  [[ "$(marketing_version "$commit")" == "$version" ]] ||
    fail "MARKETING_VERSION at $alpha_tag doesn't match $version."
  tag_exists "v$version" && fail "v$version already exists."

  local previous_tag=""
  previous_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*' "$commit" 2>/dev/null)" ||
    previous_tag=""

  printf 'version=%s\n' "$version"
  printf 'tag=%s\n' "v$version"
  printf 'commit=%s\n' "$commit"
  printf 'alpha_tag=%s\n' "$alpha_tag"
  printf 'previous_tag=%s\n' "$previous_tag"
}

[[ $# -ge 1 ]] || { usage >&2; exit 64; }
mode="$1"
shift
case "$mode" in
  alpha) plan_alpha "$@" ;;
  stable) plan_stable "$@" ;;
  --help|-h) usage ;;
  *) usage >&2; exit 64 ;;
esac
