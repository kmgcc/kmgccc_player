//
//  Constants.swift
//  myPlayer2
//
//  kmgccc_player - App Constants
//

import Foundation

/// App-wide constants.
enum Constants {

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

        static let miniPlayerHeight: CGFloat = 50
        static let miniPlayerPadding: CGFloat = 16

        static let trackRowHeight: CGFloat = 48
        static let artworkSmallSize: CGFloat = 40
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
        static let lyricsExtensions = ["ttml", "lrc"]
    }
}
