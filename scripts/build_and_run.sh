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
KMGCCC_DEBUG_PERF="${KMGCCC_DEBUG_PERF:-0}"
PROCESS_PREFLIGHT="$SCRIPT_DIR/check-app-process-state.sh"
DEPENDENCY_PREFLIGHT="$SCRIPT_DIR/check-melismakit-dependency.sh"
MELISMAKIT_EXPECTED_SOURCE="${MELISMAKIT_EXPECTED_SOURCE:-local}"
BUILD_LOG="${KMGCCC_BUILD_LOG:-$REPO_ROOT/build/logs/build_and_run-$(date +%Y%m%d-%H%M%S)-$$.log}"
RUN_LOCK_DIR="${KMGCCC_RUN_LOCK_DIR:-${TMPDIR:-/tmp}/kmgccc-player-build-and-run.lock}"
RUN_LOCK_HELD=0

case "$MELISMAKIT_EXPECTED_SOURCE" in
    local|remote) ;;
    *)
        echo "error: MELISMAKIT_EXPECTED_SOURCE must be local or remote" >&2
        exit 2
        ;;
esac

case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

dependency_preflight_args() {
    if [[ "$MELISMAKIT_EXPECTED_SOURCE" == "remote" ]]; then
        printf '%s\n' --require-remote
    else
        printf '%s\n' --require-local
    fi
}

release_run_lock() {
    local owner_pid

    if ((RUN_LOCK_HELD == 0)); then
        return 0
    fi

    owner_pid="$(/bin/cat "$RUN_LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$owner_pid" == "$$" ]]; then
        /bin/rm -f "$RUN_LOCK_DIR/pid"
        /bin/rmdir "$RUN_LOCK_DIR" 2>/dev/null || true
    fi
    RUN_LOCK_HELD=0
}

acquire_run_lock() {
    local owner_pid

    if /bin/mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
        RUN_LOCK_HELD=1
        trap release_run_lock EXIT
        printf '%s\n' "$$" >"$RUN_LOCK_DIR/pid"
        return 0
    fi

    owner_pid="$(/bin/cat "$RUN_LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! /bin/kill -0 "$owner_pid" 2>/dev/null; then
        /bin/rm -f "$RUN_LOCK_DIR/pid"
        /bin/rmdir "$RUN_LOCK_DIR" 2>/dev/null || true
        if /bin/mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
            RUN_LOCK_HELD=1
            trap release_run_lock EXIT
            printf '%s\n' "$$" >"$RUN_LOCK_DIR/pid"
            return 0
        fi
    fi

    if [[ -n "$owner_pid" ]]; then
        echo "error: another build_and_run.sh process owns the run lock (PID $owner_pid)" >&2
    else
        echo "error: another build_and_run.sh process owns the run lock at $RUN_LOCK_DIR" >&2
    fi
    exit 4
}

prepare_for_test() {
    if ! "$PROCESS_PREFLIGHT" --terminate-existing; then
        echo "error: could not clear existing $APP_NAME process(es); refusing to launch another instance." >&2
        exit 3
    fi
}

running_pids() {
    /usr/bin/pgrep -x "$APP_NAME" || true
}

wait_for_single_process() {
    local attempt
    local pids
    local pid_count

    for attempt in {1..40}; do
        pids="$(running_pids)"
        pid_count=0
        for _ in $pids; do
            pid_count=$((pid_count + 1))
        done

        if ((pid_count == 1)); then
            echo "Verified exactly one running process: $APP_NAME"
            /bin/ps -ww -p "$pids" -o pid=,ppid=,user=,lstart=,command=
            return 0
        fi

        if ((pid_count > 1)); then
            echo "error: more than one $APP_NAME process appeared after launch; clearing all exact matches." >&2
            "$PROCESS_PREFLIGHT" --terminate-existing || true
            return 1
        fi
        sleep 0.25
    done

    echo "error: $APP_NAME did not remain running after launch" >&2
    return 1
}

acquire_run_lock

"$DEPENDENCY_PREFLIGHT" "$(dependency_preflight_args)"

# The library is exclusive. The main test entry has explicit authorization to
# end exact matching app processes before building and again before launching.
prepare_for_test

echo "========================================"
echo "Building $APP_NAME ($CONFIGURATION) via xcodebuild..."
echo "========================================"

mkdir -p "$(dirname "$BUILD_LOG")"
if ! xcodebuild \
    -project "$REPO_ROOT/kmgccc_player.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}" \
    -verbose \
    build >"$BUILD_LOG" 2>&1; then
    echo "error: xcodebuild failed; recent output:" >&2
    tail -n 100 "$BUILD_LOG" >&2 || true
    echo "Full build log: $BUILD_LOG" >&2
    exit 1
fi

echo "Build log: $BUILD_LOG"
"$DEPENDENCY_PREFLIGHT" "$(dependency_preflight_args)" --build-log "$BUILD_LOG"

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
            --env "KMGCCC_DEBUG_PERF=$KMGCCC_DEBUG_PERF" \
            "$APP_BUNDLE" \
            --args "$@"
    else
        /usr/bin/open -n \
            --env "KMGCCC_LOG_LEVEL=$KMGCCC_LOG_LEVEL" \
            --env "KMGCCC_DEBUG_PERF=$KMGCCC_DEBUG_PERF" \
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

prepare_for_test

if [ "$#" -gt 0 ]; then
    shift
fi
case "$MODE" in
    run)
        open_app "$@"
        wait_for_single_process
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app "$@"
        wait_for_single_process
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app "$@"
        wait_for_single_process
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app "$@"
        wait_for_single_process
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
