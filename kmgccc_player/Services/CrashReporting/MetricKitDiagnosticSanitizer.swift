import Foundation

nonisolated enum MetricKitDiagnosticSanitizer {
    private static let redactionVersion = "1"
    private static let patterns: [(key: String, pattern: String, replacement: String)] = [
        ("externalPath", #"/(?:Users|Volumes|home|private/(?:var|tmp)|var/folders|tmp)(?:/[^\s\"'<>]+)+"#, "<EXTERNAL_PATH>"),
        ("email", #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<EMAIL_REDACTED>"),
        ("secret", #"(?i)\b(authorization|cookie|token|secret|password|api[_-]?key)\b(\s*[:=]\s*)[^\s,;]+"#, "$1$2<REDACTED>"),
        ("urlDetails", #"(https?://[^\s?#]+)(?:\?[^\s#]*)?(?:#[^\s]*)?"#, "$1")
    ]

    static func sanitize(_ data: Data) throws -> (json: String, counts: [String: Int]) {
        let object = try JSONSerialization.jsonObject(with: data)
        var counts: [String: Int] = [:]
        let sanitized = sanitizeValue(object, counts: &counts)
        let output = try JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard output.count <= 1_800_000,
              let json = String(data: output, encoding: .utf8) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        return (json, counts)
    }

    static var version: String { redactionVersion }

    private static func sanitizeValue(_ value: Any, counts: inout [String: Int]) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { sanitizeValue($0, counts: &counts) }
        }
        if let array = value as? [Any] {
            return array.prefix(10_000).map { sanitizeValue($0, counts: &counts) }
        }
        guard var string = value as? String else { return value }
        for rule in patterns {
            guard let expression = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            let matches = expression.numberOfMatches(in: string, range: range)
            if matches > 0 {
                string = expression.stringByReplacingMatches(
                    in: string,
                    range: range,
                    withTemplate: rule.replacement
                )
                counts[rule.key, default: 0] += matches
            }
        }
        if string.count > 4_096 {
            string = String(string.prefix(4_095)) + "…"
            counts["textTruncated", default: 0] += 1
        }
        return string
    }
}
