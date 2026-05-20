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

import AppKit
import Foundation

nonisolated enum ColorSystemSelfCheck {

    static let envVarName = "COLOR_SYSTEM_SELF_CHECK"

    /// Reads the env var. When set to "1", runs the check and exits.
    /// Otherwise returns immediately — zero cost in production.
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment[envVarName] == "1" else { return }
        let report = runAll()
        for line in report.lines { print(line) }
        FileHandle.standardOutput.synchronizeFile()
        exit(report.allPassed ? 0 : 1)
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

        report.lines.append(
            "Result: \(report.allPassed ? "ALL PASS" : "FAILURES PRESENT")"
        )
        return report
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
