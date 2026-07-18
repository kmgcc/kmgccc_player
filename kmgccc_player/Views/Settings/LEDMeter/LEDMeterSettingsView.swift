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
    @Environment(\.settingsAppForegroundColors) private var appColors

    /// Hide the embedded "LED Meter" header when this view is rendered as a tab
    /// inside another settings container that already shows a title.
    let showTitle: Bool

    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels
    @State private var hasActiveSession: Bool = false

    init(showTitle: Bool = true) {
        self.showTitle = showTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.scaled(20)) {
            if showTitle {
                SettingsHeaderLabel("settings.section.led", systemImage: "waveform.path.ecg")
            }

            // Live Preview
            VStack(alignment: .leading, spacing: presentationStyle.scaled(12)) {
                SettingsSectionTitle("settings.led.live_preview")

                LedMeterView(
                    level: Double(ledMeterProvider.normalizedLevel),
                    ledValues: ledMeterProvider.metrics.leds,
                    dotSize: presentationStyle.scaled(14),
                    spacing: presentationStyle.scaled(7),
                    contentScale: presentationStyle.fullscreenScale,
                    isPlaying: playerVM.isPlaying
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, presentationStyle.scaled(40))
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: presentationStyle.scaled(16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: presentationStyle.scaled(16))
                        .strokeBorder(
                            presentationStyle.settingsPrimaryTextColor(appColors: appColors).opacity(0.05),
                            lineWidth: presentationStyle.scaledHairlineWidth
                        )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Visual Config
            visualConfigSection
        }
        .onAppear {
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
        .onChange(of: ledCount) { _, _ in applyLedConfig() }
        .onChange(of: brightnessLevels) { _, _ in applyLedConfig() }
    }

    private var visualConfigSection: some View {
        SettingsSection("settings.led.config") {
            VStack(spacing: presentationStyle.scaled(16)) {
                ledCountPicker
                brightnessLevelsPicker
            }
        }
    }

    private var ledCountPicker: some View {
        HStack(spacing: presentationStyle.scaled(8)) {
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
                        .fill(selectorKnobColor.opacity(0.18))
                },
                content: { count, isSelected in
                    Text("\(count)")
                        .font(.system(
                            size: presentationStyle.scaled(11),
                            weight: isSelected ? .medium : .regular
                        ))
                        .padding(.horizontal, presentationStyle.scaled(10))
                        .padding(.vertical, presentationStyle.scaled(4))
                        .foregroundStyle(
                            isSelected
                                ? presentationStyle.settingsSelectedTextColor(
                                    accentColor: themeStore.accentColor,
                                    appColors: appColors
                                )
                                : presentationStyle.settingsSecondaryTextColor(appColors: appColors)
                        )
                }
            )
            .padding(presentationStyle.scaled(3))
            .background(
                Capsule()
                    .fill(presentationStyle.settingsSegmentedTrackColor(appColors: appColors))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var brightnessLevelsPicker: some View {
        HStack(spacing: presentationStyle.scaled(8)) {
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
                        .fill(selectorKnobColor.opacity(0.18))
                },
                content: { level, isSelected in
                    Text("\(level)")
                        .font(.system(
                            size: presentationStyle.scaled(11),
                            weight: isSelected ? .medium : .regular
                        ))
                        .padding(.horizontal, presentationStyle.scaled(10))
                        .padding(.vertical, presentationStyle.scaled(4))
                        .foregroundStyle(
                            isSelected
                                ? presentationStyle.settingsSelectedTextColor(
                                    accentColor: themeStore.accentColor,
                                    appColors: appColors
                                )
                                : presentationStyle.settingsSecondaryTextColor(appColors: appColors)
                        )
                }
            )
            .padding(presentationStyle.scaled(3))
            .background(
                Capsule()
                    .fill(presentationStyle.settingsSegmentedTrackColor(appColors: appColors))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var selectorKnobColor: Color {
        presentationStyle.usesMaterialSectionCards
            ? presentationStyle.settingsPrimaryTextColor(appColors: appColors)
            : themeStore.accentColor
    }

    private func applyLedConfig() {
        settings.ledCount = ledCount
        settings.ledBrightnessLevels = brightnessLevels

        ledMeterProvider.updateConfig(
            LEDMeterConfig(
                ledCount: ledCount,
                levels: brightnessLevels,
                cutoffHz: Float(settings.ledCutoffHz),
                sensitivity: settings.ledSensitivity,
                speed: Float(settings.ledSpeed),
                targetHz: settings.ledTargetHz
            )
        )
    }
}
