//
//  FullscreenCoverHorizontalOffset.swift
//  myPlayer2
//
//  Shared horizontal offset policy for cover-element fullscreen skins.
//

import SwiftUI

enum FullscreenCoverHorizontalOffset {
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
