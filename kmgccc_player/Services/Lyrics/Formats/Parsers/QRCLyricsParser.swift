//
//  QRCLyricsParser.swift
//  kmgccc_player
//
//  QQ Music word-timed lyrics. Ported from AMLL packages/lyric formats/qrc.ts
//  (AGPL-3.0-only); also accepts the decrypted `<QrcInfos>` XML container.
//
//  [190871,1984]For (190871,361)the (191232,172)first (191404,376)
//

import Foundation

nonisolated enum QRCLyricsParser {
    private static let lineTag = LyricsPattern(#"^\[(\d+),(\d+)\]"#)
    private static let xmlLyricContent = LyricsPattern(#"(?s)LyricContent="(.*?)"\s*/>"#)

    static func parse(_ text: String) -> ParsedLyrics {
        ParsedLyrics(lines: unwrappedContent(of: text).components(separatedBy: .newlines).compactMap(parseLine))
    }

    private static func parseLine(_ rawLine: String) -> ParsedLyrics.Line? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard let tag = lineTag.firstMatch(in: trimmed),
              let start = Int(tag[1]),
              let duration = Int(tag[2]) else { return nil }
        let words = TrailingTimedWords.parse(String(trimmed.dropFirst(tag[0].count)))
        guard !words.isEmpty else { return nil }

        var line = ParsedLyrics.Line(words: words, startMs: start, endMs: start + duration)
        line.extractBackgroundParentheses()
        return line
    }

    /// QQ Music stores QRC inside `<Lyric_1 LyricContent="…"/>`.
    private static func unwrappedContent(of text: String) -> String {
        guard let match = xmlLyricContent.firstMatch(in: text) else { return text }
        return match[1]
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
