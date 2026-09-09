//
//  NativeLyricsTTMLAdapter.swift
//  myPlayer2
//
//  Compatibility boundary between the player's stored Apple lyric TTML and
//  the strict NativeLyrics decoder.
//
//  Older AMLL imports in the player repeat absolute clock values on every
//  timed descendant (`div`, `p`, and `span`). NativeLyrics intentionally
//  follows TTML and resolves child clocks relative to their parent. The
//  conversion must happen at the app boundary so the renderer can stay strict
//  and the same repair is applied to every native lyrics surface.
//

import Foundation

nonisolated enum NativeLyricsTTMLAdapter {
    private static let ttNamespace = "http://www.w3.org/ns/ttml"
    private static let timedNames: Set<String> = ["body", "div", "p", "span", "br"]

    /// Returns TTML suitable for `NativeLyrics.LyricsView.load`.
    ///
    /// Standard parent-relative TTML is returned byte-for-byte (apart from
    /// outer whitespace). Legacy absolute timing and unnamespaced timed
    /// content are normalized through Foundation's XML tree. Invalid input is
    /// intentionally returned unchanged so the renderer's normal load error
    /// remains the single failure boundary and preserves the last valid view.
    static func normalizeForNative(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard let document = try? XMLDocument(
            data: Data(trimmed.utf8),
            options: [.nodePreserveAll]
        ), let root = document.rootElement(), root.localName == "tt" else {
            return trimmed
        }

        let body = descendants(of: root).first { $0.localName == "body" }
        let absolute = body.map(looksLikeAbsoluteTiming) ?? false
        let namespaceRepair = needsNamespaceRepair(root)

        // Do not serialize ordinary TTML. Besides avoiding unnecessary work,
        // this preserves the exact text used by the app's track identity and
        // avoids changing whitespace in strict files.
        guard absolute || namespaceRepair else { return trimmed }

        if namespaceRepair { repairStructuralNamespaces(root) }
        if absolute, let body {
            // The detector only classifies finite clocks. If a malformed
            // value is encountered, leave the original payload for LyricsView
            // to reject rather than manufacturing a partial document.
            guard normalizeAbsoluteTimes(body, origin: 0) else { return trimmed }
        }

        return String(
            decoding: document.xmlData(options: [.nodeCompactEmptyElement]),
            as: UTF8.self
        )
    }

    private static func descendants(of element: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            result.append(child)
            result.append(contentsOf: descendants(of: child))
        }
        return result
    }

    private static func children(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func timed(_ element: XMLElement) -> Bool {
        timedNames.contains(element.localName ?? element.name ?? "")
    }

    private static func attribute(_ name: String, from element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private static func looksLikeAbsoluteTiming(_ body: XMLElement) -> Bool {
        var equalFirstChildren = 0
        var comparisons = 0
        var zeroFirstChildren = 0
        var nonZeroEqualFirstChildren = 0

        func visit(_ parent: XMLElement) {
            let parentBegin = attribute("begin", from: parent).flatMap(parseTime)
            let timedChildren = children(of: parent).filter {
                timed($0) && attribute("begin", from: $0) != nil
            }
            if let parentBegin,
               let childBegin = timedChildren.first.flatMap({
                   attribute("begin", from: $0).flatMap(parseTime)
               }) {
                comparisons += 1
                if abs(childBegin - parentBegin) < 0.02 { equalFirstChildren += 1 }
                if childBegin < 0.02 { zeroFirstChildren += 1 }
                // A standard parent-relative TTML line commonly has
                // `p begin="0s"` and its first child span at `0s`. That is
                // an equality too, but it is not evidence that the clocks are
                // absolute. Repeated non-zero equalities (the signature of
                // LDDC's div -> p -> span export) are the useful discriminator.
                if parentBegin >= 0.02,
                   childBegin >= 0.02,
                   abs(childBegin - parentBegin) < 0.02
                {
                    nonZeroEqualFirstChildren += 1
                }
            }
            for child in children(of: parent) {
                visit(child)
            }
        }

        visit(body)
        guard comparisons >= 2 else { return false }

        // A legacy export repeats the absolute start on the div -> p -> span
        // chain. Standard parent-relative TTML commonly starts each line's
        // first span at zero, so zero equality alone must never trigger a
        // rewrite. Require either more equalities than zero-start edges or at
        // least two repeated non-zero edges from the absolute export.
        return equalFirstChildren >= 2
            && equalFirstChildren * 2 >= comparisons
            && (equalFirstChildren > zeroFirstChildren || nonZeroEqualFirstChildren >= 2)
    }

    private static func needsNamespaceRepair(_ root: XMLElement) -> Bool {
        guard root.uri != ttNamespace else {
            return descendants(of: root).contains {
                timedNames.contains($0.localName ?? $0.name ?? "")
                    && $0.uri != ttNamespace
            }
        }
        return true
    }

    private static func repairStructuralNamespaces(_ root: XMLElement) {
        // XMLDocument serializes a default namespace onto all unprefixed
        // descendants. Removing explicit empty declarations on timed nodes is
        // required for older exports that shadow the root namespace with
        // `xmlns=""`.
        if root.uri != ttNamespace {
            if let prefix = root.prefix, !prefix.isEmpty {
                root.removeNamespace(forPrefix: prefix)
            }
            root.name = root.localName ?? root.name ?? "tt"
        }
        root.removeNamespace(forPrefix: "")
        root.addNamespace(
            XMLNode.namespace(withName: "", stringValue: ttNamespace) as! XMLNode
        )
        for element in descendants(of: root)
            where timedNames.contains(element.localName ?? element.name ?? "") {
            if element.uri != ttNamespace {
                if let prefix = element.prefix, !prefix.isEmpty {
                    element.removeNamespace(forPrefix: prefix)
                }
                element.removeNamespace(forPrefix: "")
                element.name = element.localName ?? element.name
            }
        }
    }

    /// Converts absolute descendant clocks into parent-relative TTML clocks.
    /// `origin` is the absolute start of the current parent.
    @discardableResult
    private static func normalizeAbsoluteTimes(
        _ element: XMLElement,
        origin: Double
    ) -> Bool {
        let absoluteStart = attribute("begin", from: element).flatMap(parseTime) ?? origin
        guard absoluteStart.isFinite, absoluteStart >= 0 else { return false }

        if attribute("begin", from: element) != nil {
            setTime(max(0, absoluteStart - origin), attribute: "begin", on: element)
        }
        if let end = attribute("end", from: element) {
            guard let absoluteEnd = parseTime(end), absoluteEnd.isFinite, absoluteEnd >= 0 else {
                return false
            }
            setTime(max(0, absoluteEnd - origin), attribute: "end", on: element)
        }
        if let dur = attribute("dur", from: element) {
            guard let duration = parseTime(dur), duration.isFinite, duration >= 0 else {
                return false
            }
            setTime(duration, attribute: "dur", on: element)
        }

        for child in children(of: element) where timed(child) {
            guard normalizeAbsoluteTimes(child, origin: absoluteStart) else { return false }
        }
        return true
    }

    private static func setTime(_ value: Double, attribute: String, on element: XMLElement) {
        let text = String(format: "%.6fs", locale: Locale(identifier: "en_US_POSIX"), value)
        if let existing = element.attribute(forName: attribute) {
            existing.stringValue = text
        } else {
            element.addAttribute(
                XMLNode.attribute(withName: attribute, stringValue: text) as! XMLNode
            )
        }
    }

    private static func parseTime(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes: [(String, Double)] = [
            ("ms", 0.001),
            ("h", 3600),
            ("m", 60),
            ("s", 1)
        ]
        for (suffix, factor) in suffixes where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count)),
                  number.isFinite,
                  number >= 0 else { return nil }
            return number * factor
        }
        // Some earlier Apple exports wrote bare decimal seconds. Normalize
        // those too before the strict native parser sees them.
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 2:
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]),
                  minutes >= 0,
                  seconds >= 0,
                  seconds < 60 else { return nil }
            return minutes * 60 + seconds
        case 3:
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]),
                  hours >= 0,
                  minutes >= 0,
                  minutes < 60,
                  seconds >= 0,
                  seconds < 60 else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        default:
            return nil
        }
    }
}
