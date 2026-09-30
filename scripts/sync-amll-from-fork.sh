#!/usr/bin/env bash
set -euo pipefail

APP_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_AMLL_SOURCE="$APP_REPO_ROOT/Dependencies/Submodules/AMLLIntegration"
AMLL_SOURCE="${AMLL_SOURCE:-$DEFAULT_AMLL_SOURCE}"
AMLL_OUTPUT_DIR="${AMLL_OUTPUT_DIR:-$APP_REPO_ROOT/kmgccc_player/Resources/AMLL}"
PNPM_VERSION="11.1.0"

sanitize_bundle_paths() {
  local bundle="$AMLL_OUTPUT_DIR/amll-background.js"
  [[ -f "$bundle" ]] || return 0
  AMLL_SOURCE_PREFIX="${AMLL_SOURCE%/}/" /usr/bin/perl -0pi -e \
    's{\Q$ENV{AMLL_SOURCE_PREFIX}\E}{}g' "$bundle"
}

if [[ ! -e "$AMLL_SOURCE/.git" ]]; then
  echo "AMLL source repo not found: $AMLL_SOURCE" >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

# Build tools resolve macOS /tmp through /private/tmp before embedding source
# paths. Canonicalize the source first so sanitization removes the same prefix
# regardless of whether the checkout was reached through a symlinked directory.
AMLL_SOURCE="$(cd "$AMLL_SOURCE" && pwd -P)"

mkdir -p "$AMLL_OUTPUT_DIR"

if [[ "${1:-}" == "--sanitize-existing" ]]; then
  sanitize_bundle_paths
  echo "Sanitized local build paths in existing AMLL bundles."
  exit 0
fi

cd "$AMLL_SOURCE/packages/core"
corepack "pnpm@$PNPM_VERSION" exec tsdown --config tsdown.myplayer-background.config.ts

cp "$AMLL_SOURCE/packages/core/dist-myplayer-background/amll-background.mjs" "$AMLL_OUTPUT_DIR/amll-background.js"
sanitize_bundle_paths

echo "Synced AMLL background bundle to $AMLL_OUTPUT_DIR"
