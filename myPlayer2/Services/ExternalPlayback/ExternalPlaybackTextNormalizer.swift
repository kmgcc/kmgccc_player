//
//  ExternalPlaybackTextNormalizer.swift
//  myPlayer2
//
//  Shared normalization and scoring helpers for external playback matching.
//

import Foundation

nonisolated enum ExternalPlaybackTextNormalizer {
    private static let versionNoiseWords: Set<String> = [
        "live", "remaster", "remastered", "deluxe", "edition", "version", "single",
        "ep", "mono", "stereo", "radio", "edit", "instrumental", "karaoke",
        "伴奏", "现场", "国语版", "粤语版", "重制", "重录", "加长版", "特别版"
    ]

    private static let connectorWords: Set<String> = [
        "feat", "featuring", "ft", "with", "and", "x"
    ]

    static func normalizedKey(_ value: String?) -> String {
        normalize(value).folded
    }

    static func normalize(_ value: String?) -> NormalizedText {
        let original = value ?? ""
        let folded = fold(original)
        let stripped = stripVersionNoise(from: folded)
        return NormalizedText(
            original: original,
            folded: folded,
            stripped: stripped,
            tokens: Set(tokenize(stripped)),
            compact: compact(stripped)
        )
    }

    static func normalizeArtist(_ value: String?) -> NormalizedArtist {
        let text = normalize(value)
        let parts = splitArtistParts(text.stripped)
        let normalizedParts = parts
            .map { normalize($0).compact }
            .filter { !$0.isEmpty && !connectorWords.contains($0) }
        return NormalizedArtist(
            text: text,
            parts: Set(normalizedParts)
        )
    }

    static func stringSimilarity(_ lhs: NormalizedText, _ rhs: NormalizedText) -> Double {
        if lhs.compact.isEmpty || rhs.compact.isEmpty { return 0 }
        if lhs.compact == rhs.compact { return 1 }
        if lhs.compact.contains(rhs.compact) || rhs.compact.contains(lhs.compact) {
            let shorter = Double(min(lhs.compact.count, rhs.compact.count))
            let longer = Double(max(lhs.compact.count, rhs.compact.count))
            return max(0.78, shorter / max(longer, 1))
        }

        let tokenScore = jaccard(lhs.tokens, rhs.tokens)
        let editScore = levenshteinRatio(lhs.compact, rhs.compact)
        return max(tokenScore, editScore)
    }

    static func artistSimilarity(_ lhs: NormalizedArtist, _ rhs: NormalizedArtist) -> Double {
        if lhs.text.compact.isEmpty || rhs.text.compact.isEmpty { return 0 }
        if lhs.text.compact == rhs.text.compact { return 1 }
        if lhs.text.compact.contains(rhs.text.compact) || rhs.text.compact.contains(lhs.text.compact) {
            return 0.92
        }

        let partScore = jaccard(lhs.parts, rhs.parts)
        let textScore = stringSimilarity(lhs.text, rhs.text)
        return max(partScore, textScore)
    }

    static func durationScore(source: Double, candidate: Double) -> Double {
        guard source > 0, candidate > 0 else { return 0.35 }
        let diff = abs(source - candidate)
        switch diff {
        case 0...2: return 1.0
        case 2...5: return 0.82
        case 5...12: return 0.55
        case 12...25: return 0.22
        default: return 0
        }
    }

    static func hasObviousConflict(
        titleScore: Double,
        artistScore: Double,
        sourceDuration: Double,
        candidateDuration: Double
    ) -> Bool {
        if titleScore < 0.45 { return true }
        if artistScore < 0.18 { return true }
        if sourceDuration > 0, candidateDuration > 0, abs(sourceDuration - candidateDuration) > 45 {
            return true
        }
        return false
    }

    private static func fold(_ value: String) -> String {
        var result = value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)

        let replacements: [(String, String)] = [
            ("（", "("), ("）", ")"), ("【", "("), ("】", ")"), ("[", "("), ("]", ")"),
            ("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'"),
            ("＆", "&"), ("、", ","), ("，", ","), ("×", " x "), ("／", "/"),
            ("-", " "), ("_", " "), ("·", " "), ("・", " "), (":", " "), ("：", " ")
        ]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        result = result.replacingOccurrences(
            of: #"(?i)\b(feat\.?|featuring|ft\.?|with)\b"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"[&+/]+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripVersionNoise(from value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"\(([^)]*)\)"#,
            with: { match in
                let content = String(match.dropFirst().dropLast())
                let words = tokenize(content)
                return words.allSatisfy { versionNoiseWords.contains($0) } ? " " : " \(content) "
            },
            options: .regularExpression
        )

        let suffixPattern = #"(?i)\b(live|remaster(?:ed)?|deluxe|edition|version|single|ep|instrumental|karaoke|radio edit|伴奏|现场|国语版|粤语版|重制|重录|加长版|特别版)\b"#
        result = result.replacingOccurrences(of: suffixPattern, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenize(_ value: String) -> [String] {
        splitTokenRuns(value)
            .flatMap { splitMixedToken($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !connectorWords.contains($0) }
    }

    private static func splitTokenRuns(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in value.unicodeScalars {
            let kind = CharacterKind(scalar)
            if kind == .other {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func splitArtistParts(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: #"\b(feat|featuring|ft|with|and|x)\b"#, with: ",", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",;/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func splitMixedToken(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        let scalars = Array(value.unicodeScalars)
        var result: [String] = []
        var current = ""
        var previousKind: CharacterKind?

        for scalar in scalars {
            let kind = CharacterKind(scalar)
            if let previousKind, previousKind != kind, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.unicodeScalars.append(scalar)
            previousKind = kind
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func compact(_ value: String) -> String {
        tokenize(value).joined()
    }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        return Double(intersection) / Double(max(union, 1))
    }

    private static func levenshteinRatio(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            previous = current
        }

        let distance = previous[b.count]
        let maxLength = max(a.count, b.count)
        return 1 - Double(distance) / Double(maxLength)
    }

    struct NormalizedText: Sendable {
        var original: String
        var folded: String
        var stripped: String
        var tokens: Set<String>
        var compact: String
    }

    struct NormalizedArtist: Sendable {
        var text: NormalizedText
        var parts: Set<String>
    }

    private enum CharacterKind {
        case han
        case latin
        case other

        init(_ scalar: UnicodeScalar) {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                self = .han
            } else if CharacterSet.alphanumerics.contains(scalar) {
                self = .latin
            } else {
                self = .other
            }
        }
    }
}

private extension String {
    func replacingOccurrences(
        of pattern: String,
        with replacement: (Substring) -> String,
        options: NSString.CompareOptions
    ) -> String {
        guard options.contains(.regularExpression),
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }
        let nsRange = NSRange(startIndex..<endIndex, in: self)
        var result = ""
        var lastIndex = startIndex
        for match in regex.matches(in: self, range: nsRange) {
            guard let range = Range(match.range, in: self) else { continue }
            result += self[lastIndex..<range.lowerBound]
            result += replacement(self[range])
            lastIndex = range.upperBound
        }
        result += self[lastIndex..<endIndex]
        return result
    }
}
