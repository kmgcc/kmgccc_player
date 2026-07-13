#!/usr/bin/env bash
set -euo pipefail

APP_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_AMLL_SOURCE="$APP_REPO_ROOT/Dependencies/Submodules/AMLLIntegration"
AMLL_SOURCE="${AMLL_SOURCE:-$DEFAULT_AMLL_SOURCE}"
AMLL_OUTPUT_DIR="${AMLL_OUTPUT_DIR:-$APP_REPO_ROOT/kmgccc_player/Resources/AMLL}"
PNPM_VERSION="11.1.0"

sanitize_bundle_paths() {
  local bundle
  for bundle in "$AMLL_OUTPUT_DIR"/amll-*.js; do
    [[ -f "$bundle" ]] || continue
    AMLL_SOURCE_PREFIX="${AMLL_SOURCE%/}/" /usr/bin/perl -0pi -e \
      's{\Q$ENV{AMLL_SOURCE_PREFIX}\E}{}g' "$bundle"
  done
}

canonicalize_css_module_prefix() {
  local generated_prefix=""
  generated_prefix="$(
    /usr/bin/perl -ne 'if (/"active": "([A-Za-z0-9_-]+)_active"/) { print $1; exit }' \
      "$AMLL_OUTPUT_DIR/amll-core.js"
  )"
  [[ -n "$generated_prefix" ]] || return 0
  GENERATED_PREFIX="${generated_prefix}_" /usr/bin/perl -0pi -e \
    's/\Q$ENV{GENERATED_PREFIX}\E/REXxza_/g' \
    "$AMLL_OUTPUT_DIR/amll-core.js" \
    "$AMLL_OUTPUT_DIR/style.css"
}

if [[ ! -e "$AMLL_SOURCE/.git" ]]; then
  echo "AMLL source repo not found: $AMLL_SOURCE" >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

mkdir -p "$AMLL_OUTPUT_DIR"

if [[ "${1:-}" == "--sanitize-existing" ]]; then
  sanitize_bundle_paths
  echo "Sanitized local build paths in existing AMLL bundles."
  exit 0
fi

cd "$AMLL_SOURCE/packages/core"
corepack "pnpm@$PNPM_VERSION" exec tsdown --config tsdown.myplayer.config.ts
corepack "pnpm@$PNPM_VERSION" exec tsdown --config tsdown.myplayer-background.config.ts

cd "$AMLL_SOURCE/packages/lyric"
corepack "pnpm@$PNPM_VERSION" exec tsdown --config tsdown.myplayer.config.ts

cp "$AMLL_SOURCE/packages/core/dist-myplayer/amll-core.mjs" "$AMLL_OUTPUT_DIR/amll-core.js"
cp "$AMLL_SOURCE/packages/core/dist-myplayer/style.css" "$AMLL_OUTPUT_DIR/style.css"
cp "$AMLL_SOURCE/packages/core/dist-myplayer-background/amll-background.mjs" "$AMLL_OUTPUT_DIR/amll-background.js"
cp "$AMLL_SOURCE/packages/lyric/dist-myplayer/amll-lyric.mjs" "$AMLL_OUTPUT_DIR/amll-lyric.js"

canonicalize_css_module_prefix
sanitize_bundle_paths

echo "Synced AMLL core, background, and parser bundles to $AMLL_OUTPUT_DIR"
