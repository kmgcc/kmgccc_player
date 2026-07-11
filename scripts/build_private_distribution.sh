#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${PRIVATE_REPO_PATH:-}" ]; then
    echo "error: PRIVATE_REPO_PATH must be explicitly provided" >&2
    exit 2
fi
if [ ! -d "$PRIVATE_REPO_PATH" ]; then
    echo "error: PRIVATE_REPO_PATH is not a directory: $PRIVATE_REPO_PATH" >&2
    exit 2
fi
PRIVATE_REPO_PATH="$(cd "$PRIVATE_REPO_PATH" && pwd)"
BUILD_METALLIB="$PRIVATE_REPO_PATH/scripts/build_bokeh_metallib.sh"
ASSEMBLE_BUNDLE="$PRIVATE_REPO_PATH/scripts/assemble_private_bundle.sh"
[ -x "$BUILD_METALLIB" ] || { echo "error: missing executable: $BUILD_METALLIB" >&2; exit 1; }
[ -x "$ASSEMBLE_BUNDLE" ] || { echo "error: missing executable: $ASSEMBLE_BUNDLE" >&2; exit 1; }

CONFIGURATION="${CONFIGURATION:-PrivateDistribution}"
[ "$CONFIGURATION" = PrivateDistribution ] || {
    echo "error: private distribution requires CONFIGURATION=PrivateDistribution" >&2
    exit 2
}
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/kmgccc-player-private-PrivateDistribution}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kmgccc-private-distribution.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

METALLIB="$STAGING_DIR/BokehTransition.metallib"
PRIVATE_BUNDLE="$STAGING_DIR/BKArt.bundle"
"$BUILD_METALLIB" --output "$METALLIB" >/dev/null
"$ASSEMBLE_BUNDLE" --output "$PRIVATE_BUNDLE" >/dev/null

rm -rf "$DERIVED_DATA_PATH"
xcodebuild \
    -project "$REPO_ROOT/kmgccc_player.xcodeproj" \
    -scheme kmgccc_player \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
    build

APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/kmgccc_player.app"
[ -d "$APP" ] || { echo "error: private app was not produced: $APP" >&2; exit 1; }

PRIVATE_RESOURCES="$APP/Contents/Resources/Private"
mkdir -p "$PRIVATE_RESOURCES"
cp -R "$PRIVATE_BUNDLE" "$PRIVATE_RESOURCES/BKArt.bundle"
cp "$METALLIB" "$PRIVATE_RESOURCES/BokehTransition.metallib"

# Current Swift uses makeDefaultLibrary(); keep the named private artifact and
# provide the compatibility name until the loader accepts an explicit bundle.
cp "$METALLIB" "$APP/Contents/Resources/default.metallib"

if find "$PRIVATE_RESOURCES" \( -type f -o -type d \) \( \
    -iname '*.metal' -o -iname '*.swift' -o -iname '*.png' -o -iname '*.jpg' \
    -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.webp' \
    -o -name 'PrivateArtSources' -o -iname '*.sh' \
\) -print -quit | grep -q .; then
    echo "error: private app contains source, script, or plaintext art" >&2
    exit 1
fi
if find "$APP" \( -type f -o -type d \) \( \
    -iname '*.metal' -o -name 'PrivateArtSources' -o -name 'BKThemes' \
\) -print -quit | grep -q .; then
    echo "error: app contains private source/master paths" >&2
    exit 1
fi

if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR/kmgccc_player-private.app"
    cp -R "$APP" "$OUTPUT_DIR/kmgccc_player-private.app"
    APP="$OUTPUT_DIR/kmgccc_player-private.app"
fi
printf '%s\n' "$APP"
