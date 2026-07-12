#!/usr/bin/env bash
set -euo pipefail

# Default configuration is Debug
CONFIGURATION="${CONFIGURATION:-Debug}"
APP_NAME="kmgccc_player"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DERIVED_DATA_PATH="$REPO_ROOT/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Export log level for the app, defaulting to info
export KMGCCC_LOG_LEVEL="${KMGCCC_LOG_LEVEL:-info}"

# Kill any existing instance of the app
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

echo "========================================"
echo "Building $APP_NAME ($CONFIGURATION) via xcodebuild..."
echo "========================================"

xcodebuild \
    -project "$REPO_ROOT/kmgccc_player.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [ ! -d "$APP_BUNDLE" ]; then
    echo "error: build succeeded but App Bundle not found at: $APP_BUNDLE" >&2
    exit 1
fi

if [ ! -x "$APP_BINARY" ]; then
    echo "error: App binary not found or not executable at: $APP_BINARY" >&2
    exit 1
fi

echo "========================================"
echo "Launching $APP_NAME with KMGCCC_LOG_LEVEL=$KMGCCC_LOG_LEVEL..."
echo "========================================"

# Run the app binary directly to stream logs in the terminal
"$APP_BINARY"
