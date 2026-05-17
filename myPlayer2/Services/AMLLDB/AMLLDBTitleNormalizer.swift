//
//  AMLLDBTitleNormalizer.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB Title Normalization Utilities
//  Normalizes song titles for better matching comparison
//

import Foundation

/// Utility class for normalizing and comparing song titles
nonisolated struct AMLLDBTitleNormalizer {

    // MARK: - Title Normalization

    /// Normalize title for comparison
    /// - Handles brackets, spaces, case, fullwidth-halfwidth
    static func normalize(_ title: String) -> String {
        var result = title

        // Convert fullwidth to halfwidth
        result = result.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? result

        // Normalize brackets: （）[]【】 -> ()
        result = normalizeBrackets(result)

        // Lowercase
        result = result.lowercased()

        // Collapse multiple spaces
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        // Trim
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    /// Compact normalized text (remove all spaces and punctuation)
    static func compactNormalize(_ title: String) -> String {
        let normalized = normalize(title)
        return normalized.replacingOccurrences(
            of: #"[[:space:][:punct:]]+"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Normalize brackets: （）[]【】{｝ -> ()
    static func normalizeBrackets(_ text: String) -> String {
        var result = text

        // Chinese brackets
        result = result.replacingOccurrences(of: "（", with: "(")
        result = result.replacingOccurrences(of: "）", with: ")")
        result = result.replacingOccurrences(of: "【", with: "(")
        result = result.replacingOccurrences(of: "】", with: ")")
        result = result.replacingOccurrences(of: "｛", with: "(")
        result = result.replacingOccurrences(of: "｝", with: ")")

        return result
    }

    // MARK: - Version Suffix Handling

    /// Common version suffixes to strip for comparison
    static let versionSuffixes = [
        // English
        "feat", "ft", "featuring", "with",
        "live", "acoustic", "acoustic version",
        "deluxe", "deluxe edition", "deluxe version",
        "explicit", "explicit version",
        "cover", "cover version",
        "demo", "demo version",
        "remaster", "remastered", "remastered version",
        "radio edit", "radio version",
        "original", "original version",
        "instrumental", "instrumental version",
        "karaoke",
        "mv ver", "mv version",
        "music video",
        // Chinese
        "纯享", "纯享版",
        "伴奏", "伴奏版",
        "现场", "现场版",
        "翻唱", "翻唱版",
        "抖音版",
        "官方版",
        "完整版",
        "精修版"
    ]

    /// Strip version suffixes from title for comparison
    static func stripVersionSuffix(_ title: String) -> String {
        var result = normalize(title)

        // Remove content in brackets first
        result = stripBracketContent(result)

        // Remove common suffixes
        for suffix in versionSuffixes {
            let patterns = [
                " - \(suffix)",
                " (\(suffix))",
                " \(suffix)",
                "-\(suffix)",
                "\(suffix)"
            ]

            for pattern in patterns {
                if result.hasSuffix(pattern) {
                    result = String(result.dropLast(pattern.count))
                }
            }
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Strip content inside brackets
    static func stripBracketContent(_ title: String) -> String {
        var result = title

        // Remove (content) patterns
        let bracketPattern = #"\([^)]*\)"#
        if let regex = try? NSRegularExpression(pattern: bracketPattern) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Remove [content] patterns
        let squareBracketPattern = #"\[[^\]]*\]"#
        if let regex = try? NSRegularExpression(pattern: squareBracketPattern) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Alias Extraction

    /// Extract aliases from title with markers like "又名:", "alias:", "aka:"
    static func extractAliases(_ title: String) -> (primary: String, aliases: [String]) {
        let markers = ["又名", "别名", "alias", "aka", "also known as"]

        var primaryTitle = title
        var aliases: [String] = []

        // Pattern to match bracketed alias content
        let bracketPattern = #"[（\(\[【]([^）\)\]】]+)[）\)\]】]"#

        guard let regex = try? NSRegularExpression(pattern: bracketPattern) else {
            return (cleanTitle(title), aliases)
        }

        let nsTitle = title as NSString
        let matches = regex.matches(in: title, range: NSRange(location: 0, length: nsTitle.length))

        for match in matches.reversed() {
            let innerRange = match.range(at: 1)
            guard innerRange.location != NSNotFound else { continue }

            let innerText = nsTitle.substring(with: innerRange)

            // Check if this bracket contains alias marker
            let normalizedInner = normalize(innerText)
            if markers.contains(where: { normalizedInner.contains($0) }) {
                // Extract alias text
                let aliasText = extractAliasText(innerText, markers: markers)
                if !aliasText.isEmpty {
                    aliases.append(aliasText)
                }

                // Remove the bracket from primary title
                if let range = Range(match.range, in: primaryTitle) {
                    primaryTitle.removeSubrange(range)
                }
            }
        }

        // Clean up primary title
        primaryTitle = cleanTitle(primaryTitle)

        // Deduplicate aliases
        aliases = deduplicateAliases(aliases)

        return (primaryTitle, aliases)
    }

    /// Extract alias text from bracket content
    private static func extractAliasText(_ text: String, markers: [String]) -> String {
        var result = text

        // Remove marker prefixes
        for marker in markers {
            let patterns = [
                #"(?i)\b\(marker)\b"#,
                marker,
                "\(marker):",
                "\(marker)："
            ]

            for pattern in patterns {
                result = result.replacingOccurrences(
                    of: pattern,
                    with: "",
                    options: .regularExpression
                )
            }
        }

        // Clean up
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ":：=-"))

        return cleanTitle(result)
    }

    /// Clean title: collapse whitespace, trim
    static func cleanTitle(_ title: String) -> String {
        let collapsed = title.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Deduplicate aliases by normalized value
    private static func deduplicateAliases(_ aliases: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for alias in aliases {
            let normalized = normalize(alias)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(alias)
        }

        return result
    }

    // MARK: - Title Comparison

    /// Compare two titles and return similarity score (0.0 - 1.0)
    static func compareTitles(_ title1: String, _ title2: String) -> Double {
        let norm1 = normalize(title1)
        let norm2 = normalize(title2)

        // Exact match
        if norm1 == norm2 { return 1.0 }

        let compact1 = compactNormalize(title1)
        let compact2 = compactNormalize(title2)

        // Compact exact match
        if compact1 == compact2 { return 0.96 }

        // Stripped version comparison
        let stripped1 = stripVersionSuffix(title1)
        let stripped2 = stripVersionSuffix(title2)

        if stripped1 == stripped2 { return 0.92 }

        // Prefix match
        if norm1.hasPrefix(norm2) || norm2.hasPrefix(norm1) {
            let shorter = min(norm1.count, norm2.count)
            let longer = max(norm1.count, norm2.count)
            return 0.85 + (Double(shorter) / Double(longer) * 0.1)
        }

        // Contains match
        if norm1.contains(norm2) || norm2.contains(norm1) {
            let shorter = min(norm1.count, norm2.count)
            let longer = max(norm1.count, norm2.count)
            return 0.75 + (Double(shorter) / Double(longer) * 0.1)
        }

        // Compact contains match
        if compact1.contains(compact2) || compact2.contains(compact1) {
            return 0.70
        }

        // Levenshtein similarity
        let levDistance = Levenshtein.distance(norm1, norm2)
        let maxLen = max(norm1.count, norm2.count)
        guard maxLen > 0 else { return 0 }

        let levSimilarity = 1.0 - Double(levDistance) / Double(maxLen)

        // Threshold: similarity >= 0.6 is acceptable
        if levSimilarity >= 0.6 {
            return levSimilarity * 0.85 // Scale down slightly for fuzzy match
        }

        return 0
    }
}

// MARK: - Levenshtein Distance

/// Lightweight Levenshtein edit distance implementation
nonisolated struct Levenshtein {

    /// Calculate edit distance between two strings
    static func distance(_ s1: String, _ s2: String) -> Int {
        let arr1 = Array(s1)
        let arr2 = Array(s2)

        let m = arr1.count
        let n = arr2.count

        // Edge cases
        if m == 0 { return n }
        if n == 0 { return m }

        // Use two rows for optimization (space: O(n) instead of O(m*n))
        var prevRow = Array(repeating: 0, count: n + 1)
        var currRow = Array(repeating: 0, count: n + 1)

        // Initialize first row
        for j in 0...n {
            prevRow[j] = j
        }

        // Fill matrix
        for i in 1...m {
            currRow[0] = i

            for j in 1...n {
                let cost = arr1[i - 1] == arr2[j - 1] ? 0 : 1

                currRow[j] = min(
                    prevRow[j] + 1,       // deletion
                    currRow[j - 1] + 1,   // insertion
                    prevRow[j - 1] + cost // substitution
                )
            }

            // Swap rows
            swap(&prevRow, &currRow)
        }

        return prevRow[n]
    }

    /// Calculate normalized similarity (0.0 - 1.0)
    static func similarity(_ s1: String, _ s2: String) -> Double {
        let dist = distance(s1, s2)
        let maxLen = max(s1.count, s2.count)
        guard maxLen > 0 else { return 1.0 }

        return 1.0 - Double(dist) / Double(maxLen)
    }
}

// MARK: - Artist Normalization

/// Utility for normalizing and comparing artist names
nonisolated struct AMLLDBArtistNormalizer {

    /// Common artist separators
    static let separators = ["/", "、", ",", "&", "feat.", "ft.", " x ", "×", "；", ";"]

    /// Normalize artist string to array of individual artists
    static func normalizeArtists(_ artists: String) -> [String] {
        let normalized = AMLLDBTitleNormalizer.normalize(artists)

        // Split by separators
        var result: [String] = [normalized]

        for sep in separators {
            result = result.flatMap { artist in
                artist.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }

        // Filter empty and "various artists"
        return result.filter { artist in
            !artist.isEmpty && !isVariousArtists(artist)
        }
    }

    /// Normalize array of artists
    static func normalizeArtistArray(_ artists: [String]) -> [String] {
        artists.flatMap { normalizeArtists($0) }.filter { !$0.isEmpty && !isVariousArtists($0) }
    }

    /// Check if artist is "Various Artists" or similar
    static func isVariousArtists(_ artist: String) -> Bool {
        let normalized = AMLLDBTitleNormalizer.normalize(artist)
        let variousPatterns = [
            "various artists", "various", "群星", "多位艺人", "多位歌手", "多位艺术家", "多人"
        ]
        return variousPatterns.contains(where: { normalized.contains($0) })
    }

    /// Compare artist sets and return similarity score (0.0 - 1.0)
    static func compareArtistSets(_ artists1: [String], _ artists2: [String]) -> Double {
        let set1 = Set(normalizeArtistArray(artists1).map { AMLLDBTitleNormalizer.compactNormalize($0) })
        let set2 = Set(normalizeArtistArray(artists2).map { AMLLDBTitleNormalizer.compactNormalize($0) })

        // Empty sets
        if set1.isEmpty || set2.isEmpty { return 0 }

        // Exact match
        if set1 == set2 { return 1.0 }

        // Jaccard similarity: intersection / union
        let intersection = set1.intersection(set2)
        let union = set1.union(set2)

        let jaccard = Double(intersection.count) / Double(union.count)

        // Partial credit for partial overlap
        if jaccard > 0 {
            return jaccard
        }

        // Check for contains match between any pair
        for a1 in set1 {
            for a2 in set2 {
                if a1.contains(a2) || a2.contains(a1) {
                    // Partial match bonus
                    return 0.3
                }
            }
        }

        return 0
    }
}

// MARK: - Duration Comparison

/// Utility for comparing song durations
nonisolated struct AMLLDBDurationComparator {

    /// Calculate duration similarity score using linear decay
    /// - Parameters:
    ///   - queryMs: Query track duration in milliseconds
    ///   - candidateMs: Candidate track duration in milliseconds
    /// - Returns: Score from 0.0 to 1.0
    static func compareDuration(queryMs: Int?, candidateMs: Int?) -> Double {
        guard let qMs = queryMs, let cMs = candidateMs else { return 0 }

        let diff = abs(qMs - cMs)

        // Within 10 seconds: full score
        if diff <= 10000 { return 1.0 }

        // Within 60 seconds: linear decay
        if diff <= 60000 {
            let decayRange = 60000 - 10000 // 50 seconds
            let decayAmount = diff - 10000
            return 1.0 - (Double(decayAmount) / Double(decayRange) * 0.8) // Decay to 0.2
        }

        // Beyond 60 seconds: minimum score
        return 0.1
    }
}

// MARK: - Album Comparison

/// Utility for comparing album names
nonisolated struct AMLLDBAlbumComparator {

    /// Calculate album similarity score
    static func compareAlbums(_ album1: String?, _ album2: String?) -> Double {
        guard let a1 = album1, let a2 = album2 else { return 0 }

        let a1Trimmed = a1.trimmingCharacters(in: .whitespacesAndNewlines)
        let a2Trimmed = a2.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !a1Trimmed.isEmpty, !a2Trimmed.isEmpty else { return 0 }

        let norm1 = AMLLDBTitleNormalizer.normalize(a1Trimmed)
        let norm2 = AMLLDBTitleNormalizer.normalize(a2Trimmed)

        // Exact match
        if norm1 == norm2 { return 1.0 }

        // Contains match
        if norm1.contains(norm2) || norm2.contains(norm1) {
            return 0.7
        }

        // Compact match
        let compact1 = AMLLDBTitleNormalizer.compactNormalize(a1Trimmed)
        let compact2 = AMLLDBTitleNormalizer.compactNormalize(a2Trimmed)

        if compact1 == compact2 { return 0.8 }
        if compact1.contains(compact2) || compact2.contains(compact1) {
            return 0.5
        }

        return 0
    }
}
