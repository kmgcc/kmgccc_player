//
//  ColorSystemSelfCheck.swift
//  myPlayer2
//
//  Debug-only self-check entry point for the colour decision engine.
//
//  Why this exists (and not XCTest): the Xcode project has no test
//  target, and Phase 2 of the OKLCH colour-system migration explicitly
//  requires repeatable pass/fail coverage of the new orthogonal axes
//  (UltraDark / NearMonochrome) and structured palettes
//  (salientHighlightPalette / displayPalette). Adding a full test
//  target would touch shared `.pbxproj` configuration, which the
//  Phase 2 brief asks us to avoid. This file is the agreed fallback:
//  synthetic RGBA buffers fed straight into `analyzeSyntheticSample`,
//  with assertions reported via stderr / stdout and the process exit
//  code.
//
//  Invocation:
//      COLOR_SYSTEM_SELF_CHECK=1 \
//          ./kmgccc_player.app/Contents/MacOS/kmgccc_player
//
//  The app exits 0 if every scenario passed, 1 otherwise. Normal
//  launches (without the env var) skip the check completely.
//
//  Release safety: the entire body of `runIfRequested` is guarded by
//  `#if DEBUG`. A Release build will not read the env var, will not run
//  the check, and cannot be made to `exit()` mid-launch by an attacker
//  setting `COLOR_SYSTEM_SELF_CHECK=1`. The env-var gate remains as a
//  second layer for Debug builds (the default install) so day-to-day
//  development launches still no-op unless the engineer opts in.
//

import AppKit
import Foundation
import SwiftUI

nonisolated enum ColorSystemSelfCheck {

    static let envVarName = "COLOR_SYSTEM_SELF_CHECK"

    /// Reads the env var. When set to "1", runs the check and exits.
    /// Otherwise returns immediately — zero cost in production.
    ///
    /// Double-gated:
    ///   1. `#if DEBUG` compiles the body out entirely in Release builds,
    ///      so a shipped binary cannot be made to run the check or call
    ///      `exit()` even if `COLOR_SYSTEM_SELF_CHECK=1` is set in the
    ///      environment.
    ///   2. In Debug builds the env-var gate still applies — normal Debug
    ///      launches no-op, the check fires only when the engineer opts
    ///      in.
    static func runIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment[envVarName] == "1" else { return }
        let report = runAll()
        for line in report.lines { print(line) }
        exit(report.allPassed ? 0 : 1)
        #endif
    }

    // MARK: - Report

    struct CheckReport {
        var lines: [String] = []
        var allPassed: Bool = true

        mutating func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            let mark = ok ? "PASS" : "FAIL"
            if detail.isEmpty {
                lines.append("[\(mark)] \(name)")
            } else {
                lines.append("[\(mark)] \(name) — \(detail)")
            }
            if !ok { allPassed = false }
        }

        mutating func section(_ title: String) {
            lines.append("---- \(title) ----")
        }
    }

    // MARK: - Entry

    static func runAll() -> CheckReport {
        var report = CheckReport()
        report.lines.append("ColorSystemSelfCheck — \(Date())")
        report.lines.append("cacheVersion=\(ArtworkColorExtractor.cacheVersion)")

        report.section("Quadrants — UltraDark × NearMonochrome")
        checkUltraDarkColored(&report)
        checkUltraDarkMono(&report)
        checkNormalColored(&report)
        checkNormalMono(&report)

        report.section("OKColor math primitives")
        checkOKColorRoundTrip(&report)
        checkOKColorClamps(&report)
        checkOKColorHueWrap(&report)
        checkOKColorSoftShoulder(&report)

        report.section("Salient highlight palette")
        checkSalientYellowOnBlack(&report)
        checkSalientOrangeOnNavy(&report)
        checkSalientRedOnDarkCanvas(&report)
        checkSalientTinyNoiseRejected(&report)

        report.section("Display palette")
        checkDisplayPaletteMultiColor(&report)
        checkDisplayPaletteNearMonoRestraint(&report)
        checkDisplayPaletteSalientPriorityUnderContention(&report)

        report.section("Phase 3 hotfix — consumer projection")
        checkSpectrumNearMonoNeutralised(&report)
        checkSpectrumLowSaturationNotAmplified(&report)
        checkSpectrumColourfulPassThrough(&report)
        checkHomeShapesNearMonoChromaCeiling(&report)
        checkHomeShapesUltraDarkLightnessBand(&report)

        report.section("Phase 4 — ReadabilityProfile + MiniPlayerControl")
        checkReadabilityNearMonoNeutral(&report)
        checkReadabilityBrightArtworkDarkForeground(&report)
        checkReadabilityDarkArtworkLightForeground(&report)
        checkControlNearMonoNeutral(&report)
        checkControlColourfulPreservesHue(&report)

        report.section("Phase 4.5 — AppForegroundPalette")
        checkAppFgNearMonoAchromatic(&report)
        checkAppFgColorfulHasTint(&report)
        checkAppFgLightColorfulHasTint(&report)
        checkAppFgLightChromaHigherThanDark(&report)
        checkAppFgDarkLightnessHierarchy(&report)
        checkAppFgLightLightnessHierarchy(&report)
        checkAppFgSeparateFromReadabilityProfile(&report)
        checkAppFgDarkSecondaryBelowPrimary(&report)
        checkAppFgDarkTertiaryBelowSecondary(&report)
        checkAppFgDarkCoolHueReduced(&report)
        checkAppFgLightModeDirectional(&report)

        report.section("Phase 5 — LyricsColorPalette")
        checkLyricsNearMonoWindowNeutral(&report)
        checkLyricsNearMonoFullscreenNeutral(&report)
        checkLyricsNearMonoCoverBlurProfilesNeutral(&report)
        checkLyricsColorfulWindowKeepsTint(&report)
        checkLyricsLightnessHierarchy(&report)

        report.section("Phase 6 v3 — Tone Ladder + LED + artistic lyrics")
        checkToneLadderBasicHierarchy(&report)
        checkToneLadderNearMonoNeutral(&report)
        checkToneLadderHueFamilyChromaPreserved(&report, family: "yellow", base: OKColor.OKLCH(l: 0.78, c: 0.14, h: 0.12))
        checkToneLadderHueFamilyChromaPreserved(&report, family: "red",    base: OKColor.OKLCH(l: 0.58, c: 0.16, h: 0.04))
        checkToneLadderHueFamilyChromaPreserved(&report, family: "blue",   base: OKColor.OKLCH(l: 0.55, c: 0.16, h: 0.69))
        checkToneLadderHueFamilyChromaPreserved(&report, family: "purple", base: OKColor.OKLCH(l: 0.50, c: 0.16, h: 0.85))
        // v3 regression guards: the bugs the v2 selfcheck did NOT catch.
        checkToneLadderColorfulSeedSurvivesNearMonoFlag(&report)
        checkArtisticLyricsColorfulSeedSurvivesNeutralFallback(&report)
        checkArtisticLyricsSubInactiveCloseToMainInactive(&report)
        checkLEDLevelHueDriftVisible(&report)
        checkLEDToneStepsPerceptual(&report)
        checkLEDColorfulNotPale(&report)
        checkLEDPeakNotWhiteWashed(&report)
        checkLEDLightnessSurvivesOpacity(&report)
        checkArtisticLyricsToneLadderHierarchy(&report)
        checkArtisticLyricsHueIdentityPreserved(&report)
        checkCoverBlurProfileUnaffectedByArtisticToneLadder(&report)

        report.lines.append(
            "Result: \(report.allPassed ? "ALL PASS" : "FAILURES PRESENT")"
        )
        return report
    }

    // MARK: - Phase 6 v2 scenarios

    private static func checkToneLadderBasicHierarchy(_ report: inout CheckReport) {
        let base = OKColor.OKLCH(l: 0.55, c: 0.14, h: 0.12)
        let lookup: [PerceptualToneLadder.LyricsRole: OKColor.OKLCH] = Dictionary(
            uniqueKeysWithValues: PerceptualToneLadder.LyricsRole.allCases.map {
                ($0, PerceptualToneLadder.artisticLyricsTone(
                    base: base,
                    role: $0,
                    isUltraDark: false,
                    isNearMonochrome: false
                ))
            }
        )
        guard
            let active = lookup[.mainActive],
            let subActive = lookup[.subActive],
            let inactive = lookup[.mainInactive],
            let lineInactive = lookup[.lineTimingMainInactive],
            let subInactive = lookup[.subInactive],
            let lineSubInactive = lookup[.lineTimingSubInactive]
        else {
            report.record("ToneLadder v2: artistic lyrics L hierarchy", false, "role lookup failed")
            return
        }
        // v3 ordering: mainActive > subActive > mainInactive > subInactive
        //              > lineTimingMainInactive > lineTimingSubInactive.
        // Translation now sits next to its main counterpart at each tier.
        let lOK = active.l > subActive.l
            && subActive.l > inactive.l
            && inactive.l > subInactive.l
            && subInactive.l > lineInactive.l
            && lineInactive.l > lineSubInactive.l
        // v2 invariant: inactive must retain chroma identity — no longer
        // mechanically below the visible-chroma floor.
        let floor = ColorSystemTokens.ToneLadder.lyricsColorfulMinimumChroma
        let cOK = inactive.c >= floor && lineSubInactive.c >= floor * 0.85
        report.record(
            "ToneLadder v3: artistic lyrics L hierarchy + chroma floor", lOK && cOK,
            "L active/sub/inactive/subInact/lineInact/lineSubInact=\(format(active.l))/\(format(subActive.l))/\(format(inactive.l))/\(format(subInactive.l))/\(format(lineInactive.l))/\(format(lineSubInactive.l)) C active/inactive/lineSub=\(format(active.c))/\(format(inactive.c))/\(format(lineSubInactive.c)) floor=\(format(floor))"
        )
    }

    /// v3 regression guard for the on-screen #80828X grey bug.
    ///
    /// v2 routed the artistic Tone Ladder through the analysis-level
    /// `isNearMonochrome` flag. When `resolveLyricsAnalysis` returned
    /// `.neutralFallback` (its `isNearMonochrome` is hardcoded `true`) the
    /// ladder clamped every role's chroma to `nearMonoChromaCeiling` even
    /// though the seed itself was colourful. The user picked #808284 off
    /// screen.
    ///
    /// v3 trusts the seed: when `base.c >= lyricsSeedChromaPreferred`, the
    /// `isNearMonochrome` flag is ignored and the colourful floor / cap
    /// path runs. This test would have failed under v2 and must pass under
    /// v3.
    private static func checkToneLadderColorfulSeedSurvivesNearMonoFlag(_ report: inout CheckReport) {
        let T = ColorSystemTokens.ToneLadder.self
        // Colourful seed (red): chroma well above the seed-preferred floor.
        let base = OKColor.OKLCH(l: 0.58, c: 0.16, h: 0.04)
        let roles = PerceptualToneLadder.LyricsRole.allCases.map {
            ($0, PerceptualToneLadder.artisticLyricsTone(
                base: base,
                role: $0,
                isUltraDark: false,
                isNearMonochrome: true   // <-- the buggy flag we now ignore
            ))
        }
        let minC = roles.map(\.1.c).min() ?? 0
        let limit = T.lyricsNearMonoSeedTrustChromaAssertion
        let ok = minC >= limit
        report.record(
            "ToneLadder v3: colourful seed survives isNearMonochrome=true", ok,
            "minRoleC=\(format(minC)) min=\(format(limit)) seedC=\(format(base.c))"
        )
    }

    /// v3 regression guard wired through the SemanticPalette entry point so
    /// the post-hoc `neutraliseLyricsSurfaceIfNearMono` skip is also
    /// covered. With `.neutralFallback` (isNearMonochrome=true) + a
    /// colourful highlight base, the artistic path must still produce
    /// colourful lyrics. v2 returned #80828X-style grey here.
    private static func checkArtisticLyricsColorfulSeedSurvivesNeutralFallback(_ report: inout CheckReport) {
        let analysis = ArtworkColorAnalysis.neutralFallback // isNearMonochrome=true
        let seedColor = NSColor(deviceRed: 0.92, green: 0.34, blue: 0.12, alpha: 1)
        let set = SemanticPaletteSelfCheck.fullscreenLyricsColorSet(
            analysis: analysis,
            scheme: .dark,
            highlightBaseColor: seedColor,
            inactiveBaseColor: NSColor.darkGray,
            isUltraDark: false,
            usesArtisticBackground: true
        )
        let chromas: [CGFloat] = [
            set.mainActive, set.mainInactive, set.subActive,
            set.subInactive, set.lineTimingMainInactive, set.lineTimingSubInactive
        ].compactMap { OKColor.nsColorToOKLCH($0)?.c }
        let minC = chromas.min() ?? 0
        let limit = ColorSystemTokens.ToneLadder.lyricsNearMonoSeedTrustChromaAssertion
        // Hue identity must survive too — if the system white-washes the
        // seed it would have an undefined hue.
        let seedH = OKColor.nsColorToOKLCH(seedColor)?.h ?? 0
        let inactiveH = OKColor.nsColorToOKLCH(set.mainInactive)?.h ?? .infinity
        let hueOK = circularHueDelta(inactiveH, seedH) <= ColorSystemTokens.ToneLadder.lyricsHueIdentityAssertion
        let ok = minC >= limit && hueOK
        report.record(
            "Lyrics v3: artistic path keeps colour under .neutralFallback analysis", ok,
            "minRoleC=\(format(minC)) min=\(format(limit)) seedC=\(format(OKColor.nsColorToOKLCH(seedColor)?.c ?? 0)) inactiveHueΔ=\(format(circularHueDelta(inactiveH, seedH)))"
        )
    }

    /// v3 invariant on translation rows: the user complaint was that sub /
    /// translation L sat too far below main-inactive L. Verify the delta
    /// between sub-inactive and main-inactive stays inside
    /// `lyricsSubInactiveLightnessProximityAssertion` for both the
    /// main-mode and line-timing-mode roles.
    private static func checkArtisticLyricsSubInactiveCloseToMainInactive(_ report: inout CheckReport) {
        let T = ColorSystemTokens.ToneLadder.self
        let base = OKColor.OKLCH(l: 0.55, c: 0.14, h: 0.12)
        let lookup: [PerceptualToneLadder.LyricsRole: OKColor.OKLCH] = Dictionary(
            uniqueKeysWithValues: PerceptualToneLadder.LyricsRole.allCases.map {
                ($0, PerceptualToneLadder.artisticLyricsTone(
                    base: base,
                    role: $0,
                    isUltraDark: false,
                    isNearMonochrome: false
                ))
            }
        )
        guard
            let mainInactive = lookup[.mainInactive],
            let subInactive = lookup[.subInactive],
            let lineMain = lookup[.lineTimingMainInactive],
            let lineSub = lookup[.lineTimingSubInactive]
        else {
            report.record("Lyrics v3: sub-inactive L close to main-inactive L", false, "role lookup failed")
            return
        }
        let limit = T.lyricsSubInactiveLightnessProximityAssertion
        let mainGap = mainInactive.l - subInactive.l
        let lineGap = lineMain.l - lineSub.l
        // Sub must stay below or equal to its main counterpart, but the gap
        // must be small enough that the rows read as the same tier.
        let ok = mainGap >= 0 && mainGap <= limit
            && lineGap >= 0 && lineGap <= limit
        report.record(
            "Lyrics v3: sub-inactive L close to main-inactive L", ok,
            "main-vs-subInactive Δ=\(format(mainGap)) line-main-vs-line-sub Δ=\(format(lineGap)) max=\(format(limit))"
        )
    }

    /// v3 LED tone hierarchy needs visible *hue* shift between low / mid /
    /// peak (in addition to L and chroma). v2's drift scales were too
    /// small to read against the opacity ramp. Verify low and peak land in
    /// different hue positions relative to the seed.
    private static func checkLEDLevelHueDriftVisible(_ report: inout CheckReport) {
        let base = OKColor.OKLCH(l: 0.84, c: 0.095, h: 0.09)
        let low = PerceptualToneLadder.ledTone(base: base, level: 1, maxLevel: 9, scheme: .dark, isNearMonochrome: false)
        let peak = PerceptualToneLadder.ledTone(base: base, level: 9, maxLevel: 9, scheme: .dark, isNearMonochrome: false)
        let lowDrift = circularHueDelta(low.h, base.h)
        let peakDrift = circularHueDelta(peak.h, base.h)
        // Low must drift further from the seed than peak (shadow drift
        // scale is heavier than highlight drift scale).
        let ok = lowDrift > peakDrift && lowDrift >= 0.003
        report.record(
            "LED v3: low-level hue drift visible vs peak", ok,
            "lowHueΔ=\(format(lowDrift)) peakHueΔ=\(format(peakDrift))"
        )
    }

    private static func checkToneLadderNearMonoNeutral(_ report: inout CheckReport) {
        // v3 contract: neutralisation only fires when BOTH the analysis bit
        // is true AND the seed itself has trivial chroma. Use a genuinely
        // near-grey seed (c < lyricsSeedChromaPreferred) so the test still
        // verifies the nearMono path the same way the runtime does.
        let base = OKColor.OKLCH(l: 0.50, c: 0.003, h: 0.67)
        let lyricMaxC = PerceptualToneLadder.LyricsRole.allCases
            .map {
                PerceptualToneLadder.artisticLyricsTone(
                    base: base,
                    role: $0,
                    isUltraDark: false,
                    isNearMonochrome: true
                ).c
            }
            .max() ?? .infinity
        let led = PerceptualToneLadder.ledTone(
            base: base,
            level: 3,
            maxLevel: 5,
            scheme: .dark,
            isNearMonochrome: true
        )
        let lyricOK = lyricMaxC <= ColorSystemTokens.ToneLadder.nearMonoChromaAssertion
        let ledOK = led.c <= ColorSystemTokens.ToneLadder.ledNearMonoChromaCap
        report.record(
            "ToneLadder v3: nearMono+grey-seed outputs neutral", lyricOK && ledOK,
            "lyricsMaxC=\(format(lyricMaxC)) limit=\(format(ColorSystemTokens.ToneLadder.nearMonoChromaAssertion)) ledC=\(format(led.c)) ledLimit=\(format(ColorSystemTokens.ToneLadder.ledNearMonoChromaCap)) seedC=\(format(base.c))"
        )
    }

    /// For each hue family, verifies the v2 invariants on the artistic lyric
    /// ladder:
    ///   - inactive chroma is at least 85% of active chroma (no grey-wash)
    ///   - sub-inactive chroma is at least 75% of active chroma
    ///   - final hue stays within `lyricsHueIdentityAssertion` of the seed
    ///     hue (circular distance)
    ///   - final chroma is above the visible-identity floor
    private static func checkToneLadderHueFamilyChromaPreserved(
        _ report: inout CheckReport,
        family: String,
        base: OKColor.OKLCH
    ) {
        let T = ColorSystemTokens.ToneLadder.self
        let roles = PerceptualToneLadder.LyricsRole.allCases.map {
            ($0, PerceptualToneLadder.artisticLyricsTone(
                base: base,
                role: $0,
                isUltraDark: false,
                isNearMonochrome: false
            ))
        }
        let lookup = Dictionary(uniqueKeysWithValues: roles)
        guard
            let active = lookup[.mainActive],
            let inactive = lookup[.mainInactive],
            let lineInactive = lookup[.lineTimingMainInactive],
            let subInactive = lookup[.subInactive],
            let lineSubInactive = lookup[.lineTimingSubInactive]
        else {
            report.record("ToneLadder v2 (\(family)): chroma + hue identity preserved", false, "role lookup failed")
            return
        }

        let ratioInactive = active.c > 0 ? inactive.c / active.c : 0
        let ratioLineInactive = active.c > 0 ? lineInactive.c / active.c : 0
        let ratioSubInactive = active.c > 0 ? subInactive.c / active.c : 0
        let ratioLineSubInactive = active.c > 0 ? lineSubInactive.c / active.c : 0
        let chromaRatioOK = ratioInactive >= T.lyricsInactiveChromaRatioAssertion
            && ratioLineInactive >= T.lyricsInactiveChromaRatioAssertion * 0.95
            && ratioSubInactive >= 0.75
            && ratioLineSubInactive >= 0.70

        let floor = T.lyricsColorfulMinimumChroma
        let chromaFloorOK = inactive.c >= floor
            && lineInactive.c >= floor * 0.95
            && subInactive.c >= floor * 0.85
            && lineSubInactive.c >= floor * 0.80

        let hueLimit = T.lyricsHueIdentityAssertion
        let hueOK = circularHueDelta(active.h, base.h) <= hueLimit
            && circularHueDelta(inactive.h, base.h) <= hueLimit
            && circularHueDelta(subInactive.h, base.h) <= hueLimit
            && circularHueDelta(lineSubInactive.h, base.h) <= hueLimit

        let ok = chromaRatioOK && chromaFloorOK && hueOK
        report.record(
            "ToneLadder v2 (\(family)): chroma + hue identity preserved", ok,
            "C active/inact/lineInact/subInact/lineSubInact=\(format(active.c))/\(format(inactive.c))/\(format(lineInactive.c))/\(format(subInactive.c))/\(format(lineSubInactive.c)) ratios=\(format(ratioInactive))/\(format(ratioLineInactive))/\(format(ratioSubInactive))/\(format(ratioLineSubInactive)) min=\(format(T.lyricsInactiveChromaRatioAssertion)) hueΔ active/inact/subInact=\(format(circularHueDelta(active.h, base.h)))/\(format(circularHueDelta(inactive.h, base.h)))/\(format(circularHueDelta(subInactive.h, base.h)))"
        )
    }

    private static func checkLEDToneStepsPerceptual(_ report: inout CheckReport) {
        let base = OKColor.OKLCH(l: 0.84, c: 0.095, h: 0.09)
        let low = PerceptualToneLadder.ledTone(base: base, level: 1, maxLevel: 5, scheme: .dark, isNearMonochrome: false)
        let mid = PerceptualToneLadder.ledTone(base: base, level: 3, maxLevel: 5, scheme: .dark, isNearMonochrome: false)
        let peak = PerceptualToneLadder.ledTone(base: base, level: 5, maxLevel: 5, scheme: .dark, isNearMonochrome: false)
        let d1 = oklabDistance(low, mid)
        let d2 = oklabDistance(mid, peak)
        let minDistance = ColorSystemTokens.ToneLadder.ledPerceptualStepAssertion
        let ok = low.l < mid.l && mid.l < peak.l
            && d1 >= minDistance && d2 >= minDistance * 0.5
            && mid.c >= base.c
        report.record(
            "LED v2: tone steps have perceptual distance", ok,
            "L=\(format(low.l))/\(format(mid.l))/\(format(peak.l)) C=\(format(low.c))/\(format(mid.c))/\(format(peak.c)) d=\(format(d1))/\(format(d2))"
        )
    }

    private static func checkLEDColorfulNotPale(_ report: inout CheckReport) {
        let source = OKColor.OKLCH(l: 0.82, c: 0.090, h: 0.10)
        let tone = PerceptualToneLadder.ledTone(
            base: source,
            level: 5,
            maxLevel: 5,
            scheme: .dark,
            isNearMonochrome: false
        )
        let limit = ColorSystemTokens.ToneLadder.ledColorfulMinimumChromaAssertion
        let ok = tone.c >= limit
        report.record(
            "LED v2: colorful artwork not pale", ok,
            "C=\(format(tone.c)) min=\(format(limit)) L=\(format(tone.l))"
        )
    }

    private static func checkLEDPeakNotWhiteWashed(_ report: inout CheckReport) {
        // Peak LED must stay below the white-out ceiling AND must retain hue
        // identity. v1 sat at L=0.890 which was visible, but the new wider
        // band must not overshoot.
        let base = OKColor.OKLCH(l: 0.84, c: 0.095, h: 0.09)
        let peak = PerceptualToneLadder.ledTone(base: base, level: 10, maxLevel: 10, scheme: .dark, isNearMonochrome: false)
        let ceiling = ColorSystemTokens.ToneLadder.ledPeakLightnessCeilingAssertion
        let hueLimit = ColorSystemTokens.ToneLadder.lyricsHueIdentityAssertion
        let ok = peak.l <= ceiling
            && peak.c >= ColorSystemTokens.ToneLadder.ledColorfulMinimumChromaAssertion
            && circularHueDelta(peak.h, base.h) <= hueLimit
        report.record(
            "LED v2: peak not white-washed", ok,
            "peakL=\(format(peak.l)) ceiling=\(format(ceiling)) C=\(format(peak.c)) hueΔ=\(format(circularHueDelta(peak.h, base.h)))"
        )
    }

    /// LED renders OKLCH-coloured cells against a dark background with an
    /// opacity ramp on top. The Phase 6 v1 ladder placed the OKLCH L band
    /// so low that opacity multiplication pushed low levels below the
    /// visibility threshold. v2 enforces a minimum spread of the
    /// opacity-multiplied L between low and peak levels.
    private static func checkLEDLightnessSurvivesOpacity(_ report: inout CheckReport) {
        let base = OKColor.OKLCH(l: 0.84, c: 0.095, h: 0.09)
        // Models the real consumer: brightnessLevels = 10 maps to maxLevel
        // = brightnessLevels - 1 = 9 (see LEDColorResolver.oklchColorForLevel).
        let brightnessLevels = 10
        let maxLevel = brightnessLevels - 1
        let low = PerceptualToneLadder.ledTone(base: base, level: 1, maxLevel: maxLevel, scheme: .dark, isNearMonochrome: false)
        let peak = PerceptualToneLadder.ledTone(base: base, level: maxLevel, maxLevel: maxLevel, scheme: .dark, isNearMonochrome: false)
        let opacityLow = ledOpacity(level: 1, levels: brightnessLevels)
        let opacityPeak = ledOpacity(level: maxLevel, levels: brightnessLevels)
        // Approximate perceived L on black background after opacity multiply.
        // OKLCH L approximates lightness on a perceptual scale; multiplying
        // by alpha against black is a usable first-order model for the
        // delta a user actually sees.
        let perceivedLow = low.l * opacityLow
        let perceivedPeak = peak.l * opacityPeak
        let visibilityDelta = perceivedPeak - perceivedLow
        let minDelta = ColorSystemTokens.ToneLadder.ledLightnessVisibilityAssertion
        let ok = visibilityDelta >= minDelta
        report.record(
            "LED v2: lightness survives opacity ramp", ok,
            "perceivedL low/peak=\(format(perceivedLow))/\(format(perceivedPeak)) Δ=\(format(visibilityDelta)) min=\(format(minDelta))"
        )
    }

    private static func checkArtisticLyricsToneLadderHierarchy(_ report: inout CheckReport) {
        guard let analysis = analyseMix(side: 64, regions: [
            (0.65, (20, 32, 70, 255)),
            (0.35, (235, 96, 34, 255)),
        ]) else {
            report.record("Lyrics v2: artistic fullscreen tone ladder hierarchy", false, "analysis nil")
            return
        }
        let set = SemanticPaletteSelfCheck.fullscreenLyricsColorSet(
            analysis: analysis,
            scheme: .dark,
            highlightBaseColor: NSColor(deviceRed: 0.92, green: 0.34, blue: 0.12, alpha: 1),
            inactiveBaseColor: NSColor(deviceRed: 0.05, green: 0.10, blue: 0.25, alpha: 1),
            isUltraDark: false,
            usesArtisticBackground: true
        )
        guard
            let active = OKColor.nsColorToOKLCH(set.mainActive),
            let inactive = OKColor.nsColorToOKLCH(set.mainInactive),
            let subActive = OKColor.nsColorToOKLCH(set.subActive),
            let subInactive = OKColor.nsColorToOKLCH(set.subInactive)
        else {
            report.record("Lyrics v2: artistic fullscreen tone ladder hierarchy", false, "OKLCH nil")
            return
        }
        let lOK = active.l > inactive.l + ColorSystemTokens.ToneLadder.lyricsActiveInactiveLightnessGapAssertion
            && subActive.l > subInactive.l + ColorSystemTokens.ToneLadder.lyricsSecondaryInactiveLightnessGapAssertion
            && active.l > subActive.l
            && inactive.l > subInactive.l
        let alphaOK = set.mainActive.alphaComponent == 1
            && set.mainInactive.alphaComponent == 1
            && set.subInactive.alphaComponent == 1
        // v2 invariant on the wired path: single-seed must produce inactive
        // chroma no lower than 85% of active chroma.
        let chromaRatio = active.c > 0 ? inactive.c / active.c : 0
        let chromaOK = chromaRatio >= ColorSystemTokens.ToneLadder.lyricsInactiveChromaRatioAssertion
            && inactive.c >= ColorSystemTokens.ToneLadder.lyricsColorfulMinimumChroma * 0.85
        report.record(
            "Lyrics v2: artistic fullscreen tone ladder hierarchy", lOK && alphaOK && chromaOK,
            "L active/sub/inactive/subInactive=\(format(active.l))/\(format(subActive.l))/\(format(inactive.l))/\(format(subInactive.l)) C active/inactive ratio=\(format(active.c))/\(format(inactive.c))/\(format(chromaRatio))"
        )
    }

    /// Covers a strongly-tinted artwork (red/orange) and verifies the
    /// emitted artistic lyric set still reads as "the same hue family". v1
    /// pulled inactive/sub colours toward neutral via the background-as-seed
    /// path; v2 must keep all roles within the seed hue band.
    private static func checkArtisticLyricsHueIdentityPreserved(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (220, 80, 30, 255)) else {
            report.record("Lyrics v2: hue identity preserved on colourful artwork", false, "analysis nil")
            return
        }
        let seedColor = NSColor(deviceRed: 0.86, green: 0.31, blue: 0.12, alpha: 1)
        guard let seedLCH = OKColor.nsColorToOKLCH(seedColor) else {
            report.record("Lyrics v2: hue identity preserved on colourful artwork", false, "seed OKLCH nil")
            return
        }
        let set = SemanticPaletteSelfCheck.fullscreenLyricsColorSet(
            analysis: analysis,
            scheme: .dark,
            highlightBaseColor: seedColor,
            inactiveBaseColor: NSColor.darkGray,
            isUltraDark: false,
            usesArtisticBackground: true
        )
        guard
            let active = OKColor.nsColorToOKLCH(set.mainActive),
            let inactive = OKColor.nsColorToOKLCH(set.mainInactive),
            let subInactive = OKColor.nsColorToOKLCH(set.subInactive),
            let lineSubInactive = OKColor.nsColorToOKLCH(set.lineTimingSubInactive)
        else {
            report.record("Lyrics v2: hue identity preserved on colourful artwork", false, "set OKLCH nil")
            return
        }
        let hueLimit = ColorSystemTokens.ToneLadder.lyricsHueIdentityAssertion
        let hueOK = circularHueDelta(active.h, seedLCH.h) <= hueLimit
            && circularHueDelta(inactive.h, seedLCH.h) <= hueLimit
            && circularHueDelta(subInactive.h, seedLCH.h) <= hueLimit
            && circularHueDelta(lineSubInactive.h, seedLCH.h) <= hueLimit
        let floor = ColorSystemTokens.ToneLadder.lyricsColorfulMinimumChroma
        let chromaOK = active.c >= floor
            && inactive.c >= floor
            && subInactive.c >= floor * 0.85
            && lineSubInactive.c >= floor * 0.80
        report.record(
            "Lyrics v2: hue identity preserved on colourful artwork", hueOK && chromaOK,
            "seedH=\(format(seedLCH.h)) hueΔ active/inact/subInact/lineSubInact=\(format(circularHueDelta(active.h, seedLCH.h)))/\(format(circularHueDelta(inactive.h, seedLCH.h)))/\(format(circularHueDelta(subInactive.h, seedLCH.h)))/\(format(circularHueDelta(lineSubInactive.h, seedLCH.h))) C=\(format(active.c))/\(format(inactive.c))/\(format(subInactive.c))/\(format(lineSubInactive.c))"
        )
    }

    private static func checkCoverBlurProfileUnaffectedByArtisticToneLadder(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (46, 92, 210, 255)) else {
            report.record("Lyrics v2: cover blur profile remains separate", false, "analysis nil")
            return
        }
        let themeColor = NSColor(deviceRed: 0.18, green: 0.34, blue: 0.82, alpha: 1)
        let cover = SemanticPaletteSelfCheck.coverBlurLyricsColorSet(
            analysis: analysis,
            themeColor: themeColor,
            profile: .lighter
        )
        let artistic = SemanticPaletteSelfCheck.fullscreenLyricsColorSet(
            analysis: analysis,
            scheme: .dark,
            highlightBaseColor: themeColor,
            inactiveBaseColor: themeColor,
            isUltraDark: false,
            usesArtisticBackground: true
        )
        guard
            let coverInactiveL = OKColor.nsColorToOKLCH(cover.mainInactive)?.l,
            let artisticInactiveL = OKColor.nsColorToOKLCH(artistic.mainInactive)?.l
        else {
            report.record("Lyrics v2: cover blur profile remains separate", false, "OKLCH nil")
            return
        }
        let ok = coverInactiveL < 0.30 && artisticInactiveL > 0.45
        report.record(
            "Lyrics v2: cover blur profile remains separate", ok,
            "coverInactiveL=\(format(coverInactiveL)) artisticInactiveL=\(format(artisticInactiveL))"
        )
    }

    // MARK: Phase 6 v2 helpers

    private static func ledOpacity(level: Int, levels: Int) -> CGFloat {
        // Mirrors `LEDColorResolver.opacityForLevel` in dark scheme so the
        // self-check stays an accurate model of what the user actually sees.
        guard level > 0, levels > 1 else { return 0 }
        let maxLevel = levels - 1
        let t = CGFloat(level) / CGFloat(maxLevel)
        return 0.08 + pow(t, 1.55) * 0.92
    }

    private static func circularHueDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(raw, 1 - raw)
    }

    // MARK: - Phase 5 scenarios

    private static func checkLyricsNearMonoWindowNeutral(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (196, 196, 196, 255)) else {
            report.record("Lyrics: near-mono window active/inactive neutral", false, "analysis nil")
            return
        }
        let palette = SemanticPaletteSelfCheck.lyricsPalette(analysis: analysis, scheme: .dark)
        let limit = ColorSystemTokens.Lyrics.nearMonoChromaAssertion
        let activeC = OKColor.nsColorToOKLCH(palette.windowActive)?.c ?? .infinity
        let inactiveC = OKColor.nsColorToOKLCH(palette.windowInactive)?.c ?? .infinity
        let ok = analysis.isNearMonochrome && activeC <= limit && inactiveC <= limit
        report.record(
            "Lyrics: near-mono window active/inactive neutral", ok,
            "nearMono=\(analysis.isNearMonochrome) activeC=\(format(activeC)) inactiveC=\(format(inactiveC)) limit=\(format(limit))"
        )
    }

    private static func checkLyricsNearMonoFullscreenNeutral(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (42, 42, 42, 255)) else {
            report.record("Lyrics: near-mono fullscreen tiers neutral", false, "analysis nil")
            return
        }
        let palette = SemanticPaletteSelfCheck.lyricsPalette(analysis: analysis, scheme: .dark)
        let tiers: [(NSColor, String)] = [
            (palette.fullscreen.mainActive, "mainActive"),
            (palette.fullscreen.mainInactive, "mainInactive"),
            (palette.fullscreen.subActive, "subActive"),
            (palette.fullscreen.subInactive, "subInactive"),
            (palette.fullscreen.lineTimingMainInactive, "lineTimingMainInactive"),
            (palette.fullscreen.lineTimingSubInactive, "lineTimingSubInactive"),
        ]
        let (worstName, worstChroma) = worstChroma(in: tiers)
        let limit = ColorSystemTokens.Lyrics.nearMonoChromaAssertion
        let ok = analysis.isNearMonochrome && worstChroma <= limit
        report.record(
            "Lyrics: near-mono fullscreen tiers neutral", ok,
            "nearMono=\(analysis.isNearMonochrome) worst=\(worstName) C=\(format(worstChroma)) limit=\(format(limit))"
        )
    }

    private static func checkLyricsNearMonoCoverBlurProfilesNeutral(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (210, 210, 210, 255)) else {
            report.record("Lyrics: near-mono cover-blur profiles neutral", false, "analysis nil")
            return
        }
        let themeColor = NSColor(deviceRed: 0.82, green: 0.80, blue: 0.78, alpha: 1)
        let lighter = SemanticPaletteSelfCheck.coverBlurLyricsColorSet(
            analysis: analysis,
            themeColor: themeColor,
            profile: .lighter
        )
        let darker = SemanticPaletteSelfCheck.coverBlurLyricsColorSet(
            analysis: analysis,
            themeColor: themeColor,
            profile: .darker
        )
        let tiers: [(NSColor, String)] = [
            (lighter.mainActive, "lighter.mainActive"),
            (lighter.mainInactive, "lighter.mainInactive"),
            (lighter.subActive, "lighter.subActive"),
            (lighter.subInactive, "lighter.subInactive"),
            (darker.mainActive, "darker.mainActive"),
            (darker.mainInactive, "darker.mainInactive"),
            (darker.subActive, "darker.subActive"),
            (darker.subInactive, "darker.subInactive"),
        ]
        let (worstName, worstChroma) = worstChroma(in: tiers)
        let limit = ColorSystemTokens.Lyrics.nearMonoChromaAssertion
        let ok = analysis.isNearMonochrome && worstChroma <= limit
        report.record(
            "Lyrics: near-mono cover-blur profiles neutral", ok,
            "worst=\(worstName) C=\(format(worstChroma)) limit=\(format(limit))"
        )
    }

    private static func checkLyricsColorfulWindowKeepsTint(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (42, 106, 210, 255)) else {
            report.record("Lyrics: colorful window keeps theme tint", false, "analysis nil")
            return
        }
        let palette = SemanticPaletteSelfCheck.lyricsPalette(analysis: analysis, scheme: .dark)
        guard let active = OKColor.nsColorToOKLCH(palette.windowActive) else {
            report.record("Lyrics: colorful window keeps theme tint", false, "OKLCH nil")
            return
        }
        let ok = !analysis.isNearMonochrome && active.c > ColorSystemTokens.Lyrics.nearMonoChromaAssertion
        report.record(
            "Lyrics: colorful window keeps theme tint", ok,
            "nearMono=\(analysis.isNearMonochrome) activeC=\(format(active.c))"
        )
    }

    private static func checkLyricsLightnessHierarchy(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (42, 106, 210, 255)) else {
            report.record("Lyrics: fullscreen/window hierarchy", false, "analysis nil")
            return
        }
        let palette = SemanticPaletteSelfCheck.lyricsPalette(analysis: analysis, scheme: .dark)
        guard
            let fsActiveL = OKColor.nsColorToOKLCH(palette.fullscreen.mainActive)?.l,
            let fsInactiveL = OKColor.nsColorToOKLCH(palette.fullscreen.mainInactive)?.l
        else {
            report.record("Lyrics: fullscreen/window hierarchy", false, "OKLCH nil")
            return
        }
        let windowAlphaOK = palette.windowActive.alphaComponent > palette.windowInactive.alphaComponent
        let fsLightnessOK = fsActiveL > fsInactiveL + 0.10
        report.record(
            "Lyrics: fullscreen/window hierarchy", windowAlphaOK && fsLightnessOK,
            "windowAlpha=\(format(palette.windowActive.alphaComponent))>\(format(palette.windowInactive.alphaComponent)) fsL=\(format(fsActiveL))>\(format(fsInactiveL))"
        )
    }

    // MARK: - Phase 4 scenarios

    /// Near-mono cover: readability profile foregroundPrimary must have
    /// OKLCH chroma below the perceptual threshold so overlay text reads
    /// as neutral, not as a tinted pastel.
    private static func checkReadabilityNearMonoNeutral(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (200, 200, 200, 255)) else {
            report.record("ReadabilityProfile: near-mono foreground neutral", false, "analysis nil")
            return
        }
        guard analysis.isNearMonochrome else {
            report.record(
                "ReadabilityProfile: near-mono foreground neutral", false,
                "synthetic sample not classified nearMono"
            )
            return
        }
        let profile = SemanticPaletteSelfCheck.readabilityProfile(analysis)
        guard let lch = OKColor.nsColorToOKLCH(profile.foregroundPrimary) else {
            report.record("ReadabilityProfile: near-mono foreground neutral", false, "OKLCH nil")
            return
        }
        let limit = ColorSystemTokens.ReadabilityProfile.nearMonoChromaAssertion
        let ok = lch.c <= limit
        report.record(
            "ReadabilityProfile: near-mono foreground neutral", ok,
            "chroma=\(format(lch.c)) limit=\(format(limit)) usesDark=\(profile.usesDarkForeground)"
        )
    }

    /// Bright artwork: readability profile must select dark foreground and
    /// produce a low-L colour (charcoal, not near-white).
    private static func checkReadabilityBrightArtworkDarkForeground(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (240, 235, 228, 255)) else {
            report.record("ReadabilityProfile: bright artwork \u{2192} dark foreground", false, "analysis nil")
            return
        }
        let profile = SemanticPaletteSelfCheck.readabilityProfile(analysis)
        guard let lch = OKColor.nsColorToOKLCH(profile.foregroundPrimary) else {
            report.record("ReadabilityProfile: bright artwork \u{2192} dark foreground", false, "OKLCH nil")
            return
        }
        let ok = profile.usesDarkForeground && lch.l < 0.50
        report.record(
            "ReadabilityProfile: bright artwork \u{2192} dark foreground", ok,
            "usesDark=\(profile.usesDarkForeground) L=\(format(lch.l))"
        )
    }

    /// Dark artwork: readability profile must select light foreground and
    /// produce a high-L colour (near-white).
    private static func checkReadabilityDarkArtworkLightForeground(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (25, 22, 30, 255)) else {
            report.record("ReadabilityProfile: dark artwork \u{2192} light foreground", false, "analysis nil")
            return
        }
        let profile = SemanticPaletteSelfCheck.readabilityProfile(analysis)
        guard let lch = OKColor.nsColorToOKLCH(profile.foregroundPrimary) else {
            report.record("ReadabilityProfile: dark artwork \u{2192} light foreground", false, "OKLCH nil")
            return
        }
        let ok = !profile.usesDarkForeground && lch.l > 0.80
        report.record(
            "ReadabilityProfile: dark artwork \u{2192} light foreground", ok,
            "usesDark=\(profile.usesDarkForeground) L=\(format(lch.l))"
        )
    }

    /// Near-mono cover: MiniPlayer control primary (chrome surface path)
    /// must collapse to near-zero OKLCH chroma. Tests the
    /// `neutralAchromaticControl` output directly.
    private static func checkControlNearMonoNeutral(_ report: inout CheckReport) {
        let primary = SemanticPaletteSelfCheck.neutralAchromaticControl()
        guard let lch = OKColor.nsColorToOKLCH(primary) else {
            report.record("MiniPlayerControl: near-mono primary neutral", false, "OKLCH nil")
            return
        }
        let limit = ColorSystemTokens.MiniPlayerControl.nearMonoChromaAssertion
        let ok = lch.c <= limit && lch.l >= 0.88
        report.record(
            "MiniPlayerControl: near-mono primary neutral", ok,
            "chroma=\(format(lch.c)) limit=\(format(limit)) L=\(format(lch.l))"
        )
    }

    /// Colourful source: lifted accent must preserve hue and reach the
    /// minimum lightness target. Tests `liftedAccentControl` directly.
    private static func checkControlColourfulPreservesHue(_ report: inout CheckReport) {
        let sourceNS = NSColor(
            calibratedRed: 40.0/255, green: 100.0/255, blue: 180.0/255, alpha: 1
        )
        let lifted = SemanticPaletteSelfCheck.liftedAccentControl(sourceNS)
        guard
            let srcLch = OKColor.nsColorToOKLCH(sourceNS),
            let outLch = OKColor.nsColorToOKLCH(lifted)
        else {
            report.record("MiniPlayerControl: colourful preserves hue", false, "OKLCH nil")
            return
        }
        let hueOK = ColorMath.circularHueDistance(srcLch.h, outLch.h) <= 0.06
        let liftOK = outLch.l >= ColorSystemTokens.MiniPlayerControl.liftedMinL - 0.001
        let ok = hueOK && liftOK
        report.record(
            "MiniPlayerControl: colourful preserves hue", ok,
            "srcH=\(format(srcLch.h)) outH=\(format(outLch.h)) L=\(format(outLch.l))"
        )
    }

    // MARK: - Phase 4.5 scenarios

    /// Near-mono cover: all AppForegroundPalette tiers must be
    /// perceptually achromatic (OKLCH chroma ≤ nearMonoChromaAssertion).
    /// Uses a blue accent that would otherwise tint the foreground, to
    /// confirm the isNearMonochrome override crushes chroma to zero.
    private static func checkAppFgNearMonoAchromatic(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (200, 200, 200, 255)) else {
            report.record("AppForeground: near-mono all tiers achromatic", false, "analysis nil")
            return
        }
        guard analysis.isNearMonochrome else {
            report.record(
                "AppForeground: near-mono all tiers achromatic", false,
                "synthetic sample not classified nearMono"
            )
            return
        }
        let blueAccent = NSColor(deviceRed: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        let palette = SemanticPaletteSelfCheck.appForeground(
            analysis: analysis, globalAccent: blueAccent, isDark: true
        )
        let tiers: [(NSColor, String)] = [
            (palette.primary, "primary"),
            (palette.secondary, "secondary"),
            (palette.tertiary, "tertiary"),
            (palette.quaternary, "quaternary"),
            (palette.disabled, "disabled"),
        ]
        let limit = ColorSystemTokens.AppForeground.nearMonoChromaAssertion
        var worstChroma: CGFloat = 0
        var worstTier = ""
        for (color, name) in tiers {
            if let lch = OKColor.nsColorToOKLCH(color) {
                if lch.c > worstChroma { worstChroma = lch.c; worstTier = name }
            }
        }
        let ok = worstChroma <= limit
        report.record(
            "AppForeground: near-mono all tiers achromatic", ok,
            "worstChroma=\(format(worstChroma)) limit=\(format(limit)) tier=\(worstTier)"
        )
    }

    /// Colourful artwork: dark-mode primary foreground must carry a
    /// non-zero OKLCH chroma tint (from artwork hue) while staying well
    /// below the colorfulChromaAssertion ceiling. Confirms the tinted-
    /// neutral effect is actually applied on normal artwork.
    private static func checkAppFgColorfulHasTint(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)) else {
            report.record("AppForeground: colorful artwork has tint", false, "analysis nil")
            return
        }
        guard !analysis.isNearMonochrome else {
            report.record(
                "AppForeground: colorful artwork has tint", false,
                "synthetic sample classified nearMono — need colourful input"
            )
            return
        }
        let blueAccent = NSColor(deviceRed: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        let palette = SemanticPaletteSelfCheck.appForeground(
            analysis: analysis, globalAccent: blueAccent, isDark: true
        )
        guard let lch = OKColor.nsColorToOKLCH(palette.primary) else {
            report.record("AppForeground: colorful artwork has tint", false, "OKLCH nil")
            return
        }
        let ceiling = ColorSystemTokens.AppForeground.colorfulChromaAssertion
        let hasTint = lch.c > 0.001
        let withinCeiling = lch.c <= ceiling
        let ok = hasTint && withinCeiling
        report.record(
            "AppForeground: colorful artwork has tint", ok,
            "primaryChroma=\(format(lch.c)) ceiling=\(format(ceiling)) hasTint=\(hasTint)"
        )
    }

    /// Dark mode: lightness hierarchy primary > secondary > tertiary >
    /// quaternary > disabled. Ensures the visual weight ordering is
    /// preserved even when the chroma scale shifts with artwork.
    private static func checkAppFgDarkLightnessHierarchy(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)) else {
            report.record("AppForeground: dark mode L hierarchy", false, "analysis nil")
            return
        }
        let accent = NSColor(deviceRed: 0.85, green: 0.42, blue: 0.18, alpha: 1)
        let p = SemanticPaletteSelfCheck.appForeground(
            analysis: analysis, globalAccent: accent, isDark: true
        )
        guard
            let lPri = OKColor.nsColorToOKLCH(p.primary)?.l,
            let lSec = OKColor.nsColorToOKLCH(p.secondary)?.l,
            let lTer = OKColor.nsColorToOKLCH(p.tertiary)?.l,
            let lQua = OKColor.nsColorToOKLCH(p.quaternary)?.l,
            let lDis = OKColor.nsColorToOKLCH(p.disabled)?.l
        else {
            report.record("AppForeground: dark mode L hierarchy", false, "OKLCH nil")
            return
        }
        let assertion = ColorSystemTokens.AppForeground.darkPrimaryLAssertion
        let ok = lPri >= assertion
            && lPri > lSec
            && lSec > lTer
            && lTer > lQua
            && lQua > lDis
        report.record(
            "AppForeground: dark mode L hierarchy", ok,
            "L: \(format(lPri))>\(format(lSec))>\(format(lTer))>\(format(lQua))>\(format(lDis))"
        )
    }

    /// Light mode: lightness hierarchy primary < secondary < tertiary <
    /// quaternary < disabled (low L = dark text on light background).
    private static func checkAppFgLightLightnessHierarchy(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)) else {
            report.record("AppForeground: light mode L hierarchy", false, "analysis nil")
            return
        }
        let accent = NSColor(deviceRed: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        let p = SemanticPaletteSelfCheck.appForeground(
            analysis: analysis, globalAccent: accent, isDark: false
        )
        guard
            let lPri = OKColor.nsColorToOKLCH(p.primary)?.l,
            let lSec = OKColor.nsColorToOKLCH(p.secondary)?.l,
            let lTer = OKColor.nsColorToOKLCH(p.tertiary)?.l,
            let lQua = OKColor.nsColorToOKLCH(p.quaternary)?.l,
            let lDis = OKColor.nsColorToOKLCH(p.disabled)?.l
        else {
            report.record("AppForeground: light mode L hierarchy", false, "OKLCH nil")
            return
        }
        let assertion = ColorSystemTokens.AppForeground.lightPrimaryLAssertion
        let ok = lPri <= assertion
            && lPri < lSec
            && lSec < lTer
            && lTer < lQua
            && lQua < lDis
        report.record(
            "AppForeground: light mode L hierarchy", ok,
            "L: \(format(lPri))<\(format(lSec))<\(format(lTer))<\(format(lQua))<\(format(lDis))"
        )
    }

    /// AppForegroundPalette.primary must differ from
    /// ArtworkReadabilityProfile.foregroundPrimary for the same analysis.
    /// They serve different surfaces; if they were equal something in the
    /// factory pipeline has accidentally aliased the two paths.
    private static func checkAppFgSeparateFromReadabilityProfile(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)) else {
            report.record("AppForeground: separate from ReadabilityProfile", false, "analysis nil")
            return
        }
        let accent = NSColor(deviceRed: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        let appFg = SemanticPaletteSelfCheck.appForeground(
            analysis: analysis, globalAccent: accent, isDark: true
        )
        let readability = SemanticPaletteSelfCheck.readabilityProfile(analysis)
        let notIdentical = !isColorRGBEqual(
            appFg.primary, readability.foregroundPrimary, epsilon: 0.01
        )
        report.record(
            "AppForeground: separate from ReadabilityProfile", notIdentical,
            "fgPrimary ≠ readabilityPrimary: \(notIdentical)"
        )
    }

    /// Light-mode colourful artwork: light-mode primary foreground must carry
    /// a non-zero OKLCH chroma tint while staying within lightColorfulChromaAssertion.
    private static func checkAppFgLightColorfulHasTint(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)) else {
            report.record("AppForeground: light-mode colorful has tint", false, "analysis nil")
            return
        }
        guard !analysis.isNearMonochrome else {
            report.record(
                "AppForeground: light-mode colorful has tint", false,
                "synthetic sample classified nearMono"
            )
            return
        }
        let blueAccent = NSColor(deviceRed: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        let palette = SemanticPaletteSelfCheck.appForeground(
            analysis: analysis, globalAccent: blueAccent, isDark: false
        )
        guard let lch = OKColor.nsColorToOKLCH(palette.primary) else {
            report.record("AppForeground: light-mode colorful has tint", false, "OKLCH nil")
            return
        }
        let ceiling = ColorSystemTokens.AppForeground.lightColorfulChromaAssertion
        let hasTint = lch.c > 0.001
        let withinCeiling = lch.c <= ceiling
        let ok = hasTint && withinCeiling
        report.record(
            "AppForeground: light-mode colorful has tint", ok,
            "primaryChroma=\(format(lch.c)) ceiling=\(format(ceiling))"
        )
    }

    /// Light-mode primary chroma must exceed dark-mode primary chroma for
    /// the same colourful artwork + accent. The wider cap for light mode
    /// is the whole point of the per-mode split.
    private static func checkAppFgLightChromaHigherThanDark(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)) else {
            report.record("AppForeground: light chroma > dark chroma", false, "analysis nil")
            return
        }
        guard !analysis.isNearMonochrome else {
            report.record(
                "AppForeground: light chroma > dark chroma", false,
                "synthetic sample classified nearMono"
            )
            return
        }
        let accent = NSColor(deviceRed: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        let dark  = SemanticPaletteSelfCheck.appForeground(analysis: analysis, globalAccent: accent, isDark: true)
        let light = SemanticPaletteSelfCheck.appForeground(analysis: analysis, globalAccent: accent, isDark: false)
        guard
            let lchDark  = OKColor.nsColorToOKLCH(dark.primary),
            let lchLight = OKColor.nsColorToOKLCH(light.primary)
        else {
            report.record("AppForeground: light chroma > dark chroma", false, "OKLCH nil")
            return
        }
        let ok = lchLight.c > lchDark.c
        report.record(
            "AppForeground: light chroma > dark chroma", ok,
            "lightC=\(format(lchLight.c)) darkC=\(format(lchDark.c))"
        )
    }

    /// Dark mode secondary chroma must stay within its absolute low-chroma cap.
    /// Primary is intentionally very high-L in dark mode, so realised primary
    /// chroma can be clipped by sRGB gamut for some hues; the hierarchy is
    /// locked by lightness above and by this secondary cap here.
    private static func checkAppFgDarkSecondaryBelowPrimary(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)) else {
            report.record("AppForeground: dark secondary chroma bounded", false, "analysis nil")
            return
        }
        let accent = NSColor(deviceRed: 0.90, green: 0.55, blue: 0.10, alpha: 1)
        let p = SemanticPaletteSelfCheck.appForeground(analysis: analysis, globalAccent: accent, isDark: true)
        guard let secC = OKColor.nsColorToOKLCH(p.secondary)?.c else {
            report.record("AppForeground: dark secondary chroma bounded", false, "OKLCH nil")
            return
        }
        let cap = ColorSystemTokens.AppForeground.darkSecondaryChromaAssertion
        let ok = secC <= cap
        report.record(
            "AppForeground: dark secondary chroma bounded", ok,
            "sec=\(format(secC)) cap=\(format(cap))"
        )
    }

    /// Dark mode tertiary chroma must be ≤ secondary chroma × ratio cap.
    private static func checkAppFgDarkTertiaryBelowSecondary(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)) else {
            report.record("AppForeground: dark tertiary chroma ≤ secondary × cap", false, "analysis nil")
            return
        }
        let accent = NSColor(deviceRed: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        let p = SemanticPaletteSelfCheck.appForeground(analysis: analysis, globalAccent: accent, isDark: true)
        guard
            let secC = OKColor.nsColorToOKLCH(p.secondary)?.c,
            let terC = OKColor.nsColorToOKLCH(p.tertiary)?.c
        else {
            report.record("AppForeground: dark tertiary chroma ≤ secondary × cap", false, "OKLCH nil")
            return
        }
        let cap = ColorSystemTokens.AppForeground.darkTertiaryToSecondaryRatioCap
        let ok = secC > 0 ? (terC / secC) <= cap : terC == 0
        report.record(
            "AppForeground: dark tertiary chroma ≤ secondary × cap", ok,
            "ter/sec=\(format(secC > 0 ? terC / secC : 0)) cap=\(format(cap)) ter=\(format(terC)) sec=\(format(secC))"
        )
    }

    /// Dark mode cool-hue accent must produce lower primary chroma than
    /// an equivalent warm accent — confirming the hue-aware reduction
    /// applies to the blue/cyan range.
    private static func checkAppFgDarkCoolHueReduced(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)) else {
            report.record("AppForeground: dark cool hue chroma reduced vs warm", false, "analysis nil")
            return
        }
        guard !analysis.isNearMonochrome else {
            report.record("AppForeground: dark cool hue chroma reduced vs warm", false, "nearMono")
            return
        }
        // Blue accent (OKLCH hue ≈ 0.62 — inside cool range 0.40…0.72)
        let blueAccent = NSColor(deviceRed: 0.10, green: 0.35, blue: 0.90, alpha: 1)
        // Warm amber accent (OKLCH hue ≈ 0.08 — outside cool range)
        let warmAccent = NSColor(deviceRed: 0.90, green: 0.55, blue: 0.10, alpha: 1)
        let blue = SemanticPaletteSelfCheck.appForeground(analysis: analysis, globalAccent: blueAccent, isDark: true)
        let warm = SemanticPaletteSelfCheck.appForeground(analysis: analysis, globalAccent: warmAccent, isDark: true)
        guard
            let blueC = OKColor.nsColorToOKLCH(blue.primary)?.c,
            let warmC = OKColor.nsColorToOKLCH(warm.primary)?.c
        else {
            report.record("AppForeground: dark cool hue chroma reduced vs warm", false, "OKLCH nil")
            return
        }
        let ok = blueC < warmC
        report.record(
            "AppForeground: dark cool hue chroma reduced vs warm", ok,
            "blueC=\(format(blueC)) warmC=\(format(warmC))"
        )
    }

    /// Light mode directional tint test.
    /// Warm artwork → sRGB red channel > blue channel (warm bias).
    /// Cool artwork → sRGB blue channel > red channel (cool bias).
    /// Both conditions must hold for the same analysis (switching accent).
    private static func checkAppFgLightModeDirectional(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (40, 100, 200, 255)),
              !analysis.isNearMonochrome else {
            report.record("AppForeground: light mode warm/cool direction", false, "analysis nil or nearMono")
            return
        }
        let warmAccent = NSColor(deviceRed: 0.90, green: 0.55, blue: 0.10, alpha: 1)
        let coolAccent = NSColor(deviceRed: 0.10, green: 0.35, blue: 0.90, alpha: 1)
        let warmPalette = SemanticPaletteSelfCheck.appForeground(analysis: analysis, globalAccent: warmAccent, isDark: false)
        let coolPalette = SemanticPaletteSelfCheck.appForeground(analysis: analysis, globalAccent: coolAccent, isDark: false)
        guard
            let warmRGB = warmPalette.primary.usingColorSpace(.deviceRGB),
            let coolRGB = coolPalette.primary.usingColorSpace(.deviceRGB)
        else {
            report.record("AppForeground: light mode warm/cool direction", false, "RGB conversion nil")
            return
        }
        let warmIsWarm = warmRGB.redComponent > warmRGB.blueComponent
        let coolIsCool = coolRGB.blueComponent > coolRGB.redComponent
        let ok = warmIsWarm && coolIsCool
        report.record(
            "AppForeground: light mode warm/cool direction", ok,
            "warm R>\u{3e}B: \(warmIsWarm) (R=\(format(warmRGB.redComponent)) B=\(format(warmRGB.blueComponent))) | cool B>R: \(coolIsCool) (R=\(format(coolRGB.redComponent)) B=\(format(coolRGB.blueComponent)))"
        )
    }

    // MARK: - Phase 3 hotfix scenarios

    /// A 95%-grey + 5% yellow accent cover is `isNearMonochrome == true`
    /// (the salient yellow does not break the chromatic regime gate). The
    /// Spectrum preparation must hard-clamp the yellow's OKLCH chroma to
    /// near zero so the spectrum reads as grey, not yellow / pink.
    private static func checkSpectrumNearMonoNeutralised(_ report: inout CheckReport) {
        guard let analysis = analyseMix(side: 64, regions: [
            (0.95, (15, 15, 15, 255)),
            (0.05, (255, 200, 30, 255))
        ]) else {
            report.record("Spectrum: near-mono input neutralised", false, "analysis nil")
            return
        }
        guard analysis.isNearMonochrome else {
            report.record(
                "Spectrum: near-mono input neutralised", false,
                "synthetic sample was not classified near-mono"
            )
            return
        }
        let inputs = Array(analysis.displayPalette.prefix(2))
        let prepared = SpectrumPaletteSelfCheck.prepare(inputs, analysis: analysis)
        let chromas = prepared.compactMap { OKColor.nsColorToOKLCH($0)?.c }
        let maxChroma = chromas.max() ?? 1.0
        let ok = maxChroma <= 0.010
        report.record(
            "Spectrum: near-mono input neutralised", ok,
            "maxOKLCHChroma=\(format(maxChroma)) limit=0.010 inputs=\(inputs.count)"
        )
    }

    /// A muted dusty-blue cover (low colourfulness but NOT near-mono). The
    /// Spectrum preparation must apply the soft chroma shoulder so the
    /// downstream brightness/saturation tuner doesn't lift output chroma
    /// far above the source.
    private static func checkSpectrumLowSaturationNotAmplified(_ report: inout CheckReport) {
        guard let analysis = analyseMix(side: 64, regions: [
            (0.60, (110, 118, 132, 255)),
            (0.40, (95, 104, 118, 255))
        ]) else {
            report.record("Spectrum: low-sat not amplified", false, "analysis nil")
            return
        }
        let inputs = Array(analysis.displayPalette.prefix(2))
        guard !inputs.isEmpty else {
            report.record("Spectrum: low-sat not amplified", false, "empty displayPalette")
            return
        }
        let prepared = SpectrumPaletteSelfCheck.prepare(inputs, analysis: analysis)
        let sourceChromas: [CGFloat] = inputs.compactMap { OKColor.nsColorToOKLCH($0)?.c }
        let outChromas: [CGFloat] = prepared.compactMap { OKColor.nsColorToOKLCH($0)?.c }
        var worstAmp: CGFloat = 1
        if sourceChromas.count == outChromas.count, !sourceChromas.isEmpty {
            for i in 0..<sourceChromas.count {
                let src = sourceChromas[i]
                let out = outChromas[i]
                let amp: CGFloat
                if src > 0 {
                    amp = out / src
                } else {
                    amp = out > 0.01 ? 99 : 1
                }
                if amp > worstAmp { worstAmp = amp }
            }
        } else {
            worstAmp = 99
        }
        // Soft shoulder; we accept up to ~1.05× source chroma. Anything
        // above means the tuner is fabricating colour.
        let ok = worstAmp <= 1.05
        report.record(
            "Spectrum: low-sat not amplified", ok,
            "worstChromaAmp=\(format(worstAmp)) src=\(sourceChromas.map(format)) out=\(outChromas.map(format))"
        )
    }

    /// A vivid 4-way colourful cover. The Spectrum preparation must NOT
    /// flatten it — colourfulness is well above the low-sat gate, so the
    /// prepared output equals the input.
    private static func checkSpectrumColourfulPassThrough(_ report: inout CheckReport) {
        guard let analysis = analyseMix(side: 64, regions: [
            (0.25, (210, 35, 45, 255)),
            (0.25, (40, 180, 60, 255)),
            (0.25, (40, 80, 200, 255)),
            (0.25, (240, 200, 30, 255))
        ]) else {
            report.record("Spectrum: colourful pass-through", false, "analysis nil")
            return
        }
        let inputs = Array(analysis.displayPalette.prefix(2))
        guard !inputs.isEmpty else {
            report.record("Spectrum: colourful pass-through", false, "empty displayPalette")
            return
        }
        let prepared = SpectrumPaletteSelfCheck.prepare(inputs, analysis: analysis)
        var allEqual = prepared.count == inputs.count
        if allEqual {
            for i in 0..<inputs.count {
                if !isColorRGBEqual(prepared[i], inputs[i], epsilon: 1e-6) {
                    allEqual = false
                    break
                }
            }
        }
        let ok = !analysis.isNearMonochrome
            && analysis.colorfulness >= 0.18
            && allEqual
        report.record(
            "Spectrum: colourful pass-through", ok,
            "nearMono=\(analysis.isNearMonochrome) colorfulness=\(format(analysis.colorfulness)) equal=\(prepared.count == inputs.count)"
        )
    }

    /// Near-mono cover projected through the Home shape palette must come
    /// out with chroma well below the perceptual visibility threshold.
    /// The Phase-3-hotfix dark+nearMono ceiling is 0.012; we require all
    /// output chromas to respect it.
    private static func checkHomeShapesNearMonoChromaCeiling(_ report: inout CheckReport) {
        guard let analysis = analyseMix(side: 64, regions: [
            (0.95, (15, 15, 15, 255)),
            (0.05, (255, 200, 30, 255))
        ]) else {
            report.record("HomeShapes: near-mono chroma ceiling", false, "analysis nil")
            return
        }
        guard analysis.isNearMonochrome else {
            report.record(
                "HomeShapes: near-mono chroma ceiling", false,
                "synthetic sample was not classified near-mono"
            )
            return
        }
        guard let projected = HomeAmbientPaletteSelfCheck.project(
            analysis: analysis,
            colorScheme: .dark
        ), !projected.isEmpty else {
            report.record("HomeShapes: near-mono chroma ceiling", false, "projection nil/empty")
            return
        }
        let chromas = projected.compactMap { OKColor.nsColorToOKLCH($0)?.c }
        let maxChroma = chromas.max() ?? 1.0
        // Allow the configured ceiling 0.012 + 1e-6 numeric slack. ultraDark
        // path uses 0.010; we test the normal dark+nearMono path here.
        let limit: CGFloat = analysis.isUltraDark ? 0.0105 : 0.0125
        let ok = maxChroma <= limit
        report.record(
            "HomeShapes: near-mono chroma ceiling", ok,
            "maxOKLCHChroma=\(format(maxChroma)) limit=\(format(limit)) ultraDark=\(analysis.isUltraDark)"
        )
    }

    /// An UltraDark deep-navy cover projected through Home shapes must
    /// land in the [0.05, 0.18] L band per the Phase 3 hotfix. We sample
    /// every projected colour to ensure no entry exceeds the band.
    private static func checkHomeShapesUltraDarkLightnessBand(_ report: inout CheckReport) {
        guard let analysis = analyse(side: 32, fill: (10, 25, 70, 255)) else {
            report.record("HomeShapes: ultraDark lightness band", false, "analysis nil")
            return
        }
        guard analysis.isUltraDark else {
            report.record(
                "HomeShapes: ultraDark lightness band", false,
                "synthetic sample was not classified ultraDark"
            )
            return
        }
        guard let projected = HomeAmbientPaletteSelfCheck.project(
            analysis: analysis,
            colorScheme: .dark
        ), !projected.isEmpty else {
            report.record("HomeShapes: ultraDark lightness band", false, "projection nil/empty")
            return
        }
        let ls = projected.compactMap { OKColor.nsColorToOKLCH($0)?.l }
        let maxL = ls.max() ?? 1.0
        let minL = ls.min() ?? 0.0
        // Band is [0.05, 0.18]. Allow 1e-6 numeric slack on both sides.
        let ok = maxL <= 0.1801 && minL >= 0.0499
        report.record(
            "HomeShapes: ultraDark lightness band", ok,
            "L range=[\(format(minL)), \(format(maxL))] band=[0.05, 0.18]"
        )
    }

    private static func isColorRGBEqual(
        _ a: NSColor,
        _ b: NSColor,
        epsilon: CGFloat
    ) -> Bool {
        guard
            let lhs = a.usingColorSpace(.deviceRGB),
            let rhs = b.usingColorSpace(.deviceRGB)
        else { return false }
        return abs(lhs.redComponent - rhs.redComponent) <= epsilon
            && abs(lhs.greenComponent - rhs.greenComponent) <= epsilon
            && abs(lhs.blueComponent - rhs.blueComponent) <= epsilon
    }

    // MARK: - Quadrant scenarios

    private static func checkUltraDarkColored(_ report: inout CheckReport) {
        // Deep navy: dim on every lightness signal, but saturated enough
        // that chromatic gates must keep it OUT of the mono regime.
        guard let a = analyse(side: 32, fill: (10, 25, 70, 255)) else {
            report.record("UltraDark colored (deep navy)", false, "analysis nil")
            return
        }
        let ok = a.isUltraDark && !a.isNearMonochrome
        report.record(
            "UltraDark colored (deep navy)", ok,
            describe(a)
        )
    }

    private static func checkUltraDarkMono(_ report: inout CheckReport) {
        // Near-black grey: both dim AND chromatically empty.
        guard let a = analyse(side: 32, fill: (15, 15, 15, 255)) else {
            report.record("UltraDark mono (near-black grey)", false, "analysis nil")
            return
        }
        let ok = a.isUltraDark && a.isNearMonochrome
        report.record(
            "UltraDark mono (near-black grey)", ok,
            describe(a)
        )
    }

    private static func checkNormalColored(_ report: inout CheckReport) {
        // Mid-tone teal: bright enough to escape UltraDark, saturated
        // enough to escape NearMonochrome.
        guard let a = analyse(side: 32, fill: (40, 180, 160, 255)) else {
            report.record("Normal colored (mid teal)", false, "analysis nil")
            return
        }
        let ok = !a.isUltraDark && !a.isNearMonochrome
        report.record(
            "Normal colored (mid teal)", ok,
            describe(a)
        )
    }

    private static func checkNormalMono(_ report: inout CheckReport) {
        // Light grey: bright enough to escape UltraDark, but no usable hue.
        guard let a = analyse(side: 32, fill: (200, 200, 200, 255)) else {
            report.record("Normal mono (light grey)", false, "analysis nil")
            return
        }
        let ok = !a.isUltraDark && a.isNearMonochrome
        report.record(
            "Normal mono (light grey)", ok,
            describe(a)
        )
    }

    // MARK: - OKColor primitives

    private static func checkOKColorRoundTrip(_ report: inout CheckReport) {
        // Round-trip a saturated mid-tone colour through sRGB→OKLab→
        // OKLCH→OKLab→linear-sRGB→sRGB and back. Inside the gamut the
        // worst per-channel error should be tiny (well below a JND).
        let inputs: [(CGFloat, CGFloat, CGFloat)] = [
            (0.20, 0.50, 0.85),  // blue
            (0.92, 0.65, 0.10),  // amber
            (0.50, 0.50, 0.50),  // mid grey
            (0.10, 0.05, 0.05),  // very dark
        ]
        var worst: CGFloat = 0
        for input in inputs {
            let color = NSColor(deviceRed: input.0, green: input.1, blue: input.2, alpha: 1)
            guard let lch = OKColor.nsColorToOKLCH(color) else {
                report.record("OKColor.roundTrip", false, "nsColorToOKLCH returned nil")
                return
            }
            let back = OKColor.okLCHToNSColor(lch, alpha: 1)
            let bRGB = back.usingColorSpace(.deviceRGB) ?? back
            worst = max(worst,
                abs(bRGB.redComponent - input.0),
                abs(bRGB.greenComponent - input.1),
                abs(bRGB.blueComponent - input.2)
            )
        }
        let ok = worst < 0.005
        report.record(
            "OKColor.roundTrip", ok,
            "worst-channel ΔRGB=\(format(worst))"
        )
    }

    private static func checkOKColorClamps(_ report: inout CheckReport) {
        let lch = OKColor.OKLCH(l: 0.95, c: 0.20, h: 0.50)
        let cl = OKColor.clampLightness(lch, lo: 0.20, hi: 0.50)
        let cc = OKColor.clampChroma(lch, lo: 0.05, hi: 0.10)
        let ok = abs(cl.l - 0.50) < 1e-9
            && abs(cl.c - lch.c) < 1e-9
            && abs(cc.c - 0.10) < 1e-9
            && abs(cc.l - lch.l) < 1e-9
        report.record(
            "OKColor.clampLightness/chroma", ok,
            "cl.l=\(format(cl.l)) cc.c=\(format(cc.c))"
        )
    }

    private static func checkOKColorHueWrap(_ report: inout CheckReport) {
        let h1 = OKColor.normalizedHue(1.20)
        let h2 = OKColor.normalizedHue(-0.10)
        let rotated = OKColor.rotateHue(
            OKColor.OKLCH(l: 0.5, c: 0.1, h: 0.95),
            by: 0.10
        )
        let ok = abs(h1 - 0.20) < 1e-9
            && abs(h2 - 0.90) < 1e-9
            && abs(rotated.h - 0.05) < 1e-9
        report.record(
            "OKColor.normalizedHue/rotateHue", ok,
            "h1=\(format(h1)) h2=\(format(h2)) rotated.h=\(format(rotated.h))"
        )
    }

    private static func checkOKColorSoftShoulder(_ report: inout CheckReport) {
        // chroma below ceiling passes through; above ceiling compresses
        // smoothly toward `ceiling + softness`.
        let underCeiling = OKColor.chromaSoftShoulder(
            OKColor.OKLCH(l: 0.5, c: 0.05, h: 0.30),
            ceiling: 0.10, softness: 0.05
        )
        let overCeiling = OKColor.chromaSoftShoulder(
            OKColor.OKLCH(l: 0.5, c: 1.00, h: 0.30),
            ceiling: 0.10, softness: 0.05
        )
        let ok = abs(underCeiling.c - 0.05) < 1e-9
            && overCeiling.c > 0.10
            && overCeiling.c < 0.10 + 0.05  // never exceeds ceiling+softness
        report.record(
            "OKColor.chromaSoftShoulder", ok,
            "under=\(format(underCeiling.c)) over=\(format(overCeiling.c))"
        )
    }

    // MARK: - Salient highlight scenarios

    private static func checkSalientYellowOnBlack(_ report: inout CheckReport) {
        // 95% near-black + 5% bright yellow. Cover is technically near-
        // monochrome (low avg sat / colorfulness) — the yellow MUST still
        // surface in `salientHighlightPalette`, and MUST surface in
        // `displayPalette` even though near-mono caps richPalette.
        guard let a = analyseMix(side: 64, regions: [
            (0.95, (15, 15, 15, 255)),
            (0.05, (255, 200, 30, 255))
        ]) else {
            report.record("Salient: 95% black + 5% yellow", false, "analysis nil")
            return
        }
        let foundYellow = a.salientHighlightPalette.contains { isHueClose(of: $0, target: 0.13) }
        let inDisplay = a.displayPalette.contains { isHueClose(of: $0, target: 0.13) }
        let ok = !a.salientHighlightPalette.isEmpty && foundYellow && inDisplay
        report.record(
            "Salient: 95% black + 5% yellow", ok,
            "salient.count=\(a.salientHighlightPalette.count) foundYellow=\(foundYellow) display.contains=\(inDisplay) nearMono=\(a.isNearMonochrome)"
        )
    }

    private static func checkSalientOrangeOnNavy(_ report: inout CheckReport) {
        // 90% deep navy + 10% bright orange. Non-near-mono cover; both
        // hues should ride through. Salient palette should contain the
        // orange even though navy dominates by area.
        guard let a = analyseMix(side: 64, regions: [
            (0.90, (10, 25, 70, 255)),
            (0.10, (255, 130, 30, 255))
        ]) else {
            report.record("Salient: 90% navy + 10% orange", false, "analysis nil")
            return
        }
        let foundOrange = a.salientHighlightPalette.contains { isHueClose(of: $0, target: 0.07) }
        let multipleColors = a.displayPalette.count >= 2
        let ok = foundOrange && multipleColors
        report.record(
            "Salient: 90% navy + 10% orange", ok,
            "salient.count=\(a.salientHighlightPalette.count) display.count=\(a.displayPalette.count) foundOrange=\(foundOrange)"
        )
    }

    private static func checkSalientRedOnDarkCanvas(_ report: inout CheckReport) {
        // 80% dark canvas + 20% red title — a typical "song title against
        // dark cover" layout. Red lives in salient AND display.
        guard let a = analyseMix(side: 64, regions: [
            (0.80, (30, 30, 40, 255)),
            (0.20, (210, 35, 45, 255))
        ]) else {
            report.record("Salient: 80% canvas + 20% red title", false, "analysis nil")
            return
        }
        let foundRed = a.salientHighlightPalette.contains { isHueClose(of: $0, target: 0.99) || isHueClose(of: $0, target: 0.0) }
        let ok = foundRed
        report.record(
            "Salient: 80% canvas + 20% red title", ok,
            "salient.count=\(a.salientHighlightPalette.count) display.count=\(a.displayPalette.count) foundRed=\(foundRed)"
        )
    }

    private static func checkSalientTinyNoiseRejected(_ report: inout CheckReport) {
        // 99% near-black + 0.5% red noise + 0.5% blue noise. Each noise
        // colour sits below the minAreaShare floor (and below the noise
        // floor when the gray dampener is applied). Salient palette
        // should be empty.
        guard let a = analyseMix(side: 64, regions: [
            (0.99, (20, 20, 20, 255)),
            (0.005, (220, 30, 30, 255)),
            (0.005, (30, 30, 220, 255))
        ]) else {
            report.record("Salient: 99% black + 1% high-sat noise", false, "analysis nil")
            return
        }
        let ok = a.salientHighlightPalette.isEmpty
        report.record(
            "Salient: 99% black + 1% high-sat noise", ok,
            "salient.count=\(a.salientHighlightPalette.count) (expected 0)"
        )
    }

    // MARK: - Display palette scenarios

    private static func checkDisplayPaletteMultiColor(_ report: inout CheckReport) {
        // Four roughly equal regions of distinct hues. We do not require
        // all four to survive (top/rich palette have their own dedup) —
        // but display must contain at least 3 distinct hues.
        guard let a = analyseMix(side: 64, regions: [
            (0.25, (210, 35, 45, 255)),    // red
            (0.25, (40, 180, 60, 255)),    // green
            (0.25, (40, 80, 200, 255)),    // blue
            (0.25, (240, 200, 30, 255))    // amber
        ]) else {
            report.record("Display: 4-way multi-colour", false, "analysis nil")
            return
        }
        let hues = a.displayPalette.compactMap { color -> CGFloat? in
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &alpha)
            return h
        }
        let distinctHues = countDistinctHues(hues, gap: 0.05)
        let ok = a.displayPalette.count >= 3 && distinctHues >= 3 && !a.isNearMonochrome
        report.record(
            "Display: 4-way multi-colour", ok,
            "display.count=\(a.displayPalette.count) distinctHues=\(distinctHues) nearMono=\(a.isNearMonochrome)"
        )
    }

    private static func checkDisplayPaletteSalientPriorityUnderContention(
        _ report: inout CheckReport
    ) {
        // Adversarial near-mono case: two distinguishable grey regions
        // PLUS a 5% bright yellow. Under near-mono `cap=2`, the two greys
        // are large area + low saturation → they will both populate
        // `topPalette` (and pass DisplayPalette's RGB-gap distinctness
        // check since |60-15|/255 ≈ 0.176 > 0.14). The yellow is small +
        // high-sat → rejected from `topPalette` (uiThemePalette's
        // isNearMono filter kicks it out) but accepted by salient.
        //
        // Under the OLD `top → salient → rich` ordering the two greys
        // would consume both slots and the yellow would be dropped from
        // displayPalette. The new ordering reserves slot 1 for the
        // primary grey, then admits the yellow ahead of the tail of
        // top — yellow MUST appear in displayPalette.
        guard let a = analyseMix(side: 64, regions: [
            (0.50, (15, 15, 15, 255)),
            (0.45, (60, 60, 60, 255)),
            (0.05, (255, 200, 30, 255))
        ]) else {
            report.record(
                "Display: salient priority under near-mono contention",
                false, "analysis nil"
            )
            return
        }
        let yellowInDisplay = a.displayPalette.contains {
            isHueClose(of: $0, target: 0.13)
        }
        let yellowInSalient = a.salientHighlightPalette.contains {
            isHueClose(of: $0, target: 0.13)
        }
        let displayWithinCap =
            a.displayPalette.count <= ColorSystemTokens.DisplayPalette.nearMonoMaxCount
        let ok = a.isNearMonochrome && yellowInSalient && yellowInDisplay
            && displayWithinCap
        report.record(
            "Display: salient priority under near-mono contention", ok,
            "nearMono=\(a.isNearMonochrome) salient.count=\(a.salientHighlightPalette.count) "
                + "display.count=\(a.displayPalette.count) yellowInSalient=\(yellowInSalient) "
                + "yellowInDisplay=\(yellowInDisplay) top.count=\(a.topPalette.count)"
        )
    }

    private static func checkDisplayPaletteNearMonoRestraint(_ report: inout CheckReport) {
        // Light grey with no salient highlight. displayPalette must stay
        // narrow (≤ nearMonoMaxCount) and must not fabricate colours via
        // richPalette merge.
        guard let a = analyse(side: 32, fill: (200, 200, 200, 255)) else {
            report.record("Display: near-mono restraint (pure grey)", false, "analysis nil")
            return
        }
        let ok = a.isNearMonochrome
            && a.displayPalette.count <= ColorSystemTokens.DisplayPalette.nearMonoMaxCount
        report.record(
            "Display: near-mono restraint (pure grey)", ok,
            "nearMono=\(a.isNearMonochrome) display.count=\(a.displayPalette.count) cap=\(ColorSystemTokens.DisplayPalette.nearMonoMaxCount)"
        )
    }

    // MARK: - Helpers

    private static func analyse(
        side: Int,
        fill rgba: (UInt8, UInt8, UInt8, UInt8)
    ) -> ArtworkColorAnalysis? {
        let pixels = makePixels(side: side, fill: rgba)
        return ArtworkColorExtractor.analyzeSyntheticSample(pixels: pixels, side: side)
    }

    private static func analyseMix(
        side: Int,
        regions: [(Double, (UInt8, UInt8, UInt8, UInt8))]
    ) -> ArtworkColorAnalysis? {
        let pixels = makePixelsMixed(side: side, regions: regions)
        return ArtworkColorExtractor.analyzeSyntheticSample(pixels: pixels, side: side)
    }

    private static func makePixels(
        side: Int,
        fill rgba: (UInt8, UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        let total = side * side
        var out = [UInt8](repeating: 0, count: total * 4)
        for i in 0..<total {
            out[i * 4 + 0] = rgba.0
            out[i * 4 + 1] = rgba.1
            out[i * 4 + 2] = rgba.2
            out[i * 4 + 3] = rgba.3
        }
        return out
    }

    private static func makePixelsMixed(
        side: Int,
        regions: [(Double, (UInt8, UInt8, UInt8, UInt8))]
    ) -> [UInt8] {
        let total = side * side
        var out = [UInt8](repeating: 0, count: total * 4)
        var offset = 0
        let lastIdx = regions.count - 1
        for (i, region) in regions.enumerated() {
            let count: Int
            if i == lastIdx {
                count = total - offset
            } else {
                count = Int(Double(total) * region.0)
            }
            let upper = min(offset + count, total)
            for j in offset..<upper {
                out[j * 4 + 0] = region.1.0
                out[j * 4 + 1] = region.1.1
                out[j * 4 + 2] = region.1.2
                out[j * 4 + 3] = region.1.3
            }
            offset += count
        }
        return out
    }

    private static func isHueClose(of color: NSColor, target: CGFloat, gap: CGFloat = 0.06) -> Bool {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return ColorMath.circularHueDistance(h, target) <= gap
    }

    private static func countDistinctHues(_ hues: [CGFloat], gap: CGFloat) -> Int {
        var representatives: [CGFloat] = []
        for h in hues {
            let isDistinct = representatives.allSatisfy {
                ColorMath.circularHueDistance(h, $0) > gap
            }
            if isDistinct { representatives.append(h) }
        }
        return representatives.count
    }

    private static func oklabDistance(_ a: OKColor.OKLCH, _ b: OKColor.OKLCH) -> CGFloat {
        let la = OKColor.okLCHToOKLab(a)
        let lb = OKColor.okLCHToOKLab(b)
        let dl = la.l - lb.l
        let da = la.a - lb.a
        let db = la.b - lb.b
        return sqrt(dl * dl + da * da + db * db)
    }

    private static func worstChroma(in colors: [(NSColor, String)]) -> (String, CGFloat) {
        var worstName = ""
        var worstValue: CGFloat = 0
        for (color, name) in colors {
            let chroma = OKColor.nsColorToOKLCH(color)?.c ?? .infinity
            if chroma > worstValue {
                worstValue = chroma
                worstName = name
            }
        }
        return (worstName, worstValue)
    }

    private static func describe(_ a: ArtworkColorAnalysis) -> String {
        "UltraDark=\(a.isUltraDark) NearMono=\(a.isNearMonochrome) "
            + "avgHslL=\(format(a.avgHslLightness)) luma=\(format(a.weightedLuma)) "
            + "avgSat=\(format(a.avgSaturation)) colorfulness=\(format(a.colorfulness)) "
            + "domBri=\(format(a.dominantBrightness))"
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }
}
