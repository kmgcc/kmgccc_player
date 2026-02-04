//
//  AppSettings.swift
//  myPlayer2
//
//  TrueMusic - App Settings Model
//  Uses AppStorage for persistent user preferences.
//

import Foundation
import SwiftUI

/// Observable app settings using AppStorage for persistence.
@Observable
final class AppSettings {

    // MARK: - Singleton

    static let shared = AppSettings()

    // MARK: - Audio Settings

    /// Master volume (0.0 to 1.0)
    @ObservationIgnored
    @AppStorage("volume") var volume: Double = 0.8

    // MARK: - LED Meter Settings

    /// Number of LEDs (default 11)
    @ObservationIgnored
    @AppStorage("ledCount") var ledCount: Int = 11

    /// Brightness levels per LED (default 5)
    @ObservationIgnored
    @AppStorage("ledBrightnessLevels") var ledBrightnessLevels: Int = 5

    /// Glass outline intensity (0.0 to 1.0, default 0.8)
    @ObservationIgnored
    @AppStorage("ledGlassOutlineIntensity") var ledGlassOutlineIntensity: Double = 0.8

    /// LED sensitivity (0.5 to 2.0, default 1.0)
    @ObservationIgnored
    @AppStorage("ledSensitivity") private var _ledSensitivity: Double = 1.0

    var ledSensitivity: Float {
        get { Float(_ledSensitivity) }
        set { _ledSensitivity = Double(newValue) }
    }

    /// LED low frequency weight (0.0 to 1.0, default 0.7)
    @ObservationIgnored
    @AppStorage("ledLowFrequencyWeight") private var _ledLowFrequencyWeight: Double = 0.7

    var ledLowFrequencyWeight: Float {
        get { Float(_ledLowFrequencyWeight) }
        set { _ledLowFrequencyWeight = Double(newValue) }
    }

    /// LED response speed (0.0 to 1.0, default 0.5)
    @ObservationIgnored
    @AppStorage("ledResponseSpeed") private var _ledResponseSpeed: Double = 0.5

    var ledResponseSpeed: Float {
        get { Float(_ledResponseSpeed) }
        set { _ledResponseSpeed = Double(newValue) }
    }

    // MARK: - Appearance Settings

    /// Appearance mode: "system", "light", or "dark"
    @ObservationIgnored
    @AppStorage("appearance") var appearance: String = "system"

    /// Accent color hex string
    @ObservationIgnored
    @AppStorage("accentColorHex") var accentColorHex: String = "#007AFF"

    /// Liquid Glass intensity (0.0 to 1.0)
    @ObservationIgnored
    @AppStorage("liquidGlassIntensity") var liquidGlassIntensity: Double = 1.0

    // MARK: - AMLL Settings

    /// AMLL configuration as JSON string
    @ObservationIgnored
    @AppStorage("amllConfigJSON") var amllConfigJSON: String = "{}"

    /// Lyrics font name
    @ObservationIgnored
    @AppStorage("lyricsFontName") var lyricsFontName: String = "SF Pro"

    /// Lyrics font name (Chinese/CJK)
    @ObservationIgnored
    @AppStorage("lyricsFontNameZh") var lyricsFontNameZh: String = "PingFang SC"

    /// Lyrics font name (Latin/English)
    @ObservationIgnored
    @AppStorage("lyricsFontNameEn") var lyricsFontNameEn: String = "SF Pro Text"

    /// Translation font name
    @ObservationIgnored
    @AppStorage("lyricsTranslationFontName") var lyricsTranslationFontName: String = "SF Pro Text"

    /// Lyrics font weight (100~900)
    @ObservationIgnored
    @AppStorage("lyricsFontWeight") var lyricsFontWeight: Int = 600

    /// Lyrics font size
    @ObservationIgnored
    @AppStorage("lyricsFontSize") var lyricsFontSize: Double = 24.0

    /// Lead-in milliseconds for next line start/word timing
    @ObservationIgnored
    @AppStorage("lyricsLeadInMs") var lyricsLeadInMs: Double = 300

    /// Now Playing skin identifier
    @ObservationIgnored
    @AppStorage("nowPlayingSkin") var nowPlayingSkin: String = "coverLed"

    // MARK: - Playback Settings

    /// Shuffle enabled
    @ObservationIgnored
    @AppStorage("shuffleEnabled") var shuffleEnabled: Bool = false

    /// Repeat mode: "off", "all", "one"
    @ObservationIgnored
    @AppStorage("repeatMode") var repeatMode: String = "off"

    // MARK: - Private Init

    private init() {}

    // MARK: - Computed Properties

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var accentColor: Color {
        Color(hex: accentColorHex) ?? .accentColor
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
