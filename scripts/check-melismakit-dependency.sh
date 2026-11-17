#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$REPO_ROOT/kmgccc_player.xcodeproj/project.pbxproj"
RESOLVED_FILE="$REPO_ROOT/kmgccc_player.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
LOCAL_PACKAGE_PATH="${MELISMAKIT_LOCAL_PATH:-$REPO_ROOT/../MelismaKit}"
EXPECTED_SOURCE="${MELISMAKIT_EXPECTED_SOURCE:-auto}"
BUILD_LOG=""

usage() {
    printf '%s\n' \
        "Usage: ./scripts/check-melismakit-dependency.sh [--auto|--require-local|--require-remote] [--build-log path]" \
        "" \
        "By default, accept the local or remote MelismaKit reference configured in Xcode." \
        "Use --require-local or --require-remote to enforce a specific source."
}

fail() {
    printf 'DEPENDENCY-FAIL: %s\n' "$1" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
        --auto)
            EXPECTED_SOURCE="auto"
            ;;
        --require-local)
            EXPECTED_SOURCE="local"
            ;;
        --require-remote)
            EXPECTED_SOURCE="remote"
            ;;
        --build-log)
            shift
            [[ $# -gt 0 ]] || fail "--build-log requires a file path"
            BUILD_LOG="$1"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

case "$EXPECTED_SOURCE" in
    auto|local|remote) ;;
    *) fail "MELISMAKIT_EXPECTED_SOURCE must be auto, local or remote" ;;
esac

[[ -f "$PROJECT_FILE" ]] || fail "Xcode project file not found: $PROJECT_FILE"

has_remote_reference=0
has_local_reference=0
if rg -q 'XCRemoteSwiftPackageReference "melismakit"' "$PROJECT_FILE"; then
    has_remote_reference=1
fi
if rg -q 'XCLocalSwiftPackageReference "[^"]*(melismakit|MelismaKit)' "$PROJECT_FILE" ||
   rg -q 'relativePath = "[^"]*MelismaKit' "$PROJECT_FILE"; then
    has_local_reference=1
fi
if rg -q 'XCLocalSwiftPackageReference "[^"]*NativeLyrics' "$PROJECT_FILE" ||
   rg -q 'relativePath = "[^"]*NativeLyrics' "$PROJECT_FILE"; then
    fail "the Xcode project still references the old NativeLyrics checkout; point it at ../MelismaKit"
fi

if ((has_remote_reference == 1 && has_local_reference == 1)); then
    fail "the Xcode project contains both local and remote MelismaKit references. Select one source."
fi
if [[ "$EXPECTED_SOURCE" == "auto" ]]; then
    if ((has_remote_reference == 1)); then
        EXPECTED_SOURCE="remote"
    elif ((has_local_reference == 1)); then
        EXPECTED_SOURCE="local"
    else
        fail "the Xcode project has no MelismaKit package reference"
    fi
fi

resolved_pin=""
if [[ -f "$RESOLVED_FILE" ]]; then
    resolved_pin="$(rg -n -A8 '"identity" : "melismakit"' "$RESOLVED_FILE" || true)"
fi

REMOTE_SOURCE_PATTERN='SourcePackages[/\\]checkouts[/\\][Mm]elisma[Kk]it'
LOCAL_SOURCE_PATTERN='MelismaKit[/\\]Sources[/\\]MelismaKit'
if [[ -n "$BUILD_LOG" ]]; then
    [[ -f "$BUILD_LOG" ]] || fail "build log not found: $BUILD_LOG"
    if rg -q 'NativeLyrics[/\\]Sources[/\\]MelismaKit' "$BUILD_LOG"; then
        fail "build log still references the old NativeLyrics checkout path"
    fi
fi

if [[ "$EXPECTED_SOURCE" == "local" ]]; then
    [[ -d "$LOCAL_PACKAGE_PATH" ]] ||
        fail "local MelismaKit checkout not found: $LOCAL_PACKAGE_PATH"
    [[ -f "$LOCAL_PACKAGE_PATH/Package.swift" ]] ||
        fail "local checkout has no Package.swift: $LOCAL_PACKAGE_PATH"
    ((has_remote_reference == 0)) ||
        fail "the Xcode project still points MelismaKit to a remote package; switch the project dependency to the local MelismaKit checkout before testing"
    ((has_local_reference == 1)) ||
        fail "the Xcode project does not expose a local MelismaKit package reference"

    if [[ -n "$resolved_pin" ]]; then
        printf 'DEPENDENCY-NOTE: using the local Xcode reference. Package.resolved also contains a remote MelismaKit pin.\n'
    fi

    if [[ -n "$BUILD_LOG" ]]; then
        if rg -q "$REMOTE_SOURCE_PATTERN" "$BUILD_LOG"; then
            fail "build log still contains the remote SourcePackages/checkouts/melismakit path"
        fi
        if ! rg -q "$LOCAL_SOURCE_PATTERN" "$BUILD_LOG"; then
            printf 'DEPENDENCY-NOTE: no local MelismaKit source path in this log. Incremental builds may reuse cached outputs. Using the Xcode project reference.\n'
        fi
    fi

    local_revision="$(git -C "$LOCAL_PACKAGE_PATH" rev-parse --short HEAD 2>/dev/null || true)"
    [[ -n "$local_revision" ]] || fail "local MelismaKit checkout is not a readable Git worktree"
    printf 'DEPENDENCY-PASS: local MelismaKit source at %s (%s)\n' \
        "$LOCAL_PACKAGE_PATH" "$local_revision"
    exit 0
fi

((has_remote_reference == 1)) ||
    fail "remote MelismaKit was requested, but the Xcode project is not using its remote package reference"

if [[ -n "$BUILD_LOG" ]]; then
    if rg -v "$REMOTE_SOURCE_PATTERN" "$BUILD_LOG" | rg "$LOCAL_SOURCE_PATTERN" >/dev/null; then
        fail "build log contains a local MelismaKit source path while the project uses the remote package"
    fi
    if ! rg -q "$REMOTE_SOURCE_PATTERN" "$BUILD_LOG"; then
        printf 'DEPENDENCY-NOTE: no remote MelismaKit source path in this log. Incremental builds may reuse cached outputs. Using the Xcode project reference.\n'
    fi
fi

if [[ -n "$resolved_pin" ]]; then
    printf 'DEPENDENCY-PASS: remote MelismaKit resolution:\n%s\n' "$resolved_pin"
else
    printf 'DEPENDENCY-PASS: remote MelismaKit reference. Xcode manages package resolution during the build.\n'
fi
