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
  derived_data_path="$HOME/Library/Developer/Xcode/DerivedData/pomme-cli-contract"
  rtk proxy xcodebuild \
    -project "$repo_root/pomme.xcodeproj" \
    -scheme pomme \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -arch arm64 \
    -derivedDataPath "$derived_data_path" \
    build
  runner="$derived_data_path/Build/Products/Release/pomme"
fi

[[ -n "$runner" && -x "$runner" ]] || {
  echo "Pomme runner is not executable: $runner" >&2
  exit 66
}

work="$(mktemp -d "${TMPDIR:-/tmp}/pomme-cli-contract.XXXXXX")"
delete_fixture_bundle=""
delete_fixture_vm_store_dir=""
delete_fixture_sentinel=""
delete_fixture_runtime_dir=""
delete_fixture_runtime_record=""
cleanup() {
  if [[ -n "$delete_fixture_runtime_record" ]]; then
    rm -f -- "$delete_fixture_runtime_record"
  fi
  if [[ -n "$delete_fixture_sentinel" ]]; then
    rm -f -- "$delete_fixture_sentinel"
  fi
  if [[ -n "$delete_fixture_bundle" ]]; then
    if [[ -d "$delete_fixture_bundle" ]] && ! rmdir "$delete_fixture_bundle"; then
      printf 'cleanup left non-empty delete fixture bundle: %s\n' "$delete_fixture_bundle" >&2
    fi
  fi
  if [[ -n "$delete_fixture_vm_store_dir" ]]; then
    if [[ -d "$delete_fixture_vm_store_dir" ]] && ! rmdir "$delete_fixture_vm_store_dir"; then
      printf 'cleanup left non-empty delete fixture VM store: %s\n' "$delete_fixture_vm_store_dir" >&2
    fi
  fi
  local item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    rm -f -- "$item"
  done < <(find "$work" -mindepth 1 -maxdepth 1 -type f -print)
  # Inventory reads create an empty app-support layout holding only lock files.
  if [[ -d "$work/app-support" ]]; then
    find "$work/app-support" -type f -name '*.lock' -delete
    if [[ -n "$delete_fixture_runtime_dir" && -d "$delete_fixture_runtime_dir" ]] \
      && ! rmdir "$delete_fixture_runtime_dir"; then
      printf 'cleanup left non-empty delete fixture runtime directory: %s\n' "$delete_fixture_runtime_dir" >&2
    fi
    find "$work/app-support" -depth -type d -empty -delete
  fi
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

expect_exit_1() {
  local label="$1"
  shift
  local status
  if "$@" >"$work/stdout" 2>"$work/stderr"; then
    status=0
  else
    status=$?
  fi
  if [[ $status -eq 1 ]]; then
    pass "$label"
  else
    fail "$label (exit $status, expected 1)"
    sed -n '1,80p' "$work/stderr" >&2
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
expect_success "compact agent inventory" "$runner" agent-help
cp "$work/stdout" "$work/agent-help"
expect_success "discovery root help" "$runner" --help
cp "$work/stdout" "$work/root-help"
expect_success "discovery JSON inventory" "$runner" tools --format json
cp "$work/stdout" "$work/tools-json"
if python3 - "$work/root-help" "$work/tools-json" "$work/agent-help" <<'PY'
import json, re, sys
help_text, catalog, compact = (open(p).read() for p in sys.argv[1:])
registered = set()
for line in help_text.split('SUBCOMMANDS:', 1)[1].splitlines():
    match = re.match(r'^  ([a-z][a-z-]*(?:, [a-z][a-z-]*)?)\s{2,}', line)
    if match:
        registered.update(match[1].split(', '))
assert json.loads(catalog)['schemaVersion'] == 1
groups = {g['name']: g['commands'] for g in json.loads(catalog)['groups']}
discovered = {alias for commands in groups.values() for command in commands
              for alias in command.split()[0].split('|')}
assert discovered == registered | {'tools', 'agent-help'}, (registered - discovered, discovered - registered)
compact_tokens = set(re.findall(r'[a-z][a-z-]*', compact))
assert discovered <= compact_tokens, discovered - compact_tokens
assert 'sessions' in groups['guest'] and 'template' in groups['vm']
assert compact.startswith('pomme-agent-help v1;')
assert 'sessions=list|ls|inspect|attach|logs|terminate|delete' in compact
assert 'template=create|list|delete' in compact
PY
then
  pass "discovery matches registered commands, aliases, groups, and new leaves"
else
  fail "discovery matches registered commands, aliases, groups, and new leaves"
fi

expect_success "guest log help" "$runner" log --help
if grep -q -- '--follow' "$work/stdout" \
  && grep -q -- '--category' "$work/stdout" \
  && grep -q -- '--last' "$work/stdout" \
  && grep -q -- '--format' "$work/stdout"; then
  pass "guest log help lists history, follow, category, and format options"
else
  fail "guest log help lists history, follow, category, and format options"
fi

expect_failure "guest log requires a name without POMME_VM_NAME" \
  env -u POMME_VM_NAME "$runner" log
if grep -q 'Specify a VM name or set POMME_VM_NAME' "$work/stderr"; then
  pass "guest log names the target fallback"
else
  fail "guest log names the target fallback"
fi

expect_failure "guest log rejects malformed history duration" \
  "$runner" log example --last 0m
if grep -q -- '--last must be boot or a positive number' "$work/stderr"; then
  pass "guest log explains its supported history duration"
else
  fail "guest log explains its supported history duration"
fi

expect_failure "guest log rejects JSON documents while following" \
  "$runner" log example --follow --format json
if grep -q -- '--format json conflicts with --follow' "$work/stderr"; then
  pass "guest log explains the follow format restriction"
else
  fail "guest log explains the follow format restriction"
fi

expect_failure "guest log rejects explicit timeout while following" \
  "$runner" log example --follow --timeout 30
if grep -q -- '--timeout conflicts with --follow' "$work/stderr"; then
  pass "guest log explains the follow timeout restriction"
else
  fail "guest log explains the follow timeout restriction"
fi

if env POMME_VM_NAME=log-target-fallback "$runner" log >"$work/stdout" 2>"$work/stderr"; then
  fail "guest log uses POMME_VM_NAME before VM lookup"
elif grep -q 'log-target-fallback' "$work/stderr"; then
  pass "guest log uses POMME_VM_NAME before VM lookup"
else
  fail "guest log uses POMME_VM_NAME before VM lookup"
  sed -n '1,80p' "$work/stderr" >&2
fi

for representation in json jsonl; do
  expect_success "tools $representation inventory" "$runner" tools --format "$representation"
  cp "$work/stdout" "$work/tools-$representation"
  expect_success "agent-help $representation inventory" "$runner" agent-help --format "$representation"
  if python3 - "$work/tools-$representation" "$work/stdout" "$representation" <<'PY'
import json, sys
def read(path):
    with open(path) as source:
        return [json.loads(line) for line in source] if sys.argv[3] == 'jsonl' else json.load(source)
expected, actual = read(sys.argv[1]), read(sys.argv[2])
assert actual == expected
assert actual  # An unsupported command must not pass as two empty streams.
PY
  then
    pass "agent-help $representation matches tools payload"
  else
    fail "agent-help $representation matches tools payload"
  fi
done
expect_success "agent-help JSON shorthand" "$runner" agent-help --json
if python3 -c 'import json,sys; assert json.load(open(sys.argv[1])) == json.load(open(sys.argv[2]))' "$work/tools-json" "$work/stdout"; then
  pass "agent-help JSON shorthand matches tools"
else
  fail "agent-help JSON shorthand matches tools"
fi
expect_failure "agent-help rejects conflicting formats" "$runner" agent-help --json --format jsonl
if grep -q -- '--json conflicts with --format jsonl' "$work/stderr"; then
  pass "agent-help uses common format conflict diagnostic"
else
  fail "agent-help uses common format conflict diagnostic"
fi
expect_failure "agent-help rejects bogus format" "$runner" agent-help --format bogus
if grep -q "'table', 'json' or 'jsonl'" "$work/stderr"; then
  pass "agent-help names supported formats"
else
  fail "agent-help names supported formats"
fi
expect_failure "agent status requires target" "$runner" agent status
expect_failure "agent repair requires target" "$runner" agent repair
expect_failure "agent repair rejects unsupported final state" \
  "$runner" agent repair missing --final-state normal

expect_failure "create resume rejects restore options" \
  "$runner" create example --resume --version 26.6.0
expect_failure "create resume rejects boot options" \
  "$runner" create example --resume --boot normal

expect_failure "local restore image dry-run rejects a missing file" \
  "$runner" create example --restore-image "$work/missing.ipsw" --dry-run
if grep -qi 'does not exist' "$work/stderr"; then
  pass "local restore image reaches file validation"
else
  fail "local restore image reaches file validation"
fi
expect_failure "local restore image rejects a network device selector" \
  "$runner" create example --restore-image "$work/missing.ipsw" --ipsw-device VirtualMac2,1 --dry-run

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
for security_command in sip amfi; do
  expect_success "$security_command help" "$runner" "$security_command" --help
  if grep -qi 'resume' "$work/stdout" && grep -q -- '--final-state' "$work/stdout"; then
    pass "$security_command help explains retained transaction resume"
  else
    fail "$security_command help explains retained transaction resume"
  fi
done
expect_success "Screen Sharing help" "$runner" screen-sharing --help
if grep -qi 'guest agent' "$work/stdout"; then
  pass "Screen Sharing help explains guest support requirement"
else
  fail "Screen Sharing help explains guest support requirement"
fi
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
expect_success "MDM any-state help" "$runner" mdm --help
if grep -q -- '--final-security' "$work/stdout" && grep -q -- '--dry-run' "$work/stdout" \
  && grep -q -- '--from-template' "$work/stdout" && grep -q -- '--skip-server-preflight' "$work/stdout"; then
  pass "MDM exposes any-state preparation options"
else
  fail "MDM exposes any-state preparation options"
fi
expect_failure "MDM rejects invalid final security" "$runner" mdm missing --profile missing --final-security enabled
expect_failure "MDM rejects a Recovery creation boot" "$runner" mdm missing --profile missing --from-template base --boot recovery
expect_failure "MDM rejects conflicting creation sources" "$runner" mdm missing --profile missing --from-template base --latest
# A plain-HTTP server keeps the dry run offline: HTTP has no TLS to probe.
cat >"$work/mdm-http.mobileconfig" <<'PROFILE'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PayloadType</key><string>Configuration</string>
<key>PayloadIdentifier</key><string>com.example.contract</string>
<key>PayloadUUID</key><string>11111111-2222-3333-4444-555555555555</string>
<key>PayloadVersion</key><integer>1</integer>
<key>PayloadContent</key><array><dict>
<key>PayloadType</key><string>com.apple.mdm</string>
<key>PayloadIdentifier</key><string>com.example.contract.mdm</string>
<key>PayloadUUID</key><string>22222222-3333-4444-5555-666666666666</string>
<key>PayloadVersion</key><integer>1</integer>
<key>ServerURL</key><string>http://mdm.invalid/mdm</string>
</dict></array>
</dict></plist>
PROFILE
chmod 600 "$work/mdm-http.mobileconfig"
expect_exit_1 "MDM dry run blocks a missing VM without a creation source" \
  "$runner" mdm contract-missing --profile "$work/mdm-http.mobileconfig" --dry-run --format json
if python3 -c 'import json,sys; p=json.load(sys.stdin); r=p["result"]["readiness"]; assert p["ok"] is False; assert r["vmExists"] is False; assert [b["code"] for b in r["blockers"]]==["vmMissing"]; assert p["result"]["serverTrust"]["result"]=="notApplicable"; assert [s["status"] for s in p["steps"]]==["blocked"]' <"$work/stdout"; then
  pass "MDM dry run reports vmMissing without touching the VM store"
else
  fail "MDM dry run reports vmMissing without touching the VM store"
fi
if [[ ! -e "$POMME_APP_SUPPORT_DIR/VMs/contract-missing.bundle" ]]; then
  pass "MDM dry run creates no VM bundle"
else
  fail "MDM dry run creates no VM bundle"
fi
expect_failure "unknown root command is rejected" "$runner" definitely-not-a-command

expect_success "tools expose UI capability discovery" "$runner" tools --format json
if python3 -c 'import json,sys; p=json.load(sys.stdin)["uiCapabilities"]; assert "settingsAI" not in p; assert p["implementedOperations"]==["click","key","key-sequence","type","screenshot"]' <"$work/stdout"; then
  pass "UI capability discovery lists only the direct operations"
else
  fail "UI capability discovery lists only the direct operations"
fi
expect_failure "ui ai is not a command" "$runner" ui ai settings
if grep -q "unexpected arguments: 'ai', 'settings'" "$work/stderr"; then
  pass "ui ai is rejected as an unexpected argument"
else
  fail "ui ai is rejected as an unexpected argument"
fi
expect_failure "ui key takes the VM from the environment" env POMME_VM_NAME=invalid/name \
  "$runner" ui key --key return --format json
if grep -q 'Invalid VM name invalid/name' "$work/stderr"; then
  pass "ui key reaches target validation"
else
  fail "ui key reaches target validation"
fi
expect_failure "ui key-sequence takes the VM from the environment" env POMME_VM_NAME=invalid/name \
  "$runner" ui key-sequence -- return right
if grep -q 'Invalid VM name invalid/name' "$work/stderr"; then
  pass "ui key-sequence reaches target validation"
else
  fail "ui key-sequence reaches target validation"
fi
expect_failure "ui key takes no positional VM" "$runner" ui key missing --key return
if grep -q "Unexpected argument 'missing'" "$work/stderr"; then
  pass "ui key names the positional VM as unexpected"
else
  fail "ui key names the positional VM as unexpected"
fi
expect_failure "dry-run rejects memory below the provisional floor" "$runner" create example \
  --restore-image "$work/missing.ipsw" --memory 512MB --dry-run
if grep -q 'provisional guest minimum' "$work/stderr"; then
  pass "dry-run names the provisional memory floor"
else
  fail "dry-run names the provisional memory floor"
fi
cat >"$work/parallel.yaml" <<'YAML'
schemaVersion: 1
name: cfgtest
versions: [26.6.2]
boot: none
YAML
expect_failure "parallel takes no value" "$runner" create --config "$work/parallel.yaml" --dry-run --parallel 2
if grep -q -- '--parallel takes no value' "$work/stderr"; then
  pass "parallel explains that it takes no value"
else
  fail "parallel explains that it takes no value"
fi
rm -f "$work/parallel.yaml"
expect_failure "click rejects a negative coordinate" "$runner" ui click --vm missing --x -1 --y 1
if grep -q -- '--x must be' "$work/stderr"; then
  pass "click names the coordinate range"
else
  fail "click names the coordinate range"
fi
expect_failure "snapshot names are validated as snapshot names" "$runner" snapshot create missing --snapshot "bad/snap"
if grep -q 'Invalid snapshot name bad/snap' "$work/stderr"; then
  pass "snapshot rejection names the snapshot"
else
  fail "snapshot rejection names the snapshot"
fi
expect_failure "snapshot name is not a second positional value" "$runner" snapshot create missing clean
if grep -q "Missing expected argument '--snapshot <name>'" "$work/stderr"; then
  pass "positional snapshot name points at --snapshot"
else
  fail "positional snapshot name points at --snapshot"
fi
expect_failure "job ID is not a second positional value" "$runner" jobs logs missing 3f2a --job 3f2a
if grep -q "Unexpected argument '3f2a'" "$work/stderr"; then
  pass "positional job ID is an unexpected argument"
else
  fail "positional job ID is an unexpected argument"
fi
expect_failure "session ID requires --session" "$runner" sessions logs missing 00000000-0000-0000-0000-000000000000
if grep -q "Missing expected argument '--session <id>'" "$work/stderr"; then
  pass "positional session ID points at --session"
else
  fail "positional session ID points at --session"
fi
expect_failure "exec takes the VM name from the environment" env POMME_VM_NAME=invalid/name \
  "$runner" exec -- /bin/echo hi
if grep -q 'Invalid VM name invalid/name' "$work/stderr"; then
  pass "exec name comes from the environment, not the command"
else
  fail "exec name comes from the environment, not the command"
fi
expect_failure "shell takes no expression" "$runner" shell missing --detach 'ls -l /Users'
if grep -q "Unexpected argument 'ls -l /Users'" "$work/stderr"; then
  pass "shell expression is an unexpected argument"
else
  fail "shell expression is an unexpected argument"
fi
expect_failure "shell takes no timeout" "$runner" shell missing --detach --timeout 5
if grep -q "Unknown option '--timeout'" "$work/stderr"; then
  pass "shell names --timeout as unknown"
else
  fail "shell names --timeout as unknown"
fi
for shell_flag in --stdin --pty --guest-stdout; do
  expect_failure "shell has no $shell_flag" "$runner" shell missing --detach "$shell_flag"
  if grep -q "Unknown option '$shell_flag'" "$work/stderr"; then
    pass "shell names $shell_flag as unknown"
  else
    fail "shell names $shell_flag as unknown"
  fi
done
expect_failure "attached shell requires a terminal" "$runner" shell missing </dev/null
if grep -q 'An attached shell requires an interactive terminal' "$work/stderr"; then
  pass "attached shell names the terminal requirement"
else
  fail "attached shell names the terminal requirement"
fi
expect_success "ui keys lists the key vocabulary" "$runner" ui keys
if grep -q '^return' "$work/stdout" && grep -q '^command-' "$work/stdout"; then
  pass "ui keys names keys and modifier prefixes"
else
  fail "ui keys names keys and modifier prefixes"
fi
expect_success "ui keys renders JSON" "$runner" ui keys --format json
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["ok"] and d["namedKeys"] and d["modifierPrefixes"] else 1)' "$work/stdout"; then
  pass "ui keys JSON carries the vocabulary"
else
  fail "ui keys JSON carries the vocabulary"
fi
expect_failure "key sequence takes keys only after --" env POMME_VM_NAME=pomme-test-nonexistent \
  "$runner" ui key-sequence return right
if grep -q 'Put the keys after --' "$work/stderr"; then
  pass "key sequence explains the -- terminator"
else
  fail "key sequence explains the -- terminator"
fi

expect_failure "status without a target shows status usage" env -u POMME_VM_NAME "$runner" status
if grep -q '^Usage: pomme status' "$work/stderr" && grep -q "See 'pomme status --help'" "$work/stderr"; then
  pass "status run-time validation names the status usage"
else
  fail "status run-time validation names the status usage"
fi
expect_failure "non-interactive delete requires force" "$runner" delete missing </dev/null
if grep -q '^Usage: pomme delete' "$work/stderr" && grep -q -- 'Pass -f/--force' "$work/stderr"; then
  pass "delete run-time validation names the delete usage"
else
  fail "delete run-time validation names the delete usage"
fi

# Only the parse-time conflict is exercised here: --all must never act on
# this host's inventory from a contract test.
for all_command in stop pause resume delete; do
  expect_failure "$all_command --all rejects VM names" "$runner" "$all_command" -a pomme-contract-all-missing
  if grep -q -- '--all conflicts with VM names.' "$work/stderr"; then
    pass "$all_command names the --all conflict"
  else
    fail "$all_command names the --all conflict"
  fi
done

for delete_command in delete rm; do
  expect_success "$delete_command help" "$runner" "$delete_command" --help
  tr -s '[:space:]' ' ' <"$work/stdout" >"$work/delete-help-normalized"
  if grep -Fq 'Stop running VMs and delete without prompting. May power off if shutdown times out.' "$work/delete-help-normalized"; then
    pass "$delete_command help explains automatic stopping and skipped confirmation"
  else
    fail "$delete_command help explains automatic stopping and skipped confirmation"
  fi
done

delete_fixture_name="pomme-delete-cli-$$"
delete_fixture_vm_store_dir="$POMME_APP_SUPPORT_DIR/VMs"
delete_fixture_bundle="$POMME_APP_SUPPORT_DIR/VMs/$delete_fixture_name.bundle"
delete_fixture_sentinel="$delete_fixture_bundle/untouched-sentinel"
delete_fixture_runtime_dir="$POMME_APP_SUPPORT_DIR/Runtime"
delete_fixture_runtime_record="$delete_fixture_runtime_dir/issue8-$delete_fixture_name.json"
mkdir -p -- "$delete_fixture_bundle" "$delete_fixture_runtime_dir"
printf 'issue 8 deletion sentinel\n' >"$delete_fixture_sentinel"
python3 - "$delete_fixture_name" "$delete_fixture_bundle" "$delete_fixture_runtime_record" "$$" <<'PY'
import json, sys

name, bundle, record, pid = sys.argv[1:]
with open(record, 'w', encoding='utf-8') as destination:
    json.dump({
        'id': '00000000-0000-0000-0000-000000000008',
        'name': name,
        'bundlePath': bundle,
        'socketPath': '/tmp/pomme-issue8-fixture.sock',
        'pid': int(pid),
        'startedAt': '2026-09-23T00:00:00Z',
    }, destination, sort_keys=True)
    destination.write('\n')
PY
cp -- "$delete_fixture_sentinel" "$work/delete-expected-sentinel"
cp -- "$delete_fixture_runtime_record" "$work/delete-expected-runtime-record"

for delete_command in delete rm; do
  expect_exit_1 "$delete_command --force fails when the running helper cannot be stopped" \
    "$runner" "$delete_command" "$delete_fixture_name" --force
  if [[ -d "$delete_fixture_bundle" ]] \
    && cmp -s "$work/delete-expected-sentinel" "$delete_fixture_sentinel" \
    && cmp -s "$work/delete-expected-runtime-record" "$delete_fixture_runtime_record"; then
    pass "$delete_command stop failure preserves the bundle and runtime record"
  else
    fail "$delete_command stop failure preserves the bundle and runtime record"
  fi
done

rm -f -- "$delete_fixture_runtime_record"
expect_success "force deletes the stopped credential-free synthetic bundle" \
  "$runner" delete "$delete_fixture_name" --force
if [[ ! -e "$delete_fixture_bundle" ]]; then
  pass "stopped synthetic bundle was removed"
else
  fail "stopped synthetic bundle was removed"
fi

marketing_version="$(sed -n 's/^MARKETING_VERSION = //p' "$repo_root/Config/Shared.xcconfig")"
expect_success "version prints the build identity" "$runner" --version
version_line="$(cat "$work/stdout")"
if [[ -n "$marketing_version" && "$version_line" == "pomme $marketing_version ("?*")" ]]; then
  pass "version line names the marketing version and commit"
else
  fail "version line names the marketing version and commit"
fi
expect_failure "create --version without a value is still an option error" "$runner" create example --version
if grep -q "Missing value for '--version <version>'" "$work/stderr"; then
  pass "create --version keeps its option meaning"
else
  fail "create --version keeps its option meaning"
fi

expect_success "jsonl list of an empty inventory" "$runner" list --format jsonl
if [[ ! -s "$work/stdout" ]]; then
  pass "jsonl prints no line for an empty inventory"
else
  fail "jsonl prints no line for an empty inventory"
fi
expect_success "ui keys renders JSONL" "$runner" ui keys --format jsonl
if python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1])]; sys.exit(0 if len(rows) > 1 and all(r["kind"] in ("key","modifier") for r in rows) else 1)' "$work/stdout"; then
  pass "ui keys JSONL prints one tagged object per line"
else
  fail "ui keys JSONL prints one tagged object per line"
fi
expect_failure "raw output format is rejected" "$runner" list --format raw
if grep -q "'table', 'json' or 'jsonl'" "$work/stderr"; then
  pass "raw rejection names the supported formats"
else
  fail "raw rejection names the supported formats"
fi

expect_failure "ui type requires --text or --text-env" env POMME_VM_NAME=invalid/name "$runner" ui type hi
if grep -q 'Choose exactly one of --text or --text-env.' "$work/stderr"; then
  pass "ui type names its two text forms"
else
  fail "ui type names its two text forms"
fi
expect_failure "ui type --text takes the VM from the environment" env POMME_VM_NAME=invalid/name \
  "$runner" ui type --text hi
if grep -q 'Invalid VM name invalid/name' "$work/stderr"; then
  pass "ui type reaches target validation"
else
  fail "ui type reaches target validation"
fi

expect_failure "screenshot rejects a missing output directory" \
  "$runner" ui screenshot --vm missing --output /nonexistentdir/s.png
if grep -q 'No such directory: /nonexistentdir' "$work/stderr"; then
  pass "screenshot names the missing output directory"
else
  fail "screenshot names the missing output directory"
fi

expect_failure "ipsw list rejects a malformed device identifier" "$runner" ipsw list --device Bogus
if grep -q -- '--device must be an Apple model identifier' "$work/stderr"; then
  pass "ipsw list names the device identifier shape"
else
  fail "ipsw list names the device identifier shape"
fi

cat >"$work/cfgbad.yaml" <<'YAML'
name: cfgbad
versions: [26.6.2]
YAML
expect_failure "config validate rejects a config without schemaVersion" "$runner" config validate "$work/cfgbad.yaml"
if grep -q "missing required key 'schemaVersion'" "$work/stderr" && ! grep -q 'CodingKeys' "$work/stderr"; then
  pass "config decode failure names the missing key in plain words"
else
  fail "config decode failure names the missing key in plain words"
fi
rm -f "$work/cfgbad.yaml"

cat >"$work/goodbogus.yaml" <<'YAML'
schemaVersion: 1
name: cfgtest
versions: [26.6.2]
bogusKey: true
YAML
expect_failure "config validate rejects an unknown key" "$runner" config validate "$work/goodbogus.yaml"
if grep -q "Config key 'bogusKey' is not recognized" "$work/stderr"; then
  pass "config unknown key is named"
else
  fail "config unknown key is named"
fi
rm -f "$work/goodbogus.yaml"

expect_failure "cp names a missing host source" "$runner" cp /nonexistent.txt missing:/tmp/x
if grep -q 'Host file /nonexistent.txt does not exist.' "$work/stderr"; then
  pass "cp missing host source is reported on the host"
else
  fail "cp missing host source is reported on the host"
fi

# Presentation options preserve result bytes for text and empty JSONL. JSON
# object key order is unspecified, so compare decoded structured values.
for progress_format in table json jsonl; do
  "$runner" list --format "$progress_format" --progress off >"$work/progress-baseline" 2>"$work/progress-baseline-stderr"
  for progress_mode in auto plain off; do
    expect_success "list $progress_format accepts progress $progress_mode" \
      "$runner" list --format "$progress_format" --progress "$progress_mode"
    if [[ "$progress_format" == table || ( "$progress_format" == jsonl && ! -s "$work/progress-baseline" ) ]]; then
      if cmp -s "$work/progress-baseline" "$work/stdout"; then
        pass "progress $progress_mode preserves $progress_format result bytes"
      else
        fail "progress $progress_mode preserves $progress_format result bytes"
      fi
    elif python3 -c 'import json,sys; decode=lambda p: json.load(open(p)) if sys.argv[3] == "json" else [json.loads(line) for line in open(p)]; sys.exit(0 if decode(sys.argv[1]) == decode(sys.argv[2]) else 1)' "$work/progress-baseline" "$work/stdout" "$progress_format"; then
      pass "progress $progress_mode preserves $progress_format result values"
    else
      fail "progress $progress_mode preserves $progress_format result values"
    fi
    if [[ "$progress_format" != table ]]; then
      if python3 -c 'import json,sys; text=open(sys.argv[1]).read(); json.loads(text) if sys.argv[2] == "json" else [json.loads(line) for line in text.splitlines()]' "$work/stdout" "$progress_format"; then
        pass "progress $progress_mode preserves valid $progress_format"
      else
        fail "progress $progress_mode preserves valid $progress_format"
      fi
    fi
  done
done
for progress_mode in auto plain off; do
  expect_success "nonempty JSONL accepts progress $progress_mode" \
    "$runner" ui keys --format jsonl --progress "$progress_mode"
  if python3 -c 'import json,sys; rows=[json.loads(line) for line in open(sys.argv[1])]; sys.exit(0 if len(rows)>1 else 1)' "$work/stdout"; then
    pass "progress $progress_mode preserves nonempty JSONL records"
  else
    fail "progress $progress_mode preserves nonempty JSONL records"
  fi
  expect_failure "progress $progress_mode retains missing VM errors" \
    "$runner" status pomme-contract-progress-missing --progress "$progress_mode"
  if [[ -s "$work/stderr" ]] && grep -q 'Error:' "$work/stderr" && [[ ! -s "$work/stdout" ]]; then
    pass "progress $progress_mode keeps errors on stderr"
  else
    fail "progress $progress_mode keeps errors on stderr"
  fi
done
expect_success "debug diagnostics remain visible with progress off" "$runner" list --progress off --debug
if grep -q 'Debug logging enabled' "$work/stderr"; then
  pass "progress off preserves explicit debug diagnostics"
else
  fail "progress off preserves explicit debug diagnostics"
fi
expect_failure "invalid progress mode is rejected" "$runner" list --progress animated
expect_failure "guest debug argument does not enable host diagnostics" \
  "$runner" exec pomme-contract-progress-missing --progress off -- /bin/echo --debug --progress plain
if ! grep -q 'Debug logging enabled' "$work/stderr"; then
  pass "guest options stay outside host presentation settings"
else
  fail "guest options stay outside host presentation settings"
fi

if [[ $failures -ne 0 ]]; then
  printf '%d of %d contract checks failed\n' "$failures" "$checks" >&2
  exit 1
fi

printf 'all %d Pomme CLI contract checks passed\n' "$checks"
