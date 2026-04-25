//
//  LyricsViewModel.swift
//  myPlayer2
//
//  kmgccc_player - Lyrics ViewModel
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

    private let settings: AppSettings
    private var playbackSourceProvider: (() -> PlaybackSource)?

    // Don't cache store reference - always get from LyricsSurfaceManager
    // This ensures we always use the current active store after surface switches
    private var store: LyricsWebViewStore {
        LyricsSurfaceManager.shared.mainStore
    }

    // MARK: - State

    /// Current track (source of lyrics).
    private(set) var currentTrack: Track?
    private var lastAppliedTrackId: UUID?
    private var lastAppliedExternalLyricsIdentity: String?
    private var lastAppliedExternalLyricsSignature: String?

    /// Whether lyrics are available.
    var hasLyrics: Bool {
        guard let track = currentTrack else { return false }
        return !getContentForTrack(track).isEmpty
    }

    /// Whether the WebView is ready.
    var isReady: Bool {
        store.isReady
    }

    var webViewStore: LyricsWebViewStore {
        // Always get the current store from LyricsSurfaceManager
        // This ensures we get the correct store even after surface switches
        LyricsSurfaceManager.shared.mainStore
    }

    /// Callback for when user seeks via lyrics UI.
    var onSeekRequest: ((TimeInterval) -> Void)? {
        didSet {
            rebindSeekCallback()
        }
    }

    // MARK: - Initialization

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings.shared

        // Apply initial config
        refreshConfigFromSettings()
    }

    /// Bind a runtime playback source provider so config can apply source-specific overlays.
    /// Must not persist any overlay back to settings.
    func setPlaybackSourceProvider(_ provider: @escaping () -> PlaybackSource) {
        playbackSourceProvider = provider
        refreshConfigFromSettings()
    }

    // MARK: - Track Management

    /// Apply a new track with correct sequence (Task F).
    func applyTrack(_ track: Track?, currentTime: TimeInterval = 0, isPlaying: Bool = false) {
        rebindSeekCallback()
        currentTrack = track
        lastAppliedTrackId = track?.id

        let lyricsText = getContentForTrack(track)
        let snapshotTTML = track == nil ? "" : lyricsText
        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: track?.id,
            lyricsTTML: snapshotTTML,
            currentTime: currentTime,
            isPlaying: isPlaying
        )

        // 使用统一日志系统，LyricsWebViewStore 也会打印 applyTrack 日志
        Log.debug("[LyricsVM] applyTrack: \(track?.title ?? "nil"), lyricsLen: \(lyricsText.count), webViewObjectID=\(store.webViewObjectID)", category: .lyrics)

        // Update config
        refreshConfigFromSettings()

        // Use store's sequenced apply
        // Distinguish transition nil (debounced) from concrete "no lyrics" (clear immediately).
        let ttmlForStore: String? = (track == nil) ? nil : lyricsText
        store.applyTrack(
            trackID: track?.id,
            ttml: ttmlForStore,
            currentTime: currentTime,
            isPlaying: isPlaying)
        rebindSeekCallback()
    }

    /// Unified AMLL state sync entrypoint.
    func ensureAMLLLoaded(
        track: Track?,
        currentTime: TimeInterval,
        isPlaying: Bool,
        reason: String,
        forceWebReload: Bool = false,
        forceLyricsReload: Bool = false,
        recreateWebViewOnForceReload: Bool = false
    ) {
        // 短路：如果 track 为 nil 且已经处理过 nil，避免重复空转
        if track == nil && lastAppliedTrackId == nil && !forceLyricsReload {
            rebindSeekCallback()
            // 仅同步必要的播放状态，不做重复歌词应用
            LyricsSurfaceManager.shared.updatePlaybackTime(currentTime)
            LyricsSurfaceManager.shared.updatePlayingState(isPlaying)
            store.setPlaying(isPlaying)
            store.setCurrentTime(currentTime)
            return
        }
        
        // 对相同状态的调用来做去重，避免同一阶段连续打印相同 debug 日志
        let trackIdStr = track?.id.uuidString.prefix(8) ?? "nil"
        let logKey = "ensureAMLLLoaded.\(reason).\(trackIdStr)"
        let shouldLog = LogStateTrackerSync.shared.checkStateChanged(key: logKey, value: "\(isPlaying).\(currentTime)")
        
        if shouldLog {
            Log.debug("[LyricsVM] ensureAMLLLoaded: reason=\(reason), trackId=\(trackIdStr), isReady=\(store.isReady), webViewObjectID=\(store.webViewObjectID)", category: .lyrics)
        }

        if forceWebReload {
            store.forceReload(recreateWebView: recreateWebViewOnForceReload)
        }
        rebindSeekCallback()

        if shouldApplyTrack(track, forceLyricsReload: forceLyricsReload) {
            applyTrack(track, currentTime: currentTime, isPlaying: isPlaying)
        } else {
            // Re-sync theme even if track hasn't changed (ensure latest palette)
            if let palette = ThemeStore.shared.palette {
                store.applyTheme(palette)
            }

            // Just sync state
            LyricsSurfaceManager.shared.updatePlaybackTime(currentTime)
            LyricsSurfaceManager.shared.updatePlayingState(isPlaying)
            store.setPlaying(isPlaying)
            store.setCurrentTime(currentTime)
        }
    }

    func ensureExternalAMLLLoaded(
        presentation: NowPlayingPresentation,
        reason: String,
        forceWebReload: Bool = false,
        forceLyricsReload: Bool = false,
        recreateWebViewOnForceReload: Bool = false
    ) {
        rebindSeekCallback()
        currentTrack = presentation.localTrack
        let identity = presentation.lyricsIdentity ?? "external.empty"
        let lyricsText = presentation.lyricsText ?? ""
        let lyricsSignature = "\(identity):\(lyricsText.count):\(lyricsText.hashValue)"
        let trackID = presentation.localTrack?.id

        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: trackID,
            lyricsTTML: lyricsText,
            currentTime: presentation.currentTime,
            isPlaying: presentation.isPlaying
        )

        Log.debug(
            "[LyricsVM] ensureExternalAMLLLoaded: reason=\(reason), identity=\(identity.prefix(16)), lyricsLen=\(lyricsText.count), webViewObjectID=\(store.webViewObjectID)",
            category: .lyrics
        )

        refreshConfigFromSettings()

        if forceWebReload {
            store.forceReload(recreateWebView: recreateWebViewOnForceReload)
        }
        rebindSeekCallback()

        if forceLyricsReload || lastAppliedExternalLyricsSignature != lyricsSignature {
            lastAppliedExternalLyricsIdentity = identity
            lastAppliedExternalLyricsSignature = lyricsSignature
            store.applyTrack(
                trackID: trackID,
                ttml: lyricsText,
                currentTime: presentation.currentTime,
                isPlaying: presentation.isPlaying
            )
            rebindSeekCallback()
        } else {
            if let palette = ThemeStore.shared.palette {
                store.applyTheme(palette)
            }
            LyricsSurfaceManager.shared.updatePlaybackTime(presentation.currentTime)
            LyricsSurfaceManager.shared.updatePlayingState(presentation.isPlaying)
            store.setPlaying(presentation.isPlaying)
            store.setCurrentTime(presentation.currentTime)
        }
    }

    private func shouldApplyTrack(_ track: Track?, forceLyricsReload: Bool) -> Bool {
        if forceLyricsReload { return true }
        return lastAppliedTrackId != track?.id
    }

    private func getContentForTrack(_ track: Track?) -> String {
        guard let track = track else { return "" }

        // Priority 1: User imported text/file
        if let t1 = nonEmptyLyricsText(track.lyricsText) {
            return t1
        }

        // Priority 2: Embedded/pasted TTML
        if let t2 = nonEmptyLyricsText(track.ttmlLyricText) {
            return t2
        }

        return ""
    }

    private func nonEmptyLyricsText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// Clear current lyrics.
    func clearLyrics() {
        rebindSeekCallback()
        currentTrack = nil
        lastAppliedTrackId = nil
        lastAppliedExternalLyricsIdentity = nil
        lastAppliedExternalLyricsSignature = nil
        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: nil,
            lyricsTTML: "",
            currentTime: 0,
            isPlaying: false
        )
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
        rebindSeekCallback()
        LyricsSurfaceManager.shared.updatePlaybackTime(seconds)
        store.setCurrentTime(seconds)
    }

    /// Set playback state.
    func setPlaying(_ isPlaying: Bool) {
        rebindSeekCallback()
        LyricsSurfaceManager.shared.updatePlayingState(isPlaying)
        store.setPlaying(isPlaying)
    }

    private func rebindSeekCallback() {
        store.onUserSeek = onSeekRequest
    }

    // MARK: - Configuration

    /// Update AMLL configuration based on AppSettings.
    func refreshConfigFromSettings() {
        let surfaceRole = LyricsSurfaceRole(rawValue: store.role) ?? .main
        let resolvedScheme = ThemeStore.shared.colorScheme
        let resolvedTheme = resolvedScheme == .dark ? "dark" : "light"
        let isDarkMode = resolvedScheme == .dark

        let palette = ThemeStore.shared.palette
        let paletteMatchesScheme = palette?.scheme == resolvedScheme

        let playbackSource = playbackSourceProvider?() ?? .local
        let overlay = LyricsRuntimeOverlayResolver.overlay(
            context: .mainPanel,
            playbackSource: playbackSource
        )

        let trackOffsetMs = max(-15000, min(15000, currentTrack?.lyricsTimeOffsetMs ?? 0))
        let effectiveGlobalAdvanceMs = max(
            -5000,
            min(5000, settings.lyricsGlobalAdvanceMs + overlay.globalAdvanceDeltaMs)
        )
        let combinedOffsetMs = max(-20000, min(20000, trackOffsetMs - effectiveGlobalAdvanceMs))
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
        let nearSwitchGapMs = max(0, min(500, settings.lyricsNearSwitchGapMs))

        let config: [String: Any] = [
            "fontSize": settings.lyricsFontSize,
            "fontWeight": clampedWeight,
            "fontFamilyMain": mainFontFamily,
            "fontFamilyTranslation": translationFontFamily,
            "translationFontSize": settings.lyricsTranslationFontSize,
            "translationFontWeight": clampedTranslationWeight,
            "leadInMs": leadInMs,
            "nearSwitchGapMs": nearSwitchGapMs,
            "timeOffsetMs": combinedOffsetMs,
            "theme": resolvedTheme,
            "renderScale": surfaceRole.renderScale,
            "enableBlur": surfaceRole.enableBlur,
            "enableSpring": surfaceRole.enableSpring,
            "fpsCap": surfaceRole.fpsCap,
            "overscanPx": surfaceRole.overscanPx,
            "wordFadeWidth": surfaceRole.wordFadeWidth,
            "lineHeight": 1.5,
            "activeScale": surfaceRole.activeScale,
            "textColor": (paletteMatchesScheme ? palette?.text : nil)
                ?? (isDarkMode ? "rgba(255,255,255,0.98)" : "rgba(0,0,0,0.9)"),
            "shadowColor": "rgba(0,0,0,0)",
        ]

        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            LyricsSurfaceManager.shared.updateSurfaceConfigSnapshot(json, for: surfaceRole)
            store.setConfigJSON(json)
            if surfaceRole == .main {
                store.scheduleDebugVisibleLayerProbe(label: "main-config", delay: 0.75)
            }
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
