//
//  ExpandableVolumeControl.swift
//  myPlayer2
//
//  kmgccc_player - Expandable Volume Control for Fullscreen Mini Player
//  Circle button that expands into a pill with volume slider on hover.
//  Expands to the LEFT (right edge stays fixed).
//

import AppKit
import SwiftUI

/// Circular volume button that expands into a pill with slider on hover.
/// Expands to the LEFT (right edge stays fixed), used in fullscreen mini player.
struct ExpandableVolumeControl: View {
    @Binding var volume: Double
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private let buttonSize: CGFloat = 60
    private let iconSize: CGFloat = 20
    private let expandedWidth: CGFloat = 180
    private let animationDuration: Double = 0.25

    var body: some View {
        // Container with fixed right edge, expands to the left
        ZStack(alignment: .trailing) {
            // Background pill/glass effect - anchored to trailing (right)
            containerBackground
                .frame(width: isExpanded ? expandedWidth : buttonSize, height: buttonSize)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)

            // Content: slider + icon (icon always on the right)
            HStack(spacing: 0) {
                // Volume slider (visible on hover) - on the LEFT side
                if isExpanded {
                    Slider(value: $volume, in: 0...1)
                        .controlSize(.regular)
                        .tint(controlPrimaryColor)
                        .compositingGroup()
                        .blendMode(.screen)
                        .frame(width: expandedWidth - buttonSize - 16)
                        .padding(.leading, 12)
                        .transition(.opacity)
                }

                // Volume icon button (always visible, always on the RIGHT)
                Button(action: toggleMute) {
                    Image(systemName: volumeIcon)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(controlPrimaryColor)
                        .compositingGroup()
                        .blendMode(.screen)
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("volume")
            }
            // Keep content at trailing edge
            .frame(width: isExpanded ? expandedWidth : buttonSize, alignment: .trailing)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
        }
        .frame(width: isExpanded ? expandedWidth : buttonSize, height: buttonSize)
        .contentShape(Rectangle())
        .onHover { hovering in
            isExpanded = hovering
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var containerBackground: some View {
        if isExpanded {
            // Expanded pill shape
            Capsule()
                .fill(.clear)
                .liquidGlassPill(
                    colorScheme: colorScheme,
                    accentColor: nil as Color?,
                    prominence: .standard,
                    isFloating: true
                )
        } else {
            // Collapsed circle
            Circle()
                .fill(.clear)
                .liquidGlassCircle(
                    colorScheme: colorScheme,
                    accentColor: nil as Color?,
                    prominence: .standard,
                    isFloating: true
                )
        }
    }

    // MARK: - Helpers

    private var volumeIcon: String {
        if volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private var controlPrimaryColor: Color {
        // Use the same color logic as FullscreenMiniPlayerView
        Color(nsColor: resolveControlAccentColor(from: themeStore.accentNSColor)).opacity(0.96)
    }

    private func resolveControlAccentColor(from color: NSColor) -> NSColor {
        let minSaturation: CGFloat = 0.88
        let minLightness: CGFloat = 0.90
        let maxLightness: CGFloat = 0.98

        let saturated = enforceMinimumSaturation(color, minimumSaturation: minSaturation)
        let lifted = enforceMinimumLightness(saturated, minimumLightness: minLightness)
        return enforceMaximumLightness(lifted, maximumLightness: maxLightness)
    }

    private func enforceMinimumLightness(_ color: NSColor, minimumLightness: CGFloat) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetL = max(hsl.l, minimumLightness)
        if targetL <= hsl.l + 0.000_001 { return color }
        return colorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
    }

    private func enforceMaximumLightness(_ color: NSColor, maximumLightness: CGFloat) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetL = min(hsl.l, maximumLightness)
        if targetL >= hsl.l - 0.000_001 { return color }
        return colorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
    }

    private func enforceMinimumSaturation(_ color: NSColor, minimumSaturation: CGFloat) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetS = max(hsl.s, minimumSaturation)
        if targetS <= hsl.s + 0.000_001 { return color }
        return colorFromHsl(h: hsl.h, s: targetS, l: hsl.l)
    }

    private func hslComponents(from color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }

        let r = max(0, min(1, rgb.redComponent))
        let g = max(0, min(1, rgb.greenComponent))
        let b = max(0, min(1, rgb.blueComponent))

        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        let l = (maxV + minV) * 0.5

        var h: CGFloat = 0
        if delta > 0.000_001 {
            if maxV == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                h = ((b - r) / delta) + 2
            } else {
                h = ((r - g) / delta) + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }

        var s: CGFloat = 0
        if delta > 0.000_001 {
            s = delta / (1 - abs(2 * l - 1))
        }

        return (h: h, s: s, l: l)
    }

    private func colorFromHsl(h: CGFloat, s: CGFloat, l: CGFloat) -> NSColor {
        let hue = max(0, min(1, h))
        let sat = max(0, min(1, s))
        let lig = max(0, min(1, l))

        let c = (1 - abs(2 * lig - 1)) * sat
        let hPrime = hue * 6
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))

        var rp: CGFloat = 0
        var gp: CGFloat = 0
        var bp: CGFloat = 0

        switch hPrime {
        case 0..<1:
            rp = c; gp = x; bp = 0
        case 1..<2:
            rp = x; gp = c; bp = 0
        case 2..<3:
            rp = 0; gp = c; bp = x
        case 3..<4:
            rp = 0; gp = x; bp = c
        case 4..<5:
            rp = x; gp = 0; bp = c
        default:
            rp = c; gp = 0; bp = x
        }

        let m = lig - c * 0.5
        return NSColor(calibratedRed: max(0, min(1, rp + m)), green: max(0, min(1, gp + m)), blue: max(0, min(1, bp + m)), alpha: 1.0)
    }

    private func toggleMute() {
        if volume > 0 {
            // Store current volume and mute
            UserDefaults.standard.set(volume, forKey: "_expandableVolume_lastVolume")
            volume = 0
        } else {
            // Restore previous volume or default to 0.5
            let lastVolume = UserDefaults.standard.double(forKey: "_expandableVolume_lastVolume")
            volume = lastVolume > 0 ? lastVolume : 0.5
        }
    }
}

// MARK: - Preview

#Preview("Expandable Volume Control") { @MainActor in
    @Previewable @State var volume: Double = 0.7
    @Previewable @State var isExpanded: Bool = false

    HStack {
        Spacer()
        ExpandableVolumeControl(volume: $volume, isExpanded: $isExpanded)
    }
    .frame(width: 400, height: 200)
    .background(Color.black.opacity(0.8))
    .environmentObject(ThemeStore.shared)
}
