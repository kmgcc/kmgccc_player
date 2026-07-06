//
//  PlaybackDynamicSnapshot.swift
//  myPlayer2
//
//  kmgccc_player - Dynamic playback state that changes frequently
//  Separated from TrackVisualSnapshot to minimize view recomputation.
//

import Foundation

/// Immutable snapshot of dynamic playback state.
/// These properties change frequently during playback (multiple times per second).
struct PlaybackDynamicSnapshot: Hashable, Sendable {
    let currentTime: Double
    let duration: Double
    let progress: Double  // 0.0 to 1.0
    let isPlaying: Bool
    let volume: Double
    let isSeeking: Bool
    
    // Audio levels (for visualization)
    let leftLevel: Float
    let rightLevel: Float
    let combinedLevel: Float
    
    // When this snapshot was created
    let timestamp: Date
    
    init(
        currentTime: Double = 0,
        duration: Double = 0,
        isPlaying: Bool = false,
        volume: Double = 1.0,
        isSeeking: Bool = false,
        leftLevel: Float = 0,
        rightLevel: Float = 0,
        combinedLevel: Float = 0
    ) {
        self.currentTime = currentTime
        self.duration = duration
        self.progress = duration > 0 ? currentTime / duration : 0
        self.isPlaying = isPlaying
        self.volume = volume
        self.isSeeking = isSeeking
        self.leftLevel = leftLevel
        self.rightLevel = rightLevel
        self.combinedLevel = combinedLevel
        self.timestamp = Date()
    }
    
    // MARK: - Derived Properties
    
    /// Current time formatted as MM:SS.
    var currentTimeText: String {
        let minutes = Int(currentTime) / 60
        let seconds = Int(currentTime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Remaining time formatted as -MM:SS.
    var remainingTimeText: String {
        let remaining = max(0, duration - currentTime)
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "-%d:%02d", minutes, seconds)
    }
    
    /// Whether playback has started (currentTime > 0).
    var hasStarted: Bool {
        currentTime > 0.1
    }
    
    /// Whether playback is near the end (within 5 seconds).
    var isNearEnd: Bool {
        duration > 0 && (duration - currentTime) < 5
    }
    
    // MARK: - Hashable
    
    /// Hash only the stable properties, not timestamp.
    func hash(into hasher: inout Hasher) {
        hasher.combine(currentTime)
        hasher.combine(isPlaying)
        hasher.combine(volume)
    }
    
    static func == (lhs: PlaybackDynamicSnapshot, rhs: PlaybackDynamicSnapshot) -> Bool {
        lhs.currentTime == rhs.currentTime &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.volume == rhs.volume &&
        lhs.isSeeking == rhs.isSeeking
    }
}

// MARK: - Convenience

extension PlaybackDynamicSnapshot {
    /// Snapshot for stopped/reset state.
    static var stopped: PlaybackDynamicSnapshot {
        PlaybackDynamicSnapshot()
    }
    
    /// Snapshot for paused state at specific time.
    static func paused(at time: Double, duration: Double = 0) -> PlaybackDynamicSnapshot {
        PlaybackDynamicSnapshot(
            currentTime: time,
            duration: duration,
            isPlaying: false
        )
    }
    
    /// Snapshot for playing state at specific time.
    static func playing(at time: Double, duration: Double = 0) -> PlaybackDynamicSnapshot {
        PlaybackDynamicSnapshot(
            currentTime: time,
            duration: duration,
            isPlaying: true
        )
    }
}

// MARK: - Protocol for Services

/// Protocol for services that can provide dynamic snapshots.
protocol PlaybackDynamicSnapshotProvider: AnyObject {
    var currentSnapshot: PlaybackDynamicSnapshot { get }
    func subscribe(to updates: @escaping (PlaybackDynamicSnapshot) -> Void) -> Any
}
