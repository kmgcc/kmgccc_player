#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT=""

usage() {
    cat >&2 <<'USAGE'
Usage: scripts/prepare_public_history.sh --output PATH

Creates a sanitized clone for public release. The current checkout is never
rewritten. Review the output and run verify_public_source.sh from that clone
before pushing it anywhere.
USAGE
}

while (($#)); do
    case "$1" in
        --output)
            (($# >= 2)) || { echo "error: --output requires a path" >&2; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

[ -n "$OUTPUT" ] || { echo "error: --output is required" >&2; exit 2; }
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd -P)/$(basename "$OUTPUT")"
case "$OUTPUT" in
    "$ROOT"|"$ROOT"/*)
        echo "error: output must be outside the current checkout" >&2
        exit 2
        ;;
esac
[ ! -e "$OUTPUT" ] || { echo "error: output already exists: $OUTPUT" >&2; exit 2; }

git clone --no-local --no-hardlinks "$ROOT" "$OUTPUT" >/dev/null
cd "$OUTPUT"

git filter-branch --force --prune-empty \
    --index-filter 'git rm -r --cached --ignore-unmatch \
        BKThemes \
        EncryptedArtAssets \
        PrivateArtSources \
        BKArt.bundle \
        PrivateArtRuntime.bundle \
        kmgccc_player/Resources/BKArt.bundle \
        kmgccc_player/Rendering/BokehTransition/BokehTransitionShader.metal \
        scripts/encrypt_art_assets.swift \
        scripts/encrypted_asset_allowlist.json' \
    --tag-name-filter cat -- --all >/dev/null

while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    git update-ref -d "$ref"
done < <(git for-each-ref --format='%(refname)' refs/original/)

git reflog expire --expire=now --all
git gc --prune=now --aggressive >/dev/null

printf '%s\n' "$OUTPUT"
