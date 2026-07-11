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
PRIVATE_BUILDER="$PRIVATE_REPO_PATH/scripts/build_private_resources.sh"
[ -x "$PRIVATE_BUILDER" ] || { echo "error: missing executable: $PRIVATE_BUILDER" >&2; exit 1; }

CONFIGURATION="${CONFIGURATION:-PrivateDistribution}"
[ "$CONFIGURATION" = PrivateDistribution ] || {
    echo "error: private distribution requires CONFIGURATION=PrivateDistribution" >&2
    exit 2
}
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/kmgccc-player-private-PrivateDistribution}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kmgccc-private-distribution.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
"$PRIVATE_BUILDER" --output "$STAGING_DIR" >/dev/null
PRIVATE_ART_BUNDLE="$STAGING_DIR/BKArt.bundle"
PRIVATE_BOKEH_BUNDLE="$STAGING_DIR/BokehTransitionResources.bundle"
PRIVATE_RUNTIME_BUNDLE="$STAGING_DIR/PrivateArtRuntime.bundle"

if [ "${CLEAN_BUILD:-1}" = "1" ]; then
    rm -rf "$DERIVED_DATA_PATH"
fi
xcodebuild \
    -project "$REPO_ROOT/kmgccc_player.xcodeproj" \
    -scheme kmgccc_player \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    PRIVATE_RESOURCE_MODE=disabled \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
    build

APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/kmgccc_player.app"
[ -d "$APP" ] || { echo "error: private app was not produced: $APP" >&2; exit 1; }

PRIVATE_RESOURCES="$APP/Contents/Resources"
cp -R "$PRIVATE_ART_BUNDLE" "$PRIVATE_RESOURCES/BKArt.bundle"
cp -R "$PRIVATE_BOKEH_BUNDLE" "$PRIVATE_RESOURCES/BokehTransitionResources.bundle"
cp -R "$PRIVATE_RUNTIME_BUNDLE" "$PRIVATE_RESOURCES/PrivateArtRuntime.bundle"

if find "$PRIVATE_RESOURCES" \( -type f -o -type d \) \( \
    -iname '*.metal' -o -iname '*.swift' -o -iname '*.png' -o -iname '*.jpg' \
    -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.webp' \
    -o -name 'PrivateArtSources' -o -iname '*.sh' -o -iname '*.air' \
\) -print -quit | grep -q .; then
    echo "error: private app contains source, script, or plaintext art" >&2
    exit 1
fi
if find "$APP" -type f -iname '*.metal' -print -quit | grep -q .; then
    echo "error: app contains private source/master paths" >&2
    exit 1
fi
while IFS= read -r private_path; do
    case "$private_path" in
        */EncryptedArtAssets/BKThemes) ;;
        *)
            echo "error: app contains private source/master path: $private_path" >&2
            exit 1
            ;;
    esac
done < <(find "$APP" \( -type d -name 'PrivateArtSources' -o -type d -name 'BKThemes' \) -print)

if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR/kmgccc_player-private.app"
    cp -R "$APP" "$OUTPUT_DIR/kmgccc_player-private.app"
    APP="$OUTPUT_DIR/kmgccc_player-private.app"
fi
printf '%s\n' "$APP"
