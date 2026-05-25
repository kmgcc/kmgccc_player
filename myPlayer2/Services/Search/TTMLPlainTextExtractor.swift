//
//  TTMLPlainTextExtractor.swift
//  myPlayer2
//
//  Extracts user-visible lyric text from TTML without indexing XML tags,
//  timestamps, or attributes.
//

import Foundation

nonisolated enum TTMLPlainTextExtractor {
    static func extractPlainText(from ttml: String, sourceDescription: String? = nil) -> String {
        let parser = TTMLXMLTextParser()
        if let extracted = parser.parse(ttml), !extracted.isEmpty {
            return extracted
        }

        if let sourceDescription {
            Log.warning(
                "[SearchIndex] TTML parse failed; falling back to tag-stripped lyrics: \(sourceDescription)",
                category: .library
            )
        }
        return fallbackStripTags(ttml)
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
    private var bodyFallback = ""
    private var lines: [String] = []
    private var didFail = false

    func parse(_ ttml: String) -> String? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), !didFail else { return nil }

        if !lines.isEmpty {
            return lines.joined(separator: "\n")
        }

        let fallback = TTMLPlainTextExtractor.normalizeExtractedText(bodyFallback)
        return fallback.isEmpty ? nil : fallback
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
        lines.append(contentsOf: splitLines)
        currentLine = ""
    }

    private func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }
}
