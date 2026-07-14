#!/usr/bin/env bash
# Audits release contents and Git history without printing file contents.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
invocation_dir="$(pwd -P)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run from a Git checkout containing this script." >&2
  exit 2
}
cd "$repo_root"

usage() {
  cat <<'USAGE'
Usage: scripts/audit_release_contents.sh [options]

Audits release contents: tracked paths, selected Git history, and optional .app bundles.
The audit prints only commit/ref/path/object metadata, never file contents.

Options:
  --ref <ref>       Audit one ref or commit; repeatable. Default: HEAD.
  --all-refs        Audit every local ref, remote ref, tag, stash, and tool ref.
  --reflogs         Include reflog-only commits for the selected checkout.
  --app <path>      Audit a built .app bundle; repeatable.
  -h, --help        Show this help.

Exit status: 0 clean, 1 prohibited material found, 2 invalid invocation or Git error.
USAGE
}

all_refs=0
include_reflogs=0
declare -a selected_refs=()
declare -a app_paths=()

while (($#)); do
  case "$1" in
    --ref)
      (($# >= 2)) || { echo "ERROR: --ref requires a value." >&2; exit 2; }
      selected_refs+=("$2")
      shift 2
      ;;
    --all-refs)
      all_refs=1
      shift
      ;;
    --reflogs)
      include_reflogs=1
      shift
      ;;
    --app)
      (($# >= 2)) || { echo "ERROR: --app requires a path." >&2; exit 2; }
      app_paths+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ((all_refs)) && ((${#selected_refs[@]})); then
  echo "ERROR: choose either --all-refs or one or more --ref options." >&2
  exit 2
fi

normalized_app_paths=()
for app in "${app_paths[@]:-}"; do
  [[ -n "$app" ]] || continue
  case "$app" in
    /*) normalized_app_paths+=("$app") ;;
    *) normalized_app_paths+=("$invocation_dir/$app") ;;
  esac
done
app_paths=("${normalized_app_paths[@]:-}")

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/myplayer-release-audit.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
ref_tips="$tmpdir/ref-tips.tsv"
commit_refs="$tmpdir/commit-refs.tsv"
: > "$ref_tips"

violations=0

record_failure() {
  local scope="$1"
  local ref="$2"
  local commit="$3"
  local path="$4"
  local risk="$5"
  printf 'FAIL scope=%s ref=%s commit=%s path=%s risk=%s\n' \
    "$scope" "$ref" "$commit" "$path" "$risk"
  violations=$((violations + 1))
}

path_risk() {
  local path="$1"
  local lower
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"

  case "/$lower/" in
    */privateartsources/*)
      printf '%s\n' 'art-source'
      return
      ;;
    */encryptedartassets/*)
      printf '%s\n' 'encrypted-art-runtime-resource'
      return
      ;;
    */bkthemes/*)
      printf '%s\n' 'art-master-or-theme'
      return
      ;;
    */privateartruntime.bundle|*/privateartruntime.bundle/*|privateartruntime.bundle)
      printf '%s\n' 'art-runtime-bundle'
      return
      ;;
    */bkart.bundle|*/bkart.bundle/*|bkart.bundle)
      printf '%s\n' 'art-bundle'
      return
      ;;
    */scripts/encrypt_art_assets.swift|*/scripts/encrypted_asset_allowlist.json)
      printf '%s\n' 'art-encryption-tooling'
      return
      ;;
  esac

  case "$lower" in
    */privateartruntimeloader.swift)
      # Loader boundary; the runtime implementation is packaged separately.
      return
      ;;
    *bokeh*.metal|*bokeh*.metallib|*/bokehtransition/*.metal|*/bokehtransition/*.metallib|*/privateshaders/*|*/privatebokeh/*)
      printf '%s\n' 'bokeh-metal-library'
      return
      ;;
    *privateart*|*private_art*|*privateartwork*|*private_artwork*|*privateassets*|*private_assets*)
      printf '%s\n' 'legacy-art-path'
      return
      ;;
    *encrypt_art_assets.swift|*encrypted_asset_allowlist.json|*encrypted*allowlist*.json)
      printf '%s\n' 'art-encryption-tooling'
      return
      ;;
  esac

  if [[ "$lower" =~ (bokeh|bktheme|bkart|encryptedart|privateart).*(backup|archive|copy|old|orig) ]] || \
     [[ "$lower" =~ (backup|archive|copy|old|orig).*(bokeh|bktheme|bkart|encryptedart|privateart) ]]; then
    printf '%s\n' 'art-material-backup-or-archive'
  fi
}

artifact_risk() {
  local path="$1"
  local lower
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" == *.metal ]]; then
    printf '%s\n' 'metal-source-in-app-bundle'
    return
  fi

  path_risk "$path"
}

scan_worktree() {
  local path risk
  while IFS= read -r -d '' path; do
    risk="$(path_risk "$path" || true)"
    if [[ -n "$risk" ]]; then
      record_failure 'worktree' 'WORKTREE' '-' "$path" "$risk"
    fi
  done < <(git ls-files -co --exclude-standard -z)
}

scan_known_restricted_worktree_roots() {
  local path risk
  for path in \
    'BKThemes' \
    'PrivateArtSources' \
    'EncryptedArtAssets' \
    'BKArt.bundle' \
    'ArtRuntime.bundle' \
    'kmgccc_player/Resources/BKArt.bundle'; do
    [[ -e "$path" ]] || continue
    risk="$(path_risk "$path" || true)"
    case "$path" in
      BKThemes) risk='art-master-or-theme' ;;
      PrivateArtSources) risk='art-source' ;;
      EncryptedArtAssets) risk='encrypted-art-runtime-resource' ;;
      ArtRuntime.bundle) risk='auxiliary-runtime-bundle' ;;
      *) risk='art-bundle' ;;
    esac
    record_failure 'worktree' 'WORKTREE' '-' "$path" "$risk"
  done
}

add_ref_tip() {
  local label="$1"
  local revision="$2"
  local commit
  commit="$(git rev-parse --verify "${revision}^{commit}" 2>/dev/null)" || {
    echo "ERROR: cannot resolve ref to a commit: $revision" >&2
    exit 2
  }
  printf '%s\t%s\n' "$label" "$commit" >> "$ref_tips"
}

collect_ref_tips() {
  local ref
  if ((all_refs)); then
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      add_ref_tip "$ref" "$ref"
    done < <(git for-each-ref --format='%(refname)')
  elif ((${#selected_refs[@]})); then
    for ref in "${selected_refs[@]}"; do
      add_ref_tip "$ref" "$ref"
    done
  else
    add_ref_tip 'HEAD' 'HEAD'
  fi
}

collect_commits() {
  local ref commit
  while IFS=$'\t' read -r ref commit; do
    while IFS= read -r commit; do
      printf '%s\t%s\n' "$commit" "$ref"
    done < <(git rev-list "$commit")
  done < "$ref_tips" > "$tmpdir/reachable-commit-refs.tsv"

  if ((include_reflogs)); then
    while IFS=$'\t' read -r commit ref; do
      [[ -n "$commit" && -n "$ref" ]] || continue
      if git cat-file -e "${commit}^{commit}" 2>/dev/null; then
        printf '%s\t%s\n' "$commit" "reflog:${ref}"
      fi
    done < <(git reflog show --all --format='%H%x09%gD') >> "$tmpdir/reachable-commit-refs.tsv"
  fi

  LC_ALL=C sort -k1,1 -u "$tmpdir/reachable-commit-refs.tsv" > "$commit_refs"
}

scan_history() {
  local commit path risk
  local -a history_args=()

  if ((all_refs)); then
    history_args+=(--all)
  elif ((${#selected_refs[@]})); then
    history_args+=("${selected_refs[@]}")
  else
    history_args+=(HEAD)
  fi
  ((include_reflogs)) && history_args+=(--reflog)

  # Walk the selected history in one Git process, and classify paths in one
  # awk process. Calling `tr` once per historical path made large audits slow.
  while IFS=$'\t' read -r commit path risk; do
    [[ -n "$commit" && -n "$path" && -n "$risk" ]] || continue
    record_failure 'history' 'reachable-history' "$commit" "$path" "$risk"
  done < <(
    git log --no-color --no-renames --format='COMMIT %H' --name-only "${history_args[@]}" |
      awk '
        /^COMMIT / { commit = $0; sub(/^COMMIT /, "", commit); next }
        NF {
          lower = tolower($0)
          risk = ""
          if (lower ~ /(^|\/)privateartsources(\/|$)/) risk = "art-source"
          else if (lower ~ /(^|\/)encryptedartassets(\/|$)/) risk = "encrypted-art-runtime-resource"
          else if (lower ~ /(^|\/)bkthemes(\/|$)/) risk = "art-master-or-theme"
          else if (lower ~ /(^|\/)bkart\.bundle(\/|$)/) risk = "art-bundle"
          else if (lower ~ /(^|\/)scripts\/encrypt_art_assets\.swift$/ || lower ~ /(^|\/)scripts\/encrypted_asset_allowlist\.json$/) risk = "art-encryption-tooling"
          else if (lower ~ /bokeh.*\.met(al|allib)$/ || lower ~ /(^|\/)bokehtransition\/.*\.met(al|allib)$/ || lower ~ /(^|\/)privateshaders(\/|$)/ || lower ~ /(^|\/)privatebokeh(\/|$)/) risk = "bokeh-metal-library"
          else if (lower ~ /(^|\/)privateartruntimeloader\.swift$/) risk = ""
          else if (lower ~ /privateart|private_art|privateartwork|private_artwork|privateassets|private_assets/) risk = "legacy-art-path"
          else if (lower ~ /(bokeh|bktheme|bkart|encryptedart|privateart).*(backup|archive|copy|old|orig)/ || lower ~ /(backup|archive|copy|old|orig).*(bokeh|bktheme|bkart|encryptedart|privateart)/) risk = "art-material-backup-or-archive"
          if (risk != "") print commit "\t" $0 "\t" risk
        }
      '
  )
}

scan_unreachable_objects() {
  local fsck_output="$tmpdir/fsck.txt"
  if ! git fsck --no-reflogs --unreachable --no-progress > "$fsck_output" 2>&1; then
    echo "ERROR: git fsck failed; resolve repository integrity errors before publishing." >&2
    return 2
  fi

  local state type object path risk
  while IFS=' ' read -r state type object; do
    [[ -n "$object" ]] || continue
    case "$type" in
      commit)
        while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          risk="$(path_risk "$path" || true)"
          if [[ -n "$risk" ]]; then
            record_failure 'unreachable-object' 'UNREACHABLE' "$object" "$path" "$risk"
          fi
        done < <(git ls-tree -r --name-only "$object")
        ;;
      tree|blob)
        record_failure 'unreachable-object' 'UNREACHABLE' "$object" '-' 'unattributed-git-object-review-required'
        ;;
    esac
  done < <(awk '/^(unreachable|dangling) (commit|tree|blob) / { print $1, $2, $3 }' "$fsck_output")
}

scan_app_bundles() {
  local app path relative risk
  # Bash 3.2 treats an empty declared array as unset under `set -u`.
  for app in "${app_paths[@]:-}"; do
    [[ -n "$app" ]] || continue
    [[ -d "$app" ]] || { echo "ERROR: app bundle not found: $app" >&2; exit 2; }
    while IFS= read -r -d '' path; do
      relative="${path#"$app"/}"
      risk="$(artifact_risk "$relative" || true)"
      if [[ -n "$risk" ]]; then
        record_failure 'app-bundle' "$app" '-' "$relative" "$risk"
      fi
    done < <(find "$app" -type f -print0)
  done
}

scan_worktree
scan_known_restricted_worktree_roots
collect_ref_tips
collect_commits
scan_history
scan_unreachable_objects
scan_app_bundles

if ((violations)); then
  printf 'RESULT: FAIL (%d prohibited path or object%s found)\n' \
    "$violations" "$([[ $violations -eq 1 ]] || printf 's')"
  exit 1
fi

echo 'RESULT: PASS (no prohibited paths, selected-history paths, or app-bundle entries found)'
