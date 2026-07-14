#!/bin/bash
set -euo pipefail

# Prepares optional local runtime resources for the app bundle. Runs as an
# Xcode build phase for Debug, Release, and Archive builds, and is also used
# by command-line builds.
#
# Behavior is controlled by build settings (typically provided through
# Config/LocalOverrides.xcconfig on this machine):
#
#   AUXILIARY_RESOURCE_ROOT  - local path to a runtime resource source.
#                              Empty/absent on a clean clone.
#   AUXILIARY_RESOURCE_MODE  - auto (default) | enabled | disabled.
#   AUXILIARY_RESOURCE_STRICT - YES | NO (default). When YES, a configured but
#                              unusable resource root fails the build instead
#                              of being skipped.
#
# A clean clone with no local override is the normal state: this script
# exits 0 and the build continues with the in-repo resources. No empty
# directory or placeholder is required.

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-kmgccc_player.app}"
RESOURCES="${APP}/Contents/Resources"
MODE="${AUXILIARY_RESOURCE_MODE:-auto}"
STRICT="${AUXILIARY_RESOURCE_STRICT:-NO}"
ROOT="${AUXILIARY_RESOURCE_ROOT:-}"

ART_BUNDLE="$RESOURCES/BKArt.bundle"
BOKEH_BUNDLE="$RESOURCES/BokehTransitionResources.bundle"
RUNTIME_BUNDLE="$RESOURCES/ArtRuntime.bundle"

# Clear any resources left by a previous build in this DerivedData directory so
# a later build without local resources does not inherit them.
rm -rf "$ART_BUNDLE" "$BOKEH_BUNDLE" "$RUNTIME_BUNDLE"

if [ "$MODE" = disabled ]; then
    echo "note: auxiliary resources disabled for this build"
    exit 0
fi

if [ "$MODE" != auto ] && [ "$MODE" != enabled ]; then
    echo "error: unsupported AUXILIARY_RESOURCE_MODE: $MODE" >&2
    exit 2
fi

if [ -z "$ROOT" ]; then
    if [ "$MODE" = enabled ]; then
        if [ "$STRICT" = YES ]; then
            echo "error: AUXILIARY_RESOURCE_ROOT is required when AUXILIARY_RESOURCE_MODE=enabled" >&2
            exit 1
        fi
        echo "note: auxiliary resource root not configured; skipping"
    fi
    exit 0
fi

if [ ! -d "$ROOT" ]; then
    if [ "$STRICT" = YES ]; then
        echo "error: auxiliary resource root is not a directory" >&2
        exit 1
    fi
    echo "note: auxiliary resource root not found; skipping"
    exit 0
fi

BUILDER="$ROOT/scripts/build_resources.sh"
if [ ! -x "$BUILDER" ]; then
    if [ "$STRICT" = YES ]; then
        echo "error: auxiliary resource builder is unavailable" >&2
        exit 1
    fi
    echo "note: auxiliary resource builder unavailable; skipping"
    exit 0
fi

[ -d "$APP" ] || {
    echo "error: target app is unavailable before resource preparation: $APP" >&2
    exit 1
}

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/myplayer-runtime-resources.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

"$BUILDER" --output "$STAGING_DIR"
for bundle in BKArt.bundle BokehTransitionResources.bundle ArtRuntime.bundle; do
    [ -d "$STAGING_DIR/$bundle" ] || {
        echo "error: resource builder did not produce $bundle" >&2
        exit 1
    }
    cp -R "$STAGING_DIR/$bundle" "$RESOURCES/$bundle"
done

if find "$RESOURCES" -type f \( \
    -iname '*.metal' -o -iname '*.swift' -o -iname '*.air' -o \
    -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o \
    -iname '*.heic' -o -iname '*.webp' \
\) -print -quit | grep -q .; then
    echo "error: resource preparation produced source or plaintext art" >&2
    exit 1
fi

# Xcode signs the final application after build phases. When signing is enabled,
# the runtime library is signed first and the manifest hash is updated afterward.
# For unsigned verification the artifact is left unchanged so its original hash
# remains valid.
RUNTIME_BINARY="$RESOURCES/ArtRuntime.bundle/Contents/MacOS/ArtRuntime"
if [ -f "$RUNTIME_BINARY" ]; then
    SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "$SIGN_IDENTITY" ]; then
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$RUNTIME_BINARY" >/dev/null
        MANIFEST="$RESOURCES/ArtRuntime.bundle/Contents/Resources/ArtRuntime.manifest.json"
        HASH="$(shasum -a 256 "$RUNTIME_BINARY" | awk '{print $1}')"
        if command -v jq >/dev/null 2>&1; then
            TMP_MANIFEST="${MANIFEST}.tmp"
            jq --arg hash "$HASH" '.librarySHA256 = $hash' "$MANIFEST" > "$TMP_MANIFEST"
            mv "$TMP_MANIFEST" "$MANIFEST"
        elif command -v python3 >/dev/null 2>&1; then
            MANIFEST="$MANIFEST" HASH="$HASH" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["MANIFEST"])
data = json.loads(path.read_text())
data["librarySHA256"] = os.environ["HASH"]
path.write_text(json.dumps(data, indent=2) + "\n")
PY
        else
            echo "error: jq or python3 is required to update the signed runtime manifest" >&2
            exit 1
        fi
    fi
fi

echo "note: runtime resources prepared"
