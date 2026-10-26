#!/usr/bin/env bash
# Standalone AVFoundation probe; compiles the production range resolver only.
# Usage: Tests/run_motion_artwork_loop_range_probe.sh square.mp4 tall.mp4
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/motion-range-probe.XXXXXX")"
trap 'rm -rf "$PROBE_OUTPUT_DIR"' EXIT
{
  echo 'import Foundation'
  echo 'import AVFoundation'
  sed -n '/^nonisolated enum MotionArtworkLoopRange {/,/^}/p' "$ROOT/kmgccc_player/Views/Common/MotionArtworkView.swift"
} > "$PROBE_OUTPUT_DIR/ProductionLoopRange.swift"
xcrun swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
  "$PROBE_OUTPUT_DIR/ProductionLoopRange.swift" \
  "$ROOT/Tests/MotionArtworkLoopRangeProbe.swift" \
  -o "$PROBE_OUTPUT_DIR/motion-range-probe"
"$PROBE_OUTPUT_DIR/motion-range-probe" "$@"
