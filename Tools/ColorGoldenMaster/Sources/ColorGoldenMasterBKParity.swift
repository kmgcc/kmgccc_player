import AppKit
import Foundation

struct BKParitySummary {
    var total = 0
    var pass = 0
    var reviewRequired = 0
    var blocker = 0

    var statusLine: String {
        "total=\(total) pass=\(pass) review_required=\(reviewRequired) blocker=\(blocker)"
    }
}

enum ColorGoldenMasterBKParity {
    static let reportVersion = 1

    static func buildRows() throws -> [BKParityRow] {
        let sections = try ColorGoldenMasterSamples.sections()
        var rows: [BKParityRow] = []
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

    static func summarize(_ rows: [BKParityRow]) -> BKParitySummary {
        var summary = BKParitySummary()
        for row in rows {
            summary.total += 1
            switch row.classification {
            case .pass:
                summary.pass += 1
            case .reviewRequired:
                summary.reviewRequired += 1
            case .blocker:
                summary.blocker += 1
            }
        }
        return summary
    }

    static func render() throws -> (text: String, summary: BKParitySummary) {
        let rows = try buildRows()
        let summary = summarize(rows)
        var lines: [String] = []
        lines.append("# BK Controlled Difference Report")
        lines.append("format_version: \(reportVersion)")
        lines.append("mode: bk-parity")
        lines.append("legacy_policy: \(BKPerceptualPolicy.legacyHSB.rawValue)")
        lines.append("candidate_policy: \(BKPerceptualPolicy.candidateOKLCH.rawValue)")
        lines.append("summary: \(summary.statusLine)")
        lines.append("")
        lines.append("sample\tsection\tpath\tscheme\trole\tinput_base_palette\tselected_extracted_palette\tlegacy_background_base\tcandidate_background_base\tlegacy_atmosphere\tcandidate_atmosphere\tlegacy_shape_swatches\tcandidate_shape_swatches\tlegacy_primary_shape\tcandidate_primary_shape\tlegacy_secondary_shape\tcandidate_secondary_shape\tlegacy_highlight_glow\tcandidate_highlight_glow\tlegacy_stabilized\tcandidate_stabilized\tlegacy_rgb_oklch\tcandidate_rgb_oklch\tdelta_l\tdelta_c\tdelta_h\tdelta_e_oklab\ttarget_gamut\tcontract_metrics\tclassification\treason")
        for row in rows {
            lines.append(row.tsvLine)
        }
        return (lines.joined(separator: "\n") + "\n", summary)
    }

    static func renderHTML() throws -> String {
        let rows = try buildRows()
        let summary = summarize(rows)
        return BKParityReviewArtifact.render(rows: rows, summary: summary)
    }

    private static func appendRows(
        sample: GoldenSample,
        sectionID: String,
        analysis: ArtworkColorAnalysis,
        to rows: inout [BKParityRow]
    ) {
        let missBasePalette = analysis.topPalette
        let hitBasePalette = analysis.displayPalette.isEmpty ? analysis.topPalette : analysis.displayPalette
        appendRowsForPath(
            sample: sample,
            sectionID: sectionID,
            path: "cache-miss",
            basePalette: missBasePalette,
            analysis: analysis,
            to: &rows
        )
        appendRowsForPath(
            sample: sample,
            sectionID: sectionID,
            path: "cache-hit",
            basePalette: hitBasePalette,
            analysis: analysis,
            to: &rows
        )
    }

    private static func appendRowsForPath(
        sample: GoldenSample,
        sectionID: String,
        path: String,
        basePalette: [NSColor],
        analysis: ArtworkColorAnalysis,
        to rows: inout [BKParityRow]
    ) {
        let selected = BKInputPalettePolicy.selectedPalette(
            analysis: analysis,
            basePalette: basePalette,
            richPalette: analysis.richPalette,
            fallbackPalette: ColorGoldenMasterSupport.bkFallbackPalette
        )
        for isDark in [true, false] {
            let scheme = isDark ? "dark" : "light"
            let legacy = BKLegacyHSBPolicy.palette(
                extracted: selected,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            let candidate = BKColorEngine.makeCandidateOKLCH(
                fromLegacy: legacy,
                analysis: analysis
            )
            let swatchSeed = ColorGoldenMasterSupport.stableSeed(
                for: sample.id,
                salt: "bk-parity-\(path)-\(scheme)"
            )
            let legacySwatches = BKLegacyHSBPolicy.shapeSwatches(
                seed: swatchSeed,
                extracted: selected,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis
            )
            let candidateSwatches = BKColorEngine.makeCandidateOKLCHShapeSwatches(
                seed: swatchSeed,
                extracted: selected,
                fallback: ColorGoldenMasterSupport.bkFallbackPalette,
                isDark: isDark,
                analysis: analysis,
                candidatePalette: candidate
            )
            let legacyStabilized = legacySwatches.colors.prefix(4).map {
                BKLegacyHSBPolicy.stabilize(
                    color: $0,
                    kind: .shape,
                    palette: legacy,
                    saturationJitter: 0.03,
                    brightnessJitter: 0.02
                )
            }
            let candidateStabilized = candidateSwatches.colors.prefix(4).map {
                BKColorEngine.stabilizeCandidateOKLCH(
                    color: $0,
                    kind: .shape,
                    palette: candidate,
                    saturationJitter: 0.03,
                    brightnessJitter: 0.02
                )
            }
            let metrics = BKPerceptualRolePolicy.contractMetrics(
                palette: candidate,
                shapeSwatches: candidateSwatches.colors,
                stabilizedShapes: Array(candidateStabilized),
                analysis: analysis
            )
            let context = BKParityContext(
                inputBasePalette: colorArrayDescription(basePalette),
                selectedExtractedPalette: colorArrayDescription(selected),
                legacyBackgroundBase: cgColorDescription(legacy.bgStops.first),
                candidateBackgroundBase: cgColorDescription(candidate.bgStops.first),
                legacyAtmosphere: cgColorArrayDescription(legacy.bgVariants.flatMap { $0 }.ifEmpty(legacy.bgStops)),
                candidateAtmosphere: cgColorArrayDescription(candidate.bgVariants.flatMap { $0 }.ifEmpty(candidate.bgStops)),
                legacyShapeSwatches: cgColorArrayDescription(legacySwatches.colors),
                candidateShapeSwatches: cgColorArrayDescription(candidateSwatches.colors),
                legacyPrimaryShape: cgColorDescription(legacySwatches.colors.first ?? legacy.shapePool.first),
                candidatePrimaryShape: cgColorDescription(candidateSwatches.colors.first ?? candidate.shapePool.first),
                legacySecondaryShape: cgColorDescription(legacySwatches.colors.dropFirst().first ?? legacy.shapePool.dropFirst().first),
                candidateSecondaryShape: cgColorDescription(candidateSwatches.colors.dropFirst().first ?? candidate.shapePool.dropFirst().first),
                legacyHighlightGlow: cgColorDescription(legacy.dotBase),
                candidateHighlightGlow: cgColorDescription(candidate.dotBase),
                legacyStabilized: cgColorArrayDescription(Array(legacyStabilized)),
                candidateStabilized: cgColorArrayDescription(Array(candidateStabilized))
            )

            let rolePairs = roleColorPairs(
                legacy: legacy,
                candidate: candidate,
                legacySwatches: legacySwatches.colors,
                candidateSwatches: candidateSwatches.colors,
                legacyStabilized: Array(legacyStabilized),
                candidateStabilized: Array(candidateStabilized)
            )
            for pair in rolePairs {
                let diff = ColorDifference(
                    legacy: nsColor(from: pair.legacy),
                    candidate: nsColor(from: pair.candidate)
                )
                rows.append(
                    BKParityRow(
                        sample: sample.id,
                        sectionID: sectionID,
                        path: path,
                        scheme: scheme,
                        role: pair.role.rawValue,
                        legacy: nsColor(from: pair.legacy),
                        candidate: nsColor(from: pair.candidate),
                        diff: diff,
                        context: context,
                        metrics: metrics
                    )
                )
            }
        }
    }

    private static func roleColorPairs(
        legacy: HarmonizedPalette,
        candidate: HarmonizedPalette,
        legacySwatches: [CGColor],
        candidateSwatches: [CGColor],
        legacyStabilized: [CGColor],
        candidateStabilized: [CGColor]
    ) -> [(role: BKSemanticColorRole, legacy: CGColor?, candidate: CGColor?)] {
        [
            (.backgroundBase, legacy.bgStops.first, candidate.bgStops.first),
            (
                .backgroundAtmosphere,
                legacy.bgVariants.flatMap { $0 }.dropFirst().first ?? legacy.bgStops.dropFirst().first,
                candidate.bgVariants.flatMap { $0 }.dropFirst().first ?? candidate.bgStops.dropFirst().first
            ),
            (.floatingShapePrimary, legacySwatches.first ?? legacy.shapePool.first, candidateSwatches.first ?? candidate.shapePool.first),
            (
                .floatingShapeSecondary,
                legacySwatches.dropFirst().first ?? legacy.shapePool.dropFirst().first,
                candidateSwatches.dropFirst().first ?? candidate.shapePool.dropFirst().first
            ),
            (.highlightGlow, legacy.dotBase, candidate.dotBase),
            (.stabilizedShape, legacyStabilized.first, candidateStabilized.first),
        ]
    }

    private static func nsColor(from color: CGColor?) -> NSColor {
        guard let color else { return NSColor.black }
        return ColorGoldenMasterSupport.nsColor(from: color) ?? NSColor.black
    }

    private static func colorArrayDescription(_ colors: [NSColor]) -> String {
        colors.map(ColorGoldenMasterSupport.colorDescription(_:)).joined(separator: " | ")
    }

    private static func cgColorDescription(_ color: CGColor?) -> String {
        ColorGoldenMasterSupport.colorDescription(color.map(nsColor(from:)))
    }

    private static func cgColorArrayDescription(_ colors: [CGColor]) -> String {
        colors.map { cgColorDescription($0) }.joined(separator: " | ")
    }
}

struct BKParityContext {
    let inputBasePalette: String
    let selectedExtractedPalette: String
    let legacyBackgroundBase: String
    let candidateBackgroundBase: String
    let legacyAtmosphere: String
    let candidateAtmosphere: String
    let legacyShapeSwatches: String
    let candidateShapeSwatches: String
    let legacyPrimaryShape: String
    let candidatePrimaryShape: String
    let legacySecondaryShape: String
    let candidateSecondaryShape: String
    let legacyHighlightGlow: String
    let candidateHighlightGlow: String
    let legacyStabilized: String
    let candidateStabilized: String
}

struct BKParityRow {
    let sample: String
    let sectionID: String
    let path: String
    let scheme: String
    let role: String
    let legacy: NSColor
    let candidate: NSColor
    let diff: ColorDifference
    let context: BKParityContext
    let metrics: BKLayerContractMetrics

    var classification: BKLayerContractClassification {
        metrics.classification
    }

    var reason: String {
        if !metrics.blockerReasons.isEmpty {
            return metrics.blockerReasons.joined(separator: "; ")
        }
        if !metrics.reviewReasons.isEmpty {
            return metrics.reviewReasons.joined(separator: "; ")
        }
        return "candidate satisfies BK layer contract"
    }

    var tsvLine: String {
        [
            sample,
            sectionID,
            path,
            scheme,
            role,
            context.inputBasePalette,
            context.selectedExtractedPalette,
            context.legacyBackgroundBase,
            context.candidateBackgroundBase,
            context.legacyAtmosphere,
            context.candidateAtmosphere,
            context.legacyShapeSwatches,
            context.candidateShapeSwatches,
            context.legacyPrimaryShape,
            context.candidatePrimaryShape,
            context.legacySecondaryShape,
            context.candidateSecondaryShape,
            context.legacyHighlightGlow,
            context.candidateHighlightGlow,
            context.legacyStabilized,
            context.candidateStabilized,
            ColorGoldenMasterSupport.colorDescription(legacy),
            ColorGoldenMasterSupport.colorDescription(candidate),
            ColorGoldenMasterSupport.f(diff.deltaL),
            ColorGoldenMasterSupport.f(diff.deltaC),
            ColorGoldenMasterSupport.f(diff.deltaH),
            ColorGoldenMasterSupport.f(diff.deltaEOKLab),
            diff.targetGamutDescription,
            metricDescription,
            classification.rawValue,
            reason,
        ].map(sanitizeTSV).joined(separator: "\t")
    }

    var metricDescription: String {
        [
            "bgL=\(ColorGoldenMasterSupport.f(metrics.backgroundBaseL))",
            "bgMaxC=\(ColorGoldenMasterSupport.f(metrics.backgroundMaxC))",
            "shapeMaxL=\(ColorGoldenMasterSupport.f(metrics.shapeMaxL))",
            "shapeMaxC=\(ColorGoldenMasterSupport.f(metrics.shapeMaxC))",
            "shapeMinL=\(ColorGoldenMasterSupport.f(metrics.shapeMinL))",
            "highlightL=\(ColorGoldenMasterSupport.f(metrics.highlightL))",
            "highlightC=\(ColorGoldenMasterSupport.f(metrics.highlightC))",
            "sRGBBgL=\(ColorGoldenMasterSupport.f(metrics.sRGBBackgroundBaseL))",
            "sRGBShapeMaxL=\(ColorGoldenMasterSupport.f(metrics.sRGBShapeMaxL))",
            "lightSep=\(ColorGoldenMasterSupport.f(metrics.lightModeSeparation))",
            "darkShapeUpper=\(ColorGoldenMasterSupport.f(metrics.darkModeShapeUpperBound))",
            "nearMonoMaxC=\(ColorGoldenMasterSupport.f(metrics.nearMonoMaxChroma))",
        ].joined(separator: ",")
    }

    private func sanitizeTSV(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

enum BKParityReviewArtifact {
    static func render(rows: [BKParityRow], summary: BKParitySummary) -> String {
        let grouped = Dictionary(grouping: rows) { row in
            "\(row.sample)::\(row.path)::\(row.scheme)"
        }
        let orderedKeys = grouped.keys.sorted()
        let cards = orderedKeys.map { key -> String in
            let groupRows = grouped[key] ?? []
            guard let first = groupRows.first else { return "" }
            let roles = groupRows.map(roleBlock(from:)).joined(separator: "\n")
            return """
            <section class="card \(first.classification.rawValue)">
              <header>
                <div>
                  <h2>\(escape(first.sample))</h2>
                  <p>\(escape(first.sectionID)) / \(escape(first.path)) / \(escape(first.scheme))</p>
                </div>
                <strong>\(escape(first.classification.rawValue))</strong>
              </header>
              <div class="metrics">\(escape(first.metricDescription))</div>
              <div class="roles">\(roles)</div>
              <p class="reason">\(escape(first.reason))</p>
            </section>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>BK Parity Review</title>
        <style>
        body { margin: 0; font: 13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f5f5f2; color: #1f2328; }
        main { max-width: 1400px; margin: 0 auto; padding: 24px; }
        h1 { margin: 0 0 6px; font-size: 24px; }
        .summary { margin: 0 0 20px; color: #4b5563; }
        .card { border: 1px solid #d7d7d2; border-radius: 8px; background: #fff; margin: 14px 0; padding: 14px; }
        .card.blocker { border-color: #b42318; }
        .card.review-required { border-color: #b7791f; }
        header { display: flex; justify-content: space-between; gap: 16px; align-items: baseline; margin-bottom: 10px; }
        h2 { font-size: 15px; margin: 0; }
        p { margin: 2px 0 0; }
        .metrics, .reason { color: #59636e; word-break: break-word; }
        .roles { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 10px; margin-top: 12px; }
        .role { border: 1px solid #e4e4df; border-radius: 6px; padding: 10px; background: #fbfbf9; }
        .role-title { display: flex; justify-content: space-between; gap: 8px; margin-bottom: 8px; font-weight: 600; }
        .swatches { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
        .swatch { min-height: 56px; border-radius: 6px; border: 1px solid rgba(0,0,0,.12); }
        .caption { margin-top: 4px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: #4b5563; word-break: break-word; }
        </style>
        </head>
        <body>
        <main>
          <h1>BK Parity Review</h1>
          <p class="summary">\(escape(summary.statusLine))</p>
          \(cards)
        </main>
        </body>
        </html>
        """
    }

    private static func roleBlock(from row: BKParityRow) -> String {
        let legacyCSS = cssColor(row.legacy, target: .displayP3)
        let candidateCSS = cssColor(row.candidate, target: .displayP3)
        return """
        <div class="role">
          <div class="role-title"><span>\(escape(row.role))</span><span>ΔE \(escape(ColorGoldenMasterSupport.f(row.diff.deltaEOKLab)))</span></div>
          <div class="swatches">
            <div>
              <div class="swatch" style="background:\(legacyCSS)"></div>
              <div class="caption">legacy<br>\(escape(ColorGoldenMasterSupport.colorDescription(row.legacy)))</div>
            </div>
            <div>
              <div class="swatch" style="background:\(candidateCSS)"></div>
              <div class="caption">candidate<br>\(escape(ColorGoldenMasterSupport.colorDescription(row.candidate)))</div>
            </div>
          </div>
        </div>
        """
    }

    private static func cssColor(_ color: NSColor, target: ColorRenderTarget) -> String {
        ColorRenderingAdapter.makeCSSColor(color, target: target)
            ?? ColorRenderingAdapter.makeCSSSRGBFallback(color)
            ?? "#808080"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] {
        isEmpty ? fallback : self
    }
}
