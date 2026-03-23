//
//  ExpandableVolumeControl.swift
//  myPlayer2
//
//  kmgccc_player - Expandable Volume Control for Fullscreen Mini Player
//  Circle button that expands into a pill with volume slider on hover.
//

import AppKit
import SwiftUI

/// Circular volume button that expands into a pill with slider on hover.
/// Used in fullscreen mini player, positioned to the right of the main pill.
struct ExpandableVolumeControl: View {
    @Binding var volume: Double
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private let buttonSize: CGFloat = 60
    private let iconSize: CGFloat = 20
    private let expandedWidth: CGFloat = 180
    private let animationDuration: Double = 0.25

    var body: some View {
        ZStack {
            // Background pill/glass effect
            containerBackground

            // Content: icon + slider
            HStack(spacing: 0) {
                // Volume icon button (always visible)
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
                .help(LocalizedStringKey("volume"))

                // Volume slider (visible on hover)
                if isHovered {
                    Slider(value: $volume, in: 0...1)
                        .controlSize(.regular)
                        .tint(controlPrimaryColor)
                        .compositingGroup()
                        .blendMode(.screen)
                        .frame(width: expandedWidth - buttonSize - 16)
                        .transition(.opacity)
                }
            }
            .padding(.trailing, isHovered ? 12 : 0)
        }
        .frame(width: isHovered ? expandedWidth : buttonSize, height: buttonSize)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var containerBackground: some View {
        if isHovered {
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
        FullscreenMiniPlayerView.resolveControlPrimaryColor(from: themeStore.accentNSColor)
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

    HStack(spacing: 20) {
        ExpandableVolumeControl(volume: $volume)
    }
    .frame(width: 400, height: 200)
    .background(Color.black.opacity(0.8))
    .environmentObject(ThemeStore.shared)
}
