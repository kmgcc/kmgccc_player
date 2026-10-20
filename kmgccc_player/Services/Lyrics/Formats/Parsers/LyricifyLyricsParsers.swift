//
//  LyricifyLyricsParsers.swift
//  kmgccc_player
//
//  The Lyricify family: Syllable (LYS), Lines (LYL) and Quick Export (LQE).
//  Ported from AMLL packages/lyric formats/lys.ts, lyl.ts and lqe.ts
//  (AGPL-3.0-only).
//

import Foundation

/// Word-timed lines prefixed with a property digit.
///
///     [4]Lately (358,1336)I've (1694,487)been(2181,673)
///
/// Property 0–2 infers background vocals from parentheses, 3–5 marks a lead
/// line and 6–8 a background line; a value of 2 modulo 3 marks a duet line.
nonisolated enum LYSLyricsParser {
    private static let propertyTag = LyricsPattern(#"^\[(\d+)\]"#)

    static func parse(_ text: String) -> ParsedLyrics {
        ParsedLyrics(lines: text.components(separatedBy: .newlines).compactMap(parseLine))
    }

    private static func parseLine(_ rawLine: String) -> ParsedLyrics.Line? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard let tag = propertyTag.firstMatch(in: trimmed), let rawProperty = Int(tag[1]) else { return nil }
        let words = TrailingTimedWords.parse(String(trimmed.dropFirst(tag[0].count)))
        guard let first = words.first, let last = words.last else { return nil }

        let property = (0...8).contains(rawProperty) ? rawProperty : 0
        var line = ParsedLyrics.Line(words: words, startMs: first.startMs, endMs: last.endMs)
        line.isDuet = property % 3 == 2
        switch property {
        case 0...2:
            line.extractBackgroundParentheses()
        case 6...8:
            line.extractBackgroundParentheses(knownBackground: true)
        default:
            break
        }
        return line
    }
}

/// Line-timed lyrics with explicit start and end.
///
///     [type:LyricifyLines]
///     [54260,57380]Stop and stare
nonisolated enum LYLLyricsParser {
    private static let timedLine = LyricsPattern(#"^\[(\d+),(\d+)\](.*)$"#)

    static func parse(_ text: String) -> ParsedLyrics {
        ParsedLyrics(lines: text.components(separatedBy: .newlines).compactMap(parseLine))
    }

    private static func parseLine(_ rawLine: String) -> ParsedLyrics.Line? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard let match = timedLine.firstMatch(in: trimmed),
              let start = Int(match[1]),
              let end = Int(match[2]) else { return nil }

        let word = ParsedLyrics.Word(text: match[3], startMs: start, endMs: end)
        var line = ParsedLyrics.Line(words: [word], startMs: start, endMs: end)
        line.extractBackgroundParentheses()
        line.words[0].text = line.words[0].text.trimmingCharacters(in: .whitespaces)
        return line
    }
}

/// A container whose `lyrics` section is LYS and whose `translation` and
/// `pronunciation` sections are line-timed LRC.
///
///     [Lyricify Quick Export]
///     [lyrics: format@Lyricify Syllable]
///     [4]A(365,350)ni(715,307)
///     [translation: format@LRC]
///     [00:00.365]不生亦不灭
nonisolated enum LQELyricsParser {
    private static let sectionHeader = LyricsPattern(#"^\[([A-Za-z]+):.+\]$"#)

    static func parse(_ text: String) -> ParsedLyrics {
        let sections = sections(in: text)
        guard let lyricLines = sections["lyrics"] else { return ParsedLyrics(lines: []) }

        var lyrics = LYSLyricsParser.parse(lyricLines.joined(separator: "\n"))
        if let translation = sections["translation"] {
            lyrics.attach(LyricsTimestamp.lineTimedTexts(in: translation.joined(separator: "\n")), as: .translation)
        }
        if let pronunciation = sections["pronunciation"] {
            lyrics.attach(LyricsTimestamp.lineTimedTexts(in: pronunciation.joined(separator: "\n")), as: .romanization)
        }
        return lyrics
    }

    /// Lines grouped under their lowercased `[name: …]` header.
    private static func sections(in text: String) -> [String: [String]] {
        var sections: [String: [String]] = [:]
        var currentSection: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let header = sectionHeader.firstMatch(in: line) {
                currentSection = header[1].lowercased()
                continue
            }
            if let currentSection {
                sections[currentSection, default: []].append(line)
            }
        }
        return sections
    }
}
