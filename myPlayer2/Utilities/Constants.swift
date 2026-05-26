//
//  Constants.swift
//  myPlayer2
//
//  kmgccc_player - App Constants
//

import Foundation

/// App-wide constants.
nonisolated enum Constants {

    // MARK: - App Info

    static var appName: String { NSLocalizedString("common.app_name", comment: "") }
    static let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    // MARK: - Layout

    enum Layout {
        static let sidebarMinWidth: CGFloat = 200
        static let sidebarMaxWidth: CGFloat = 310
        static let sidebarDefaultWidth: CGFloat = 220

        static let lyricsPanelMinWidth: CGFloat = 280
        static let lyricsPanelMaxWidth: CGFloat = 560
        static let lyricsPanelDefaultWidth: CGFloat = 320
        static let detailContentMinWidth: CGFloat = 620

        static let miniPlayerHeight: CGFloat = 50
        static let miniPlayerPadding: CGFloat = 16

        enum TrackRow {
            static let height: CGFloat = 52
            static let lyricSnippetHeight: CGFloat = 64
            static let artworkSize: CGFloat = 44
            static let horizontalSpacing: CGFloat = 13
            static let textColumnSpacing: CGFloat = 10
            static let textVerticalSpacing: CGFloat = 3
            static let horizontalPadding: CGFloat = 10
            static let verticalPadding: CGFloat = 5
            static let titleLineHeight: CGFloat = 25
            static let titleFontSize: CGFloat = 14.5
            static let subtitleFontSize: CGFloat = 12.5
            static let lyricSnippetFontSize: CGFloat = 11.5
            static let durationFontSize: CGFloat = 11.5
            static let playingIndicatorFontSize: CGFloat = 12.5
            static let cornerRadius: CGFloat = 9
            static let artworkCornerRadius: CGFloat = 7
            static let trailingMenuGlyphSize: CGFloat = 14
            static let trailingMenuHitSize: CGFloat = 30
        }

        static let trackRowHeight: CGFloat = TrackRow.height
        static let artworkSmallSize: CGFloat = TrackRow.artworkSize
        static let artworkMediumSize: CGFloat = 64
        static let artworkLargeSize: CGFloat = 300
    }

    // MARK: - LED Meter

    enum LEDMeter {
        /// Number of LED columns
        static let columnCount: Int = 9

        /// Brightness levels per LED
        static let brightnessLevels: Int = 6

        /// Total steps (columns × levels)
        static let totalSteps: Int = columnCount * brightnessLevels  // 54

        /// LED size
        static let ledSize: CGFloat = 12

        /// Spacing between LEDs
        static let ledSpacing: CGFloat = 8
    }

    // MARK: - Animation

    enum Animation {
        static let defaultDuration: Double = 0.25
        static let fastDuration: Double = 0.15
        static let slowDuration: Double = 0.4
    }

    // MARK: - File Types

    enum FileTypes {
        static let supportedAudioExtensions = ["mp3", "m4a", "flac", "wav", "aiff", "aac", "ogg"]
        static let lyricsExtensions = ["ttml"]
    }
}
