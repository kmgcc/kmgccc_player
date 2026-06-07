#!/usr/bin/env swift
//
//  MetadataMatchScorerTests.swift
//  myPlayer2/Tests
//
//  Standalone Swift script: run with `swift MetadataMatchScorerTests.swift`
//  Tests the short-title matching gate introduced to prevent errors like
//  "Colors / Halsey" matching against "Closer / Halsey".
//
//  NOTE: This file mirrors only the logic under test from:
//    - ExternalPlaybackTextNormalizer (normalization + scoring)
//  It does NOT depend on any app target. Keep in sync with the real impl.
//

import Foundation

// MARK: - Inline copy of core normalizer logic (kept in sync with ExternalPlaybackTextNormalizer.swift)

enum Normalizer {
    private static let versionNoiseWords: Set<String> = [
        "live", "remaster", "remastered", "deluxe", "edition", "version", "single",
        "ep", "mono", "stereo", "radio", "edit", "instrumental", "karaoke",
        "伴奏", "现场", "国语版", "粤语版", "重制", "重录", "加长版", "特别版"
    ]
    private static let connectorWords: Set<String> = ["feat", "featuring", "ft", "with", "and", "x"]

    struct NText {
        var original: String
        var folded: String
        var stripped: String
        var tokens: Set<String>
        var compact: String
    }

    struct NArtist {
        var text: NText
        var parts: Set<String>
    }

    static func normalize(_ value: String?) -> NText {
        let original = value ?? ""
        let folded = fold(original)
        let stripped = stripVersionNoise(from: folded)
        return NText(
            original: original,
            folded: folded,
            stripped: stripped,
            tokens: Set(tokenize(stripped)),
            compact: compact(stripped)
        )
    }

    static func normalizeArtist(_ value: String?) -> NArtist {
        let text = normalize(value)
        let parts = splitArtistParts(text.stripped)
        let normalizedParts = parts
            .map { normalize($0).compact }
            .filter { !$0.isEmpty && !connectorWords.contains($0) }
        return NArtist(text: text, parts: Set(normalizedParts))
    }

    static func stringSimilarity(_ lhs: NText, _ rhs: NText) -> Double {
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

    static func artistSimilarity(_ lhs: NArtist, _ rhs: NArtist) -> Double {
        if lhs.text.compact.isEmpty || rhs.text.compact.isEmpty { return 0 }
        if lhs.text.compact == rhs.text.compact { return 1 }
        if lhs.text.compact.contains(rhs.text.compact) || rhs.text.compact.contains(lhs.text.compact) {
            return 0.92
        }
        let partScore = jaccard(lhs.parts, rhs.parts)
        let textScore = stringSimilarity(lhs.text, rhs.text)
        return max(partScore, textScore)
    }

    // MARK: - Short-title gate (mirrors ExternalPlaybackTextNormalizer additions)

    static func hasShortTitleConflict(_ source: NText, _ candidate: NText) -> Bool {
        guard isShortSingleToken(source), isShortSingleToken(candidate) else { return false }
        if source.compact.contains(candidate.compact) || candidate.compact.contains(source.compact) {
            return false
        }
        return levenshteinDistance(source.compact, candidate.compact) > 1
    }

    static func isShortSingleToken(_ text: NText) -> Bool {
        text.tokens.count == 1 && text.compact.count <= 6
    }

    static let shortTitleFuzzyFloor: Double = 0.82

    // MARK: - Combined title acceptance check (mirrors scorer logic in QQMusicCoverService + ExternalPlaybackMatchResolver)

    static func titleAccepted(source: NText, candidate: NText) -> Bool {
        if !candidate.compact.isEmpty, hasShortTitleConflict(source, candidate) { return false }
        let score = stringSimilarity(source, candidate)
        let bothShort = isShortSingleToken(source) && isShortSingleToken(candidate)
        let floor: Double = bothShort ? shortTitleFuzzyFloor : 0.50
        return score >= floor
            || candidate.compact.contains(source.compact)
            || source.compact.contains(candidate.compact)
    }

    // MARK: - Internals

    private static func fold(_ value: String) -> String {
        var result = value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let replacements: [(String, String)] = [
            ("（", "("), ("）", ")"), ("【", "("), ("】", ")"), ("[", "("), ("]", ")"),
            ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
            ("＆", "&"), ("、", ","), ("，", ","), ("×", " x "), ("／", "/"),
            ("-", " "), ("_", " "), ("·", " "), ("・", " "), (":", " "), ("：", " ")
        ]
        for (from, to) in replacements { result = result.replacingOccurrences(of: from, with: to) }
        result = result.replacingOccurrences(
            of: #"(?i)\b(feat\.?|featuring|ft\.?|with)\b"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[&+/]+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripVersionNoise(from value: String) -> String {
        var result = value
        // Strip parenthesised blocks that contain only noise words
        if let regex = try? NSRegularExpression(pattern: #"\(([^)]*)\)"#) {
            var out = ""
            var last = value.startIndex
            let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
            for m in regex.matches(in: value, range: nsRange) {
                guard let range = Range(m.range, in: value) else { continue }
                out += value[last..<range.lowerBound]
                let inner = String(value[range].dropFirst().dropLast())
                let words = tokenize(inner)
                out += words.allSatisfy { versionNoiseWords.contains($0) } ? " " : " \(inner) "
                last = range.upperBound
            }
            out += value[last..<value.endIndex]
            result = out
        }
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
            let kind = charKind(scalar)
            if kind == "other" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func splitMixedToken(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var prevKind: String?
        for scalar in value.unicodeScalars {
            let kind = charKind(scalar)
            if let pk = prevKind, pk != kind, !current.isEmpty { result.append(current); current = "" }
            current.unicodeScalars.append(scalar)
            prevKind = kind
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func splitArtistParts(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: #"\b(feat|featuring|ft|with|and|x)\b"#, with: ",", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",;/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func charKind(_ scalar: Unicode.Scalar) -> String {
        if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { return "han" }
        if CharacterSet.alphanumerics.contains(scalar) { return "latin" }
        return "other"
    }

    private static func compact(_ value: String) -> String { tokenize(value).joined() }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private static func levenshteinRatio(_ lhs: String, _ rhs: String) -> Double {
        let d = levenshteinDistance(lhs, rhs)
        let m = max(lhs.count, rhs.count)
        guard m > 0 else { return 1 }
        return 1 - Double(d) / Double(m)
    }

    static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + (a[i-1] == b[j-1] ? 0 : 1))
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(
    _ condition: Bool,
    _ description: String,
    file: String = #file,
    line: Int = #line
) {
    if condition {
        print("  ✅ PASS: \(description)")
        passed += 1
    } else {
        print("  ❌ FAIL: \(description)  [\(URL(fileURLWithPath: file).lastPathComponent):\(line)]")
        failed += 1
    }
}

func titleAccepted(query: String, candidate: String) -> Bool {
    Normalizer.titleAccepted(
        source: Normalizer.normalize(query),
        candidate: Normalizer.normalize(candidate)
    )
}

func titleScore(query: String, candidate: String) -> Double {
    Normalizer.stringSimilarity(Normalizer.normalize(query), Normalizer.normalize(candidate))
}

func editDist(_ a: String, _ b: String) -> Int {
    Normalizer.levenshteinDistance(
        Normalizer.normalize(a).compact,
        Normalizer.normalize(b).compact
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 1 — Colors / Halsey must NOT match Closer / Halsey
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 1: Colors / Halsey ≠ Closer / Halsey ===")
check(!titleAccepted(query: "Colors", candidate: "Closer"),
      "\"Colors\" must NOT accept \"Closer\" (ed=\(editDist("Colors","Closer")))")
let closerRawScore = titleScore(query: "Colors", candidate: "Closer")
check(closerRawScore < Normalizer.shortTitleFuzzyFloor,
      "Raw score for Colors/Closer (\(String(format:"%.3f",closerRawScore))) is below short-title floor 0.80 — gate fires first anyway")

// ─────────────────────────────────────────────────────────────────────────────
// Test 2 — Colors matches Colors exactly
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 2: Colors / Halsey = Colors / Halsey ===")
check(titleAccepted(query: "Colors", candidate: "Colors"),
      "\"Colors\" accepts exact match \"Colors\"")

// ─────────────────────────────────────────────────────────────────────────────
// Test 3 — Version suffix variants accepted
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 3: Version suffix variants ===")
let versionCases: [(String, String)] = [
    ("Colors", "Colors - Single"),
    ("Colors", "Colors (Stripped)"),
    ("Colors", "Colors (Live)"),
    ("Colors", "Colors (Acoustic)"),
    ("Colors", "Colors (Remastered)"),
    ("Colors", "Colors (Deluxe Edition)"),
]
for (q, c) in versionCases {
    check(titleAccepted(query: q, candidate: c), "\"\(q)\" accepts \"\(c)\"")
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 4 — Artist typo tolerance (title is exact, artist side scored separately)
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 4: Artist typo tolerance ===")
check(titleAccepted(query: "Colors", candidate: "Colors"),
      "Title exact match still works (artist typo Halsy→Halsey scored independently)")
let artistSrc = Normalizer.normalizeArtist("Halsy")
let artistCnd = Normalizer.normalizeArtist("Halsey")
let aScore = Normalizer.artistSimilarity(artistSrc, artistCnd)
check(aScore >= 0.80,
      "Artist \"Halsy\" vs \"Halsey\" score=\(String(format:"%.3f",aScore)) ≥ 0.80")

// ─────────────────────────────────────────────────────────────────────────────
// Test 5 — Short title pairs that must be rejected (ed > 1)
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 5: Short title pairs — rejected (ed > 1) ===")
let rejectedPairs: [(String, String)] = [
    ("Stay",  "Star"),   // ed=2
    ("Home",  "Hope"),   // ed=2
    ("Hello", "Holla"),  // ed=2
    ("Light", "Night"),  // ed=2
    ("Flame", "Frame"),  // ed=2
    ("Yours", "Hours"),  // ed=2
    ("Sorry", "Story"),  // ed=2
]
for (q, c) in rejectedPairs {
    check(!titleAccepted(query: q, candidate: c),
          "\"\(q)\" rejects \"\(c)\" (ed=\(editDist(q,c)))")
}
// "Love" inside "Lover" — containment path, intentionally accepted
let loveAccepted = titleAccepted(query: "Love", candidate: "Lover")
print("  ℹ️  INFO: \"Love\" vs \"Lover\" = \(loveAccepted ? "accepted (containment)" : "rejected")")

// ─────────────────────────────────────────────────────────────────────────────
// Test 6 — Title exact, artist minor diff → title side accepted
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 6: Title exact, artist minor diff ===")
check(titleAccepted(query: "Colors", candidate: "Colors"),
      "Title exact accepted (artist scored separately)")

// ─────────────────────────────────────────────────────────────────────────────
// Test 7 — Artist exact, title clearly different → title rejected
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 7: Artist exact, title clearly different → title rejected ===")
check(!titleAccepted(query: "Colors", candidate: "Closer"),
      "\"Colors\" rejects \"Closer\" even when artist matches perfectly (ed=\(editDist("Colors","Closer")))")
check(!titleAccepted(query: "Stay",   candidate: "Star"),
      "\"Stay\" rejects \"Star\" (ed=\(editDist("Stay","Star")))")

// ─────────────────────────────────────────────────────────────────────────────
// Test 8 — feat. / featuring stripped before comparison
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 8: feat. / featuring stripping ===")
check(titleAccepted(query: "Colors feat. SZA", candidate: "Colors"),
      "\"Colors feat. SZA\" → stripped core \"Colors\" → matches \"Colors\"")
check(titleAccepted(query: "Colors", candidate: "Colors ft. SZA"),
      "\"Colors\" matches candidate \"Colors ft. SZA\" (feat stripped)")
check(titleAccepted(query: "Colors featuring SZA", candidate: "Colors"),
      "\"Colors featuring SZA\" matches \"Colors\"")

// ─────────────────────────────────────────────────────────────────────────────
// Test 9 — remix/live/acoustic don't break core title match
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 9: Remix/live/acoustic versions ===")
check(titleAccepted(query: "Colors", candidate: "Colors (Acoustic Version)"),
      "Colors matches \"Colors (Acoustic Version)\"")
check(titleAccepted(query: "Colors", candidate: "Colors - Live"),
      "Colors matches \"Colors - Live\"")
check(!titleAccepted(query: "Colors", candidate: "Closer (Remix)"),
      "\"Colors\" does NOT match \"Closer (Remix)\" — core word still differs (ed=\(editDist("Colors","Closer")))")

// ─────────────────────────────────────────────────────────────────────────────
// Test 10 — Near-exact 1-edit-distance pairs: accepted with score cap
// ─────────────────────────────────────────────────────────────────────────────
print("\n=== Test 10: Edit distance 1 — within tolerance ===")
let edOneAccepted: [(String, String)] = [
    ("Color",  "Colour"),   // ed=1
    ("Colors", "Colours"),  // ed=1
]
for (q, c) in edOneAccepted {
    check(titleAccepted(query: q, candidate: c),
          "\"\(q)\" accepts \"\(c)\" (ed=\(editDist(q,c)), within 1-edit tolerance)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Summary
// ─────────────────────────────────────────────────────────────────────────────
print("\n==========================================")
print("Results: \(passed) passed, \(failed) failed")
print("==========================================\n")
if failed > 0 { exit(1) }
