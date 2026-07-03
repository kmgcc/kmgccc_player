import AppKit
import Foundation
import SwiftUI

struct LEDParitySummary {
    var total = 0
    var preserve = 0
    var candidateBetter = 0
    var legacyBetter = 0
    var hierarchyRisk = 0
    var nearMonoRisk = 0
    var p3FallbackShift = 0
    var greenRisk = 0
    var hueFamilyDrift = 0

    var blocker: Int {
        hierarchyRisk + nearMonoRisk + p3FallbackShift + hueFamilyDrift
    }

    var statusLine: String {
        [
            "total=\(total)",
            "preserve=\(preserve)",
            "candidate_better=\(candidateBetter)",
            "legacy_better=\(legacyBetter)",
            "hierarchy_risk=\(hierarchyRisk)",
            "near_mono_risk=\(nearMonoRisk)",
            "p3_fallback_shift=\(p3FallbackShift)",
            "green_risk=\(greenRisk)",
            "hue_family_drift=\(hueFamilyDrift)",
            "blocker=\(blocker)",
        ].joined(separator: " ")
    }
}

enum ColorGoldenMasterLEDParity {
    static let reportVersion = 2
    static let brightnessLevels = 10
    static let volumeCount = 10

    static func buildRows() throws -> [LEDParityRow] {
        let sections = try ledSections()
        var rows: [LEDParityRow] = []
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

    static func summarize(_ rows: [LEDParityRow]) -> LEDParitySummary {
        var summary = LEDParitySummary()
        for row in rows {
            summary.total += 1
            switch row.classification {
            case .preserve:
                summary.preserve += 1
            case .candidateBetter:
                summary.candidateBetter += 1
            case .legacyBetter:
                summary.legacyBetter += 1
            case .hierarchyRisk:
                summary.hierarchyRisk += 1
            case .nearMonoRisk:
                summary.nearMonoRisk += 1
            case .p3FallbackShift:
                summary.p3FallbackShift += 1
            case .greenRisk:
                summary.greenRisk += 1
            case .hueFamilyDrift:
                summary.hueFamilyDrift += 1
            }
        }
        return summary
    }

    static func render() throws -> (text: String, summary: LEDParitySummary) {
        let rows = try buildRows()
        let summary = summarize(rows)
        var lines: [String] = []
        lines.append("# LED Controlled Difference Report")
        lines.append("format_version: \(reportVersion)")
        lines.append("mode: led-parity")
        lines.append("legacy_policy: \(LEDColorResolverImplementation.legacy.rawValue)")
        lines.append("current_candidate_policy: \(PerceptualToneLadder.LEDToneVariant.migrationReference.rawValue)")
        lines.append("retuned_candidate_policy: \(PerceptualToneLadder.LEDToneVariant.retuned.rawValue)")
        lines.append("pipeline: LED seed -> LEDPerceptualPolicy -> LEDSemanticPalette -> ColorRenderingAdapter -> Display P3 / sRGB fallback")
        lines.append("summary: \(summary.statusLine)")
        lines.append("")
        lines.append("sample\tsection\tscheme\tinput_seed\tnear_mono\tultra_dark\thue_risk\tlegacy_center\tcurrent_center\tretuned_center\tlegacy_edge\tcurrent_edge\tretuned_edge\tlegacy_status_levels\tcurrent_status_levels\tretuned_status_levels\tlegacy_center_levels\tcurrent_center_levels\tretuned_center_levels\tlegacy_edge_levels\tcurrent_edge_levels\tretuned_edge_levels\tretuned_level_policy\tretuned_display_p3\tretuned_srgb_fallback\tlegacy_delta_l\tlegacy_delta_c\tlegacy_delta_h\tlegacy_delta_e_oklab\tretune_delta_l\tretune_delta_c\tretune_delta_h\tretune_delta_e_oklab\tmonotonic\tp3_srgb_order\tclassification\treason")
        for row in rows {
            lines.append(row.tsvLine)
        }
        return (lines.joined(separator: "\n") + "\n", summary)
    }

    static func renderHTML() throws -> String {
        let rows = try buildRows()
        let summary = summarize(rows)
        return LEDParityReviewArtifact.render(rows: rows, summary: summary)
    }

    private static func appendRows(
        sample: GoldenSample,
        sectionID: String,
        analysis: ArtworkColorAnalysis,
        to rows: inout [LEDParityRow]
    ) {
        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let palette = SemanticPaletteFactory.make(
                from: analysis,
                scheme: scheme,
                userFallbackAccent: ColorGoldenMasterSupport.fallbackAccent,
                useArtworkTint: true
            )
            let legacy = makeSnapshot(
                palette: palette,
                scheme: scheme,
                implementation: .legacy
            )
            let currentCandidate = makeSnapshot(
                palette: palette,
                scheme: scheme,
                implementation: .oklch,
                levelToneVariant: .migrationReference
            )
            let retunedCandidate = makeSnapshot(
                palette: palette,
                scheme: scheme,
                implementation: .oklch,
                levelToneVariant: .retuned
            )
            let semantic = retunedCandidate.semantic
            let diff = LEDSnapshotDifference(legacy: legacy, candidate: retunedCandidate)
            let retuneDiff = LEDSnapshotDifference(legacy: currentCandidate, candidate: retunedCandidate)
            let evaluation = classify(
                diff: diff,
                candidate: retunedCandidate,
                analysis: analysis,
                semantic: semantic
            )
            rows.append(
                LEDParityRow(
                    sample: sample.id,
                    sectionID: sectionID,
                    scheme: scheme == .dark ? "dark" : "light",
                    inputSeed: semantic.seed,
                    legacy: legacy,
                    currentCandidate: currentCandidate,
                    candidate: retunedCandidate,
                    diff: diff,
                    retuneDiff: retuneDiff,
                    nearMono: semantic.isNearMonochrome,
                    ultraDark: semantic.isUltraDark || analysis.isUltraDark,
                    hueRisk: semantic.hueRisk,
                    monotonic: LEDMonotonicEvaluation(snapshot: retunedCandidate),
                    fallbackOrder: LEDFallbackOrderEvaluation(snapshot: retunedCandidate),
                    classification: evaluation.kind,
                    reason: evaluation.reason
                )
            )
        }
    }

    private static func makeSnapshot(
        palette: SemanticPalette,
        scheme: ColorScheme,
        implementation: LEDColorResolverImplementation,
        levelToneVariant: PerceptualToneLadder.LEDToneVariant = .retuned
    ) -> LEDColorSnapshot {
        let resolver = LEDColorResolver(
            accentColor: Color(nsColor: palette.globalAccent),
            colorScheme: scheme,
            brightnessLevels: brightnessLevels,
            palette: palette,
            implementation: implementation,
            levelToneVariant: levelToneVariant
        )
        let maxLevel = brightnessLevels - 1
        let levels = Array(0...maxLevel)
        let semantic = resolver.oklchSemanticPalette
        let centerBase = baseLCHForIndex(index: 4, count: volumeCount, semantic: semantic)
        let edgeBase = baseLCHForIndex(index: 0, count: volumeCount, semantic: semantic)
        let isOKLCH = implementation == .oklch
        return LEDColorSnapshot(
            semantic: semantic,
            variant: implementation == .legacy ? "legacy" : levelToneVariant.rawValue,
            center: resolver.centerColor,
            edge: resolver.edgeColor,
            statusLevels: levels.map { resolver.statusLightNSColor(level: $0) },
            centerLevels: levels.map { resolver.volumeLEDNSColor(index: 4, count: volumeCount, level: $0) },
            edgeLevels: levels.map { resolver.volumeLEDNSColor(index: 0, count: volumeCount, level: $0) },
            centerStrokeLevels: levels.map { resolver.volumeLEDStrokeNSColor(index: 4, count: volumeCount, level: $0) },
            edgeStrokeLevels: levels.map { resolver.volumeLEDStrokeNSColor(index: 0, count: volumeCount, level: $0) },
            statusDiagnostics: makeLevelDiagnostics(
                colors: levels.map { resolver.statusLightNSColor(level: $0) },
                base: semantic.statusBase,
                levels: levels,
                scheme: scheme,
                isNearMonochrome: semantic.isNearMonochrome,
                isUltraDark: semantic.isUltraDark,
                variant: levelToneVariant,
                includesPolicy: isOKLCH
            ),
            centerDiagnostics: makeLevelDiagnostics(
                colors: levels.map { resolver.volumeLEDNSColor(index: 4, count: volumeCount, level: $0) },
                base: centerBase,
                levels: levels,
                scheme: scheme,
                isNearMonochrome: semantic.isNearMonochrome,
                isUltraDark: semantic.isUltraDark,
                variant: levelToneVariant,
                includesPolicy: isOKLCH
            ),
            edgeDiagnostics: makeLevelDiagnostics(
                colors: levels.map { resolver.volumeLEDNSColor(index: 0, count: volumeCount, level: $0) },
                base: edgeBase,
                levels: levels,
                scheme: scheme,
                isNearMonochrome: semantic.isNearMonochrome,
                isUltraDark: semantic.isUltraDark,
                variant: levelToneVariant,
                includesPolicy: isOKLCH
            )
        )
    }

    private static func baseLCHForIndex(index: Int, count: Int, semantic: LEDSemanticPalette) -> OKColor.OKLCH {
        guard count > 1 else { return semantic.center }
        let center = Double(count - 1) / 2.0
        let distance = abs(Double(index) - center) / center
        return OKColor.oklabLerp(semantic.center, semantic.edge, t: CGFloat(distance))
    }

    private static func makeLevelDiagnostics(
        colors: [NSColor],
        base: OKColor.OKLCH,
        levels: [Int],
        scheme: ColorScheme,
        isNearMonochrome: Bool,
        isUltraDark: Bool,
        variant: PerceptualToneLadder.LEDToneVariant,
        includesPolicy: Bool
    ) -> [LEDLevelDiagnostic] {
        let maxLevel = max(1, brightnessLevels - 1)
        return zip(levels, colors).map { level, color in
            let style = includesPolicy
                ? PerceptualToneLadder.ledLevelStylePolicy(
                    base: base,
                    level: level,
                    maxLevel: maxLevel,
                    scheme: scheme,
                    isNearMonochrome: isNearMonochrome,
                    isUltraDark: isUltraDark,
                    variant: variant
                )
                : nil
            return LEDLevelDiagnostic(level: level, color: color, style: style)
        }
    }

    private static func classify(
        diff: LEDSnapshotDifference,
        candidate: LEDColorSnapshot,
        analysis: ArtworkColorAnalysis,
        semantic: LEDSemanticPalette
    ) -> (kind: LEDParityClassification, reason: String) {
        let monotonic = LEDMonotonicEvaluation(snapshot: candidate)
        if !monotonic.ok {
            return (.hierarchyRisk, monotonic.reason)
        }

        if semantic.isNearMonochrome && candidate.maxChroma > 0.012 {
            return (.nearMonoRisk, "nearMono candidate max chroma \(ColorGoldenMasterSupport.f(candidate.maxChroma)) exceeds neutral LED ceiling")
        }

        let fallback = LEDFallbackOrderEvaluation(snapshot: candidate)
        if !fallback.ok {
            return (.p3FallbackShift, fallback.reason)
        }

        if let legacyCenter = diff.center.legacyLCH,
           let candidateCenter = diff.center.candidateLCH,
           legacyCenter.c >= 0.030,
           candidateCenter.c >= 0.030,
           diff.center.deltaH > 0.115 {
            return (.hueFamilyDrift, "center hue family drift ΔH=\(ColorGoldenMasterSupport.f(diff.center.deltaH))")
        }

        if semantic.hueRisk.isGreenRisk && diff.maxDeltaEOKLab > 0.010 {
            return (.greenRisk, "green/yellow-green/cyan risk row requires visual approval; \(diff.summary)")
        }

        if !semantic.isNearMonochrome,
           candidate.centerLCH?.c ?? 0 < 0.040,
           diff.legacy.centerLCH?.c ?? 0 > 0.060 {
            return (.legacyBetter, "candidate loses visible LED chroma versus legacy")
        }

        if diff.maxDeltaEOKLab < 0.006 && diff.maxDeltaH < 0.006 {
            return (.preserve, "legacy/candidate visually equivalent under OKLab threshold")
        }

        let reason: String
        if analysis.isUltraDark {
            reason = "approved delta: UltraDark candidate keeps L visible while reducing sticker-like chroma; \(diff.summary)"
        } else if semantic.isNearMonochrome {
            reason = "approved delta: candidate keeps nearMono neutral; \(diff.summary)"
        } else {
            reason = "approved delta: candidate applies formal OKLCH LED policy; \(diff.summary)"
        }
        return (.candidateBetter, reason)
    }

    private static func ledSections() throws -> [GoldenSampleSection] {
        var sections = try ColorGoldenMasterSamples.sections()
        sections.append(
            GoldenSampleSection(
                id: "led_synthetic",
                title: "LED Migration Synthetic",
                samples: ledSyntheticSamples
            )
        )
        return sections
    }

    private static let ledSyntheticSamples: [GoldenSample] = [
        GoldenSample(
            id: "led.synthetic.high-chroma-green",
            title: "LED synthetic high chroma green",
            note: "Dedicated LED parity sample for saturated green risk.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (20, 205, 70, 255))])
        ),
        GoldenSample(
            id: "led.synthetic.yellow-green-overlap",
            title: "LED synthetic yellow-green overlap",
            note: "Dedicated LED parity sample for legacy hue cap overlap around yellow-green.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (176, 210, 20, 255))])
        ),
        GoldenSample(
            id: "led.synthetic.high-chroma-cyan",
            title: "LED synthetic high chroma cyan",
            note: "Dedicated LED parity sample for cyan risk.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (15, 190, 210, 255))])
        ),
        GoldenSample(
            id: "led.synthetic.high-chroma-blue",
            title: "LED synthetic high chroma blue",
            note: "Dedicated LED parity sample for saturated blue.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (35, 80, 240, 255))])
        ),
        GoldenSample(
            id: "led.synthetic.high-chroma-red",
            title: "LED synthetic high chroma red",
            note: "Dedicated LED parity sample for saturated red.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (230, 32, 44, 255))])
        ),
        GoldenSample(
            id: "led.synthetic.high-chroma-purple",
            title: "LED synthetic high chroma purple",
            note: "Dedicated LED parity sample for saturated purple.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (155, 55, 230, 255))])
        ),
        GoldenSample(
            id: "led.synthetic.near-mono-mid-gray",
            title: "LED synthetic nearMono mid gray",
            note: "Dedicated LED parity sample for neutral nearMono.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (128, 128, 128, 255))])
        ),
        GoldenSample(
            id: "led.synthetic.ultra-dark-green-pin",
            title: "LED synthetic UltraDark green pin",
            note: "UltraDark with a small trusted green region.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.90, (4, 5, 6, 255)),
                SyntheticRegion(0.10, (18, 150, 60, 255)),
            ])
        ),
        GoldenSample(
            id: "led.synthetic.low-light-yellow-green-pin",
            title: "LED synthetic low-light yellow-green pin",
            note: "Low-brightness review sample for yellow-green level stylization.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.84, (8, 9, 10, 255)),
                SyntheticRegion(0.16, (154, 185, 22, 255)),
            ])
        ),
        GoldenSample(
            id: "led.synthetic.low-light-green-pin",
            title: "LED synthetic low-light green pin",
            note: "Low-brightness review sample for green level stylization.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.84, (7, 9, 10, 255)),
                SyntheticRegion(0.16, (20, 170, 76, 255)),
            ])
        ),
        GoldenSample(
            id: "led.synthetic.low-light-cyan-pin",
            title: "LED synthetic low-light cyan pin",
            note: "Low-brightness review sample for cyan level stylization.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.84, (6, 9, 11, 255)),
                SyntheticRegion(0.16, (22, 170, 190, 255)),
            ])
        ),
        GoldenSample(
            id: "led.synthetic.low-light-blue-pin",
            title: "LED synthetic low-light blue pin",
            note: "Low-brightness review sample for blue level stylization.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.84, (6, 8, 12, 255)),
                SyntheticRegion(0.16, (45, 92, 225, 255)),
            ])
        ),
        GoldenSample(
            id: "led.synthetic.low-light-red-pin",
            title: "LED synthetic low-light red pin",
            note: "Low-brightness review sample for red level stylization.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.84, (10, 7, 7, 255)),
                SyntheticRegion(0.16, (220, 38, 48, 255)),
            ])
        ),
        GoldenSample(
            id: "led.synthetic.low-light-purple-pin",
            title: "LED synthetic low-light purple pin",
            note: "Low-brightness review sample for purple level stylization.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.84, (9, 7, 12, 255)),
                SyntheticRegion(0.16, (150, 58, 220, 255)),
            ])
        ),
        GoldenSample(
            id: "led.synthetic.ultra-dark-cyan-pin",
            title: "LED synthetic UltraDark cyan pin",
            note: "UltraDark cyan risk sample for peak glow and fallback order.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.92, (3, 4, 6, 255)),
                SyntheticRegion(0.08, (18, 170, 190, 255)),
            ])
        ),
        GoldenSample(
            id: "led.synthetic.ultra-dark-blue-pin",
            title: "LED synthetic UltraDark blue pin",
            note: "UltraDark blue sample for peak glow and low-level hue drift.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.92, (3, 4, 7, 255)),
                SyntheticRegion(0.08, (38, 86, 220, 255)),
            ])
        ),
    ]
}

enum LEDParityClassification: String {
    case preserve
    case candidateBetter = "candidate-better"
    case legacyBetter = "legacy-better"
    case hierarchyRisk = "hierarchy-risk"
    case nearMonoRisk = "near-mono-risk"
    case p3FallbackShift = "p3-fallback-shift"
    case greenRisk = "green-risk"
    case hueFamilyDrift = "hue-family-drift"
}

struct LEDColorSnapshot {
    let semantic: LEDSemanticPalette
    let variant: String
    let center: NSColor
    let edge: NSColor
    let statusLevels: [NSColor]
    let centerLevels: [NSColor]
    let edgeLevels: [NSColor]
    let centerStrokeLevels: [NSColor]
    let edgeStrokeLevels: [NSColor]
    let statusDiagnostics: [LEDLevelDiagnostic]
    let centerDiagnostics: [LEDLevelDiagnostic]
    let edgeDiagnostics: [LEDLevelDiagnostic]

    var allColors: [NSColor] {
        [center, edge]
            + statusLevels
            + centerLevels
            + edgeLevels
            + centerStrokeLevels
            + edgeStrokeLevels
    }

    var centerLCH: OKColor.OKLCH? {
        OKColor.nsColorToOKLCH(center)
    }

    var edgeLCH: OKColor.OKLCH? {
        OKColor.nsColorToOKLCH(edge)
    }

    var maxChroma: CGFloat {
        allColors.compactMap { OKColor.nsColorToOKLCH($0)?.c }.max() ?? 0
    }
}

struct LEDLevelDiagnostic {
    let level: Int
    let color: NSColor
    let style: PerceptualToneLadder.LEDLevelStylePolicy?

    var description: String {
        let lch = OKColor.nsColorToOKLCH(color)
            .map(ColorGoldenMasterSupport.lchDescription)
            ?? "oklch=nil"
        let p3 = ColorRenderingAdapter.resolve(color, target: .displayP3)
            .map(resolvedDescription)
            ?? "p3=nil"
        let srgb = ColorRenderingAdapter.resolve(color, target: .sRGB)
            .map(resolvedDescription)
            ?? "srgb=nil"
        let policy = style?.description ?? "policy=legacy-output"
        return "\(level)=\(lch) \(policy) p3{\(p3)} srgb{\(srgb)}"
    }

    private func resolvedDescription(_ color: ResolvedRGBColor) -> String {
        "rgb=\(ColorGoldenMasterSupport.f(color.red)),\(ColorGoldenMasterSupport.f(color.green)),\(ColorGoldenMasterSupport.f(color.blue)) C=\(ColorGoldenMasterSupport.f(color.resolvedChroma)) mapped=\(ColorGoldenMasterSupport.bool(color.wasGamutMapped))"
    }
}

struct LEDSnapshotDifference {
    let legacy: LEDColorSnapshot
    let candidate: LEDColorSnapshot
    let center: ColorDifference
    let edge: ColorDifference
    let statusLevels: [ColorDifference]
    let centerLevels: [ColorDifference]
    let edgeLevels: [ColorDifference]

    var maxDeltaL: CGFloat {
        allDiffs.map(\.deltaL).max() ?? 0
    }

    var maxDeltaC: CGFloat {
        allDiffs.map(\.deltaC).max() ?? 0
    }

    var maxDeltaH: CGFloat {
        allDiffs.map(\.deltaH).max() ?? 0
    }

    var maxDeltaEOKLab: CGFloat {
        allDiffs.map(\.deltaEOKLab).max() ?? 0
    }

    var summary: String {
        "maxΔL=\(ColorGoldenMasterSupport.f(maxDeltaL)) maxΔC=\(ColorGoldenMasterSupport.f(maxDeltaC)) maxΔH=\(ColorGoldenMasterSupport.f(maxDeltaH)) maxΔE=\(ColorGoldenMasterSupport.f(maxDeltaEOKLab))"
    }

    private var allDiffs: [ColorDifference] {
        [center, edge] + statusLevels + centerLevels + edgeLevels
    }

    init(legacy: LEDColorSnapshot, candidate: LEDColorSnapshot) {
        self.legacy = legacy
        self.candidate = candidate
        center = ColorDifference(legacy: legacy.center, candidate: candidate.center)
        edge = ColorDifference(legacy: legacy.edge, candidate: candidate.edge)
        statusLevels = zip(legacy.statusLevels, candidate.statusLevels).map(ColorDifference.init)
        centerLevels = zip(legacy.centerLevels, candidate.centerLevels).map(ColorDifference.init)
        edgeLevels = zip(legacy.edgeLevels, candidate.edgeLevels).map(ColorDifference.init)
    }
}

struct LEDMonotonicEvaluation {
    let ok: Bool
    let reason: String

    init(snapshot: LEDColorSnapshot) {
        let groups = [
            ("status", snapshot.statusLevels),
            ("center", snapshot.centerLevels),
            ("edge", snapshot.edgeLevels),
            ("center-stroke", snapshot.centerStrokeLevels),
            ("edge-stroke", snapshot.edgeStrokeLevels),
        ]
        var failures: [String] = []
        for (name, colors) in groups {
            let lch = colors.compactMap { OKColor.nsColorToOKLCH($0) }
            if !Self.nonDecreasing(lch.map(\.l), tolerance: 0.0015) {
                failures.append("\(name) L not monotonic")
            }
            if !Self.nonDecreasing(lch.map(\.c), tolerance: 0.0025) {
                failures.append("\(name) C not monotonic")
            }
            if let peak = lch.last {
                let hueStable = lch.allSatisfy { color in
                    color.c < 0.012 || peak.c < 0.012 || ColorMath.circularHueDistance(color.h, peak.h) <= 0.035
                }
                if !hueStable {
                    failures.append("\(name) hue jumps across levels")
                }
            }
        }

        if let center = snapshot.centerLCH,
           let edge = snapshot.edgeLCH {
            if edge.l > center.l + 0.002 {
                failures.append("edge L exceeds center L")
            }
            if edge.c > center.c + 0.002 {
                failures.append("edge C exceeds center C")
            }
        }

        ok = failures.isEmpty
        reason = ok ? "candidate L/C/hue hierarchy monotonic" : failures.joined(separator: "; ")
    }

    private static func nonDecreasing(_ values: [CGFloat], tolerance: CGFloat) -> Bool {
        guard values.count > 1 else { return true }
        for index in 1..<values.count {
            if values[index] + tolerance < values[index - 1] {
                return false
            }
        }
        return true
    }
}

struct LEDFallbackOrderEvaluation {
    let ok: Bool
    let reason: String

    init(snapshot: LEDColorSnapshot) {
        let p3 = Self.resolvedLCH(snapshot.centerLevels, target: .displayP3)
        let srgb = Self.resolvedLCH(snapshot.centerLevels, target: .sRGB)
        let p3Order = Self.orderSignature(p3)
        let srgbOrder = Self.orderSignature(srgb)
        let centerEdgeP3 = Self.centerEdgeSignature(snapshot: snapshot, target: .displayP3)
        let centerEdgeSRGB = Self.centerEdgeSignature(snapshot: snapshot, target: .sRGB)
        ok = p3Order == srgbOrder && centerEdgeP3 == centerEdgeSRGB
        reason = ok
            ? "P3 and sRGB fallback preserve center/edge/level order"
            : "P3/sRGB order mismatch levels=\(p3Order)/\(srgbOrder) centerEdge=\(centerEdgeP3)/\(centerEdgeSRGB)"
    }

    private static func resolvedLCH(_ colors: [NSColor], target: ColorRenderTarget) -> [OKColor.OKLCH] {
        colors.compactMap { color in
            guard let resolved = ColorRenderingAdapter.resolve(color, target: target) else { return nil }
            return OKColor.nsColorToOKLCH(nsColor(from: resolved))
        }
    }

    private static func orderSignature(_ colors: [OKColor.OKLCH]) -> String {
        let lOK = nonDecreasing(colors.map(\.l), tolerance: 0.002)
        let cOK = nonDecreasing(colors.map(\.c), tolerance: 0.003)
        return "L\(lOK ? "1" : "0")C\(cOK ? "1" : "0")"
    }

    private static func centerEdgeSignature(snapshot: LEDColorSnapshot, target: ColorRenderTarget) -> String {
        guard let center = ColorRenderingAdapter.resolve(snapshot.center, target: target),
              let edge = ColorRenderingAdapter.resolve(snapshot.edge, target: target),
              let centerLCH = OKColor.nsColorToOKLCH(nsColor(from: center)),
              let edgeLCH = OKColor.nsColorToOKLCH(nsColor(from: edge))
        else {
            return "unknown"
        }
        return "edgeLowerL=\(edgeLCH.l <= centerLCH.l + 0.002),edgeLowerC=\(edgeLCH.c <= centerLCH.c + 0.003)"
    }

    private static func nonDecreasing(_ values: [CGFloat], tolerance: CGFloat) -> Bool {
        guard values.count > 1 else { return true }
        for index in 1..<values.count {
            if values[index] + tolerance < values[index - 1] {
                return false
            }
        }
        return true
    }

    private static func nsColor(from resolved: ResolvedRGBColor) -> NSColor {
        switch resolved.target {
        case .sRGB:
            return NSColor(
                srgbRed: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: CGFloat(resolved.alpha)
            )
        case .displayP3, .linearDisplayP3:
            return NSColor(
                displayP3Red: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: CGFloat(resolved.alpha)
            )
        }
    }
}

struct LEDParityRow {
    let sample: String
    let sectionID: String
    let scheme: String
    let inputSeed: LEDSeed
    let legacy: LEDColorSnapshot
    let currentCandidate: LEDColorSnapshot
    let candidate: LEDColorSnapshot
    let diff: LEDSnapshotDifference
    let retuneDiff: LEDSnapshotDifference
    let nearMono: Bool
    let ultraDark: Bool
    let hueRisk: LEDHueRisk
    let monotonic: LEDMonotonicEvaluation
    let fallbackOrder: LEDFallbackOrderEvaluation
    let classification: LEDParityClassification
    let reason: String

    var tsvLine: String {
        [
            sample,
            sectionID,
            scheme,
            "\(inputSeed.reason) \(ColorGoldenMasterSupport.lchDescription(inputSeed.lch)) trusted=\(ColorGoldenMasterSupport.bool(inputSeed.trustsHue))",
            ColorGoldenMasterSupport.bool(nearMono),
            ColorGoldenMasterSupport.bool(ultraDark),
            hueRisk.rawValue,
            ColorGoldenMasterSupport.colorDescription(legacy.center),
            ColorGoldenMasterSupport.colorDescription(currentCandidate.center),
            ColorGoldenMasterSupport.colorDescription(candidate.center),
            ColorGoldenMasterSupport.colorDescription(legacy.edge),
            ColorGoldenMasterSupport.colorDescription(currentCandidate.edge),
            ColorGoldenMasterSupport.colorDescription(candidate.edge),
            colorListDescription(legacy.statusLevels),
            colorListDescription(currentCandidate.statusLevels),
            colorListDescription(candidate.statusLevels),
            colorListDescription(legacy.centerLevels),
            colorListDescription(currentCandidate.centerLevels),
            colorListDescription(candidate.centerLevels),
            colorListDescription(legacy.edgeLevels),
            colorListDescription(currentCandidate.edgeLevels),
            colorListDescription(candidate.edgeLevels),
            diagnosticsDescription(candidate.centerDiagnostics),
            outputListDescription([candidate.center, candidate.edge] + candidate.centerLevels, target: .displayP3),
            outputListDescription([candidate.center, candidate.edge] + candidate.centerLevels, target: .sRGB),
            ColorGoldenMasterSupport.f(diff.maxDeltaL),
            ColorGoldenMasterSupport.f(diff.maxDeltaC),
            ColorGoldenMasterSupport.f(diff.maxDeltaH),
            ColorGoldenMasterSupport.f(diff.maxDeltaEOKLab),
            ColorGoldenMasterSupport.f(retuneDiff.maxDeltaL),
            ColorGoldenMasterSupport.f(retuneDiff.maxDeltaC),
            ColorGoldenMasterSupport.f(retuneDiff.maxDeltaH),
            ColorGoldenMasterSupport.f(retuneDiff.maxDeltaEOKLab),
            monotonic.reason,
            fallbackOrder.reason,
            classification.rawValue,
            reason,
        ].map(sanitizeTSV).joined(separator: "\t")
    }

    private func colorListDescription(_ colors: [NSColor]) -> String {
        colors.enumerated()
            .map { index, color in "\(index)=\(ColorGoldenMasterSupport.colorDescription(color))" }
            .joined(separator: " | ")
    }

    private func diagnosticsDescription(_ diagnostics: [LEDLevelDiagnostic]) -> String {
        diagnostics.map(\.description).joined(separator: " | ")
    }

    private func outputListDescription(_ colors: [NSColor], target: ColorRenderTarget) -> String {
        colors.enumerated()
            .map { index, color in
                guard let resolved = ColorRenderingAdapter.resolve(color, target: target) else {
                    return "\(index)=nil"
                }
                return "\(index)=\(resolvedDescription(resolved))"
            }
            .joined(separator: " | ")
    }

    private func resolvedDescription(_ color: ResolvedRGBColor) -> String {
        "rgb=\(ColorGoldenMasterSupport.f(color.red)),\(ColorGoldenMasterSupport.f(color.green)),\(ColorGoldenMasterSupport.f(color.blue)) resolvedC=\(ColorGoldenMasterSupport.f(color.resolvedChroma)) mapped=\(ColorGoldenMasterSupport.bool(color.wasGamutMapped))"
    }

    private func sanitizeTSV(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

enum LEDParityReviewArtifact {
    static func render(rows: [LEDParityRow], summary: LEDParitySummary) -> String {
        let cards = rows.map(cardHTML).joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>LED Parity Review</title>
        <style>
        :root { color-scheme: dark light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        body { margin: 0; background: #111318; color: #eceff4; }
        header { position: sticky; top: 0; z-index: 1; padding: 16px 20px; background: rgba(17,19,24,0.94); border-bottom: 1px solid #2a2f3a; }
        h1 { margin: 0 0 6px; font-size: 20px; }
        .summary { color: #aeb6c4; font-size: 12px; }
        main { padding: 16px 20px 28px; display: grid; gap: 14px; }
        .card { border: 1px solid #2c3340; border-radius: 8px; background: #181c23; padding: 12px; }
        .meta { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; font-size: 12px; color: #b7c0ce; margin-bottom: 10px; }
        .pill { border: 1px solid #3b4555; border-radius: 999px; padding: 2px 8px; }
        .classification { color: #fff; background: #374151; border-color: #596579; }
        .classification.hierarchy-risk, .classification.near-mono-risk, .classification.p3-fallback-shift, .classification.hue-family-drift { background: #7f1d1d; border-color: #ef4444; }
        .classification.green-risk { background: #365314; border-color: #84cc16; }
        .classification.candidate-better { background: #164e63; border-color: #22d3ee; }
        .classification.legacy-better { background: #713f12; border-color: #f59e0b; }
        .grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
        .side { min-width: 0; }
        .side h2 { margin: 0 0 8px; font-size: 13px; color: #d7dde8; }
        .row { margin: 8px 0; }
        .label { font-size: 11px; color: #8f9bad; margin-bottom: 4px; }
        .swatches { display: grid; grid-template-columns: repeat(10, minmax(18px, 1fr)); gap: 4px; }
        .pair { display: grid; grid-template-columns: repeat(2, minmax(44px, 1fr)); gap: 4px; }
        .swatch { min-height: 28px; border-radius: 4px; border: 1px solid rgba(255,255,255,0.18); box-shadow: inset 0 0 0 1px rgba(0,0,0,0.18); }
        .small { font-size: 11px; color: #aeb6c4; line-height: 1.45; overflow-wrap: anywhere; }
        @media (max-width: 820px) { .grid { grid-template-columns: 1fr; } }
        </style>
        </head>
        <body>
        <header>
          <h1>LED Parity Review</h1>
          <div class="summary">\(escape(summary.statusLine))</div>
        </header>
        <main>
        \(cards)
        </main>
        </body>
        </html>
        """
    }

    private static func cardHTML(_ row: LEDParityRow) -> String {
        """
        <section class="card">
          <div class="meta">
            <span class="pill">\(escape(row.sample))</span>
            <span class="pill">\(escape(row.scheme))</span>
            <span class="pill">nearMono \(escape(ColorGoldenMasterSupport.bool(row.nearMono)))</span>
            <span class="pill">UltraDark \(escape(ColorGoldenMasterSupport.bool(row.ultraDark)))</span>
            <span class="pill">risk \(escape(row.hueRisk.rawValue))</span>
            <span class="pill classification \(escape(row.classification.rawValue))">\(escape(row.classification.rawValue))</span>
          </div>
          <div class="grid">
            \(sideHTML(title: "Legacy", snapshot: row.legacy))
            \(sideHTML(title: "Current Candidate", snapshot: row.currentCandidate))
            \(sideHTML(title: "Retuned Candidate", snapshot: row.candidate))
          </div>
          <div class="small">Seed: \(escape(row.inputSeed.reason)) \(escape(ColorGoldenMasterSupport.lchDescription(row.inputSeed.lch))) trusted=\(escape(ColorGoldenMasterSupport.bool(row.inputSeed.trustsHue)))</div>
          <div class="small">Legacy Δ: \(escape(row.diff.summary))</div>
          <div class="small">Retune Δ: \(escape(row.retuneDiff.summary))</div>
          <div class="small">Monotonic: \(escape(row.monotonic.reason))</div>
          <div class="small">P3/sRGB: \(escape(row.fallbackOrder.reason))</div>
          <div class="small">Review: \(escape(row.reason))</div>
        </section>
        """
    }

    private static func sideHTML(title: String, snapshot: LEDColorSnapshot) -> String {
        """
        <div class="side">
          <h2>\(escape(title))</h2>
          <div class="row">
            <div class="label">center / edge</div>
            <div class="pair">\(swatch(snapshot.center))\(swatch(snapshot.edge))</div>
          </div>
          <div class="row">
            <div class="label">status levels 0...9</div>
            <div class="swatches">\(snapshot.statusLevels.map(swatch).joined())</div>
          </div>
          <div class="row">
            <div class="label">volume center levels 0...9</div>
            <div class="swatches">\(snapshot.centerLevels.map(swatch).joined())</div>
          </div>
          <div class="row">
            <div class="label">volume edge levels 0...9</div>
            <div class="swatches">\(snapshot.edgeLevels.map(swatch).joined())</div>
          </div>
          <div class="small">center \(escape(ColorGoldenMasterSupport.colorDescription(snapshot.center)))</div>
          <div class="small">edge \(escape(ColorGoldenMasterSupport.colorDescription(snapshot.edge)))</div>
          <div class="small">center diagnostics \(escape(diagnosticsDescription(snapshot.centerDiagnostics)))</div>
        </div>
        """
    }

    private static func diagnosticsDescription(_ diagnostics: [LEDLevelDiagnostic]) -> String {
        diagnostics
            .map(\.description)
            .joined(separator: " | ")
    }

    private static func swatch(_ color: NSColor) -> String {
        let fallback = ColorRenderingAdapter.makeCSSSRGBFallback(color) ?? "#000"
        let p3 = ColorRenderingAdapter.makeCSSColor(color, target: .displayP3) ?? fallback
        return "<div class=\"swatch\" style=\"background: \(escapeAttribute(fallback)); background: \(escapeAttribute(p3));\"></div>"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "'", with: "&#39;")
    }
}
