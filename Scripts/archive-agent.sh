#!/usr/bin/env bash
# Retain one independently verified signed Pomme agent per SHA-256 digest.
# The store is append-only: an existing digest entry is verified and reused;
# it is never replaced in place.
set -euo pipefail

usage() {
  echo 'Usage: Scripts/archive-agent.sh --source PATH [--expected-sha256 HEX] [--store-root DIR]'
  echo '       PATH must be an absolute regular signed Pomme executable.'
  echo '       --store-root is the Pomme application-support root; by default'
  echo '       POMME_APP_SUPPORT_DIR or ~/Library/Application Support/pomme is used.'
}

fail() { echo "pomme agent archive: $*" >&2; exit 1; }

source_path=''
expected_sha256=''
store_root=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 && -n "$2" ]] || fail '--source requires a path.'
      source_path="$2"
      shift 2
      ;;
    --expected-sha256)
      [[ $# -ge 2 && -n "$2" ]] || fail '--expected-sha256 requires a digest.'
      expected_sha256="$2"
      shift 2
      ;;
    --store-root)
      [[ $# -ge 2 && -n "$2" && "$2" == /* ]] || fail '--store-root requires an absolute directory path.'
      store_root="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown option: $1"
      ;;
  esac
done

[[ -n "$source_path" && "$source_path" == /* ]] || fail '--source requires an absolute path.'
for dependency in rtk codesign shasum awk stat find id mkdir mktemp install mv rm dirname basename realpath; do
  command -v "$dependency" >/dev/null 2>&1 || fail "Required tool is unavailable: $dependency"
done

readonly signing_requirement='anchor apple generic and identifier "com.github.weswhet.pomme" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2D8XQ77EBQ"'
readonly artifact_directory_name='AgentArtifacts'
readonly digest_directory_name='sha256'
readonly artifact_name='pomme-agent'
readonly maximum_artifact_bytes=$((128 * 1024 * 1024))

run() { rtk proxy "$@"; }

is_lowercase_sha256() {
  local value="$1"
  [[ ${#value} -eq 64 && "$value" != *[!0123456789abcdef]* ]]
}

if [[ -n "$expected_sha256" ]]; then
  is_lowercase_sha256 "$expected_sha256" || fail '--expected-sha256 must be a lowercase SHA-256 digest.'
fi

if [[ -z "$store_root" ]]; then
  if [[ -n "${POMME_APP_SUPPORT_DIR:-}" ]]; then
    store_root="$POMME_APP_SUPPORT_DIR"
  else
    user_home="${HOME:-}"
    [[ -n "$user_home" ]] || fail 'HOME is unavailable.'
    store_root="$user_home/Library/Application Support/pomme"
  fi
fi
[[ "$store_root" == /* ]] || fail 'The Pomme application-support root must be absolute.'

store_parent="$(run dirname -- "$store_root")"
store_leaf="$(run basename -- "$store_root")"
store_parent_real="$(run realpath "$store_parent")"
[[ -n "$store_leaf" && "$store_parent_real/$store_leaf" == "$store_root" ]] || fail 'The Pomme application-support root contains a symlink or is not canonical.'
if [[ -e "$store_parent" || -L "$store_parent" ]]; then
  [[ ! -L "$store_parent" && -d "$store_parent" ]] || fail 'The Pomme application-support parent is not a directory.'
  [[ "$(run stat -f '%u' "$store_parent")" == "$(run id -u)" ]] || fail 'The Pomme application-support parent is not owned by the current user.'
  [[ -z "$(run find "$store_parent" -prune \( -perm -0020 -o -perm -0002 \) -print -quit)" ]] || fail 'The Pomme application-support parent is group/world writable.'
else
  fail 'The Pomme application-support parent is unavailable.'
fi

current_uid="$(run id -u)"

has_group_or_world_write() {
  local path="$1"
  [[ -z "$(run find "$path" -prune \( -perm -0020 -o -perm -0002 \) -print -quit)" ]]
}

validate_directory() {
  local path="$1"
  [[ ! -L "$path" && -d "$path" ]] || fail 'A store directory is not a regular directory.'
  [[ "$(run stat -f '%u' "$path")" == "$current_uid" ]] || fail 'A store directory is not owned by the current user.'
  has_group_or_world_write "$path" || fail 'A store directory is group/world writable.'
}

ensure_directory() {
  local path="$1"
  if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
    fail 'A store path is not a private directory.'
  fi
  if [[ ! -e "$path" ]]; then
    run mkdir -m 700 -- "$path" || fail 'Could not create the Pomme artifact directory.'
  fi
  validate_directory "$path"
}

validate_regular_file() {
  local path="$1"
  local size links
  [[ ! -L "$path" && -f "$path" ]] || fail 'An agent artifact is not a regular file.'
  [[ "$(run stat -f '%u' "$path")" == "$current_uid" ]] || fail 'An agent artifact is not owned by the current user.'
  links="$(run stat -f '%l' "$path")"
  [[ "$links" == 1 ]] || fail 'An agent artifact has unexpected hard links.'
  has_group_or_world_write "$path" || fail 'An agent artifact is group/world writable.'
  size="$(run stat -f '%z' "$path")"
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le "$maximum_artifact_bytes" ]] || fail 'An agent artifact has an invalid size.'
}

verify_signature() {
  run codesign --verify --strict --all-architectures \
    --test-requirement="=$signing_requirement" "$1"
}

digest_for() {
  run shasum -a 256 "$1" | run awk '{ print $1 }'
}

verify_entry() {
  local path="$1" expected="$2" actual
  validate_regular_file "$path"
  verify_signature "$path" || fail 'The retained Pomme agent signature is invalid.'
  actual="$(digest_for "$path")"
  [[ "$actual" == "$expected" ]] || fail 'The retained Pomme agent digest does not match its directory.'
}

source_parent="$(run dirname -- "$source_path")"
source_leaf="$(run basename -- "$source_path")"
source_parent_real="$(run realpath "$source_parent")"
[[ "$source_parent_real/$source_leaf" == "$source_path" ]] || fail 'The source path contains a symlink or non-canonical parent.'
validate_directory "$source_parent"
validate_regular_file "$source_path"
verify_signature "$source_path" || fail 'The source Pomme agent signature is invalid.'
source_digest="$(digest_for "$source_path")"
is_lowercase_sha256 "$source_digest" || fail 'The source digest is malformed.'
if [[ -n "$expected_sha256" && "$source_digest" != "$expected_sha256" ]]; then
  fail 'The source does not match --expected-sha256.'
fi

ensure_directory "$store_root"
artifact_root="$store_root/$artifact_directory_name"
digest_root="$artifact_root/$digest_directory_name"
digest_directory="$digest_root/$source_digest"
destination="$digest_directory/$artifact_name"
ensure_directory "$artifact_root"
ensure_directory "$digest_root"

if [[ -L "$digest_directory" || ( -e "$digest_directory" && ! -d "$digest_directory" ) ]]; then
  fail 'The digest artifact directory is unsafe.'
fi
if [[ ! -e "$digest_directory" ]]; then
  run mkdir -m 700 -- "$digest_directory" || fail 'Could not create the digest artifact directory.'
fi
validate_directory "$digest_directory"

if [[ -L "$destination" || -e "$destination" ]]; then
  verify_entry "$destination" "$source_digest"
  echo "Reused signed Pomme agent artifact: $destination"
  exit 0
fi

unknown_entry="$(run find "$digest_directory" -mindepth 1 -maxdepth 1 ! -name "$artifact_name" -print -quit)"
[[ -z "$unknown_entry" ]] || fail 'The digest directory contains an unexpected entry.'

temporary=''
cleanup() {
  if [[ -n "$temporary" ]]; then
    run rm -f -- "$temporary" || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

temporary="$(run mktemp "$digest_directory/.pomme-agent.XXXXXX")"
run install -m 0555 -- "$source_path" "$temporary"
verify_entry "$temporary" "$source_digest"

# `mv -n` is the final no-clobber operation.  If another writer won the
# append race, verify its complete entry and discard only our known temporary.
run mv -n -- "$temporary" "$destination"
verify_entry "$destination" "$source_digest"
run rm -f -- "$temporary"
temporary=''
echo "Archived signed Pomme agent artifact: $destination"
