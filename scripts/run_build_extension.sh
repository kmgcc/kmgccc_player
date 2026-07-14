#!/usr/bin/env bash
set -euo pipefail

# Xcode build-phase adapter for an optional machine-local build extension.
# The hook receives an empty staging directory through `--output`. Outputs are
# installed as one transaction so a failed hook or copy preserves the last
# complete result. Disabling the hook removes only previously recorded output.

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-kmgccc_player.app}"
RESOURCES="$APP/Contents/Resources"
MODE="${BUILD_EXTENSION_MODE:-auto}"
STRICT="${BUILD_EXTENSION_STRICT:-NO}"
HOOK="${BUILD_EXTENSION_HOOK:-}"
STATE_ROOT="${DERIVED_FILE_DIR:-${TARGET_TEMP_DIR:-${TEMP_FILES_DIR:-${TMPDIR:-/tmp}/kmgccc-build-state}}}"
STATE_FILE="${BUILD_EXTENSION_STATE_FILE:-$STATE_ROOT/build-extension.paths}"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

validate_name() {
  local name="$1"
  case "$name" in
    ''|.|..|*/*|*$'\n'*) fail "invalid optional build output name" ;;
  esac
}

remove_recorded_outputs() {
  local name
  [[ -f "$STATE_FILE" ]] || return 0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    validate_name "$name"
    rm -rf "$RESOURCES/$name"
  done < "$STATE_FILE"
  rm -f "$STATE_FILE"
}

case "$MODE" in
  auto|enabled|disabled) ;;
  *)
    printf 'error: unsupported BUILD_EXTENSION_MODE: %s\n' "$MODE" >&2
    exit 2
    ;;
esac

if [[ "$MODE" == disabled ]]; then
  remove_recorded_outputs
  exit 0
fi

if [[ -z "$HOOK" || ! -x "$HOOK" ]]; then
  if [[ "$MODE" == enabled && "$STRICT" == YES ]]; then
    fail "an executable BUILD_EXTENSION_HOOK is required"
  fi
  remove_recorded_outputs
  exit 0
fi

[[ -d "$APP" ]] || fail "target app is unavailable before optional build outputs are prepared"
mkdir -p "$RESOURCES" "$STATE_ROOT"

HOOK_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/kmgccc-build-extension.XXXXXX")"
PREPARED_DIR="$(mktemp -d "$RESOURCES/.build-extension-prepared.XXXXXX")"
BACKUP_DIR="$(mktemp -d "$RESOURCES/.build-extension-backup.XXXXXX")"
NEXT_STATE="$(mktemp "$STATE_ROOT/build-extension.next.XXXXXX")"
PREVIOUS_STATE="$(mktemp "$STATE_ROOT/build-extension.previous.XXXXXX")"
REPLACED_NAMES="$(mktemp "$STATE_ROOT/build-extension.replaced.XXXXXX")"
[[ -f "$STATE_FILE" ]] && cp "$STATE_FILE" "$PREVIOUS_STATE"
transaction_started=0
committed=0

rollback() {
  local name
  set +e
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    rm -rf "$RESOURCES/$name"
  done < "$NEXT_STATE"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -e "$BACKUP_DIR/$name" || -L "$BACKUP_DIR/$name" ]]; then
      mv "$BACKUP_DIR/$name" "$RESOURCES/$name"
    fi
  done < "$REPLACED_NAMES"
  if [[ -s "$PREVIOUS_STATE" ]]; then
    cp "$PREVIOUS_STATE" "$STATE_FILE"
  else
    rm -f "$STATE_FILE"
  fi
  set -e
}

cleanup() {
  local status=$?
  if ((transaction_started == 1 && committed == 0)); then
    rollback
  fi
  rm -rf "$HOOK_STAGING" "$PREPARED_DIR" "$BACKUP_DIR"
  rm -f "$NEXT_STATE" "$PREVIOUS_STATE" "$REPLACED_NAMES"
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

"$HOOK" --output "$HOOK_STAGING"

output_count=0
while IFS= read -r -d '' item; do
  name="$(basename "$item")"
  validate_name "$name"
  COPYFILE_DISABLE=1 /usr/bin/ditto "$item" "$PREPARED_DIR/$name"
  printf '%s\n' "$name" >> "$NEXT_STATE"
  output_count=$((output_count + 1))
done < <(/usr/bin/find "$HOOK_STAGING" -mindepth 1 -maxdepth 1 -print0)

if ((output_count == 0)); then
  if [[ "$MODE" == enabled && "$STRICT" == YES ]]; then
    fail "optional build hook produced no outputs"
  fi
  remove_recorded_outputs
  exit 0
fi

LC_ALL=C sort -u "$NEXT_STATE" -o "$NEXT_STATE"
{
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE"
  cat "$NEXT_STATE"
} | LC_ALL=C sort -u > "$REPLACED_NAMES"

transaction_started=1
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  validate_name "$name"
  if [[ -e "$RESOURCES/$name" || -L "$RESOURCES/$name" ]]; then
    mv "$RESOURCES/$name" "$BACKUP_DIR/$name"
  fi
done < "$REPLACED_NAMES"

while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  mv "$PREPARED_DIR/$name" "$RESOURCES/$name"
done < "$NEXT_STATE"

mv "$NEXT_STATE" "$STATE_FILE"
committed=1
transaction_started=0
