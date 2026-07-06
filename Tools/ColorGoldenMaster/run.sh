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
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterAccentReview.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterBKParity.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterLEDParity.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterLyricsParity.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterReadabilityParity.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterSnapshot.swift" \
  "${SCRIPT_DIR}/Sources/ColorGoldenMasterMain.swift" \
  "kmgccc_player/Utilities/ColorMath.swift" \
  "kmgccc_player/Utilities/OKColor.swift" \
  "kmgccc_player/Utilities/AccentColorPolicy.swift" \
  "kmgccc_player/Utilities/ColorRenderingAdapter.swift" \
  "kmgccc_player/Utilities/ColorSystemTokens.swift" \
  "kmgccc_player/Utilities/ArtworkColorAnalysis.swift" \
  "kmgccc_player/Utilities/ArtworkColorExtractor.swift" \
  "kmgccc_player/Utilities/SemanticPalette.swift" \
  "kmgccc_player/Utilities/LEDColorResolver.swift" \
  "kmgccc_player/Views/NowPlaying/BKExtractedPalettePolicy.swift" \
  "kmgccc_player/Views/NowPlaying/BKColorEngine.swift" \
  "kmgccc_player/Views/NowPlaying/BKPerceptualColorPolicy.swift" \
  -o "${BIN}"

exec "${BIN}" "$@"
