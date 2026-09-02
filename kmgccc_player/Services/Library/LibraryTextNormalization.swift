import Foundation

/// Shared string-level canonicalization for library identity fields.
///
/// This type deliberately has no Track/SwiftData dependency so persistence
/// sidecars and structured credits can use exactly the same rules in
/// lightweight test targets and background indexers.
nonisolated enum LibraryTextNormalization {
    static let unknownArtist = "未知歌手"

    static func normalize(_ value: String?, fallback: String) -> String {
        comparisonKey(display(value, fallback: fallback))
    }

    static func display(_ value: String?, fallback: String) -> String {
        let collapsed = collapsedWhitespace(value)
        return collapsed.isEmpty ? fallback : collapsed
    }

    static func collapsedWhitespace(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func comparisonKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}
