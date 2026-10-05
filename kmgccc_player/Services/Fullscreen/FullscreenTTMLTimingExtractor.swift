import Foundation

enum FullscreenTTMLTimingExtractor {
    static func lastMainLineEndTime(in ttml: String) -> TimeInterval? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let delegate = FullscreenTTMLTimingParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        guard parser.parse() else { return nil }
        return delegate.lastMainLineEndTime
    }
}

private final class FullscreenTTMLTimingParser: NSObject, XMLParserDelegate {
    private(set) var lastMainLineEndTime: TimeInterval?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.localName(qName ?? elementName)
        guard name == "p" else { return }
        guard !Self.isBackgroundLine(attributeDict) else { return }

        let begin = Self.timeValue(forLocalName: "begin", in: attributeDict)
        let explicitEnd = Self.timeValue(forLocalName: "end", in: attributeDict)
        let duration = Self.timeValue(forLocalName: "dur", in: attributeDict)
        let endTime = explicitEnd ?? begin.flatMap { start in duration.map { start + $0 } }
        guard let endTime, endTime.isFinite, endTime >= 0 else { return }
        lastMainLineEndTime = max(lastMainLineEndTime ?? 0, endTime)
    }

    private static func isBackgroundLine(_ attributes: [String: String]) -> Bool {
        attributes.contains { key, value in
            localName(key) == "role" && value.lowercased().contains("x-bg")
        }
    }

    private static func timeValue(
        forLocalName targetName: String,
        in attributes: [String: String]
    ) -> TimeInterval? {
        guard let raw = attributes.first(where: { localName($0.key) == targetName })?.value else {
            return nil
        }
        return parseTimeExpression(raw)
    }

    private static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }

    private static func parseTimeExpression(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .lowercased()
        guard !value.isEmpty else { return nil }

        if value.hasSuffix("ms"),
           let milliseconds = Double(value.dropLast(2)) {
            return milliseconds / 1000.0
        }
        if value.hasSuffix("s"),
           let seconds = Double(value.dropLast()) {
            return seconds
        }
        if value.hasSuffix("m"),
           let minutes = Double(value.dropLast()) {
            return minutes * 60.0
        }
        if value.hasSuffix("h"),
           let hours = Double(value.dropLast()) {
            return hours * 3600.0
        }

        let parts = value.split(separator: ":").map(String.init)
        if parts.count == 2 || parts.count == 3 {
            guard let seconds = Double(parts[parts.count - 1]) else { return nil }
            guard let minutes = Double(parts[parts.count - 2]) else { return nil }
            let hours = parts.count == 3 ? (Double(parts[0]) ?? .nan) : 0
            guard hours.isFinite, minutes.isFinite, seconds.isFinite else { return nil }
            return hours * 3600.0 + minutes * 60.0 + seconds
        }

        return Double(value)
    }
}
