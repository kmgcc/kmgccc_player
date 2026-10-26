//
//  LEDMeterSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - LED Meter Settings View
//

import SwiftUI

/// LED meter rows shown under an audio visualization selector while LED is
/// selected. The configuration is global, so every surface shares it.
struct LEDMeterSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels

    var body: some View {
        VStack(spacing: presentationStyle.scaled(16)) {
            ledCountPicker
            brightnessLevelsPicker
        }
        .onAppear {
            ledCount = settings.ledCount
            brightnessLevels = settings.ledBrightnessLevels
        }
        .onChange(of: ledCount) { _, _ in applyLedConfig() }
        .onChange(of: brightnessLevels) { _, _ in applyLedConfig() }
    }

    private var ledCountPicker: some View {
        HStack(spacing: presentationStyle.scaled(8)) {
            Text("settings.led.count")
                .settingsRowLabelStyle()
            Spacer()
            SlidingSelector(
                segments: [9, 11, 13, 15],
                selection: $ledCount,
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
