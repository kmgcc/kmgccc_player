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
    @Environment(LEDMeterService.self) private var ledMeter
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var sensitivity: Float = AppSettings.shared.ledSensitivity
    @State private var cutoffHz: Double = AppSettings.shared.ledCutoffHz
    @State private var preGain: Double = AppSettings.shared.ledPreGain
    @State private var speed: Double = AppSettings.shared.ledSpeed
    @State private var targetHz: Int = AppSettings.shared.ledTargetHz
    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels
    @State private var lookaheadMs: Double = AppSettings.shared.lookaheadMs

    @AppStorage("ledTransientThreshold") private var transientThreshold: Double = 12.0
    @AppStorage("ledTransientIntensity") private var transientIntensity: Double = 4.0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("settings.section.led", systemImage: "waveform.path.ecg")

            // Live Preview
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.led.live_preview")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

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
            preGain = settings.ledPreGain
            speed = settings.ledSpeed
            targetHz = settings.ledTargetHz
            ledCount = settings.ledCount
            brightnessLevels = settings.ledBrightnessLevels
            lookaheadMs = settings.lookaheadMs
        }
        .onChange(of: sensitivity) { _, _ in applyLedConfig() }
        .onChange(of: cutoffHz) { _, _ in applyLedConfig() }
        .onChange(of: preGain) { _, _ in applyLedConfig() }
        .onChange(of: speed) { _, _ in applyLedConfig() }
        .onChange(of: targetHz) { _, _ in applyLedConfig() }
        .onChange(of: ledCount) { _, _ in applyLedConfig() }
        .onChange(of: brightnessLevels) { _, _ in applyLedConfig() }
        .onChange(of: lookaheadMs) { _, newValue in settings.lookaheadMs = newValue }
        .onChange(of: transientThreshold) { _, _ in applyLedConfig() }
        .onChange(of: transientIntensity) { _, _ in applyLedConfig() }
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
            HStack(spacing: 4) {
                ForEach([9, 11, 13, 15], id: \.self) { count in
                    Button {
                        ledCount = count
                    } label: {
                        Text("\(count)")
                            .font(.system(size: 11, weight: ledCount == count ? .medium : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule()
                            .fill(ledCount == count ? themeStore.accentColor.opacity(0.18) : Color.clear)
                    )
                    .foregroundStyle(ledCount == count ? themeStore.accentColor : .secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private var brightnessLevelsPicker: some View {
        HStack(spacing: 8) {
            Text("settings.led.brightness")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach([3, 5, 7], id: \.self) { level in
                    Button {
                        brightnessLevels = level
                    } label: {
                        Text("\(level)")
                            .font(.system(size: 11, weight: brightnessLevels == level ? .medium : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule()
                            .fill(brightnessLevels == level ? themeStore.accentColor.opacity(0.18) : Color.clear)
                    )
                    .foregroundStyle(brightnessLevels == level ? themeStore.accentColor : .secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
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
            Slider(value: $sensitivity, in: 0.5...3.0)
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
                    Text("settings.led.pregain")
                    Spacer()
                    Text(String(format: "%.2fx", preGain))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $preGain, in: 0.0...2.0, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.transient_threshold")
                    Spacer()
                    Text(String(format: "%.1f dB", transientThreshold))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $transientThreshold, in: 1.0...12.0, step: 0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.transient_intensity")
                    Spacer()
                    Text(String(format: "%.1fx", transientIntensity))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $transientIntensity, in: 0.0...4.0, step: 0.1)
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

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.lookahead")
                    Spacer()
                    Text(String(format: "%.0f ms", lookaheadMs))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $lookaheadMs, in: 0...500, step: 10)
                Text("settings.led.lookahead_desc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            HStack(spacing: 4) {
                ForEach([30, 60], id: \.self) { hz in
                    Button {
                        targetHz = hz
                    } label: {
                        Text("\(hz) Hz")
                            .font(.system(size: 11, weight: targetHz == hz ? .medium : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule()
                            .fill(targetHz == hz ? themeStore.accentColor.opacity(0.18) : Color.clear)
                    )
                    .foregroundStyle(targetHz == hz ? themeStore.accentColor : .secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private func applyLedConfig() {
        settings.ledSensitivity = sensitivity
        settings.ledCutoffHz = cutoffHz
        settings.ledPreGain = preGain
        settings.ledSpeed = speed
        settings.ledTargetHz = targetHz
        settings.ledCount = ledCount
        settings.ledBrightnessLevels = brightnessLevels
        settings.lookaheadMs = lookaheadMs

        ledMeter.updateConfig(
            LEDMeterConfig(
                ledCount: ledCount,
                levels: brightnessLevels,
                cutoffHz: Float(cutoffHz),
                preGain: Float(preGain),
                sensitivity: sensitivity,
                speed: Float(speed),
                targetHz: targetHz,
                transientThreshold: Float(transientThreshold),
                transientIntensity: Float(transientIntensity)
            )
        )
    }
}