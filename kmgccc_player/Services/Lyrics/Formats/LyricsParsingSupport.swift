//
//  LyricsParsingSupport.swift
//  kmgccc_player
//
//  Shared helpers for the local lyric parsers: a Sendable regex wrapper and
//  LRC-style timestamp parsing.
//

import Foundation

/// A compiled pattern that can live in a static constant of a nonisolated parser.
nonisolated struct LyricsPattern: Sendable {
    nonisolated enum Token: Equatable, Sendable {
        case text(String)
        /// Capture groups of a match; index 0 is the whole match.
        case match([String])
    }

    private let regex: NSRegularExpression

    /// Patterns are source constants, so an invalid one is a programming error.
    init(_ pattern: String) {
        regex = try! NSRegularExpression(pattern: pattern)
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: fullRange(of: text)) != nil
    }

    /// Capture groups of the first match. Groups that did not participate are empty strings.
    func firstMatch(in text: String) -> [String]? {
        regex.firstMatch(in: text, options: [], range: fullRange(of: text))
            .map { captures($0, in: text) }
    }

    /// The text split into alternating plain segments and matches, in source order.
    func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, options: [], range: fullRange(of: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                tokens.append(.text(String(text[cursor..<range.lowerBound])))
            }
            tokens.append(.match(captures(match, in: text)))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            tokens.append(.text(String(text[cursor...])))
        }
        return tokens
    }

    func replacingMatches(in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, options: [], range: fullRange(of: text), withTemplate: template)
    }

    private func fullRange(of text: String) -> NSRange {
        NSRange(text.startIndex..., in: text)
    }

    private func captures(_ match: NSTextCheckingResult, in text: String) -> [String] {
        (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

nonisolated enum LyricsTimestamp {
    /// A line-timed text such as `[01:02.34]text`.
    nonisolated struct TimedText: Equatable, Sendable {
        var ms: Int
        var text: String
    }

    /// Body of an LRC time tag: `mm:ss`, `mm:ss.xx` or `mm:ss,xxx`.
    static let lrcTimePattern = #"\d+:\d{1,2}(?:[.,]\d+)?"#

    private static let leadingLineTag = LyricsPattern(#"^\[("# + lrcTimePattern + #")\]"#)
    private static let offsetTag = LyricsPattern(#"(?im)^\s*\[offset:\s*([+-]?\d+)\s*\]"#)

    /// Parses `mm:ss(.fff)` or `hh:mm:ss(.fff)` into milliseconds.
    static func milliseconds(from text: String) -> Int? {
        let components = text.replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var seconds = 0.0
        for component in components {
            guard let value = Double(component), value.isFinite, value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return Int((seconds * 1000).rounded())
    }

    /// Strips every leading `[mm:ss.xx]` tag of a line, returning their times and the rest of the line.
    static func leadingLineTimes(of line: String) -> (times: [Int], rest: String) {
        var rest = Substring(line)
        var times: [Int] = []
        while let match = leadingLineTag.firstMatch(in: String(rest)),
              let ms = milliseconds(from: match[1]) {
            times.append(ms)
            rest = rest.dropFirst(match[0].count)
        }
        return (times, String(rest))
    }

    /// Line-timed texts of an LRC document; a line with several tags yields one entry per tag.
    static func lineTimedTexts(in text: String) -> [TimedText] {
        text.components(separatedBy: .newlines).flatMap { rawLine -> [TimedText] in
            let (times, rest) = leadingLineTimes(of: rawLine.trimmingCharacters(in: .whitespaces))
            let content = rest.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return [] }
            return times.map { TimedText(ms: $0, text: content) }
        }
    }

    /// The `[offset:±ms]` tag of an LRC document. A positive offset shows lyrics earlier.
    static func lrcOffsetMs(in text: String) -> Int {
        offsetTag.firstMatch(in: text).flatMap { Int($0[1]) } ?? 0
    }
}

/// Words written as `text(start,duration)`, shared by QRC and Lyricify Syllable.
nonisolated enum TrailingTimedWords {
    private static let timeTag = LyricsPattern(#"\((\d+),(\d+)\)"#)

    /// Text after the last time tag has no timing and is dropped.
    static func parse(_ content: String) -> [ParsedLyrics.Word] {
        var words: [ParsedLyrics.Word] = []
        var pendingText = ""
        for token in timeTag.tokens(in: content) {
            switch token {
            case .text(let text):
                pendingText = text
            case .match(let groups):
                if !pendingText.isEmpty, let start = Int(groups[1]), let duration = Int(groups[2]) {
                    words.append(ParsedLyrics.Word(text: pendingText, startMs: start, endMs: start + duration))
                }
                pendingText = ""
            }
        }
        return words
    }
}
