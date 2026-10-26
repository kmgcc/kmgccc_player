#!/usr/bin/env bash
# Standalone model/store/service tests; does not build or launch the main App.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/music-enrichment-tests.XXXXXX")"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
  "$ROOT/kmgccc_player/Models/MusicEnrichment.swift" \
  "$ROOT/kmgccc_player/Services/MusicEnrichment/MusicEnrichmentStore.swift" \
  "$ROOT/kmgccc_player/Services/MusicEnrichment/MusicEnrichmentHelperClient.swift" \
  "$ROOT/kmgccc_player/Services/MusicEnrichment/MusicEnrichmentService.swift" \
  "$ROOT/kmgccc_player/Services/MusicEnrichment/MusicEnrichmentService+Completion.swift" \
  "$ROOT/kmgccc_player/Services/MusicEnrichment/MusicEnrichmentService+Editing.swift" \
  "$ROOT/kmgccc_player/Services/MusicEnrichment/MusicEnrichmentService+Import.swift" \
  "$ROOT/kmgccc_player/Services/MusicEnrichment/MusicEnrichmentService+AlbumMotion.swift" \
  "$ROOT/kmgccc_player/Services/Background/BackgroundWorkContext.swift" \
  "$ROOT/Tests/MusicEnrichmentCoreTests.swift" \
  -o "$TEST_OUTPUT_DIR/music-enrichment-core-tests"

"$TEST_OUTPUT_DIR/music-enrichment-core-tests"
