//
//  LEDMeterSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - LED Meter Settings View
//

import SwiftUI

/// LED meter settings: live preview, visual config, and tuning parameters.
struct LEDMeterSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(PlayerViewModel.self) private var playerVM
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    /// Hide the embedded "LED Meter" header when this view is rendered as a tab
    /// inside another settings container that already shows a title.
    let showTitle: Bool

    @State private var cutoffHz: Double = AppSettings.shared.ledCutoffHz
    @State private var speed: Double = AppSettings.shared.ledSpeed
    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels
    @State private var hasActiveSession: Bool = false

    init(showTitle: Bool = true) {
        self.showTitle = showTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showTitle {
                SettingsHeaderLabel("settings.section.led", systemImage: "waveform.path.ecg")
            }

            // Live Preview
            VStack(alignment: .leading, spacing: 12) {
                SettingsSectionTitle("settings.led.live_preview")

                let ledMeter = ledMeterProvider.getOrCreate()

                LedMeterView(
                    level: Double(ledMeter.normalizedLevel),
                    ledValues: ledMeter.metrics.leds,
                    dotSize: 14,
                    spacing: 7,
                    isPlaying: playerVM.isPlaying
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.primary.opacity(0.05))
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Visual Config
            visualConfigSection

            // Tuning Sliders
            tuningSection
        }
        .onAppear {
            cutoffHz = settings.ledCutoffHz
            speed = settings.ledSpeed
            ledCount = settings.ledCount
            brightnessLevels = settings.ledBrightnessLevels
            if !hasActiveSession {
                ledMeterProvider.acquireSession()
                hasActiveSession = true
            }
        }
        .onDisappear {
            if hasActiveSession {
                ledMeterProvider.releaseSession()
                hasActiveSession = false
            }
        }
        .onChange(of: cutoffHz) { _, _ in applyLedConfig() }
        .onChange(of: speed) { _, _ in applyLedConfig() }
        .onChange(of: ledCount) { _, _ in applyLedConfig() }
        .onChange(of: brightnessLevels) { _, _ in applyLedConfig() }
    }

    private var visualConfigSection: some View {
        SettingsSection("settings.led.config") {
            VStack(spacing: 16) {
                ledCountPicker
                brightnessLevelsPicker
            }
        }
    }

    private var ledCountPicker: some View {
        HStack(spacing: 8) {
            Text("settings.led.count")
                .settingsRowLabelStyle()
            Spacer()
            SlidingSelector(
                segments: [9, 11, 13, 15],
                selection: $ledCount,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(themeStore.accentColor.opacity(0.18))
                },
                content: { count, isSelected in
                    Text("\(count)")
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                }
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var brightnessLevelsPicker: some View {
        HStack(spacing: 8) {
            Text("settings.led.brightness")
                .settingsRowLabelStyle()
            Spacer()
            SlidingSelector(
                segments: [3, 5, 7],
                selection: $brightnessLevels,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(themeStore.accentColor.opacity(0.18))
                },
                content: { level, isSelected in
                    Text("\(level)")
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                }
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var tuningSection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 16) {
                tuningSlidersContent
            }
        }
    }

    private var tuningSlidersContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.frequency")
                        .settingsRowLabelStyle()
                    Spacer()
                    Text(String(format: "%.0f Hz", cutoffHz))
                        .font(presentationStyle.rowValueFont)
                        .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                }
                Slider(value: $cutoffHz, in: 200...6000, step: 100)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.speed")
                        .settingsRowLabelStyle()
                    Spacer()
                    Text(String(format: "%.2fx", speed))
                        .font(presentationStyle.rowValueFont)
                        .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                }
                Slider(value: $speed, in: 0.5...2.0, step: 0.05)
            }
        }
        .padding(.horizontal, 10)
    }

    private func applyLedConfig() {
        settings.ledCutoffHz = cutoffHz
        settings.ledSpeed = speed
        settings.ledCount = ledCount
        settings.ledBrightnessLevels = brightnessLevels

        ledMeterProvider.getOrCreate().updateConfig(
            LEDMeterConfig(
                ledCount: ledCount,
                levels: brightnessLevels,
                cutoffHz: Float(cutoffHz),
                sensitivity: LEDDefaults.sensitivity,
                speed: Float(speed),
                targetHz: LEDDefaults.targetHz
            )
        )
    }
}
