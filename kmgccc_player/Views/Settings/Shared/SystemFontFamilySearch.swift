import Foundation

/// Font names used by settings. No font instances or glyph data are retained.
nonisolated struct SystemFontFamily: Identifiable, Equatable, Sendable {
    let name: String
    let displayName: String
    let aliases: [String]

    var id: String { name }

    fileprivate let searchKeys: [String]

    init(name: String, displayName: String? = nil, aliases: [String] = []) {
        let resolvedDisplayName = displayName ?? name
        self.name = name
        self.displayName = resolvedDisplayName
        self.aliases = aliases

        var seen = Set<String>()
        searchKeys = ([name, resolvedDisplayName] + aliases).compactMap { value in
            let key = SystemFontFamilySearch.normalizedParts(value).joined()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
    }
}

nonisolated enum SystemFontFamilySearch {
    static func matches(
        in families: [SystemFontFamily],
        query: String,
        selectedFamily: String,
        limit: Int = 12
    ) -> [SystemFontFamily] {
        guard limit > 0 else { return [] }

        var candidates = families
        if !selectedFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !candidates.contains(where: { $0.name == selectedFamily }) {
            candidates.insert(SystemFontFamily(name: selectedFamily), at: 0)
        }

        let queryParts = normalizedParts(query)
        let queryKey = queryParts.joined()
        let selectedKey = normalizedParts(selectedFamily).joined()
        if queryKey.isEmpty || queryKey == selectedKey {
            let selected = candidates.filter { $0.name == selectedFamily }
            let remaining = candidates.filter { $0.name != selectedFamily }
            return Array((selected + remaining).prefix(limit))
        }

        let scored = candidates.enumerated().compactMap { index, family -> (Int, Int, SystemFontFamily)? in
            guard let rank = rank(family, queryKey: queryKey, queryParts: queryParts) else {
                return nil
            }
            return (rank, index, family)
        }
        return scored.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1 < $1.1
        }.prefix(limit).map { $0.2 }
    }

    fileprivate static func normalizedParts(_ value: String) -> [String] {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    }

    private static func rank(
        _ family: SystemFontFamily,
        queryKey: String,
        queryParts: [String]
    ) -> Int? {
        let wholeRank = bestRank(queryKey, in: family.searchKeys).map { $0 * 2 }
        guard queryParts.count > 1 else { return wholeRank }

        var worstPartRank = 0
        for part in queryParts {
            guard let partRank = bestRank(part, in: family.searchKeys) else {
                return wholeRank
            }
            worstPartRank = max(worstPartRank, partRank)
        }

        // A complete name wins ties over words found in separate aliases.
        let partsRank = worstPartRank * 2 + 1
        return min(wholeRank ?? partsRank, partsRank)
    }

    private static func bestRank(_ query: String, in keys: [String]) -> Int? {
        keys.compactMap { key -> Int? in
            if key == query { return 0 }
            if key.hasPrefix(query) { return 1 }
            if key.contains(query) { return 2 }
            if isSubsequence(query, of: key) { return 3 }
            return nil
        }.min()
    }

    private static func isSubsequence(_ query: String, of key: String) -> Bool {
        var queryIndex = query.startIndex
        for character in key {
            if character == query[queryIndex] {
                query.formIndex(after: &queryIndex)
                if queryIndex == query.endIndex { return true }
            }
        }
        return false
    }
}
