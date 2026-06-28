import AppKit
import Foundation
import SwiftUI

struct AccentParitySummary {
    var total = 0
    var unchanged = 0
    var acceptableDrift = 0
    var reviewRequired = 0
    var blocker = 0
    var approvedDelta = 0

    var statusLine: String {
        "total=\(total) unchanged=\(unchanged) acceptable_drift=\(acceptableDrift) review_required=\(reviewRequired) blocker=\(blocker) approved_delta=\(approvedDelta)"
    }
}

enum ColorGoldenMasterAccentParity {
    static let reportVersion = 1
    static let reviewDeltaE: CGFloat = 0.045
    static let reviewDeltaH: CGFloat = 0.055
    static let miniPlayerReviewDeltaE: CGFloat = 0.035
    static let blockerDeltaH: CGFloat = 0.120
    static let nearMonoChromaBlocker: CGFloat = 0.018

    static func buildRows() throws -> [AccentParityRow] {
        let manifest = try ApprovedAccentDeltaManifest.load()
        let sections = try accentSections()
        var rows: [AccentParityRow] = []
        for section in sections {
            for sample in section.samples {
                let loaded = try ColorGoldenMasterSupport.load(sample)
                appendRows(
                    sample: loaded.sample,
                    sectionID: section.id,
                    analysis: loaded.analysis,
                    approvedManifest: manifest,
                    to: &rows
                )
            }
        }
        return rows
    }

    static func summarize(_ rows: [AccentParityRow]) -> AccentParitySummary {
        var summary = AccentParitySummary()
        for row in rows {
            summary.total += 1
            switch row.classification {
            case .unchanged: summary.unchanged += 1
            case .acceptableDrift: summary.acceptableDrift += 1
            case .reviewRequired: summary.reviewRequired += 1
            case .blocker: summary.blocker += 1
            case .approvedDelta: summary.approvedDelta += 1
            }
        }
        return summary
    }

    static func render() throws -> (text: String, summary: AccentParitySummary) {
        let rows = try buildRows()
        let summary = summarize(rows)

        var lines: [String] = []
        lines.append("# Accent Controlled Difference Report")
        lines.append("format_version: \(reportVersion)")
        lines.append("mode: parity")
        lines.append("candidate_policy: \(AccentColorPolicy.Implementation.candidate.rawValue)")
        lines.append("legacy_policy: \(AccentColorPolicy.Implementation.legacy.rawValue)")
        lines.append("review_delta_e_oklab: \(ColorGoldenMasterSupport.f(reviewDeltaE))")
        lines.append("review_delta_h: \(ColorGoldenMasterSupport.f(reviewDeltaH))")
        lines.append("mini_player_review_delta_e_oklab: \(ColorGoldenMasterSupport.f(miniPlayerReviewDeltaE))")
        lines.append("blocker_delta_h: \(ColorGoldenMasterSupport.f(blockerDeltaH))")
        lines.append("near_mono_chroma_blocker: \(ColorGoldenMasterSupport.f(nearMonoChromaBlocker))")
        lines.append("summary: \(summary.statusLine)")
        lines.append("")
        lines.append("sample\tsurface\trole\tscheme\tlegacy_hex\tcandidate_hex\tlegacy_oklch\tcandidate_oklch\tdelta_l\tdelta_c\tdelta_h\tdelta_e_oklab\ttarget_gamut\tclassification\treason")
        for row in rows {
            lines.append(row.tsvLine)
        }
        return (lines.joined(separator: "\n") + "\n", summary)
    }

    // MARK: - Visual review artifact (tooling output, not strict baseline)

    /// Renders an HTML page of every blocker / review-required row with
    /// legacy vs candidate swatches in Display P3 (with sRGB fallback), the
    /// accent shown as foreground text on the scheme background, OKLCH
    /// values and per-channel deltas. Intended for fast human judgement of
    /// hue family, gray/dirty light accents, and neon dark accents.
    static func renderHTML() throws -> String {
        let rows = try buildRows()
        let summary = summarize(rows)
        let focus = rows.filter {
            $0.classification == .blocker || $0.classification == .reviewRequired
        }
        let surfaceOrder = ["globalAccent", "uiAccentOnDark", "uiAccentOnLight", "miniPlayer"]
        var html = htmlHead(summary: summary, focusCount: focus.count)
        for surface in surfaceOrder {
            let group = focus
                .filter { $0.surface == surface }
                .sorted { $0.diff.deltaEOKLab > $1.diff.deltaEOKLab }
            guard !group.isEmpty else { continue }
            html += "<h2>\(surface) — \(group.count) need review</h2>\n<table>\n"
            html += "<tr><th>sample</th><th>legacy (current)</th><th>candidate (OKLCH)</th><th>OKLCH</th><th>delta</th><th>gamut</th></tr>\n"
            for row in group { html += htmlRow(row) }
            html += "</table>\n"
        }
        html += "</body></html>\n"
        return html
    }

    private static func htmlHead(summary: AccentParitySummary, focusCount: Int) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <title>Accent Parity Review</title>
        <style>
          body { font: 13px -apple-system, system-ui, sans-serif; margin: 24px; color: #1c1c1e; background: #fff; }
          h1 { font-size: 20px; } h2 { font-size: 15px; margin-top: 28px; border-bottom: 1px solid #ddd; padding-bottom: 4px; }
          .summary { font-family: ui-monospace, Menlo, monospace; background: #f4f4f6; padding: 8px 10px; border-radius: 6px; }
          .note { color: #666; max-width: 70ch; }
          table { border-collapse: collapse; width: 100%; margin-top: 8px; }
          th { text-align: left; font-size: 11px; color: #888; font-weight: 600; padding: 4px 8px; }
          td { padding: 6px 8px; vertical-align: middle; border-top: 1px solid #eee; }
          .cellDark { background: #15161a; border-radius: 8px; }
          .cellLight { background: #f0f0f2; border-radius: 8px; }
          .pill { display: inline-block; width: 72px; height: 26px; border-radius: 13px; vertical-align: middle; }
          .fg { display: inline-block; margin-left: 8px; font-weight: 700; font-size: 15px; vertical-align: middle; }
          .cap { font-family: ui-monospace, Menlo, monospace; font-size: 10px; color: #999; margin-top: 3px; }
          .cellDark .cap { color: #aaa; }
          .sample { font-family: ui-monospace, Menlo, monospace; font-size: 11px; }
          .sub { color: #888; font-size: 11px; }
          .cls { display: inline-block; font-size: 10px; padding: 1px 6px; border-radius: 4px; margin-top: 3px; }
          .review-required { background: #fff3cd; color: #856404; }
          .blocker { background: #f8d7da; color: #721c24; }
          .oklch, .delta { font-family: ui-monospace, Menlo, monospace; font-size: 11px; white-space: nowrap; }
          .gamut { font-family: ui-monospace, Menlo, monospace; font-size: 10px; color: #999; max-width: 22ch; }
        </style></head><body>
        <h1>Accent Parity Review</h1>
        <p class="summary">\(summary.statusLine)</p>
        <p class="note">\(focusCount) rows shown (blocker + review-required). Swatches render in Display&nbsp;P3 on a capable display/browser, with sRGB fallback otherwise. <b>Legacy</b> is current production output; <b>candidate</b> is the OKLCH policy. Each cell sits on the scheme background, with the accent also drawn as foreground text to judge readability / gray / neon. Sorted worst-&Delta;E first per surface. Tooling artifact only &mdash; not part of the strict golden baseline.</p>
        """
    }

    private static func htmlRow(_ row: AccentParityRow) -> String {
        let d = row.diff
        let lL = d.legacyLCH.map { ColorGoldenMasterSupport.f($0.l) } ?? "—"
        let lC = d.legacyLCH.map { ColorGoldenMasterSupport.f($0.c) } ?? "—"
        let lH = d.legacyLCH.map { ColorGoldenMasterSupport.f($0.h) } ?? "—"
        let cL = d.candidateLCH.map { ColorGoldenMasterSupport.f($0.l) } ?? "—"
        let cC = d.candidateLCH.map { ColorGoldenMasterSupport.f($0.c) } ?? "—"
        let cH = d.candidateLCH.map { ColorGoldenMasterSupport.f($0.h) } ?? "—"
        let deltas = "ΔL \(ColorGoldenMasterSupport.f(d.deltaL))<br>ΔC \(ColorGoldenMasterSupport.f(d.deltaC))<br>ΔH \(ColorGoldenMasterSupport.f(d.deltaH))<br><b>ΔE \(ColorGoldenMasterSupport.f(d.deltaEOKLab))</b>"
        return """
        <tr>
          <td><div class="sample">\(htmlEscape(row.sample))</div><div class="sub">\(row.role) · \(row.scheme)</div><div class="cls \(row.classification.rawValue)">\(row.classification.rawValue)</div></td>
          \(swatchCell(row.legacy, scheme: row.scheme, caption: ColorGoldenMasterSupport.hex(row.legacy)))
          \(swatchCell(row.candidate, scheme: row.scheme, caption: ColorGoldenMasterSupport.hex(row.candidate)))
          <td class="oklch">L \(lL)→\(cL)<br>C \(lC)→\(cC)<br>H \(lH)→\(cH)</td>
          <td class="delta">\(deltas)</td>
          <td class="gamut">\(htmlEscape(d.targetGamutDescription))</td>
        </tr>
        """
    }

    private static func swatchCell(_ color: NSColor, scheme: String, caption: String) -> String {
        let cls = scheme == "dark" ? "cellDark" : "cellLight"
        return """
        <td class="\(cls)"><span class="pill" style="\(cssBackground(color))"></span><span class="fg" style="\(cssForeground(color))">Aa 12:34</span><div class="cap">\(htmlEscape(caption))</div></td>
        """
    }

    private static func cssBackground(_ color: NSColor) -> String {
        let srgb = ColorRenderingAdapter.makeCSSSRGBFallback(color) ?? "#888888"
        let p3 = ColorRenderingAdapter.makeCSSColor(color, target: .displayP3) ?? srgb
        return "background:\(srgb);background:\(p3);"
    }

    private static func cssForeground(_ color: NSColor) -> String {
        let srgb = ColorRenderingAdapter.makeCSSSRGBFallback(color) ?? "#888888"
        let p3 = ColorRenderingAdapter.makeCSSColor(color, target: .displayP3) ?? srgb
        return "color:\(srgb);color:\(p3);"
    }

    private static func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func appendRows(
        sample: GoldenSample,
        sectionID: String,
        analysis: ArtworkColorAnalysis,
        approvedManifest: ApprovedAccentDeltaManifest,
        to rows: inout [AccentParityRow]
    ) {
        let legacyDark = AccentColorPolicy.legacyOptimizedAccent(for: .dark, analysis: analysis)
        let legacyLight = AccentColorPolicy.legacyOptimizedAccent(for: .light, analysis: analysis)
        let candidateDark = AccentColorPolicy.candidateOptimizedAccent(for: .dark, analysis: analysis)
        let candidateLight = AccentColorPolicy.candidateOptimizedAccent(for: .light, analysis: analysis)

        appendRow(
            sample: sample,
            sectionID: sectionID,
            surface: "globalAccent",
            role: "globalAccent",
            scheme: .dark,
            legacy: legacyDark,
            candidate: candidateDark,
            analysis: analysis,
            approvedManifest: approvedManifest,
            to: &rows
        )
        appendRow(
            sample: sample,
            sectionID: sectionID,
            surface: "globalAccent",
            role: "globalAccent",
            scheme: .light,
            legacy: legacyLight,
            candidate: candidateLight,
            analysis: analysis,
            approvedManifest: approvedManifest,
            to: &rows
        )
        appendRow(
            sample: sample,
            sectionID: sectionID,
            surface: "uiAccentOnDark",
            role: "uiAccentOnDark",
            scheme: .dark,
            legacy: legacyDark,
            candidate: candidateDark,
            analysis: analysis,
            approvedManifest: approvedManifest,
            to: &rows
        )
        appendRow(
            sample: sample,
            sectionID: sectionID,
            surface: "uiAccentOnLight",
            role: "uiAccentOnLight",
            scheme: .light,
            legacy: legacyLight,
            candidate: candidateLight,
            analysis: analysis,
            approvedManifest: approvedManifest,
            to: &rows
        )
        appendRow(
            sample: sample,
            sectionID: sectionID,
            surface: "miniPlayer",
            role: "controlPrimary",
            scheme: .dark,
            legacy: AccentColorPolicy.legacyMiniPlayerControlColor(base: legacyDark, scheme: .dark),
            candidate: AccentColorPolicy.candidateMiniPlayerControlColor(base: candidateDark, scheme: .dark),
            analysis: analysis,
            approvedManifest: approvedManifest,
            to: &rows
        )
        appendRow(
            sample: sample,
            sectionID: sectionID,
            surface: "miniPlayer",
            role: "controlPrimary",
            scheme: .light,
            legacy: AccentColorPolicy.legacyMiniPlayerControlColor(base: legacyLight, scheme: .light),
            candidate: AccentColorPolicy.candidateMiniPlayerControlColor(base: candidateLight, scheme: .light),
            analysis: analysis,
            approvedManifest: approvedManifest,
            to: &rows
        )
    }

    private static func appendRow(
        sample: GoldenSample,
        sectionID: String,
        surface: String,
        role: String,
        scheme: ColorScheme,
        legacy: NSColor,
        candidate: NSColor,
        analysis: ArtworkColorAnalysis,
        approvedManifest: ApprovedAccentDeltaManifest,
        to rows: inout [AccentParityRow]
    ) {
        let diff = ColorDifference(legacy: legacy, candidate: candidate)
        let key = ApprovedAccentDeltaManifest.Key(
            sample: sample.id,
            surface: surface,
            role: role,
            scheme: schemeName(scheme)
        )
        let classification = classify(
            key: key,
            surface: surface,
            diff: diff,
            analysis: analysis,
            approvedManifest: approvedManifest
        )
        rows.append(
            AccentParityRow(
                sample: sample.id,
                sectionID: sectionID,
                surface: surface,
                role: role,
                scheme: schemeName(scheme),
                legacy: legacy,
                candidate: candidate,
                diff: diff,
                classification: classification.kind,
                reason: classification.reason
            )
        )
    }

    private static func classify(
        key: ApprovedAccentDeltaManifest.Key,
        surface: String,
        diff: ColorDifference,
        analysis: ArtworkColorAnalysis,
        approvedManifest: ApprovedAccentDeltaManifest
    ) -> (kind: AccentParityClassification, reason: String) {
        if diff.isUnchanged {
            return (.unchanged, "no RGB/OKLCH drift")
        }

        // Blockers are evaluated before the approved-delta manifest so a manifest
        // entry can never bless away a hard blocker (nearMono neon / hue-family
        // crossing). Approved-delta may only downgrade review-required drift.
        if analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate
            && diff.candidateLCH?.c ?? 0 > nearMonoChromaBlocker {
            return (.blocker, "nearMono candidate chroma exceeds neutral ceiling")
        }

        if let legacy = diff.legacyLCH,
           let candidate = diff.candidateLCH,
           legacy.c >= 0.030,
           candidate.c >= 0.030,
           diff.deltaH > blockerDeltaH {
            return (.blocker, "hue family likely crossed")
        }

        if approvedManifest.contains(key) {
            return (.approvedDelta, approvedManifest.reason(for: key) ?? "approved manifest entry")
        }

        let reviewE = surface == "miniPlayer" ? miniPlayerReviewDeltaE : reviewDeltaE
        if diff.deltaEOKLab >= reviewE {
            return (.reviewRequired, "deltaE exceeds initial review threshold")
        }
        if diff.deltaH >= reviewDeltaH && (diff.legacyLCH?.c ?? 0) >= 0.030 {
            return (.reviewRequired, "hue drift exceeds initial review threshold")
        }
        return (.acceptableDrift, "same-family small drift under initial thresholds")
    }

    private static func accentSections() throws -> [GoldenSampleSection] {
        var sections = try ColorGoldenMasterSamples.sections()
        sections.append(
            GoldenSampleSection(
                id: "accent_synthetic",
                title: "Accent Migration Synthetic",
                samples: accentSyntheticSamples
            )
        )
        return sections
    }

    private static let accentSyntheticSamples: [GoldenSample] = [
        GoldenSample(
            id: "accent.synthetic.high-chroma-blue",
            title: "Accent synthetic high chroma blue",
            note: "Dedicated accent parity sample for saturated blue.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (25, 70, 245, 255))])
        ),
        GoldenSample(
            id: "accent.synthetic.high-chroma-green",
            title: "Accent synthetic high chroma green",
            note: "Dedicated accent parity sample for saturated green.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (20, 205, 70, 255))])
        ),
        GoldenSample(
            id: "accent.synthetic.high-chroma-red",
            title: "Accent synthetic high chroma red",
            note: "Dedicated accent parity sample for saturated red.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (230, 32, 44, 255))])
        ),
        GoldenSample(
            id: "accent.synthetic.warm-yellow-paper",
            title: "Accent synthetic warm yellow paper",
            note: "Dedicated accent parity sample for warm paper.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.70, (205, 185, 124, 255)),
                SyntheticRegion(0.20, (116, 92, 48, 255)),
                SyntheticRegion(0.10, (245, 229, 170, 255)),
            ])
        ),
        GoldenSample(
            id: "accent.synthetic.near-mono-dark-gray",
            title: "Accent synthetic nearMono dark gray",
            note: "Dedicated accent parity sample for dark nearMono.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (42, 42, 42, 255))])
        ),
        GoldenSample(
            id: "accent.synthetic.ultra-dark-trusted-teal",
            title: "Accent synthetic UltraDark trusted teal",
            note: "Dedicated accent parity sample for UltraDark with trusted hue.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.82, (5, 13, 16, 255)),
                SyntheticRegion(0.18, (18, 125, 132, 255)),
            ])
        ),
        GoldenSample(
            id: "accent.synthetic.low-light-high-chroma",
            title: "Accent synthetic low light high chroma",
            note: "Dedicated accent parity sample for low-light saturated color.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.72, (8, 9, 18, 255)),
                SyntheticRegion(0.28, (96, 20, 170, 255)),
            ])
        ),
        GoldenSample(
            id: "accent.synthetic.black-small-color",
            title: "Accent synthetic black small color",
            note: "Dedicated accent parity sample for black field with small color block.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.94, (0, 0, 0, 255)),
                SyntheticRegion(0.06, (42, 150, 255, 255)),
            ])
        ),
        GoldenSample(
            id: "accent.synthetic.p3-edge-orange",
            title: "Accent synthetic P3 edge orange proxy",
            note: "sRGB proxy near a high-chroma P3 orange edge for fallback stability.",
            source: .synthetic(side: 64, regions: [SyntheticRegion(1.0, (255, 95, 10, 255))])
        ),
    ]

    private static func schemeName(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }
}

enum AccentParityClassification: String {
    case unchanged
    case acceptableDrift = "acceptable-drift"
    case reviewRequired = "review-required"
    case blocker
    case approvedDelta = "approved-delta"
}

struct AccentParityRow {
    let sample: String
    let sectionID: String
    let surface: String
    let role: String
    let scheme: String
    let legacy: NSColor
    let candidate: NSColor
    let diff: ColorDifference
    let classification: AccentParityClassification
    let reason: String

    var tsvLine: String {
        [
            sample,
            surface,
            role,
            scheme,
            ColorGoldenMasterSupport.hex(legacy),
            ColorGoldenMasterSupport.hex(candidate),
            ColorGoldenMasterSupport.lchDescription(diff.legacyLCH),
            ColorGoldenMasterSupport.lchDescription(diff.candidateLCH),
            ColorGoldenMasterSupport.f(diff.deltaL),
            ColorGoldenMasterSupport.f(diff.deltaC),
            ColorGoldenMasterSupport.f(diff.deltaH),
            ColorGoldenMasterSupport.f(diff.deltaEOKLab),
            diff.targetGamutDescription,
            classification.rawValue,
            reason,
        ].map(sanitizeTSV).joined(separator: "\t")
    }

    private func sanitizeTSV(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

struct ColorDifference {
    let legacyLCH: OKColor.OKLCH?
    let candidateLCH: OKColor.OKLCH?
    let deltaL: CGFloat
    let deltaC: CGFloat
    let deltaH: CGFloat
    let deltaEOKLab: CGFloat
    let targetGamutDescription: String
    let isUnchanged: Bool

    init(legacy: NSColor, candidate: NSColor) {
        legacyLCH = OKColor.nsColorToOKLCH(legacy)
        candidateLCH = OKColor.nsColorToOKLCH(candidate)
        if let legacyLCH, let candidateLCH {
            deltaL = abs(candidateLCH.l - legacyLCH.l)
            deltaC = abs(candidateLCH.c - legacyLCH.c)
            deltaH = ColorMath.circularHueDistance(candidateLCH.h, legacyLCH.h)
            let legacyLab = OKColor.okLCHToOKLab(legacyLCH)
            let candidateLab = OKColor.okLCHToOKLab(candidateLCH)
            deltaEOKLab = sqrt(
                pow(candidateLab.l - legacyLab.l, 2)
                    + pow(candidateLab.a - legacyLab.a, 2)
                    + pow(candidateLab.b - legacyLab.b, 2)
            )
        } else {
            deltaL = 1
            deltaC = 1
            deltaH = 1
            deltaEOKLab = 1
        }

        let legacyHex = ColorGoldenMasterSupport.hex(legacy)
        let candidateHex = ColorGoldenMasterSupport.hex(candidate)
        isUnchanged = legacyHex == candidateHex
            && deltaL < 0.00005
            && deltaC < 0.00005
            && deltaH < 0.00005
            && deltaEOKLab < 0.00005

        let legacyP3 = ColorRenderingAdapter.resolve(legacy, target: .displayP3)
        let candidateP3 = ColorRenderingAdapter.resolve(candidate, target: .displayP3)
        let legacySRGB = ColorRenderingAdapter.resolve(legacy, target: .sRGB)
        let candidateSRGB = ColorRenderingAdapter.resolve(candidate, target: .sRGB)
        targetGamutDescription = [
            "displayP3",
            "legacyC=\(ColorGoldenMasterSupport.f(CGFloat(legacyP3?.resolvedChroma ?? 0)))",
            "candidateC=\(ColorGoldenMasterSupport.f(CGFloat(candidateP3?.resolvedChroma ?? 0)))",
            "sRGBLegacyMapped=\(ColorGoldenMasterSupport.bool(legacySRGB?.wasGamutMapped ?? false))",
            "sRGBCandidateMapped=\(ColorGoldenMasterSupport.bool(candidateSRGB?.wasGamutMapped ?? false))",
        ].joined(separator: ",")
    }
}

struct ApprovedAccentDeltaManifest: Decodable {
    struct Entry: Decodable {
        let sample: String
        let surface: String
        let role: String
        let scheme: String
        let reason: String
    }

    struct Key: Hashable {
        let sample: String
        let surface: String
        let role: String
        let scheme: String
    }

    let version: Int
    let deltas: [Entry]

    static func load() throws -> ApprovedAccentDeltaManifest {
        let url = ColorGoldenMasterCLI.toolDirectory
            .appendingPathComponent("ApprovedDeltas/accent-approved-deltas.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ApprovedAccentDeltaManifest(version: 1, deltas: [])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ApprovedAccentDeltaManifest.self, from: data)
    }

    func contains(_ key: Key) -> Bool {
        deltas.contains { entry in
            entry.sample == key.sample
                && entry.surface == key.surface
                && entry.role == key.role
                && entry.scheme == key.scheme
        }
    }

    func reason(for key: Key) -> String? {
        deltas.first { entry in
            entry.sample == key.sample
                && entry.surface == key.surface
                && entry.role == key.role
                && entry.scheme == key.scheme
        }?.reason
    }
}
