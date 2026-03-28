//
//  FullscreenCoverGradientBlurSkin.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Cover Gradient Blur Skin
//

import AppKit
import SwiftUI

struct FullscreenCoverGradientBlurSkin: NowPlayingSkin {
    let id = "fullscreen.coverGradientBlur"
    let name = NSLocalizedString("skin.cover_gradient_blur.name", comment: "")
    let detail = NSLocalizedString("skin.cover_gradient_blur.detail", comment: "")
    let systemImage = "photo.fill"
    var isFullscreenCompatible: Bool { true }
    var isNowPlayingCompatible: Bool { false }

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(
            CoverGradientBlurBackgroundView(
                artworkData: context.track?.artworkData,
                artworkImage: context.track?.artworkImage,
                artworkChecksum: context.track?.artworkChecksum ?? 0,
                dominantColor: context.theme.artworkAverageColor ?? context.theme.artworkPalette.first,
                config: makeConfigFromSettings()
            )
        )
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        // This skin uses the background AS the artwork (full cover with blur)
        // No separate foreground artwork card needed
        AnyView(EmptyView())
    }

    var fullscreenSettingsView: AnyView? {
        AnyView(CoverGradientBlurSettingsView())
    }

    private func makeConfigFromSettings() -> CoverGradientBlurConfig {
        Self.configFromSettings()
    }

    static func configFromSettings() -> CoverGradientBlurConfig {
        let storedBlurRadius = UserDefaults.standard.double(forKey: "skin.coverGradientBlur.maxBlurRadius")
        let storedEdgeFillMode = UserDefaults.standard.string(forKey: "skin.coverGradientBlur.edgeFillMode")

        let blurRadius: CGFloat = storedBlurRadius > 0 ? storedBlurRadius : 200.0
        // Fixed values
        let transitionWidth: CGFloat = 0.8
        let colorIntensity: CGFloat = 0.5
        let edgeFillMode: CoverEdgeFillMode = CoverEdgeFillMode(rawValue: storedEdgeFillMode ?? "") ?? .pixelStretch

        // Convert transitionWidth to blur ratios
        // transitionWidth 0.8 means blur starts at 0.1 and ends at 0.9 of canvas
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

// MARK: - Background View Wrapper

private struct CoverGradientBlurSkinBackground: View {
    let context: SkinContext

    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 1600

    private var config: CoverGradientBlurConfig {
        // Fixed values
        let transitionW: CGFloat = 0.8
        let colorOverlayIntensity: CGFloat = 0.5
        let blurStartRatio = max(0, min(1, 0.5 - transitionW * 0.5))
        let blurEndRatio = max(0, min(1, 0.5 + transitionW * 0.5))
        
        return CoverGradientBlurConfig(
            blurRadius: CGFloat(maxBlurRadius),
            colorOverlayOpacity: colorOverlayIntensity,
            transitionDuration: 0.35,
            edgeStripWidth: 3.0,
            blurStartRatio: blurStartRatio,
            blurEndRatio: blurEndRatio,
            overlayOffsetRatio: 0.15,
            blurCurveGamma: 5.0
        )
    }

    var body: some View {
        CoverGradientBlurBackgroundView(
            artworkData: context.track?.artworkData,
            artworkImage: context.track?.artworkImage,
            artworkChecksum: context.track?.artworkChecksum ?? 0,
            dominantColor: context.theme.artworkAverageColor,
            config: config
        )
        .ignoresSafeArea()
    }
}

// MARK: - Artwork View

private struct CoverGradientBlurArtwork: View {
    let context: SkinContext
    @StateObject private var fullscreenManager = FullscreenWindowManager.shared

    // MARK: - Fullscreen Fine-tuning Constants
    private let fullscreenArtworkBoost: CGFloat = 1.15
    private let fullscreenLeftShift: CGFloat = -36

    var body: some View {
        let contentSize = context.contentSize
        let isFullscreen = fullscreenManager.isFullscreenActive

        let artworkBoost = isFullscreen ? fullscreenArtworkBoost : 1.0
        let leftShift = (isFullscreen && context.lyricsVisible) ? fullscreenLeftShift : 0

        let scaleFactor: CGFloat = isFullscreen ? 0.55 : 0.5
        let maxSizeBase: CGFloat = isFullscreen ? 420 : 320
        let maxSize = maxSizeBase * artworkBoost
        let maxArtwork = min(contentSize.width * scaleFactor, contentSize.height * scaleFactor, maxSize)
        let artworkSize = max(180 * artworkBoost, maxArtwork)
        let yOffset: CGFloat = isFullscreen ? 24 : 16

        artworkView
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: leftShift, y: yOffset)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let image = context.track?.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: accentNSColor).opacity(0.6),
                            Color(nsColor: accentNSColor).opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.5))
                }
        }
    }

    private var accentNSColor: NSColor {
        if let accent = context.theme.artworkAccentColor {
            return NSColor(accent)
        }
        return NSColor.controlAccentColor
    }
}

// MARK: - Settings View

private struct CoverGradientBlurSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 1600
    @AppStorage("skin.coverGradientBlur.edgeFillMode") private var edgeFillMode: String = CoverEdgeFillMode.pixelStretch.rawValue

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
        Button {
            edgeFillMode = mode.rawValue
        } label: {
            Text(mode.displayName)
                .font(.system(size: 11, weight: currentEdgeFillMode == mode ? .medium : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
            Capsule()
                .fill(currentEdgeFillMode == mode ? themeStore.accentColor.opacity(0.18) : Color.clear)
        )
        .foregroundStyle(
            currentEdgeFillMode == mode ? themeStore.accentColor : .secondary
        )
    }

    private var blurRadiusSlider: some View {
        HStack(spacing: 12) {
            Text("模糊半径")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Slider(value: $maxBlurRadius, in: 100...2500, step: 100)
                .tint(themeStore.accentColor)
                .frame(maxWidth: .infinity)

            Text("\(Int(maxBlurRadius))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(themeStore.accentColor)
                .lineLimit(1)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
