#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$REPO_ROOT/kmgccc_player.xcodeproj/project.pbxproj"
RESOLVED_FILE="$REPO_ROOT/kmgccc_player.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
LOCAL_PACKAGE_PATH="${MELISMAKIT_LOCAL_PATH:-$REPO_ROOT/../NativeLyrics}"
EXPECTED_SOURCE="local"
BUILD_LOG=""

usage() {
    printf '%s\n' \
        "Usage: ./scripts/check-melismakit-dependency.sh [--require-local|--require-remote] [--build-log path]" \
        "" \
        "The default test-build policy requires the local NativeLyrics checkout." \
        "Use --require-remote only for an explicitly remote dependency build."
}

fail() {
    printf 'DEPENDENCY-FAIL: %s\n' "$1" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
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

[[ -f "$PROJECT_FILE" ]] || fail "Xcode project file not found: $PROJECT_FILE"
[[ -f "$RESOLVED_FILE" ]] || fail "Package.resolved not found: $RESOLVED_FILE"

has_remote_reference=0
has_local_reference=0
if rg -q 'XCRemoteSwiftPackageReference "melismakit"' "$PROJECT_FILE"; then
    has_remote_reference=1
fi
if rg -q 'XCLocalSwiftPackageReference "[^"]*(melismakit|NativeLyrics)' "$PROJECT_FILE" ||
   rg -q 'relativePath = "[^"]*NativeLyrics' "$PROJECT_FILE"; then
    has_local_reference=1
fi

resolved_pin="$(rg -n -A8 '"identity" : "melismakit"' "$RESOLVED_FILE" || true)"

if [[ "$EXPECTED_SOURCE" == "local" ]]; then
    [[ -d "$LOCAL_PACKAGE_PATH" ]] ||
        fail "local MelismaKit checkout not found: $LOCAL_PACKAGE_PATH"
    [[ -f "$LOCAL_PACKAGE_PATH/Package.swift" ]] ||
        fail "local checkout has no Package.swift: $LOCAL_PACKAGE_PATH"
    ((has_remote_reference == 0)) ||
        fail "the Xcode project still points MelismaKit to a remote package; switch the project dependency to the local NativeLyrics checkout before testing"
    ((has_local_reference == 1)) ||
        fail "the Xcode project does not expose a local NativeLyrics/MelismaKit package reference"

    if [[ -n "$resolved_pin" ]]; then
        printf 'DEPENDENCY-REVIEW: Package.resolved still contains a remote MelismaKit pin; the local project reference remains authoritative:\n%s\n' "$resolved_pin" >&2
    fi

    if [[ -n "$BUILD_LOG" ]]; then
        [[ -f "$BUILD_LOG" ]] || fail "build log not found: $BUILD_LOG"
        rg -q 'NativeLyrics/Sources/MelismaKit|NativeLyrics[/\\]Sources[/\\]MelismaKit' "$BUILD_LOG" ||
            fail "build log does not show compiler input from the local NativeLyrics/Sources/MelismaKit path"
        if rg -q 'SourcePackages[/\\]checkouts[/\\]melismakit' "$BUILD_LOG"; then
            fail "build log still contains the remote SourcePackages/checkouts/melismakit path"
        fi
    fi

    local_revision="$(git -C "$LOCAL_PACKAGE_PATH" rev-parse --short HEAD 2>/dev/null || true)"
    [[ -n "$local_revision" ]] || fail "local NativeLyrics checkout is not a readable Git worktree"
    printf 'DEPENDENCY-PASS: local MelismaKit source at %s (NativeLyrics %s)\n' \
        "$LOCAL_PACKAGE_PATH" "$local_revision"
    exit 0
fi

((has_remote_reference == 1)) ||
    fail "remote MelismaKit was requested, but the Xcode project is not using its remote package reference"
[[ -n "$resolved_pin" ]] ||
    fail "remote MelismaKit was requested, but Package.resolved has no MelismaKit pin"

if [[ -n "$BUILD_LOG" ]]; then
    [[ -f "$BUILD_LOG" ]] || fail "build log not found: $BUILD_LOG"
    rg -q 'SourcePackages[/\\]checkouts[/\\]melismakit' "$BUILD_LOG" ||
        fail "build log does not show compiler input from SourcePackages/checkouts/melismakit"
fi

printf 'DEPENDENCY-PASS: remote MelismaKit resolution:\n%s\n' "$resolved_pin"
