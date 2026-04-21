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
    
    /// Fullscreen-player UI lyrics surface, shared by both system fullscreen-space
    /// presentation and embedded-in-window presentation.
    case fullscreen = "fullscreen"

    /// Fullscreen cover-blur highlight overlay - transparent auxiliary layer.
    case fullscreenCoverBlurHighlight = "fullscreenCoverBlurHighlight"
    
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
        case .fullscreen, .fullscreenCoverBlurHighlight:
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
            return 0.75
        case .fullscreen, .fullscreenCoverBlurHighlight:
            return 0.75
        case .batchPreview:
            return 0.45
        case .standalone:
            return 0.75
        }
    }

    /// Whether the renderer should keep blur enabled for this role.
    var enableBlur: Bool {
        switch self {
        case .main, .fullscreen, .fullscreenCoverBlurHighlight:
            return true
        case .batchPreview, .standalone:
            return false
        }
    }

    /// Whether the renderer should use spring-based animation.
    var enableSpring: Bool {
        switch self {
        case .batchPreview:
            return false
        case .main, .fullscreen, .fullscreenCoverBlurHighlight, .standalone:
            return true
        }
    }

    /// Target AMLL FPS cap for this role. `0` means uncapped.
    var fpsCap: Int {
        switch self {
        case .batchPreview:
            return 45
        case .main, .fullscreen, .fullscreenCoverBlurHighlight, .standalone:
            return 60
        }
    }

    /// Overscan budget in pixels. Lower values reduce work for small embedded surfaces.
    var overscanPx: Int {
        switch self {
        case .batchPreview:
            return 96
        case .main:
            return 260
        case .fullscreen, .fullscreenCoverBlurHighlight:
            return 260
        case .standalone:
            return 180
        }
    }

    /// Per-word fade width. Smaller values reduce mask work.
    var wordFadeWidth: Double {
        switch self {
        case .batchPreview:
            return 0.3
        case .main:
            return 0.7
        case .fullscreen, .fullscreenCoverBlurHighlight, .standalone:
            return 0.7
        }
    }

    /// Active line scale multiplier.
    var activeScale: Double {
        switch self {
        case .main:
            return 1.2
        case .batchPreview:
            return 1.04
        case .fullscreen, .fullscreenCoverBlurHighlight:
            return 1.2
        case .standalone:
            return 1.1
        }
    }
    
    /// Whether this role should persist state when hidden.
    var persistsState: Bool {
        switch self {
        case .main:
            return true   // Keep lyrics loaded
        case .fullscreen:
            return true   // Keep lyrics loaded
        case .fullscreenCoverBlurHighlight:
            return false  // Auxiliary overlay only exists while cover-blur fullscreen is active
        case .batchPreview:
            return false  // Can be recreated
        case .standalone:
            return true
        }
    }
    
    /// Whether this role is a fullscreen role.
    var isFullscreen: Bool {
        switch self {
        case .fullscreen, .fullscreenCoverBlurHighlight:
            return true
        case .main, .batchPreview, .standalone:
            return false
        }
    }

    /// Whether this role supports user seek callbacks.
    var supportsSeekCallback: Bool {
        switch self {
        case .main:
            return true
        case .fullscreen:
            return true
        case .fullscreenCoverBlurHighlight:
            return false  // Overlay is passthrough only
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
        case .fullscreenCoverBlurHighlight:
            return "Fullscreen Cover Blur Highlight"
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
        case .fullscreenCoverBlurHighlight: return 4
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
