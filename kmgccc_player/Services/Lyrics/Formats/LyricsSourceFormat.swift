//
//  LyricsSourceFormat.swift
//  kmgccc_player
//
//  Lyric formats accepted from local files and how to recognize them from
//  their content. File extensions are unreliable (A2 and plain LRC share
//  `.lrc`, tag lyrics have none), so detection never depends on them.
//

import Foundation

nonisolated enum LyricsSourceFormat: String, Sendable {
    case ttml
    /// Line-synced LRC, including LDDC-style `[time]word[time]word` lines.
    case lrc
    /// Enhanced LRC with `<time>` word tags.
    case lrcA2
    case yrc
    case qrc
    case lys
    case lyl
    case lqe

    /// Signatures overlap, so formats are tried in this order:
    /// A2 lines are also LRC lines, and LYL lines look like QRC lines without word tags.
    static let detectionOrder: [LyricsSourceFormat] = [.ttml, .lqe, .yrc, .qrc, .lys, .lyl, .lrcA2, .lrc]

    static func detect(in text: String) -> LyricsSourceFormat? {
        detectionOrder.first { $0.matches(text) }
    }

    /// Whether the text carries any time tag at all. Separates an unknown timed
    /// format from plain, unsynced lyrics.
    static func containsTimeTags(_ text: String) -> Bool {
        anyTimeTag.matches(text)
    }

    private func matches(_ text: String) -> Bool {
        switch self {
        case .ttml: LyricsFormatSupport.looksLikeTTML(text)
        case .lrc: Self.lrcSignature.matches(text)
        case .lrcA2: Self.lrcA2Signature.matches(text)
        case .yrc: Self.yrcSignature.matches(text)
        case .qrc: text.contains("LyricContent=") || Self.qrcSignature.matches(text)
        case .lys: Self.lysSignature.matches(text)
        case .lyl: Self.lylSignature.matches(text)
        case .lqe: Self.lqeSignature.matches(text)
        }
    }

    private static let lrcTag = #"\["# + LyricsTimestamp.lrcTimePattern + #"\]"#
    private static let lrcSignature = LyricsPattern(#"(?m)^\s*"# + lrcTag)
    private static let lrcA2Signature = LyricsPattern(
        #"(?m)^\s*"# + lrcTag + #".*<"# + LyricsTimestamp.lrcTimePattern + #">"#
    )
    private static let yrcSignature = LyricsPattern(#"(?m)^\s*\[\d+,\d+\]\s*\(\d+,\d+,\d+\)"#)
    private static let qrcSignature = LyricsPattern(#"(?m)^\s*\[\d+,\d+\].*\(\d+,\d+\)"#)
    private static let lysSignature = LyricsPattern(#"(?m)^\s*\[\d\].*\(\d+,\d+\)"#)
    private static let lylSignature = LyricsPattern(#"(?m)^\s*\[(?:type:LyricifyLines|\d+,\d+)\]"#)
    private static let lqeSignature = LyricsPattern(#"(?m)^\s*\[(?:Lyricify Quick Export|lyrics:\s*format@)"#)
    private static let anyTimeTag = LyricsPattern(
        lrcTag + #"|<"# + LyricsTimestamp.lrcTimePattern + #">|\[\d+,\d+\]|\(\d+,\d+(?:,\d+)?\)"#
    )
}
