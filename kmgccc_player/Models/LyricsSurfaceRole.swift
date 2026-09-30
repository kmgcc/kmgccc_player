//
//  LyricsSurfaceRole.swift
//  myPlayer2
//
//  kmgccc_player - Defines the role of a lyrics surface for lifecycle management
//

import Foundation

/// Identifies the role of a lyrics surface for lifecycle and configuration.
/// Each role may have different rendering requirements.
enum LyricsSurfaceRole: String, CaseIterable, Sendable {
    static let amllMediumResolutionScale: Double = 0.75
    static let amllLowResolutionScale: Double = 0.5

    /// Main sidebar lyrics panel.
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
    
    /// Whether this role owns an independent renderer surface.
    var requiresSeparateInstance: Bool {
        switch self {
        case .main:
            return false  // Canonical window playback surface
        case .fullscreen, .fullscreenCoverBlurHighlight:
            return true   // Isolated for fullscreen
        case .batchPreview:
            return true   // Isolated for preview independence
        case .standalone:
            return true   // Always isolated
        }
    }

    /// Whether the role follows the app-wide Now Playing snapshot. Editing
    /// previews own a deliberately independent clock/document and must never be
    /// overwritten by the currently playing track.
    var receivesSharedPlaybackSnapshot: Bool {
        self != .batchPreview
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

    /// Whether the user-facing AMLL render quality setting should affect this role.
    var supportsAMLLRenderQuality: Bool {
        switch self {
        case .main, .fullscreen, .fullscreenCoverBlurHighlight, .standalone:
            return true
        case .batchPreview:
            return false
        }
    }

    /// Whether the renderer should keep blur enabled for this role.
    ///
    /// `KMGCCC_LYRICS_BLUR=0` disables it for A/B measurement. Every blurred
    /// row carries a live `CIGaussianBlur` on its Core Animation layer, and
    /// those filters are evaluated by the render server rather than by this
    /// process, so their cost shows up in WindowServer instead of in the app.
    var enableBlur: Bool {
        if ProcessInfo.processInfo.environment["KMGCCC_LYRICS_BLUR"] == "0" {
            return false
        }
        switch self {
        case .main, .fullscreen, .fullscreenCoverBlurHighlight:
            return true
        case .batchPreview, .standalone:
            return false
        }
    }

    /// Whether the renderer should bake a settled row's blur into its bitmap.
    ///
    /// `KMGCCC_LYRICS_BAKE=0` keeps the live `CIGaussianBlur` filter instead,
    /// for A/B measurement of the two paths side by side.
    var bakeSettledBlur: Bool {
        if ProcessInfo.processInfo.environment["KMGCCC_LYRICS_BAKE"] == "0" {
            return false
        }
        // Runtime A/B hook. Comparing the baked and live renderings across two
        // launches is useless: the window position drifts and the frosted pane
        // then samples a different part of the desktop, which is the same order
        // of magnitude as the difference being measured. Flipping this default
        // and rebuilding the configuration lets one instance capture the very
        // same lyric frame both ways.
        if let override = UserDefaults.standard.object(forKey: "debugLyricsBakeSettledBlur") as? Bool {
            return override
        }
        return true
    }

    /// Whether the renderer should use spring-based animation.
    var enableSpring: Bool {
        switch self {
        case .main, .fullscreen, .fullscreenCoverBlurHighlight, .batchPreview, .standalone:
            return true
        }
    }

    /// Target AMLL FPS cap for this role. `0` means uncapped.
    var fpsCap: Int {
        switch self {
        case .main, .fullscreen, .fullscreenCoverBlurHighlight, .batchPreview, .standalone:
            return 0
        }
    }

    /// Overscan budget in pixels. Lower values reduce work for small embedded surfaces.
    var overscanPx: Int {
        switch self {
        case .batchPreview:
            return 96
        case .main:
            return 80
        case .fullscreen, .fullscreenCoverBlurHighlight:
            return 180
        case .standalone:
            return 80
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
        case .main, .fullscreen, .fullscreenCoverBlurHighlight, .batchPreview:
            return 1.2
        case .standalone:
            return 1.1
        }
    }

    /// Glyph cache budget in bytes for rasterized text in MelismaKit.
    /// Setting this appropriately prevents unbounded CGImage / CoreAnimation backing bloat.
    var glyphCacheBudgetBytes: Int {
        switch self {
        case .main:
            return 3 * 1024 * 1024
        case .fullscreen:
            return 6 * 1024 * 1024
        case .fullscreenCoverBlurHighlight:
            return 3 * 1024 * 1024
        case .batchPreview:
            return 2 * 1024 * 1024
        case .standalone:
            return 3 * 1024 * 1024
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
        case .main, .fullscreen, .batchPreview, .standalone:
            return true
        case .fullscreenCoverBlurHighlight:
            return false  // Overlay is passthrough only
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
    /// All roles that own an independent renderer surface.
    static var independentRoles: [LyricsSurfaceRole] {
        allCases.filter { $0.requiresSeparateInstance }
    }
    
    /// All roles that share the main renderer state.
    static var sharedRoles: [LyricsSurfaceRole] {
        allCases.filter { !$0.requiresSeparateInstance }
    }
}
