//
//  LyricsTTMLConverter.swift
//  kmgccc_player
//
//  Single entry point that turns lyric text in any supported local format
//  into validated TTML, the only lyric format the app stores.
//
//  Plain LRC keeps going through `LRCConverterService`, whose credit
//  stripping, placeholder detection, interlude timing and translation
//  matching are tuned for real-world LRC. Every other format is parsed into
//  `ParsedLyrics` and written by `TTMLLyricsWriter`.
//
//  Adding a format: add a case to `LyricsSourceFormat` with its signature,
//  write a parser that returns `ParsedLyrics`, and route it below.
//

import Foundation

nonisolated enum LyricsConversionError: LocalizedError, Equatable, Sendable {
    case emptyText
    case unreadableFile
    case unreadableEncoding
    case unrecognizedFormat
    case missingTimeline
    case noLyricLines
    case instrumentalPlaceholder
    case invalidTTML(String)

    var errorDescription: String? {
        switch self {
        case .emptyText: "歌词为空"
        case .unreadableFile: "无法读取歌词文件"
        case .unreadableEncoding: "无法识别文件编码"
        case .unrecognizedFormat: "无法识别歌词格式"
        case .missingTimeline: "歌词缺少时间轴"
        case .noLyricLines: "没有可用歌词"
        case .instrumentalPlaceholder: "这是纯音乐的占位歌词"
        case .invalidTTML(let message): message
        }
    }
}

nonisolated enum LyricsTTMLConverter {
    static func ttml(from text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LyricsConversionError.emptyText }
        guard let format = LyricsSourceFormat.detect(in: trimmed) else {
            throw LyricsSourceFormat.containsTimeTags(trimmed)
                ? LyricsConversionError.unrecognizedFormat
                : LyricsConversionError.missingTimeline
        }

        let candidate: String
        switch format {
        case .ttml:
            candidate = trimmed
        case .lrc:
            candidate = try await ttmlFromLineSyncedLRC(trimmed)
        case .lrcA2:
            candidate = try writtenTTML(lrcA2Lyrics(trimmed))
        case .yrc:
            candidate = try writtenTTML(YRCLyricsParser.parse(trimmed))
        case .qrc:
            candidate = try writtenTTML(QRCLyricsParser.parse(trimmed))
        case .lys:
            candidate = try writtenTTML(LYSLyricsParser.parse(trimmed))
        case .lyl:
            candidate = try writtenTTML(LYLLyricsParser.parse(trimmed))
        case .lqe:
            candidate = try writtenTTML(LQELyricsParser.parse(trimmed))
        }

        let validation = LyricsFormatSupport.validateTTML(candidate)
        if let message = validation.message {
            throw LyricsConversionError.invalidTTML(message)
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writtenTTML(_ lyrics: ParsedLyrics) throws -> String {
        let normalized = lyrics.normalized()
        guard !normalized.lines.isEmpty else { throw LyricsConversionError.noLyricLines }
        return TTMLLyricsWriter.ttml(from: normalized)
    }

    private static func lrcA2Lyrics(_ text: String) -> ParsedLyrics {
        let split = LRCTranslationSplitter.split(text)
        var lyrics = LRCA2LyricsParser.parse(split.original)
        if let translation = split.translation {
            lyrics.attach(LyricsTimestamp.lineTimedTexts(in: translation), as: .translation)
        }
        return lyrics.shifted(byMs: -LyricsTimestamp.lrcOffsetMs(in: text))
    }

    private static func ttmlFromLineSyncedLRC(_ text: String) async throws -> String {
        let split = LRCTranslationSplitter.split(text)
        do {
            if let translation = split.translation {
                return try await LRCConverterService.shared.convertToTTMLWithTranslation(
                    origContent: split.original,
                    transContent: translation,
                    applyOffsetTag: true
                )
            }
            return try await LRCConverterService.shared.convertToTTML(lrcContent: text, applyOffsetTag: true)
        } catch LRCConversionError.instrumentalPlaceholderLyrics {
            throw LyricsConversionError.instrumentalPlaceholder
        } catch {
            throw LyricsConversionError.noLyricLines
        }
    }
}
