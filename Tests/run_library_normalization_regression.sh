#!/usr/bin/env bash
# Standalone regression runner for LibraryNormalization.
#
# The regression file lives outside the xcodebuild scheme on purpose: it
# compiles the normalization sources directly so grouping rules stay honest
# without dragging SwiftData/AppKit in. Keep the source list in sync with the
# real dependencies of LibraryNormalization.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/library_normalization_regression"

xcrun swiftc -parse-as-library \
  "$ROOT/kmgccc_player/Services/Library/LibraryTextNormalization.swift" \
  "$ROOT/kmgccc_player/Models/TrackCredit.swift" \
  "$ROOT/kmgccc_player/Services/Library/LibraryNormalization.swift" \
  "$ROOT/Tests/LibraryNormalizationRegressionTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
