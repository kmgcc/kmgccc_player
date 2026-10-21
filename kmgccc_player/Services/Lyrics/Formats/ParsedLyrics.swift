//
//  ParsedLyrics.swift
//  kmgccc_player
//
//  Format-neutral lyric model shared by the local lyric parsers. Each source
//  format is parsed into this shape, normalized once, and written to TTML by
//  `TTMLLyricsWriter`, so a new format only needs a parser.
//
//  The model follows the AMLL lyric package (applemusic-like-lyrics,
//  packages/lyric, AGPL-3.0-only). Times are milliseconds.
//

import Foundation

nonisolated struct ParsedLyrics: Equatable, Sendable {
    nonisolated struct Word: Equatable, Sendable {
        var text: String
        var startMs: Int
        var endMs: Int

        /// Whitespace between timed words; written as plain text, its times are ignored.
        var isSpacing: Bool { text.allSatisfy(\.isWhitespace) }

        static func spacing(at ms: Int) -> Word {
            Word(text: " ", startMs: ms, endMs: ms)
        }
    }

    nonisolated struct Line: Equatable, Sendable {
        var words: [Word]
        var startMs: Int
        var endMs: Int
        var translation: String?
        var romanization: String?
        /// Background vocals; written into the preceding line as an `x-bg` span.
        var isBackground = false
        /// Right-aligned duet line; written with the `v2` agent.
        var isDuet = false

        var text: String { words.map(\.text).joined() }
    }

    nonisolated enum SideText: Sendable {
        case translation
        case romanization
    }

    var lines: [Line]
}

nonisolated extension ParsedLyrics {
    /// Lines that carry no usable end (line-timed sources) are shown until the next line,
    /// or for this long when they are the last line.
    static let fallbackLastLineDurationMs = 4_000

    /// Attaches line-timed side texts to the lines that start at the same time, in order.
    mutating func attach(_ entries: [LyricsTimestamp.TimedText], as side: SideText) {
        var pendingByTime = Dictionary(grouping: entries, by: \.ms)
        for index in lines.indices {
            guard var pending = pendingByTime[lines[index].startMs], !pending.isEmpty else { continue }
            let text = pending.removeFirst().text
            pendingByTime[lines[index].startMs] = pending
            switch side {
            case .translation: lines[index].translation = text
            case .romanization: lines[index].romanization = text
            }
        }
    }

    func shifted(byMs delta: Int) -> ParsedLyrics {
        guard delta != 0 else { return self }
        var result = self
        for lineIndex in result.lines.indices {
            result.lines[lineIndex].startMs += delta
            result.lines[lineIndex].endMs += delta
            for wordIndex in result.lines[lineIndex].words.indices {
                result.lines[lineIndex].words[wordIndex].startMs += delta
                result.lines[lineIndex].words[wordIndex].endMs += delta
            }
        }
        return result
    }

    /// Lyrics ready for TTML: empty lines dropped, negative or inverted times repaired,
    /// line ranges widened to cover their words, and missing line ends filled in.
    func normalized() -> ParsedLyrics {
        var result = lines.compactMap(Self.normalizedLine)
        for index in result.indices where result[index].endMs <= result[index].startMs {
            let start = result[index].startMs
            let nextStart = result[(index + 1)...].first { $0.startMs > start }?.startMs
            result[index].endMs = nextStart ?? start + Self.fallbackLastLineDurationMs
            // A line-timed source stores the whole line as one zero-length word.
            if result[index].words.count == 1 {
                result[index].words[0].endMs = result[index].endMs
            }
        }
        return ParsedLyrics(lines: result)
    }

    private static func normalizedLine(_ source: Line) -> Line? {
        var line = source
        line.words = line.words.filter { !$0.text.isEmpty }.map { word in
            var word = word
            word.startMs = max(0, word.startMs)
            word.endMs = max(word.startMs, word.endMs)
            return word
        }
        while line.words.first?.isSpacing == true { line.words.removeFirst() }
        while line.words.last?.isSpacing == true { line.words.removeLast() }

        let timedWords = line.words.filter { !$0.isSpacing }
        guard let firstStart = timedWords.map(\.startMs).min(),
              let lastEnd = timedWords.map(\.endMs).max() else { return nil }
        line.startMs = min(max(0, line.startMs), firstStart)
        line.endMs = max(line.endMs, lastEnd)
        line.translation = nonEmpty(line.translation)
        line.romanization = nonEmpty(line.romanization)
        return line
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

nonisolated extension ParsedLyrics.Line {
    /// YRC, QRC, LYS and LYL mark background vocals by wrapping the whole line in
    /// parentheses. Strips them, marks the line, and returns whether it was a background line.
    ///
    /// A line already known to be background (LYS properties 6–8) has each parenthesis
    /// stripped where present: exporters often drop the closing one after the last time tag.
    @discardableResult
    mutating func extractBackgroundParentheses(knownBackground: Bool = false) -> Bool {
        let opening: Set<Character> = ["(", "（"]
        let closing: Set<Character> = [")", "）"]
        guard let firstIndex = words.firstIndex(where: { !$0.isSpacing }),
              let lastIndex = words.lastIndex(where: { !$0.isSpacing }) else { return false }

        let firstText = words[firstIndex].text
        let lastText = words[lastIndex].text
        var open = firstText.firstIndex { !$0.isWhitespace }
        if let index = open, !opening.contains(firstText[index]) { open = nil }
        var close = lastText.lastIndex { !$0.isWhitespace }
        if let index = close, !closing.contains(lastText[index]) { close = nil }
        guard knownBackground || (open != nil && close != nil) else { return false }

        func removing(_ removed: [String.Index?], from text: String) -> String {
            String(text.indices.filter { !removed.contains($0) }.map { text[$0] })
        }
        if firstIndex == lastIndex {
            words[firstIndex].text = removing([open, close], from: firstText)
        } else {
            words[firstIndex].text = removing([open], from: firstText)
            words[lastIndex].text = removing([close], from: lastText)
        }
        isBackground = true
        return true
    }
}
