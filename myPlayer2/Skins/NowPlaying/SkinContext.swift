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

    struct TrackMetadata {
        let id: UUID
        let title: String
        let artist: String
        let album: String
        let duration: Double
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

    var contentSize: CGSize {
        contentBounds.size
    }
}
