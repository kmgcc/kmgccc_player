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
                dominantColor: context.theme.artworkAverageColor ?? context.theme.artworkPalette.first,
                trackID: context.track?.id,
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
        let storedBlurRadius = UserDefaults.standard.double(forKey: "skin.coverGradientBlur.maxBlurRadius")
        let storedTransitionWidth = UserDefaults.standard.double(forKey: "skin.coverGradientBlur.transitionWidth")
        let storedColorIntensity = UserDefaults.standard.double(forKey: "skin.coverGradientBlur.colorOverlayIntensity")

        let blurRadius: CGFloat = storedBlurRadius > 0 ? storedBlurRadius : 80.0
        let transitionWidth: CGFloat = storedTransitionWidth > 0 ? storedTransitionWidth : 0.5
        let colorIntensity: CGFloat = storedColorIntensity > 0 ? storedColorIntensity : 0.65

        // Convert transitionWidth to blur ratios
        // transitionWidth 0.5 means blur starts at 0.25 and ends at 0.75 of canvas
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
            blurCurveGamma: 5.0
        )
    }
}

// MARK: - Background View Wrapper

private struct CoverGradientBlurSkinBackground: View {
    let context: SkinContext

    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 80
    @AppStorage("skin.coverGradientBlur.transitionWidth") private var transitionWidth: Double = 0.5
    @AppStorage("skin.coverGradientBlur.colorOverlayIntensity") private var colorOverlayIntensity: Double = 0.7
    @AppStorage("skin.coverGradientBlur.debugMode") private var debugMode: Bool = false
    @AppStorage("skin.coverGradientBlur.debugStage") private var debugStageStr: String = "D"

    private var config: CoverGradientBlurConfig {
        let transitionW = CGFloat(transitionWidth)
        let blurStartRatio = max(0, min(1, 0.5 - transitionW * 0.5))
        let blurEndRatio = max(0, min(1, 0.5 + transitionW * 0.5))
        
        return CoverGradientBlurConfig(
            blurRadius: CGFloat(maxBlurRadius),
            colorOverlayOpacity: CGFloat(colorOverlayIntensity),
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
            dominantColor: context.theme.artworkAverageColor,
            trackID: context.track?.id,
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
    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 80
    @AppStorage("skin.coverGradientBlur.transitionWidth") private var transitionWidth: Double = 0.5
    @AppStorage("skin.coverGradientBlur.colorOverlayIntensity") private var colorOverlayIntensity: Double = 0.7
    
    // Debug mode settings
    @AppStorage("skin.coverGradientBlur.debugMode") private var debugMode: Bool = false
    @AppStorage("skin.coverGradientBlur.debugStage") private var debugStage: String = "D"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Max Blur Radius
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("模糊半径")
                    Spacer()
                    Text("\(Int(maxBlurRadius))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $maxBlurRadius, in: 20...150, step: 5)
            }

            // Transition Width
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("过渡宽度")
                    Spacer()
                    Text(String(format: "%.2f", transitionWidth))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $transitionWidth, in: 0.3...0.8, step: 0.05)
            }

            // Color Overlay Intensity
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("色彩覆盖强度")
                    Spacer()
                    Text(String(format: "%.2f", colorOverlayIntensity))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $colorOverlayIntensity, in: 0...1.0, step: 0.05)
            }
            
            Divider()
            
            // Debug Mode Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("调试模式")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $debugMode)
                }
                
                if debugMode {
                    Text("选择调试阶段:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Picker("调试阶段", selection: $debugStage) {
                        Text("Stage A: 仅封面").tag("A")
                        Text("Stage B: + Edge Extension").tag("B")
                        Text("Stage C: + Blur").tag("C")
                        Text("Stage D: 完整效果").tag("D")
                    }
                    .pickerStyle(.radioGroup)
                    
                    Text("查看 Console.app 中的 [Edge] 日志")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }
}
