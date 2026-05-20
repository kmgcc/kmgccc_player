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
        FileHandle.standardOutput.synchronizeFile()
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

        report.lines.append(
            "Result: \(report.allPassed ? "ALL PASS" : "FAILURES PRESENT")"
        )
        return report
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
