//
//  LyricsEditorInput.swift
//  kmgccc_player
//
//  Rules for the lyric text box shared by the single and batch track editors.
//  Pasted lyrics in any supported format are converted to TTML in place;
//  until that has happened the text cannot be saved, because saving stores
//  only TTML and would otherwise clear the track's lyrics.
//

import Foundation

nonisolated enum LyricsEditorInput {
    nonisolated enum Review: Equatable, Sendable {
        /// Empty, or already valid TTML.
        case accepted
        /// Other lyric text, converted; the editor should replace its text with this TTML.
        case converted(String)
        /// Text that cannot become TTML, with the reason to show.
        case rejected(String)
    }

    /// Whether the text still has to go through `review` before it can be saved.
    static func needsConversion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !LyricsFormatSupport.looksLikeTTML(trimmed)
    }

    /// Why the text cannot be saved as it stands, or nil when it can.
    static func saveIssue(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if LyricsFormatSupport.looksLikeTTML(trimmed) {
            return LyricsFormatSupport.validateTTML(trimmed).message
        }
        return "歌词尚未转换为 TTML"
    }

    /// Validates TTML or converts other lyric text, off the main actor.
    static func review(_ text: String) async -> Review {
        await Task.detached(priority: .userInitiated) { () async -> Review in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .accepted }
            if LyricsFormatSupport.looksLikeTTML(trimmed) {
                return LyricsFormatSupport.validateTTML(trimmed).message.map(Review.rejected) ?? .accepted
            }
            do {
                return .converted(try await LyricsTTMLConverter.ttml(from: trimmed))
            } catch {
                return .rejected(error.localizedDescription)
            }
        }.value
    }
}
