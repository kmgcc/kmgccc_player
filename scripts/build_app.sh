#!/usr/bin/env bash
set -euo pipefail

# Build and validate the app using only inputs available in a clean checkout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
MELISMAKIT_EXPECTED_SOURCE="${MELISMAKIT_EXPECTED_SOURCE:-local}"

if (($# > 0)); then
  CONFIGURATION="$1"
  shift
fi
if (($# > 0)); then
  echo "error: unexpected argument: $1" >&2
  exit 2
fi
case "$CONFIGURATION" in
  Debug|Release) ;;
  *) echo "error: configuration must be Debug or Release" >&2; exit 2 ;;
esac
case "$MELISMAKIT_EXPECTED_SOURCE" in
  local) MELISMAKIT_DEPENDENCY_FLAG="--require-local" ;;
  remote) MELISMAKIT_DEPENDENCY_FLAG="--require-remote" ;;
  *) echo "error: MELISMAKIT_EXPECTED_SOURCE must be local or remote" >&2; exit 2 ;;
esac

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/kmgccc-player-$CONFIGURATION}"
PROJECT="$REPO_ROOT/kmgccc_player.xcodeproj"
APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/kmgccc_player.app"
DSYM="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/kmgccc_player.app.dSYM"
BUILD_LOG="${KMGCCC_BUILD_LOG:-$REPO_ROOT/build/logs/build_app-$(date +%Y%m%d-%H%M%S)-$$.log}"

"$SCRIPT_DIR/check-melismakit-dependency.sh" "$MELISMAKIT_DEPENDENCY_FLAG"

rm -rf "$DERIVED_DATA_PATH"

XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme kmgccc_player
  -configuration "$CONFIGURATION"
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$DERIVED_DATA_PATH"
  BUILD_EXTENSION_MODE=disabled
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
)
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  XCODEBUILD_ARGS+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY")
fi
if [[ -n "${CODE_SIGN_STYLE:-}" ]]; then
  XCODEBUILD_ARGS+=("CODE_SIGN_STYLE=$CODE_SIGN_STYLE")
fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ -n "${CODE_SIGN_INJECT_BASE_ENTITLEMENTS:-}" ]]; then
  XCODEBUILD_ARGS+=("CODE_SIGN_INJECT_BASE_ENTITLEMENTS=$CODE_SIGN_INJECT_BASE_ENTITLEMENTS")
fi

mkdir -p "$(dirname "$BUILD_LOG")"
if ! xcodebuild "${XCODEBUILD_ARGS[@]}" \
  -verbose \
  build >"$BUILD_LOG" 2>&1; then
  echo "error: xcodebuild failed; recent output:" >&2
  tail -n 100 "$BUILD_LOG" >&2 || true
  echo "Full build log: $BUILD_LOG" >&2
  exit 1
fi

"$SCRIPT_DIR/check-melismakit-dependency.sh" "$MELISMAKIT_DEPENDENCY_FLAG" --build-log "$BUILD_LOG"

[[ -d "$APP" ]] || { echo "error: app was not produced: $APP" >&2; exit 1; }
"$SCRIPT_DIR/check-app-bundle.sh" "$APP"

if [[ "$CONFIGURATION" == "Release" ]]; then
  [[ -d "$DSYM" ]] || { echo "error: Release build did not produce a dSYM: $DSYM" >&2; exit 1; }
  [[ -n "${CRASH_SYMBOL_ARCHIVE_DIR:-}" && -n "${CRASH_SYMBOL_BACKUP_DIR:-}" ]] || {
    echo "error: Release symbol retention requires CRASH_SYMBOL_ARCHIVE_DIR and CRASH_SYMBOL_BACKUP_DIR" >&2
    exit 1
  }
  "$SCRIPT_DIR/package-crash-symbols.sh" \
    --app "$APP" \
    --dsym "$DSYM" \
    --manifest "$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/kmgccc_player.symbols-manifest.json" \
    --archive-dir "$CRASH_SYMBOL_ARCHIVE_DIR" \
    --backup-dir "$CRASH_SYMBOL_BACKUP_DIR"
fi

if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
  rm -rf "$OUTPUT_DIR/kmgccc_player.app"
  COPYFILE_DISABLE=1 /usr/bin/ditto "$APP" "$OUTPUT_DIR/kmgccc_player.app"
  APP="$OUTPUT_DIR/kmgccc_player.app"
fi
printf '%s\n' "$APP"
