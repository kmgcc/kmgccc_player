#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/kmgccc_player.xcodeproj"
SCHEME="kmgccc_player"
CONFIGURATION="Debug"
DERIVED_DATA_DIR="$ROOT_DIR/.codex/DerivedData/multi-library-storage"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/kmgccc_player.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/kmgccc_player"
APP_PROCESS_NAME="kmgccc_player"

worktree_instance_running() {
    local pid command
    while IFS= read -r pid; do
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command" == "$APP_EXECUTABLE"* ]]; then
            return 0
        fi
    done < <(pgrep -x "$APP_PROCESS_NAME" || true)
    return 1
}

stop_worktree_instance() {
    local pid command
    while IFS= read -r pid; do
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command" == "$APP_EXECUTABLE"* ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    done < <(pgrep -x "$APP_PROCESS_NAME" || true)
}

build_app() {
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        CODE_SIGNING_ALLOWED=NO \
        build
}

launch_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

verify_app() {
    local attempt
    for attempt in {1..20}; do
        if worktree_instance_running; then
            return 0
        fi
        sleep 0.25
    done
    echo "worktree app did not start: $APP_EXECUTABLE" >&2
    exit 1
}

stop_worktree_instance
build_app

case "$MODE" in
    run)
        launch_app
        ;;
    --debug|debug)
        lldb -- "$APP_EXECUTABLE"
        ;;
    --logs|logs)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_PROCESS_NAME\""
        ;;
    --telemetry|telemetry)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_PROCESS_NAME\""
        ;;
    --verify|verify)
        launch_app
        verify_app
        echo "worktree app is running: $APP_EXECUTABLE"
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
