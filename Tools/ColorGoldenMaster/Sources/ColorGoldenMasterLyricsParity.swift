import AppKit
import Foundation
import SwiftUI

struct LyricsParitySummary {
    var total = 0
    var preserve = 0
    var reviewRequired = 0
    var hierarchyRisk = 0
    var alphaRisk = 0
    var p3FallbackRisk = 0
    var nearMonoRisk = 0
    var coverBlurRisk = 0

    var statusLine: String {
        [
            "total=\(total)",
            "preserve=\(preserve)",
            "review_required=\(reviewRequired)",
            "hierarchy_risk=\(hierarchyRisk)",
            "alpha_risk=\(alphaRisk)",
            "p3_fallback_risk=\(p3FallbackRisk)",
            "near_mono_risk=\(nearMonoRisk)",
            "cover_blur_risk=\(coverBlurRisk)",
        ].joined(separator: " ")
    }
}

enum ColorGoldenMasterLyricsParity {
    static let reportVersion = 1
    static let candidatePolicy = "phase2_fullscreen_oklch_semantic_palette"

    static func buildRows() throws -> [LyricsParityRow] {
        let sections = try ColorGoldenMasterSamples.sections()
        var rows: [LyricsParityRow] = []
        for section in sections {
            for sample in section.samples {
                let loaded = try ColorGoldenMasterSupport.load(sample)
                appendRows(
                    sample: loaded.sample,
                    sectionID: section.id,
                    analysis: loaded.analysis,
                    to: &rows
                )
            }
        }
        return rows
    }

    static func summarize(_ rows: [LyricsParityRow]) -> LyricsParitySummary {
        var summary = LyricsParitySummary()
        for row in rows {
            summary.total += 1
            if row.riskTags == ["preserve"] {
                summary.preserve += 1
            } else {
                summary.reviewRequired += 1
            }
            if row.riskTags.contains("hierarchy-risk") { summary.hierarchyRisk += 1 }
            if row.riskTags.contains("alpha-contamination")
                || row.riskTags.contains("alpha-hierarchy") {
                summary.alphaRisk += 1
            }
            if row.riskTags.contains("p3-fallback-shift") { summary.p3FallbackRisk += 1 }
            if row.riskTags.contains("near-mono-risk") { summary.nearMonoRisk += 1 }
            if row.riskTags.contains("cover-blur-pollution") { summary.coverBlurRisk += 1 }
        }
        return summary
    }

    static func render() throws -> (text: String, summary: LyricsParitySummary) {
        let rows = try buildRows()
        let summary = summarize(rows)
        var lines: [String] = []
        lines.append("# Lyrics Legacy Parity and Web Adapter Model")
        lines.append("format_version: \(reportVersion)")
        lines.append("mode: lyrics-parity")
        lines.append("legacy_policy: production_lyrics_legacy")
        lines.append("candidate_policy: \(candidatePolicy)")
        lines.append("strict_baseline: unchanged")
        lines.append("adapter_source: myPlayer2/Resources/AMLL/index.html")
        lines.append("summary: \(summary.statusLine)")
        lines.append("")
        lines.append([
            "sample",
            "section",
            "scheme",
            "mode",
            "skin",
            "background_type",
            "role_group",
            "role",
            "legacy_swift_role",
            "legacy_swift_css",
            "legacy_swift_oklch",
            "alpha",
            "legacy_final_css",
            "legacy_final_oklch",
            "candidate_css",
            "candidate_oklch",
            "candidate_policy",
            "display_p3_output",
            "srgb_fallback",
            "web_adapter_derived_role",
            "web_adapter_formula",
            "web_adapter_notes",
            "blend_mode",
            "delta_l",
            "delta_c",
            "delta_h",
            "delta_e_oklab",
            "hierarchy_metrics",
            "risk_tags",
            "route_note",
        ].joined(separator: "\t"))
        for row in rows {
            lines.append(row.tsvLine)
        }
        return (lines.joined(separator: "\n") + "\n", summary)
    }

    static func renderHTML() throws -> String {
        let rows = try buildRows()
        let summary = summarize(rows)
        return LyricsParityReviewArtifact.render(rows: rows, summary: summary)
    }

    private static func appendRows(
        sample: GoldenSample,
        sectionID: String,
        analysis: ArtworkColorAnalysis,
        to rows: inout [LyricsParityRow]
    ) {
        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let palette = SemanticPaletteFactory.make(
                from: analysis,
                scheme: scheme,
                userFallbackAccent: ColorGoldenMasterSupport.fallbackAccent,
                useArtworkTint: true
            )
            let schemeName = scheme == .dark ? "dark" : "light"

            appendWindowRows(
                sample: sample,
                sectionID: sectionID,
                schemeName: schemeName,
                palette: palette,
                analysis: analysis,
                mode: "window_lyrics",
                skin: "main/window",
                backgroundType: "transparent window host",
                routeNote: "LyricsWebViewStore.applyEffectiveTheme writes --amll-text/--amll-active/--amll-inactive; no fullscreen adapter derivation",
                to: &rows
            )
            appendWindowRows(
                sample: sample,
                sectionID: sectionID,
                schemeName: schemeName,
                palette: palette,
                analysis: analysis,
                mode: "batch_preview",
                skin: "batchPreview",
                backgroundType: "batch preview host; reuses window theme palette path",
                routeNote: "LyricsSurfaceRole.batchPreview consumes ThemePalette; color path matches window lyrics for this model",
                to: &rows
            )

            appendFullscreenRows(
                sample: sample,
                sectionID: sectionID,
                schemeName: schemeName,
                mode: "standard_fullscreen",
                skin: "coverLed/rotatingCover/kmgccc.cassette/non-CoverBlur skins",
                backgroundType: "standard fullscreen skin, BK/custom background, or embedded opaque base",
                legacyColorSet: SemanticPaletteFactory.legacyFullscreenLyricsColorSet(
                    analysis: analysis,
                    scheme: scheme,
                    highlightBaseColor: palette.fullscreenLyricBase,
                    inactiveBaseColor: palette.fullscreenLyricInactiveBase,
                    isUltraDark: analysis.isUltraDark,
                    usesArtisticBackground: false
                ),
                semanticPalette: SemanticPaletteFactory.fullscreenLyricSemanticPalette(
                    analysis: analysis,
                    scheme: scheme,
                    highlightBaseColor: palette.fullscreenLyricBase,
                    inactiveBaseColor: palette.fullscreenLyricInactiveBase,
                    isUltraDark: analysis.isUltraDark,
                    usesArtisticBackground: false,
                    skinID: "coverLed/rotatingCover/kmgccc.cassette",
                    backgroundType: .standardSkin
                ),
                scheme: scheme,
                coverBlurProfile: nil,
                blendMode: "normal",
                analysis: analysis,
                routeNote: "Real user path for every fullscreen skin except fullscreen.coverGradientBlur and Apple style; fullscreenLyricDodgeMode=true makes colors opaque",
                to: &rows
            )

            let artisticSeed = SemanticPaletteFactory.artisticLyricsSingleSeed(
                preferred: palette.fullscreenLyricBase,
                averageBaseColor: palette.fullscreenLyricInactiveBase,
                analysis: analysis
            )
            appendFullscreenRows(
                sample: sample,
                sectionID: sectionID,
                schemeName: schemeName,
                mode: "artistic_background_fullscreen",
                skin: "non-CoverBlur fullscreen skins with fullscreenArtBackgroundEnabled=true",
                backgroundType: artisticSeed == nil
                    ? "artistic requested but seed missing; production falls back to standard fullscreen color set"
                    : "artistic fullscreen/BK art background; Swift roles are OKLCH-led before Web derivation",
                legacyColorSet: SemanticPaletteFactory.legacyFullscreenLyricsColorSet(
                    analysis: analysis,
                    scheme: scheme,
                    highlightBaseColor: palette.fullscreenLyricBase,
                    inactiveBaseColor: palette.fullscreenLyricInactiveBase,
                    isUltraDark: analysis.isUltraDark,
                    usesArtisticBackground: true
                ),
                semanticPalette: SemanticPaletteFactory.fullscreenLyricSemanticPalette(
                    analysis: analysis,
                    scheme: scheme,
                    highlightBaseColor: palette.fullscreenLyricBase,
                    inactiveBaseColor: palette.fullscreenLyricInactiveBase,
                    isUltraDark: analysis.isUltraDark,
                    usesArtisticBackground: true,
                    skinID: "coverLed/rotatingCover/kmgccc.cassette",
                    backgroundType: artisticSeed == nil ? .fallbackSkin : .artisticBackground
                ),
                scheme: scheme,
                coverBlurProfile: nil,
                blendMode: "normal",
                analysis: analysis,
                routeNote: artisticSeed == nil
                    ? "Compatibility fallback inside fullscreenLyricsColorSet(... usesArtisticBackground: true)"
                    : "Real user path when fullscreenArtBackgroundEnabled is true and artistic seed resolves",
                to: &rows
            )

            for profile in [LyricsCoverBlurBlendProfile.lighter, .darker] {
                let themeColor = analysis.averageColor
                let legacyColorSet = SemanticPaletteFactory.legacyCoverBlurLyricsColorSet(
                    analysis: analysis,
                    themeColor: themeColor,
                    profile: profile
                )
                let semanticPalette = SemanticPaletteFactory.coverBlurLyricSemanticPalette(
                    analysis: analysis,
                    themeColor: themeColor,
                    profile: profile,
                    mode: .coverBlur,
                    skinID: "fullscreen.coverGradientBlur"
                )
                appendFullscreenRows(
                    sample: sample,
                    sectionID: sectionID,
                    schemeName: schemeName,
                    mode: "cover_blur_generic_\(profile.rawValue)",
                    skin: "fullscreen.coverGradientBlur",
                    backgroundType: "generic CoverBlur fullscreen path; themeColor=averageColor; profile=\(profile.rawValue)",
                    legacyColorSet: legacyColorSet,
                    semanticPalette: semanticPalette,
                    scheme: profile.paletteScheme,
                    coverBlurProfile: profile,
                    blendMode: profile == .darker ? "plus-darker" : "plus-lighter",
                    analysis: analysis,
                    routeNote: "Current real CoverBlur path uses one fullscreen AMLL surface with coverBlurFullscreenGenericMode=true; visible bg roles come from --amll-fs-* plus profile opacity/weight",
                    to: &rows
                )
                appendDedicatedCoverBlurRows(
                    sample: sample,
                    sectionID: sectionID,
                    schemeName: schemeName,
                    profile: profile,
                    legacyColorSet: legacyColorSet,
                    semanticPalette: semanticPalette,
                    analysis: analysis,
                    to: &rows
                )
            }

            let appleThemeColor = palette.fullscreenLyricBase
            let appleLegacyColorSet = SemanticPaletteFactory.legacyCoverBlurLyricsColorSet(
                analysis: analysis,
                themeColor: appleThemeColor,
                profile: .lighter
            )
            let appleSemanticPalette = SemanticPaletteFactory.coverBlurLyricSemanticPalette(
                analysis: analysis,
                themeColor: appleThemeColor,
                profile: .lighter,
                mode: .appleStyle,
                skinID: "appleStyle"
            )
            appendFullscreenRows(
                sample: sample,
                sectionID: sectionID,
                schemeName: schemeName,
                mode: "apple_style_cover_blur_lighter",
                skin: "appleStyle",
                backgroundType: "Apple style skin reuses generic CoverBlur lyrics path with fixed lighter profile",
                legacyColorSet: appleLegacyColorSet,
                semanticPalette: appleSemanticPalette,
                scheme: LyricsCoverBlurBlendProfile.lighter.paletteScheme,
                coverBlurProfile: .lighter,
                blendMode: "plus-lighter",
                analysis: analysis,
                routeNote: "Current real Apple style lyrics path: makeAppleStyleCoverBlurLyricsTheme uses fullscreen base color and fixed lighter profile",
                to: &rows
            )
        }
    }

    private static func appendWindowRows(
        sample: GoldenSample,
        sectionID: String,
        schemeName: String,
        palette: SemanticPalette,
        analysis: ArtworkColorAnalysis,
        mode: String,
        skin: String,
        backgroundType: String,
        routeNote: String,
        to rows: inout [LyricsParityRow]
    ) {
        let active = palette.windowLyricActive
        let inactive = palette.windowLyricInactive
        let adapterNotes = "base theme vars only: --amll-text=active, --amll-active=active, --amll-inactive=inactive"
        let roles = [
            LyricsAdapterRole(
                roleGroup: "active",
                role: "window_active",
                legacySwiftRole: "ThemePalette.activeLine / --amll-active",
                legacySwiftColor: active,
                legacySwiftCSS: ArtworkColorExtractor.cssRGBA(active, alpha: active.alphaComponent),
                finalColor: active,
                effectiveAlpha: active.alphaComponent,
                finalCSS: ArtworkColorExtractor.cssRGBA(active, alpha: active.alphaComponent),
                webDerivedRole: "--amll-active",
                formula: "direct ThemePalette var",
                notes: adapterNotes,
                blendMode: "normal"
            ),
            LyricsAdapterRole(
                roleGroup: "inactive",
                role: "window_inactive",
                legacySwiftRole: "ThemePalette.inactiveLine / --amll-inactive",
                legacySwiftColor: inactive,
                legacySwiftCSS: ArtworkColorExtractor.cssRGBA(inactive, alpha: inactive.alphaComponent),
                finalColor: inactive,
                effectiveAlpha: inactive.alphaComponent,
                finalCSS: ArtworkColorExtractor.cssRGBA(inactive, alpha: inactive.alphaComponent),
                webDerivedRole: "--amll-inactive",
                formula: "direct ThemePalette var",
                notes: adapterNotes,
                blendMode: "normal"
            ),
            LyricsAdapterRole(
                roleGroup: "secondary",
                role: "window_secondary_inherited",
                legacySwiftRole: "AMLL secondary inherits text/inactive vars",
                legacySwiftColor: inactive,
                legacySwiftCSS: ArtworkColorExtractor.cssRGBA(inactive, alpha: inactive.alphaComponent),
                finalColor: inactive,
                effectiveAlpha: inactive.alphaComponent,
                finalCSS: ArtworkColorExtractor.cssRGBA(inactive, alpha: inactive.alphaComponent),
                webDerivedRole: "inherited --amll-inactive",
                formula: "no App adapter secondary color in window mode",
                notes: adapterNotes,
                blendMode: "normal"
            ),
            LyricsAdapterRole(
                roleGroup: "background_lyric",
                role: "window_background_lyric_inherited",
                legacySwiftRole: "AMLL background line fallback",
                legacySwiftColor: inactive,
                legacySwiftCSS: ArtworkColorExtractor.cssRGBA(inactive, alpha: inactive.alphaComponent),
                finalColor: inactive,
                effectiveAlpha: inactive.alphaComponent,
                finalCSS: ArtworkColorExtractor.cssRGBA(inactive, alpha: inactive.alphaComponent),
                webDerivedRole: "inherited --amll-inactive",
                formula: "no fullscreen background derivation in window mode",
                notes: adapterNotes,
                blendMode: "normal"
            ),
        ]
        appendRows(
            sample: sample,
            sectionID: sectionID,
            schemeName: schemeName,
            mode: mode,
            skin: skin,
            backgroundType: backgroundType,
            roles: roles,
            analysis: analysis,
            backgroundL: schemeName == "dark" ? 0.08 : 0.94,
            routeNote: routeNote,
            to: &rows
        )
    }

    private static func appendFullscreenRows(
        sample: GoldenSample,
        sectionID: String,
        schemeName: String,
        mode: String,
        skin: String,
        backgroundType: String,
        legacyColorSet: LyricsSurfaceColorSet,
        semanticPalette: FullscreenLyricSemanticPalette,
        scheme: ColorScheme,
        coverBlurProfile: LyricsCoverBlurBlendProfile?,
        blendMode: String,
        analysis: ArtworkColorAnalysis,
        routeNote: String,
        to rows: inout [LyricsParityRow]
    ) {
        let adapter = FullscreenLyricsAdapterModel(
            legacyColorSet: legacyColorSet,
            semanticPalette: semanticPalette,
            scheme: scheme,
            coverBlurProfile: coverBlurProfile,
            blendMode: blendMode
        )
        appendRows(
            sample: sample,
            sectionID: sectionID,
            schemeName: schemeName,
            mode: mode,
            skin: skin,
            backgroundType: backgroundType,
            roles: adapter.roles,
            analysis: analysis,
            backgroundL: adapter.backgroundL,
            routeNote: routeNote,
            to: &rows
        )
    }

    private static func appendDedicatedCoverBlurRows(
        sample: GoldenSample,
        sectionID: String,
        schemeName: String,
        profile: LyricsCoverBlurBlendProfile,
        legacyColorSet: LyricsSurfaceColorSet,
        semanticPalette: FullscreenLyricSemanticPalette,
        analysis: ArtworkColorAnalysis,
        to rows: inout [LyricsParityRow]
    ) {
        let adapter = DedicatedCoverBlurAdapterModel(
            legacyColorSet: legacyColorSet,
            semanticPalette: semanticPalette,
            profile: profile
        )
        appendRows(
            sample: sample,
            sectionID: sectionID,
            schemeName: schemeName,
            mode: "cover_blur_dedicated_compat_\(profile.rawValue)",
            skin: "fullscreenCoverBlurHighlight compatibility",
            backgroundType: "dedicated .amll-surface-fullscreen-cover-blur model; second overlay currently disabled",
            roles: adapter.roles,
            analysis: analysis,
            backgroundL: adapter.backgroundL,
            routeNote: "Compatibility model for existing index.html --amll-cb-* derivations; current product keeps shouldRenderCoverBlurHighlightOverlay=false",
            to: &rows
        )
    }

    private static func appendRows(
        sample: GoldenSample,
        sectionID: String,
        schemeName: String,
        mode: String,
        skin: String,
        backgroundType: String,
        roles: [LyricsAdapterRole],
        analysis: ArtworkColorAnalysis,
        backgroundL: CGFloat,
        routeNote: String,
        to rows: inout [LyricsParityRow]
    ) {
        let hierarchy = LyricsHierarchyMetrics(roles: roles, backgroundL: backgroundL)
        for role in roles {
            let diff = ColorDifference(legacy: role.legacySwiftColor, candidate: role.finalColor)
            let fallback = P3FallbackMetrics(color: role.finalColor)
            let riskTags = classify(
                mode: mode,
                role: role,
                analysis: analysis,
                hierarchy: hierarchy,
                fallback: fallback
            )
            rows.append(
                LyricsParityRow(
                    sample: sample.id,
                    sectionID: sectionID,
                    scheme: schemeName,
                    mode: mode,
                    skin: skin,
                    backgroundType: backgroundType,
                    adapterRole: role,
                    diff: diff,
                    hierarchy: hierarchy,
                    fallback: fallback,
                    riskTags: riskTags,
                    routeNote: routeNote
                )
            )
        }
    }

    private static func classify(
        mode: String,
        role: LyricsAdapterRole,
        analysis: ArtworkColorAnalysis,
        hierarchy: LyricsHierarchyMetrics,
        fallback: P3FallbackMetrics
    ) -> [String] {
        var tags: [String] = []
        if hierarchy.hasHierarchyRisk {
            tags.append("hierarchy-risk")
        }
        if role.effectiveAlpha < 0.999 {
            if mode.contains("fullscreen") || mode.contains("cover_blur") || mode.contains("apple_style") {
                if role.roleGroup == "active" || role.roleGroup == "inactive" || role.roleGroup == "secondary" {
                    tags.append("alpha-contamination")
                } else {
                    tags.append("alpha-hierarchy")
                }
            } else if role.roleGroup != "active" {
                tags.append("alpha-hierarchy")
            }
        }
        if fallback.hasFallbackShift {
            tags.append("p3-fallback-shift")
        }
        if analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate {
            let c = OKColor.nsColorToOKLCH(role.finalColor)?.c ?? 0
            if c > 0.020 {
                tags.append("near-mono-risk")
            }
        }
        if mode.contains("cover_blur") || mode.contains("apple_style") {
            if role.blendMode.contains("plus-") || role.roleGroup == "background_lyric" {
                tags.append("cover-blur-pollution")
            }
        }
        return tags.isEmpty ? ["preserve"] : Array(Set(tags)).sorted()
    }
}

struct LyricsAdapterRole {
    let roleGroup: String
    let role: String
    let legacySwiftRole: String
    let legacySwiftColor: NSColor
    let legacySwiftCSS: String
    let finalColor: NSColor
    let effectiveAlpha: CGFloat
    let finalCSS: String
    let webDerivedRole: String
    let formula: String
    let notes: String
    let blendMode: String
}

struct LyricsParityRow {
    let sample: String
    let sectionID: String
    let scheme: String
    let mode: String
    let skin: String
    let backgroundType: String
    let adapterRole: LyricsAdapterRole
    let diff: ColorDifference
    let hierarchy: LyricsHierarchyMetrics
    let fallback: P3FallbackMetrics
    let riskTags: [String]
    let routeNote: String

    var tsvLine: String {
        [
            sample,
            sectionID,
            scheme,
            mode,
            skin,
            backgroundType,
            adapterRole.roleGroup,
            adapterRole.role,
            adapterRole.legacySwiftRole,
            adapterRole.legacySwiftCSS,
            ColorGoldenMasterSupport.lchDescription(OKColor.nsColorToOKLCH(adapterRole.legacySwiftColor)),
            ColorGoldenMasterSupport.f(adapterRole.effectiveAlpha),
            adapterRole.finalCSS,
            ColorGoldenMasterSupport.colorDescription(adapterRole.finalColor),
            candidateCSS,
            candidateOKLCH,
            ColorGoldenMasterLyricsParity.candidatePolicy,
            displayP3Output,
            sRGBFallback,
            adapterRole.webDerivedRole,
            adapterRole.formula,
            adapterRole.notes,
            adapterRole.blendMode,
            ColorGoldenMasterSupport.f(diff.deltaL),
            ColorGoldenMasterSupport.f(diff.deltaC),
            ColorGoldenMasterSupport.f(diff.deltaH),
            ColorGoldenMasterSupport.f(diff.deltaEOKLab),
            hierarchy.description,
            riskTags.joined(separator: ","),
            routeNote,
        ].map(sanitizeTSV).joined(separator: "\t")
    }

    var displayP3Output: String {
        ColorRenderingAdapter.makeCSSColor(adapterRole.finalColor, target: .displayP3)
            ?? ColorRenderingAdapter.makeCSSSRGBFallback(adapterRole.finalColor)
            ?? adapterRole.finalCSS
    }

    var sRGBFallback: String {
        ColorRenderingAdapter.makeCSSSRGBFallback(adapterRole.finalColor) ?? adapterRole.finalCSS
    }

    var candidateCSS: String { adapterRole.finalCSS }

    var candidateOKLCH: String {
        ColorGoldenMasterSupport.colorDescription(adapterRole.finalColor)
    }

    private func sanitizeTSV(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

struct FullscreenLyricsAdapterModel {
    let legacyColorSet: LyricsSurfaceColorSet
    let semanticPalette: FullscreenLyricSemanticPalette
    let scheme: ColorScheme
    let coverBlurProfile: LyricsCoverBlurBlendProfile?
    let blendMode: String

    var backgroundL: CGFloat {
        switch coverBlurProfile {
        case .lighter:
            return 0.12
        case .darker:
            return 0.90
        case .none:
            return scheme == .dark ? 0.08 : 0.92
        }
    }

    var roles: [LyricsAdapterRole] {
        combinedRoles(
            legacy: legacyRoles,
            candidate: candidateRoles
        )
    }

    private var legacyRoles: [LyricsAdapterRole] {
        let profileName = coverBlurProfile?.rawValue ?? "none"
        let baseOpacity = fullscreenBackgroundBaseOpacity(profile: coverBlurProfile)
        let karaokeOpacity = fullscreenBackgroundKaraokeOpacity(profile: coverBlurProfile)
        let karaokeWeight = fullscreenBackgroundKaraokeWeight(profile: coverBlurProfile)
        let active = LyricsColorWebModel.opaque(legacyColorSet.mainActive)
        let inactive = LyricsColorWebModel.opaque(legacyColorSet.mainInactive)
        let subInactive = LyricsColorWebModel.opaque(legacyColorSet.subInactive)
        let lineTimingInactive = LyricsColorWebModel.opaque(legacyColorSet.lineTimingMainInactive)
        let bgActive = LyricsColorWebModel.opaque(legacyColorSet.subActive)
        let bgKaraoke = LyricsColorWebModel.mixedOpaque(
            foreground: legacyColorSet.mainActive,
            background: legacyColorSet.mainInactive,
            foregroundWeight: karaokeWeight
        )
        let notes = "fullscreenOpaqueLyricsMode=true; toOpaqueColor strips rgba alpha; profile=\(profileName)"
        return [
            role(
                group: "active",
                name: "fs_main_active",
                source: legacyColorSet.mainActive,
                final: active,
                alpha: 1,
                cssVar: "--amll-fs-main-active",
                formula: "toOpaqueColor(fullscreenActiveColor)",
                notes: notes
            ),
            role(
                group: "inactive",
                name: "fs_main_inactive",
                source: legacyColorSet.mainInactive,
                final: inactive,
                alpha: 1,
                cssVar: "--amll-fs-main-inactive",
                formula: "toOpaqueColor(fullscreenInactiveColor)",
                notes: notes
            ),
            role(
                group: "secondary",
                name: "fs_sub_color",
                source: legacyColorSet.subInactive,
                final: subInactive,
                alpha: 1,
                cssVar: "--amll-fs-sub-color",
                formula: "resolve --amll-fs-sub-inactive then set --amll-fs-sub-color",
                notes: notes + "; active and inactive sub lines are unified to sub-inactive"
            ),
            role(
                group: "secondary",
                name: "fs_line_timing_inactive",
                source: legacyColorSet.lineTimingMainInactive,
                final: lineTimingInactive,
                alpha: 1,
                cssVar: "--amll-fs-main-line-timing-inactive",
                formula: "toOpaqueColor(fullscreenLineTimingInactiveColor)",
                notes: notes
            ),
            role(
                group: "background_lyric",
                name: "fs_bg_inactive",
                source: legacyColorSet.mainInactive,
                final: inactive.withAlphaComponent(baseOpacity),
                alpha: baseOpacity,
                cssVar: "--amll-fs-bg-inactive",
                formula: "set from --amll-fs-main-inactive; CSS opacity=\(ColorGoldenMasterSupport.f(baseOpacity))",
                notes: notes
            ),
            role(
                group: "background_lyric",
                name: "fs_bg_active_explicit",
                source: legacyColorSet.subActive,
                final: bgActive,
                alpha: 1,
                cssVar: "--amll-fs-bg-active",
                formula: "explicit fullscreenBackgroundColor=colorSet.subActive",
                notes: notes
            ),
            role(
                group: "background_lyric",
                name: "fs_bg_karaoke_active",
                source: legacyColorSet.mainActive,
                final: bgKaraoke.withAlphaComponent(karaokeOpacity),
                alpha: karaokeOpacity,
                cssVar: "--amll-fs-bg-karaoke-active",
                formula: "mix mainActive/mainInactive in sRGB weight=\(ColorGoldenMasterSupport.f(karaokeWeight)); CSS opacity=\(ColorGoldenMasterSupport.f(karaokeOpacity))",
                notes: notes
            ),
        ]
    }

    private var candidateRoles: [LyricsAdapterRole] {
        let notes = "Swift FullscreenLyricSemanticPalette direct role; Web adapter only consumes P3/sRGB payload, opacity, blend, and masks"
        return [
            semanticRole(group: "active", name: "fs_main_active", role: semanticPalette.mainActive, alpha: 1, cssVar: "--amll-fs-main-active", formula: "direct fullscreenActiveColor payload", notes: notes),
            semanticRole(group: "inactive", name: "fs_main_inactive", role: semanticPalette.mainInactive, alpha: 1, cssVar: "--amll-fs-main-inactive", formula: "direct fullscreenInactiveColor payload", notes: notes),
            semanticRole(group: "secondary", name: "fs_sub_color", role: semanticPalette.subColor, alpha: 1, cssVar: "--amll-fs-sub-color", formula: "direct fullscreenSubColor payload", notes: notes),
            semanticRole(group: "secondary", name: "fs_line_timing_inactive", role: semanticPalette.lineTimingMainInactive, alpha: 1, cssVar: "--amll-fs-main-line-timing-inactive", formula: "direct fullscreenLineTimingInactiveColor payload", notes: notes),
            semanticRole(group: "background_lyric", name: "fs_bg_inactive", role: semanticPalette.backgroundInactive, alpha: semanticPalette.alpha.backgroundBaseOpacity, cssVar: "--amll-fs-bg-inactive", formula: "direct fullscreenBackgroundInactiveColor payload; renderer opacity=\(ColorGoldenMasterSupport.f(semanticPalette.alpha.backgroundBaseOpacity))", notes: notes),
            semanticRole(group: "background_lyric", name: "fs_bg_active_explicit", role: semanticPalette.backgroundActive, alpha: 1, cssVar: "--amll-fs-bg-active", formula: "direct fullscreenBackgroundColor payload", notes: notes),
            semanticRole(group: "background_lyric", name: "fs_bg_karaoke_active", role: semanticPalette.backgroundKaraokeActive, alpha: semanticPalette.alpha.backgroundKaraokeOpacity, cssVar: "--amll-fs-bg-karaoke-active", formula: "direct fullscreenBackgroundKaraokeActiveColor payload; renderer opacity=\(ColorGoldenMasterSupport.f(semanticPalette.alpha.backgroundKaraokeOpacity))", notes: notes),
        ]
    }

    private func role(
        group: String,
        name: String,
        source: NSColor,
        final: NSColor,
        alpha: CGFloat,
        cssVar: String,
        formula: String,
        notes: String
    ) -> LyricsAdapterRole {
        LyricsAdapterRole(
            roleGroup: group,
            role: name,
            legacySwiftRole: cssVar,
            legacySwiftColor: source,
            legacySwiftCSS: ArtworkColorExtractor.cssRGBA(source, alpha: source.alphaComponent),
            finalColor: final.withAlphaComponent(alpha),
            effectiveAlpha: alpha,
            finalCSS: ArtworkColorExtractor.cssRGBA(final, alpha: alpha),
            webDerivedRole: cssVar,
            formula: formula,
            notes: notes,
            blendMode: blendMode
        )
    }

    private func semanticRole(
        group: String,
        name: String,
        role: LyricSemanticRoleColor,
        alpha: CGFloat,
        cssVar: String,
        formula: String,
        notes: String
    ) -> LyricsAdapterRole {
        let final = role.nsColor.withAlphaComponent(alpha)
        return LyricsAdapterRole(
            roleGroup: group,
            role: name,
            legacySwiftRole: cssVar,
            legacySwiftColor: final,
            legacySwiftCSS: LyricRenderingAdapter.cssFallback(role, alpha: alpha),
            finalColor: final,
            effectiveAlpha: alpha,
            finalCSS: LyricRenderingAdapter.cssFallback(role, alpha: alpha),
            webDerivedRole: cssVar,
            formula: formula,
            notes: notes,
            blendMode: blendMode
        )
    }

    private func combinedRoles(
        legacy: [LyricsAdapterRole],
        candidate: [LyricsAdapterRole]
    ) -> [LyricsAdapterRole] {
        let legacyByName = Dictionary(uniqueKeysWithValues: legacy.map { ($0.role, $0) })
        return candidate.map { candidateRole in
            guard let legacyRole = legacyByName[candidateRole.role] else { return candidateRole }
            return LyricsAdapterRole(
                roleGroup: candidateRole.roleGroup,
                role: candidateRole.role,
                legacySwiftRole: legacyRole.webDerivedRole,
                legacySwiftColor: legacyRole.finalColor,
                legacySwiftCSS: legacyRole.finalCSS,
                finalColor: candidateRole.finalColor,
                effectiveAlpha: candidateRole.effectiveAlpha,
                finalCSS: candidateRole.finalCSS,
                webDerivedRole: candidateRole.webDerivedRole,
                formula: "\(candidateRole.formula); legacy=\(legacyRole.formula)",
                notes: "\(candidateRole.notes); legacy_notes=\(legacyRole.notes)",
                blendMode: candidateRole.blendMode
            )
        }
    }

    private func fullscreenBackgroundBaseOpacity(profile: LyricsCoverBlurBlendProfile?) -> CGFloat {
        switch profile {
        case .lighter:
            return 0.38
        case .darker:
            return 0.48
        case .none:
            return 0.46
        }
    }

    private func fullscreenBackgroundKaraokeOpacity(profile: LyricsCoverBlurBlendProfile?) -> CGFloat {
        switch profile {
        case .lighter:
            return 0.82
        case .darker:
            return 0.86
        case .none:
            return 0.86
        }
    }

    private func fullscreenBackgroundKaraokeWeight(profile: LyricsCoverBlurBlendProfile?) -> CGFloat {
        profile == .lighter ? 0.90 : 0.88
    }
}

struct DedicatedCoverBlurAdapterModel {
    let legacyColorSet: LyricsSurfaceColorSet
    let semanticPalette: FullscreenLyricSemanticPalette
    let profile: LyricsCoverBlurBlendProfile

    var backgroundL: CGFloat { profile == .lighter ? 0.12 : 0.90 }

    var roles: [LyricsAdapterRole] {
        let legacy = legacyRoles
        let candidate = candidateRoles
        let legacyByName = Dictionary(uniqueKeysWithValues: legacy.map { ($0.role, $0) })
        return candidate.map { candidateRole in
            guard let legacyRole = legacyByName[candidateRole.role] else { return candidateRole }
            return LyricsAdapterRole(
                roleGroup: candidateRole.roleGroup,
                role: candidateRole.role,
                legacySwiftRole: legacyRole.webDerivedRole,
                legacySwiftColor: legacyRole.finalColor,
                legacySwiftCSS: legacyRole.finalCSS,
                finalColor: candidateRole.finalColor,
                effectiveAlpha: candidateRole.effectiveAlpha,
                finalCSS: candidateRole.finalCSS,
                webDerivedRole: candidateRole.webDerivedRole,
                formula: "\(candidateRole.formula); legacy=\(legacyRole.formula)",
                notes: "\(candidateRole.notes); legacy_notes=\(legacyRole.notes)",
                blendMode: candidateRole.blendMode
            )
        }
    }

    private var legacyRoles: [LyricsAdapterRole] {
        let baseOpacity: CGFloat = profile == .lighter ? 0.34 : 0.44
        let karaokeOpacity: CGFloat = profile == .lighter ? 0.80 : 0.86
        let karaokeWeight: CGFloat = profile == .lighter ? 0.90 : 0.86
        let blendMode = profile == .darker ? "plus-darker" : "plus-lighter"
        let active = LyricsColorWebModel.opaque(legacyColorSet.mainActive)
        let inactive = LyricsColorWebModel.opaque(legacyColorSet.mainInactive)
        let subInactive = LyricsColorWebModel.opaque(legacyColorSet.subInactive)
        let lineTimingInactive = LyricsColorWebModel.opaque(legacyColorSet.lineTimingMainInactive)
        let bgActive = LyricsColorWebModel.opaque(legacyColorSet.subActive)
        let bgKaraoke = LyricsColorWebModel.mixedOpaque(
            foreground: legacyColorSet.mainActive,
            background: legacyColorSet.mainInactive,
            foregroundWeight: karaokeWeight
        )
        let notes = "dedicated .amll-surface-fullscreen-cover-blur compatibility model; current second overlay disabled"

        func role(
            group: String,
            name: String,
            source: NSColor,
            final: NSColor,
            alpha: CGFloat,
            cssVar: String,
            formula: String
        ) -> LyricsAdapterRole {
            LyricsAdapterRole(
                roleGroup: group,
                role: name,
                legacySwiftRole: cssVar,
                legacySwiftColor: source,
                legacySwiftCSS: ArtworkColorExtractor.cssRGBA(source, alpha: source.alphaComponent),
                finalColor: final.withAlphaComponent(alpha),
                effectiveAlpha: alpha,
                finalCSS: ArtworkColorExtractor.cssRGBA(final, alpha: alpha),
                webDerivedRole: cssVar,
                formula: formula,
                notes: notes,
                blendMode: blendMode
            )
        }

        return [
            role(group: "active", name: "cb_main_active", source: legacyColorSet.mainActive, final: active, alpha: 1, cssVar: "--amll-cb-main-active", formula: "direct coverBlurMainActiveColor"),
            role(group: "inactive", name: "cb_main_inactive", source: legacyColorSet.mainInactive, final: inactive, alpha: 1, cssVar: "--amll-cb-main-inactive", formula: "direct coverBlurMainInactiveColor"),
            role(group: "secondary", name: "cb_sub_color", source: legacyColorSet.subInactive, final: subInactive, alpha: 1, cssVar: "--amll-cb-sub-color", formula: "resolve --amll-cb-sub-inactive then set --amll-cb-sub-color"),
            role(group: "secondary", name: "cb_line_timing_inactive", source: legacyColorSet.lineTimingMainInactive, final: lineTimingInactive, alpha: 1, cssVar: "--amll-cb-main-line-timing-inactive", formula: "direct coverBlurLineTimingInactiveColor"),
            role(group: "background_lyric", name: "cb_bg_inactive", source: legacyColorSet.mainInactive, final: inactive, alpha: baseOpacity, cssVar: "--amll-cb-bg-inactive", formula: "set from --amll-cb-main-inactive; CSS opacity=\(ColorGoldenMasterSupport.f(baseOpacity))"),
            role(group: "background_lyric", name: "cb_bg_active_explicit", source: legacyColorSet.subActive, final: bgActive, alpha: 1, cssVar: "--amll-cb-bg-active", formula: "explicit coverBlurBackgroundColor=colorSet.subActive"),
            role(group: "background_lyric", name: "cb_bg_karaoke_active", source: legacyColorSet.mainActive, final: bgKaraoke, alpha: karaokeOpacity, cssVar: "--amll-cb-bg-karaoke-active", formula: "mix mainActive/mainInactive in sRGB weight=\(ColorGoldenMasterSupport.f(karaokeWeight)); CSS opacity=\(ColorGoldenMasterSupport.f(karaokeOpacity))"),
        ]
    }

    private var candidateRoles: [LyricsAdapterRole] {
        let blendMode = profile == .darker ? "plus-darker" : "plus-lighter"
        let notes = "Swift FullscreenLyricSemanticPalette direct role for disabled/dedicated CoverBlur compatibility branch"

        func role(
            group: String,
            name: String,
            semantic: LyricSemanticRoleColor,
            alpha: CGFloat,
            cssVar: String,
            formula: String
        ) -> LyricsAdapterRole {
            let final = semantic.nsColor.withAlphaComponent(alpha)
            return LyricsAdapterRole(
                roleGroup: group,
                role: name,
                legacySwiftRole: cssVar,
                legacySwiftColor: final,
                legacySwiftCSS: LyricRenderingAdapter.cssFallback(semantic, alpha: alpha),
                finalColor: final,
                effectiveAlpha: alpha,
                finalCSS: LyricRenderingAdapter.cssFallback(semantic, alpha: alpha),
                webDerivedRole: cssVar,
                formula: formula,
                notes: notes,
                blendMode: blendMode
            )
        }

        return [
            role(group: "active", name: "cb_main_active", semantic: semanticPalette.mainActive, alpha: 1, cssVar: "--amll-cb-main-active", formula: "direct coverBlurMainActiveColor payload"),
            role(group: "inactive", name: "cb_main_inactive", semantic: semanticPalette.mainInactive, alpha: 1, cssVar: "--amll-cb-main-inactive", formula: "direct coverBlurMainInactiveColor payload"),
            role(group: "secondary", name: "cb_sub_color", semantic: semanticPalette.subColor, alpha: 1, cssVar: "--amll-cb-sub-color", formula: "direct coverBlurSubColor payload"),
            role(group: "secondary", name: "cb_line_timing_inactive", semantic: semanticPalette.lineTimingMainInactive, alpha: 1, cssVar: "--amll-cb-main-line-timing-inactive", formula: "direct coverBlurLineTimingInactiveColor payload"),
            role(group: "background_lyric", name: "cb_bg_inactive", semantic: semanticPalette.backgroundInactive, alpha: semanticPalette.alpha.dedicatedCoverBlurBackgroundBaseOpacity, cssVar: "--amll-cb-bg-inactive", formula: "direct coverBlurBackgroundInactiveColor payload; renderer opacity=\(ColorGoldenMasterSupport.f(semanticPalette.alpha.dedicatedCoverBlurBackgroundBaseOpacity))"),
            role(group: "background_lyric", name: "cb_bg_active_explicit", semantic: semanticPalette.backgroundActive, alpha: 1, cssVar: "--amll-cb-bg-active", formula: "direct coverBlurBackgroundColor payload"),
            role(group: "background_lyric", name: "cb_bg_karaoke_active", semantic: semanticPalette.backgroundKaraokeActive, alpha: semanticPalette.alpha.dedicatedCoverBlurBackgroundKaraokeOpacity, cssVar: "--amll-cb-bg-karaoke-active", formula: "direct coverBlurBackgroundKaraokeActiveColor payload; renderer opacity=\(ColorGoldenMasterSupport.f(semanticPalette.alpha.dedicatedCoverBlurBackgroundKaraokeOpacity))"),
        ]
    }
}

enum LyricsColorWebModel {
    static func opaque(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return NSColor(
            deviceRed: rgb.redComponent,
            green: rgb.greenComponent,
            blue: rgb.blueComponent,
            alpha: 1
        )
    }

    static func mixedOpaque(
        foreground: NSColor,
        background: NSColor,
        foregroundWeight: CGFloat
    ) -> NSColor {
        let fg = rgba(foreground)
        let bg = rgba(background)
        let w = ColorMath.clamp(foregroundWeight, 0, 1)
        let r = round(fg.r * w + bg.r * (1 - w))
        let g = round(fg.g * w + bg.g * (1 - w))
        let b = round(fg.b * w + bg.b * (1 - w))
        return NSColor(
            deviceRed: ColorMath.clamp(r / 255, 0, 1),
            green: ColorMath.clamp(g / 255, 0, 1),
            blue: ColorMath.clamp(b / 255, 0, 1),
            alpha: 1
        )
    }

    private static func rgba(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return (
            ColorMath.clamp(rgb.redComponent * 255, 0, 255),
            ColorMath.clamp(rgb.greenComponent * 255, 0, 255),
            ColorMath.clamp(rgb.blueComponent * 255, 0, 255),
            ColorMath.clamp(rgb.alphaComponent, 0, 1)
        )
    }
}

struct LyricsHierarchyMetrics {
    let activeProminence: CGFloat
    let inactiveProminence: CGFloat
    let secondaryProminence: CGFloat
    let backgroundProminence: CGFloat
    let expectedPolarity: String

    init(roles: [LyricsAdapterRole], backgroundL: CGFloat) {
        func prominence(_ roleGroup: String) -> CGFloat {
            guard let color = roles.first(where: { $0.roleGroup == roleGroup })?.finalColor,
                  let l = OKColor.nsColorToOKLCH(color)?.l else {
                return 0
            }
            return abs(l - backgroundL)
        }

        activeProminence = prominence("active")
        inactiveProminence = prominence("inactive")
        secondaryProminence = prominence("secondary")
        backgroundProminence = prominence("background_lyric")
        expectedPolarity = backgroundL < 0.5 ? "light-on-dark" : "dark-on-light"
    }

    var hasHierarchyRisk: Bool {
        activeProminence + 0.010 < inactiveProminence
            || activeProminence + 0.010 < secondaryProminence
            || activeProminence + 0.020 < backgroundProminence
    }

    var description: String {
        [
            "polarity=\(expectedPolarity)",
            "active=\(ColorGoldenMasterSupport.f(activeProminence))",
            "inactive=\(ColorGoldenMasterSupport.f(inactiveProminence))",
            "secondary=\(ColorGoldenMasterSupport.f(secondaryProminence))",
            "background=\(ColorGoldenMasterSupport.f(backgroundProminence))",
            "active_gt_inactive=\(ColorGoldenMasterSupport.bool(activeProminence >= inactiveProminence - 0.010))",
            "active_gt_secondary=\(ColorGoldenMasterSupport.bool(activeProminence >= secondaryProminence - 0.010))",
            "active_gt_background=\(ColorGoldenMasterSupport.bool(activeProminence >= backgroundProminence - 0.020))",
        ].joined(separator: ",")
    }
}

struct P3FallbackMetrics {
    let displayP3Chroma: CGFloat
    let sRGBChroma: CGFloat
    let displayP3L: CGFloat
    let sRGBL: CGFloat
    let wasGamutMapped: Bool

    init(color: NSColor) {
        let p3 = ColorRenderingAdapter.resolve(color, target: .displayP3)
        let sRGB = ColorRenderingAdapter.resolve(color, target: .sRGB)
        displayP3Chroma = CGFloat(p3?.resolvedChroma ?? 0)
        sRGBChroma = CGFloat(sRGB?.resolvedChroma ?? 0)
        displayP3L = CGFloat(OKColor.nsColorToOKLCH(ColorRenderingAdapter.makeNSColor(color, target: .displayP3))?.l ?? 0)
        sRGBL = CGFloat(OKColor.nsColorToOKLCH(ColorRenderingAdapter.makeNSColor(color, target: .sRGB))?.l ?? 0)
        wasGamutMapped = sRGB?.wasGamutMapped ?? false
    }

    var hasFallbackShift: Bool {
        wasGamutMapped || abs(displayP3L - sRGBL) > 0.018 || abs(displayP3Chroma - sRGBChroma) > 0.020
    }
}

enum LyricsParityReviewArtifact {
    static func render(rows: [LyricsParityRow], summary: LyricsParitySummary) -> String {
        let reviewRows = selectedRowsForReview(rows)
        let grouped = Dictionary(grouping: reviewRows) { row in
            "\(row.sample)::\(row.scheme)::\(row.mode)"
        }
        var seenKeys: Set<String> = []
        var orderedKeys: [String] = []
        for row in reviewRows {
            let key = "\(row.sample)::\(row.scheme)::\(row.mode)"
            if seenKeys.insert(key).inserted {
                orderedKeys.append(key)
            }
        }
        let cards = orderedKeys.map { key -> String in
            let groupRows = (grouped[key] ?? []).sorted { $0.adapterRole.role < $1.adapterRole.role }
            guard let first = groupRows.first else { return "" }
            let roles = ["active", "inactive", "secondary", "background_lyric"].compactMap { group in
                groupRows.first(where: { $0.adapterRole.roleGroup == group })
            }
            let extras = groupRows.filter { row in
                !roles.contains { $0.adapterRole.role == row.adapterRole.role }
            }
            return card(first: first, roles: roles, extras: extras)
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Lyrics Parity Review</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; font: 13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f6f6f3; color: #1f2328; }
        main { max-width: 1480px; margin: 0 auto; padding: 24px; }
        h1 { margin: 0 0 6px; font-size: 24px; }
        .summary { margin: 0 0 18px; color: #59636e; }
        .card { border: 1px solid #d7d7d0; border-radius: 8px; background: #fff; margin: 14px 0; padding: 14px; }
        .card.risk { border-color: #b7791f; }
        header { display: flex; justify-content: space-between; gap: 16px; align-items: flex-start; margin-bottom: 10px; }
        h2 { font-size: 15px; margin: 0; }
        p { margin: 3px 0 0; }
        .meta, .metrics, .route { color: #59636e; word-break: break-word; }
        .roles { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 10px; margin-top: 12px; }
        .role { border: 1px solid #e4e4df; border-radius: 6px; padding: 10px; background: #fbfbf9; }
        .role-title { display: flex; justify-content: space-between; gap: 8px; margin-bottom: 8px; font-weight: 600; }
        .swatches { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }
        .swatch { min-height: 54px; border-radius: 6px; border: 1px solid rgba(0,0,0,.14); background-clip: padding-box; }
        .caption { margin-top: 4px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: #4b5563; word-break: break-word; }
        .sample-line { display: grid; grid-template-columns: 1fr; gap: 5px; margin-top: 8px; padding: 9px; border-radius: 6px; background: #101114; }
        .sample-line.light { background: #f0eee8; }
        .lyric { font-size: 18px; font-weight: 700; line-height: 1.22; }
        .extras { margin-top: 8px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: #59636e; }
        </style>
        </head>
        <body>
        <main>
          <h1>Lyrics Parity Review</h1>
          <p class="summary">\(escape(summary.statusLine)) &middot; candidate fields are the fullscreen OKLCH semantic palette now used by production; legacy columns retain rollback/parity output.</p>
          \(cards)
        </main>
        </body>
        </html>
        """
    }

    private static func selectedRowsForReview(_ rows: [LyricsParityRow]) -> [LyricsParityRow] {
        let primary = rows.filter { $0.sectionID == "golden_gate" || $0.sectionID == "synthetic" }
        let riskExtended = rows
            .filter { $0.sectionID == "extended_corpus" && $0.riskTags != ["preserve"] }
            .sorted {
                if $0.sample != $1.sample { return $0.sample < $1.sample }
                if $0.mode != $1.mode { return $0.mode < $1.mode }
                if $0.scheme != $1.scheme { return $0.scheme < $1.scheme }
                return $0.adapterRole.role < $1.adapterRole.role
            }
            .prefix(240)
        return primary + Array(riskExtended)
    }

    private static func card(
        first: LyricsParityRow,
        roles: [LyricsParityRow],
        extras: [LyricsParityRow]
    ) -> String {
        let roleBlocks = roles.map(roleBlock(from:)).joined(separator: "\n")
        let risk = roles.flatMap(\.riskTags).contains { $0 != "preserve" }
        let active = roles.first(where: { $0.adapterRole.roleGroup == "active" })?.displayP3Output ?? "#fff"
        let inactive = roles.first(where: { $0.adapterRole.roleGroup == "inactive" })?.displayP3Output ?? "#bbb"
        let secondary = roles.first(where: { $0.adapterRole.roleGroup == "secondary" })?.displayP3Output ?? "#999"
        let background = roles.first(where: { $0.adapterRole.roleGroup == "background_lyric" })?.displayP3Output ?? "#777"
        let sampleClass = first.hierarchy.expectedPolarity == "dark-on-light" ? "sample-line light" : "sample-line"
        let extraText = extras.map { "\($0.adapterRole.role)=\($0.adapterRole.finalCSS) tags=\($0.riskTags.joined(separator: ","))" }
            .joined(separator: " | ")
        return """
        <section class="card \(risk ? "risk" : "")">
          <header>
            <div>
              <h2>\(escape(first.sample))</h2>
              <p class="meta">\(escape(first.sectionID)) / \(escape(first.scheme)) / \(escape(first.mode)) / \(escape(first.skin))</p>
              <p class="meta">\(escape(first.backgroundType))</p>
            </div>
            <strong>\(escape(Array(Set(roles.flatMap(\.riskTags))).sorted().joined(separator: ",")))</strong>
          </header>
          <div class="metrics">\(escape(first.hierarchy.description))</div>
          <div class="\(sampleClass)">
            <div class="lyric" style="color:\(active)">Active lyric sample</div>
            <div class="lyric" style="color:\(inactive)">Inactive lyric sample</div>
            <div class="lyric" style="color:\(secondary)">Secondary lyric sample</div>
            <div class="lyric" style="color:\(background)">Background lyric sample</div>
          </div>
          <div class="roles">\(roleBlocks)</div>
          <div class="extras">\(escape(extraText))</div>
          <p class="route">\(escape(first.routeNote))</p>
        </section>
        """
    }

    private static func roleBlock(from row: LyricsParityRow) -> String {
        """
        <div class="role">
          <div class="role-title"><span>\(escape(row.adapterRole.roleGroup))</span><span>&Delta;E \(escape(ColorGoldenMasterSupport.f(row.diff.deltaEOKLab)))</span></div>
          <div class="swatches">
            <div>
              <div class="swatch" style="background:\(row.adapterRole.legacySwiftCSS)"></div>
              <div class="caption">legacy swift<br>\(escape(row.adapterRole.legacySwiftCSS))</div>
            </div>
            <div>
              <div class="swatch" style="background:\(row.displayP3Output)"></div>
              <div class="caption">final P3<br>\(escape(row.displayP3Output))</div>
            </div>
            <div>
              <div class="swatch" style="background:\(row.sRGBFallback)"></div>
              <div class="caption">sRGB fallback<br>\(escape(row.sRGBFallback))</div>
            </div>
          </div>
          <div class="caption">\(escape(row.adapterRole.role)) &middot; alpha \(escape(ColorGoldenMasterSupport.f(row.adapterRole.effectiveAlpha))) &middot; \(escape(row.adapterRole.webDerivedRole)) &middot; \(escape(row.riskTags.joined(separator: ",")))</div>
        </div>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
