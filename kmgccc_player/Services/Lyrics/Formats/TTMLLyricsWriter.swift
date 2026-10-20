//
//  TTMLLyricsWriter.swift
//  kmgccc_player
//
//  Writes `ParsedLyrics` as the AMLL TTML profile read by MelismaKit:
//  absolute times on every element, one `<p>` per line, words as timed
//  `<span>`s, background vocals as an `x-bg` span inside the line they
//  accompany, and translation / romanization as `x-translation` / `x-roman`.
//  The document shell matches `LRCConverterService` output.
//

import Foundation

nonisolated enum TTMLLyricsWriter {
    /// Expects `ParsedLyrics.normalized()` input.
    static func ttml(from lyrics: ParsedLyrics, translationLanguage: String = "zh-CN") -> String {
        let groups = lineGroups(from: lyrics.lines)
        var xml = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:amll="http://www.example.com/ns/amll" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">"#
        // `v2` is declared as "other" so MelismaKit places duet lines on the opposite side.
        xml += #"<head><metadata><ttm:agent type="person" xml:id="v1" /><ttm:agent type="other" xml:id="v2" /></metadata></head>"#

        let begin = groups.map(\.startMs).min() ?? 0
        let end = groups.map(\.endMs).max() ?? 0
        xml += "<body dur=\"\(timestamp(end))\"><div begin=\"\(timestamp(begin))\" end=\"\(timestamp(end))\">"
        for (index, group) in groups.enumerated() {
            let agent = group.main.isDuet ? "v2" : "v1"
            xml += "<p begin=\"\(timestamp(group.startMs))\" end=\"\(timestamp(group.endMs))\" ttm:agent=\"\(agent)\" itunes:key=\"L\(index + 1)\">"
            xml += wordSpans(group.main.words)
            if let background = group.background {
                xml += #"<span ttm:role="x-bg">"#
                xml += wordSpans(background.words)
                xml += sideTextSpans(of: background, translationLanguage: translationLanguage)
                xml += "</span>"
            }
            xml += sideTextSpans(of: group.main, translationLanguage: translationLanguage)
            xml += "</p>"
        }
        xml += "</div></body></tt>"
        return xml
    }

    /// One `<p>`: a line and the background vocals that follow it.
    nonisolated private struct LineGroup {
        var main: ParsedLyrics.Line
        var background: ParsedLyrics.Line?

        var startMs: Int { min(main.startMs, background?.startMs ?? main.startMs) }
        var endMs: Int { max(main.endMs, background?.endMs ?? main.endMs) }
    }

    /// Background lines join the line before them (in source order); a background line
    /// with nothing to join is written as a line of its own. Groups are then ordered by time.
    private static func lineGroups(from lines: [ParsedLyrics.Line]) -> [LineGroup] {
        var groups: [LineGroup] = []
        for line in lines {
            if line.isBackground,
               let last = groups.indices.last,
               groups[last].background == nil,
               !groups[last].main.isBackground {
                groups[last].background = line
            } else {
                groups.append(LineGroup(main: line))
            }
        }
        return groups.enumerated()
            .sorted { lhs, rhs in
                lhs.element.startMs == rhs.element.startMs
                    ? lhs.offset < rhs.offset
                    : lhs.element.startMs < rhs.element.startMs
            }
            .map { $0.element }
    }

    private static func wordSpans(_ words: [ParsedLyrics.Word]) -> String {
        words.map { word in
            if word.isSpacing { return " " }
            return "<span begin=\"\(timestamp(word.startMs))\" end=\"\(timestamp(word.endMs))\">\(escaped(word.text))</span>"
        }.joined()
    }

    private static func sideTextSpans(of line: ParsedLyrics.Line, translationLanguage: String) -> String {
        var xml = ""
        if let translation = line.translation {
            xml += "<span ttm:role=\"x-translation\" xml:lang=\"\(translationLanguage)\">\(escaped(translation))</span>"
        }
        if let romanization = line.romanization {
            xml += "<span ttm:role=\"x-roman\">\(escaped(romanization))</span>"
        }
        return xml
    }

    /// `mm:ss.mmm`, the clock format `LRCConverterService` writes.
    static func timestamp(_ ms: Int) -> String {
        let value = max(0, ms)
        return String(format: "%02d:%02d.%03d", value / 60_000, value % 60_000 / 1_000, value % 1_000)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
