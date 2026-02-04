//
//  SettingsView.swift
//  myPlayer2
//
//  TrueMusic - Settings View
//  Provides user-configurable settings including LED meter, Appearance, and AMLL.
//

import AppKit
import SwiftUI

/// Settings view with sidebar categories.
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    // MARK: - Navigation

    @State private var selection: SettingsCategory = .appearance

    // MARK: - App Settings

    @State private var appearance: String = AppSettings.shared.appearance
    @State private var liquidGlassIntensity: Double = AppSettings.shared.liquidGlassIntensity

    // MARK: - AMLL Settings

    @State private var lyricsLeadInMs: Double = AppSettings.shared.lyricsLeadInMs
    @State private var lyricsFontNameZh: String = AppSettings.shared.lyricsFontNameZh
    @State private var lyricsFontNameEn: String = AppSettings.shared.lyricsFontNameEn
    @State private var lyricsTranslationFontName: String = AppSettings.shared.lyricsTranslationFontName
    @State private var lyricsFontWeight: Int = AppSettings.shared.lyricsFontWeight
    @State private var lyricsFontSize: Double = AppSettings.shared.lyricsFontSize
    @State private var nowPlayingSkin: String = AppSettings.shared.nowPlayingSkin

    // MARK: - LED Settings State

    @State private var sensitivity: Float = AppSettings.shared.ledSensitivity
    @State private var lowFrequencyWeight: Float = AppSettings.shared.ledLowFrequencyWeight
    @State private var responseSpeed: Float = AppSettings.shared.ledResponseSpeed
    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels
    @State private var glassOutlineIntensity: Double = AppSettings.shared.ledGlassOutlineIntensity

    // MARK: - Preview Level (LED)
    @State private var previewLevel: Double = 0.5

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    private let fontWeights: [(label: String, value: Int)] = [
        ("Thin", 100),
        ("Light", 300),
        ("Regular", 400),
        ("Medium", 500),
        ("Semibold", 600),
        ("Bold", 700)
    ]

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.systemImage)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200)
            .navigationTitle("Settings")
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(selection.title)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 680)
        // Sync State -> AppSettings
        .onChange(of: appearance) { _, val in AppSettings.shared.appearance = val }
        .onChange(of: liquidGlassIntensity) { _, val in
            AppSettings.shared.liquidGlassIntensity = val
        }
        .onChange(of: lyricsLeadInMs) { _, val in AppSettings.shared.lyricsLeadInMs = val }
        .onChange(of: lyricsFontNameZh) { _, val in AppSettings.shared.lyricsFontNameZh = val }
        .onChange(of: lyricsFontNameEn) { _, val in AppSettings.shared.lyricsFontNameEn = val }
        .onChange(of: lyricsTranslationFontName) { _, val in
            AppSettings.shared.lyricsTranslationFontName = val
        }
        .onChange(of: lyricsFontWeight) { _, val in AppSettings.shared.lyricsFontWeight = val }
        .onChange(of: lyricsFontSize) { _, val in AppSettings.shared.lyricsFontSize = val }
        .onChange(of: nowPlayingSkin) { _, val in AppSettings.shared.nowPlayingSkin = val }
        .onChange(of: sensitivity) { _, val in AppSettings.shared.ledSensitivity = val }
        .onChange(of: lowFrequencyWeight) { _, val in AppSettings.shared.ledLowFrequencyWeight = val
        }
        .onChange(of: responseSpeed) { _, val in AppSettings.shared.ledResponseSpeed = val }
        .onChange(of: ledCount) { _, val in AppSettings.shared.ledCount = val }
        .onChange(of: brightnessLevels) { _, val in AppSettings.shared.ledBrightnessLevels = val }
        .onChange(of: glassOutlineIntensity) { _, val in
            AppSettings.shared.ledGlassOutlineIntensity = val
        }
    }

    // MARK: - Appearance Section

    private var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch selection {
                case .appearance:
                    appearanceSection
                case .nowPlaying:
                    nowPlayingSection
                case .lyrics:
                    amllSection
                case .led:
                    ledSettingsSection
                case .about:
                    aboutSection
                }
            }
            .padding(24)
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Appearance & Visuals", systemImage: "paintbrush")
                .font(.headline)

            // Theme Picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            // Liquid Glass Intensity
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Liquid Glass Blur")
                    Spacer()
                    Text(String(format: "%.0f%%", liquidGlassIntensity * 100))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)

                Slider(value: $liquidGlassIntensity, in: 0...1, step: 0.1)

                Text("Adjusts the blur strength of the sidebar and UI elements.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Now Playing Section

    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Now Playing", systemImage: "sparkles")
                .font(.headline)

            GroupBox("Skin") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Skin", selection: $nowPlayingSkin) {
                        ForEach(NowPlayingSkin.allCases) { skin in
                            Label(skin.title, systemImage: skin.systemImage)
                                .tag(skin.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text("Choose the visual style of the Now Playing page.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - AMLL Section

    private var amllSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Lyrics (AMLL)", systemImage: "text.quote")
                .font(.headline)

            GroupBox("Timing") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Lead-in (ms)")
                        Spacer()
                        Text("\(Int(lyricsLeadInMs)) ms")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $lyricsLeadInMs, in: 0...800, step: 20)
                    Text("Advance the next line’s first word and the previous line’s last word.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            GroupBox("Fonts") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(lyricsFontSize)) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $lyricsFontSize, in: 16...48, step: 1)

                    HStack {
                        Text("Font Weight")
                        Spacer()
                        Picker("", selection: $lyricsFontWeight) {
                            ForEach(fontWeights, id: \.value) { weight in
                                Text(weight.label).tag(weight.value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    Divider()

                    HStack {
                        Text("Chinese Font")
                        Spacer()
                        Picker("", selection: $lyricsFontNameZh) {
                            ForEach(fontFamilies, id: \.self) { family in
                                Text(family)
                                    .font(.custom(family, size: 12))
                                    .tag(family)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    HStack {
                        Text("English Font")
                        Spacer()
                        Picker("", selection: $lyricsFontNameEn) {
                            ForEach(fontFamilies, id: \.self) { family in
                                Text(family)
                                    .font(.custom(family, size: 12))
                                    .tag(family)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    HStack {
                        Text("Translation Font")
                        Spacer()
                        Picker("", selection: $lyricsTranslationFontName) {
                            ForEach(fontFamilies, id: \.self) { family in
                                Text(family)
                                    .font(.custom(family, size: 12))
                                    .tag(family)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }
                }
            }

            GroupBox("Preview") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("春夏秋冬")
                            .font(.custom(lyricsFontNameZh, size: CGFloat(lyricsFontSize)))
                            .fontWeight(fontWeight(lyricsFontWeight))
                        Text("Live in Kunming")
                            .font(.custom(lyricsFontNameEn, size: CGFloat(lyricsFontSize)))
                            .fontWeight(fontWeight(lyricsFontWeight))
                    }
                    Text("Translation: The wind is whispering tonight")
                        .font(.custom(lyricsTranslationFontName, size: CGFloat(max(12, lyricsFontSize * 0.7))))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - LED Settings Section

    private var ledSettingsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("LED Meter", systemImage: "waveform.path.ecg")
                .font(.headline)

            // Preview
            VStack(spacing: 8) {
                LedMeterView(level: previewLevel, dotSize: 14, spacing: 8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                Slider(value: $previewLevel, in: 0...1) {
                    Text("Preview Level")
                }
            }

            // Visual Config
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    Text("LED Count")
                    Picker("", selection: $ledCount) {
                        Text("9").tag(9)
                        Text("11").tag(11)
                        Text("13").tag(13)
                        Text("15").tag(15)
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Brightness Levels")
                    Picker("", selection: $brightnessLevels) {
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("7").tag(7)
                    }
                    .labelsHidden()
                }
            }

            // Sliders for Fine Tuning
            Group {
                // Glass Outline
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Outline Intensity")
                        Spacer()
                        Text(String(format: "%.0f%%", glassOutlineIntensity * 100)).foregroundStyle(
                            .secondary)
                    }
                    Slider(value: $glassOutlineIntensity, in: 0...1)
                }

                // Sensitivity
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Audio Sensitivity")
                        Spacer()
                        Text(String(format: "%.1fx", sensitivity)).foregroundStyle(.secondary)
                    }
                    Slider(value: $sensitivity, in: 0.5...2.0)
                }

                // Bass Weight
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bass Weight")
                        Spacer()
                        Text(String(format: "%.0f%%", lowFrequencyWeight * 100)).foregroundStyle(
                            .secondary)
                    }
                    Slider(value: $lowFrequencyWeight, in: 0...1)
                }

                // Speed
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Response Speed")
                        Spacer()
                        Text(
                            responseSpeed < 0.3 ? "Slow" : (responseSpeed < 0.7 ? "Normal" : "Fast")
                        ).foregroundStyle(.secondary)
                    }
                    Slider(value: $responseSpeed, in: 0...1)
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("About", systemImage: "info.circle")
                .font(.headline)

            Text("TrueMusic v1.0")
                .font(.subheadline.bold())

            Text(
                "A native macOS music player featuring AMLL lyrics engine and Liquid Glass aesthetics."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fontWeight(_ weight: Int) -> Font.Weight {
        switch weight {
        case 100: return .ultraLight
        case 200: return .thin
        case 300: return .light
        case 400: return .regular
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        case 900: return .black
        default: return .regular
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance
    case nowPlaying
    case lyrics
    case led
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .nowPlaying: return "Now Playing"
        case .lyrics: return "Lyrics"
        case .led: return "LED Meter"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintbrush"
        case .nowPlaying: return "sparkles"
        case .lyrics: return "text.quote"
        case .led: return "waveform.path.ecg"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Preview

#Preview("Settings") {
    SettingsView()
}
