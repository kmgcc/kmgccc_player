#!/usr/bin/env bash

if [[ -n "${KMGCCC_BOOTSTRAP_COMMON_LOADED:-}" ]]; then
  return 0
fi
KMGCCC_BOOTSTRAP_COMMON_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$ROOT/.build"
DOWNLOADS_DIR="$BUILD_ROOT/downloads"
SOURCES_DIR="$BUILD_ROOT/sources"
WORK_DIR="$BUILD_ROOT/work"
PRODUCTS_DIR="$BUILD_ROOT/products"
LOG_DIR="$BUILD_ROOT/logs"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-prepare}"
BOOTSTRAP_FORCE="${BOOTSTRAP_FORCE:-0}"
BOOTSTRAP_CURRENT_PID=""

mkdir -p "$DOWNLOADS_DIR" "$SOURCES_DIR" "$WORK_DIR" "$PRODUCTS_DIR" "$LOG_DIR"

component_log() {
  printf '[%s] %s\n' "$1" "$2"
}

bootstrap_fail() {
  local component="$1"
  local message="$2"
  local hint="${3:-Run ./scripts/bootstrap.sh}"
  printf '[%s] FAIL: %s\n' "$component" "$message" >&2
  printf '[%s] %s\n' "$component" "$hint" >&2
  return 1
}

require_command() {
  local command_name="$1"
  local hint="$2"
  command -v "$command_name" >/dev/null 2>&1 \
    || bootstrap_fail Environment "Required command not found: $command_name" "$hint"
}

terminate_process_tree() {
  local pid="$1"
  /usr/bin/pkill -TERM -P "$pid" 2>/dev/null || true
  /bin/kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  /usr/bin/pkill -KILL -P "$pid" 2>/dev/null || true
  /bin/kill -KILL "$pid" 2>/dev/null || true
}

bootstrap_cleanup() {
  if [[ -n "$BOOTSTRAP_CURRENT_PID" ]]; then
    terminate_process_tree "$BOOTSTRAP_CURRENT_PID"
    BOOTSTRAP_CURRENT_PID=""
  fi
}

run_logged() {
  local component="$1"
  local stage="$2"
  local timeout_seconds="$3"
  shift 3

  local safe_name log_file deadline exit_code
  safe_name="$(printf '%s-%s' "$component" "$stage" | /usr/bin/tr -cs '[:alnum:]._-' '_')"
  log_file="$LOG_DIR/${safe_name}.log"
  component_log "$component" "$stage..."

  "$@" >"$log_file" 2>&1 &
  BOOTSTRAP_CURRENT_PID=$!
  deadline=$((SECONDS + timeout_seconds))

  while /bin/kill -0 "$BOOTSTRAP_CURRENT_PID" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      terminate_process_tree "$BOOTSTRAP_CURRENT_PID"
      BOOTSTRAP_CURRENT_PID=""
      printf '[%s] FAIL: %s timed out after %ss.\n' "$component" "$stage" "$timeout_seconds" >&2
      /usr/bin/tail -n 80 "$log_file" >&2 || true
      printf '[%s] Full log: %s\n' "$component" "$log_file" >&2
      return 124
    fi
    sleep 1
  done

  if wait "$BOOTSTRAP_CURRENT_PID"; then
    exit_code=0
  else
    exit_code=$?
  fi
  BOOTSTRAP_CURRENT_PID=""

  if ((exit_code != 0)); then
    printf '[%s] FAIL: %s exited with %s.\n' "$component" "$stage" "$exit_code" >&2
    /usr/bin/tail -n 80 "$log_file" >&2 || true
    printf '[%s] Full log: %s\n' "$component" "$log_file" >&2
    return "$exit_code"
  fi
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

hash_inputs() {
  local input file
  {
    for input in "$@"; do
      if [[ -f "$input" ]]; then
        printf '%s  %s\n' "$(sha256_file "$input")" "${input#$ROOT/}"
      elif [[ -d "$input" ]]; then
        while IFS= read -r -d '' file; do
          printf '%s  %s\n' "$(sha256_file "$file")" "${file#$ROOT/}"
        done < <(
          /usr/bin/find "$input" -type f \
            ! -name '.DS_Store' \
            ! -name '*.pyc' \
            ! -path '*/__pycache__/*' \
            ! -path '*/.git/*' \
            ! -path '*/node_modules/*' \
            ! -path '*/dist-myplayer*/*' \
            -print0 | LC_ALL=C /usr/bin/sort -z
        )
      else
        printf 'MISSING  %s\n' "${input#$ROOT/}"
      fi
    done
  } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

is_arm64_macho() {
  [[ -f "$1" ]] && /usr/bin/lipo -archs "$1" 2>/dev/null | /usr/bin/grep -qw arm64
}

stamp_matches() {
  local product_dir="$1"
  local expected="$2"
  [[ -f "$product_dir/.bootstrap-version" ]] \
    && [[ "$(<"$product_dir/.bootstrap-version")" == "$expected" ]]
}

write_stamp() {
  local product_dir="$1"
  local value="$2"
  mkdir -p "$product_dir"
  printf '%s\n' "$value" >"$product_dir/.bootstrap-version"
}

download_checked() {
  local component="$1"
  local url="$2"
  local expected_sha="$3"
  local archive="$4"

  mkdir -p "$(dirname "$archive")"
  if [[ -f "$archive" ]] && [[ "$(sha256_file "$archive")" == "$expected_sha" ]]; then
    component_log "$component" "download cached"
    return 0
  fi

  rm -f "$archive"
  run_logged "$component" download 240 \
    /usr/bin/curl --fail --location --retry 3 --retry-delay 2 \
      --connect-timeout 15 --max-time 220 --silent --show-error \
      "$url" -o "$archive"
  [[ "$(sha256_file "$archive")" == "$expected_sha" ]] \
    || bootstrap_fail "$component" "Downloaded archive checksum mismatch." "Remove $archive and rerun ./scripts/bootstrap.sh"
}

install_if_changed() {
  local source="$1"
  local destination="$2"
  if [[ -f "$destination" ]] && /usr/bin/cmp -s "$source" "$destination"; then
    return 0
  fi
  mkdir -p "$(dirname "$destination")"
  COPYFILE_DISABLE=1 /bin/cp -f "$source" "$destination"
}
