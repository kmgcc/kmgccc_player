import AppKit
import Foundation

enum AccentParityReviewArtifact {
    static let queueName = "Stage 3 Accent Parity Review"
    static let maxQueueCount = 100

    static func render(rows: [AccentParityRow], summary: AccentParitySummary) throws -> String {
        let queue = reviewQueue(from: rows)
        let payload = ReviewPagePayload(
            formatVersion: 1,
            generatedAt: isoTimestamp(),
            queueName: queueName,
            sourceReport: ColorGoldenMasterCLI.accentParityURL.path,
            fullReportTotal: rows.count,
            fullReviewRequired: summary.reviewRequired,
            fullBlocker: summary.blocker,
            fullAcceptableDrift: summary.acceptableDrift,
            fullApprovedDelta: summary.approvedDelta,
            queueCount: queue.count,
            summaryLine: summary.statusLine,
            items: queue.map(makeItem(from:))
        )
        return try html(payload: payload)
    }

    static func exportReviewSession(path: String) throws -> AccentReviewExportResult {
        let sessionURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: sessionURL)
        let decoder = JSONDecoder()
        let session = try decoder.decode(AccentReviewSession.self, from: data)

        let outputDirectory = ColorGoldenMasterCLI.toolDirectory
            .appendingPathComponent("ReviewSessions", isDirectory: true)
            .appendingPathComponent("\(sessionURL.deletingPathExtension().lastPathComponent)-export", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let decisions = session.decisions.sorted { left, right in
            if left.sample != right.sample { return left.sample < right.sample }
            if left.surface != right.surface { return left.surface < right.surface }
            if left.role != right.role { return left.role < right.role }
            return left.scheme < right.scheme
        }
        var byID: [String: AccentReviewDecision] = [:]
        for decision in decisions {
            byID[decision.id] = decision
        }
        let unresolvedFromQueue = session.queueItems?
            .filter { byID[$0.id] == nil }
            .map { AccentReviewDecision(queueItem: $0, decision: "undecided") }
            ?? []

        let approved = decisions.filter { $0.decision == "candidate_better" && $0.approvedDelta }
        let needsTuning = decisions.filter { $0.decision == "needs_tuning" }
        let legacyBetter = decisions.filter { $0.decision == "legacy_better" }
        let candidateBetter = decisions.filter { $0.decision == "candidate_better" }
        let bothAcceptable = decisions.filter { $0.decision == "both_acceptable" }
        let undecided = decisions.filter { $0.decision == "skip_undecided" } + unresolvedFromQueue

        let approvedManifest = ApprovedAccentDeltaCandidate(
            version: 1,
            sourceReviewSession: sessionURL.path,
            generatedAt: isoTimestamp(),
            deltas: approved.map { decision in
                ApprovedAccentDeltaCandidate.Entry(
                    sample: decision.sample,
                    surface: decision.surface,
                    role: decision.role,
                    scheme: decision.scheme,
                    reason: decision.note?.isEmpty == false
                        ? decision.note!
                        : "accent review: candidate better"
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let approvedURL = outputDirectory.appendingPathComponent("accent-approved-deltas.candidate.json")
        try encoder.encode(approvedManifest).write(to: approvedURL, options: .atomic)

        let needsTuningURL = outputDirectory.appendingPathComponent("needs-tuning.md")
        let legacyBetterURL = outputDirectory.appendingPathComponent("legacy-better.md")
        let candidateBetterURL = outputDirectory.appendingPathComponent("candidate-better.md")
        let bothAcceptableURL = outputDirectory.appendingPathComponent("both-acceptable.md")
        let undecidedURL = outputDirectory.appendingPathComponent("undecided.md")
        let summaryURL = outputDirectory.appendingPathComponent("summary.md")

        try markdownList(title: "Needs Tuning", decisions: needsTuning).write(to: needsTuningURL, atomically: true, encoding: .utf8)
        try markdownList(title: "Legacy Better", decisions: legacyBetter).write(to: legacyBetterURL, atomically: true, encoding: .utf8)
        try markdownList(title: "Candidate Better", decisions: candidateBetter).write(to: candidateBetterURL, atomically: true, encoding: .utf8)
        try markdownList(title: "Both Acceptable", decisions: bothAcceptable).write(to: bothAcceptableURL, atomically: true, encoding: .utf8)
        try markdownList(title: "Undecided", decisions: undecided).write(to: undecidedURL, atomically: true, encoding: .utf8)

        let summaryText = """
        # Accent Review Session Export

        source_session: \(sessionURL.path)
        source_report: \(session.sourceReport)
        decisions: \(decisions.count)
        approved_delta_candidates: \(approved.count)
        needs_tuning: \(needsTuning.count)
        legacy_better: \(legacyBetter.count)
        candidate_better: \(candidateBetter.count)
        both_acceptable: \(bothAcceptable.count)
        undecided: \(undecided.count)

        Files:
        - \(approvedURL.path)
        - \(needsTuningURL.path)
        - \(legacyBetterURL.path)
        - \(candidateBetterURL.path)
        - \(bothAcceptableURL.path)
        - \(undecidedURL.path)
        """
        try summaryText.write(to: summaryURL, atomically: true, encoding: .utf8)

        return AccentReviewExportResult(
            outputDirectory: outputDirectory.path,
            approvedURL: approvedURL.path,
            needsTuningURL: needsTuningURL.path,
            legacyBetterURL: legacyBetterURL.path,
            undecidedURL: undecidedURL.path,
            summaryURL: summaryURL.path,
            approvedCount: approved.count,
            needsTuningCount: needsTuning.count,
            legacyBetterCount: legacyBetter.count,
            undecidedCount: undecided.count,
            decisionCount: decisions.count
        )
    }

    private static func reviewQueue(from rows: [AccentParityRow]) -> [AccentReviewSelection] {
        let allCandidates = rows
            .filter { $0.classification != .unchanged }
            .map { row in
                AccentReviewSelection(row: row, queueReasons: [])
            }
        let focusCandidates = rows
            .filter { $0.classification == .blocker || $0.classification == .reviewRequired }
            .map { row in
                AccentReviewSelection(row: row, queueReasons: [])
            }

        var selected: [String: AccentReviewSelection] = [:]
        var order: [String] = []
        var sampleCounts: [String: Int] = [:]

        func consider(
            _ rows: [AccentReviewSelection],
            reason: String,
            limit: Int,
            sampleLimit: Int = 3
        ) {
            var added = 0
            for var selection in rows where added < limit && selected.count < maxQueueCount {
                let id = itemID(selection.row)
                if selected[id] != nil {
                    selected[id]?.queueReasons.append(reason)
                    continue
                }
                guard (sampleCounts[selection.row.sample] ?? 0) < sampleLimit else { continue }
                selection.queueReasons.append(reason)
                selected[id] = selection
                order.append(id)
                sampleCounts[selection.row.sample, default: 0] += 1
                added += 1
            }
        }

        let byDelta = focusCandidates.sorted { $0.row.diff.deltaEOKLab > $1.row.diff.deltaEOKLab }
        let allByDelta = allCandidates.sorted { $0.row.diff.deltaEOKLab > $1.row.diff.deltaEOKLab }
        consider(Array(byDelta.prefix(90)), reason: "top-delta", limit: 30, sampleLimit: 2)

        for family in colorFamilyOrder {
            consider(
                allByDelta.filter { colorFamily(for: $0.row) == family },
                reason: "family-\(family)",
                limit: 3,
                sampleLimit: 5
            )
        }

        for risk in priorityRiskTags {
            consider(
                allByDelta.filter { riskTags(for: $0.row).contains(risk) },
                reason: "risk-\(risk)",
                limit: 3,
                sampleLimit: 5
            )
        }

        consider(allByDelta.filter { !riskTags(for: $0.row).isEmpty }, reason: "risk-sample", limit: 18, sampleLimit: 4)
        consider(byDelta.filter { $0.row.surface == "miniPlayer" }, reason: "mini-player", limit: 20, sampleLimit: 3)
        consider(byDelta.filter { $0.row.scheme == "light" }, reason: "light-mode", limit: 16, sampleLimit: 3)
        consider(byDelta.filter { $0.row.scheme == "dark" }, reason: "dark-mode", limit: 12, sampleLimit: 3)
        consider(byDelta, reason: "coverage-fill", limit: maxQueueCount, sampleLimit: 8)

        let ordered = order.compactMap { selected[$0] }
        return interleaved(ordered)
    }

    private static func interleaved(_ selections: [AccentReviewSelection]) -> [AccentReviewSelection] {
        var buckets: [String: [AccentReviewSelection]] = [:]
        for selection in selections {
            buckets[colorFamily(for: selection.row), default: []].append(selection)
        }
        let keys = colorFamilyOrder + buckets.keys.sorted().filter { !colorFamilyOrder.contains($0) }
        var result: [AccentReviewSelection] = []
        while result.count < selections.count {
            var appended = false
            for key in keys {
                guard var bucket = buckets[key], !bucket.isEmpty else { continue }
                result.append(bucket.removeFirst())
                buckets[key] = bucket
                appended = true
            }
            if !appended { break }
        }
        return result
    }

    private static func makeItem(from selection: AccentReviewSelection) -> AccentReviewItem {
        let row = selection.row
        return AccentReviewItem(
            id: itemID(row),
            sample: row.sample,
            sectionID: row.sectionID,
            surface: row.surface,
            role: row.role,
            scheme: row.scheme,
            colorFamily: colorFamily(for: row),
            colorCategory: colorCategory(for: row),
            riskTags: riskTags(for: row),
            queueReasons: selection.queueReasons,
            classification: row.classification.rawValue,
            reason: row.reason,
            targetGamut: row.diff.targetGamutDescription,
            legacy: colorPayload(row.legacy),
            candidate: colorPayload(row.candidate),
            diff: diffPayload(row.diff)
        )
    }

    private static func itemID(_ row: AccentParityRow) -> String {
        "\(row.sample)::\(row.surface)::\(row.role)::\(row.scheme)"
    }

    private static func colorPayload(_ color: NSColor) -> AccentReviewColor {
        let lch = OKColor.nsColorToOKLCH(color)
        let p3 = ColorRenderingAdapter.resolve(color, target: .displayP3)
        let srgb = ColorRenderingAdapter.resolve(color, target: .sRGB)
        let p3CSS = ColorRenderingAdapter.makeCSSColor(color, target: .displayP3)
            ?? ColorRenderingAdapter.makeCSSSRGBFallback(color)
            ?? "rgb(128 128 128)"
        let srgbCSS = ColorRenderingAdapter.makeCSSSRGBFallback(color) ?? "rgb(128 128 128)"
        return AccentReviewColor(
            hex: ColorGoldenMasterSupport.hex(color),
            oklch: lch.map { AccentReviewOKLCH(l: Double($0.l), c: Double($0.c), h: Double($0.h)) },
            displayP3CSS: p3CSS,
            sRGBCSS: srgbCSS,
            displayP3: p3.map(AccentReviewResolvedColor.init(_:)),
            sRGB: srgb.map(AccentReviewResolvedColor.init(_:))
        )
    }

    private static func diffPayload(_ diff: ColorDifference) -> AccentReviewDiff {
        AccentReviewDiff(
            deltaL: Double(diff.deltaL),
            deltaC: Double(diff.deltaC),
            deltaH: Double(diff.deltaH),
            deltaEOKLab: Double(diff.deltaEOKLab),
            signedDeltaL: Double((diff.candidateLCH?.l ?? 0) - (diff.legacyLCH?.l ?? 0)),
            signedDeltaC: Double((diff.candidateLCH?.c ?? 0) - (diff.legacyLCH?.c ?? 0)),
            signedDeltaH: signedHueDelta(legacy: diff.legacyLCH?.h, candidate: diff.candidateLCH?.h)
        )
    }

    private static func signedHueDelta(legacy: CGFloat?, candidate: CGFloat?) -> Double {
        guard let legacy, let candidate else { return 0 }
        var delta = candidate - legacy
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        return Double(delta)
    }

    private static let colorFamilyOrder = [
        "red", "orange", "yellow", "yellow-green", "green", "teal",
        "cyan", "blue", "purple", "pink-magenta", "warm-neutral",
        "cool-neutral", "nearMono", "UltraDark"
    ]

    private static let priorityRiskTags = [
        "P3-edge synthetic",
        "black small color",
        "nearMono",
        "UltraDark",
        "high-chroma blue",
        "high-chroma red",
        "high-chroma green",
        "warm paper / yellow",
        "low-chroma hue-trusted"
    ]

    private static func colorFamily(for row: AccentParityRow) -> String {
        if row.isNearMonochrome { return "nearMono" }
        if row.isUltraDark { return "UltraDark" }
        let legacy = row.diff.legacyLCH
        let candidate = row.diff.candidateLCH
        let chroma = ((legacy?.c ?? 0) + (candidate?.c ?? 0)) * 0.5
        let hue = candidate?.h ?? legacy?.h ?? 0
        if chroma < 0.035 {
            return isWarmNeutralHue(hue) ? "warm-neutral" : "cool-neutral"
        }
        switch normalizedHue(hue) {
        case 0..<0.035, 0.965...1: return "red"
        case 0.035..<0.105: return "orange"
        case 0.105..<0.170: return "yellow"
        case 0.170..<0.260: return "yellow-green"
        case 0.260..<0.420: return "green"
        case 0.420..<0.500: return "teal"
        case 0.500..<0.580: return "cyan"
        case 0.580..<0.700: return "blue"
        case 0.700..<0.820: return "purple"
        default: return "pink-magenta"
        }
    }

    private static func colorCategory(for row: AccentParityRow) -> String {
        let family = colorFamily(for: row)
        if row.isNearMonochrome { return "nearMono" }
        if row.isUltraDark { return "\(family) · UltraDark" }
        let chroma = ((row.diff.legacyLCH?.c ?? 0) + (row.diff.candidateLCH?.c ?? 0)) * 0.5
        if chroma >= 0.120 { return "high-chroma \(family)" }
        if chroma < 0.045 { return "\(family) low-chroma" }
        return family
    }

    private static func riskTags(for row: AccentParityRow) -> [String] {
        var tags: [String] = []
        let family = colorFamily(for: row)
        let chroma = max(row.diff.legacyLCH?.c ?? 0, row.diff.candidateLCH?.c ?? 0)
        if row.isNearMonochrome { tags.append("nearMono") }
        if row.isUltraDark { tags.append("UltraDark") }
        if row.hasTrustedHueCandidate && chroma < 0.070 && !row.isNearMonochrome {
            tags.append("low-chroma hue-trusted")
        }
        if chroma >= 0.120 && ["blue", "purple", "red", "green"].contains(family) {
            tags.append("high-chroma \(family)")
        }
        if row.sample.contains("warm-yellow-paper") || family == "yellow" {
            tags.append("warm paper / yellow")
        }
        if row.sample.contains("black-small-color") {
            tags.append("black small color")
        }
        if row.sample.contains("p3-edge") {
            tags.append("P3-edge synthetic")
        }
        return Array(Set(tags)).sorted()
    }

    private static func isWarmNeutralHue(_ hue: CGFloat) -> Bool {
        let h = normalizedHue(hue)
        return h < 0.180 || h > 0.880
    }

    private static func normalizedHue(_ hue: CGFloat) -> CGFloat {
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }

    private static func html(payload: ReviewPagePayload) throws -> String {
        let data = try jsonForHTML(payload)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Accent Parity Review</title>
        <style>
        :root {
          color-scheme: dark;
          --bg: #111214;
          --panel: #1b1d21;
          --panel2: #22252a;
          --stroke: #343841;
          --text: #f2f3f5;
          --muted: #a7acb7;
          --soft: #737a87;
          --good: #62d38f;
          --warn: #e7c66b;
          --bad: #ff7a86;
          --focus: #8fb6ff;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          background: var(--bg);
          color: var(--text);
          font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
          letter-spacing: 0;
        }
        button, select, input, textarea {
          font: inherit;
        }
        button {
          border: 1px solid var(--stroke);
          background: #262a31;
          color: var(--text);
          min-height: 34px;
          border-radius: 6px;
          padding: 6px 10px;
          cursor: pointer;
        }
        button:hover { border-color: #5b6372; background: #303640; }
        button.primary { border-color: #4e6fa8; background: #29446e; }
        button.approved { border-color: #507a5c; background: #244b33; }
        button.warn { border-color: #7d6841; background: #4a3b24; }
        select, textarea {
          border: 1px solid var(--stroke);
          background: #15171b;
          color: var(--text);
          border-radius: 6px;
        }
        textarea {
          width: 100%;
          min-height: 54px;
          resize: vertical;
          padding: 8px;
        }
        .app {
          min-height: 100vh;
          display: grid;
          grid-template-rows: auto 1fr auto;
        }
        header {
          position: sticky;
          top: 0;
          z-index: 5;
          background: rgba(17, 18, 20, 0.96);
          border-bottom: 1px solid var(--stroke);
          padding: 12px 16px;
          display: grid;
          grid-template-columns: minmax(280px, 1fr) auto;
          gap: 12px;
          align-items: center;
        }
        h1 {
          font-size: 16px;
          margin: 0 0 5px;
          font-weight: 650;
        }
        .meta, .small {
          color: var(--muted);
          font-size: 11px;
        }
        .toolbar {
          display: flex;
          flex-wrap: wrap;
          justify-content: flex-end;
          gap: 8px;
          align-items: center;
        }
        .toolbar label {
          color: var(--muted);
          display: flex;
          gap: 5px;
          align-items: center;
        }
        .toolbar select { min-height: 32px; padding: 4px 26px 4px 8px; }
        main {
          width: min(1520px, 100%);
          margin: 0 auto;
          padding: 16px;
        }
        .notice {
          border: 1px solid var(--stroke);
          background: #181a1f;
          color: var(--muted);
          padding: 10px 12px;
          border-radius: 8px;
          margin-bottom: 12px;
          display: flex;
          justify-content: space-between;
          gap: 12px;
        }
        .card-head {
          display: grid;
          grid-template-columns: minmax(0, 1fr) auto;
          gap: 12px;
          margin-bottom: 12px;
        }
        .sample-title {
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 13px;
          overflow-wrap: anywhere;
        }
        .chips {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
          margin-top: 7px;
        }
        .chip {
          border: 1px solid var(--stroke);
          background: #202329;
          color: var(--muted);
          border-radius: 6px;
          padding: 3px 7px;
          font-size: 11px;
        }
        .chip.hot { color: #f4d67c; border-color: #6f5c30; background: #322a18; }
        .review-grid {
          display: grid;
          grid-template-columns: minmax(320px, 1fr) minmax(230px, 300px) minmax(320px, 1fr);
          gap: 12px;
        }
        .side, .diff-panel {
          border: 1px solid var(--stroke);
          background: var(--panel);
          border-radius: 8px;
          padding: 12px;
          min-width: 0;
        }
        .side h2, .diff-panel h2 {
          margin: 0 0 10px;
          font-size: 13px;
          font-weight: 650;
        }
        .hexline {
          display: flex;
          justify-content: space-between;
          gap: 10px;
          color: var(--muted);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 11px;
          margin-bottom: 10px;
        }
        .scene-pair {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 10px;
        }
        .scene {
          border: 1px solid rgba(255,255,255,0.08);
          border-radius: 8px;
          padding: 12px;
          min-height: 148px;
          display: flex;
          flex-direction: column;
          gap: 9px;
        }
        .scene.light {
          background: #f4f3ef;
          color: #1c1c1f;
          border-color: rgba(0,0,0,0.12);
        }
        .scene.dark {
          background: #15171b;
          color: #f1f2f4;
        }
        .scene-title { font-weight: 700; color: var(--accent-srgb); }
        .scene-body { font-size: 11px; line-height: 1.35; color: currentColor; opacity: 0.72; }
        .accent-fill {
          background: var(--accent-srgb);
          color: #0c0d10;
          border: 0;
          border-radius: 6px;
          min-height: 30px;
          width: 100%;
          font-weight: 700;
        }
        .selected-row {
          display: flex;
          align-items: center;
          justify-content: space-between;
          border: 1px solid color-mix(in srgb, var(--accent-srgb), transparent 52%);
          border-radius: 6px;
          padding: 6px 7px;
          color: var(--accent-srgb);
          font-weight: 650;
          min-height: 32px;
        }
        .tiny-icon {
          width: 18px;
          height: 18px;
          display: inline-grid;
          place-items: center;
          border: 1px solid currentColor;
          border-radius: 50%;
          font-size: 10px;
        }
        .mini {
          margin-top: 10px;
          display: grid;
          grid-template-columns: 52px minmax(0, 1fr);
          gap: 10px;
          padding: 10px;
          border-radius: 8px;
          border: 1px solid rgba(255,255,255,0.08);
          background: #171a1f;
        }
        .mini.light {
          background: #edeae4;
          color: #15161a;
          border-color: rgba(0,0,0,0.12);
        }
        .cover {
          width: 52px;
          height: 52px;
          border-radius: 6px;
          background:
            linear-gradient(135deg, var(--accent-srgb), transparent 55%),
            linear-gradient(315deg, #090a0d, #3b3f48);
        }
        .mini-title {
          font-weight: 700;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .mini-artist {
          color: currentColor;
          opacity: 0.58;
          font-size: 11px;
          margin-top: 2px;
        }
        .progress {
          height: 4px;
          border-radius: 99px;
          background: rgba(128,128,128,0.28);
          margin: 8px 0;
          overflow: hidden;
        }
        .progress span {
          display: block;
          width: 58%;
          height: 100%;
          background: var(--accent-srgb);
        }
        .controls {
          display: flex;
          align-items: center;
          gap: 10px;
          color: var(--accent-srgb);
          font-size: 13px;
        }
        .play {
          width: 26px;
          height: 26px;
          border-radius: 50%;
          display: inline-grid;
          place-items: center;
          background: var(--accent-srgb);
          color: #0d0e12;
          font-weight: 800;
        }
        @supports (color: color(display-p3 1 0 0)) {
          .scene-title, .selected-row, .controls { color: var(--accent-p3); }
          .accent-fill, .progress span, .play { background: var(--accent-p3); }
          .cover {
            background:
              linear-gradient(135deg, var(--accent-p3), transparent 55%),
              linear-gradient(315deg, #090a0d, #3b3f48);
          }
        }
        .strips {
          margin-top: 10px;
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 8px;
        }
        .strip {
          min-height: 34px;
          border-radius: 6px;
          border: 1px solid rgba(255,255,255,0.10);
          padding: 6px;
          display: flex;
          align-items: flex-end;
          color: rgba(255,255,255,0.9);
          font-size: 10px;
          text-shadow: 0 1px 2px rgba(0,0,0,0.55);
        }
        .strip.p3 { background: var(--accent-srgb); }
        .strip.srgb { background: var(--accent-srgb); }
        @supports (color: color(display-p3 1 0 0)) {
          .strip.p3 { background: var(--accent-p3); }
        }
        .diff-row {
          margin: 10px 0 12px;
        }
        .diff-label {
          display: flex;
          justify-content: space-between;
          color: var(--muted);
          font-size: 11px;
          margin-bottom: 4px;
        }
        .bar {
          height: 8px;
          border-radius: 99px;
          background: #111318;
          overflow: hidden;
          border: 1px solid rgba(255,255,255,0.06);
        }
        .bar span {
          display: block;
          height: 100%;
          width: 0%;
          background: linear-gradient(90deg, #7798df, #dbbd67);
        }
        .ok-table {
          width: 100%;
          border-collapse: collapse;
          margin-top: 12px;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 11px;
          color: var(--muted);
        }
        .ok-table td {
          padding: 4px 0;
          border-top: 1px solid rgba(255,255,255,0.06);
        }
        .decision-area {
          border-top: 1px solid var(--stroke);
          background: #15171b;
          padding: 12px 16px;
        }
        .decision-inner {
          max-width: 1520px;
          margin: 0 auto;
          display: grid;
          grid-template-columns: minmax(380px, 1fr) minmax(260px, 420px);
          gap: 12px;
          align-items: start;
        }
        .decision-buttons {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
        }
        .decision-buttons button.active {
          outline: 2px solid var(--focus);
          outline-offset: 1px;
        }
        .approved-toggle {
          display: inline-flex;
          align-items: center;
          gap: 7px;
          margin-left: 2px;
          color: var(--muted);
          min-height: 34px;
        }
        .approved-toggle input { width: 16px; height: 16px; }
        .empty {
          border: 1px solid var(--stroke);
          background: var(--panel);
          border-radius: 8px;
          padding: 24px;
          color: var(--muted);
        }
        @media (max-width: 980px) {
          header, .card-head, .review-grid, .decision-inner {
            grid-template-columns: 1fr;
          }
          .toolbar { justify-content: flex-start; }
          .scene-pair { grid-template-columns: 1fr; }
        }
        </style>
        </head>
        <body>
        <div class="app">
          <header>
            <div>
              <h1>Accent Parity Review</h1>
              <div class="meta">
                <span id="progressText"></span>
                <span> · </span>
                <span id="doneText"></span>
                <span> · </span>
                <span id="p3Status"></span>
              </div>
            </div>
            <div class="toolbar">
              <label>surface <select id="surfaceFilter"></select></label>
              <label>family <select id="familyFilter"></select></label>
              <label>risk <select id="riskFilter"></select></label>
              <button id="jumpUnresolved">Jump unresolved</button>
              <button id="importButton">Import JSON</button>
              <button id="exportButton" class="primary">Export session</button>
              <input id="importInput" type="file" accept="application/json,.json" hidden>
            </div>
          </header>
          <main>
            <div class="notice">
              <span>This queue is representative, not exhaustive. Full report remains available separately.</span>
              <span id="queueText"></span>
            </div>
            <section id="reviewCard"></section>
          </main>
          <footer class="decision-area">
            <div class="decision-inner">
              <div>
                <div class="decision-buttons">
                  <button data-decision="legacy_better">1 Legacy better</button>
                  <button data-decision="candidate_better" class="primary">2 Candidate better</button>
                  <button data-decision="both_acceptable">3 Both acceptable</button>
                  <button data-decision="needs_tuning" class="warn">4 Needs tuning</button>
                  <button data-decision="skip_undecided">5 Skip / undecided</button>
                  <label class="approved-toggle"><input id="approvedDelta" type="checkbox"> Mark as approved delta</label>
                  <button id="backButton">Back</button>
                  <button id="undoButton">Undo last decision</button>
                </div>
                <div class="small" style="margin-top:7px">Shortcuts: 1-5 decide, A toggles approved delta, Left/Right navigates.</div>
              </div>
              <div>
                <textarea id="noteBox" placeholder="Optional note, for example: light mode too gray"></textarea>
              </div>
            </div>
          </footer>
        </div>
        <script id="review-data" type="application/json">\(data)</script>
        <script>
        const reviewData = JSON.parse(document.getElementById('review-data').textContent);
        const items = reviewData.items;
        const storageKey = `accent-review-session:v${reviewData.format_version}:${reviewData.source_report}`;
        const p3Supported = CSS.supports('color', 'color(display-p3 1 0 0)');
        let decisions = loadStoredDecisions();
        let historyStack = [];
        let currentIndex = 0;
        const filters = { surface: 'all', family: 'all', risk: 'all' };

        const el = {
          card: document.getElementById('reviewCard'),
          progress: document.getElementById('progressText'),
          done: document.getElementById('doneText'),
          p3: document.getElementById('p3Status'),
          queue: document.getElementById('queueText'),
          surface: document.getElementById('surfaceFilter'),
          family: document.getElementById('familyFilter'),
          risk: document.getElementById('riskFilter'),
          note: document.getElementById('noteBox'),
          approved: document.getElementById('approvedDelta'),
          importInput: document.getElementById('importInput')
        };

        hydrateFilters();
        render();

        document.querySelectorAll('[data-decision]').forEach(button => {
          button.addEventListener('click', () => choose(button.dataset.decision));
        });
        document.getElementById('backButton').addEventListener('click', previous);
        document.getElementById('undoButton').addEventListener('click', undo);
        document.getElementById('jumpUnresolved').addEventListener('click', jumpUnresolved);
        document.getElementById('exportButton').addEventListener('click', exportSession);
        document.getElementById('importButton').addEventListener('click', () => el.importInput.click());
        el.importInput.addEventListener('change', importSession);
        el.note.addEventListener('input', updateCurrentNote);
        el.approved.addEventListener('change', updateApproved);
        for (const select of [el.surface, el.family, el.risk]) {
          select.addEventListener('change', () => {
            filters.surface = el.surface.value;
            filters.family = el.family.value;
            filters.risk = el.risk.value;
            currentIndex = 0;
            render();
          });
        }
        document.addEventListener('keydown', event => {
          if (event.target && ['TEXTAREA', 'INPUT', 'SELECT'].includes(event.target.tagName)) return;
          if (event.key >= '1' && event.key <= '5') {
            choose(['legacy_better', 'candidate_better', 'both_acceptable', 'needs_tuning', 'skip_undecided'][Number(event.key) - 1]);
          } else if (event.key === 'ArrowLeft') {
            previous();
          } else if (event.key === 'ArrowRight') {
            next();
          } else if (event.key.toLowerCase() === 'a') {
            toggleApproved();
          }
        });

        function visibleItems() {
          return items.filter(item => {
            if (filters.surface !== 'all' && item.surface !== filters.surface) return false;
            if (filters.family !== 'all' && item.color_family !== filters.family) return false;
            if (filters.risk !== 'all' && !item.risk_tags.includes(filters.risk)) return false;
            return true;
          });
        }

        function hydrateFilters() {
          fillSelect(el.surface, ['all', ...unique(items.map(item => item.surface))]);
          fillSelect(el.family, ['all', ...unique(items.map(item => item.color_family))]);
          fillSelect(el.risk, ['all', ...unique(items.flatMap(item => item.risk_tags))]);
        }

        function fillSelect(select, values) {
          select.innerHTML = values.map(value => `<option value="${escapeAttr(value)}">${escapeHTML(value)}</option>`).join('');
        }

        function render() {
          const visible = visibleItems();
          if (currentIndex >= visible.length) currentIndex = Math.max(0, visible.length - 1);
          const item = visible[currentIndex];
          const doneCount = Object.keys(decisions).length;
          el.p3.textContent = p3Supported ? 'Display P3 CSS supported' : 'Display P3 CSS unsupported, swatches show sRGB fallback';
          el.queue.textContent = `${reviewData.queue_count} item queue from ${reviewData.full_review_required} review-required rows`;
          el.done.textContent = `${doneCount} saved decisions`;
          if (!item) {
            el.progress.textContent = 'No matching items';
            el.card.innerHTML = '<div class="empty">No items match the current filters.</div>';
            return;
          }
          el.progress.textContent = `${currentIndex + 1} / ${visible.length}`;
          const decision = decisions[item.id] || {};
          el.note.value = decision.note || '';
          el.approved.checked = !!decision.approved_delta;
          el.approved.disabled = decision.decision !== 'candidate_better';
          renderDecisionButtons(decision.decision);
          el.card.innerHTML = cardHTML(item, currentIndex + 1, visible.length);
        }

        function cardHTML(item, position, total) {
          const tags = [
            item.color_family,
            item.surface,
            item.scheme,
            item.classification,
            ...item.risk_tags,
            ...item.queue_reasons
          ];
          return `
            <div class="card-head">
              <div>
                <div class="sample-title">${escapeHTML(item.sample)}</div>
                <div class="chips">${tags.map(tag => `<span class="chip ${tag.includes('risk') || tag.includes('high-chroma') || tag.includes('UltraDark') ? 'hot' : ''}">${escapeHTML(tag)}</span>`).join('')}</div>
              </div>
              <div class="meta">Current category: ${escapeHTML(item.color_family)} · ${escapeHTML(item.surface)}<br>${position} / ${total}</div>
            </div>
            <div class="review-grid">
              ${sideHTML('Legacy HSL', item.legacy, item)}
              ${diffHTML(item)}
              ${sideHTML('Candidate OKLCH', item.candidate, item)}
            </div>
          `;
        }

        function sideHTML(title, color, item) {
          const style = `--accent-srgb:${color.srgb_css};--accent-p3:${color.display_p3_css};`;
          return `
            <section class="side" style="${escapeAttr(style)}">
              <h2>${escapeHTML(title)}</h2>
              <div class="hexline"><span>${escapeHTML(color.hex)}</span><span>${oklchText(color.oklch)}</span></div>
              <div class="scene-pair">
                ${accentSceneHTML('light')}
                ${accentSceneHTML('dark')}
              </div>
              ${miniPlayerHTML(item.scheme === 'light' ? 'light' : 'dark')}
              <div class="strips">
                <div class="strip p3">Display P3</div>
                <div class="strip srgb">sRGB fallback</div>
              </div>
            </section>
          `;
        }

        function accentSceneHTML(mode) {
          return `
            <div class="scene ${mode}">
              <div class="scene-title">Selected Accent</div>
              <div class="scene-body">Title, body copy, button and selected state share this accent.</div>
              <button class="accent-fill">Accent action</button>
              <div class="selected-row"><span>Selected state</span><span class="tiny-icon">i</span></div>
            </div>
          `;
        }

        function miniPlayerHTML(mode) {
          return `
            <div class="mini ${mode}">
              <div class="cover"></div>
              <div>
                <div class="mini-title">MiniPlayer control tone</div>
                <div class="mini-artist">Review mock</div>
                <div class="progress"><span></span></div>
                <div class="controls"><span>prev</span><span class="play">play</span><span>next</span><span style="margin-left:auto">love</span><span>more</span></div>
              </div>
            </div>
          `;
        }

        function diffHTML(item) {
          const d = item.diff;
          return `
            <section class="diff-panel">
              <h2>Difference</h2>
              ${barHTML('OKLCH L', d.delta_l, d.signed_delta_l, 0.18)}
              ${barHTML('OKLCH C', d.delta_c, d.signed_delta_c, 0.09)}
              ${barHTML('Hue', d.delta_h, d.signed_delta_h, 0.12)}
              ${barHTML('ΔE OKLab', d.delta_e_oklab, d.delta_e_oklab, 0.16)}
              <table class="ok-table">
                <tr><td>surface</td><td>${escapeHTML(item.surface)}</td></tr>
                <tr><td>role</td><td>${escapeHTML(item.role)}</td></tr>
                <tr><td>reason</td><td>${escapeHTML(item.reason)}</td></tr>
                <tr><td>gamut</td><td>${escapeHTML(item.target_gamut)}</td></tr>
              </table>
            </section>
          `;
        }

        function barHTML(label, value, signed, scale) {
          const pct = Math.max(2, Math.min(100, Math.abs(value) / scale * 100));
          const sign = signed > 0 ? '+' : '';
          return `
            <div class="diff-row">
              <div class="diff-label"><span>${label}</span><span>${sign}${format(signed)} / abs ${format(value)}</span></div>
              <div class="bar"><span style="width:${pct}%"></span></div>
            </div>
          `;
        }

        function choose(decision) {
          const item = visibleItems()[currentIndex];
          if (!item) return;
          const previousDecision = decisions[item.id] ? {...decisions[item.id]} : null;
          const approved = decision === 'candidate_better' && el.approved.checked;
          historyStack.push({ id: item.id, previousDecision, previousIndex: currentIndex });
          decisions[item.id] = {
            id: item.id,
            sample: item.sample,
            surface: item.surface,
            role: item.role,
            scheme: item.scheme,
            decision,
            approved_delta: approved,
            note: el.note.value.trim()
          };
          save();
          next();
        }

        function updateCurrentNote() {
          const item = visibleItems()[currentIndex];
          if (!item || !decisions[item.id]) return;
          decisions[item.id].note = el.note.value.trim();
          save(false);
        }

        function updateApproved() {
          const item = visibleItems()[currentIndex];
          if (!item) return;
          if (!decisions[item.id] || decisions[item.id].decision !== 'candidate_better') {
            el.approved.checked = false;
            return;
          }
          decisions[item.id].approved_delta = el.approved.checked;
          save(false);
          render();
        }

        function toggleApproved() {
          const item = visibleItems()[currentIndex];
          if (!item) return;
          if (!decisions[item.id] || decisions[item.id].decision !== 'candidate_better') {
            decisions[item.id] = {
              id: item.id,
              sample: item.sample,
              surface: item.surface,
              role: item.role,
              scheme: item.scheme,
              decision: 'candidate_better',
              approved_delta: true,
              note: el.note.value.trim()
            };
          } else {
            decisions[item.id].approved_delta = !decisions[item.id].approved_delta;
          }
          save();
          render();
        }

        function previous() {
          if (currentIndex > 0) currentIndex -= 1;
          render();
        }

        function next() {
          const visible = visibleItems();
          currentIndex = Math.min(currentIndex + 1, Math.max(visible.length - 1, 0));
          render();
        }

        function undo() {
          const last = historyStack.pop();
          if (!last) return;
          if (last.previousDecision) decisions[last.id] = last.previousDecision;
          else delete decisions[last.id];
          currentIndex = last.previousIndex;
          save();
          render();
        }

        function jumpUnresolved() {
          const visible = visibleItems();
          const index = visible.findIndex(item => !decisions[item.id]);
          if (index >= 0) currentIndex = index;
          render();
        }

        function renderDecisionButtons(active) {
          document.querySelectorAll('[data-decision]').forEach(button => {
            button.classList.toggle('active', button.dataset.decision === active);
          });
        }

        function sessionPayload() {
          return {
            format_version: 1,
            generated_at: new Date().toISOString(),
            source_report: reviewData.source_report,
            queue_name: reviewData.queue_name,
            queue_items: items.map(item => ({
              id: item.id,
              sample: item.sample,
              surface: item.surface,
              role: item.role,
              scheme: item.scheme,
              color_family: item.color_family,
              risk_tags: item.risk_tags
            })),
            decisions: Object.values(decisions)
          };
        }

        function exportSession() {
          const blob = new Blob([JSON.stringify(sessionPayload(), null, 2)], { type: 'application/json' });
          const url = URL.createObjectURL(blob);
          const anchor = document.createElement('a');
          anchor.href = url;
          anchor.download = 'accent-review-session.json';
          anchor.click();
          URL.revokeObjectURL(url);
        }

        function importSession(event) {
          const file = event.target.files && event.target.files[0];
          if (!file) return;
          file.text().then(text => {
            const session = JSON.parse(text);
            if (!Array.isArray(session.decisions)) throw new Error('missing decisions');
            for (const decision of session.decisions) {
              if (decision && decision.id) decisions[decision.id] = decision;
            }
            save();
            render();
          }).catch(error => {
            alert(`Could not import review session: ${error.message}`);
          }).finally(() => {
            event.target.value = '';
          });
        }

        function loadStoredDecisions() {
          try {
            const text = localStorage.getItem(storageKey);
            return text ? JSON.parse(text) : {};
          } catch {
            return {};
          }
        }

        function save(rerender = true) {
          localStorage.setItem(storageKey, JSON.stringify(decisions));
          if (rerender) render();
        }

        function unique(values) {
          return Array.from(new Set(values)).filter(Boolean).sort();
        }

        function format(value) {
          return Number(value || 0).toFixed(4);
        }

        function oklchText(oklch) {
          if (!oklch) return 'oklch=nil';
          return `L ${format(oklch.l)} C ${format(oklch.c)} H ${format(oklch.h)}`;
        }

        function escapeHTML(value) {
          return String(value).replace(/[&<>"']/g, char => ({
            '&': '&amp;',
            '<': '&lt;',
            '>': '&gt;',
            '"': '&quot;',
            "'": '&#39;'
          }[char]));
        }

        function escapeAttr(value) {
          return escapeHTML(value);
        }
        </script>
        </body>
        </html>
        """
    }

    private static func jsonForHTML<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "</", with: "<\\/")
            ?? "{}"
    }

    private static func markdownList(title: String, decisions: [AccentReviewDecision]) -> String {
        var lines = ["# \(title)", ""]
        if decisions.isEmpty {
            lines.append("_None._")
        } else {
            for decision in decisions {
                var line = "- `\(decision.sample)` \(decision.surface)/\(decision.role)/\(decision.scheme)"
                if let note = decision.note, !note.isEmpty {
                    line += " — \(note)"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isoTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

struct AccentReviewSelection {
    let row: AccentParityRow
    var queueReasons: [String]
}

struct ReviewPagePayload: Encodable {
    let formatVersion: Int
    let generatedAt: String
    let queueName: String
    let sourceReport: String
    let fullReportTotal: Int
    let fullReviewRequired: Int
    let fullBlocker: Int
    let fullAcceptableDrift: Int
    let fullApprovedDelta: Int
    let queueCount: Int
    let summaryLine: String
    let items: [AccentReviewItem]
}

struct AccentReviewItem: Encodable {
    let id: String
    let sample: String
    let sectionID: String
    let surface: String
    let role: String
    let scheme: String
    let colorFamily: String
    let colorCategory: String
    let riskTags: [String]
    let queueReasons: [String]
    let classification: String
    let reason: String
    let targetGamut: String
    let legacy: AccentReviewColor
    let candidate: AccentReviewColor
    let diff: AccentReviewDiff
}

struct AccentReviewColor: Encodable {
    let hex: String
    let oklch: AccentReviewOKLCH?
    let displayP3CSS: String
    let sRGBCSS: String
    let displayP3: AccentReviewResolvedColor?
    let sRGB: AccentReviewResolvedColor?

    enum CodingKeys: String, CodingKey {
        case hex, oklch
        case displayP3CSS = "display_p3_css"
        case sRGBCSS = "srgb_css"
        case displayP3 = "display_p3"
        case sRGB = "srgb"
    }
}

struct AccentReviewOKLCH: Encodable {
    let l: Double
    let c: Double
    let h: Double
}

struct AccentReviewResolvedColor: Encodable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    let target: String
    let isLinear: Bool
    let requestedChroma: Double
    let resolvedChroma: Double
    let wasGamutMapped: Bool

    init(_ color: ResolvedRGBColor) {
        red = color.red
        green = color.green
        blue = color.blue
        alpha = color.alpha
        target = color.target.rawValue
        isLinear = color.isLinear
        requestedChroma = color.requestedChroma
        resolvedChroma = color.resolvedChroma
        wasGamutMapped = color.wasGamutMapped
    }
}

struct AccentReviewDiff: Encodable {
    let deltaL: Double
    let deltaC: Double
    let deltaH: Double
    let deltaEOKLab: Double
    let signedDeltaL: Double
    let signedDeltaC: Double
    let signedDeltaH: Double

    enum CodingKeys: String, CodingKey {
        case deltaL = "delta_l"
        case deltaC = "delta_c"
        case deltaH = "delta_h"
        case deltaEOKLab = "delta_e_oklab"
        case signedDeltaL = "signed_delta_l"
        case signedDeltaC = "signed_delta_c"
        case signedDeltaH = "signed_delta_h"
    }
}

struct AccentReviewSession: Decodable {
    let formatVersion: Int
    let generatedAt: String?
    let sourceReport: String
    let queueName: String?
    let queueItems: [AccentReviewQueueItem]?
    let decisions: [AccentReviewDecision]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case generatedAt = "generated_at"
        case sourceReport = "source_report"
        case queueName = "queue_name"
        case queueItems = "queue_items"
        case decisions
    }
}

struct AccentReviewQueueItem: Decodable {
    let id: String
    let sample: String
    let surface: String
    let role: String
    let scheme: String
    let colorFamily: String?
    let riskTags: [String]?

    enum CodingKeys: String, CodingKey {
        case id, sample, surface, role, scheme
        case colorFamily = "color_family"
        case riskTags = "risk_tags"
    }
}

struct AccentReviewDecision: Decodable {
    let id: String
    let sample: String
    let surface: String
    let role: String
    let scheme: String
    let decision: String
    let approvedDelta: Bool
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id, sample, surface, role, scheme, decision, note
        case approvedDelta = "approved_delta"
    }

    init(queueItem: AccentReviewQueueItem, decision: String) {
        id = queueItem.id
        sample = queueItem.sample
        surface = queueItem.surface
        role = queueItem.role
        scheme = queueItem.scheme
        self.decision = decision
        approvedDelta = false
        note = nil
    }
}

struct ApprovedAccentDeltaCandidate: Encodable {
    struct Entry: Encodable {
        let sample: String
        let surface: String
        let role: String
        let scheme: String
        let reason: String
    }

    let version: Int
    let sourceReviewSession: String
    let generatedAt: String
    let deltas: [Entry]
}

struct AccentReviewExportResult {
    let outputDirectory: String
    let approvedURL: String
    let needsTuningURL: String
    let legacyBetterURL: String
    let undecidedURL: String
    let summaryURL: String
    let approvedCount: Int
    let needsTuningCount: Int
    let legacyBetterCount: Int
    let undecidedCount: Int
    let decisionCount: Int
}
