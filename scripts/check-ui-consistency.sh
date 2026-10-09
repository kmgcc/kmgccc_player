#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  printf '%s\n' \
    "Usage: ./scripts/check-ui-consistency.sh [--all] [--strict-copy] [path ...]" \
    "" \
    "Default mode checks added lines in changed tracked files and all lines in untracked files." \
    "--all checks the tracked UI source tree instead."
}

audit_all=0
strict_copy=0
explicit_paths=()
explicit_count=0

while (($# > 0)); do
  case "$1" in
    --all)
      audit_all=1
      ;;
    --strict-copy)
      strict_copy=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      while (($# > 0)); do
        explicit_paths+=("$1")
        explicit_count=$((explicit_count + 1))
        shift
      done
      break
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      explicit_paths+=("$1")
      explicit_count=$((explicit_count + 1))
      ;;
  esac
  shift
done

is_ui_source() {
  case "$1" in
    kmgccc_player/Views/*.swift|kmgccc_player/AppKit/*.swift|kmgccc_player/Services/*Dialog.swift|kmgccc_player/Utilities/*.swift)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

changed_paths() {
  if ((audit_all)); then
    git ls-files -- \
      'kmgccc_player/Views' \
      'kmgccc_player/AppKit' \
      'kmgccc_player/Services' \
      'kmgccc_player/Utilities'
  else
    {
      git diff --name-only --diff-filter=ACMRTUXB HEAD --
      git ls-files --others --exclude-standard
    } | sort -u
  fi
}

read_scan_content() {
  local path="$1"

  if ((audit_all)) || ((explicit_count > 0)); then
    sed -n '1,$p' "$path"
    return
  fi

  if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    git diff --no-ext-diff --unified=0 HEAD -- "$path" |
      sed -n '/^+++/! s/^+//p'
  else
    sed -n '1,$p' "$path"
  fi
}

report_matches() {
  local path="$1"
  local label="$2"
  local pattern="$3"
  local content="$4"
  local matches

  matches="$(printf '%s\n' "$content" | grep -nE "$pattern" || true)"
  [[ -n "$matches" ]] || return 0

  printf '[FAIL] %s: %s\n' "$path" "$label"
  printf '%s\n' "$matches" | sed 's/^/  /'
  violations=$((violations + 1))
}

report_copy_review() {
  local path="$1"
  local content="$2"
  local matches

  matches="$(printf '%s\n' "$content" |
    grep -nE '(Text|Button|Label)\([^"]*"[^"]*(不是|并非|不会|不要|不支持|无需|不需要|不能)[^"]*"' ||
    true)"
  [[ -n "$matches" ]] || return 0

  printf '[REVIEW] %s: user-facing copy may contain a reverse explanation\n' "$path"
  printf '%s\n' "$matches" | sed 's/^/  /'
  copy_reviews=$((copy_reviews + 1))
  if ((strict_copy)); then
    violations=$((violations + 1))
  fi
}

violations=0
copy_reviews=0
path_count=0

if ((explicit_count > 0)); then
  path_source="$(printf '%s\n' "${explicit_paths[@]}")"
else
  path_source="$(changed_paths)"
fi

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  [[ -f "$path" ]] || continue
  is_ui_source "$path" || continue

  content="$(read_scan_content "$path")"
  [[ -n "$content" ]] || continue
  path_count=$((path_count + 1))

  report_matches "$path" "shadow or glow is not allowed on app-owned UI" \
    '\.(shadow|shadowed|glow)[[:space:]]*\(' "$content"
  report_matches "$path" "stroke is not a default hierarchy treatment" \
    '\.(stroke|strokeBorder)[[:space:]]*\(' "$content"
  report_matches "$path" "system bordered button style must use the shared capsule style" \
    '\.buttonStyle\([[:space:]]*\.bordered(Prominent)?([[:space:]]|\)|,)' "$content"
  report_matches "$path" "checkbox toggle style does not satisfy the settings switch contract" \
    '\.toggleStyle\([[:space:]]*\.checkbox[[:space:]]*\)' "$content"
  report_copy_review "$path" "$content"
done <<< "$path_source"

if ((path_count == 0)); then
  printf 'RESULT: NOTHING TO CHECK (no added UI source lines to inspect)\n'
  exit 0
fi

if ((copy_reviews > 0)) && ((strict_copy == 0)); then
  printf '[INFO] %s copy review item(s) require human judgment; use --strict-copy to make them blocking.\n' "$copy_reviews"
fi

if ((violations > 0)); then
  printf 'RESULT: FAIL (%s blocking issue(s) across %s UI file(s))\n' "$violations" "$path_count"
  exit 1
fi

printf 'RESULT: PASS (%s UI file(s) inspected)\n' "$path_count"
