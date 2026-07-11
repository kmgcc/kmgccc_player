//
//  FullscreenCoverHorizontalOffset.swift
//  myPlayer2
//
//  Shared horizontal offset policy for cover-element fullscreen skins.
//

import SwiftUI

enum FullscreenCoverHorizontalOffset {
    /// Shared left-bias for the whole cover group (artwork + visualizer +
    /// overlay + lyrics) across all non-cover-blur fullscreen skins
    /// (Classic, Rotating Cover, Cassette, AppleStyle).
    ///
    /// Applied identically to the artwork area
    /// (`FullscreenPlayerView.skinArtworkArea`) and the lyrics column
    /// (`FullscreenPlayerView.fullscreenLyricsLayer`) so cover, visualizer,
    /// and lyrics translate together without altering their relative spacing.
    /// Both call sites subtract this value, i.e. shift left.
    ///
    /// Kept in base-canvas points so it scales proportionally with the
    /// fullscreen canvas and stays balanced across window sizes and aspect
    /// ratios - never a fixed screen-pixel value.
    static let groupLeftBias: CGFloat = 36

    static func artworkOffsetX(
        for context: SkinContext,
        baseOffset: CGFloat = 0
    ) -> CGFloat {
        guard context.usesFullscreenPlayerLayout, context.lyricsVisible else {
            return baseOffset
        }

        // Apply a small, shared left-bias so all cover-element skins remain
        // visually centered inside the shared artwork column as the layout
        // compresses on narrower windowed-fullscreen widths.
        let width = max(1, context.contentSize.width)
        let compression = max(0, min(1, (900 - width) / 360))
        let adaptiveLeftBias = 1 - compression * 3
        return baseOffset + adaptiveLeftBias
    }
}
