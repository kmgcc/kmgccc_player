#!/usr/bin/env bash
set -euo pipefail

# Default configuration is Debug
CONFIGURATION="${CONFIGURATION:-Debug}"
MODE="${1:-run}"
APP_NAME="kmgccc_player"
BUNDLE_ID="kmgccc.player"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/build/DerivedData}"
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
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}" \
    build

if [ ! -d "$APP_BUNDLE" ]; then
    echo "error: build succeeded but App Bundle not found at: $APP_BUNDLE" >&2
    exit 1
fi

if [ ! -x "$APP_BINARY" ]; then
    echo "error: App binary not found or not executable at: $APP_BINARY" >&2
    exit 1
fi

open_app() {
    if [ "$#" -gt 0 ]; then
        /usr/bin/open -n \
            --env "KMGCCC_LOG_LEVEL=$KMGCCC_LOG_LEVEL" \
            "$APP_BUNDLE" \
            --args "$@"
    else
        /usr/bin/open -n \
            --env "KMGCCC_LOG_LEVEL=$KMGCCC_LOG_LEVEL" \
            "$APP_BUNDLE"
    fi
}

# System spatial audio treats the process as a regular media app only when it
# has a real development/distribution signature and is launched through
# LaunchServices. Verify the produced bundle before opening it.
if [ -e "$APP_BUNDLE/Contents/_CodeSignature/CodeResources" ]; then
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
fi

echo "========================================"
echo "Launching $APP_BUNDLE..."
echo "========================================"

if [ "$#" -gt 0 ]; then
    shift
fi
case "$MODE" in
    run)
        open_app "$@"
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app "$@"
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app "$@"
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app "$@"
        for _ in {1..20}; do
            if pgrep -x "$APP_NAME" >/dev/null; then
                echo "Verified running process: $APP_NAME"
                exit 0
            fi
            sleep 0.25
        done
        echo "error: $APP_NAME did not remain running after launch" >&2
        exit 1
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
