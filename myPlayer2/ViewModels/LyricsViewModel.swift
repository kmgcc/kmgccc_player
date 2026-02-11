//
//  LyricsViewModel.swift
//  myPlayer2
//
//  TrueMusic - Lyrics ViewModel
//  Manages lyrics display and sync via LyricsWebViewStore.
//

import Foundation
import SwiftUI

/// Observable ViewModel for lyrics display.
/// Now delegates all WebView communication to LyricsWebViewStore.
@Observable
@MainActor
final class LyricsViewModel {

    // MARK: - Dependencies

    private let store: LyricsWebViewStore
    private let settings: AppSettings

    // MARK: - State

    /// Current track (source of lyrics).
    private(set) var currentTrack: Track?
    private var lastAppliedTrackId: UUID?

    /// Whether lyrics are available.
    var hasLyrics: Bool {
        if let track = currentTrack {
            return (track.lyricsText != nil && !track.lyricsText!.isEmpty)
                || (track.ttmlLyricText != nil && !track.ttmlLyricText!.isEmpty)
        }
        return false
    }

    /// Whether the WebView is ready.
    var isReady: Bool {
        store.isReady
    }

    /// Callback for when user seeks via lyrics UI.
    var onSeekRequest: ((TimeInterval) -> Void)? {
        didSet {
            store.onUserSeek = onSeekRequest
        }
    }

    // MARK: - Initialization

    init(settings: AppSettings? = nil) {
        self.store = LyricsWebViewStore.shared
        self.settings = settings ?? AppSettings.shared

        // Apply initial config
        refreshConfigFromSettings()
    }

    // MARK: - Track Management

    /// Apply a new track with correct sequence (Task F).
    func applyTrack(_ track: Track?, currentTime: TimeInterval = 0, isPlaying: Bool = false) {
        currentTrack = track
        lastAppliedTrackId = track?.id

        let lyricsText = getContentForTrack(track)

        print(
            "[LyricsVM] applyTrack: \(track?.title ?? "nil"), lyricsLen: \(lyricsText.count), webViewObjectID=\(store.webViewObjectID)"
        )

        // Update config
        refreshConfigFromSettings()

        // Use store's sequenced apply
        store.applyTrack(
            ttml: lyricsText.isEmpty ? nil : lyricsText, currentTime: currentTime,
            isPlaying: isPlaying)
    }

    /// Unified AMLL state sync entrypoint.
    func ensureAMLLLoaded(
        track: Track?,
        currentTime: TimeInterval,
        isPlaying: Bool,
        reason: String,
        forceWebReload: Bool = false,
        forceLyricsReload: Bool = false
    ) {
        print(
            "[LyricsVM] ensureAMLLLoaded: reason=\(reason), trackId=\(track?.id.uuidString.prefix(8) ?? "nil"), isReady=\(store.isReady), webViewObjectID=\(store.webViewObjectID)"
        )

        if forceWebReload {
            store.forceReload()
        }

        if shouldApplyTrack(track, forceLyricsReload: forceLyricsReload) {
            applyTrack(track, currentTime: currentTime, isPlaying: isPlaying)
        } else {
            // Re-sync theme even if track hasn't changed (ensure latest palette)
            if let palette = ThemeStore.shared.palette {
                store.applyTheme(palette)
            }

            // Just sync state
            store.setPlaying(isPlaying)
            store.setCurrentTime(currentTime)
        }
    }

    private func shouldApplyTrack(_ track: Track?, forceLyricsReload: Bool) -> Bool {
        if forceLyricsReload { return true }
        return lastAppliedTrackId != track?.id
    }

    private func getContentForTrack(_ track: Track?) -> String {
        guard let track = track else { return "" }

        // Priority 1: User imported text/file
        if let t1 = track.lyricsText, !t1.isEmpty {
            return t1
        }

        // Priority 2: Embedded/pasted TTML
        if let t2 = track.ttmlLyricText, !t2.isEmpty {
            return t2
        }

        return ""
    }

    /// Clear current lyrics.
    func clearLyrics() {
        currentTrack = nil
        lastAppliedTrackId = nil
        store.setLyricsTTML("")
    }

    /// Retrieve current TTML (debug helper)
    func getCurrentTrackTTML() -> String? {
        return getContentForTrack(currentTrack)
    }

    func loadSampleLyrics() {
        if let url = Bundle.main.url(
            forResource: "sample", withExtension: "ttml", subdirectory: "AMLL"
        ) {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                print("[LyricsVM] Loaded sample.ttml: \(text.count) bytes")
                store.setLyricsTTML(text)
            } catch {
                print("[LyricsVM] Failed to load sample.ttml: \(error)")
            }
        } else {
            print("[LyricsVM] sample.ttml not found in bundle")
        }
    }

    // MARK: - Sync

    /// Sync current playback time to lyrics.
    func syncTime(_ seconds: TimeInterval) {
        store.setCurrentTime(seconds)
    }

    /// Set playback state.
    func setPlaying(_ isPlaying: Bool) {
        store.setPlaying(isPlaying)
    }

    // MARK: - Configuration

    /// Update AMLL configuration based on AppSettings.
    func refreshConfigFromSettings() {
        let resolvedScheme = ThemeStore.shared.colorScheme
        let resolvedTheme = resolvedScheme == .dark ? "dark" : "light"
        let isDarkMode = resolvedScheme == .dark

        let palette = ThemeStore.shared.palette
        let paletteMatchesScheme = palette?.scheme == resolvedScheme

        let offsetMs = max(-15000, min(15000, currentTrack?.lyricsTimeOffsetMs ?? 0))
        let mainFontFamily = cssFontFamily([
            settings.lyricsFontNameEn,
            settings.lyricsFontNameZh,
        ])
        let translationFontFamily = cssFontFamily([
            settings.lyricsTranslationFontName
        ])
        let modeWeight = isDarkMode ? settings.lyricsFontWeightDark : settings.lyricsFontWeightLight
        let clampedWeight = max(100, min(900, modeWeight))
        let translationWeight =
            isDarkMode
            ? settings.lyricsTranslationFontWeightDark : settings.lyricsTranslationFontWeightLight
        let clampedTranslationWeight = max(100, min(900, translationWeight))
        let leadInMs = max(0, settings.lyricsLeadInMs)

        let config: [String: Any] = [
            "fontSize": settings.lyricsFontSize,
            "fontWeight": clampedWeight,
            "fontFamilyMain": mainFontFamily,
            "fontFamilyTranslation": translationFontFamily,
            "translationFontSize": settings.lyricsTranslationFontSize,
            "translationFontWeight": clampedTranslationWeight,
            "leadInMs": leadInMs,
            "timeOffsetMs": offsetMs,
            "theme": resolvedTheme,
            "lineHeight": 1.5,
            "activeScale": 1.1,
            "textColor": (paletteMatchesScheme ? palette?.text : nil)
                ?? (isDarkMode ? "rgba(255,255,255,0.98)" : "rgba(0,0,0,0.9)"),
            "shadowColor": (paletteMatchesScheme ? palette?.shadow : nil)
                ?? (isDarkMode ? "rgba(0,0,0,0.2)" : "rgba(0,0,0,0.05)"),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            store.setConfigJSON(json)
        }
    }

    private func cssFontFamily(_ names: [String]) -> String {
        let sanitized =
            names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { name in
                "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
        let fallbacks = ["-apple-system", "\"Helvetica Neue\"", "sans-serif"]
        return (sanitized + fallbacks).joined(separator: ", ")
    }

    // MARK: - Dynamic Color (Moved to ThemeStore)
}
