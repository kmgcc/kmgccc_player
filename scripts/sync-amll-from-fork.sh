#!/usr/bin/env bash
set -euo pipefail

APP_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_AMLL_SOURCE="/Users/kmg/Documents/vscode/player/myPlayer2/applemusic-like-lyrics-kmgcccplayer-integration"
AMLL_SOURCE="${AMLL_SOURCE:-$DEFAULT_AMLL_SOURCE}"
APP_AMLL_DIR="$APP_REPO_ROOT/myPlayer2/Resources/AMLL"

if [[ ! -d "$AMLL_SOURCE/.git" ]]; then
  echo "AMLL source repo not found: $AMLL_SOURCE" >&2
  exit 1
fi

if [[ ! -d "$APP_AMLL_DIR" ]]; then
  echo "App AMLL resource dir not found: $APP_AMLL_DIR" >&2
  exit 1
fi

cd "$AMLL_SOURCE/packages/core"
pnpm exec tsdown --config tsdown.myplayer.config.ts
pnpm exec tsdown --config tsdown.myplayer-background.config.ts

cd "$AMLL_SOURCE/packages/lyric"
pnpm exec tsdown --config tsdown.myplayer.config.ts

cp "$AMLL_SOURCE/packages/core/dist-myplayer/amll-core.mjs" "$APP_AMLL_DIR/amll-core.js"
cp "$AMLL_SOURCE/packages/core/dist-myplayer/style.css" "$APP_AMLL_DIR/style.css"
cp "$AMLL_SOURCE/packages/core/dist-myplayer-background/amll-background.mjs" "$APP_AMLL_DIR/amll-background.js"
cp "$AMLL_SOURCE/packages/lyric/dist-myplayer/amll-lyric.mjs" "$APP_AMLL_DIR/amll-lyric.js"

echo "Synced AMLL core, background, and parser bundles to $APP_AMLL_DIR"
