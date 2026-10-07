#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

old_product="tid""dly"
old_wire="q""ga"
old_agent="fall""back[-_]?agent|fall""backAgent|Fall""backAgent|fall""back[-_]?only|fall""backOnly|Fall""backOnly"
old_guest_ids="apple[-_]?guest|apple[-_]?vsock|native[-_]?${old_wire}"
old_provisioning="fresh""[-_ ]?lab|fresh""Lab|Fresh""Lab"
old_vm_ingest="Imp""ort(Command|edBundle|Clone)|imp""ort(VM|Bundle)|commandName:[[:space:]]*\"imp""ort\""
retired_port="$((505000 + 50))"
retired_port_grouped="505[_ ]?0${retired_port: -2}"
content_pattern="${old_product}|${old_wire}|${old_agent}|${old_guest_ids}|${old_provisioning}|${old_vm_ingest}|${retired_port}|${retired_port_grouped}"

# The apple variety Pomme is named after shares a word with the old product
# name, so that exact name is allowed; any other use is still reported.
apple_name="Tid""dly Pomme"

# Prints tracked content that matches a retired pattern. The generated
# lockfile and lines made only of base64, such as certificate data, are
# skipped, because random base64 can spell a retired token by chance.
retired_matches() {
  git grep -I -n -i -E "$content_pattern" "$@" -- . ':(exclude)Website/package-lock.json' \
    | grep -v -E '^([^:]+:){2,3}[[:space:]]*[A-Za-z0-9+/=]{40,}\\?$' \
    | sed "s/${apple_name}//g" \
    | grep -i -E "$content_pattern" || true
}

status=0

if git ls-files | grep -E -i "$content_pattern"; then
  echo "retired identifier found in a tracked filename" >&2
  status=1
fi

matches="$(retired_matches)"
if [[ -n "$matches" ]]; then
  printf '%s\n' "$matches"
  echo "retired identifier found in tracked content" >&2
  status=1
fi

if [[ "${1:-}" == "--history" ]]; then
  commit_count="$(git rev-list --all --count)"
  if [[ "$commit_count" != "1" ]]; then
    echo "expected one reachable root commit, found $commit_count" >&2
    status=1
  fi

  if git rev-list --objects --all | grep -E -i "$content_pattern"; then
    echo "retired identifier found in a reachable object path" >&2
    status=1
  fi

  while IFS= read -r commit; do
    matches="$(retired_matches "$commit")"
    if [[ -n "$matches" ]]; then
      printf '%s\n' "$matches"
      echo "retired identifier found in reachable commit $commit" >&2
      status=1
    fi
  done < <(git rev-list --all)
fi

if [[ $status -ne 0 ]]; then
  exit "$status"
fi

echo "Pomme identifier audit passed"
