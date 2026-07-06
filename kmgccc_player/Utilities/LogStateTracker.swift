//
//  LogStateTracker.swift
//  myPlayer2
//
//  kmgccc_player - Log State Tracking for Duplicate Suppression
//  Tracks state changes to suppress repetitive log messages.
//

import Foundation

/// Actor-based state tracker for log deduplication.
/// Tracks state values by key and only returns `true` when state changes.
actor LogStateTracker {
    
    static let shared = LogStateTracker()
    
    private init() {}
    
    /// Stored state values keyed by log context.
    private var stateValues: [String: String] = [:]
    
    /// Check if state has changed for the given key.
    /// - Parameters:
    ///   - key: Unique identifier for the state being tracked
    ///   - value: Current value to compare against stored value
    /// - Returns: `true` if this is a new or changed state, `false` if unchanged
    func checkStateChanged(key: String, value: String) -> Bool {
        let previous = stateValues[key]
        guard previous != value else {
            return false
        }
        stateValues[key] = value
        return true
    }
    
    /// Check if state has changed (Any version with JSON encoding).
    /// - Parameters:
    ///   - key: Unique identifier for the state being tracked
    ///   - value: Current value (must be Encodable)
    /// - Returns: `true` if this is a new or changed state, `false` if unchanged
    func checkStateChanged<T: Encodable>(key: String, value: T) -> Bool {
        guard let data = try? JSONEncoder().encode(value),
              let jsonString = String(data: data, encoding: .utf8) else {
            // If we can't encode, let it through
            return true
        }
        return checkStateChanged(key: key, value: jsonString)
    }
    
    /// Clear tracked state for a specific key.
    func clearState(key: String) {
        stateValues.removeValue(forKey: key)
    }
    
    /// Clear all tracked states.
    func clearAll() {
        stateValues.removeAll()
    }
}

/// Non-actor version for synchronous contexts (not thread-safe).
/// Use only when called from a single thread (e.g., @MainActor).
@MainActor
final class LogStateTrackerSync {
    
    static let shared = LogStateTrackerSync()
    
    private init() {}
    
    private var stateValues: [String: String] = [:]
    
    /// Check if state has changed for the given key.
    func checkStateChanged(key: String, value: String) -> Bool {
        let previous = stateValues[key]
        guard previous != value else {
            return false
        }
        stateValues[key] = value
        return true
    }
    
    /// Check if state has changed (Any version with JSON encoding).
    func checkStateChanged<T: Encodable>(key: String, value: T) -> Bool {
        guard let data = try? JSONEncoder().encode(value),
              let jsonString = String(data: data, encoding: .utf8) else {
            return true
        }
        return checkStateChanged(key: key, value: jsonString)
    }
    
    /// Clear tracked state for a specific key.
    func clearState(key: String) {
        stateValues.removeValue(forKey: key)
    }
    
    /// Clear all tracked states.
    func clearAll() {
        stateValues.removeAll()
    }
}

// MARK: - Convenience Extensions for Common Patterns

extension LogStateTracker {
    
    /// Track theme-related state changes.
    /// Common keys: "theme.updateThemeFromArtworkData", "theme.refreshPalette.scheme", "theme.applyTheme.palette"
    func trackThemeState(_ key: String, trackID: UUID?, checksum: UInt64) -> Bool {
        let value = "track=\(trackID?.uuidString ?? "nil")|checksum=\(checksum)"
        return checkStateChanged(key: key, value: value)
    }
    
    /// Track lyrics WebView state changes.
    func trackLyricsState(_ key: String, objectID: Int, state: String) -> Bool {
        let value = "objectID=\(objectID)|state=\(state)"
        return checkStateChanged(key: key, value: value)
    }
    
    /// Track playback state changes.
    func trackPlaybackState(_ key: String, trackID: UUID?, isPlaying: Bool, time: Double) -> Bool {
        let timeInt = Int(time * 100) // Reduce precision to avoid noise
        let value = "track=\(trackID?.uuidString.prefix(8) ?? "nil")|playing=\(isPlaying)|time=\(timeInt)"
        return checkStateChanged(key: key, value: value)
    }
    
    /// Track fullscreen state changes.
    func trackFullscreenState(_ key: String, isActive: Bool, isTransitioning: Bool) -> Bool {
        let value = "active=\(isActive)|transitioning=\(isTransitioning)"
        return checkStateChanged(key: key, value: value)
    }
}