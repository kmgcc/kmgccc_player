//
//  LyricsSyncDriver.swift
//  myPlayer2
//
//  kmgccc_player - Throttled lyrics synchronization driver
//  Prevents redundant sync calls and coordinates across surfaces.
//

import Foundation

/// Throttled sync driver for lyrics surfaces.
/// Deduplicates and throttles time updates to prevent redundant WebView communication.
@MainActor
final class LyricsSyncDriver {
    
    static let shared = LyricsSyncDriver()
    
    // Configuration
    private let timeUpdateThrottleHz: Double = 20.0  // Max 20Hz updates
    private let minTimeDelta: Double = 0.05  // Minimum 50ms between updates
    
    // State
    private var lastTimeUpdate: Date = .distantPast
    private var lastSentTime: Double = 0
    private var pendingTime: Double?
    private var throttleTimer: Timer?
    
    // Callbacks for surfaces
    private var timeUpdateHandlers: [() -> Void] = []
    
    private init() {}
    
    /// Request a time update, may be throttled.
    func requestTimeUpdate(_ time: Double, immediate: Bool = false) {
        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastTimeUpdate)
        
        // Skip if time hasn't changed meaningfully
        if abs(time - lastSentTime) < 0.01 && !immediate {
            return
        }
        
        // If immediate or enough time passed, send now
        if immediate || timeSinceLast >= (1.0 / timeUpdateThrottleHz) {
            sendTimeUpdate(time)
        } else {
            // Queue for later
            pendingTime = time
            scheduleThrottledUpdate()
        }
    }
    
    /// Register a handler for time updates.
    func onTimeUpdate(_ handler: @escaping () -> Void) {
        timeUpdateHandlers.append(handler)
    }
    
    /// Remove all handlers.
    func clearHandlers() {
        timeUpdateHandlers.removeAll()
    }
    
    // MARK: - Private
    
    private func sendTimeUpdate(_ time: Double) {
        lastTimeUpdate = Date()
        lastSentTime = time
        pendingTime = nil
        
        // Notify all registered handlers
        for handler in timeUpdateHandlers {
            handler()
        }
    }
    
    private func scheduleThrottledUpdate() {
        guard throttleTimer == nil, pendingTime != nil else { return }
        
        let delay = max(0, (1.0 / timeUpdateThrottleHz) - Date().timeIntervalSince(lastTimeUpdate))
        
        throttleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let pending = self.pendingTime else { return }
                self.sendTimeUpdate(pending)
                self.throttleTimer = nil
            }
        }
    }
}

// MARK: - Deduplicating Sync State

@MainActor
final class LyricsSyncState {
    
    static let shared = LyricsSyncState()
    
    private var lastSentConfig: String?
    private var lastSentTTML: String?
    private var lastSentPlaying: Bool?
    private var lastSentTime: Double?
    
    private init() {}
    
    /// Check if config JSON has changed.
    func shouldUpdateConfig(_ json: String) -> Bool {
        if json == lastSentConfig { return false }
        lastSentConfig = json
        return true
    }
    
    /// Check if TTML has changed.
    func shouldUpdateTTML(_ ttml: String) -> Bool {
        if ttml == lastSentTTML { return false }
        lastSentTTML = ttml
        return true
    }
    
    /// Check if playing state has changed.
    func shouldUpdatePlaying(_ isPlaying: Bool) -> Bool {
        if isPlaying == lastSentPlaying { return false }
        lastSentPlaying = isPlaying
        return true
    }
    
    /// Check if time has changed meaningfully.
    func shouldUpdateTime(_ time: Double) -> Bool {
        if let last = lastSentTime, abs(time - last) < 0.01 { return false }
        lastSentTime = time
        return true
    }
    
    /// Reset all state (e.g., on track change).
    func reset() {
        lastSentConfig = nil
        lastSentTTML = nil
        lastSentPlaying = nil
        lastSentTime = nil
    }
}
