#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT=""

usage() {
    cat >&2 <<'USAGE'
Usage: scripts/prepare_public_history.sh --output PATH

Creates a sanitized clone for a public release. The current checkout is never
rewritten. The generated clone removes disallowed resources, build caches,
historical key material, and internal release wording from every reachable ref.
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

# The source checkout may contain stale remote-tracking refs. They are not
# public refs and must not keep the old object graph alive in the release clone.
while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if git symbolic-ref --quiet "$ref" >/dev/null 2>&1; then
        git symbolic-ref --delete "$ref"
    else
        git update-ref -d "$ref"
    fi
done < <(git for-each-ref --format='%(refname)' refs/remotes/)

# Keep the public README stable across rewritten historical commits. This
# prevents an old release description from reintroducing internal layout.
SAFE_README_BLOB="$(git hash-object -w README.md)"
export SAFE_README_BLOB

export FILTER_BRANCH_SQUELCH_WARNING=1
git filter-branch --force --prune-empty \
    --index-filter '
        git rm -r --cached --ignore-unmatch \
            BKThemes \
            EncryptedArtAssets \
            PrivateArtSources \
            BKArt.bundle \
            PrivateArtRuntime.bundle \
            .derivedData \
            .derivedDataAudioAudit \
            .derivedDataLocal \
            .derivedDataCodex \
            .derivedDataCodexHeaderCache \
            .derivedDataCodexRename \
            .derivedDataCodexResourceAudit \
            .derivedDataLocal2 \
            LDDC_Fetch_Core/.venv_arm64 \
            LDDC_Fetch_Core/.venv_x86_64 \
            LDDC_Fetch_Core/build_arm64 \
            LDDC_Fetch_Core/build_x86_64 \
            build \
            kmgccc_player/Resources/BKArt.bundle \
            kmgccc_player/Rendering/BokehTransition/BokehTransitionShader.metal \
            scripts/encrypt_art_assets.swift \
            scripts/encrypted_asset_allowlist.json >/dev/null 2>&1 || true

        for generated_root in $(
            git ls-files | grep -E "^\\.derivedData[^/]*(/|$)" | sed -e "s#/.*##" | sort -u || true
        ); do
            [ -n "$generated_root" ] || continue
            git rm -r --cached --ignore-unmatch "$generated_root" >/dev/null 2>&1 || true
        done

        if git ls-files --error-unmatch README.md >/dev/null 2>&1; then
            git update-index --add --cacheinfo 100644,"$SAFE_README_BLOB",README.md
        fi

        for loader in $(
            git ls-files | grep -E "(^|/)Services/Theme/EncryptedArtAssetLoader\\.swift$" || true
        ); do
            [ -n "$loader" ] || continue
            temporary_blob="$(mktemp)"
            git show ":$loader" | perl -0pe "
                s/let ([abcd]): \[UInt8\] = \[[^\]]*\]/let \\$1: [UInt8] = []/g;
                s/kmgccc-player-art-assets-[A-Za-z0-9_-]+/public-art-assets-v1/g;
                s/embedded[A-Za-z]*KeyMaterial/publicKeyMaterial/g;
            " > "$temporary_blob"
            sanitized_blob="$(git hash-object -w "$temporary_blob")"
            git update-index --add --cacheinfo 100644,"$sanitized_blob",$loader
            rm -f "$temporary_blob"
        done
    ' \
    --msg-filter "perl -0pe '
        s/myPlayer2-private/external-resources/gi;
        s/private repository/external resource source/gi;
        s/private enhancement/external enhancement/gi;
        s/public\/private source separation/resource boundary/gi;
        s/encrypted art/art resources/gi;
        s/private/external/gi;
    '" \
    --tag-name-filter cat -- --all >/dev/null

while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    git update-ref -d "$ref"
done < <(git for-each-ref --format='%(refname)' refs/original/)

git reflog expire --expire=now --all
git gc --prune=now --aggressive >/dev/null

printf '%s\n' "$OUTPUT"
