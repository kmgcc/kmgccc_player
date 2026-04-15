//
//  ArtBackgroundPolicy.swift
//  myPlayer2
//
//  Host-level activation rules for BK art backgrounds.
//

import Foundation

enum ArtBackgroundPolicy {
    static func normalIsActive(
        contentMode: ContentMode,
        isEnabled: Bool,
        hasTrack: Bool,
        isFullscreenActive: Bool,
        allowsHostArtBackground: Bool
    ) -> Bool {
        contentMode == .nowPlaying
            && isEnabled
            && hasTrack
            && !isFullscreenActive
            && allowsHostArtBackground
    }

    static func fullscreenIsActive(
        isEnabled: Bool,
        hasTrack: Bool,
        allowsHostArtBackground: Bool
    ) -> Bool {
        isEnabled
            && hasTrack
            && allowsHostArtBackground
    }
}
