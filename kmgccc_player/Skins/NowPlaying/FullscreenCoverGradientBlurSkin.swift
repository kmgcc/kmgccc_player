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
            CoverGradientBlurSkinBackgroundBridge(context: context, config: makeConfigFromSettings())
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

        // Fall back to the slider's own default (1600) — not 200 — when the
        // slider was never touched, so the rendered blur matches the value the
        // settings UI shows and the far edge actually reaches several hundred px.
        let blurRadius: CGFloat = storedBlurRadius > 0 ? storedBlurRadius : 1600.0
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
            edgeFillMode: edgeFillMode,
            // Confine the in-cover blur to a narrow strip hugging the right edge
            // (30% of the cover width, not the 0.48 default's ~half): the cover's
            // left ~78% stays crisp and only a thin near-edge band ramps up.
            // Smaller = narrower blurred strip (clearer cover) but the curve must
            // be steeper to keep the edge value up; larger = wider soft band.
            blurStartRatioFromEdge: 0.30,
            // In-cover ramp across the narrow strip: ~0 at the start so the strip's
            // inner side blends into the crisp cover, accelerating to a stronger
            // edge value (~0.19 of the radius ≈ 28px) so the cover↔stretch junction
            // is well masked and the fill has a high base for the linear floor to
            // grow from. Raised from ~22px, which left the junction too sharp.
            // Bigger quadratic term = bigger edge; the negative cubic keeps the
            // curve ≤ 1 at the far right.
            blurAlphaCoefficients: (0, 0, 1.8, -0.8),
            // Adds a continuous blur ramp across the fill (pixel-stretch) region:
            // 0 at the cover's right edge, easing up smoothly toward the right.
            // The mask is 0 inside the cover, so the cover interior is untouched.
            // This makes the fill connect to the cover at a low blur and increase
            // continuously, with no hard seam at the cover→fill boundary.
            extensionFloorStrength: 0.2
        )
    }
}

// MARK: - Background View Wrapper (SemanticPalette bridge)

/// Thin wrapper that reads `themeStore.semanticPalette.coverGradientDominant` from the
/// SwiftUI environment and forwards it as the dominant color, replacing the old
/// `context.theme.artworkAverageColor` source.
private struct CoverGradientBlurSkinBackgroundBridge: View {
    let context: SkinContext
    let config: CoverGradientBlurConfig

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var transitionBlurProgress: CGFloat = 0
    @State private var blurResetTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let centeredVisible = context.usesFullscreenPlayerLayout && !context.lyricsVisible

            ZStack {
                backgroundLayers(size: geometry.size, centeredVisible: centeredVisible)

                backgroundLayers(size: geometry.size, centeredVisible: centeredVisible)
                    .blur(radius: transitionBlurRadius, opaque: true)
                    .opacity(Double(transitionBlurOpacity))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .compositingGroup()
            .animation(layoutAnimation, value: centeredVisible)
            .onChange(of: centeredVisible) { _, _ in
                runTransitionBlur()
            }
        }
        .onDisappear {
            blurResetTask?.cancel()
        }
    }

    private var layoutAnimation: Animation {
        if context.theme.reduceMotion {
            return .easeInOut(duration: 0.42)
        }
        return .timingCurve(0.24, 0.72, 0.18, 1.0, duration: 0.82)
    }

    private var blurRiseAnimation: Animation {
        context.theme.reduceMotion
            ? .easeInOut(duration: 0.14)
            : .easeOut(duration: 0.28)
    }

    private var blurFallAnimation: Animation {
        context.theme.reduceMotion
            ? .easeInOut(duration: 0.26)
            : .timingCurve(0.18, 0.86, 0.24, 1.0, duration: 0.92)
    }

    private var transitionBlurRadius: CGFloat {
        36 * easedTransitionBlurProgress
    }

    private var transitionBlurOpacity: CGFloat {
        smoothstep(edge0: 0, edge1: 0.25, value: transitionBlurProgress)
    }

    private var easedTransitionBlurProgress: CGFloat {
        smoothstep(edge0: 0, edge1: 1, value: transitionBlurProgress)
    }

    private func runTransitionBlur() {
        blurResetTask?.cancel()
        withAnimation(blurRiseAnimation) {
            transitionBlurProgress = 1
        }

        blurResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(blurFallAnimation) {
                transitionBlurProgress = 0
            }
        }
    }

    @ViewBuilder
    private func backgroundLayers(size: CGSize, centeredVisible: Bool) -> some View {
        ZStack {
            CoverGradientBlurBackgroundView(
                artworkData: context.track?.artworkData,
                artworkImage: context.track?.artworkImage,
                artworkChecksum: context.track?.artworkChecksum ?? 0,
                dominantColor: themeStore.semanticPalette.coverGradientDominant,
                config: config(for: .leading)
            )
            .frame(width: size.width, height: size.height)
            .opacity(centeredVisible ? 0 : 1)

            CoverGradientBlurBackgroundView(
                artworkData: context.track?.artworkData,
                artworkImage: context.track?.artworkImage,
                artworkChecksum: context.track?.artworkChecksum ?? 0,
                dominantColor: themeStore.semanticPalette.coverGradientDominant,
                config: config(for: .centeredSymmetric)
            )
            .frame(width: size.width, height: size.height)
            .opacity(centeredVisible ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .allowsHitTesting(false)
    }

    private func config(
        for placement: CoverGradientBlurArtworkPlacement
    ) -> CoverGradientBlurConfig {
        var copy = config
        copy.artworkPlacement = placement
        if placement == .centeredSymmetric {
            copy.blurStartRatioFromEdge = 0.22
            copy.blurAlphaCoefficients = (0, 0, 1.35, -0.55)
            copy.extensionFloorStrength = min(copy.extensionFloorStrength, 0.16)
        }
        return copy
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        let span = max(.leastNonzeroMagnitude, edge1 - edge0)
        let t = max(0, min(1, (value - edge0) / span))
        return t * t * (3 - 2 * t)
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
            dominantColor: themeStore.semanticPalette.coverGradientDominant,
            config: config
        )
        .ignoresSafeArea()
    }

    @EnvironmentObject private var themeStore: ThemeStore
}

// MARK: - Artwork View

private struct CoverGradientBlurArtwork: View {
    let context: SkinContext
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Fullscreen Fine-tuning Constants
    private let fullscreenArtworkBoost: CGFloat = 1.15
    private let fullscreenLeftShift: CGFloat = -36

    var body: some View {
        let contentSize = context.contentSize
        let usesFullscreenLayout = context.usesFullscreenPlayerLayout

        let artworkBoost = usesFullscreenLayout ? fullscreenArtworkBoost : 1.0
        let leftShift = (usesFullscreenLayout && context.lyricsVisible) ? fullscreenLeftShift : 0

        let scaleFactor: CGFloat = usesFullscreenLayout ? 0.55 : 0.5
        let maxSizeBase: CGFloat = usesFullscreenLayout ? 420 : 320
        let maxSize = maxSizeBase * artworkBoost
        let maxArtwork = min(contentSize.width * scaleFactor, contentSize.height * scaleFactor, maxSize)
        let artworkSize = max(180 * artworkBoost, maxArtwork)
        let yOffset: CGFloat = usesFullscreenLayout ? 24 : 16

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
                            ColorRenderingAdapter.makeSwiftUIColor(accentNSColor).opacity(0.6),
                            ColorRenderingAdapter.makeSwiftUIColor(accentNSColor).opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(placeholderIconColor)
                }
        }
    }

    private var accentNSColor: NSColor {
        if let accent = context.theme.artworkAccentColor {
            return NSColor(accent)
        }
        return NSColor.controlAccentColor
    }

    /// Placeholder icon colour follows the current colour scheme. Reusing the
    /// SwiftUI semantic `.primary` keeps it in sync with system foreground
    /// without introducing a second readability judgement just for this icon.
    private var placeholderIconColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.5)
            : Color.primary.opacity(0.45)
    }
}

// MARK: - Settings View

private struct CoverGradientBlurSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 1600
    @AppStorage("skin.coverGradientBlur.edgeFillMode") private var edgeFillMode: String = CoverEdgeFillMode.pixelStretch.rawValue
    @AppStorage("fullscreenDimmingIntensity") private var fullscreenDimmingIntensity: Double = 0.15

    private var currentEdgeFillMode: CoverEdgeFillMode {
        CoverEdgeFillMode(rawValue: edgeFillMode) ?? .pixelStretch
    }

    private var slidingKnobColor: Color {
        if presentationStyle.usesMaterialSectionCards {
            return FullscreenSelectionAccentStyle.dimmedAccentColor(
                from: themeStore.accentNSColor,
                lightnessDelta: 0.30
            )
        }
        return themeStore.accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            edgeFillModePicker

            blurRadiusSlider

            dimmingIntensitySlider
        }
        .padding(.vertical, 6)
    }

    private var edgeFillModePicker: some View {
        HStack(spacing: 8) {
            Text("右侧填充")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)

            Spacer()

            SlidingSelector(
                segments: CoverEdgeFillMode.allCases,
                selection: Binding(
                    get: { currentEdgeFillMode },
                    set: { edgeFillMode = $0.rawValue }
                ),
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(slidingKnobColor.opacity(0.18))
                },
                content: { mode, isSelected in
                    Text(mode.displayName)
                        .font(presentationStyle.segmentedLabelFont.weight(isSelected ? .medium : .regular))
                        .padding(.horizontal, presentationStyle.segmentedHorizontalPadding)
                        .padding(.vertical, presentationStyle.segmentedVerticalPadding)
                        .foregroundStyle(
                            isSelected
                                ? presentationStyle.selectedTextColor(accentColor: themeStore.accentColor)
                                : presentationStyle.secondaryTextColor
                        )
                }
            )
            .padding(.horizontal, presentationStyle.segmentedTrackHorizontalPadding)
            .padding(.vertical, presentationStyle.segmentedTrackVerticalPadding)
            .background(
                Capsule()
                    .fill(presentationStyle.segmentedTrackColor)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                presentationStyle.segmentedTrackStrokeColor,
                                lineWidth: presentationStyle.segmentedTrackStrokeColor == .clear ? 0 : 0.5
                            )
                            .allowsHitTesting(false)
                    )
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var blurRadiusSlider: some View {
        HStack(spacing: 12) {
            Text("模糊半径")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: 84, alignment: .leading)

            Slider(value: $maxBlurRadius, in: 100...2500, step: 100)
                .tint(themeStore.accentColor)
                .frame(maxWidth: .infinity)

            Text("\(Int(maxBlurRadius))")
                .font(presentationStyle.rowValueFont)
                .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                .lineLimit(1)
                // Don't let the value collapse into an ellipsis on narrower settings windows.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private var dimmingIntensitySlider: some View {
        HStack(spacing: 12) {
            Text("背景压暗强度")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: 84, alignment: .leading)

            Slider(value: $fullscreenDimmingIntensity, in: 0.0...0.5, step: 0.05)
                .tint(themeStore.accentColor)
                .frame(maxWidth: .infinity)

            Text(String(format: "%.0f%%", fullscreenDimmingIntensity * 100))
                .font(presentationStyle.rowValueFont)
                .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}
