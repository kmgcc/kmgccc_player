//
//  LyricsSurfaceRole.swift
//  myPlayer2
//
//  kmgccc_player - Defines the role of a lyrics surface for lifecycle management
//

import Foundation

/// Identifies the role of a lyrics surface for proper WebView lifecycle management.
/// Each role may have different lifecycle requirements and configuration.
enum LyricsSurfaceRole: String, CaseIterable, Sendable {
    /// Main sidebar lyrics panel - shared with batch editing preview.
    case main = "main"
    
    /// Fullscreen player lyrics - separate instance for isolation.
    case fullscreen = "fullscreen"
    
    /// Batch editing preview - low quality mode, separate instance.
    case batchPreview = "batchPreview"
    
    /// Standalone lyrics window (future use).
    case standalone = "standalone"
    
    // MARK: - Configuration
    
    /// Whether this role should use a separate WebView instance.
    var requiresSeparateInstance: Bool {
        switch self {
        case .main:
            return false  // Shared with batch preview
        case .fullscreen:
            return true   // Isolated for fullscreen
        case .batchPreview:
            return true   // Isolated for preview independence
        case .standalone:
            return true   // Always isolated
        }
    }
    
    /// The render scale for this role (1.0 = full quality).
    var renderScale: Double {
        switch self {
        case .main:
            return 1.0
        case .fullscreen:
            return 1.0
        case .batchPreview:
            return 0.5  // Lower quality for preview
        case .standalone:
            return 1.0
        }
    }
    
    /// Whether this role should persist state when hidden.
    var persistsState: Bool {
        switch self {
        case .main:
            return true   // Keep lyrics loaded
        case .fullscreen:
            return true   // Keep lyrics loaded
        case .batchPreview:
            return false  // Can be recreated
        case .standalone:
            return true
        }
    }
    
    /// Whether this role supports user seek callbacks.
    var supportsSeekCallback: Bool {
        switch self {
        case .main:
            return true
        case .fullscreen:
            return true
        case .batchPreview:
            return false  // Preview doesn't control playback
        case .standalone:
            return true
        }
    }
    
    // MARK: - Display Names
    
    /// Human-readable display name for this role.
    var displayName: String {
        switch self {
        case .main:
            return "Main Lyrics"
        case .fullscreen:
            return "Fullscreen Lyrics"
        case .batchPreview:
            return "Preview Lyrics"
        case .standalone:
            return "Standalone Lyrics"
        }
    }
}

// MARK: - Comparable

extension LyricsSurfaceRole: Comparable {
    static func < (lhs: LyricsSurfaceRole, rhs: LyricsSurfaceRole) -> Bool {
        lhs.priority < rhs.priority
    }
    
    /// Priority for conflict resolution (higher = more important).
    private var priority: Int {
        switch self {
        case .main: return 3
        case .fullscreen: return 4
        case .batchPreview: return 1
        case .standalone: return 2
        }
    }
}

// MARK: - Collection Helpers

extension LyricsSurfaceRole {
    /// All roles that should have their own WebView instance.
    static var independentRoles: [LyricsSurfaceRole] {
        allCases.filter { $0.requiresSeparateInstance }
    }
    
    /// All roles that share the main WebView instance.
    static var sharedRoles: [LyricsSurfaceRole] {
        allCases.filter { !$0.requiresSeparateInstance }
    }
}
