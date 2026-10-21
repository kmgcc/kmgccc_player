//
//  LRCA2LyricsParser.swift
//  kmgccc_player
//
//  Enhanced LRC (A2) with word timing. Ported from AMLL packages/lyric
//  formats/lrca2.ts (AGPL-3.0-only).
//
//  [02:38.850]<02:38.850>Words <02:39.030>are <02:39.120>made<02:39.360>
//

import Foundation

nonisolated enum LRCA2LyricsParser {
    private static let lineTag = LyricsPattern(#"^\[("# + LyricsTimestamp.lrcTimePattern + #")\]"#)
    private static let wordTag = LyricsPattern(#"<("# + LyricsTimestamp.lrcTimePattern + #")>"#)

    /// Lines without word tags become a single line-timed word. `[offset:]` is
    /// left to the caller so side texts can still be matched on the original times.
    static func parse(_ text: String) -> ParsedLyrics {
        var lines: [ParsedLyrics.Line] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard let tag = lineTag.firstMatch(in: trimmed),
                  let lineStart = LyricsTimestamp.milliseconds(from: tag[1]) else { continue }
            let words = words(in: String(trimmed.dropFirst(tag[0].count)), lineStart: lineStart)
            guard let lastTimedWord = words.last(where: { !$0.isSpacing }) else { continue }
            lines.append(ParsedLyrics.Line(words: words, startMs: lineStart, endMs: lastTimedWord.endMs))
        }
        return ParsedLyrics(lines: lines)
    }

    /// Each text segment runs from the time tag before it to the time tag after it.
    private static func words(in content: String, lineStart: Int) -> [ParsedLyrics.Word] {
        let tokens = wordTag.tokens(in: content)
        func time(at index: Int) -> Int? {
            guard tokens.indices.contains(index), case .match(let groups) = tokens[index] else { return nil }
            return LyricsTimestamp.milliseconds(from: groups[1])
        }

        var words: [ParsedLyrics.Word] = []
        func appendSpacing(at ms: Int) {
            guard let last = words.last, !last.isSpacing else { return }
            words.append(.spacing(at: ms))
        }

        for (index, token) in tokens.enumerated() {
            guard case .text(let raw) = token else { continue }
            let start = time(at: index - 1) ?? lineStart
            let end = time(at: index + 1) ?? start
            if raw.first?.isWhitespace == true { appendSpacing(at: start) }
            let text = raw.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                words.append(ParsedLyrics.Word(text: text, startMs: start, endMs: end))
            }
            if raw.last?.isWhitespace == true { appendSpacing(at: end) }
        }
        return words
    }
}
