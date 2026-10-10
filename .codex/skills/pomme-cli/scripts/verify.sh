#!/usr/bin/env bash
# Run Pomme verification in the order AGENTS.md requires: signed build and
# install, runner gate, unit tests, then CLI integration tests. Stops at the
# first failure and prints the tail of that step's log.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: verify.sh [--skip-unit] [--skip-integration] [--gate-only] [--dry-run]

Steps, in order (stop at the first failure):
  1. build        bash Scripts/build-local.sh (signed Release; installs ~/.local/bin/pomme)
  2. gate         a fresh login shell resolves `pomme` to the runner, and
                  `pomme --version` reports the repository's HEAD commit
  3. unit         xcodebuild test (Release, signing disabled)
  4. integration  bash Tests/PommeCLIIntegrationTests.sh --runner RUNNER --no-build

Options:
  --skip-unit         Skip step 3.
  --skip-integration  Skip step 4.
  --gate-only         Run only step 2 (read-only check of the installed runner).
  --dry-run           Print the steps without running them.
  -h, --help          Show this help.

The build step is never skippable before tests: every test must use the freshly
signed runner. No step starts, stops, or changes a VM.

Environment: POMME_RUNNER (default ~/.local/bin/pomme), POMME_VERIFY_LOG_DIR
(default: a new directory under $TMPDIR).
Exit: 0 all run steps passed, 1 a step failed, 2 usage error.
USAGE
}

skip_unit=false
skip_integration=false
gate_only=false
dry_run=false
while [ $# -gt 0 ]; do
  case $1 in
    --skip-unit) skip_unit=true ;;
    --skip-integration) skip_integration=true ;;
    --gate-only) gate_only=true ;;
    --dry-run) dry_run=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || { echo "not inside the Pomme repository" >&2; exit 2; }
[ -d "$repo/pomme.xcodeproj" ] || { echo "pomme.xcodeproj not found under $repo" >&2; exit 2; }
cd "$repo"

runner=${POMME_RUNNER:-$HOME/.local/bin/pomme}
log_dir=${POMME_VERIFY_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/pomme-verify.XXXXXX")}
mkdir -p "$log_dir"

gate() {
  local resolved version commit head
  resolved=$(zsh -lc 'command -v pomme' 2>/dev/null || true)
  if [ "$resolved" != "$runner" ]; then
    echo "a fresh login shell resolves pomme to '${resolved:-nothing}', not $runner"
    return 1
  fi
  version=$("$runner" --version)
  echo "runner: $runner"
  echo "version: $version"
  commit=$(sed -n 's/.*(\([0-9a-f]\{7,\}\)\(-dirty\)\{0,1\}).*/\1/p' <<<"$version")
  [ -n "$commit" ] || { echo "could not read a commit from: $version"; return 1; }
  head=$(git rev-parse HEAD)
  if [ "$(git rev-parse --verify --quiet "$commit^{commit}" || true)" != "$head" ]; then
    echo "runner was built from $commit, but HEAD is $(git rev-parse --short HEAD); rebuild with Scripts/build-local.sh"
    return 1
  fi
  echo "runner matches HEAD $(git rev-parse --short HEAD)"
}

steps=()
if $gate_only; then
  steps=(gate)
else
  steps=(build gate)
  $skip_unit || steps+=(unit)
  $skip_integration || steps+=(integration)
fi

describe() {
  case $1 in
    build) echo "bash Scripts/build-local.sh" ;;
    gate) echo "check login-shell resolution and --version of $runner against HEAD" ;;
    unit) echo "xcodebuild test -project pomme.xcodeproj -scheme pomme -configuration Release -destination platform=macOS CODE_SIGNING_ALLOWED=NO" ;;
    integration) echo "bash Tests/PommeCLIIntegrationTests.sh --runner $runner --no-build" ;;
  esac
}

if $dry_run; then
  for step in "${steps[@]}"; do
    printf '%-12s %s\n' "$step" "$(describe "$step")"
  done
  exit 0
fi

run_step() {
  case $1 in
    build) bash Scripts/build-local.sh ;;
    gate) gate ;;
    unit)
      xcodebuild test -project pomme.xcodeproj -scheme pomme -configuration Release \
        -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
      ;;
    integration) bash Tests/PommeCLIIntegrationTests.sh --runner "$runner" --no-build ;;
  esac
}

for step in "${steps[@]}"; do
  log="$log_dir/$step.log"
  start=$SECONDS
  if run_step "$step" >"$log" 2>&1; then
    printf 'ok    %-12s %4ss  %s\n' "$step" "$((SECONDS - start))" "$log"
  else
    printf 'FAIL  %-12s %4ss  %s\n' "$step" "$((SECONDS - start))" "$log"
    echo "--- last 40 lines of $step ---"
    tail -n 40 "$log"
    exit 1
  fi
done
echo "result: ${steps[*]} passed"
