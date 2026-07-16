#!/usr/bin/env bash
set -euo pipefail

# Build and validate the app using only inputs available in a clean checkout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-}"

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

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/kmgccc-player-$CONFIGURATION}"
PROJECT="$REPO_ROOT/kmgccc_player.xcodeproj"
APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/kmgccc_player.app"
DSYM="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/kmgccc_player.app.dSYM"
rm -rf "$DERIVED_DATA_PATH"

xcodebuild \
  -project "$PROJECT" \
  -scheme kmgccc_player \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  BUILD_EXTENSION_MODE=disabled \
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
  build

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
