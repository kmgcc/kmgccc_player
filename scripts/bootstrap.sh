#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AMLL_DIR="$ROOT/applemusic-like-lyrics-kmgcccplayer-integration"

if [ ! -f "$AMLL_DIR/package.json" ]; then
  echo "AMLL integration is missing or incomplete."
  echo "Initializing Git submodules..."
  git -C "$ROOT" submodule update --init --recursive
fi

if [ ! -f "$AMLL_DIR/package.json" ]; then
  echo "ERROR: AMLL integration is still missing after submodule init." >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

echo "Bootstrap complete. AMLL integration is present."
