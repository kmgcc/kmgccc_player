#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/kmgccc_player.xcodeproj"
SCHEME="kmgccc_player"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kmgccc-verify.XXXXXX")"
DERIVED_DATA="$WORK_DIR/DerivedData"
PACKAGE_CACHE="$WORK_DIR/SourcePackages"
LOG_DIR="$WORK_DIR/logs"
CURRENT_PID=""
KEEP_OUTPUT="${KMGCCC_KEEP_VERIFY_OUTPUT:-0}"

mkdir -p "$LOG_DIR"

terminate_process_tree() {
  local pid="$1"
  /usr/bin/pkill -TERM -P "$pid" 2>/dev/null || true
  /bin/kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  /usr/bin/pkill -KILL -P "$pid" 2>/dev/null || true
  /bin/kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$?
  if [[ -n "$CURRENT_PID" ]]; then
    terminate_process_tree "$CURRENT_PID"
  fi
  if ((status == 0)) && [[ "$KEEP_OUTPUT" != "1" ]]; then
    rm -rf "$WORK_DIR"
  else
    printf 'Verification output: %s\n' "$WORK_DIR" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run_step() {
  local label="$1"
  local timeout_seconds="$2"
  shift 2
  local log_file="$LOG_DIR/${label//[^a-zA-Z0-9._-]/_}.log"
  local deadline started exit_code

  printf '\n==> %s\n' "$label"
  started=$SECONDS
  "$@" >"$log_file" 2>&1 &
  CURRENT_PID=$!
  deadline=$((SECONDS + timeout_seconds))

  while /bin/kill -0 "$CURRENT_PID" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      terminate_process_tree "$CURRENT_PID"
      CURRENT_PID=""
      printf '[FAIL] %s timed out after %ss.\n' "$label" "$timeout_seconds" >&2
      /usr/bin/tail -n 80 "$log_file" >&2 || true
      printf 'Full log: %s\n' "$log_file" >&2
      exit 124
    fi
    sleep 1
  done

  if wait "$CURRENT_PID"; then
    exit_code=0
  else
    exit_code=$?
  fi
  CURRENT_PID=""
  if ((exit_code != 0)); then
    printf '[FAIL] %s failed with exit code %s.\n' "$label" "$exit_code" >&2
    /usr/bin/tail -n 80 "$log_file" >&2 || true
    printf 'Full log: %s\n' "$log_file" >&2
    exit "$exit_code"
  fi
  printf '[OK] %s (%ss)\n' "$label" "$((SECONDS - started))"
}

if [[ $# -ne 0 ]]; then
  echo "Usage: ./scripts/verify.sh" >&2
  exit 2
fi

require_command xcodebuild
require_command xcrun
require_command git

run_step "Bootstrap" 3600 "$ROOT/scripts/bootstrap.sh"

run_step "ARM64 unsigned Debug build" 2400 \
  xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
    BUILD_EXTENSION_MODE=disabled \
    CODE_SIGNING_ALLOWED=NO \
    build

LRC_EXECUTABLE="$WORK_DIR/lrc-regression"
run_step "LRC regression" 180 \
  xcrun swiftc -parse-as-library \
    "$ROOT/kmgccc_player/Services/LDDC/LRCConverterService.swift" \
    "$ROOT/Tests/LRCConverterServiceRegressionTests.swift" \
    -o "$LRC_EXECUTABLE"
run_step "LRC regression execution" 60 "$LRC_EXECUTABLE"

run_step "XCTest" 1800 \
  xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme kmgccc_playerTests \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
    BUILD_EXTENSION_MODE=disabled \
    CODE_SIGNING_ALLOWED=NO \
    test

APP="$DERIVED_DATA/Build/Products/Debug/kmgccc_player.app"
run_step "Required App bundle components" 120 \
  "$ROOT/scripts/check-app-bundle.sh" "$APP"

printf '\nQuick verification passed.\n'
printf 'App: %s\n' "$APP"
