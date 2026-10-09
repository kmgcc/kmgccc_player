#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  printf '%s\n' \
    "Usage: ./scripts/check-motion-consistency.sh [--all] [--strict] [path ...]" \
    "" \
    "Default mode reports changed Swift files and all untracked Swift files and prints RESULT: REPORT (findings are not enforced; exit code stays 0)." \
    "--all scans the full application Swift source tree." \
    "--strict exits non-zero for unallowlisted raw spring recipes, timing curves, raw dynamics, custom curves, direct MotionSpec constructors, policy bypasses, unparameterized animations, unbound transitions, AppKit timing groups, or Core Animation instances."
}

scan_all=0
strict=0
explicit_paths=()

while (($# > 0)); do
  case "$1" in
    --all)
      scan_all=1
      ;;
    --strict)
      strict=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      explicit_paths+=("$@")
      break
      ;;
    -* )
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      explicit_paths+=("$1")
      ;;
  esac
  shift
done

is_swift_source() {
  [[ "$1" == kmgccc_player/*.swift ]]
}

scan_paths() {
  if ((${#explicit_paths[@]} > 0)); then
    printf '%s\n' "${explicit_paths[@]}"
  elif ((scan_all)); then
    rg --files kmgccc_player -g '*.swift'
  else
    {
      git diff --name-only --diff-filter=ACMRTUXB HEAD --
      git ls-files --others --exclude-standard
    } | sort -u
  fi
}

is_allowlisted() {
  local path="$1"
  local line="$2"
  local text="$3"

  if [[ "$text" == *'.animation(nil'* ]]; then
    case "$path" in
      kmgccc_player/Views/Fullscreen/FullscreenMiniPlayerView.swift|\
      kmgccc_player/Views/Fullscreen/FullscreenPlayerView.swift|\
      kmgccc_player/Views/Controls/ExpandableVolumeControl.swift)
        printf 'explicit foreground rendering transaction isolation'
        return 0
        ;;
    esac
  fi

  if [[ "$text" == *'.transition(.identity'* ]]; then
    printf 'identity transition has no visual motion'
    return 0
  fi

  if [[ "$path" == kmgccc_player/Skins/NowPlaying/KmgcccCassetteSkin.swift && "$text" == *kmgLookTransitionAnimation* ]]; then
    printf 'registered cassette artwork transition'
    return 0
  fi

  case "$path" in
    kmgccc_player/Views/Controls/SeamlessMarqueeText.swift)
      if [[ "$text" == *'withAnimation(.linear'* ]]; then
        printf 'continuous marquee loop'
        return 0
      fi
      ;;
    kmgccc_player/Views/NowPlaying/LedMeterView.swift)
      if [[ "$text" == *'TimelineView(.animation'* ]]; then
        printf 'TimelineView cadence for meter rendering'
        return 0
      fi
      if [[ "$text" == *brightnessState* ]]; then
        printf 'high-frequency meter brightness follower'
        return 0
      fi
      ;;
    kmgccc_player/Skins/NowPlaying/CapsuleSpectrumHostView.swift)
      if [[ "$text" == *'///'* || "$text" == *'//'* ]]; then
        printf 'documentation for continuous spectrum follower'
        return 0
      fi
      if [[ "$text" == *CapsuleSpectrumDynamics* || "$text" == *MotionSpec* || "$text" == *response* || "$text" == *dampingFraction* ]]; then
        printf 'display-link spectrum follower dynamics'
        return 0
      fi
      ;;
    kmgccc_player/Skins/NowPlaying/KmgcccCassetteSkin.swift)
      if [[ "$text" == *kmgLookTransitionAnimation* ]]; then
        printf 'registered cassette artwork transition'
        return 0
      fi
      if [[ "$text" == *CA*Animation* || "$text" == *cassetteReel* || "$text" == *CAMediaTimingFunction* ]]; then
        printf 'cassette reel acceleration/deceleration and continuous rotation state machine'
        return 0
      fi
      ;;
    kmgccc_player/Views/NowPlaying/BKArtBackgroundView.swift)
      if [[ "$text" == *cubicBezier* || "$text" == *easeOutQuint* || "$text" == *easeInQuint* ]]; then
        printf 'continuous background particle choreography'
        return 0
      fi
      ;;
  esac

  return 1
}

findings=0
blocking_findings=0
scanned=0

report_match() {
  local kind="$1"
  local path="$2"
  local line="$3"
  local text="$4"
  local reason

  if reason="$(is_allowlisted "$path" "$line" "$text")"; then
    printf 'ALLOW  %-8s %s:%s — %s (%s)\n' "$kind" "$path" "$line" "$text" "$reason"
    return
  fi

  findings=$((findings + 1))
  if [[ "$kind" == "RAW_SPRING" || "$kind" == "TIMING_CURVE" || "$kind" == "RAW_PHYSICS" || "$kind" == "CUSTOM_CURVE" || "$kind" == "DIRECT_SPEC" || "$kind" == "UNPARAM_ANIM" || "$kind" == "UNBOUND_TRANSITION" || "$kind" == "APPKIT_TIMING" || "$kind" == "CA_ANIM" || "$kind" == "POLICY_BYPASS" ]]; then
    blocking_findings=$((blocking_findings + 1))
  fi
  printf 'REVIEW  %-8s %s:%s — %s\n' "$kind" "$path" "$line" "$text"
}

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  is_swift_source "$path" || continue
  [[ -f "$path" ]] || continue
  scanned=$((scanned + 1))
  motion_animation_count="$(rg -c --no-filename '\.motionAnimation' "$path" || true)"
  motion_animation_count="${motion_animation_count:-0}"

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    report_match "RAW_SPRING" "$path" "$line" "$text"
  done < <(rg -n '\.spring\((response|duration):|Animation\.spring' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    report_match "TIMING_CURVE" "$path" "$line" "$text"
  done < <(rg -n '\.(easeIn|easeOut|easeInOut|smooth|snappy|timingCurve)\(' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    report_match "RAW_PHYSICS" "$path" "$line" "$text"
  done < <(rg -n 'dampingFraction[[:space:]]*:' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    report_match "POLICY_BYPASS" "$path" "$line" "$text"
  done < <(rg -n '\b(if|guard|while|switch)[[:space:]]+!?[[:space:]]*reduceMotion\b|\breduceMotion[[:space:]]*(\?|==|!=|&&|\|\|)' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    report_match "CUSTOM_CURVE" "$path" "$line" "$text"
  done < <(rg -n 'cubicBezier|easeOutQuint|easeInQuint' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    report_match "DIRECT_SPEC" "$path" "$line" "$text"
  done < <(rg -n 'MotionSpec[[:space:]]*\(' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    [[ "$text" == *motionAnimation* ]] && continue
    [[ "$text" == *"policy.animation("* ]] && continue
    [[ "$text" == *"Policy.animation("* ]] && continue
    [[ "$text" == *"swiftUIAnimation("* ]] && continue
    [[ "$text" == *"coreAnimation("* ]] && continue
    report_match "IMPLICIT_ANIM" "$path" "$line" "$text"
  done < <(rg -n '\.animation\(' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    report_match "UNPARAM_ANIM" "$path" "$line" "$text"
  done < <(rg -n 'withAnimation[[:space:]]*\{' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    report_match "UNPARAM_ANIM" "$path" "$line" "$text"
  done < <(rg -n 'withAnimation[[:space:]]*\([[:space:]]*\)' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    if ((motion_animation_count == 0)); then
      report_match "UNBOUND_TRANSITION" "$path" "$line" "$text"
    fi
  done < <(rg -n '\.transition\(' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    report_match "CA_ANIM" "$path" "$line" "$text"
  done < <(rg -n 'CA(Basic|Keyframe|Spring)Animation' "$path" || true)

  while IFS=: read -r line text; do
    [[ -n "$line" ]] || continue
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    report_match "APPKIT_TIMING" "$path" "$line" "$text"
  done < <(rg -n 'NSAnimationContext|CAMediaTimingFunction' "$path" || true)
done < <(scan_paths)

printf '%s\n' "Scanned $scanned Swift file(s); $findings review finding(s); $blocking_findings strict finding(s)."

if ((strict && blocking_findings > 0)); then
  printf 'RESULT: FAIL (%s blocking finding(s), strict mode)\n' "$blocking_findings"
  exit 1
fi

if ((strict)); then
  printf 'RESULT: PASS (strict mode, 0 blocking finding(s))\n'
else
  printf 'RESULT: REPORT (%s blocking finding(s) not enforced; rerun with --strict to gate)\n' "$blocking_findings"
fi
