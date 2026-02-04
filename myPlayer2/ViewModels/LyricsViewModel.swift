//
//  LyricsViewModel.swift
//  myPlayer2
//
//  TrueMusic - Lyrics ViewModel
//  Manages lyrics display and sync.
//

import AppKit
import Foundation

/// Observable ViewModel for lyrics display.
/// Bridges track lyrics data with AMLL bridge service.
@Observable
@MainActor
final class LyricsViewModel {

    // MARK: - Dependencies

    /// The real lyrics bridge (exposed for view binding).
    let bridge: LyricsBridge

    private let settings: AppSettings

    // MARK: - State

    /// Current track (source of lyrics).
    private(set) var currentTrack: Track?
    private var cachedColorTrackId: UUID?
    private var cachedTextColor: String?
    private var cachedShadowColor: String?

    /// Whether lyrics are available.
    var hasLyrics: Bool {
        if let track = currentTrack {
            return (track.lyricsText != nil && !track.lyricsText!.isEmpty)
                || (track.ttmlLyricText != nil && !track.ttmlLyricText!.isEmpty)
        }
        return false
    }

    /// Callback for when user seeks via lyrics UI.
    var onSeekRequest: ((TimeInterval) -> Void)?

    // MARK: - Initialization

    init(
        bridgeService: LyricsBridgeServiceProtocol? = nil,
        settings: AppSettings = .shared
    ) {
        self.bridge = LyricsBridge()
        self.settings = settings

        // Set up seek callback
        bridge.onUserSeek = { [weak self] time in
            self?.onSeekRequest?(time)
        }

        // Apply initial config
        refreshConfigFromSettings()
    }

    // MARK: - Track Management

    /// Apply a new track (loads its lyrics).
    func applyTrack(_ track: Track?) {
        currentTrack = track

        let lyricsText = getContentForTrack(track)

        print("[LyricsVM] applyTrack: \(track?.title ?? "nil"), lyricsLen: \(lyricsText.count)")
        bridge.setLyricsTTML(lyricsText)
        refreshConfigFromSettings()
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
        bridge.setLyricsTTML("")
    }

    /// Retrieve current TTML (debug helper)
    func getCurrentTrackTTML() -> String? {
        return getContentForTrack(currentTrack)
    }

    func loadSampleLyrics() {
        // Load sample.ttml from bundle
        if let url = Bundle.main.url(
            forResource: "sample", withExtension: "ttml", subdirectory: "AMLL")
        {
            do {
                let text = try String(contentsOf: url)
                print("[LyricsVM] Loaded sample.ttml: \(text.count) bytes")
                bridge.setLyricsTTML(text)
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
        bridge.setCurrentTime(seconds)
    }

    /// Set playback state.
    func setPlaying(_ isPlaying: Bool) {
        bridge.setPlaying(isPlaying)
    }

    // MARK: - Configuration

    /// Update AMLL configuration based on AppSettings.
    func refreshConfigFromSettings() {
        let isDarkMode = resolveIsDarkMode()
        let colors = resolveDynamicColors(isDarkMode: isDarkMode)
        let config: [String: Any] = [
            "fontSize": settings.lyricsFontSize,
            "theme": settings.appearance,
            "lineHeight": 1.5,
            "activeScale": 1.1,
            "textColor": colors?.text ?? (isDarkMode ? "rgba(255,255,255,0.98)" : "rgba(0,0,0,0.9)"),
            "shadowColor": colors?.shadow ?? (isDarkMode ? "rgba(0,0,0,0.2)" : "rgba(0,0,0,0.05)"),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            bridge.setConfigJSON(json)
        }
    }

    // MARK: - Dynamic Color

    private func resolveIsDarkMode() -> Bool {
        switch settings.appearance {
        case "dark":
            return true
        case "light":
            return false
        default:
            if let match = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
                return match == .darkAqua
            }
            return false
        }
    }

    private func resolveDynamicColors(isDarkMode: Bool) -> (
        text: String, shadow: String
    )? {
        guard let track = currentTrack, let artwork = track.artworkData else {
            cachedColorTrackId = nil
            cachedTextColor = nil
            cachedShadowColor = nil
            return nil
        }

        if cachedColorTrackId == track.id,
            let cachedTextColor,
            let cachedShadowColor
        {
            return (cachedTextColor, cachedShadowColor)
        }

        guard let baseColor = ArtworkColorExtractor.averageColor(from: artwork) else {
            return nil
        }

        let adjusted = ArtworkColorExtractor.adjustedAccent(from: baseColor, isDarkMode: isDarkMode)
        let textColor = ArtworkColorExtractor.cssRGBA(adjusted, alpha: isDarkMode ? 0.98 : 0.9)
        let shadow = isDarkMode ? "rgba(0,0,0,0.2)" : "rgba(0,0,0,0.05)"

        cachedColorTrackId = track.id
        cachedTextColor = textColor
        cachedShadowColor = shadow

        return (textColor, shadow)
    }
}
