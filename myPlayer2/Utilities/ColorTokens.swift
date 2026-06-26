//
//  ColorTokens.swift
//  myPlayer2
//
//  kmgccc_player - Color Design Tokens
//  Lightweight SwiftUI color tokens still used by library rows.
//

import SwiftUI

/// Color design tokens for kmgccc_player.
enum ColorTokens {

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.7)

    // MARK: - Accent

    static let accent = Color.accentColor

    // MARK: - Backgrounds

    static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
    static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)

    // MARK: - Player Controls

    static let controlActive = Color.primary
    static let controlInactive = Color.secondary.opacity(0.6)

    // MARK: - Progress Bar

    static let progressTrack = Color.white.opacity(0.2)
    static let progressFill = Color.accentColor
    static let progressKnob = Color.white
}
