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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private let collapsedWidth: CGFloat = 60
    private let expandedWidth: CGFloat = 180
    private let controlHeight: CGFloat = 60
    private let iconAreaWidth: CGFloat = 60
    private let iconSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            volumeIconButton

            sliderView
        }
        .frame(width: currentWidth, height: controlHeight, alignment: .leading)
        .contentShape(Capsule())
        .liquidGlassPill(
            colorScheme: colorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            isFloating: true
        )
        .onHover { hovering in
            isExpanded = hovering
        }
        .animation(expandAnimation, value: isExpanded)
    }

    private var volumeIconButton: some View {
        Button(action: toggleMute) {
            Image(systemName: volumeIcon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(controlPrimaryColor)
                .compositingGroup()
                .blendMode(.screen)
                .frame(width: iconAreaWidth, height: controlHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("volume")
    }

    private var sliderView: some View {
        Slider(value: $volume, in: 0...1)
            .controlSize(.regular)
            .tint(controlPrimaryColor)
            .compositingGroup()
            .blendMode(.screen)
            .frame(maxWidth: .infinity)
            .padding(.trailing, 18)
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
    }

    private var currentWidth: CGFloat {
        isExpanded ? expandedWidth : collapsedWidth
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
        FullscreenMiniPlayerView.resolveControlPrimaryColor(from: themeStore.accentNSColor)
    }

    private func toggleMute() {
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
