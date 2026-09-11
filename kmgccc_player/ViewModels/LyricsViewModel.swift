//
//  LyricsViewModel.swift
//  myPlayer2
//
//  kmgccc_player - Lyrics ViewModel
//  Manages lyrics content, configuration and playback synchronization.
//

import Foundation
import NativeLyrics
import SwiftUI

/// Observable ViewModel for the main lyrics display. NativeLyrics is the
/// production path; LyricsWebViewStore is consulted only by the rollback
/// backend.
@Observable
@MainActor
final class LyricsViewModel {

    // MARK: - Dependencies

    private let settings: AppSettings
    private var playbackSourceProvider: (() -> PlaybackSource)?

    private var usesNativeRenderer: Bool {
        LyricsSurfaceManager.rendererBackend == .native
    }

    // Rollback-only compatibility store. Keep access lazy so the production
    // native path never materializes a WebView owner.
    private var store: LyricsWebViewStore {
        LyricsSurfaceManager.shared.mainStore
    }

    /// Current track (source of lyrics).
    private(set) var currentTrack: Track?
    private var lastAppliedTrackId: UUID?
    private var lastAppliedExternalLyricsIdentity: String?
    private var lastAppliedExternalLyricsSignature: String?
    /// Artwork source belonging to the lyric document currently on screen.
    /// ThemeStore holds the previous palette while a new cover is analysed;
    /// these fields let the native surface keep that confirmed palette without
    /// treating it as the new song's colour.
    private var expectedPaletteTrackID: UUID?
    private var expectedPaletteArtworkIdentity: String?
    private var expectedPaletteArtworkChecksum: UInt64 = 0
    /// Effective lyrics time offset for external playback, mirrored from the
    /// presentation's `externalLyricsTimeOffsetMs` (override ?? matched-track
    /// offset). Local playback reads `currentTrack.lyricsTimeOffsetMs` instead.
    private var externalLyricsTimeOffsetMs: Double = 0
    private var legacyLyricsMigrationTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingTrackContentTask: Task<Void, Never>?
    private var pendingTrackContentID: UUID?

    /// Whether lyrics are available.
    var hasLyrics: Bool {
        guard let track = currentTrack else { return false }
        return !getContentForTrack(track).isEmpty
    }

    /// Whether the selected renderer can accept state.
    var isReady: Bool {
        usesNativeRenderer
            ? (NativeLyricsSurfaceManager.shared.existingSurface(for: .main)?.isReady ?? true)
            : store.isReady
    }

    /// Callback for when user seeks via lyrics UI.
    var onSeekRequest: ((TimeInterval) -> Void)? {
        didSet {
            rebindSeekCallback()
        }
    }

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
    func applyTrack(
        _ track: Track?,
        currentTime: TimeInterval = 0,
        isPlaying: Bool = false,
        forceLyricsReload: Bool = false
    ) {
        pendingTrackContentTask?.cancel()
        pendingTrackContentTask = nil
        pendingTrackContentID = nil
        rebindSeekCallback()
        currentTrack = track
        lastAppliedTrackId = track?.id
        expectedPaletteTrackID = track?.id
        expectedPaletteArtworkIdentity = track?.id.uuidString
        expectedPaletteArtworkChecksum = track?.artworkData.map(ColorMath.fnv1a) ?? 0

        let lyricsText = getContentForTrack(track, currentTime: currentTime, isPlaying: isPlaying)
        let snapshotTTML = track == nil ? "" : lyricsText

        // Configuration is part of the document-install contract. Apply its
        // final font/timing/motion values before the one native lyric load.
        refreshConfigFromSettings()
        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: track?.id,
            lyricsTTML: snapshotTTML,
            currentTime: currentTime,
            isPlaying: isPlaying,
            forceLyricsReload: forceLyricsReload
        )
        Log.debug(
            "[LyricsVM] applyTrack: \(track?.title ?? "nil"), lyricsLen: \(lyricsText.count), renderer=\(usesNativeRenderer ? "native" : "webView")",
            category: .lyrics
        )

        if !usesNativeRenderer {
            // Distinguish transition nil (debounced) from concrete "no lyrics"
            // (clear immediately) on the rollback bridge.
            let ttmlForStore: String? = (track == nil) ? nil : lyricsText
            store.applyTrack(
                trackID: track?.id,
                ttml: ttmlForStore,
                currentTime: currentTime,
                isPlaying: isPlaying,
                forceLyricsReload: forceLyricsReload
            )
        }
        rebindSeekCallback()
    }

    /// Unified renderer-neutral state sync entrypoint.
    func ensureLyricsLoaded(
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
            LyricsSurfaceManager.shared.updatePlayingState(isPlaying)
            LyricsSurfaceManager.shared.updatePlaybackTime(currentTime)
            if !usesNativeRenderer {
                store.setPlaying(isPlaying)
                store.setCurrentTime(currentTime)
            }
            return
        }
        
        // 对相同状态的调用来做去重，避免同一阶段连续打印相同 debug 日志
        let trackIdStr = track?.id.uuidString.prefix(8) ?? "nil"
        let logKey = "ensureLyricsLoaded.\(reason).\(trackIdStr)"
        let shouldLog = LogStateTrackerSync.shared.checkStateChanged(key: logKey, value: "\(isPlaying).\(currentTime)")
        
        if shouldLog {
            Log.debug(
                "[LyricsVM] ensureLyricsLoaded: reason=\(reason), trackId=\(trackIdStr), isReady=\(isReady), renderer=\(usesNativeRenderer ? "native" : "webView")",
                category: .lyrics
            )
        }

        if forceWebReload && !usesNativeRenderer {
            store.forceReload(recreateWebView: recreateWebViewOnForceReload)
        }
        rebindSeekCallback()

        if shouldApplyTrack(track, forceLyricsReload: forceLyricsReload) {
            if let track, shouldLoadTrackContent(track) {
                if forceLyricsReload || pendingTrackContentID != track.id {
                    scheduleTrackContentLoad(
                        track,
                        currentTime: currentTime,
                        isPlaying: isPlaying,
                        reason: reason
                    )
                }
            } else {
                applyTrack(
                    track,
                    currentTime: currentTime,
                    isPlaying: isPlaying,
                    forceLyricsReload: forceLyricsReload
                )
            }
        } else {
            // Re-sync theme even if track hasn't changed (ensure latest palette)
            if let palette = ThemeStore.shared.palette, paletteIsReadyForCurrentDocument(palette) {
                if usesNativeRenderer {
                    LyricsSurfaceManager.shared.applyTheme(palette)
                } else {
                    store.applyTheme(palette)
                }
            }

            // Just sync state
            LyricsSurfaceManager.shared.updatePlayingState(isPlaying)
            LyricsSurfaceManager.shared.updatePlaybackTime(currentTime)
            if !usesNativeRenderer {
                store.setPlaying(isPlaying)
                store.setCurrentTime(currentTime)
            }
        }
    }

    func ensureExternalLyricsLoaded(
        presentation: NowPlayingPresentation,
        reason: String,
        forceWebReload: Bool = false,
        forceLyricsReload: Bool = false,
        recreateWebViewOnForceReload: Bool = false
    ) {
        rebindSeekCallback()
        currentTrack = presentation.localTrack
        externalLyricsTimeOffsetMs = presentation.externalLyricsTimeOffsetMs ?? 0
        expectedPaletteTrackID = presentation.artworkDisplayTrackID ?? presentation.localTrack?.id
        expectedPaletteArtworkIdentity = presentation.artworkIdentity
            ?? presentation.externalStableKey
            ?? presentation.lyricsIdentity
        expectedPaletteArtworkChecksum = presentation.artworkData.map(ColorMath.fnv1a) ?? 0
        let identity = presentation.lyricsIdentity ?? "external.empty"
        let lyricsText = LyricsFormatSupport.normalizedTTMLText(presentation.lyricsText) ?? ""
        let lyricsSignature = "\(identity):\(lyricsText.count):\(lyricsText.hashValue)"
        let trackID = presentation.localTrack?.id
        // Use the lyrics-adjusted time/play state (respects audioOutputDelay and
        // the transitioning pause) so this reload path agrees with the per-tick
        // sync path in LyricsPlaybackPipeline instead of fighting it.
        let lyricsCurrentTime = presentation.lyricsCurrentTime
        let lyricsIsPlaying = presentation.effectiveLyricsIsPlaying

        // As with local tracks, final timing/motion configuration must precede
        // the native document update.
        refreshConfigFromSettings()
        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: trackID,
            lyricsTTML: lyricsText,
            currentTime: lyricsCurrentTime,
            isPlaying: lyricsIsPlaying,
            forceLyricsReload: forceLyricsReload
        )
        Log.debug(
            "[LyricsVM] ensureExternalLyricsLoaded: reason=\(reason), identity=\(identity.prefix(16)), lyricsLen=\(lyricsText.count), renderer=\(usesNativeRenderer ? "native" : "webView")",
            category: .lyrics
        )

        if forceWebReload && !usesNativeRenderer {
            store.forceReload(recreateWebView: recreateWebViewOnForceReload)
        }
        rebindSeekCallback()

        if forceLyricsReload || lastAppliedExternalLyricsSignature != lyricsSignature {
            lastAppliedExternalLyricsIdentity = identity
            lastAppliedExternalLyricsSignature = lyricsSignature
            if !usesNativeRenderer {
                store.applyTrack(
                    trackID: trackID,
                    ttml: lyricsText,
                    currentTime: lyricsCurrentTime,
                    isPlaying: lyricsIsPlaying,
                    forceLyricsReload: forceLyricsReload
                )
            }
            rebindSeekCallback()
        } else {
            if let palette = ThemeStore.shared.palette, paletteIsReadyForCurrentDocument(palette) {
                if usesNativeRenderer {
                    LyricsSurfaceManager.shared.applyTheme(palette)
                } else {
                    store.applyTheme(palette)
                }
            }
            LyricsSurfaceManager.shared.updatePlayingState(lyricsIsPlaying)
            LyricsSurfaceManager.shared.updatePlaybackTime(lyricsCurrentTime)
            if !usesNativeRenderer {
                store.setPlaying(lyricsIsPlaying)
                store.setCurrentTime(lyricsCurrentTime)
            }
        }
    }

    /// Reconcile the external lyrics offset without forcing a full lyrics reload.
    /// The playback pipeline calls this on every sync tick; it only re-pushes the
    /// renderer config when the offset actually changes (e.g. the user edited the
    /// external override), so offset edits take effect immediately.
    func applyExternalLyricsOffset(_ ms: Double) {
        let clamped = max(-15000, min(15000, ms))
        guard abs(clamped - externalLyricsTimeOffsetMs) > 0.001 else { return }
        externalLyricsTimeOffsetMs = clamped
        refreshConfigFromSettings()
    }

    private func shouldApplyTrack(_ track: Track?, forceLyricsReload: Bool) -> Bool {
        if forceLyricsReload { return true }
        return lastAppliedTrackId != track?.id
    }

    private func shouldLoadTrackContent(_ track: Track) -> Bool {
        let hasCachedTTML = track.ttmlLyricText?.isEmpty == false
        let hasCachedLyrics = track.lyricsText?.isEmpty == false
        return !hasCachedTTML && !hasCachedLyrics
    }

    /// Prepare sidecar lyrics away from the main actor before applying a new
    /// track. A track change can be observed by both the playback pipeline and
    /// the flat lyrics driver, so this is centralized here to keep either path
    /// from falling back to synchronous String(contentsOf:) I/O.
    private func scheduleTrackContentLoad(
        _ track: Track,
        currentTime: TimeInterval,
        isPlaying: Bool,
        reason: String
    ) {
        pendingTrackContentTask?.cancel()
        pendingTrackContentID = track.id
        currentTrack = track
        let trackID = track.id

        pendingTrackContentTask = Task { @MainActor [weak self, weak track] in
            guard let track else { return }

            _ = await track.loadTTMLLyricsOffMainIfNeeded()
            _ = await track.loadLyricsOffMainIfNeeded()

            // Give the control release transaction a render opportunity before
            // The renderer receives a potentially large new lyric document.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled,
                  let self,
                  self.currentTrack?.id == trackID
            else { return }

            self.pendingTrackContentTask = nil
            self.pendingTrackContentID = nil
            self.applyTrack(
                track,
                currentTime: currentTime,
                isPlaying: isPlaying,
                forceLyricsReload: true
            )
            Log.debug(
                "[LyricsVM] applied sidecar lyrics after off-main preparation: reason=\(reason), trackId=\(trackID.uuidString.prefix(8))",
                category: .lyrics
            )
        }
    }

    private func getContentForTrack(_ track: Track?, currentTime: TimeInterval = 0, isPlaying: Bool = false) -> String {
        guard let track = track else { return "" }
        let opToken = FirstUseHitchDiagnostics.begin("LyricsVM.getContent", detail: "track=\(FirstUseHitchDiagnostics.trackIDPrefix(track.id))")
        defer { FirstUseHitchDiagnostics.end(opToken) }

        // Disk-backed content is loaded by scheduleTrackContentLoad(). This
        // method is also reached from SwiftUI body evaluation, so it must stay
        // memory-only on the main actor.
        if let t1 = LyricsFormatSupport.normalizedTTMLText(track.ttmlLyricText) {
            return t1
        }

        if let legacy = nonEmptyLyricsText(track.lyricsText) {
            if let ttml = LyricsFormatSupport.normalizedTTMLText(legacy) {
                track.ttmlLyricText = ttml
                track.lyricsText = nil
                track.lyricsFileName = nil
                return ttml
            }
            if LyricsFormatSupport.looksLikeLRC(legacy) {
                scheduleLegacyLyricsMigration(
                    for: track,
                    legacyText: legacy,
                    currentTime: currentTime,
                    isPlaying: isPlaying
                )
            }
        }

        return ""
    }

    private func scheduleLegacyLyricsMigration(
        for track: Track,
        legacyText: String,
        currentTime: TimeInterval,
        isPlaying: Bool
    ) {
        guard legacyLyricsMigrationTasks[track.id] == nil else { return }
        let trackID = track.id
        legacyLyricsMigrationTasks[trackID] = Task { @MainActor [weak self, weak track] in
            defer {
                self?.legacyLyricsMigrationTasks[trackID] = nil
            }
            do {
                let converted = try await TTMLConverter.shared.convertToTTML(rawLyrics: legacyText, stripMetadata: true)
                guard let ttml = LyricsFormatSupport.normalizedTTMLText(converted) else {
                    Log.warning("[LyricsVM] Legacy LRC conversion produced invalid TTML", category: .lyrics)
                    return
                }
                guard let self, let track, track.id == trackID else { return }
                track.ttmlLyricText = ttml
                track.lyricsText = nil
                track.lyricsFileName = nil
                if self.currentTrack?.id == trackID {
                    self.applyTrack(
                        track,
                        currentTime: currentTime,
                        isPlaying: isPlaying,
                        forceLyricsReload: true
                    )
                }
            } catch {
                Log.warning("[LyricsVM] Legacy LRC conversion failed: \(error.localizedDescription)", category: .lyrics)
            }
        }
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
        expectedPaletteTrackID = nil
        expectedPaletteArtworkIdentity = nil
        expectedPaletteArtworkChecksum = 0
        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: nil,
            lyricsTTML: "",
            currentTime: 0,
            isPlaying: false
        )
        if !usesNativeRenderer {
            store.setLyricsTTML("")
        }
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
                if usesNativeRenderer {
                    LyricsSurfaceManager.shared.updatePlaybackSnapshot(
                        trackID: nil,
                        lyricsTTML: text,
                        currentTime: 0,
                        isPlaying: false,
                        forceLyricsReload: true
                    )
                } else {
                    store.setLyricsTTML(text)
                }
            } catch {
                print("[LyricsVM] Failed to load sample.ttml: \(error)")
            }
        } else {
            print("[LyricsVM] sample.ttml not found in bundle")
        }
    }

    // MARK: - Sync

    /// Sync current playback time to lyrics.
    func syncTime(_ seconds: TimeInterval, force: Bool = false) {
        rebindSeekCallback()
        LyricsSurfaceManager.shared.updatePlaybackTime(seconds, force: force)
        if !usesNativeRenderer {
            store.setCurrentTime(seconds, force: force)
        }
    }

    func revealExistingLyrics(reason: String) {
        rebindSeekCallback()
        if usesNativeRenderer {
            NativeLyricsSurfaceManager.shared.followCurrentLyrics(for: .main)
        } else {
            let targetStore = store
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                targetStore.revealExistingLyrics(reason: reason)
            }
        }
    }

    /// Set playback state.
    func setPlaying(_ isPlaying: Bool) {
        rebindSeekCallback()
        LyricsSurfaceManager.shared.updatePlayingState(isPlaying)
        if !usesNativeRenderer {
            store.setPlaying(isPlaying)
        }
    }

    private func rebindSeekCallback() {
        if usesNativeRenderer {
            NativeLyricsSurfaceManager.shared.setSeekHandler(onSeekRequest, for: .main)
        } else {
            store.onUserSeek = onSeekRequest
        }
    }

    // MARK: - Configuration

    /// Update lyric-renderer configuration based on AppSettings.
    func refreshConfigFromSettings() {
        let surfaceRole = LyricsSurfaceRole.main
        let resolvedScheme = ThemeStore.shared.colorScheme
        let resolvedTheme = resolvedScheme == .dark ? "dark" : "light"
        let isDarkMode = resolvedScheme == .dark

        let palette = ThemeStore.shared.palette
        let paletteMatchesScheme = palette?.scheme == resolvedScheme
        let paletteIsReady = paletteMatchesScheme
            && palette.map(paletteIsReadyForCurrentDocument) == true

        let playbackSource = playbackSourceProvider?() ?? .local
        let overlay = LyricsRuntimeOverlayResolver.overlay(
            context: .mainPanel,
            playbackSource: playbackSource
        )

        // External playback carries its own effective offset on the presentation
        // (override ?? matched-track offset); local playback reads the track's
        // stored offset. Reading the local track's offset for external playback
        // silently dropped the user's override offset.
        let rawTrackOffsetMs = playbackSource.isExternal
            ? externalLyricsTimeOffsetMs
            : (currentTrack?.lyricsTimeOffsetMs ?? 0)
        let trackOffsetMs = max(-15000, min(15000, rawTrackOffsetMs))
        let effectiveGlobalAdvanceMs = max(
            -5000,
            min(5000, settings.lyricsGlobalAdvanceMs + overlay.globalAdvanceDeltaMs)
        )
        let combinedOffsetMs = max(-20000, min(20000, trackOffsetMs - effectiveGlobalAdvanceMs))
        let mainFontFamily = LyricsFontResolver.cssMainFontFamily(
            english: settings.lyricsFontNameEn,
            chinese: settings.lyricsFontNameZh
        )
        let translationFontFamily = LyricsFontResolver.cssFontFamily([
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
        let springSettings = settings.lyricSpringUserSettings

        let config: [String: Any] = [
            "fontSize": settings.lyricsFontSize,
            "fontWeight": clampedWeight,
            "fontFamilyMain": mainFontFamily,
            // Keep the legacy CSS family list for the rollback WebView, but
            // expose script-specific families to NativeLyrics. A single CSS
            // list cannot preserve independent CJK/Latin settings.
            "fontFamilyLatin": settings.lyricsFontNameEn,
            "fontFamilyCJK": settings.lyricsFontNameZh,
            "fontFamilyTranslation": translationFontFamily,
            "translationFontSize": settings.lyricsTranslationFontSize,
            "translationFontWeight": clampedTranslationWeight,
            "leadInMs": leadInMs,
            "nearSwitchGapMs": nearSwitchGapMs,
            "timeOffsetMs": combinedOffsetMs,
            "seekTimeOffsetMs": trackOffsetMs,
            "theme": resolvedTheme,
            "renderScale": surfaceRole.renderScale,
            "enableBlur": surfaceRole.enableBlur,
            "enableSpring": surfaceRole.enableSpring,
            "springDuration": springSettings.duration,
            "springBounce": springSettings.bounce,
            "fpsCap": surfaceRole.fpsCap,
            "overscanPx": surfaceRole.overscanPx,
            "wordFadeWidth": surfaceRole.wordFadeWidth,
            "wordHighlightMode": settings.amllDiscreteWordHighlightEnabled ? "discrete" : "smooth",
            "lineHeight": 1.5,
            "activeScale": surfaceRole.activeScale,
            "textColor": (paletteIsReady ? palette?.text : nil)
                ?? (isDarkMode ? "rgba(255,255,255,0.98)" : "rgba(0,0,0,0.9)"),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            LyricsSurfaceManager.shared.updateSurfaceConfigSnapshot(json, for: surfaceRole)
            if !usesNativeRenderer {
                store.setConfigJSON(json)
                store.scheduleDebugVisibleLayerProbe(label: "main-config", delay: 0.75)
            }
        }

        let nativeConfiguration = NativeLyricsConfigurationMapper.makeWindowConfiguration(
            settings: settings,
            palette: paletteIsReady ? palette : nil,
            playbackSource: playbackSource,
            currentTrack: currentTrack,
            lyricsTimeOffsetMs: rawTrackOffsetMs,
            role: .main
        )
        var resolvedNativeConfiguration = nativeConfiguration
        if !paletteIsReady,
           paletteMatchesScheme,
           let existing = NativeLyricsSurfaceManager.shared.configuration(for: .main) {
            // Preserve the last confirmed palette while artwork extraction is
            // pending. A scheme change intentionally uses fresh mapper
            // defaults until ThemeStore publishes the new scheme palette.
            resolvedNativeConfiguration.palette = existing.palette
        }
        if usesNativeRenderer {
            NativeLyricsSurfaceManager.shared.applyConfiguration(resolvedNativeConfiguration, for: .main)
        }
    }

    /// ThemeStore publishes palette metadata only after artwork extraction is
    /// complete. Match the current scheme and source identity before a palette
    /// is allowed to replace the lyric surface's confirmed colours.
    private func paletteIsReadyForCurrentDocument(_ palette: ThemePalette) -> Bool {
        guard palette.scheme == ThemeStore.shared.colorScheme else { return false }
        if expectedPaletteArtworkChecksum != 0 {
            return ThemeStore.shared.paletteMatches(
                trackID: expectedPaletteTrackID,
                artworkIdentity: expectedPaletteArtworkIdentity,
                artworkChecksum: expectedPaletteArtworkChecksum
            )
        }
        if let expectedPaletteTrackID {
            return ThemeStore.shared.paletteTrackID == expectedPaletteTrackID
        }
        if let expectedPaletteArtworkIdentity,
           !expectedPaletteArtworkIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ThemeStore.shared.paletteArtworkIdentity == expectedPaletteArtworkIdentity
        }
        return ThemeStore.shared.paletteMatches(
            trackID: nil,
            artworkIdentity: nil,
            artworkChecksum: 0
        )
    }

    // MARK: - Dynamic Color (Moved to ThemeStore)
}
