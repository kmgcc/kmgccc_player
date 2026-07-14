#!/bin/bash
set -euo pipefail

# Build the app without local runtime resources.
#
# Forces auxiliary resources off even when Config/LocalOverrides.xcconfig is
# present on this machine, and verifies that no runtime resources are included
# in the bundle. A fresh clone with no local override produces the same result
# through a normal Xcode build.

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
rm -rf "$DERIVED_DATA_PATH"

xcodebuild \
    -project "$PROJECT" \
    -scheme kmgccc_player \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    AUXILIARY_RESOURCE_MODE=disabled \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
    build

[ -d "$APP" ] || { echo "error: app was not produced: $APP" >&2; exit 1; }

if find "$APP" \( -type f -o -type d \) \( \
    -iname '*.metal' -o -name 'EncryptedArtAssets' -o -name 'PrivateArtSources' \
    -o -name 'BKArt.bundle' -o -name 'BKThemes' \
    -o -name 'BokehTransitionResources.bundle' -o -name 'ArtRuntime.bundle' \
    -o -iname '*.metallib' \
\) -print -quit | grep -q .; then
    echo "error: app contains disallowed runtime resources" >&2
    exit 1
fi

if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR/kmgccc_player.app"
    cp -R "$APP" "$OUTPUT_DIR/kmgccc_player.app"
    APP="$OUTPUT_DIR/kmgccc_player.app"
fi
printf '%s\n' "$APP"
