//
//  YRCLyricsParser.swift
//  kmgccc_player
//
//  NetEase Cloud Music word-timed lyrics. Ported from AMLL packages/lyric
//  formats/yrc.ts (AGPL-3.0-only).
//
//  [190871,1984](190871,361,0)For (191232,172,0)the (191404,376,0)first
//

import Foundation

nonisolated enum YRCLyricsParser {
    private static let lineTag = LyricsPattern(#"^\[(\d+),(\d+)\]"#)
    private static let wordTag = LyricsPattern(#"\((\d+),(\d+),\d+\)"#)

    /// Lines that do not start with `[start,duration]`, such as the JSON credit
    /// lines NetEase prepends, are ignored.
    static func parse(_ text: String) -> ParsedLyrics {
        ParsedLyrics(lines: text.components(separatedBy: .newlines).compactMap(parseLine))
    }

    private static func parseLine(_ rawLine: String) -> ParsedLyrics.Line? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard let tag = lineTag.firstMatch(in: trimmed),
              let start = Int(tag[1]),
              let duration = Int(tag[2]) else { return nil }

        // Text after a time tag belongs to that tag.
        var words: [ParsedLyrics.Word] = []
        var currentTiming: (start: Int, end: Int)?
        for token in wordTag.tokens(in: String(trimmed.dropFirst(tag[0].count))) {
            switch token {
            case .match(let groups):
                if let wordStart = Int(groups[1]), let wordDuration = Int(groups[2]) {
                    currentTiming = (wordStart, wordStart + wordDuration)
                } else {
                    currentTiming = nil
                }
            case .text(let text):
                guard let timing = currentTiming else { continue }
                words.append(ParsedLyrics.Word(text: text, startMs: timing.start, endMs: timing.end))
            }
        }
        guard !words.isEmpty else { return nil }

        var line = ParsedLyrics.Line(words: words, startMs: start, endMs: start + duration)
        line.extractBackgroundParentheses()
        return line
    }
}
