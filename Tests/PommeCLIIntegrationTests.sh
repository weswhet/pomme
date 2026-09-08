#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner=""
build=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner)
      [[ $# -ge 2 ]] || { echo "--runner requires a path" >&2; exit 64; }
      runner="$2"
      shift 2
      ;;
    --no-build)
      build=0
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 64
      ;;
  esac
done

if [[ $build -eq 1 ]]; then
  rtk xcodebuildmcp macos build \
    --project-path "$repo_root/pomme.xcodeproj" \
    --scheme pomme \
    --configuration Release \
    --arch arm64 \
    --output text
  app_path_json="$(rtk xcodebuildmcp macos get-app-path \
    --project-path "$repo_root/pomme.xcodeproj" \
    --scheme pomme \
    --configuration Release \
    --arch arm64 \
    --output json)"
  runner="$(POMME_APP_PATH_JSON="$app_path_json" /usr/bin/python3 - <<'PY'
import json
import os

value = json.loads(os.environ["POMME_APP_PATH_JSON"])
print(value.get("appPath") or value.get("path") or value.get("executablePath") or "")
PY
)"
fi

[[ -n "$runner" && -x "$runner" ]] || {
  echo "Pomme runner is not executable: $runner" >&2
  exit 66
}

work="$(mktemp -d "${TMPDIR:-/tmp}/pomme-cli-contract.XXXXXX")"
cleanup() {
  local item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    rm -f -- "$item"
  done < <(find "$work" -mindepth 1 -maxdepth 1 -type f -print)
  rmdir "$work"
}
trap cleanup EXIT

export POMME_APP_SUPPORT_DIR="$work/app-support"

failures=0
checks=0

pass() {
  checks=$((checks + 1))
  printf 'ok %d - %s\n' "$checks" "$1"
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  printf 'not ok %d - %s\n' "$checks" "$1" >&2
}

expect_success() {
  local label="$1"
  shift
  if "$@" >"$work/stdout" 2>"$work/stderr"; then
    pass "$label"
  else
    fail "$label"
    sed -n '1,80p' "$work/stderr" >&2
  fi
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$work/stdout" 2>"$work/stderr"; then
    fail "$label"
  else
    pass "$label"
  fi
}

expect_success "root help" "$runner" --help
if grep -Eq '^USAGE: pomme' "$work/stdout" && grep -Eq 'agent' "$work/stdout"; then
  pass "help identifies Pomme and agent commands"
else
  fail "help identifies Pomme and agent commands"
fi

if ! grep -Eqi '(^|[[:space:]])vm[[:space:]]+import([[:space:]]|$)' "$work/stdout"; then
  pass "help omits external bundle ingestion"
else
  fail "help omits external bundle ingestion"
fi

expect_success "agent help" "$runner" agent --help
expect_failure "agent status requires target" "$runner" agent status
expect_failure "agent repair requires target" "$runner" agent repair
expect_failure "agent repair rejects unsupported final state" \
  "$runner" agent repair missing --final-state normal

expect_failure "create resume rejects restore options" \
  "$runner" create example --resume --version 26.6.0
expect_failure "create resume rejects boot options" \
  "$runner" create example --resume --boot normal

removed_ingest="im""port"
expect_failure "removed bundle-ingestion command is rejected" \
  "$runner" "$removed_ingest" "$work/missing.bundle"

removed_agent_flag="--fall""back-agent"
expect_failure "removed agent selector is rejected" \
  "$runner" remote-login enable missing "$removed_agent_flag"

removed_policy_flag="--fall""back-only"
expect_failure "removed policy selector is rejected" \
  "$runner" create example --version 26.6.0 "$removed_policy_flag"

expect_success "config help" "$runner" config --help
expect_success "IPSW help" "$runner" ipsw --help
expect_success "direct MDM help" "$runner" mdm --help
if grep -q -- '--enrollment-mode' "$work/stdout" && grep -q -- '--profile' "$work/stdout" \
  && ! grep -q 'SUBCOMMANDS:' "$work/stdout"; then
  pass "MDM exposes direct enrollment options"
else
  fail "MDM exposes direct enrollment options"
fi
expect_failure "MDM requires profile" "$runner" mdm missing
expect_failure "MDM rejects invalid mode" "$runner" mdm missing --profile missing --enrollment-mode invalid
expect_failure "MDM rejects removed enroll syntax" "$runner" mdm enroll missing --profile missing
expect_failure "MDM rejects removed approve syntax" "$runner" mdm approve missing --profile-identifier missing
expect_failure "MDM rejects removed acknowledgement" "$runner" mdm missing --profile missing --acknowledge-synthetic-approval
expect_failure "unknown root command is rejected" "$runner" definitely-not-a-command

if [[ $failures -ne 0 ]]; then
  printf '%d of %d contract checks failed\n' "$failures" "$checks" >&2
  exit 1
fi

printf 'all %d Pomme CLI contract checks passed\n' "$checks"
