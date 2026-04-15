//
//  FullscreenCoverGradientBlurSkin.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Cover Gradient Blur theme
//

import AppKit
import SwiftUI

struct CoverGradientBlurTheme: SkinTheme {
    let id = "fullscreen.coverGradientBlur"
    let name = NSLocalizedString("skin.cover_gradient_blur.name", comment: "")
    let detail = NSLocalizedString("skin.cover_gradient_blur.detail", comment: "")
    let systemImage = "photo.fill"
    let normal: (any NormalSkin)? = nil
    let fullscreen: (any FullscreenSkin)? = CoverGradientBlurFullscreenSkin()
}

struct CoverGradientBlurFullscreenSkin: FullscreenSkin {
    var wantsCoverBlurLyricsTreatment: Bool { true }
    var allowsHostArtBackground: Bool { false }

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(
            CoverGradientBlurBackgroundView(
                artworkData: context.track?.artworkData,
                artworkImage: context.track?.artworkImage,
                artworkChecksum: context.track?.artworkChecksum ?? 0,
                dominantColor: context.theme.artworkAverageColor ?? context.theme.artworkPalette.first,
                config: Self.configFromSettings()
            )
        )
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(EmptyView())
    }

    func makeSettingsView(actions _: SkinHostActions) -> AnyView? {
        AnyView(CoverGradientBlurSettingsView())
    }

    static func configFromSettings() -> CoverGradientBlurConfig {
        let storedBlurRadius = UserDefaults.standard.double(
            forKey: "skin.coverGradientBlur.maxBlurRadius")
        let storedEdgeFillMode = UserDefaults.standard.string(
            forKey: "skin.coverGradientBlur.edgeFillMode")

        let blurRadius: CGFloat = storedBlurRadius > 0 ? storedBlurRadius : 200.0
        let transitionWidth: CGFloat = 0.8
        let colorIntensity: CGFloat = 0.5
        let edgeFillMode = CoverEdgeFillMode(rawValue: storedEdgeFillMode ?? "") ?? .pixelStretch

        let blurStartRatio = max(0, min(1, 0.5 - transitionWidth * 0.5))
        let blurEndRatio = max(0, min(1, 0.5 + transitionWidth * 0.5))

        return CoverGradientBlurConfig(
            blurRadius: blurRadius,
            colorOverlayOpacity: colorIntensity,
            transitionDuration: 0.4,
            edgeStripWidth: 3.0,
            blurStartRatio: blurStartRatio,
            blurEndRatio: blurEndRatio,
            overlayOffsetRatio: 0.15,
            blurCurveGamma: 5.0,
            edgeFillMode: edgeFillMode
        )
    }
}

private struct CoverGradientBlurSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore

    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 1600
    @AppStorage("skin.coverGradientBlur.edgeFillMode") private var edgeFillMode: String =
        CoverEdgeFillMode.pixelStretch.rawValue

    private var currentEdgeFillMode: CoverEdgeFillMode {
        CoverEdgeFillMode(rawValue: edgeFillMode) ?? .pixelStretch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            edgeFillModePicker
            blurRadiusSlider
        }
        .padding(.vertical, 6)
    }

    private var edgeFillModePicker: some View {
        HStack(spacing: 8) {
            Text("右侧填充")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                ForEach(CoverEdgeFillMode.allCases, id: \.rawValue) { mode in
                    modeButton(for: mode)
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

    private func modeButton(for mode: CoverEdgeFillMode) -> some View {
        let selected = currentEdgeFillMode == mode

        return Button {
            edgeFillMode = mode.rawValue
        } label: {
            Text(mode.displayName)
                .font(.system(size: 11, weight: selected ? .medium : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
            Capsule()
                .fill(selected ? themeStore.accentColor.opacity(0.18) : Color.clear)
        )
        .foregroundStyle(selected ? themeStore.accentColor : .secondary)
    }

    private var blurRadiusSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("模糊强度")
                Spacer()
                Text(String(format: "%.0f", maxBlurRadius))
                    .foregroundStyle(themeStore.accentColor)
                    .font(.system(.subheadline, design: .monospaced))
            }

            Slider(value: $maxBlurRadius, in: 100...2400, step: 50)

            Text("调整封面扩散背景的最大模糊半径。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
