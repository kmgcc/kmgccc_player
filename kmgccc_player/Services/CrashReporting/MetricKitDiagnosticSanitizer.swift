import Foundation

nonisolated enum MetricKitDiagnosticSanitizer {
    private static let redactionVersion = "1"
    private static let keySortLocale = Locale(identifier: "en_US")
    private static let patterns: [(key: String, pattern: String, replacement: String)] = [
        ("externalPath", #"/(?:Users|Volumes|home|private/(?:var|tmp)|var/folders|tmp)(?:/[^\s\"'<>]+)+"#, "<EXTERNAL_PATH>"),
        ("email", #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<EMAIL_REDACTED>"),
        ("secret", #"(?i)\b(authorization|cookie|token|secret|password|api[_-]?key)\b(\s*[:=]\s*)[^\s,;]+"#, "$1$2<REDACTED>"),
        ("urlDetails", #"(https?://[^\s?#]+)(?:\?[^\s#]*)?(?:#[^\s]*)?"#, "$1")
    ]

    nonisolated private enum JSONWork {
        case value(Any)
        case literal(String)
        case key(String)
    }

    static func sanitize(_ data: Data) throws -> (json: String, counts: [String: Int]) {
        let object = try JSONSerialization.jsonObject(with: data)
        var counts: [String: Int] = [:]
        var output = Data()
        var work: [JSONWork] = [.value(object)]
        // MetricKit stack trees can be hundreds of containers deep. Rebuilding
        // [String: Any]/[Any] and bridging that whole tree back to Foundation
        // exhausted the worker's stack. Walk native containers iteratively and
        // ask Foundation to encode only scalar values.
        while let next = work.popLast() {
            switch next {
            case let .literal(text):
                output.append(contentsOf: text.utf8)
            case let .key(key):
                output.append(try encodeScalar(key))
            case let .value(value):
                if let dictionary = value as? NSDictionary {
                    let keys = (dictionary.allKeys as? [String] ?? []).sorted {
                        $0.compare($1, options: [.numeric, .caseInsensitive, .forcedOrdering],
                                   locale: keySortLocale) == .orderedAscending
                    }
                    output.append(contentsOf: "{".utf8)
                    work.append(.literal("}"))
                    for index in keys.indices.reversed() {
                        let key = keys[index]
                        if index < keys.count - 1 { work.append(.literal(",")) }
                        work.append(.value(dictionary.object(forKey: key)!))
                        work.append(.literal(":"))
                        work.append(.key(key))
                    }
                } else if let array = value as? NSArray {
                    let count = min(array.count, 10_000)
                    output.append(contentsOf: "[".utf8)
                    work.append(.literal("]"))
                    for index in (0..<count).reversed() {
                        if index < count - 1 { work.append(.literal(",")) }
                        work.append(.value(array.object(at: index)))
                    }
                } else if let string = value as? String {
                    output.append(try encodeScalar(sanitizeText(string, counts: &counts)))
                } else {
                    output.append(try encodeScalar(value))
                }
            }
            guard output.count <= 1_800_000 else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        guard let json = String(data: output, encoding: .utf8) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        return (json, counts)
    }

    static var version: String { redactionVersion }

    private static func encodeScalar(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    private static func sanitizeText(_ value: String, counts: inout [String: Int]) -> String {
        var string = value
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
