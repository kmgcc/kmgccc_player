//
//  ClassicLEDSkin.swift
//  myPlayer2
//
//  kmgccc_player - Classic Cover Skin
//

import AppKit
import CoreGraphics
import CoreImage
import SwiftUI

struct ClassicLEDSkin: NowPlayingSkin {
    static let id: String = "coverLed"

    let id: String = ClassicLEDSkin.id
    let name: String = NSLocalizedString("skin.classic_led.name", comment: "")
    let detail: String = NSLocalizedString("skin.classic_led.detail", comment: "")
    let systemImage: String = "dot.radiowaves.left.and.right"
    var isFullscreenCompatible: Bool { true }
    var isNowPlayingCompatible: Bool { true }

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(ClassicLEDArtwork(context: context))
    }

    var settingsView: AnyView? {
        AnyView(ClassicLEDSkinNormalSettingsView())
    }

    var fullscreenSettingsView: AnyView? {
        AnyView(ClassicLEDSkinFullscreenSettingsView())
    }
}

private struct ClassicLEDArtwork: View {
    let context: SkinContext

    @AppStorage("skin.classicLED.visualizerMode") private var normalVisualizerMode: String = "off"
    @AppStorage("skin.classicLED.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "led"

    var body: some View {
        let visualizerMode = context.usesFullscreenPlayerLayout
            ? fullscreenVisualizerMode
            : normalVisualizerMode
        ClassicCoverArtworkView(
            context: context,
            visualizerMode: visualizerMode,
            presentation: .classic
        )
    }
}

struct ClassicCoverArtworkView: View {
    enum Presentation {
        case classic
        case appleStyle
    }

    let context: SkinContext
    let visualizerMode: String
    var forceBrightLEDColors: Bool = false
    var presentation: Presentation = .classic
    @Environment(\.displayScale) private var displayScale
    @AppStorage("skin.classicLED.artworkFrameMaskEnabled") private var artworkFrameMaskEnabled: Bool = true

    private var localArtworkScale: CGFloat {
        presentation == .classic && artworkFrameMaskEnabled ? 1.08 : 1.0
    }

    // MARK: - Fullscreen Fine-tuning Constants
    /// Slight boost to artwork size in fullscreen (1.0 = no change)
    private let fullscreenArtworkBoost: CGFloat = 1.22
    /// Additional visual scale applied to the cover stack in fullscreen.
    /// Applied via scaleEffect inside the scaled canvas, so it is
    /// resolution-stable (proportional to the base canvas, not screen pixels).
    private let fullscreenCoverScaleEffect: CGFloat = 1.2
    /// Window-only boost for the complete cover/effect stack.
    private let windowCoverScaleEffect: CGFloat = 1.08

    var body: some View {
        let contentSize = context.contentSize
        let usesFullscreenLayout = context.usesFullscreenPlayerLayout

        let artworkBoost = usesFullscreenLayout ? fullscreenArtworkBoost : 1.0
        let leftShift = FullscreenCoverHorizontalOffset.artworkOffsetX(for: context)

        let scaleFactor: CGFloat = usesFullscreenLayout ? 0.6 : 0.5
        let maxSizeBase: CGFloat = usesFullscreenLayout ? 480 : 360
        // Calculate base canvas size with boost, parent container handles the fullscreenScale
        let maxSize = maxSizeBase * artworkBoost
        let maxArtwork = min(contentSize.width * scaleFactor, contentSize.height * scaleFactor, maxSize)
        let artworkSize = max(180 * artworkBoost, maxArtwork) * localArtworkScale
        let effectSpacing: CGFloat = usesFullscreenLayout ? 32 : 24
        // yOffset should be fixed in base canvas coordinates, not scaled
        // Embedded fullscreen sits slightly lower than the dedicated fullscreen space,
        // so trim the fullscreen cover stack offset only for that host.
        let yOffset: CGFloat = usesFullscreenLayout
            ? (context.fullscreenHostMode == .embeddedWindow ? 12 : 32)
            : 18

        let dotSize: CGFloat = usesFullscreenLayout ? 14 : 12
        let spacing: CGFloat = usesFullscreenLayout ? 9 : 7

        VStack(spacing: effectSpacing) {
            artworkContainer(size: artworkSize)

            if visualizerMode == "led" {
                LiveLedMeterView(
                    dotSize: dotSize,
                    spacing: spacing,
                    pillTint: context.theme.artworkAccentColor,
                    isPlaying: context.playback.isPlaying,
                    forceBrightLEDColors: forceBrightLEDColors || context.theme.artBackgroundIsUltraDark,
                    levelToneVariant: presentation == .appleStyle ? .appleStyleBright : .skinLight
                )
            } else if visualizerMode == "spectrum" {
                PillSpectrumView(
                    context: context,
                    dotSize: dotSize,
                    spacing: spacing,
                    pillTint: context.theme.artworkAccentColor,
                    isFullscreen: usesFullscreenLayout
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(usesFullscreenLayout ? fullscreenCoverScaleEffect : windowCoverScaleEffect)
        .offset(x: leftShift, y: yOffset)
    }

    @ViewBuilder
    private func artworkContainer(size: CGFloat) -> some View {
        switch presentation {
        case .classic:
            ClassicArtworkCoverContainer(
                context: context,
                size: size,
                displayScale: displayScale
            )
        case .appleStyle:
            AppleStyleArtworkCoverContainer(
                context: context,
                size: size
            )
        }
    }
}

private struct ClassicArtworkCoverContainer: View {
    let context: SkinContext
    let size: CGFloat
    let displayScale: CGFloat

    @AppStorage("skin.classicLED.artworkFrameMaskEnabled") private var artworkFrameMaskEnabled: Bool = true
    @State private var maskRefreshToken = 0

    private let cornerRadius: CGFloat = 12

    var body: some View {
        classicCoverContent
            .id(maskRefreshToken)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onTapGesture {
                advanceArtworkFrameMask()
            }
    }

    @ViewBuilder
    private var classicCoverContent: some View {
        if let image = context.track?.artworkImage {
            if let mask = artworkFrameMask {
                ArtworkFrameMaskedImageView(
                    image: image,
                    mask: mask.image,
                    frameIndex: mask.index,
                    artworkChecksum: context.track?.artworkChecksum ?? 0,
                    size: size,
                    displayScale: displayScale
                )
            } else {
                RoundedCoverArtworkImage(image: image, size: size, cornerRadius: cornerRadius)
            }
        } else {
            ArtworkPlaceholderView.nowPlaying(
                size: min(context.contentSize.width, context.contentSize.height) * 0.5,
                cornerRadius: cornerRadius
            )
        }
    }

    private var artworkFrameMask: ClassicArtworkFrameMaskAsset? {
        guard artworkFrameMaskEnabled else {
            return nil
        }

        let assets = BKThemeAssets.shared
        let frameCount = assets.artworkFrameCount
        let key = ClassicArtworkFrameMaskKey(track: context.track)
        guard let index = ClassicArtworkFrameMaskSelection.shared.maskIndex(
            for: key,
            frameCount: frameCount
        ) else {
            return nil
        }
        // The completed mask stack is scaled after rasterization for frame-specific
        // visual tuning. Include that scale here so the final transform does not
        // enlarge a lower-resolution frame asset a second time.
        let finalScale = ClassicArtworkFrameCoverTuning.finalMaskedArtworkScale(for: index)
        let targetPixel = max(1, Int(ceil(size * max(1, displayScale) * finalScale)))
        let maxPixel = ((targetPixel + 127) / 128) * 128
        guard let image = assets.artworkFrame(at: index, maxPixel: maxPixel) else {
            return nil
        }
        return ClassicArtworkFrameMaskAsset(index: index, image: image)
    }

    private func advanceArtworkFrameMask() {
        guard artworkFrameMaskEnabled, context.track?.artworkImage != nil else {
            return
        }

        let assets = BKThemeAssets.shared
        let frameCount = assets.artworkFrameCount
        let key = ClassicArtworkFrameMaskKey(track: context.track)
        guard ClassicArtworkFrameMaskSelection.shared.advanceMask(
            for: key,
            frameCount: frameCount
        ) != nil else {
            return
        }

        maskRefreshToken &+= 1
    }
}

private struct ClassicArtworkFrameMaskAsset {
    let index: Int
    let image: CGImage
}

private enum ClassicArtworkFrameCoverTuning {
    /// Manual visual tuning point for the real cover before mirrored extension.
    ///
    /// Keys are zero-based frame indices:
    /// 0 = `artworkframe1.png`, 1 = `artworkframe2.png`,
    /// 2 = `artworkframe3.png`, 3 = `artworkframe4.png`.
    ///
    /// Lower values shrink the real cover more before the mirrored extension is
    /// clipped by the fixed-size artwork frame mask. Keep values below 1.0.
    static let artworkScaleByFrameIndex: [Int: CGFloat] = [
        0: 0.90,
        1: 0.86,
        2: 0.80,
        3: 0.76,
    ]

    static let fallbackArtworkScale: CGFloat = 0.86

    /// Manual visual tuning point for the finished masked cover as a whole.
    ///
    /// This is applied after the extended artwork has been clipped by the fixed
    /// artwork frame mask, so it scales the cover and mask result together.
    static let finalMaskedArtworkScaleByFrameIndex: [Int: CGFloat] = [
        0: 1.0,
        1: 1.06,
        2: 1.1,
        3: 1.2,
    ]

    static let fallbackFinalMaskedArtworkScale: CGFloat = 1.0
    /// v6: raster budgets include the final post-mask scale so enlarged frames
    /// retain their source detail instead of being upsampled at the last step.
    static let rendererVersion = 6

    static func artworkScale(for frameIndex: Int) -> CGFloat {
        min(1.0, max(0.50, artworkScaleByFrameIndex[frameIndex] ?? fallbackArtworkScale))
    }

    static func finalMaskedArtworkScale(for frameIndex: Int) -> CGFloat {
        min(1.50, max(0.50, finalMaskedArtworkScaleByFrameIndex[frameIndex] ?? fallbackFinalMaskedArtworkScale))
    }
}

private struct AppleStyleArtworkCoverContainer: View {
    let context: SkinContext
    let size: CGFloat

    private let cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            if let image = context.track?.artworkImage {
                RoundedCoverArtworkImage(image: image, size: size, cornerRadius: cornerRadius)
                    .blur(radius: 26)
                    .opacity(context.theme.colorScheme == .dark ? 0.34 : 0.26)
                    .allowsHitTesting(false)

                RoundedCoverArtworkImage(image: image, size: size, cornerRadius: cornerRadius)
            } else {
                ArtworkPlaceholderView.nowPlaying(
                    size: min(context.contentSize.width, context.contentSize.height) * 0.5,
                    cornerRadius: cornerRadius
                )
            }
        }
        .frame(width: size, height: size)
    }
}

private struct RoundedCoverArtworkImage: View {
    let image: NSImage
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct ArtworkFrameMaskedImageView: View {
    let image: NSImage
    let mask: CGImage
    let frameIndex: Int
    let artworkChecksum: UInt64
    let size: CGFloat
    let displayScale: CGFloat
    @AppStorage("skin.classicLED.edgeBlurEnabled") private var edgeBlurEnabled: Bool = true
    @State private var extendedArtworkImage: NSImage?
    @State private var extendedArtworkKey: String?
    // The artistic-edge mask and its final scale are committed TOGETHER with
    // `extendedArtworkImage`, never from the incoming params directly. On a track
    // switch the new mask would otherwise cut in immediately while the new cover
    // is still rendering, so the new mask shape briefly framed the previous
    // cover. Holding them here makes the mask wait and swap in a single step once
    // its own cover is ready.
    @State private var displayedMask: CGImage?
    @State private var displayedFinalScale: CGFloat = 1.0
    @State private var processingTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let extendedArtworkImage, let displayedMask {
                Image(nsImage: extendedArtworkImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .mask {
                        Image(decorative: displayedMask, scale: max(1, displayScale), orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipped()
                    }
                    .scaleEffect(displayedFinalScale)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            scheduleExtendedArtworkProcessing()
        }
        .onChange(of: processingKey) { _, _ in
            scheduleExtendedArtworkProcessing()
        }
        .onDisappear {
            processingTask?.cancel()
            processingTask = nil
        }
    }

    private var artworkScale: CGFloat {
        ClassicArtworkFrameCoverTuning.artworkScale(for: frameIndex)
    }

    private var finalMaskedArtworkScale: CGFloat {
        ClassicArtworkFrameCoverTuning.finalMaskedArtworkScale(for: frameIndex)
    }

    private var targetPixel: Int {
        // Keep the reflected artwork at the same backing-pixel density as the
        // final masked stack. The outer extension is otherwise rasterized at the
        // pre-scale size and then enlarged together with the mask.
        let rawPixel = max(1, Int(ceil(size * max(1, displayScale) * finalMaskedArtworkScale)))
        return ((rawPixel + 63) / 64) * 64
    }

    private var processingKey: String {
        [
            "v\(ClassicArtworkFrameCoverTuning.rendererVersion)",
            "checksum:\(artworkChecksum)",
            "frame:\(frameIndex)",
            "px:\(targetPixel)",
            "scale:\(String(format: "%.3f", Double(artworkScale)))",
            "final:\(String(format: "%.3f", Double(finalMaskedArtworkScale)))",
            "blur:\(edgeBlurEnabled)",
        ].joined(separator: "|")
    }

    private func scheduleExtendedArtworkProcessing() {
        let key = processingKey
        guard extendedArtworkKey != key else { return }

        processingTask?.cancel()
        guard let sourceImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            extendedArtworkImage = nil
            displayedMask = nil
            extendedArtworkKey = nil
            return
        }

        let outputPixel = targetPixel
        let scale = artworkScale
        // Capture the mask + final scale that belong to THIS render so they swap
        // in atomically with the finished cover (see `displayedMask`).
        let committedMask = mask
        let committedFinalScale = finalMaskedArtworkScale
        processingTask = Task(priority: .utility) {
            if let cached = await ClassicArtworkFrameExtendedArtworkCache.shared.image(for: key),
               !Task.isCancelled {
                await MainActor.run {
                    extendedArtworkImage = cached
                    displayedMask = committedMask
                    displayedFinalScale = committedFinalScale
                    extendedArtworkKey = key
                    processingTask = nil
                }
                return
            }

            let rendered = await Task.detached(priority: .utility) {
                ClassicArtworkFrameExtendedArtworkRenderer.render(
                    sourceImage: sourceImage,
                    outputPixel: outputPixel,
                    artworkScale: scale
                )
            }.value

            guard !Task.isCancelled, let rendered else { return }
            let renderedImage = NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
            await ClassicArtworkFrameExtendedArtworkCache.shared.setImage(renderedImage, for: key)

            await MainActor.run {
                extendedArtworkImage = renderedImage
                displayedMask = committedMask
                displayedFinalScale = committedFinalScale
                extendedArtworkKey = key
                processingTask = nil
            }
        }
    }
}

private actor ClassicArtworkFrameExtendedArtworkCache {
    static let shared = ClassicArtworkFrameExtendedArtworkCache()

    private var storage: [String: NSImage] = [:]
    private var keys: [String] = []
    private var costs: [String: Int] = [:]
    private var totalBytes = 0
    private let maxCount = 40
    private let maxTotalBytes = 32 * 1024 * 1024

    func image(for key: String) -> NSImage? {
        storage[key]
    }

    func setImage(_ image: NSImage, for key: String) {
        if storage[key] == nil {
            keys.append(key)
        }
        if let previousCost = costs[key] {
            totalBytes -= previousCost
        }
        storage[key] = image
        let cost = Self.estimatedCost(for: image)
        costs[key] = cost
        totalBytes += cost

        while keys.count > maxCount || totalBytes > maxTotalBytes {
            let oldest = keys.removeFirst()
            storage.removeValue(forKey: oldest)
            if let removedCost = costs.removeValue(forKey: oldest) {
                totalBytes -= removedCost
            }
        }
    }

    private static func estimatedCost(for image: NSImage) -> Int {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let size = image.size
        return max(1, Int(ceil(size.width)) * Int(ceil(size.height)) * 4)
    }
}

private enum ClassicArtworkFrameExtendedArtworkRenderer {
    nonisolated static func render(sourceImage: CGImage, outputPixel: Int, artworkScale: CGFloat) -> CGImage? {
        autoreleasepool {
            let outputPixel = max(1, outputPixel)
            let artworkScale = min(1.0, max(0.50, artworkScale))
            guard let croppedImage = squareCrop(sourceImage) else { return nil }
            // Trim uniform white/black border fringes (compression artifacts)
            // before mirror tiling, otherwise the seam between the fringe and the
            // reflected content reads as an ugly hard line around the cover.
            let squareImage = defringeUniformBorders(croppedImage) ?? croppedImage
            let colorSpace = sourceImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
            guard let colorSpace,
                  let context = CGContext(
                    data: nil,
                    width: outputPixel,
                    height: outputPixel,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return nil
            }

            let insetPixel = max(0, Int(round(CGFloat(outputPixel) * (1 - artworkScale) * 0.5)))
            let innerPixel = max(1, outputPixel - insetPixel * 2)
            let outputSize = CGFloat(outputPixel)
            let inset = CGFloat(insetPixel)
            let innerSize = CGFloat(innerPixel)
            let innerRect = CGRect(x: inset, y: inset, width: innerSize, height: innerSize)
            let minX = innerRect.minX
            let maxX = innerRect.maxX
            let minY = innerRect.minY
            let maxY = innerRect.maxY

            context.clear(CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
            context.interpolationQuality = .high
            context.setShouldAntialias(false)

            if insetPixel > 0 {
                drawReflected(
                    squareImage,
                    in: innerRect,
                    clippedTo: CGRect(x: 0, y: minY, width: inset, height: innerSize),
                    pivotX: minX,
                    pivotY: nil,
                    context: context
                )
                drawReflected(
                    squareImage,
                    in: innerRect,
                    clippedTo: CGRect(x: maxX, y: minY, width: inset, height: innerSize),
                    pivotX: maxX,
                    pivotY: nil,
                    context: context
                )
                drawReflected(
                    squareImage,
                    in: innerRect,
                    clippedTo: CGRect(x: minX, y: 0, width: innerSize, height: inset),
                    pivotX: nil,
                    pivotY: minY,
                    context: context
                )
                drawReflected(
                    squareImage,
                    in: innerRect,
                    clippedTo: CGRect(x: minX, y: maxY, width: innerSize, height: inset),
                    pivotX: nil,
                    pivotY: maxY,
                    context: context
                )
                drawReflected(
                    squareImage,
                    in: innerRect,
                    clippedTo: CGRect(x: 0, y: 0, width: inset, height: inset),
                    pivotX: minX,
                    pivotY: minY,
                    context: context
                )
                drawReflected(
                    squareImage,
                    in: innerRect,
                    clippedTo: CGRect(x: maxX, y: 0, width: inset, height: inset),
                    pivotX: maxX,
                    pivotY: minY,
                    context: context
                )
                drawReflected(
                    squareImage,
                    in: innerRect,
                    clippedTo: CGRect(x: 0, y: maxY, width: inset, height: inset),
                    pivotX: minX,
                    pivotY: maxY,
                    context: context
                )
                drawReflected(
                    squareImage,
                    in: innerRect,
                    clippedTo: CGRect(x: maxX, y: maxY, width: inset, height: inset),
                    pivotX: maxX,
                    pivotY: maxY,
                    context: context
                )
            }

            context.draw(squareImage, in: innerRect)
            guard let baseImage = context.makeImage() else { return nil }

            // Keep the real cover (innerRect) razor-sharp and ramp the mirrored
            // extension band from sharp at the cover edge to strongly blurred at
            // the outer edge. The band is narrow, so the ramp is deliberately
            // fast. When there is no extension band (insetPixel == 0) the base
            // image is returned unchanged.
            guard insetPixel > 0 else { return baseImage }
            let edgeBlurEnabled = UserDefaults.standard.object(forKey: "skin.classicLED.edgeBlurEnabled") as? Bool ?? true
            guard edgeBlurEnabled else { return baseImage }
            return progressiveEdgeBlur(
                base: baseImage,
                outputPixel: outputPixel,
                insetPixel: insetPixel
            ) ?? baseImage
        }
    }

    // MARK: - Progressive Edge Blur

    /// Max blur radius (device px) applied at the outermost edge of the
    /// mirrored extension band. The mask ramps this to 0 at the cover edge.
    private nonisolated static let edgeBlurMaxRadius: CGFloat = 64
    /// Ramp exponent (< 1 = concave = reaches heavy blur quickly just past the
    /// cover edge). The extension band is narrow, so the progression stays fast,
    /// but eased back from 0.42 so the onset just past the cover is gentler.
    private nonisolated static let edgeBlurRampExponent: Double = 0.55

    private nonisolated static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false,
    ])

    /// Blurs only the mirrored extension band of an already-rendered extended
    /// artwork, leaving the inner cover untouched.
    private nonisolated static func progressiveEdgeBlur(
        base: CGImage,
        outputPixel: Int,
        insetPixel: Int
    ) -> CGImage? {
        autoreleasepool {
            guard insetPixel > 0,
                  let mask = edgeBlurMask(outputPixel: outputPixel, insetPixel: insetPixel)
            else {
                return base
            }

            let canvasRect = CGRect(x: 0, y: 0, width: outputPixel, height: outputPixel)
            let baseCI = CIImage(cgImage: base)

            // Clamp so the variable blur samples extended edge pixels instead of
            // transparent canvas at the outer boundary.
            guard let clampFilter = CIFilter(name: "CIAffineClamp") else { return base }
            clampFilter.setValue(baseCI, forKey: kCIInputImageKey)
            clampFilter.setValue(CGAffineTransform.identity, forKey: kCIInputTransformKey)
            guard let clamped = clampFilter.outputImage else { return base }

            guard let blurFilter = CIFilter(name: "CIMaskedVariableBlur") else { return base }
            let radius = min(edgeBlurMaxRadius, CGFloat(insetPixel) * 0.95)
            blurFilter.setValue(clamped, forKey: kCIInputImageKey)
            blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
            blurFilter.setValue(CIImage(cgImage: mask), forKey: "inputMask")

            guard let output = blurFilter.outputImage?.cropped(to: canvasRect) else { return base }
            defer { ciContext.clearCaches() }
            return ciContext.createCGImage(output, from: canvasRect) ?? base
        }
    }

    /// Straight-alpha RGBA ramp mask consumed by `CIMaskedVariableBlur`:
    /// 0 (no blur) across the inner cover square, ramping to 1 (full blur)
    /// toward the outer edge over the `insetPixel`-wide band on all four sides
    /// and corners (box / Chebyshev distance from the inner rect). The
    /// (t,t,t,t) straight-alpha encoding matches the gradient-blur masks.
    private nonisolated static func edgeBlurMask(outputPixel: Int, insetPixel: Int) -> CGImage? {
        let n = max(1, outputPixel)
        let inset = max(1, insetPixel)
        guard inset * 2 < n else { return nil }

        // Band is narrow — precompute the ramp once per distance step.
        var ramp = [UInt8](repeating: 0, count: inset + 1)
        let invInset = 1.0 / Double(inset)
        for d in 0...inset {
            let t = min(1.0, Double(d) * invInset)
            let v = pow(t, edgeBlurRampExponent)
            ramp[d] = UInt8(max(0, min(255, (v * 255).rounded())))
        }

        let lowEdge = inset           // first inner column / row
        let highEdge = n - 1 - inset  // last inner column / row
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            let dyOut = max(0, max(lowEdge - y, y - highEdge))
            let rowBase = y * n * 4
            for x in 0..<n {
                let dxOut = max(0, max(lowEdge - x, x - highEdge))
                let d = max(dxOut, dyOut)
                guard d > 0 else { continue }  // inner cover stays sharp
                let v = ramp[min(d, inset)]
                let idx = rowBase + x * 4
                pixels[idx] = v
                pixels[idx + 1] = v
                pixels[idx + 2] = v
                pixels[idx + 3] = v
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: n,
            height: n,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: n * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private nonisolated static func drawReflected(
        _ image: CGImage,
        in imageRect: CGRect,
        clippedTo clipRect: CGRect,
        pivotX: CGFloat?,
        pivotY: CGFloat?,
        context: CGContext
    ) {
        context.saveGState()
        context.clip(to: clipRect)
        if let pivotX {
            context.translateBy(x: pivotX * 2, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        if let pivotY {
            context.translateBy(x: 0, y: pivotY * 2)
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(image, in: imageRect)
        context.restoreGState()
    }

    private nonisolated static func squareCrop(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let side = min(width, height)
        let rect = CGRect(
            x: CGFloat((width - side) / 2),
            y: CGFloat((height - side) / 2),
            width: CGFloat(side),
            height: CGFloat(side)
        )
        return image.cropping(to: rect) ?? image
    }

    // MARK: - Border Fringe Removal

    /// How far inward (px) we search for the first clean line on an edge, and
    /// the cap on how much a fringe may pull — so a misjudged or intentionally
    /// uniform border is never stretched across real content.
    private nonisolated static let defringeMaxDepth = 11
    /// Max per-channel spread the OUTERMOST line may have and still trigger
    /// detection (≈0.16). The fringe's outer line is flat; the deeper transition
    /// lines it then walks through are judged by luminance alone, so a 2-3px
    /// fringe with a blended inner line is still fully removed.
    private nonisolated static let defringeUniformTolerance = 40
    /// Max mean chroma for the outermost line to count as near-greyscale, so a
    /// uniform saturated colour edge is not mistaken for a white/black fringe.
    private nonisolated static let defringeChromaTolerance = 32
    /// How much brighter / darker than the interior reference the edge must be
    /// to count as a fringe. Relative detection catches pale fringes on pale art
    /// (which absolute thresholds miss) while ignoring faint natural variation.
    private nonisolated static let defringeRelativeMargin = 20
    /// Absolute luminance floor for a white fringe / ceiling for a black fringe,
    /// so a mid-grey edge is never called white or black purely on relative
    /// grounds.
    private nonisolated static let defringeWhiteFloor = 165
    private nonisolated static let defringeBlackCeiling = 90
    /// While walking inward, a line still belongs to the fringe until its
    /// luminance returns within this margin of the interior reference.
    private nonisolated static let defringeEndMargin = 12

    /// Detects and removes a uniform near-white or near-black fringe on each of
    /// the four edges independently (an edge without a fringe is left untouched).
    /// For each fringed edge it walks inward up to `defringeMaxDepth`, finds the
    /// first clean line, and replicates that line outward over the fringe — so
    /// the subsequent mirror tiling reflects real content instead of a hard
    /// white/black seam.
    private nonisolated static func defringeUniformBorders(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        // Need enough rows/cols for the interior reference lines (depth ≤ 18).
        guard width > 40, height > 40 else {
            return image
        }

        let bytesPerRow = width * 4
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return image }
        let ptr = raw.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        // Left edge:  lines step right (+4),     positions step down a row.
        defringeEdge(ptr, lineStart0: 0, lineStride: 4, posStride: bytesPerRow, posCount: height)
        // Right edge: lines step left (-4),      positions step down a row.
        defringeEdge(ptr, lineStart0: (width - 1) * 4, lineStride: -4, posStride: bytesPerRow, posCount: height)
        // Bottom edge: lines step up a row,      positions step right (+4).
        defringeEdge(ptr, lineStart0: 0, lineStride: bytesPerRow, posStride: 4, posCount: width)
        // Top edge:   lines step down a row,     positions step right (+4).
        defringeEdge(ptr, lineStart0: (height - 1) * bytesPerRow, lineStride: -bytesPerRow, posStride: 4, posCount: width)

        return context.makeImage()
    }

    private nonisolated static func defringeEdge(
        _ ptr: UnsafeMutablePointer<UInt8>,
        lineStart0: Int,
        lineStride: Int,
        posStride: Int,
        posCount: Int
    ) {
        let sampleStep = max(1, posCount / 64)

        func luma(atLine line: Int) -> Int {
            lineLuma(ptr, base: lineStart0 + line * lineStride, posStride: posStride, posCount: posCount, sampleStep: sampleStep)
        }

        // Interior reference: median luminance of a few lines well past any
        // plausible fringe. Detection is RELATIVE to this, so a pale fringe on
        // pale art is caught and a uniformly bright/dark image is not.
        var refs = [luma(atLine: 12), luma(atLine: 14), luma(atLine: 16), luma(atLine: 18)]
        refs.sort()
        let interiorLuma = (refs[1] + refs[2]) / 2

        // Trigger on the outermost line only: it must be flat, near-grey, and
        // pulled toward white or black relative to the interior.
        let edge = lineStats(ptr, base: lineStart0, posStride: posStride, posCount: posCount, sampleStep: sampleStep)
        guard edge.spread <= defringeUniformTolerance, edge.chroma <= defringeChromaTolerance else { return }

        let isWhite = edge.luma >= interiorLuma + defringeRelativeMargin && edge.luma >= defringeWhiteFloor
        let isBlack = edge.luma <= interiorLuma - defringeRelativeMargin && edge.luma <= defringeBlackCeiling
        guard isWhite || isBlack else { return }

        // Walk inward (judging the transition lines by luminance only) until the
        // line returns to the interior — that is the first clean content line.
        var goodLine = 0
        while goodLine < defringeMaxDepth {
            let lineLuma = luma(atLine: goodLine)
            let stillFringe = isWhite
                ? lineLuma >= interiorLuma + defringeEndMargin
                : lineLuma <= interiorLuma - defringeEndMargin
            if stillFringe { goodLine += 1 } else { break }
        }

        // goodLine == defringeMaxDepth -> never returned to the interior within
        // the cap (an intentional wide border, not a fringe) -> leave it alone.
        guard goodLine > 0, goodLine < defringeMaxDepth else { return }

        let goodBase = lineStart0 + goodLine * lineStride
        for line in 0..<goodLine {
            let dstBase = lineStart0 + line * lineStride
            var p = 0
            while p < posCount {
                let src = goodBase + p * posStride
                let dst = dstBase + p * posStride
                ptr[dst] = ptr[src]
                ptr[dst + 1] = ptr[src + 1]
                ptr[dst + 2] = ptr[src + 2]
                ptr[dst + 3] = ptr[src + 3]
                p += 1
            }
        }
    }

    private nonisolated static func lineLuma(
        _ ptr: UnsafeMutablePointer<UInt8>,
        base: Int,
        posStride: Int,
        posCount: Int,
        sampleStep: Int
    ) -> Int {
        var sum = 0, count = 0
        var p = 0
        while p < posCount {
            let o = base + p * posStride
            sum += Int(ptr[o]) * 299 + Int(ptr[o + 1]) * 587 + Int(ptr[o + 2]) * 114
            count += 1
            p += sampleStep
        }
        guard count > 0 else { return 0 }
        return sum / (count * 1000)
    }

    private nonisolated static func lineStats(
        _ ptr: UnsafeMutablePointer<UInt8>,
        base: Int,
        posStride: Int,
        posCount: Int,
        sampleStep: Int
    ) -> (spread: Int, chroma: Int, luma: Int) {
        var minR = 255, minG = 255, minB = 255
        var maxR = 0, maxG = 0, maxB = 0
        var sumR = 0, sumG = 0, sumB = 0
        var count = 0

        var p = 0
        while p < posCount {
            let o = base + p * posStride
            let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
            if r < minR { minR = r }; if r > maxR { maxR = r }
            if g < minG { minG = g }; if g > maxG { maxG = g }
            if b < minB { minB = b }; if b > maxB { maxB = b }
            sumR += r; sumG += g; sumB += b
            count += 1
            p += sampleStep
        }
        guard count > 0 else { return (0, 0, 0) }

        let spread = max(maxR - minR, max(maxG - minG, maxB - minB))
        let meanR = sumR / count, meanG = sumG / count, meanB = sumB / count
        let chroma = max(meanR, max(meanG, meanB)) - min(meanR, min(meanG, meanB))
        let luma = (meanR * 299 + meanG * 587 + meanB * 114) / 1000
        return (spread, chroma, luma)
    }
}

private struct ClassicLEDSkinNormalSettingsView: View {
    @AppStorage("skin.classicLED.artworkFrameMaskEnabled") private var artworkFrameMaskEnabled: Bool = true
    @AppStorage("skin.classicLED.edgeBlurEnabled") private var edgeBlurEnabled: Bool = true
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @State private var visualizationPreferences = AudioVisualizationPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                SettingsSwitchRow(title: "风格化封面边缘", isOn: $artworkFrameMaskEnabled)
                
                Spacer()
                    .frame(width: 24)
                
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1, height: 16)
                
                Spacer()
                    .frame(width: 24)
                
                SettingsSwitchRow(title: "边缘模糊", isOn: $edgeBlurEnabled)
            }

            AudioVisualizationSelectorRow(
                title: "音频可视化",
                selection: Binding(
                    get: {
                        visualizationPreferences.selection(
                            for: ClassicLEDSkin.id,
                            scope: .window
                        ).skinKind
                    },
                    set: { kind in
                        visualizationPreferences.setSkinKind(kind, for: ClassicLEDSkin.id, scope: .window)
                        if kind != .led { ledMeterProvider.releaseNowPlayingResources() }
                    }
                )
            )
        }
    }
}

private struct ClassicLEDSkinFullscreenSettingsView: View {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @AppStorage("skin.classicLED.artworkFrameMaskEnabled") private var artworkFrameMaskEnabled: Bool = true
    @AppStorage("fullscreenArtBackgroundEnabled") private var fullscreenArtBackgroundEnabled: Bool = true
    @AppStorage("skin.classicLED.edgeBlurEnabled") private var edgeBlurEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            SettingsSwitchRow(
                title: "启用艺术背景",
                isOn: $fullscreenArtBackgroundEnabled,
                detail: "遇到性能问题时，可以关闭此选项",
                titleFont: presentationStyle.rowLabelFont,
                detailFont: presentationStyle.captionFont,
                titleColor: presentationStyle.primaryTextColor,
                detailColor: presentationStyle.secondaryTextColor
            )

            HStack(spacing: 0) {
                SettingsSwitchRow(
                    title: "风格化封面边缘",
                    isOn: $artworkFrameMaskEnabled,
                    titleFont: presentationStyle.rowLabelFont,
                    titleColor: presentationStyle.primaryTextColor
                )
                
                Spacer()
                    .frame(width: presentationStyle.scaled(24))
                
                Rectangle()
                    .fill(presentationStyle.primaryTextColor.opacity(0.12))
                    .frame(
                        width: presentationStyle.scaled(1),
                        height: presentationStyle.scaled(16)
                    )
                
                Spacer()
                    .frame(width: presentationStyle.scaled(24))
                
                SettingsSwitchRow(
                    title: "边缘模糊",
                    isOn: $edgeBlurEnabled,
                    titleFont: presentationStyle.rowLabelFont,
                    titleColor: presentationStyle.primaryTextColor
                )
            }

            AudioVisualizationSelectorRow(
                title: "音频可视化",
                selection: Binding(
                    get: { FullscreenPresentationCoordinator.shared.skinVisualizerKind },
                    set: { FullscreenPresentationCoordinator.shared.setSkinVisualizer($0) }
                )
            )
        }
    }
}

private struct PillSpectrumView: View {
    let context: SkinContext
    let dotSize: CGFloat
    let spacing: CGFloat
    let pillTint: Color?
    let isFullscreen: Bool
    @Environment(\.colorScheme) private var colorScheme

    private let capsuleCount: CGFloat = 9
    private let capsuleWidth: CGFloat = 7
    // Keep the capsule size unchanged while tightening the gaps so the
    // spectrum reads as one continuous waveform.
    private let capsuleSpacing: CGFloat = 4
    private let horizontalPadding: CGFloat = 28
    private let contentHeight: CGFloat = 52  // Spectrum bars height (increased from 48)
    private var verticalPadding: CGFloat {
        isFullscreen ? 1 : 2  // Fullscreen shell gets one final compacting pass
    }

    private var contentWidth: CGFloat {
        capsuleCount * capsuleWidth + (capsuleCount - 1) * capsuleSpacing
    }

    private var backgroundWidth: CGFloat {
        contentWidth + horizontalPadding * 2
    }

    private var backgroundHeight: CGFloat {
        contentHeight + verticalPadding * 2
    }

    var body: some View {
        PillSpectrumContainer(
            isPlaying: context.playback.isPlaying,
            usesDarkForeground: context.theme.spectrumUsesDarkForeground,
            // App light mode: darken fill + give the outline its own milder dark
            // treatment so the in-skin spectrum reads against the light glass.
            lightModeDarkening: colorScheme == .light,
            artworkColors: context.theme.spectrumArtworkColors,
            artworkAccentColor: NSColor(pillTint ?? .white),
            capsuleWidth: capsuleWidth,
            capsuleSpacing: capsuleSpacing
        )
        .frame(width: contentWidth, height: contentHeight)
        .background(
            Capsule()
                .fill(Color.clear)
                .frame(width: backgroundWidth, height: backgroundHeight)
                .liquidGlassPill(
                    colorScheme: colorScheme,
                    accentColor: pillTint,
                    prominence: pillTint != nil ? .prominent : .standard,
                    isFloating: false
                )
        )
    }
}

private struct PillSpectrumContainer: NSViewRepresentable {

    let isPlaying: Bool
    let usesDarkForeground: Bool
    var lightModeDarkening: Bool = false
    let artworkColors: [NSColor]
    let artworkAccentColor: NSColor
    let capsuleWidth: CGFloat
    let capsuleSpacing: CGFloat

    func makeNSView(context: Context) -> CapsuleSpectrumHostView {
        let view = CapsuleSpectrumHostView(configuration: makeConfiguration())
        applyColors(to: view)
        view.start()
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: CapsuleSpectrumHostView, context: Context) {
        let newHash = currentIdentityHash
        if nsView.pillSpectrumIdentityHash == newHash { return }
        nsView.pillSpectrumIdentityHash = newHash
        nsView.configure(makeConfiguration())
        applyColors(to: nsView)
        nsView.setPlayback(isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: CapsuleSpectrumHostView, coordinator: ()) {
        nsView.stop()
    }

    private var currentIdentityHash: Int {
        var hasher = Hasher()
        hasher.combine(isPlaying)
        hasher.combine(usesDarkForeground)
        hasher.combine(lightModeDarkening)
        hasher.combine(capsuleWidth)
        hasher.combine(capsuleSpacing)
        hasher.combine(SpectrumColorResolver.colorSignature(
            artworkColors: artworkColors,
            accentColor: artworkAccentColor,
            usesDarkForeground: usesDarkForeground,
            lightModeDarkening: lightModeDarkening
        ))
        return hasher.finalize()
    }

    private func makeConfiguration() -> CapsuleSpectrumConfiguration {
        .centeredBars(
            capsuleWidth: capsuleWidth,
            capsuleSpacing: capsuleSpacing,
            strokeWidth: 0.5
        )
    }

    private func applyColors(to view: CapsuleSpectrumHostView) {
        let signature = SpectrumColorResolver.colorSignature(
            artworkColors: artworkColors,
            accentColor: artworkAccentColor,
            usesDarkForeground: usesDarkForeground,
            lightModeDarkening: lightModeDarkening
        )
        view.updateColors(signature: signature) {
            let resolved = SpectrumColorResolver.resolveArtworkFaithfulColors(
                from: artworkColors,
                fallback: artworkAccentColor,
                usesDarkForeground: usesDarkForeground,
                lightModeDarkening: lightModeDarkening
            )
            return (resolved.fillColors, resolved.strokeColors)
        }
    }
}
