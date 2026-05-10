//
//  HomeFeedSection.swift
//  myPlayer2
//
//  Metadata for Home feed sections used by HomeFeedScrollView.
//  Defines section order and per-section spacing/padding.
//

import Foundation

enum HomeFeedSection: Int, CaseIterable {
    case hero
    case playlists
    case artists
    case albums
    case insights
    case footer
    case tailSpacer

    /// Top padding before the first section.
    static let topInset: CGFloat = 56

    /// Bottom padding after the last section (plus mini-player tail).
    static let bottomInset: CGFloat = 24

    /// Mini-player tail spacer height.
    static let tailSpacerHeight: CGFloat = 120

    /// Inter-section spacing for a given layout mode.
    static func sectionSpacing(for mode: HomeLayoutMode) -> CGFloat {
        mode.sectionSpacing
    }
}
