//
//  SkinContext.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing Skin Context
//  Read-only context provided to skins.
//

import AppKit
import SwiftUI

struct SkinContext {
    enum PresentationMode {
        case nowPlaying
        case fullscreenPlayer
    }

    enum FullscreenHostMode {
        case none
        case systemFullscreen
        case embeddedWindow
    }

    struct TrackMetadata {
        let id: UUID
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let artworkChecksum: UInt64
        let artworkData: Data?
        let artworkImage: NSImage?
    }

    struct PlaybackState {
        let isPlaying: Bool
        let currentTime: Double
        let duration: Double
        let progress: Double
    }

    struct ThemeTokens {
        let accentColor: Color
        let colorScheme: ColorScheme
        let reduceMotion: Bool
        let reduceTransparency: Bool
        let glassIntensity: Double
        /// Legacy background controls.
        let backgroundBlur: Double
        let backgroundBrightness: Double
        let backgroundSaturation: Double
        /// Mesh gradient controls.
        let meshAmplitude: Double
        let meshFlowSpeed: Double
        let meshSharpness: Double
        let meshSoftness: Double
        let meshColorBoost: Double
        let meshContrast: Double
        let meshBassImpact: Double
        /// Accent derived from artwork for UI tint usage.
        let artworkAccentColor: Color?
        let artworkPalette: [NSColor]
        let artworkRichPalette: [NSColor]
        let artworkAverageColor: NSColor?
        let artBackgroundIsUltraDark: Bool
        /// Background dynamics (transient overlays).
        let kickToBrightnessMix: Double
        let kickDisplaceAmount: Double
        let kickScaleAmount: Double
    }

    let track: TrackMetadata?
    let playback: PlaybackState
    let audio: AudioMetrics
    let led: LEDMeterMetrics
    let theme: ThemeTokens

    /// Full available window size for the detail column.
    let windowSize: CGSize

    /// Content bounds for artwork/decoration (excludes lyrics + bottom bar).
    /// Coordinate space is local to the content container (origin at top-left).
    let contentBounds: CGRect

    /// Scale factor for fullscreen responsive layout.
    /// Base size: 1470 x 923, scale = min(width/1470, height/923).
    /// For normal (non-fullscreen) mode, this is 1.0.
    let fullscreenScale: CGFloat

    /// Whether lyrics column is visible (for artwork positioning decisions).
    /// When false, artwork should center itself; when true, artwork should leave room for lyrics.
    let lyricsVisible: Bool

    /// UI layout semantics for the host surface.
    /// `fullscreenPlayer` means the fullscreen-player artwork/control layout,
    /// regardless of whether it lives in a system fullscreen space or inside the main window.
    let presentationMode: PresentationMode

    /// Distinguishes system fullscreen space vs embedded-window fullscreen host.
    let fullscreenHostMode: FullscreenHostMode

    var contentSize: CGSize {
        contentBounds.size
    }

    var usesFullscreenPlayerLayout: Bool {
        presentationMode == .fullscreenPlayer
    }
}

// MARK: - Fullscreen Fine-tuning Helpers
extension SkinContext {
    /// Returns a new SkinContext with adjusted content size for fullscreen scaling.
    /// Used by skins that need additional scale adjustments beyond the global fullscreenScale.
    func withContentSizeAdjustment(_ adjustment: CGFloat) -> SkinContext {
        SkinContext(
            track: track,
            playback: playback,
            audio: audio,
            led: led,
            theme: theme,
            windowSize: windowSize,
            contentBounds: CGRect(
                origin: contentBounds.origin,
                size: CGSize(
                    width: contentBounds.width * adjustment,
                    height: contentBounds.height * adjustment
                )
            ),
            fullscreenScale: fullscreenScale,
            lyricsVisible: lyricsVisible,
            presentationMode: presentationMode,
            fullscreenHostMode: fullscreenHostMode
        )
    }
}
