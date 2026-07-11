#!/bin/bash
set -euo pipefail

# This phase is intentionally public. It only knows how to call the private
# repository's artifact builder when that repository is present locally.
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-kmgccc_player.app}"
RESOURCES="${APP}/Contents/Resources"
PRIVATE_RESOURCE_MODE="${PRIVATE_RESOURCE_MODE:-auto}"
STRICT="${PRIVATE_RESOURCE_STRICT:-NO}"

PRIVATE_ART_BUNDLE="$RESOURCES/BKArt.bundle"
PRIVATE_BOKEH_BUNDLE="$RESOURCES/BokehTransitionResources.bundle"
PRIVATE_RUNTIME_BUNDLE="$RESOURCES/PrivateArtRuntime.bundle"

# Prevent a previous private build in the same DerivedData directory from
# silently turning a later public build into a private build.
rm -rf "$PRIVATE_ART_BUNDLE" "$PRIVATE_BOKEH_BUNDLE" "$PRIVATE_RUNTIME_BUNDLE"

if [ "$PRIVATE_RESOURCE_MODE" = disabled ]; then
    echo "note: private enhancement injection disabled for this build"
    exit 0
fi

if [ "$PRIVATE_RESOURCE_MODE" != auto ] && [ "$PRIVATE_RESOURCE_MODE" != enabled ]; then
    echo "error: unsupported PRIVATE_RESOURCE_MODE: $PRIVATE_RESOURCE_MODE" >&2
    exit 2
fi

if [ "$PRIVATE_RESOURCE_MODE" = auto ] && [ -z "${PRIVATE_REPO_PATH+x}" ]; then
    PRIVATE_REPO_PATH="${PROJECT_DIR}/../myPlayer2-private"
else
    PRIVATE_REPO_PATH="${PRIVATE_REPO_PATH:-}"
fi

if [ ! -d "$PRIVATE_REPO_PATH" ]; then
    echo "note: private enhancement repository not found; using public fallback"
    exit 0
fi

PRIVATE_BUILDER="$PRIVATE_REPO_PATH/scripts/build_private_resources.sh"
if [ ! -x "$PRIVATE_BUILDER" ]; then
    if [ "$STRICT" = YES ]; then
        echo "error: private enhancement builder is missing: $PRIVATE_BUILDER" >&2
        exit 1
    fi
    echo "warning: private enhancement builder is unavailable; using public fallback"
    exit 0
fi

[ -d "$APP" ] || {
    echo "error: target app is unavailable before private resource injection: $APP" >&2
    exit 1
}

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/myplayer-private-xcode.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

"$PRIVATE_BUILDER" --output "$STAGING_DIR"
for bundle in BKArt.bundle BokehTransitionResources.bundle PrivateArtRuntime.bundle; do
    [ -d "$STAGING_DIR/$bundle" ] || {
        echo "error: private builder did not produce $bundle" >&2
        exit 1
    }
    cp -R "$STAGING_DIR/$bundle" "$RESOURCES/$bundle"
done

if find "$RESOURCES" -type f \( \
    -iname '*.metal' -o -iname '*.swift' -o -iname '*.air' -o \
    -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o \
    -iname '*.heic' -o -iname '*.webp' \
\) -print -quit | grep -q .; then
    echo "error: private resource injection produced source or plaintext art" >&2
    exit 1
fi

# Xcode signs the final application after build phases. When signing is enabled,
# the nested runtime is signed first and the manifest hash is updated afterward.
# For unsigned verification we keep the artifact unchanged so its original hash
# remains valid.
RUNTIME_BINARY="$RESOURCES/PrivateArtRuntime.bundle/Contents/MacOS/PrivateArtRuntime"
if [ -f "$RUNTIME_BINARY" ]; then
    SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "$SIGN_IDENTITY" ]; then
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$RUNTIME_BINARY" >/dev/null
        MANIFEST="$RESOURCES/PrivateArtRuntime.bundle/Contents/Resources/PrivateArtRuntime.manifest.json"
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

echo "note: private Bokeh, art runtime, and encrypted art resources injected"
