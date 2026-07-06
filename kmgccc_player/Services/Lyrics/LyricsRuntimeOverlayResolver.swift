//
//  LyricsRuntimeOverlayResolver.swift
//  myPlayer2
//
//  Runtime-only overlays for lyrics config.
//  Must not write back to AppSettings/UserDefaults.
//

import Foundation

@MainActor
enum LyricsRuntimePresentationContext: String, Sendable {
    case mainPanel
    case fullscreenSystem
    case fullscreenEmbedded
}

@MainActor
struct LyricsRuntimeOverlay: Equatable, Sendable {
    var mainFontSizeDeltaPx: Double = 0
    var translationFontSizeDeltaPx: Double = 0
    var globalAdvanceDeltaMs: Double = 0

    var signature: String {
        "\(mainFontSizeDeltaPx)|\(translationFontSizeDeltaPx)|\(globalAdvanceDeltaMs)"
    }
}

@MainActor
enum LyricsRuntimeOverlayResolver {
    /// Computes additional runtime-only overlays for lyrics config.
    ///
    /// Priority:
    /// - Persisted user settings = base values
    /// - Runtime overlays (presentation / playback mode) = applied on top
    static func overlay(
        context: LyricsRuntimePresentationContext,
        playbackSource: PlaybackSource
    ) -> LyricsRuntimeOverlay {
        var overlay = LyricsRuntimeOverlay()

        // Windowed (embedded) fullscreen: make lyrics slightly larger.
        // Applies only to the embedded presentation (NOT system fullscreen space).
        if context == .fullscreenEmbedded {
            overlay.mainFontSizeDeltaPx += 6
            overlay.translationFontSizeDeltaPx += 4
        }

        // External listening mode: advance lyrics globally by 350ms.
        // Reuses the existing "global advance" chain by increasing the effective advance.
        if playbackSource.isExternal {
            overlay.globalAdvanceDeltaMs += 350
        }

        return overlay
    }
}
