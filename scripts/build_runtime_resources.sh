#!/bin/bash
set -euo pipefail

# Build a complete app with local runtime resources included.
#
# Normal Xcode builds (Debug, Release, Archive) already pick up local runtime
# resources automatically when Config/LocalOverrides.xcconfig is present. This
# script is a command-line convenience that forces the resources on (and is
# strict about their presence) and then verifies the resulting bundle.
#
# Requires a configured auxiliary resource root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIGURATION="${CONFIGURATION:-Release}"
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) echo "error: configuration must be Debug or Release" >&2; exit 2 ;;
esac

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/kmgccc-player-runtime-$CONFIGURATION}"
OUTPUT_DIR="${OUTPUT_DIR:-}"

rm -rf "$DERIVED_DATA_PATH"
xcodebuild \
    -project "$REPO_ROOT/kmgccc_player.xcodeproj" \
    -scheme kmgccc_player \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    AUXILIARY_RESOURCE_MODE=enabled \
    AUXILIARY_RESOURCE_STRICT=YES \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
    build

APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/kmgccc_player.app"
[ -d "$APP" ] || { echo "error: app was not produced: $APP" >&2; exit 1; }

RESOURCES="$APP/Contents/Resources"
for bundle in BKArt.bundle BokehTransitionResources.bundle ArtRuntime.bundle; do
    [ -d "$RESOURCES/$bundle" ] || {
        echo "error: app is missing runtime resource: $bundle" >&2
        exit 1
    }
done

if find "$RESOURCES" \( -type f -o -type d \) \( \
    -iname '*.metal' -o -iname '*.swift' -o -iname '*.png' -o -iname '*.jpg' \
    -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.webp' \
    -o -name 'PrivateArtSources' -o -iname '*.sh' -o -iname '*.air' \
\) -print -quit | grep -q .; then
    echo "error: app contains source, script, or plaintext art" >&2
    exit 1
fi

if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR/kmgccc_player.app"
    cp -R "$APP" "$OUTPUT_DIR/kmgccc_player.app"
    APP="$OUTPUT_DIR/kmgccc_player.app"
fi
printf '%s\n' "$APP"
