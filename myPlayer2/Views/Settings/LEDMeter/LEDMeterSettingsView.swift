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
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var sensitivity: Float = AppSettings.shared.ledSensitivity
    @State private var cutoffHz: Double = AppSettings.shared.ledCutoffHz
    @State private var speed: Double = AppSettings.shared.ledSpeed
    @State private var targetHz: Int = AppSettings.shared.ledTargetHz
    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("settings.section.led", systemImage: "waveform.path.ecg")

            // Live Preview
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.led.live_preview")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                let ledMeter = ledMeterProvider.getOrCreate()
                
                LedMeterView(
                    level: Double(ledMeter.normalizedLevel),
                    ledValues: ledMeter.metrics.leds,
                    dotSize: 14,
                    spacing: 7
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.primary.opacity(0.05))
                )
            }

            // Visual Config
            visualConfigSection

            // Tuning Sliders
            tuningSection
        }
        .onAppear {
            sensitivity = settings.ledSensitivity
            cutoffHz = settings.ledCutoffHz
            speed = settings.ledSpeed
            targetHz = settings.ledTargetHz
            ledCount = settings.ledCount
            brightnessLevels = settings.ledBrightnessLevels
        }
        .onChange(of: sensitivity) { _, _ in applyLedConfig() }
        .onChange(of: cutoffHz) { _, _ in applyLedConfig() }
        .onChange(of: speed) { _, _ in applyLedConfig() }
        .onChange(of: targetHz) { _, _ in applyLedConfig() }
        .onChange(of: ledCount) { _, _ in applyLedConfig() }
        .onChange(of: brightnessLevels) { _, _ in applyLedConfig() }
    }

    private var visualConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.led.config")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(spacing: 16) {
                    ledCountPicker
                    brightnessLevelsPicker
                    Divider()
                    sensitivitySlider
                    Divider()
                    tuningSlidersContent
                }
                .padding(16)
            }
        }
    }

    private var ledCountPicker: some View {
        HStack(spacing: 8) {
            Text("settings.led.count")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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

    private var sensitivitySlider: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("settings.led.sensitivity")
                Spacer()
                Text(String(format: "%.1fx", sensitivity))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $sensitivity, in: 0.5...1.5)
            Text("settings.led.sensitivity_desc")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
    }

    private var tuningSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                tuningSlidersContent
            }
            .padding(12)
        }
    }

    private var tuningSlidersContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.frequency")
                    Spacer()
                    Text(String(format: "%.0f Hz", cutoffHz))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $cutoffHz, in: 200...6000, step: 100)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.speed")
                    Spacer()
                    Text(String(format: "%.2fx", speed))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speed, in: 0.5...2.0, step: 0.05)
            }

            refreshRatePicker
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
    }

    private var refreshRatePicker: some View {
        HStack(spacing: 8) {
            Text("settings.led.publish_rate")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            SlidingSelector(
                segments: [30, 60],
                selection: $targetHz,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(themeStore.accentColor.opacity(0.18))
                },
                content: { hz, isSelected in
                    Text("\(hz) Hz")
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

    private func applyLedConfig() {
        settings.ledSensitivity = sensitivity
        settings.ledCutoffHz = cutoffHz
        settings.ledSpeed = speed
        settings.ledTargetHz = targetHz
        settings.ledCount = ledCount
        settings.ledBrightnessLevels = brightnessLevels

        ledMeterProvider.getOrCreate().updateConfig(
            LEDMeterConfig(
                ledCount: ledCount,
                levels: brightnessLevels,
                cutoffHz: Float(cutoffHz),
                sensitivity: sensitivity,
                speed: Float(speed),
                targetHz: targetHz
            )
        )
    }
}
