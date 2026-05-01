//
//  LyricsSurfaceManager.swift
//  myPlayer2
//
//  kmgccc_player - Manages WebView instances for different lyrics surfaces
//  Provides isolated WebViews per surface role with unified lifecycle.
//

import CryptoKit
import Foundation
import SwiftUI
import WebKit

/// Manages WebView instances for different lyrics surface roles.
/// Each independent role gets its own WebView to avoid contention.
/// Implements mutual exclusivity: main and fullscreen stores cannot be active simultaneously.
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
        var configJSON: String? = nil
        var configTrackID: UUID? = nil
        var isConfigTrackGuarded: Bool = false
        var themeOverridePalette: ThemePalette? = nil
        var themeOverrideTrackID: UUID? = nil
        var isThemeOverrideTrackGuarded: Bool = false
    }

    static let shared = LyricsSurfaceManager()

    private var stores: [LyricsSurfaceRole: LyricsWebViewStore] = [:]
    private var activeRoles: Set<LyricsSurfaceRole> = []
    private var currentPlaybackSnapshot: PlaybackSnapshot = .empty
    private var surfaceSnapshots: [LyricsSurfaceRole: SurfaceSnapshot] = [:]
    private var baseThemePalette: ThemePalette?

    /// Target mode for surface switching (source of truth)
    enum TargetMode {
        case main
        case fullscreen
    }
    private(set) var targetMode: TargetMode = .main

    /// Current confirmed active mode
    enum CurrentMode {
        case none
        case main
        case fullscreen
    }
    private(set) var currentMode: CurrentMode = .none

    /// Switch generation - incremented for each mode change request
    /// Used to discard stale callbacks
    private(set) var switchGeneration: Int = 0

    /// Switch state machine
    enum SwitchState {
        case idle           // No switch in progress
        case preparing      // Creating target surface
        case awaitingReady  // Waiting for target surface ready
        case active         // Target surface active, pending old teardown
    }
    private(set) var switchState: SwitchState = .idle

    /// Pending switch work item (for debouncing/disposal)
    private var pendingSwitchWorkItem: DispatchWorkItem?

    /// Callback when a switch completes
    private var onSwitchComplete: ((TargetMode, Int) -> Void)?

    private init() {}

    // MARK: - Mode Request API (Single Source of Truth)

    /// Request a mode switch. This is the ONLY way to change surfaces.
    /// Views should NOT call this directly - use reportMainVisible/reportFullscreenVisible instead.
    func requestMode(_ mode: TargetMode, onComplete: ((TargetMode, Int) -> Void)? = nil) {
        let desiredCurrentMode: CurrentMode = (mode == .main) ? .main : .fullscreen

        // Ignore only when the requested mode is already fully active and idle.
        guard !(targetMode == mode && currentMode == desiredCurrentMode && switchState == .idle) else {
            return
        }

        // Cancel any pending switch
        pendingSwitchWorkItem?.cancel()
        pendingSwitchWorkItem = nil

        // Increment generation to invalidate old callbacks
        switchGeneration += 1
        let currentGen = switchGeneration

        targetMode = mode
        onSwitchComplete = onComplete

        Log.debug("LyricsSurfaceManager: requestMode=\(mode), gen=\(currentGen), currentMode=\(currentMode)", category: .webview)

        // Start the switch process
        executeSwitch(to: mode, generation: currentGen)
    }

    /// Execute the actual switch to target mode
    private func executeSwitch(to mode: TargetMode, generation: Int) {
        switchState = .preparing

        let targetRole: LyricsSurfaceRole = (mode == .main) ? .main : .fullscreen
        let oldMode = currentMode

        Log.debug("LyricsSurfaceManager: executeSwitch to \(mode), gen=\(generation), from=\(oldMode)", category: .webview)

        // Create/get the target store
        let store = getOrCreateStore(for: targetRole)
        store.prepareWebViewIfNeeded()

        // If store is already ready, complete immediately
        if store.isReady {
            replaySnapshotAndCompleteSwitch(
                to: mode,
                generation: generation,
                targetRole: targetRole,
                store: store,
                reason: "store already ready"
            )
            return
        }

        // Wait for store to become ready
        switchState = .awaitingReady
        onStoreReadyHandlers[targetRole] = { [weak self] readyStore in
            guard let self else { return }

            // Validate generation - discard stale callbacks
            guard generation == self.switchGeneration else {
                Log.warning("LyricsSurfaceManager: stale ready callback, gen=\(generation) != current=\(self.switchGeneration)", category: .webview)
                return
            }

            self.replaySnapshotAndCompleteSwitch(
                to: mode,
                generation: generation,
                targetRole: targetRole,
                store: readyStore,
                reason: "surface ready"
            )
        }
    }

    private func replaySnapshotAndCompleteSwitch(
        to mode: TargetMode,
        generation: Int,
        targetRole: LyricsSurfaceRole,
        store: LyricsWebViewStore,
        reason: String
    ) {
        guard generation == switchGeneration else {
            Log.warning("LyricsSurfaceManager: stale replay before completeSwitch, gen=\(generation) != current=\(switchGeneration)", category: .webview)
            return
        }

        replayCurrentSnapshot(
            to: targetRole,
            store: store,
            reason: "\(reason), gen=\(generation)"
        )
        completeSwitch(to: mode, generation: generation, store: store)
    }

    /// Complete the switch after target surface is ready
    private func completeSwitch(to mode: TargetMode, generation: Int, store: LyricsWebViewStore) {
        guard generation == switchGeneration else {
            Log.warning("LyricsSurfaceManager: stale completeSwitch, gen=\(generation) != current=\(switchGeneration)", category: .webview)
            return
        }

        switchState = .active

        Log.debug("LyricsSurfaceManager: completeSwitch to \(mode), gen=\(generation)", category: .webview)

        // Activate the target role
        let targetRole: LyricsSurfaceRole = (mode == .main) ? .main : .fullscreen
        activate(role: targetRole)

        // Update current mode
        let oldMode = currentMode
        currentMode = (mode == .main) ? .main : .fullscreen

        // Teardown the opposite surface after new one is confirmed active.
        // This must not rely on oldMode only: during the very first fullscreen transition,
        // the previous main store may already exist even if currentMode has not been finalized yet.
        switch mode {
        case .main:
            teardownFullscreenStores()
        case .fullscreen:
            teardownMainStore()
        }

        switchState = .idle

        // Notify completion
        onSwitchComplete?(mode, generation)
        onSwitchComplete = nil

        Log.debug("LyricsSurfaceManager: switch complete to \(mode), gen=\(generation), previousMode=\(oldMode)", category: .webview)
    }

    // MARK: - View Visibility Reporting (Views call these, NOT requestMode)

    /// Report main view visibility change
    /// This may trigger a mode switch if fullscreen is not requested
    func reportMainVisible(_ visible: Bool) {
        Log.debug("LyricsSurfaceManager: reportMainVisible=\(visible), targetMode=\(targetMode), currentMode=\(currentMode), state=\(switchState)", category: .webview)

        // Only consider switching to main if:
        // - We're not explicitly targeting fullscreen
        // - Or fullscreen is not actually active yet
        if visible && targetMode == .fullscreen && currentMode == .fullscreen {
            // Main became visible while fullscreen is target and active
            // This could be a transient state during transition, ignore
            Log.debug("LyricsSurfaceManager: main visible but fullscreen is active, ignoring", category: .webview)
            return
        }

        if visible && currentMode != .main && switchState == .idle {
            // Main became visible and we're not already in main mode
            requestMode(.main)
        }
    }

    /// Report fullscreen view visibility change
    /// This may trigger a mode switch if conditions are met
    func reportFullscreenVisible(_ visible: Bool) {
        Log.debug("LyricsSurfaceManager: reportFullscreenVisible=\(visible), targetMode=\(targetMode), currentMode=\(currentMode), state=\(switchState)", category: .webview)

        if visible && currentMode != .fullscreen {
            // Fullscreen became visible
            requestMode(.fullscreen)
        } else if !visible && targetMode == .fullscreen {
            // Fullscreen disappeared but we were targeting it
            // This could be transient - debounce the decision
            handleFullscreenDisappeared()
        }
    }

    /// Handle fullscreen disappeared with debouncing
    private func handleFullscreenDisappeared() {
        // Cancel any pending decision
        pendingSwitchWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // Re-check conditions after delay
            // Only switch back to main if fullscreen is truly gone
            if self.targetMode == .fullscreen && self.currentMode == .fullscreen {
                // Fullscreen window is still active, don't switch
                Log.debug("LyricsSurfaceManager: fullscreen still active after debounce, keeping fullscreen", category: .webview)
                return
            }

            // Actually switch back to main
            Log.info("LyricsSurfaceManager: fullscreen truly disappeared, switching to main", category: .webview)
            self.requestMode(.main)
        }

        pendingSwitchWorkItem = workItem
        // Short delay to allow transient states to resolve
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    // MARK: - Store Management

    /// Callbacks for store ready events
    private var onStoreReadyHandlers: [LyricsSurfaceRole: (LyricsWebViewStore) -> Void] = [:]

    /// Notify that a store is ready - called by LyricsWebViewStore
    func notifyStoreReady(_ role: LyricsSurfaceRole, store: LyricsWebViewStore) {
        guard let handler = onStoreReadyHandlers.removeValue(forKey: role) else { return }
        Log.debug("LyricsSurfaceManager: store ready for \(role), triggering ready handler", category: .webview)
        handler(store)
    }

    /// Get or create a WebView store for the given role.
    func store(for role: LyricsSurfaceRole) -> LyricsWebViewStore {
        return getOrCreateStore(for: role)
    }

    /// Internal: get existing store or create new one
    private func getOrCreateStore(for role: LyricsSurfaceRole) -> LyricsWebViewStore {
        if let existing = stores[role] {
            return existing
        }

        // Create new store for this role
        let newStore = LyricsWebViewStore(role: role.rawValue)
        stores[role] = newStore
        Log.debug("Created store for role: \(role.rawValue)", category: .webview)
        return newStore
    }

    /// Return an existing store without creating a new WebView surface.
    func existingStore(for role: LyricsSurfaceRole) -> LyricsWebViewStore? {
        stores[role]
    }

    /// Mark a role as active (has a visible surface).
    func activate(role: LyricsSurfaceRole) {
        activeRoles.insert(role)
        Log.debug("Activated role: \(role.rawValue)", category: .webview)
    }

    /// Mark a role as inactive (surface hidden/closed).
    /// For non-persistent roles, performs full teardown.
    func deactivate(role: LyricsSurfaceRole) {
        activeRoles.remove(role)

        // Clean up non-persistent roles
        if !role.persistsState, let store = stores[role] {
            Log.debug("Deactivating and shutting down role: \(role.rawValue)", category: .webview)
            store.shutdown()
            stores.removeValue(forKey: role)

            // Update current mode if this was the active role
            if role == .main && currentMode == .main {
                currentMode = activeRoles.contains(.fullscreen) ? .fullscreen : .none
            } else if role.isFullscreen && currentMode == .fullscreen {
                currentMode = activeRoles.contains(.main) ? .main : .none
            }
        }
    }

    /// Explicitly tear down the main store (used when entering fullscreen).
    func teardownMainStore() {
        Log.info("Tearing down main store", category: .webview)

        if let mainStore = stores[.main] {
            mainStore.teardown()
            mainStore.shutdown()
            stores.removeValue(forKey: .main)
        }

        activeRoles.remove(.main)
    }

    /// Explicitly tear down all fullscreen stores (used when exiting fullscreen).
    func teardownFullscreenStores() {
        Log.info("Tearing down fullscreen stores", category: .webview)

        let fullscreenRoles: [LyricsSurfaceRole] = [.fullscreen, .fullscreenCoverBlurHighlight]
        for role in fullscreenRoles {
            if let store = stores[role] {
                store.teardown()
                store.shutdown()
                stores.removeValue(forKey: role)
            }
            activeRoles.remove(role)
        }
    }

    /// Apply track to all active surfaces.
    func applyTrack(trackID: UUID? = nil, ttml: String?, currentTime: Double, isPlaying: Bool) {
        for role in activeRoles {
            guard let store = stores[role] else { continue }
            store.applyTrack(
                trackID: trackID,
                ttml: ttml,
                currentTime: currentTime,
                isPlaying: isPlaying
            )
        }
    }

    /// Apply theme to all surfaces (active and pre-created).
    func applyTheme(_ palette: ThemePalette) {
        baseThemePalette = palette
        // Apply to all stores, not just active ones
        for (_, store) in stores {
            store.applyTheme(palette)
        }
    }

    func updatePlaybackSnapshot(
        trackID: UUID?,
        lyricsTTML: String,
        currentTime: Double,
        isPlaying: Bool
    ) {
        let lyricsHash = Self.hashLyrics(lyricsTTML)
        let normalizedTime = currentTime.isFinite ? currentTime : currentPlaybackSnapshot.currentTime
        let previousSnapshot = currentPlaybackSnapshot
        currentPlaybackSnapshot = PlaybackSnapshot(
            trackID: trackID,
            lyricsTTML: lyricsTTML,
            lyricsHash: lyricsHash,
            currentTime: normalizedTime,
            isPlaying: isPlaying
        )

        if previousSnapshot.trackID != trackID || previousSnapshot.lyricsHash != lyricsHash {
            Log.debug(
                "LyricsSurfaceManager: updated playback snapshot track=\(trackID?.uuidString.prefix(8) ?? "nil"), lyricsLen=\(lyricsTTML.count), hash=\(lyricsHash.prefix(8)), playing=\(isPlaying)",
                category: .webview
            )
        }
    }

    func updatePlaybackTime(_ currentTime: Double) {
        guard currentTime.isFinite else { return }
        currentPlaybackSnapshot.currentTime = currentTime
    }

    func updatePlayingState(_ isPlaying: Bool) {
        currentPlaybackSnapshot.isPlaying = isPlaying
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

    private func replayCurrentSnapshot(
        to role: LyricsSurfaceRole,
        store: LyricsWebViewStore,
        reason: String
    ) {
        if let baseThemePalette {
            store.applyTheme(baseThemePalette)
        }

        let surfaceSnapshot = surfaceSnapshots[role]
        let currentTrackID = currentPlaybackSnapshot.trackID
        if surfaceSnapshot?.isThemeOverrideTrackGuarded != true
            || surfaceSnapshot?.themeOverrideTrackID == currentTrackID {
            store.setThemePaletteOverride(surfaceSnapshot?.themeOverridePalette)
        } else {
            store.setThemePaletteOverride(nil)
        }

        if let configJSON = surfaceSnapshot?.configJSON,
           surfaceSnapshot?.isConfigTrackGuarded != true
            || surfaceSnapshot?.configTrackID == currentTrackID {
            store.forceSetConfigJSON(
                configJSON,
                reason: "replay current snapshot for \(role.rawValue)"
            )
        }

        Log.debug("LyricsSurfaceManager: replay current snapshot to \(role.rawValue), reason=\(reason), track=\(currentPlaybackSnapshot.trackID?.uuidString.prefix(8) ?? "nil"), lyricsLen=\(currentPlaybackSnapshot.lyricsTTML.count), hash=\(currentPlaybackSnapshot.lyricsHash.prefix(8)), time=\(String(format: "%.3f", currentPlaybackSnapshot.currentTime)), playing=\(currentPlaybackSnapshot.isPlaying)",
            category: .webview
        )

        store.applyTrack(
            trackID: currentPlaybackSnapshot.trackID,
            ttml: currentPlaybackSnapshot.lyricsTTML,
            currentTime: currentPlaybackSnapshot.currentTime,
            isPlaying: currentPlaybackSnapshot.isPlaying
        )
        store.scheduleDebugVisibleLayerProbe(label: "\(role.rawValue)-snapshot-replay", delay: 0.75)
    }

    /// Shutdown all stores (app termination).
    func shutdownAll() {
        Log.info("Shutting down all stores", category: .webview)
        pendingSwitchWorkItem?.cancel()
        onStoreReadyHandlers.removeAll()

        for (_, store) in stores {
            store.shutdown()
        }
        stores.removeAll()
        activeRoles.removeAll()
        currentMode = .none
        targetMode = .main
        switchGeneration = 0
        switchState = .idle
        currentPlaybackSnapshot = .empty
        surfaceSnapshots.removeAll()
        baseThemePalette = nil
    }
}

// MARK: - Convenience Extensions

extension LyricsSurfaceManager {
    private static func hashLyrics(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The shared main store (for sidebar and batch preview).
    var mainStore: LyricsWebViewStore {
        store(for: .main)
    }

    /// The fullscreen store.
    var fullscreenStore: LyricsWebViewStore {
        store(for: .fullscreen)
    }

    /// Check if a role is currently active.
    func isActive(_ role: LyricsSurfaceRole) -> Bool {
        activeRoles.contains(role)
    }

    /// Check if currently in fullscreen mode
    var isFullscreenActive: Bool {
        currentMode == .fullscreen
    }
}
