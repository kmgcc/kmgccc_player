//
//  SettingsView.swift
//  myPlayer2
//
//  TrueMusic - Settings View
//  Provides user-configurable settings including LED meter, Appearance, and AMLL.
//

import SwiftUI

/// Settings view with tabs for different categories.
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    // MARK: - App Settings

    @State private var appearance: String = AppSettings.shared.appearance
    @State private var liquidGlassIntensity: Double = AppSettings.shared.liquidGlassIntensity
    @State private var lyricsFontSize: Double = AppSettings.shared.lyricsFontSize

    // MARK: - LED Settings State

    @State private var sensitivity: Float = AppSettings.shared.ledSensitivity
    @State private var lowFrequencyWeight: Float = AppSettings.shared.ledLowFrequencyWeight
    @State private var responseSpeed: Float = AppSettings.shared.ledResponseSpeed
    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels
    @State private var glassOutlineIntensity: Double = AppSettings.shared.ledGlassOutlineIntensity

    // MARK: - Preview Level (LED)
    @State private var previewLevel: Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {

                    // Appearance Section
                    appearanceSection

                    Divider()

                    // AMLL Lyrics Section
                    amllSection

                    Divider()

                    // LED Meter Section (Visual + Audio)
                    ledSettingsSection

                    Divider()

                    // About Section
                    aboutSection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 500, minHeight: 700)
        // Sync State -> AppSettings
        .onChange(of: appearance) { _, val in AppSettings.shared.appearance = val }
        .onChange(of: liquidGlassIntensity) { _, val in
            AppSettings.shared.liquidGlassIntensity = val
        }
        .onChange(of: lyricsFontSize) { _, val in AppSettings.shared.lyricsFontSize = val }
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

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Settings")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
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

    // MARK: - AMLL Section

    private var amllSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Lyrics (AMLL)", systemImage: "text.quote")
                .font(.headline)

            // Font Size
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(lyricsFontSize)) px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)

                Slider(value: $lyricsFontSize, in: 16...48, step: 2)

                Text("Size of the active lyric line.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
}

// MARK: - Preview

#Preview("Settings") {
    SettingsView()
}
