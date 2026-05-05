//
//  ExpandableVolumeControl.swift
//  myPlayer2
//
//  kmgccc_player - Expandable Volume Control for Fullscreen Mini Player
//  Circle button that expands into a pill with volume slider on hover.
//  Expands to the LEFT (right edge stays fixed).
//

import AppKit
import Foundation
import SwiftUI

struct ExpandableVolumeControl: View {
    @Binding var volume: Double
    @Binding var isExpanded: Bool
    var scale: CGFloat = 1.0
    var onInteraction: () -> Void = {}
    var onHoverStateChanged: (Bool) -> Void = { _ in }
    var onAdjustingChanged: (Bool) -> Void = { _ in }
    var materialStyle: LiquidGlassPillMaterialStyle = .clear
    var isEnabled: Bool = true
    var usesAdaptiveForeground: Bool = false
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private let collapsedWidth: CGFloat = 60
    private let expandedWidth: CGFloat = 180
    private let controlHeight: CGFloat = 60
    private let iconAreaWidth: CGFloat = 60
    private let iconSize: CGFloat = 20
    
    // Scaled dimensions
    private var scaledCollapsedWidth: CGFloat { collapsedWidth * scale }
    private var scaledExpandedWidth: CGFloat { expandedWidth * scale }
    private var scaledControlHeight: CGFloat { controlHeight * scale }
    private var scaledIconAreaWidth: CGFloat { iconAreaWidth * scale }
    private var scaledIconSize: CGFloat { iconSize * scale }
    private var sliderTrailingPadding: CGFloat { 18 * scale }

    var body: some View {
        HStack(spacing: 0) {
            volumeIconButton

            sliderView
        }
        .frame(width: currentWidth, height: scaledControlHeight, alignment: .leading)
        .contentShape(Capsule())
        .liquidGlassPill(
            colorScheme: colorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            materialStyle: materialStyle,
            isFloating: true
        )
        .onHover { hovering in
            guard isEnabled else {
                isExpanded = false
                onHoverStateChanged(false)
                return
            }
            isExpanded = hovering
            onHoverStateChanged(hovering)
            if hovering {
                onInteraction()
            }
        }
        .animation(expandAnimation, value: isExpanded)
    }

    private var volumeIconButton: some View {
        Button(action: toggleMute) {
            Image(systemName: volumeIcon)
                .font(.system(size: scaledIconSize, weight: .semibold))
                .foregroundStyle(controlPrimaryColor)
                .opacity(isEnabled ? 1 : 0.4)
                .compositingGroup()
                .blendMode(isEnabled ? controlBlendMode : .normal)
                .frame(width: scaledIconAreaWidth, height: scaledControlHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("volume")
    }

    private var sliderView: some View {
        Slider(
            value: $volume,
            in: 0...1
        ) { editing in
            onAdjustingChanged(editing)
            if editing {
                onInteraction()
            }
        }
            .controlSize(.regular)
            .tint(controlPrimaryColor)
            .compositingGroup()
            .blendMode(controlBlendMode)
            .frame(maxWidth: .infinity)
            .padding(.trailing, sliderTrailingPadding)
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)
            .disabled(!isEnabled)
            .accessibilityHidden(!isExpanded)
            .onChange(of: volume) { _, _ in
                onInteraction()
            }
    }

    private var currentWidth: CGFloat {
        isExpanded ? scaledExpandedWidth : scaledCollapsedWidth
    }

    private var expandAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.18)
        }
        return .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)
    }

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
        Color(nsColor: controlPrimaryNSColor).opacity(0.96)
    }

    private var controlPrimaryNSColor: NSColor {
        if usesAdaptiveForeground,
           materialStyle == .clear,
           themeStore.hasArtworkThemeColor,
           FullscreenMiniPlayerView.shouldUseDarkArtworkForeground(
                for: themeStore.semanticPalette.analysis
           ) {
            return themeStore.semanticPalette.readableTextOnArtwork
        }
        return FullscreenMiniPlayerView.resolveControlAccentColor(from: themeStore.accentNSColor)
    }

    private var controlBlendMode: BlendMode {
        if usesAdaptiveForeground,
           materialStyle == .clear,
           themeStore.hasArtworkThemeColor,
           FullscreenMiniPlayerView.shouldUseDarkArtworkForeground(
                for: themeStore.semanticPalette.analysis
           ),
           ColorMath.relativeLuminance(of: controlPrimaryNSColor) < 0.58 {
            return .normal
        }
        return .screen
    }

    private func toggleMute() {
        guard isEnabled else { return }
        onInteraction()
        if volume > 0 {
            UserDefaults.standard.set(volume, forKey: "_expandableVolume_lastVolume")
            volume = 0
        } else {
            let lastVolume = UserDefaults.standard.double(forKey: "_expandableVolume_lastVolume")
            volume = lastVolume > 0 ? lastVolume : 0.5
        }
    }
}

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
