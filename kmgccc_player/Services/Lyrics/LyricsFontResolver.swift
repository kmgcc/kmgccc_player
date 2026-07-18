//
//  LyricsFontResolver.swift
//  myPlayer2
//
//  Shared font defaults and CSS family ordering for lyric surfaces.
//

import Foundation

enum LyricsFontDefaults {
    /// Inter is bundled with the app so this family is available even when the
    /// host Mac does not have it installed.
    static let english = "Inter"

    /// This is the CoreText family name used by macOS for the Simplified
    /// Chinese PingFang family.
    static let chinese = "PingFang SC"
    static let translation = chinese

    /// Decorative families supplied by recent Chinese macOS releases. They
    /// are intentionally not bundled; the app only bundles the open-source
    /// English fallback above.
    static let skinChinese = "LingWai SC"
    static let skinEnglish = "LingWai SC"
    static let skinTranslation = "HanziPen SC"

    /// Font used by the previous defaults. Only exact matches are migrated,
    /// leaving other user-selected families alone.
    static let legacySystemDefault = "SF Pro Text"
}

enum LyricsFontResolver {
    /// Build the main lyric stack with the English family first. Inter is a
    /// guaranteed English-capable fallback placed before the Chinese family,
    /// so a Chinese font's bundled Latin glyphs cannot take over when a
    /// user-selected English family is missing on the current Mac.
    static func cssMainFontFamily(english: String, chinese: String) -> String {
        cssFontFamily([english, LyricsFontDefaults.english, chinese])
    }

    static func cssFontFamily(_ names: [String]) -> String {
        var seen = Set<String>()
        let sanitized = names.compactMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let identity = trimmed.lowercased()
            guard seen.insert(identity).inserted else { return nil }

            let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        return (
            sanitized
            + ["-apple-system", "\"Helvetica Neue\"", "sans-serif"]
        ).joined(separator: ", ")
    }
}
