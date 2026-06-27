import AppKit
import Foundation
import SwiftUI

enum ColorGoldenMasterSnapshot {
    static func render() throws -> String {
        let sections = try ColorGoldenMasterSamples.sections()
        let sampleCount = sections.reduce(0) { $0 + $1.samples.count }
        let extendedManifest = try ExtendedCorpusStore.loadManifest()
        var lines: [String] = []
        lines.append("# Color Golden Master Baseline")
        lines.append("format_version: 1")
        lines.append("cache_version: \(ArtworkColorExtractor.cacheVersion)")
        lines.append("sample_count: \(sampleCount)")
        lines.append("golden_gate_sample_count: \(ColorGoldenMasterSamples.realGoldenGate.count)")
        lines.append("extended_corpus_sample_count: \(extendedManifest.selectedCount)")
        lines.append("extended_corpus_seed: \(extendedManifest.randomSeed)")
        lines.append("extended_corpus_source_artwork_count: \(extendedManifest.sourceArtworkCount)")
        lines.append("extended_corpus_decoded_artwork_count: \(extendedManifest.decodedArtworkCount)")
        lines.append("extended_corpus_candidate_artwork_count: \(extendedManifest.candidateArtworkCount)")
        lines.append("extended_corpus_failed_artwork_count: \(extendedManifest.failedArtworkCount)")
        lines.append("extended_corpus_excluded_unstable_rank_tie_count: \(extendedManifest.excludedUnstableRankTieCount)")
        lines.append("extended_corpus_coverage: \(ExtendedCorpusStore.coverageLine(from: extendedManifest))")
        lines.append("synthetic_sample_count: \(ColorGoldenMasterSamples.synthetic.count)")
        lines.append("color_space: deviceRGB components; OKLCH derived from deviceRGB")
        lines.append("precision: fixed decimal 4")
        lines.append("hue_note: hue_reliable=false means OKLCH hue is recorded numerically but should not be treated as semantic")
        lines.append("bk_note: bk.* keys use analysis.topPalette as basePalette (cache-miss/direct-analysis path); bk.hit.* keys use analysis.displayPalette as basePalette (cache-hit/snapshot path); both call production BKExtractedPalettePolicy.select, BKColorEngine.make, makeShapeSwatches, and stabilize")
        lines.append("")

        for section in sections {
            lines.append("# section \(section.title)")
            lines.append("section_id: \(section.id)")
            lines.append("section_sample_count: \(section.samples.count)")
            lines.append("")
            for sample in section.samples {
                let loaded = try ColorGoldenMasterSupport.load(sample)
                appendSample(loaded, to: &lines)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendSample(_ loaded: LoadedGoldenSample, to lines: inout [String]) {
        let sample = loaded.sample
        let analysis = loaded.analysis
        lines.append("## sample \(sample.id)")
        lines.append("title: \(sample.title)")
        lines.append("note: \(sample.note)")
        lines.append("source: \(loaded.sourceDescription)")
        lines.append("source_size_bytes: \(loaded.sourceSizeBytes)")
        lines.append("source_hash_fnv1a64: \(ColorGoldenMasterSupport.f(loaded.sourceHash))")
        lines.append("classification.near_mono: \(ColorGoldenMasterSupport.bool(analysis.isNearMonochrome))")
        lines.append("classification.ultra_dark: \(ColorGoldenMasterSupport.bool(analysis.isUltraDark))")
        lines.append("classification.is_monochrome: \(ColorGoldenMasterSupport.bool(analysis.isMonochrome))")
        lines.append("classification.has_trusted_hue_candidate: \(ColorGoldenMasterSupport.bool(analysis.hasTrustedHueCandidate))")
        lines.append("classification.lacks_trusted_hue: \(ColorGoldenMasterSupport.bool(analysis.lacksTrustedHue))")
        lines.append("classification.primary_hue_source: \(ColorGoldenMasterSupport.colorDescription(analysis.primaryHueSourceColor))")
        appendAnalysis(analysis, to: &lines)
        appendSemantic(analysis, sampleID: sample.id, to: &lines)
        appendLED(analysis, to: &lines)
        appendBK(analysis, sampleID: sample.id, to: &lines)
        appendBKHitPath(analysis, sampleID: sample.id, to: &lines)
        appendBKHitMissComparison(analysis, sampleID: sample.id, to: &lines)
    }

    private static func appendAnalysis(_ analysis: ArtworkColorAnalysis, to lines: inout [String]) {
        lines.append("analysis.avg_hue: \(ColorGoldenMasterSupport.f(analysis.avgHue))")
        lines.append("analysis.dominant_hue: \(ColorGoldenMasterSupport.f(analysis.dominantHue))")
        lines.append("analysis.dominant_hue_confidence: \(ColorGoldenMasterSupport.f(analysis.dominantHueConfidence))")
        lines.append("analysis.avg_saturation: \(ColorGoldenMasterSupport.f(analysis.avgSaturation))")
        lines.append("analysis.avg_brightness: \(ColorGoldenMasterSupport.f(analysis.avgBrightness))")
        lines.append("analysis.avg_hsl_lightness: \(ColorGoldenMasterSupport.f(analysis.avgHslLightness))")
        lines.append("analysis.weighted_luma: \(ColorGoldenMasterSupport.f(analysis.weightedLuma))")
        lines.append("analysis.saturation_variance: \(ColorGoldenMasterSupport.f(analysis.saturationVariance))")
        lines.append("analysis.lightness_variance: \(ColorGoldenMasterSupport.f(analysis.lightnessVariance))")
        lines.append("analysis.colorfulness: \(ColorGoldenMasterSupport.f(analysis.colorfulness))")
        lines.append("analysis.dominant_saturation: \(ColorGoldenMasterSupport.f(analysis.dominantSaturation))")
        lines.append("analysis.dominant_brightness: \(ColorGoldenMasterSupport.f(analysis.dominantBrightness))")
        lines.append("analysis.largest_high_saturation_area_share: \(ColorGoldenMasterSupport.f(analysis.largestHighSaturationAreaShare))")
        lines.append("analysis.high_saturation_area_share: \(ColorGoldenMasterSupport.f(analysis.highSaturationAreaShare))")
        lines.append("analysis.has_strong_accent_region: \(ColorGoldenMasterSupport.bool(analysis.hasStrongAccentRegion))")
        lines.append("analysis.uses_dark_foreground: \(ColorGoldenMasterSupport.bool(analysis.usesDarkForeground))")
        lines.append("analysis.dominant_color: \(ColorGoldenMasterSupport.colorDescription(analysis.dominantColor))")
        lines.append("analysis.average_color: \(ColorGoldenMasterSupport.colorDescription(analysis.averageColor))")
        lines.append("analysis.best_text_source_color: \(ColorGoldenMasterSupport.colorDescription(analysis.bestTextSourceColor))")
        appendColorArray("analysis.top_palette", analysis.topPalette, to: &lines)
        appendColorArray("analysis.rich_palette", analysis.richPalette, to: &lines)
        appendColorArray(
            "analysis.salient_highlight_palette",
            analysis.salientHighlightPalette,
            shares: analysis.salientHighlightAreaShares,
            to: &lines
        )
        appendColorArray("analysis.display_palette", analysis.displayPalette, to: &lines)
        appendColorArray(
            "analysis.surface_palette",
            analysis.surfacePalette,
            shares: analysis.surfacePaletteAreaShares,
            to: &lines
        )
    }

    private static func appendSemantic(
        _ analysis: ArtworkColorAnalysis,
        sampleID: String,
        to lines: inout [String]
    ) {
        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let schemeName = scheme == .dark ? "dark" : "light"
            let palette = SemanticPaletteFactory.make(
                from: analysis,
                scheme: scheme,
                userFallbackAccent: ColorGoldenMasterSupport.fallbackAccent,
                useArtworkTint: true
            )
            lines.append("semantic.\(schemeName).global_accent: \(ColorGoldenMasterSupport.colorDescription(palette.globalAccent))")
            lines.append("semantic.\(schemeName).ui_accent_on_dark: \(ColorGoldenMasterSupport.colorDescription(palette.uiAccentOnDark))")
            lines.append("semantic.\(schemeName).ui_accent_on_light: \(ColorGoldenMasterSupport.colorDescription(palette.uiAccentOnLight))")
            lines.append("semantic.\(schemeName).ambient_surface: \(ColorGoldenMasterSupport.colorDescription(palette.ambientSurface))")
            lines.append("semantic.\(schemeName).art_background_primary: \(ColorGoldenMasterSupport.colorDescription(palette.artBackgroundPrimary))")
            lines.append("semantic.\(schemeName).art_background_secondary: \(ColorGoldenMasterSupport.colorDescription(palette.artBackgroundSecondary))")
            lines.append("semantic.\(schemeName).readable_text_on_artwork: \(ColorGoldenMasterSupport.colorDescription(palette.readableTextOnArtwork))")
            lines.append("semantic.\(schemeName).secondary_text_on_artwork: \(ColorGoldenMasterSupport.colorDescription(palette.secondaryTextOnArtwork))")
            lines.append("semantic.\(schemeName).window_lyric_active: \(ColorGoldenMasterSupport.colorDescription(palette.windowLyricActive))")
            lines.append("semantic.\(schemeName).window_lyric_inactive: \(ColorGoldenMasterSupport.colorDescription(palette.windowLyricInactive))")
            lines.append("semantic.\(schemeName).fullscreen_lyric_base: \(ColorGoldenMasterSupport.colorDescription(palette.fullscreenLyricBase))")
            lines.append("semantic.\(schemeName).fullscreen_lyric_inactive_base: \(ColorGoldenMasterSupport.colorDescription(palette.fullscreenLyricInactiveBase))")
            lines.append("semantic.\(schemeName).cover_gradient_dominant: \(ColorGoldenMasterSupport.colorDescription(palette.coverGradientDominant))")
            lines.append("semantic.\(schemeName).cover_gradient_text: \(ColorGoldenMasterSupport.colorDescription(palette.coverGradientText))")
            appendReadability("semantic.\(schemeName).readability", palette.readabilityProfile, to: &lines)
            appendMiniPlayer("semantic.\(schemeName).mini_player_control", palette.miniPlayerControl, to: &lines)
            appendAppForeground("semantic.\(schemeName).app_foreground", palette.appForeground, to: &lines)
            appendLyricsPalette("semantic.\(schemeName).lyrics", palette.lyrics, to: &lines)

            let standard = SemanticPaletteFactory.fullscreenLyricsColorSet(
                analysis: analysis,
                scheme: scheme,
                highlightBaseColor: palette.fullscreenLyricBase,
                inactiveBaseColor: palette.fullscreenLyricInactiveBase,
                isUltraDark: analysis.isUltraDark,
                usesArtisticBackground: false
            )
            appendLyricsSurface("lyrics_surface.\(schemeName).standard_fullscreen", standard, to: &lines)

            let artistic = SemanticPaletteFactory.fullscreenLyricsColorSet(
                analysis: analysis,
                scheme: scheme,
                highlightBaseColor: palette.fullscreenLyricBase,
                inactiveBaseColor: palette.fullscreenLyricInactiveBase,
                isUltraDark: analysis.isUltraDark,
                usesArtisticBackground: true
            )
            appendLyricsSurface("lyrics_surface.\(schemeName).art_background_fullscreen", artistic, to: &lines)

            let coverLighter = SemanticPaletteFactory.coverBlurLyricsColorSet(
                analysis: analysis,
                themeColor: palette.coverGradientDominant,
                profile: .lighter
            )
            appendLyricsSurface("lyrics_surface.\(schemeName).cover_blur_lighter", coverLighter, to: &lines)

            let coverDarker = SemanticPaletteFactory.coverBlurLyricsColorSet(
                analysis: analysis,
                themeColor: palette.coverGradientDominant,
                profile: .darker
            )
            appendLyricsSurface("lyrics_surface.\(schemeName).cover_blur_darker", coverDarker, to: &lines)

            let seed = SemanticPaletteFactory.artisticLyricsSingleSeed(
                preferred: palette.fullscreenLyricBase,
                averageBaseColor: palette.fullscreenLyricInactiveBase,
                analysis: analysis
            )
            lines.append("lyrics_surface.\(schemeName).artistic_seed: \(ColorGoldenMasterSupport.lchDescription(seed))")
        }
    }

    private static func appendLED(_ analysis: ArtworkColorAnalysis, to lines: inout [String]) {
        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let schemeName = scheme == .dark ? "dark" : "light"
            let palette = SemanticPaletteFactory.make(
                from: analysis,
                scheme: scheme,
                userFallbackAccent: ColorGoldenMasterSupport.fallbackAccent,
                useArtworkTint: true
            )
            let resolver = LEDColorResolver(
                accentColor: Color(nsColor: palette.globalAccent),
                colorScheme: scheme,
                brightnessLevels: 10,
                palette: palette
            )
            lines.append("led.\(schemeName).center: \(ColorGoldenMasterSupport.colorDescription(resolver.centerColor))")
            lines.append("led.\(schemeName).edge: \(ColorGoldenMasterSupport.colorDescription(resolver.edgeColor))")
            for level in [0, 1, 5, 9] {
                let status = resolver.statusLightNSColor(level: level).withAlphaComponent(
                    ColorGoldenMasterSupport.ledOpacity(for: level, maxLevel: 9, scheme: scheme)
                )
                lines.append("led.\(schemeName).status.level_\(level): \(ColorGoldenMasterSupport.colorDescription(status))")
                let stroke = resolver.statusLightStrokeNSColor(level: level).withAlphaComponent(
                    min(0.50, ColorGoldenMasterSupport.ledOpacity(for: level, maxLevel: 9, scheme: scheme) * 0.55)
                )
                lines.append("led.\(schemeName).status_stroke.level_\(level): \(ColorGoldenMasterSupport.colorDescription(stroke))")
            }
            for index in [0, 4, 9] {
                let volume = resolver.volumeLEDNSColor(index: index, count: 10, level: 5).withAlphaComponent(
                    ColorGoldenMasterSupport.ledOpacity(for: 5, maxLevel: 9, scheme: scheme)
                )
                lines.append("led.\(schemeName).volume.index_\(index).level_5: \(ColorGoldenMasterSupport.colorDescription(volume))")
                let stroke = resolver.volumeLEDStrokeNSColor(index: index, count: 10, level: 5).withAlphaComponent(
                    min(0.50, ColorGoldenMasterSupport.ledOpacity(for: 5, maxLevel: 9, scheme: scheme) * 0.55)
                )
                lines.append("led.\(schemeName).volume_stroke.index_\(index).level_5: \(ColorGoldenMasterSupport.colorDescription(stroke))")
            }
        }
    }

    private static func appendBK(
        _ analysis: ArtworkColorAnalysis,
        sampleID: String,
        to lines: inout [String]
    ) {
        appendColorArray("bk.base_palette", analysis.topPalette, to: &lines)
        let extracted = BKExtractedPalettePolicy.select(
            analysis: analysis,
            basePalette: analysis.topPalette,
            richPalette: analysis.richPalette,
            fallbackPalette: ColorGoldenMasterSupport.bkFallbackPalette
        )
        appendColorArray("bk.selected_extracted_palette", extracted, to: &lines)
        for isDark in [true, false] {
            let schemeName = isDark ? "dark" : "light"
            let palette = BKColorEngine.make(
                extracted: extracted,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            lines.append("bk.\(schemeName).primary_hue_degrees: \(ColorGoldenMasterSupport.f(palette.primaryHue))")
            lines.append("bk.\(schemeName).image_hue_degrees: \(ColorGoldenMasterSupport.f(palette.imageHue))")
            lines.append("bk.\(schemeName).complexity: \(palette.complexity.rawValue)")
            lines.append("bk.\(schemeName).gray_score: \(ColorGoldenMasterSupport.f(palette.grayScore))")
            lines.append("bk.\(schemeName).is_grayscale_cover: \(ColorGoldenMasterSupport.bool(palette.isGrayscaleCover))")
            lines.append("bk.\(schemeName).is_near_gray: \(ColorGoldenMasterSupport.bool(palette.isNearGray))")
            lines.append("bk.\(schemeName).cover_luma: \(ColorGoldenMasterSupport.f(palette.coverLuma))")
            lines.append("bk.\(schemeName).image_cover_luma: \(ColorGoldenMasterSupport.f(palette.imageCoverLuma))")
            lines.append("bk.\(schemeName).cover_avg_s: \(ColorGoldenMasterSupport.f(palette.coverAvgS))")
            lines.append("bk.\(schemeName).area_dominant_s: \(ColorGoldenMasterSupport.f(palette.areaDominantS))")
            lines.append("bk.\(schemeName).area_dominant_b: \(ColorGoldenMasterSupport.f(palette.areaDominantB))")
            lines.append("bk.\(schemeName).accent_hue_degrees: \(palette.accentHue.map(ColorGoldenMasterSupport.f) ?? "nil")")
            lines.append("bk.\(schemeName).accent_strength: \(ColorGoldenMasterSupport.f(palette.accentStrength))")
            lines.append("bk.\(schemeName).accent_enabled: \(ColorGoldenMasterSupport.bool(palette.accentEnabled))")
            lines.append("bk.\(schemeName).uses_strict_neutral_rendering: \(ColorGoldenMasterSupport.bool(palette.usesStrictNeutralRendering))")
            lines.append("bk.\(schemeName).chromatic_cluster_count: \(palette.chromaticClusterCount)")
            lines.append("bk.\(schemeName).bg_b_range: \(ColorGoldenMasterSupport.range(palette.bgBRange))")
            lines.append("bk.\(schemeName).fg_b_range: \(ColorGoldenMasterSupport.range(palette.fgBRange))")
            lines.append("bk.\(schemeName).dot_b_range: \(ColorGoldenMasterSupport.range(palette.dotBRange))")
            lines.append("bk.\(schemeName).bg_s_range: \(ColorGoldenMasterSupport.range(palette.bgSRange))")
            lines.append("bk.\(schemeName).fg_s_range: \(ColorGoldenMasterSupport.range(palette.fgSRange))")
            lines.append("bk.\(schemeName).dot_s_range: \(ColorGoldenMasterSupport.range(palette.dotSRange))")
            appendCGColorArray("bk.\(schemeName).bg_stops", palette.bgStops, to: &lines)
            for (index, variant) in palette.bgVariants.enumerated() {
                appendCGColorArray("bk.\(schemeName).bg_variants[\(index)]", variant, to: &lines)
            }
            appendCGColorArray("bk.\(schemeName).shape_pool", palette.shapePool, to: &lines)
            lines.append("bk.\(schemeName).dot_base: \(ColorGoldenMasterSupport.colorDescription(ColorGoldenMasterSupport.nsColor(from: palette.dotBase)))")

            let swatches = BKColorEngine.makeShapeSwatches(
                seed: ColorGoldenMasterSupport.stableSeed(for: sampleID, salt: schemeName),
                extracted: extracted,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            lines.append("bk.\(schemeName).shape_swatches.diagnostics.avg_s: \(ColorGoldenMasterSupport.f(swatches.diagnostics.avgS))")
            lines.append("bk.\(schemeName).shape_swatches.diagnostics.hue_spread: \(ColorGoldenMasterSupport.f(swatches.diagnostics.hueSpread))")
            lines.append("bk.\(schemeName).shape_swatches.diagnostics.swatch_count: \(swatches.diagnostics.swatchCount)")
            lines.append("bk.\(schemeName).shape_swatches.diagnostics.chromatic_cluster_count: \(swatches.diagnostics.chromaticClusterCount)")
            lines.append("bk.\(schemeName).shape_swatches.diagnostics.swatch_hsb: \(swatches.diagnostics.swatchHSB.joined(separator: " | "))")
            lines.append("bk.\(schemeName).shape_swatches.diagnostics.nearest_candidate_hue_diff: \(swatches.diagnostics.nearestCandidateHueDiff.map(ColorGoldenMasterSupport.f).joined(separator: ","))")
            appendCGColorArray("bk.\(schemeName).shape_swatches.colors", swatches.colors, to: &lines)
            let stabilized = swatches.colors.prefix(4).map {
                BKColorEngine.stabilize(
                    color: $0,
                    kind: .shape,
                    palette: palette,
                    saturationJitter: 0.03,
                    brightnessJitter: 0.02
                )
            }
            appendCGColorArray("bk.\(schemeName).shape_swatches.stabilized_shape_jitter_s003_b002", Array(stabilized), to: &lines)
        }
    }

    /// Cache-hit path: when BKArtBackgroundView reads from ArtworkAssetStore,
    /// snapshot.palette = displayPalette (when non-empty) rather than
    /// topPalette. This block exercises BKExtractedPalettePolicy.select and
    /// BKColorEngine with the cache-hit basePalette input.
    private static func appendBKHitPath(
        _ analysis: ArtworkColorAnalysis,
        sampleID: String,
        to lines: inout [String]
    ) {
        // Mirror the cache-hit basePalette resolution from ArtworkAssetStore
        // (ArtworkAssetStore.swift lines 248-250):
        //   let palette = analysis.displayPalette.isEmpty == false
        //       ? (analysis.displayPalette ?? extractedPalette)
        //       : extractedPalette
        // Since we don't have the sample-based extractedPalette in the CLI,
        // and displayPalette is always non-empty when analysis exists, we use
        // displayPalette directly. When displayPalette is empty, we fall back
        // to topPalette (same as the cache-miss path), making the hit block
        // identical to the miss block — which is the correct production
        // behavior for that edge case.
        let hitBasePalette = analysis.displayPalette.isEmpty
            ? analysis.topPalette
            : analysis.displayPalette
        appendColorArray("bk.hit.base_palette", hitBasePalette, to: &lines)
        let extracted = BKExtractedPalettePolicy.select(
            analysis: analysis,
            basePalette: hitBasePalette,
            richPalette: analysis.richPalette,
            fallbackPalette: ColorGoldenMasterSupport.bkFallbackPalette
        )
        appendColorArray("bk.hit.selected_extracted_palette", extracted, to: &lines)
        for isDark in [true, false] {
            let schemeName = isDark ? "dark" : "light"
            let palette = BKColorEngine.make(
                extracted: extracted,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            lines.append("bk.hit.\(schemeName).primary_hue_degrees: \(ColorGoldenMasterSupport.f(palette.primaryHue))")
            lines.append("bk.hit.\(schemeName).image_hue_degrees: \(ColorGoldenMasterSupport.f(palette.imageHue))")
            lines.append("bk.hit.\(schemeName).complexity: \(palette.complexity.rawValue)")
            lines.append("bk.hit.\(schemeName).gray_score: \(ColorGoldenMasterSupport.f(palette.grayScore))")
            lines.append("bk.hit.\(schemeName).is_grayscale_cover: \(ColorGoldenMasterSupport.bool(palette.isGrayscaleCover))")
            lines.append("bk.hit.\(schemeName).is_near_gray: \(ColorGoldenMasterSupport.bool(palette.isNearGray))")
            lines.append("bk.hit.\(schemeName).cover_luma: \(ColorGoldenMasterSupport.f(palette.coverLuma))")
            lines.append("bk.hit.\(schemeName).image_cover_luma: \(ColorGoldenMasterSupport.f(palette.imageCoverLuma))")
            lines.append("bk.hit.\(schemeName).cover_avg_s: \(ColorGoldenMasterSupport.f(palette.coverAvgS))")
            lines.append("bk.hit.\(schemeName).area_dominant_s: \(ColorGoldenMasterSupport.f(palette.areaDominantS))")
            lines.append("bk.hit.\(schemeName).area_dominant_b: \(ColorGoldenMasterSupport.f(palette.areaDominantB))")
            lines.append("bk.hit.\(schemeName).accent_hue_degrees: \(palette.accentHue.map(ColorGoldenMasterSupport.f) ?? "nil")")
            lines.append("bk.hit.\(schemeName).accent_strength: \(ColorGoldenMasterSupport.f(palette.accentStrength))")
            lines.append("bk.hit.\(schemeName).accent_enabled: \(ColorGoldenMasterSupport.bool(palette.accentEnabled))")
            lines.append("bk.hit.\(schemeName).uses_strict_neutral_rendering: \(ColorGoldenMasterSupport.bool(palette.usesStrictNeutralRendering))")
            lines.append("bk.hit.\(schemeName).chromatic_cluster_count: \(palette.chromaticClusterCount)")
            lines.append("bk.hit.\(schemeName).bg_b_range: \(ColorGoldenMasterSupport.range(palette.bgBRange))")
            lines.append("bk.hit.\(schemeName).fg_b_range: \(ColorGoldenMasterSupport.range(palette.fgBRange))")
            lines.append("bk.hit.\(schemeName).dot_b_range: \(ColorGoldenMasterSupport.range(palette.dotBRange))")
            lines.append("bk.hit.\(schemeName).bg_s_range: \(ColorGoldenMasterSupport.range(palette.bgSRange))")
            lines.append("bk.hit.\(schemeName).fg_s_range: \(ColorGoldenMasterSupport.range(palette.fgSRange))")
            lines.append("bk.hit.\(schemeName).dot_s_range: \(ColorGoldenMasterSupport.range(palette.dotSRange))")
            appendCGColorArray("bk.hit.\(schemeName).bg_stops", palette.bgStops, to: &lines)
            for (index, variant) in palette.bgVariants.enumerated() {
                appendCGColorArray("bk.hit.\(schemeName).bg_variants[\(index)]", variant, to: &lines)
            }
            appendCGColorArray("bk.hit.\(schemeName).shape_pool", palette.shapePool, to: &lines)
            lines.append("bk.hit.\(schemeName).dot_base: \(ColorGoldenMasterSupport.colorDescription(ColorGoldenMasterSupport.nsColor(from: palette.dotBase)))")

            let swatches = BKColorEngine.makeShapeSwatches(
                seed: ColorGoldenMasterSupport.stableSeed(for: sampleID, salt: "hit_\(schemeName)"),
                extracted: extracted,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            lines.append("bk.hit.\(schemeName).shape_swatches.diagnostics.avg_s: \(ColorGoldenMasterSupport.f(swatches.diagnostics.avgS))")
            lines.append("bk.hit.\(schemeName).shape_swatches.diagnostics.hue_spread: \(ColorGoldenMasterSupport.f(swatches.diagnostics.hueSpread))")
            lines.append("bk.hit.\(schemeName).shape_swatches.diagnostics.swatch_count: \(swatches.diagnostics.swatchCount)")
            lines.append("bk.hit.\(schemeName).shape_swatches.diagnostics.chromatic_cluster_count: \(swatches.diagnostics.chromaticClusterCount)")
            lines.append("bk.hit.\(schemeName).shape_swatches.diagnostics.swatch_hsb: \(swatches.diagnostics.swatchHSB.joined(separator: " | "))")
            lines.append("bk.hit.\(schemeName).shape_swatches.diagnostics.nearest_candidate_hue_diff: \(swatches.diagnostics.nearestCandidateHueDiff.map(ColorGoldenMasterSupport.f).joined(separator: ","))")
            appendCGColorArray("bk.hit.\(schemeName).shape_swatches.colors", swatches.colors, to: &lines)
            let stabilized = swatches.colors.prefix(4).map {
                BKColorEngine.stabilize(
                    color: $0,
                    kind: .shape,
                    palette: palette,
                    saturationJitter: 0.03,
                    brightnessJitter: 0.02
                )
            }
            appendCGColorArray("bk.hit.\(schemeName).shape_swatches.stabilized_shape_jitter_s003_b002", Array(stabilized), to: &lines)
        }
    }

    private static func appendBKHitMissComparison(
        _ analysis: ArtworkColorAnalysis,
        sampleID: String,
        to lines: inout [String]
    ) {
        let missBasePalette = analysis.topPalette
        let hitBasePalette = analysis.displayPalette.isEmpty
            ? analysis.topPalette
            : analysis.displayPalette
        let missExtracted = BKExtractedPalettePolicy.select(
            analysis: analysis,
            basePalette: missBasePalette,
            richPalette: analysis.richPalette,
            fallbackPalette: ColorGoldenMasterSupport.bkFallbackPalette
        )
        let hitExtracted = BKExtractedPalettePolicy.select(
            analysis: analysis,
            basePalette: hitBasePalette,
            richPalette: analysis.richPalette,
            fallbackPalette: ColorGoldenMasterSupport.bkFallbackPalette
        )

        lines.append("bk.hit_miss.base_palette_differs: \(ColorGoldenMasterSupport.bool(!sameColorArray(missBasePalette, hitBasePalette)))")
        lines.append("bk.hit_miss.selected_extracted_palette_differs: \(ColorGoldenMasterSupport.bool(!sameColorArray(missExtracted, hitExtracted)))")

        for isDark in [true, false] {
            let schemeName = isDark ? "dark" : "light"
            let missPalette = BKColorEngine.make(
                extracted: missExtracted,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            let hitPalette = BKColorEngine.make(
                extracted: hitExtracted,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            lines.append("bk.hit_miss.\(schemeName).engine_output_differs: \(ColorGoldenMasterSupport.bool(harmonizedPaletteSignature(missPalette) != harmonizedPaletteSignature(hitPalette)))")

            let seed = ColorGoldenMasterSupport.stableSeed(for: sampleID, salt: "hit_miss_\(schemeName)")
            let missSwatches = BKColorEngine.makeShapeSwatches(
                seed: seed,
                extracted: missExtracted,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            let hitSwatches = BKColorEngine.makeShapeSwatches(
                seed: seed,
                extracted: hitExtracted,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            lines.append("bk.hit_miss.\(schemeName).shape_swatches_same_seed_differs: \(ColorGoldenMasterSupport.bool(shapeSwatchSignature(missSwatches) != shapeSwatchSignature(hitSwatches)))")

            let missStabilized = missSwatches.colors.prefix(4).map {
                BKColorEngine.stabilize(
                    color: $0,
                    kind: .shape,
                    palette: missPalette,
                    saturationJitter: 0.03,
                    brightnessJitter: 0.02
                )
            }
            let hitStabilized = hitSwatches.colors.prefix(4).map {
                BKColorEngine.stabilize(
                    color: $0,
                    kind: .shape,
                    palette: hitPalette,
                    saturationJitter: 0.03,
                    brightnessJitter: 0.02
                )
            }
            lines.append("bk.hit_miss.\(schemeName).stabilized_shape_jitter_s003_b002_same_seed_differs: \(ColorGoldenMasterSupport.bool(cgColorArraySignature(Array(missStabilized)) != cgColorArraySignature(Array(hitStabilized))))")
        }
    }

    private static func appendReadability(
        _ prefix: String,
        _ profile: ArtworkReadabilityProfile,
        to lines: inout [String]
    ) {
        lines.append("\(prefix).uses_dark_foreground: \(ColorGoldenMasterSupport.bool(profile.usesDarkForeground))")
        lines.append("\(prefix).is_near_mono: \(ColorGoldenMasterSupport.bool(profile.isNearMonochrome))")
        lines.append("\(prefix).foreground_primary: \(ColorGoldenMasterSupport.colorDescription(profile.foregroundPrimary))")
        lines.append("\(prefix).foreground_secondary: \(ColorGoldenMasterSupport.colorDescription(profile.foregroundSecondary))")
        lines.append("\(prefix).foreground_tertiary: \(ColorGoldenMasterSupport.colorDescription(profile.foregroundTertiary))")
        lines.append("\(prefix).foreground_quaternary: \(ColorGoldenMasterSupport.colorDescription(profile.foregroundQuaternary))")
        lines.append("\(prefix).icon_foreground: \(ColorGoldenMasterSupport.colorDescription(profile.iconForeground))")
    }

    private static func appendMiniPlayer(
        _ prefix: String,
        _ palette: MiniPlayerControlPalette,
        to lines: inout [String]
    ) {
        lines.append("\(prefix).primary: \(ColorGoldenMasterSupport.colorDescription(palette.primary))")
        lines.append("\(prefix).secondary: \(ColorGoldenMasterSupport.colorDescription(palette.secondary))")
        lines.append("\(prefix).progress_fill: \(ColorGoldenMasterSupport.colorDescription(palette.progressFill))")
        lines.append("\(prefix).progress_track: \(ColorGoldenMasterSupport.colorDescription(palette.progressTrack))")
    }

    private static func appendAppForeground(
        _ prefix: String,
        _ palette: AppForegroundPalette,
        to lines: inout [String]
    ) {
        lines.append("\(prefix).primary: \(ColorGoldenMasterSupport.colorDescription(palette.primary))")
        lines.append("\(prefix).secondary: \(ColorGoldenMasterSupport.colorDescription(palette.secondary))")
        lines.append("\(prefix).tertiary: \(ColorGoldenMasterSupport.colorDescription(palette.tertiary))")
        lines.append("\(prefix).quaternary: \(ColorGoldenMasterSupport.colorDescription(palette.quaternary))")
        lines.append("\(prefix).disabled: \(ColorGoldenMasterSupport.colorDescription(palette.disabled))")
    }

    private static func appendLyricsPalette(
        _ prefix: String,
        _ palette: LyricsColorPalette,
        to lines: inout [String]
    ) {
        lines.append("\(prefix).window_active: \(ColorGoldenMasterSupport.colorDescription(palette.windowActive))")
        lines.append("\(prefix).window_inactive: \(ColorGoldenMasterSupport.colorDescription(palette.windowInactive))")
        lines.append("\(prefix).fullscreen_base: \(ColorGoldenMasterSupport.colorDescription(palette.fullscreenBase))")
        lines.append("\(prefix).fullscreen_inactive_base: \(ColorGoldenMasterSupport.colorDescription(palette.fullscreenInactiveBase))")
        appendLyricsSurface("\(prefix).fullscreen", palette.fullscreen, to: &lines)
    }

    private static func appendLyricsSurface(
        _ prefix: String,
        _ set: LyricsSurfaceColorSet,
        to lines: inout [String]
    ) {
        lines.append("\(prefix).main_active: \(ColorGoldenMasterSupport.colorDescription(set.mainActive))")
        lines.append("\(prefix).main_inactive: \(ColorGoldenMasterSupport.colorDescription(set.mainInactive))")
        lines.append("\(prefix).line_timing_main_inactive: \(ColorGoldenMasterSupport.colorDescription(set.lineTimingMainInactive))")
        lines.append("\(prefix).sub_active: \(ColorGoldenMasterSupport.colorDescription(set.subActive))")
        lines.append("\(prefix).sub_inactive: \(ColorGoldenMasterSupport.colorDescription(set.subInactive))")
        lines.append("\(prefix).line_timing_sub_inactive: \(ColorGoldenMasterSupport.colorDescription(set.lineTimingSubInactive))")
    }

    private static func appendColorArray(
        _ prefix: String,
        _ colors: [NSColor],
        shares: [CGFloat] = [],
        to lines: inout [String]
    ) {
        lines.append("\(prefix).count: \(colors.count)")
        for (index, color) in colors.enumerated() {
            let share = index < shares.count
                ? " share=\(ColorGoldenMasterSupport.f(shares[index]))"
                : ""
            lines.append("\(prefix)[\(index)]:\(share) \(ColorGoldenMasterSupport.colorDescription(color))")
        }
    }

    private static func appendCGColorArray(
        _ prefix: String,
        _ colors: [CGColor],
        to lines: inout [String]
    ) {
        lines.append("\(prefix).count: \(colors.count)")
        for (index, color) in colors.enumerated() {
            let nsColor = ColorGoldenMasterSupport.nsColor(from: color)
            let hsb = BKColorEngine.hsbDebugString(for: color)
            lines.append("\(prefix)[\(index)]: \(ColorGoldenMasterSupport.colorDescription(nsColor)) hsb=(\(hsb))")
        }
    }

    private static func sameColorArray(_ lhs: [NSColor], _ rhs: [NSColor]) -> Bool {
        colorArraySignature(lhs) == colorArraySignature(rhs)
    }

    private static func colorArraySignature(_ colors: [NSColor]) -> [String] {
        colors.map(ColorGoldenMasterSupport.colorDescription)
    }

    private static func cgColorArraySignature(_ colors: [CGColor]) -> [String] {
        colors.map { color in
            let nsColor = ColorGoldenMasterSupport.nsColor(from: color)
            let hsb = BKColorEngine.hsbDebugString(for: color)
            return "\(ColorGoldenMasterSupport.colorDescription(nsColor)) hsb=(\(hsb))"
        }
    }

    private static func harmonizedPaletteSignature(_ palette: HarmonizedPalette) -> [String] {
        var signature = [
            ColorGoldenMasterSupport.f(palette.primaryHue),
            ColorGoldenMasterSupport.f(palette.imageHue),
            "\(palette.isDark)",
            palette.complexity.rawValue,
            ColorGoldenMasterSupport.f(palette.grayScore),
            ColorGoldenMasterSupport.bool(palette.isGrayscaleCover),
            ColorGoldenMasterSupport.bool(palette.isNearGray),
            ColorGoldenMasterSupport.f(palette.coverLuma),
            ColorGoldenMasterSupport.f(palette.imageCoverLuma),
            ColorGoldenMasterSupport.f(palette.coverAvgS),
            ColorGoldenMasterSupport.f(palette.areaDominantS),
            ColorGoldenMasterSupport.f(palette.areaDominantB),
            palette.accentHue.map(ColorGoldenMasterSupport.f) ?? "nil",
            ColorGoldenMasterSupport.f(palette.accentStrength),
            ColorGoldenMasterSupport.bool(palette.accentEnabled),
            ColorGoldenMasterSupport.bool(palette.usesStrictNeutralRendering),
            "\(palette.chromaticClusterCount)",
            ColorGoldenMasterSupport.range(palette.bgBRange),
            ColorGoldenMasterSupport.range(palette.fgBRange),
            ColorGoldenMasterSupport.range(palette.dotBRange),
            ColorGoldenMasterSupport.range(palette.bgSRange),
            ColorGoldenMasterSupport.range(palette.fgSRange),
            ColorGoldenMasterSupport.range(palette.dotSRange)
        ]
        signature += cgColorArraySignature(palette.bgStops)
        for variant in palette.bgVariants {
            signature += cgColorArraySignature(variant)
        }
        signature += cgColorArraySignature(palette.shapePool)
        signature += cgColorArraySignature([palette.dotBase])
        return signature
    }

    private static func shapeSwatchSignature(_ swatches: BKColorEngine.ShapeSwatchResult) -> [String] {
        [
            ColorGoldenMasterSupport.f(swatches.diagnostics.avgS),
            ColorGoldenMasterSupport.f(swatches.diagnostics.hueSpread),
            "\(swatches.diagnostics.swatchCount)",
            "\(swatches.diagnostics.chromaticClusterCount)",
            swatches.diagnostics.swatchHSB.joined(separator: "|"),
            swatches.diagnostics.nearestCandidateHueDiff.map(ColorGoldenMasterSupport.f).joined(separator: ",")
        ] + cgColorArraySignature(swatches.colors)
    }
}
