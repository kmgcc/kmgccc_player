//
//  LyricsSurfaceManager.swift
//  myPlayer2
//
//  kmgccc_player - Coordinates the native lyrics surfaces.
//

import Foundation
import MelismaKit

/// Coordinates the app-owned lyric surfaces while keeping MelismaKit as the
/// only lyrics renderer. The manager retains playback/configuration snapshots
/// so a lazily-created fullscreen or preview surface can be initialized from
/// the same state without a second rendering backend.
@MainActor
final class LyricsSurfaceManager {

    private struct PlaybackSnapshot {
        var trackID: UUID?
        var lyricsTTML: String
        var lyricsHash: String
        var currentTime: Double
        var isPlaying: Bool

        static let empty = PlaybackSnapshot(
            trackID: nil,
            lyricsTTML: "",
            lyricsHash: LyricsSurfaceManager.hashLyrics(""),
            currentTime: 0,
            isPlaying: false
        )
    }

    private struct SurfaceSnapshot {
        var configJSON: String?
        var configTrackID: UUID?
        var isConfigTrackGuarded: Bool
        var themeOverridePalette: ThemePalette?
        var themeOverrideTrackID: UUID?
        var isThemeOverrideTrackGuarded: Bool

        init(
            configJSON: String? = nil,
            configTrackID: UUID? = nil,
            isConfigTrackGuarded: Bool = false,
            themeOverridePalette: ThemePalette? = nil,
            themeOverrideTrackID: UUID? = nil,
            isThemeOverrideTrackGuarded: Bool = false
        ) {
            self.configJSON = configJSON
            self.configTrackID = configTrackID
            self.isConfigTrackGuarded = isConfigTrackGuarded
            self.themeOverridePalette = themeOverridePalette
            self.themeOverrideTrackID = themeOverrideTrackID
            self.isThemeOverrideTrackGuarded = isThemeOverrideTrackGuarded
        }
    }

    static let shared = LyricsSurfaceManager()

    private var activeRoles: Set<LyricsSurfaceRole> = []
    private var currentPlaybackSnapshot: PlaybackSnapshot = .empty
    private var isPlaybackTimePreviewActive = false
    private var surfaceSnapshots: [LyricsSurfaceRole: SurfaceSnapshot] = [:]
    private var baseThemePalette: ThemePalette?

    enum TargetMode {
        case main
        case fullscreen
    }
    private(set) var targetMode: TargetMode = .main

    enum CurrentMode {
        case none
        case main
        case fullscreen
    }
    private(set) var currentMode: CurrentMode = .none

    private(set) var switchGeneration = 0

    enum SwitchState {
        case idle
        case active
    }
    private(set) var switchState: SwitchState = .idle

    private init() {}

    var activeSurfaceDescription: String {
        guard !activeRoles.isEmpty else { return "none" }
        return activeRoles.map(\.rawValue).sorted().joined(separator: ",")
    }

    // MARK: - Surface visibility

    func requestMode(_ mode: TargetMode, onComplete: ((TargetMode, Int) -> Void)? = nil) {
        let desiredMode: CurrentMode = mode == .main ? .main : .fullscreen
        guard targetMode != mode || currentMode != desiredMode || switchState != .idle else {
            return
        }

        switchGeneration += 1
        targetMode = mode
        currentMode = desiredMode
        switchState = .active

        switch mode {
        case .main:
            activeRoles.insert(.main)
            activeRoles.remove(.fullscreen)
            activeRoles.remove(.fullscreenCoverBlurHighlight)
            NativeLyricsSurfaceManager.shared.activate(role: .main)
            NativeLyricsSurfaceManager.shared.deactivate(role: .fullscreen)
            NativeLyricsSurfaceManager.shared.deactivate(role: .fullscreenCoverBlurHighlight)
        case .fullscreen:
            activeRoles.insert(.fullscreen)
            activeRoles.remove(.main)
            NativeLyricsSurfaceManager.shared.activate(role: .fullscreen)
            NativeLyricsSurfaceManager.shared.deactivate(role: .main)
        }

        switchState = .idle
        onComplete?(mode, switchGeneration)
    }

    func reportMainVisible(_ visible: Bool) {
        if visible {
            guard targetMode != .fullscreen || currentMode != .fullscreen else { return }
            targetMode = .main
            currentMode = .main
            switchState = .idle
            activeRoles.insert(.main)
            activeRoles.remove(.fullscreen)
            activeRoles.remove(.fullscreenCoverBlurHighlight)
            NativeLyricsSurfaceManager.shared.activate(role: .main)
            NativeLyricsSurfaceManager.shared.deactivate(role: .fullscreen)
            NativeLyricsSurfaceManager.shared.deactivate(role: .fullscreenCoverBlurHighlight)
        } else {
            activeRoles.remove(.main)
            NativeLyricsSurfaceManager.shared.deactivate(role: .main)
        }
    }

    func reportFullscreenVisible(_ visible: Bool) {
        if visible {
            targetMode = .fullscreen
            currentMode = .fullscreen
            switchState = .idle
            activeRoles.insert(.fullscreen)
            activeRoles.remove(.main)
            NativeLyricsSurfaceManager.shared.activate(role: .fullscreen)
            NativeLyricsSurfaceManager.shared.deactivate(role: .main)
        } else {
            activeRoles.remove(.fullscreen)
            NativeLyricsSurfaceManager.shared.deactivate(role: .fullscreen)
            if targetMode == .fullscreen {
                requestMode(.main)
            }
        }
    }

    var isFullscreenActive: Bool { currentMode == .fullscreen }

    func hasReadySurface(for role: LyricsSurfaceRole) -> Bool {
        NativeLyricsSurfaceManager.shared.existingSurface(for: role)?.isReady == true
    }

    func activate(role: LyricsSurfaceRole) {
        activeRoles.insert(role)
        NativeLyricsSurfaceManager.shared.activate(role: role)
    }

    func deactivate(role: LyricsSurfaceRole) {
        activeRoles.remove(role)
        NativeLyricsSurfaceManager.shared.deactivate(role: role)
    }

    /// Kept as named lifecycle hooks for the fullscreen coordinator. Native
    /// surfaces are paused/deactivated here; no legacy renderer is created.
    func teardownMainStore() {
        deactivate(role: .main)
    }

    func teardownFullscreenStores() {
        deactivate(role: .fullscreen)
        deactivate(role: .fullscreenCoverBlurHighlight)
    }

    // MARK: - Playback and configuration

    func applyTrack(
        trackID: UUID? = nil,
        ttml: String?,
        currentTime: Double,
        isPlaying: Bool,
        forceLyricsReload: Bool = false
    ) {
        updatePlaybackSnapshot(
            trackID: trackID,
            lyricsTTML: ttml ?? "",
            currentTime: currentTime,
            isPlaying: isPlaying,
            forceLyricsReload: forceLyricsReload
        )
    }

    func applyTheme(_ palette: ThemePalette) {
        baseThemePalette = palette
        NativeLyricsSurfaceManager.shared.applyTheme(palette)

        // Reapply track-scoped fullscreen skin overrides after the global
        // palette changes. The config snapshot is also replayed because it
        // contains line-timing colors that are not part of ThemePalette.
        for (role, snapshot) in surfaceSnapshots {
            let trackMatches = !snapshot.isThemeOverrideTrackGuarded
                || snapshot.themeOverrideTrackID == currentPlaybackSnapshot.trackID
            guard trackMatches else { continue }

            if let override = snapshot.themeOverridePalette {
                NativeLyricsSurfaceManager.shared.applyPalette(override, for: role)
            }

            let configMatches = !snapshot.isConfigTrackGuarded
                || snapshot.configTrackID == currentPlaybackSnapshot.trackID
            if configMatches, let json = snapshot.configJSON {
                NativeLyricsSurfaceManager.shared.applyConfigurationJSON(json, for: role)
                if role == .main {
                    NativeLyricsSurfaceManager.shared.applyPalette(palette, for: role)
                }
            }
        }
    }

    func updatePlaybackSnapshot(
        trackID: UUID?,
        lyricsTTML: String,
        currentTime: Double,
        isPlaying: Bool,
        forceLyricsReload: Bool = false
    ) {
        let normalizedTime = currentTime.isFinite ? max(0, currentTime) : currentPlaybackSnapshot.currentTime
        let lyricsHash = Self.hashLyrics(lyricsTTML)
        let previous = currentPlaybackSnapshot
        currentPlaybackSnapshot = PlaybackSnapshot(
            trackID: trackID,
            lyricsTTML: lyricsTTML,
            lyricsHash: lyricsHash,
            currentTime: normalizedTime,
            isPlaying: isPlaying
        )
        NativeLyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: trackID,
            lyricsTTML: lyricsTTML,
            currentTime: normalizedTime,
            isPlaying: isPlaying,
            forceLyricsReload: forceLyricsReload
        )
        currentPlaybackSnapshot.currentTime = NativeLyricsSurfaceManager.shared.currentPlaybackTime

        if previous.trackID != trackID || previous.lyricsHash != lyricsHash {
            Log.debug(
                "LyricsSurfaceManager: snapshot track=\(trackID?.uuidString.prefix(8) ?? "nil"), lyricsLen=\(lyricsTTML.count), playing=\(isPlaying)",
                category: .lyrics
            )
        }
    }

    func updatePlaybackTime(_ currentTime: Double, force: Bool = false) {
        guard currentTime.isFinite, !isPlaybackTimePreviewActive else { return }
        NativeLyricsSurfaceManager.shared.updatePlaybackTime(currentTime, force: force)
        currentPlaybackSnapshot.currentTime = NativeLyricsSurfaceManager.shared.currentPlaybackTime
    }

    func updatePlayingState(_ isPlaying: Bool) {
        currentPlaybackSnapshot.isPlaying = isPlaying
        guard !isPlaybackTimePreviewActive else { return }
        NativeLyricsSurfaceManager.shared.updatePlayingState(isPlaying)
        currentPlaybackSnapshot.currentTime = NativeLyricsSurfaceManager.shared.currentPlaybackTime
    }

    func beginPlaybackTimePreview(at time: Double, isPlaying: Bool) {
        guard time.isFinite else { return }
        let normalized = max(0, time)
        isPlaybackTimePreviewActive = true
        currentPlaybackSnapshot.currentTime = normalized
        currentPlaybackSnapshot.isPlaying = isPlaying
        NativeLyricsSurfaceManager.shared.updatePlayingState(false)
        NativeLyricsSurfaceManager.shared.updatePlaybackTime(normalized, force: true, motion: .preview)
    }

    func updatePlaybackTimePreview(_ time: Double) {
        guard time.isFinite else { return }
        guard isPlaybackTimePreviewActive else {
            updatePlaybackTime(time, force: true)
            return
        }
        let normalized = max(0, time)
        currentPlaybackSnapshot.currentTime = normalized
        NativeLyricsSurfaceManager.shared.updatePlaybackTime(normalized, force: true, motion: .preview)
    }

    func endPlaybackTimePreview(at time: Double, isPlaying: Bool) {
        guard time.isFinite else { return }
        let normalized = max(0, time)
        isPlaybackTimePreviewActive = false
        currentPlaybackSnapshot.currentTime = normalized
        currentPlaybackSnapshot.isPlaying = isPlaying
        NativeLyricsSurfaceManager.shared.updatePlaybackTime(normalized, force: true, motion: .preview)
        NativeLyricsSurfaceManager.shared.updatePlayingState(isPlaying)
    }

    func updateSurfaceConfigSnapshot(
        _ json: String,
        for role: LyricsSurfaceRole,
        trackID: UUID? = nil,
        trackGuarded: Bool = false
    ) {
        var snapshot = surfaceSnapshots[role] ?? SurfaceSnapshot()
        snapshot.configJSON = json
        snapshot.configTrackID = trackID
        snapshot.isConfigTrackGuarded = trackGuarded
        surfaceSnapshots[role] = snapshot
    }

    func updateThemeOverrideSnapshot(
        _ palette: ThemePalette?,
        for role: LyricsSurfaceRole,
        trackID: UUID? = nil,
        trackGuarded: Bool = false
    ) {
        var snapshot = surfaceSnapshots[role] ?? SurfaceSnapshot()
        snapshot.themeOverridePalette = palette
        snapshot.themeOverrideTrackID = trackID
        snapshot.isThemeOverrideTrackGuarded = trackGuarded
        surfaceSnapshots[role] = snapshot
    }

    func shutdownAll() {
        NativeLyricsSurfaceManager.shared.shutdownAll()
        activeRoles.removeAll()
        currentPlaybackSnapshot = .empty
        isPlaybackTimePreviewActive = false
        surfaceSnapshots.removeAll()
        baseThemePalette = nil
        targetMode = .main
        currentMode = .none
        switchGeneration = 0
        switchState = .idle
    }
}
extension LyricsSurfaceManager {
    private static func hashLyrics(_ text: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    func isActive(_ role: LyricsSurfaceRole) -> Bool {
        activeRoles.contains(role) || NativeLyricsSurfaceManager.shared.isActive(role)
    }
}
