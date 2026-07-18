#!/usr/bin/env bash
# Textual hygiene check: detect references to unpublished-source / local-only
# repository and resource names in committed text.
#
# The release audit (audit_release_contents.sh) already guards file PATHS in
# the worktree, selected Git history, optional unreachable objects, and app bundles. This guard
# covers the words themselves in docs, comments, and scripts, so a stray
# mention in a comment or document cannot hint at local-only repositories or
# proprietary sources.
#
# Operational references (the release-audit detector, the gitignore exclusion
# patterns, and build-time exclude rules) are allowlisted because they must
# keep the exact names to function.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run from a Git checkout containing this script." >&2
  exit 2
}
cd "$repo_root"

patterns=(
  'PrivateArtSources'
  'EncryptedArtAssets'
  'encrypt_art_assets'
  'encrypted_asset_allowlist'
  'docs-private'
  'applemusic-like-lyrics-full-refractor'
  'applemusic-like-lyrics-full-custom-core'
  'LDDC-main'
)

# Files where these names are operationally required and therefore allowed:
# the gitignore exclusion patterns, the release-audit detector, the build-time
# exclude rules, and this detector itself.
allowlist=(
  '.gitignore'
  '.gitattributes'
  'scripts/audit_release_contents.sh'
  'scripts/build_app.sh'
  'scripts/verify_textual_hygiene.sh'
)

pat="$(IFS='|'; printf '%s' "${patterns[*]}")"
allowed="$(IFS='|'; printf '%s' "${allowlist[*]}")"

violations=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ "$f" =~ ^($allowed)$ ]] && continue
  [[ "$f" =~ ^(kmgccc_player/|Dependencies/) ]] && continue
  [[ "$f" =~ (^|/)(LICENSE|Licenses)($|/) ]] && continue
  [[ "$f" =~ \.(png|jpg|jpeg|heic|webp|icns|pdf|zip|ttf|otf|woff2?|metal|metallib|car|wav|mp3|xcassets)$ ]] && continue
  [[ "$f" == .gitmodules ]] && continue
  [[ -f "$f" ]] || continue
  if grep -nEiq "$pat" "$f"; then
    echo "TEXTUAL-HYGIENE-FAIL: $f"
    grep -nEi "$pat" "$f" | sed 's/^/  /'
    violations=$((violations + 1))
  fi
done < <(git ls-files)

if ((violations)); then
  echo "RESULT: FAIL ($violations file(s) reference unpublished-source names in text)"
  exit 1
fi
echo "RESULT: PASS (no unpublished-source names in committed text outside allowlisted files)"
