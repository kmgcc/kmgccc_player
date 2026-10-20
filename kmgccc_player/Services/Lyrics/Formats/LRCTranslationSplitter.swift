//
//  LRCTranslationSplitter.swift
//  kmgccc_player
//
//  Many LRC exports (NetEase, QQ Music, lyric tools) write the translation
//  as a second line with the same timestamp as the original:
//
//      [00:12.34]Original line
//      [00:12.34]译文
//
//  This splits such a file into an original and a translation LRC so both
//  can go through the regular translation matching.
//

import Foundation

nonisolated enum LRCTranslationSplitter {
    nonisolated struct Split: Equatable, Sendable {
        var original: String
        var translation: String?
    }

    private static let inlineTimeTags = LyricsPattern(
        #"\["# + LyricsTimestamp.lrcTimePattern + #"\]|<"# + LyricsTimestamp.lrcTimePattern + #">"#
    )

    /// Splits only when no timestamp carries three or more lines and at least half of
    /// them come in pairs, so an occasional shared timestamp in ordinary lyrics is left
    /// alone. Within a pair the first line is the original. Lines without a timestamp
    /// (`[offset:]` and other tags) are kept in both outputs.
    static func split(_ lrc: String) -> Split {
        let rawLines = lrc.components(separatedBy: .newlines)
        var lineIndexesByTime: [Int: [Int]] = [:]
        var untimedIndexes: Set<Int> = []
        for (index, rawLine) in rawLines.enumerated() {
            let (times, rest) = LyricsTimestamp.leadingLineTimes(of: rawLine.trimmingCharacters(in: .whitespaces))
            guard let firstTime = times.first else {
                untimedIndexes.insert(index)
                continue
            }
            guard !visibleText(of: rest).isEmpty else { continue }
            lineIndexesByTime[firstTime, default: []].append(index)
        }

        let groups = Array(lineIndexesByTime.values)
        let pairs = groups.filter { $0.count == 2 }
        guard pairs.count >= 2,
              pairs.count * 2 >= groups.count,
              groups.allSatisfy({ $0.count <= 2 }) else {
            return Split(original: lrc, translation: nil)
        }

        let translationIndexes = Set(pairs.map { $0[1] })
        var original: [String] = []
        var translation: [String] = []
        for (index, rawLine) in rawLines.enumerated() {
            if translationIndexes.contains(index) {
                translation.append(rawLine)
            } else {
                original.append(rawLine)
                if untimedIndexes.contains(index) { translation.append(rawLine) }
            }
        }
        return Split(original: original.joined(separator: "\n"), translation: translation.joined(separator: "\n"))
    }

    private static func visibleText(of lineContent: String) -> String {
        inlineTimeTags.replacingMatches(in: lineContent, with: "").trimmingCharacters(in: .whitespaces)
    }
}
