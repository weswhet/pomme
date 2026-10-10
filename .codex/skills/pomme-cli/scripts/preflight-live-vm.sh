#!/usr/bin/env bash
# Read-only gate before a stateful live Pomme command: require an explicitly
# named, existing, non-template VM, and record its state so it can be restored.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: preflight-live-vm.sh VM_NAME [--runner PATH] [--record-dir DIR]
       preflight-live-vm.sh --verify-restored RECORD [--runner PATH]

Record mode (before a live command):
  - refuses unless VM_NAME is given on the command line (POMME_VM_NAME and
    running-VM inference are not accepted)
  - refuses protected base-OS templates listed by `pomme template list`
  - refuses a VM that `pomme status` cannot find
  - saves `pomme status VM_NAME --format json` to a record file and prints the
    state to restore afterwards

Verify mode (after the live command):
  - compares the VM's current vmState and bootMode with RECORD

Options:
  --runner PATH          Pomme CLI (default: $POMME_RUNNER or ~/.local/bin/pomme)
  --record-dir DIR       Where records go (default: $POMME_PREFLIGHT_DIR or
                         $TMPDIR/pomme-preflight)
  --verify-restored FILE Compare current state with a record.
  -h, --help             Show this help.

Only read-only Pomme commands run: `status` and `template list`.
Exit: 0 ok, 1 refused or state differs, 2 usage error.
USAGE
}

runner=${POMME_RUNNER:-$HOME/.local/bin/pomme}
record_dir=${POMME_PREFLIGHT_DIR:-${TMPDIR:-/tmp}/pomme-preflight}
record=""
vm=""
while [ $# -gt 0 ]; do
  case $1 in
    --runner) [ $# -ge 2 ] || { usage >&2; exit 2; }; runner=$2; shift 2 ;;
    --record-dir) [ $# -ge 2 ] || { usage >&2; exit 2; }; record_dir=$2; shift 2 ;;
    --verify-restored) [ $# -ge 2 ] || { usage >&2; exit 2; }; record=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) [ -z "$vm" ] || { echo "name exactly one VM" >&2; exit 2; }; vm=$1; shift ;;
  esac
done

command -v jq >/dev/null || { echo "missing required tool: jq" >&2; exit 2; }
[ -x "$runner" ] || { echo "Pomme runner is not executable: $runner" >&2; exit 2; }

status_json() {
  "$runner" status "$1" --format json
}

if [ -n "$record" ]; then
  [ -z "$vm" ] || { echo "--verify-restored takes the VM name from the record" >&2; exit 2; }
  [ -f "$record" ] || { echo "record not found: $record" >&2; exit 2; }
  vm=$(jq -r '.name // empty' "$record")
  [ -n "$vm" ] || { echo "record has no VM name: $record" >&2; exit 2; }
  current=$(status_json "$vm") || { echo "pomme status failed for $vm" >&2; exit 1; }
  failures=0
  for field in vmState bootMode; do
    want=$(jq -r --arg f "$field" '.[$f] // "<missing>"' "$record")
    got=$(jq -r --arg f "$field" '.[$f] // "<missing>"' <<<"$current")
    if [ "$want" = "$got" ]; then
      printf 'ok    %-9s %s\n' "$field" "$got"
    else
      printf 'FAIL  %-9s now %s, recorded %s\n' "$field" "$got" "$want"
      failures=$((failures + 1))
    fi
  done
  if [ "$failures" -gt 0 ]; then
    echo "result: $vm is not in its recorded state; restore it before reporting done"
    exit 1
  fi
  echo "result: $vm matches its recorded state"
  exit 0
fi

if [ -z "$vm" ]; then
  echo "refused: name the target VM explicitly (POMME_VM_NAME and running-VM inference are not accepted)" >&2
  exit 2
fi

templates=$("$runner" template list --format json) || { echo "pomme template list failed" >&2; exit 1; }
if jq -e --arg vm "$vm" '[.templates[]?.name] | index($vm)' >/dev/null <<<"$templates"; then
  echo "refused: $vm is a protected base-OS template; clone it with \`pomme create VM --from-template $vm --memory 4GB --boot none\`" >&2
  exit 1
fi

if ! current=$(status_json "$vm" 2>&1); then
  echo "refused: $current" >&2
  exit 1
fi

mkdir -p "$record_dir"
chmod 700 "$record_dir"
record_file="$record_dir/$vm-$(date +%Y%m%dT%H%M%S).json"
umask 077
printf '%s\n' "$current" >"$record_file"

jq -r --arg record "$record_file" '
  "vm:            \(.name)",
  "vmState:       \(.vmState // "unknown")",
  "bootMode:      \(.bootMode // "unknown")",
  "helperRunning: \(.helperRunning // "unknown")",
  "guestAgent:    \(.guestAgent.connection // "unknown")",
  "record:        \($record)",
  "restore to:    vmState=\(.vmState // "unknown") bootMode=\(.bootMode // "unknown") unless the user asked for another final state"
' <<<"$current"
echo "after the live command: $0 --verify-restored $record_file"
