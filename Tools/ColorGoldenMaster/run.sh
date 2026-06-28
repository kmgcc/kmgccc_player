#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"
BIN="${BUILD_DIR}/color-golden-master"

mkdir -p "${BUILD_DIR}" "${SCRIPT_DIR}/.generated"

cd "${REPO_ROOT}"

xcrun --sdk macosx swiftc \
  -D DEBUG \
  -Onone \
  -parse-as-library \
  -module-name ColorGoldenMaster \
  "${SCRIPT_DIR}/Sources/ProductionLogShim.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterSamples.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterExtendedCorpus.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterSupport.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterAccentParity.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterSnapshot.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterMain.swift" \
  "myPlayer2/Utilities/ColorMath.swift" \
  "myPlayer2/Utilities/OKColor.swift" \
  "myPlayer2/Utilities/AccentColorPolicy.swift" \
  "myPlayer2/Utilities/ColorRenderingAdapter.swift" \
  "myPlayer2/Utilities/ColorSystemTokens.swift" \
  "myPlayer2/Utilities/ArtworkColorAnalysis.swift" \
  "myPlayer2/Utilities/ArtworkColorExtractor.swift" \
  "myPlayer2/Utilities/SemanticPalette.swift" \
  "myPlayer2/Utilities/LEDColorResolver.swift" \
  "myPlayer2/Views/NowPlaying/BKExtractedPalettePolicy.swift" \
  "myPlayer2/Views/NowPlaying/BKColorEngine.swift" \
  -o "${BIN}"

exec "${BIN}" "$@"
