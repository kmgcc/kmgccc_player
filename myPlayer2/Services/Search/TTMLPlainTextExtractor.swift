//
//  TTMLPlainTextExtractor.swift
//  myPlayer2
//
//  Extracts user-visible lyric text from TTML without indexing XML tags,
//  timestamps, or attributes.
//

import Foundation

nonisolated struct LyricPlainTextExtraction: Sendable {
    let plainText: String
    let lineStartTimes: [Double?]
}

nonisolated enum TTMLPlainTextExtractor {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var warnedDescriptions = Set<String>()

    static func extractPlainText(from ttml: String, sourceDescription: String? = nil) -> String {
        extractTimedPlainText(from: ttml, sourceDescription: sourceDescription).plainText
    }

    static func extractTimedPlainText(from ttml: String, sourceDescription: String? = nil) -> LyricPlainTextExtraction {
        let parser = TTMLXMLTextParser()
        if let extracted = parser.parse(ttml), !extracted.plainText.isEmpty {
            return extracted
        }

        if let sourceDescription {
            let alreadyWarned: Bool
            lock.lock()
            alreadyWarned = warnedDescriptions.contains(sourceDescription)
            if !alreadyWarned {
                warnedDescriptions.insert(sourceDescription)
            }
            lock.unlock()

            if !alreadyWarned {
                Log.warning(
                    "[SearchIndex] TTML parse failed; falling back to tag-stripped lyrics: \(sourceDescription)",
                    category: .library
                )
            }
        }
        return LyricPlainTextExtraction(
            plainText: fallbackStripTags(ttml),
            lineStartTimes: []
        )
    }

    static func extractTimedPlainLyrics(from lyrics: String) -> LyricPlainTextExtraction {
        let lrcLines = extractLRCPlainLyrics(from: lyrics)
        if !lrcLines.plainText.isEmpty {
            return lrcLines
        }
        return LyricPlainTextExtraction(
            plainText: normalizeExtractedText(lyrics),
            lineStartTimes: []
        )
    }

    private static func fallbackStripTags(_ value: String) -> String {
        let withoutTags = value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        return normalizeExtractedText(decodeBasicXMLEntities(withoutTags))
    }

    static func normalizeExtractedText(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .map(normalizeLine)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    fileprivate static func normalizeLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func parseTimeExpression(_ rawValue: String) -> Double? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if value.hasSuffix("ms"),
           let milliseconds = Double(value.dropLast(2)) {
            return max(0, milliseconds / 1000.0)
        }
        if value.hasSuffix("s"),
           let seconds = Double(value.dropLast()) {
            return max(0, seconds)
        }

        let parts = value.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }

        var total = 0.0
        for part in parts {
            guard let component = Double(part) else { return nil }
            total = total * 60 + component
        }
        return max(0, total)
    }

    private static func extractLRCPlainLyrics(from lyrics: String) -> LyricPlainTextExtraction {
        var lines: [(text: String, startTime: Double?)] = []
        var sawTimedLine = false

        for rawLine in lyrics.components(separatedBy: .newlines) {
            var remaining = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            var times: [Double] = []

            while remaining.hasPrefix("["),
                  let closeIndex = remaining.firstIndex(of: "]") {
                let tag = String(remaining[remaining.index(after: remaining.startIndex)..<closeIndex])
                guard let time = parseTimeExpression(tag) else { break }
                times.append(time)
                remaining = String(remaining[remaining.index(after: closeIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let normalized = normalizeLine(remaining)
            guard !normalized.isEmpty else { continue }

            if times.isEmpty {
                lines.append((normalized, nil))
            } else {
                sawTimedLine = true
                for time in times {
                    lines.append((normalized, time))
                }
            }
        }

        guard sawTimedLine else {
            return LyricPlainTextExtraction(plainText: "", lineStartTimes: [])
        }

        lines.sort {
            switch ($0.startTime, $1.startTime) {
            case let (lhs?, rhs?):
                return lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }

        return LyricPlainTextExtraction(
            plainText: lines.map { $0.text }.joined(separator: "\n"),
            lineStartTimes: lines.map { $0.startTime }
        )
    }

    private static func decodeBasicXMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private nonisolated final class TTMLXMLTextParser: NSObject, XMLParserDelegate {
    private var isInsideBody = false
    private var paragraphDepth = 0
    private var currentLine = ""
    private var currentLineStartTime: Double?
    private var bodyFallback = ""
    private var lines: [(text: String, startTime: Double?)] = []
    private var didFail = false

    func parse(_ ttml: String) -> LyricPlainTextExtraction? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), !didFail else { return nil }

        if !lines.isEmpty {
            return LyricPlainTextExtraction(
                plainText: lines.map { $0.text }.joined(separator: "\n"),
                lineStartTimes: lines.map { $0.startTime }
            )
        }

        let fallback = TTMLPlainTextExtractor.normalizeExtractedText(bodyFallback)
        return fallback.isEmpty
            ? nil
            : LyricPlainTextExtraction(plainText: fallback, lineStartTimes: [])
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        switch name {
        case "body":
            isInsideBody = true
        case "p":
            guard isInsideBody else { return }
            if paragraphDepth == 0 {
                currentLine = ""
                currentLineStartTime = Self.startTime(from: attributeDict)
            }
            paragraphDepth += 1
        case "br":
            guard isInsideBody, paragraphDepth > 0 else { return }
            currentLine.append("\n")
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        switch name {
        case "body":
            isInsideBody = false
        case "p":
            guard paragraphDepth > 0 else { return }
            paragraphDepth -= 1
            guard paragraphDepth == 0 else { return }
            appendFinalizedCurrentLine()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideBody else { return }
        bodyFallback.append(string)
        if paragraphDepth > 0 {
            currentLine.append(string)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        didFail = true
    }

    private func appendFinalizedCurrentLine() {
        let splitLines = currentLine
            .components(separatedBy: .newlines)
            .map(TTMLPlainTextExtractor.normalizeLine)
            .filter { !$0.isEmpty }
        lines.append(contentsOf: splitLines.map { ($0, currentLineStartTime) })
        currentLine = ""
        currentLineStartTime = nil
    }

    private func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }

    private static func startTime(from attributes: [String: String]) -> Double? {
        for key in ["begin", "time", "start"] {
            if let value = attributes[key],
               let seconds = TTMLPlainTextExtractor.parseTimeExpression(value) {
                return seconds
            }
        }
        if let namespaced = attributes.first(where: { localName($0.key) == "begin" })?.value {
            return TTMLPlainTextExtractor.parseTimeExpression(namespaced)
        }
        return nil
    }

    private static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }
}
