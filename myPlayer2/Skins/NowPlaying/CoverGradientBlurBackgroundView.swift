//
//  CoverGradientBlurBackgroundView.swift
//  myPlayer2
//
//  kmgccc_player - Variable Blur Background for Fullscreen Player
//

import AppKit
import CoreImage
import ImageIO
import SwiftUI

// MARK: - Edge Fill Mode

enum CoverEdgeFillMode: String, Sendable, CaseIterable {
    case pixelStretch = "pixelStretch"
    case mirroredCover = "mirroredCover"

    var displayName: String {
        switch self {
        case .pixelStretch:
            return NSLocalizedString("skin.cover_gradient_blur.edge_fill_pixel", comment: "")
        case .mirroredCover:
            return NSLocalizedString("skin.cover_gradient_blur.edge_fill_mirror", comment: "")
        }
    }
}

// MARK: - Configuration

struct CoverGradientBlurConfig: Sendable {
    var blurRadius: CGFloat = 50.0
    var colorOverlayOpacity: CGFloat = 0.65
    var transitionDuration: Double = 0.35
    var edgeStripWidth: CGFloat = 3.0
    var blurStartRatio: CGFloat = 0.55
    var blurEndRatio: CGFloat = 0.95
    var overlayOffsetRatio: CGFloat = 0.0
    var blurCurveGamma: CGFloat = 16.0
    var overlayCurveGamma: CGFloat = 3.0
    var edgeFillMode: CoverEdgeFillMode = .pixelStretch

    // How far left of the artwork's right edge the blur begins, expressed as
    // a fraction of the visible artwork width. 0.48 = legacy fullscreen default.
    var blurStartRatioFromEdge: CGFloat = 0.48

    // CIColorPolynomial alpha channel coefficients (const, linear, quadratic, cubic).
    // nil = use the renderer's built-in default (0, 0.10, 0.34, 0.56).
    var blurAlphaCoefficients: (CGFloat, CGFloat, CGFloat, CGFloat)? = nil

    static let `default` = CoverGradientBlurConfig()
    static let fullscreen = CoverGradientBlurConfig(
        blurRadius: 50.0,
        colorOverlayOpacity: 0.65,
        transitionDuration: 0.40,
        edgeStripWidth: 3.0,
        blurStartRatio: 0.55,
        blurEndRatio: 0.95,
        overlayOffsetRatio: 0.0,
        blurCurveGamma: 16.0,
        overlayCurveGamma: 3.0,
        edgeFillMode: .pixelStretch
    )
}

// MARK: - Render Key

private struct RenderKey: Equatable {
    let artworkChecksum: UInt64
    let size: CGSize
    let configHash: String
    let dominantColorHash: String

    init(
        artworkChecksum: UInt64,
        size: CGSize,
        config: CoverGradientBlurConfig,
        dominantColor: NSColor?,
        prefersAdaptiveArtworkSizing: Bool
    ) {
        self.artworkChecksum = artworkChecksum
        self.size = Self.quantized(size)
        let alphaCoeffStr: String
        if let a = config.blurAlphaCoefficients {
            alphaCoeffStr = String(format: "%.3f-%.3f-%.3f-%.3f", a.0, a.1, a.2, a.3)
        } else {
            alphaCoeffStr = "default"
        }
        self.configHash = String(
            format: "%.1f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%@-%@-%.3f-%@",
            config.blurRadius,
            config.colorOverlayOpacity,
            config.edgeStripWidth,
            config.blurStartRatio,
            config.blurEndRatio,
            config.overlayOffsetRatio,
            config.blurCurveGamma,
            config.overlayCurveGamma,
            config.edgeFillMode.rawValue,
            prefersAdaptiveArtworkSizing ? "adaptive" : "fixed",
            config.blurStartRatioFromEdge,
            alphaCoeffStr
        )
        self.dominantColorHash = dominantColor?.hexString ?? "nil"
    }

    var cacheKey: String {
        "\(artworkChecksum)-\(Int(size.width))x\(Int(size.height))-\(configHash)-\(dominantColorHash)"
    }

    var isRenderable: Bool {
        artworkChecksum != 0 && size.width > 0 && size.height > 0
    }

    static func quantized(_ size: CGSize) -> CGSize {
        guard size.width > 1, size.height > 1 else { return .zero }
        let quantizedWidth = CGFloat(Int(size.width / 10) * 10)
        let quantizedHeight = CGFloat(Int(size.height / 10) * 10)
        return CGSize(width: max(10, quantizedWidth), height: max(10, quantizedHeight))
    }
}

// MARK: - Main View

struct CoverGradientBlurBackgroundView: View {
    let artworkData: Data?
    let artworkImage: NSImage?
    let artworkChecksum: UInt64
    let dominantColor: NSColor?
    let config: CoverGradientBlurConfig
    let preferAdaptiveArtworkSizing: Bool

    @State private var sourceCGImage: CGImage?
    @State private var renderedCGImage: CGImage?
    @State private var visibleRenderedImage: Bool = false
    @State private var lastRenderKey: RenderKey?

    init(
        artworkData: Data?,
        artworkImage: NSImage?,
        artworkChecksum: UInt64,
        dominantColor: NSColor?,
        config: CoverGradientBlurConfig,
        preferAdaptiveArtworkSizing: Bool = false
    ) {
        self.artworkData = artworkData
        self.artworkImage = artworkImage
        self.artworkChecksum = artworkChecksum
        self.dominantColor = dominantColor
        self.config = config
        self.preferAdaptiveArtworkSizing = preferAdaptiveArtworkSizing
    }

    private var resolvedArtworkChecksum: UInt64 {
        if artworkChecksum != 0 {
            return artworkChecksum
        }
        return ArtworkAssetStore.checksum(for: artworkData)
    }

    private var renderKey: RenderKey {
        RenderKey(
            artworkChecksum: resolvedArtworkChecksum,
            size: currentSize,
            config: config,
            dominantColor: dominantColor,
            prefersAdaptiveArtworkSizing: preferAdaptiveArtworkSizing
        )
    }
    
    @State private var currentSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                rawImageLayer(geometry: geometry)
                    .opacity(visibleRenderedImage ? 0 : 1)

                renderedImageLayer(geometry: geometry)
                    .opacity(visibleRenderedImage ? 1 : 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(.easeInOut(duration: config.transitionDuration), value: visibleRenderedImage)
            .onAppear {
                updateCurrentSize(geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                updateCurrentSize(newSize)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: renderKey) {
            await performRender()
        }
    }

    @ViewBuilder
    private func rawImageLayer(geometry: GeometryProxy) -> some View {
        if let cgImage = sourceCGImage {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        } else {
            fallbackBackground(geometry: geometry)
        }
    }

    @ViewBuilder
    private func renderedImageLayer(geometry: GeometryProxy) -> some View {
        if let cgImage = renderedCGImage {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
    }

    @ViewBuilder
    private func fallbackBackground(geometry: GeometryProxy) -> some View {
        if let dominantColor {
            Color(nsColor: dominantColor)
        } else {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private func performRender() async {
        let key = renderKey

        guard key.isRenderable else {
            updateSourceImage(nil, forKey: key)
            updateRenderedImage(nil, forKey: key)
            return
        }

        if lastRenderKey == key, renderedCGImage != nil { return }

        guard artworkData != nil || artworkImage != nil else {
            updateSourceImage(nil, forKey: key)
            updateRenderedImage(nil, forKey: key)
            return
        }

        let preparedArtwork = await Task.detached(priority: .utility) {
            CoverGradientBlurRenderer.preparedArtworkImage(
                artworkData: artworkData,
                artworkImage: artworkImage,
                targetSize: key.size
            )
        }.value

        guard !Task.isCancelled else { return }

        let renderedBox = await CoverGradientBlurRenderStore.shared.image(for: key.cacheKey) {
            guard let preparedArtwork else { return nil }
            return await Task.detached(priority: .utility) {
                autoreleasepool {
                    guard
                        let image = CoverGradientBlurRenderer.render(
                            artworkCGImage: preparedArtwork,
                            targetSize: key.size,
                            dominantColor: dominantColor,
                            config: config,
                            preferAdaptiveArtworkSizing: preferAdaptiveArtworkSizing
                        )
                    else { return nil }
                    return CoverGradientBlurRenderedImageBox(image: image)
                }
            }.value
        }

        guard !Task.isCancelled else { return }
        if let renderedImage = renderedBox?.image {
            updatePreparedAndRenderedImages(
                preparedArtwork,
                renderedImage: renderedImage,
                forKey: key
            )
        } else {
            updateSourceImage(preparedArtwork, forKey: key)
            updateRenderedImage(nil, forKey: key)
        }
    }

    private func updateCurrentSize(_ size: CGSize) {
        let quantizedSize = RenderKey.quantized(size)
        guard quantizedSize != currentSize else { return }
        currentSize = quantizedSize
    }

    @MainActor
    private func updateSourceImage(_ image: CGImage?, forKey key: RenderKey) {
        guard key == renderKey else { return }
        sourceCGImage = image
    }
    
    @MainActor
    private func updateRenderedImage(_ image: CGImage?, forKey key: RenderKey) {
        guard key == renderKey else { return }
        renderedCGImage = image
        lastRenderKey = key
        withAnimation(.easeInOut(duration: config.transitionDuration)) {
            visibleRenderedImage = image != nil
        }
    }

    @MainActor
    private func updatePreparedAndRenderedImages(
        _ sourceImage: CGImage?,
        renderedImage: CGImage,
        forKey key: RenderKey
    ) {
        guard key == renderKey else { return }
        sourceCGImage = sourceImage
        renderedCGImage = renderedImage
        lastRenderKey = key
        withAnimation(.easeInOut(duration: config.transitionDuration)) {
            visibleRenderedImage = true
        }
    }
}

// MARK: - Renderer

enum CoverGradientBlurRenderer {

    private nonisolated static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])

    nonisolated static func preparedArtworkImage(
        artworkData: Data?,
        artworkImage: NSImage?,
        targetSize: CGSize
    ) -> CGImage? {
        if let artworkImage, let cgImage = cgImage(from: artworkImage) {
            return cgImage
        }

        guard let artworkData else { return nil }
        guard
            let source = CGImageSourceCreateWithData(
                artworkData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        let maxPixelSize = max(1, Int(ceil(max(targetSize.width, targetSize.height))))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func render(
        artworkCGImage: CGImage,
        targetSize: CGSize,
        dominantColor: NSColor?,
        config: CoverGradientBlurConfig,
        preferAdaptiveArtworkSizing: Bool = false
    ) -> CGImage? {

        guard targetSize.width > 0, targetSize.height > 0,
              targetSize.width < 10000, targetSize.height < 10000 else {
            return nil
        }

        let canvasLogicalWidth = targetSize.width
        let canvasLogicalHeight = targetSize.height
        let canvasPixelWidth = Int(canvasLogicalWidth)
        let canvasPixelHeight = Int(canvasLogicalHeight)
        
        let canvasRect = CGRect(x: 0, y: 0, width: canvasLogicalWidth, height: canvasLogicalHeight)

        let artworkWidth = CGFloat(artworkCGImage.width)
        let artworkHeight = CGFloat(artworkCGImage.height)

        let scale: CGFloat
        if preferAdaptiveArtworkSizing {
            let baseCanvasWidth: CGFloat = 1470
            let baseCanvasHeight: CGFloat = 923
            let fullscreenScale = min(
                canvasLogicalWidth / baseCanvasWidth,
                canvasLogicalHeight / baseCanvasHeight
            )
            let adaptiveHeight = min(canvasLogicalHeight, baseCanvasHeight * fullscreenScale)
            scale = adaptiveHeight / artworkHeight
        } else {
            scale = canvasLogicalHeight / artworkHeight
        }
        let drawWidth = artworkWidth * scale
        let artworkRect = CGRect(x: 0, y: 0, width: drawWidth, height: canvasLogicalHeight)
        let artworkRightEdgeX = min(drawWidth, canvasLogicalWidth)
        let artworkRightEdgePixel = Int(artworkRightEdgeX)

        // Step 1: Render Artwork + Edge Extension
        guard let baseImage = renderBaseImage(
            artworkCGImage: artworkCGImage,
            canvasPixelWidth: canvasPixelWidth,
            canvasPixelHeight: canvasPixelHeight,
            artworkRect: artworkRect,
            artworkRightEdgePixel: artworkRightEdgePixel,
            config: config
        ) else {
            return nil
        }

        let visibleArtworkWidth = artworkRightEdgeX

        let blurStartX = artworkRightEdgeX - (visibleArtworkWidth * config.blurStartRatioFromEdge)
        let blurEndInsetRatioFromRight: CGFloat = 0.04
        let blurEndX = max(
            blurStartX + 1,
            canvasLogicalWidth - (visibleArtworkWidth * blurEndInsetRatioFromRight)
        )

        let baseCIImage = CIImage(cgImage: baseImage)

        // Clamp the image to extend edge pixels infinitely - prevents blur from sampling transparent/black at boundaries
        guard let clampFilter = CIFilter(name: "CIAffineClamp") else {
            return nil
        }
        clampFilter.setValue(baseCIImage, forKey: kCIInputImageKey)
        clampFilter.setValue(CGAffineTransform.identity, forKey: kCIInputTransformKey)

        guard let clampedImage = clampFilter.outputImage else {
            return nil
        }

        guard let linearGradientFilter = CIFilter(name: "CILinearGradient") else {
            return nil
        }

        let point0 = CIVector(x: blurStartX, y: canvasLogicalHeight / 2)
        let point1 = CIVector(x: blurEndX, y: canvasLogicalHeight / 2)
        let color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        linearGradientFilter.setValue(point0, forKey: "inputPoint0")
        linearGradientFilter.setValue(point1, forKey: "inputPoint1")
        linearGradientFilter.setValue(color0, forKey: "inputColor0")
        linearGradientFilter.setValue(color1, forKey: "inputColor1")

        guard let linearMask = linearGradientFilter.outputImage?.cropped(to: canvasRect) else {
            return nil
        }

        guard let polynomialFilter = CIFilter(name: "CIColorPolynomial") else {
            return nil
        }

        let rCoeff = CIVector(x: 0, y: 0, z: 0, w: 1)
        let gCoeff = CIVector(x: 0, y: 0, z: 0, w: 1)
        let bCoeff = CIVector(x: 0, y: 0, z: 0, w: 1)
        let aCoeff: CIVector
        if let c = config.blurAlphaCoefficients {
            aCoeff = CIVector(x: c.0, y: c.1, z: c.2, w: c.3)
        } else {
            // Adaptive coefficients: when radius grows beyond ~150, slightly lift the
            // low-alpha region via the linear term so the early blur zone also responds.
            // Right-edge behaviour is preserved by reducing the cubic term in tandem.
            let baseLinear: CGFloat = 0.10
            let baseQuad: CGFloat = 0.34
            let baseCubic: CGFloat = 0.56
            let totalRadius = max(0, config.blurRadius)
            let refRadius: CGFloat = 150.0
            let adaptLinear: CGFloat
            let adaptCubic: CGFloat
            if totalRadius <= refRadius {
                adaptLinear = baseLinear
                adaptCubic = baseCubic
            } else {
                let excess = (totalRadius - refRadius) / refRadius
                // sqrt-compressed gain, capped at +20 % — low-alpha zone
                // should only get a subtle radius linkage, not follow it
                // aggressively.  Cubic term is restored to keep the
                // mid / high-alpha zones carrying most of the change.
                let gain = 1.0 + min(0.20, sqrt(excess) * 0.14)
                adaptLinear = baseLinear * gain
                adaptCubic = max(0.35, baseCubic - baseLinear * (gain - 1.0) * 0.2)
            }
            aCoeff = CIVector(x: 0, y: adaptLinear, z: baseQuad, w: adaptCubic)
        }
        
        polynomialFilter.setValue(linearMask, forKey: kCIInputImageKey)
        polynomialFilter.setValue(rCoeff, forKey: "inputRedCoefficients")
        polynomialFilter.setValue(gCoeff, forKey: "inputGreenCoefficients")
        polynomialFilter.setValue(bCoeff, forKey: "inputBlueCoefficients")
        polynomialFilter.setValue(aCoeff, forKey: "inputAlphaCoefficients")
        
        guard let nonLinearMask = polynomialFilter.outputImage?.cropped(to: canvasRect) else {
            return nil
        }

        // Large blur radii visually saturate too early if we keep reusing the same mask.
        // Split the blur into smaller passes and progressively delay later passes toward
        // the far-right region, so the blur can keep increasing all the way to the edge.
        //
        // Pass 0 uses the full non-linear mask and a radius that grows modestly beyond
        // the base cap (compressed gain), so the early / low-blur zone still responds
        // when the user increases totalRadius past ~150.  Later passes use delayed
        // masks with softer thresholds so they reach the mid-region sooner without
        // flooding the left-side cover.
        var currentImage = clampedImage
        let basePassRadius: CGFloat = 150.0
        let totalRadius = max(0, config.blurRadius)

        // Build pass radii: pass 0 gets an adaptive cap; remaining radius is split
        // into standard ≤150 passes.
        var passRadii: [CGFloat] = []
        var remaining = totalRadius
        let p0Extra = min(60.0, max(0, totalRadius - basePassRadius) * 0.10)
        let p0Cap = min(totalRadius, basePassRadius + p0Extra)
        passRadii.append(p0Cap)
        remaining -= p0Cap
        while remaining > 0 {
            let r = min(basePassRadius, remaining)
            passRadii.append(r)
            remaining -= r
        }

        for (passIndex, passRadius) in passRadii.enumerated() {
            guard passRadius > 0 else { continue }

            let passMask: CIImage
            if passIndex == 0 {
                passMask = nonLinearMask
            } else {
                let progress = CGFloat(passIndex) / CGFloat(passRadii.count)
                // Pass 1 reaches mid-to-right; Pass 2+ tilt further right.
                // Threshold start raised to 0.10 so early left-side blur is
                // preserved; cap raised to 0.72 so later passes can still
                // deliver full right-side blur without leaking left.
                let delayedThreshold = min(0.72, 0.10 + progress * 0.38)
                passMask = delayedMask(
                    from: nonLinearMask,
                    startThreshold: delayedThreshold,
                    extent: canvasRect
                ) ?? nonLinearMask
            }

            guard let passClampFilter = CIFilter(name: "CIAffineClamp") else {
                return nil
            }
            passClampFilter.setValue(currentImage, forKey: kCIInputImageKey)
            passClampFilter.setValue(CGAffineTransform.identity, forKey: kCIInputTransformKey)
            guard let clampedPassImage = passClampFilter.outputImage else {
                return nil
            }

            guard let blurFilter = CIFilter(name: "CIMaskedVariableBlur") else {
                return nil
            }
            blurFilter.setValue(clampedPassImage, forKey: kCIInputImageKey)
            blurFilter.setValue(passRadius, forKey: kCIInputRadiusKey)
            blurFilter.setValue(passMask, forKey: "inputMask")
            guard let passImage = blurFilter.outputImage?.cropped(to: canvasRect) else {
                return nil
            }
            currentImage = passImage
        }

        let blurredImage = currentImage

        let overlayStartRatioFromEdge: CGFloat = 0.28
        let overlayStartX = artworkRightEdgeX - (visibleArtworkWidth * overlayStartRatioFromEdge)
        let overlayEndX = canvasLogicalWidth
        let overlayAlphaMax = config.colorOverlayOpacity

        let overlayColor: CIColor
        if let dominant = dominantColor {
            overlayColor = CIColor(cgColor: dominant.cgColor)
        } else {
            overlayColor = CIColor(red: 0.15, green: 0.15, blue: 0.15)
        }

        guard let overlayGradientFilter = CIFilter(name: "CILinearGradient") else {
            return nil
        }

        let overlayPoint0 = CIVector(x: overlayStartX, y: canvasLogicalHeight / 2)
        let overlayPoint1 = CIVector(x: overlayEndX, y: canvasLogicalHeight / 2)
        let overlayColor0 = CIColor(
            red: overlayColor.red,
            green: overlayColor.green,
            blue: overlayColor.blue,
            alpha: 0
        )
        let overlayColor1 = CIColor(
            red: overlayColor.red,
            green: overlayColor.green,
            blue: overlayColor.blue,
            alpha: overlayAlphaMax
        )

        overlayGradientFilter.setValue(overlayPoint0, forKey: "inputPoint0")
        overlayGradientFilter.setValue(overlayPoint1, forKey: "inputPoint1")
        overlayGradientFilter.setValue(overlayColor0, forKey: "inputColor0")
        overlayGradientFilter.setValue(overlayColor1, forKey: "inputColor1")

        guard let linearOverlay = overlayGradientFilter.outputImage?.cropped(to: canvasRect) else {
            return nil
        }

        let overlayImage: CIImage
        if let overlayGammaFilter = CIFilter(name: "CIGammaAdjust") {
            overlayGammaFilter.setValue(linearOverlay, forKey: kCIInputImageKey)
            overlayGammaFilter.setValue(config.overlayCurveGamma, forKey: "inputPower")
            overlayImage = overlayGammaFilter.outputImage?.cropped(to: canvasRect) ?? linearOverlay
        } else {
            overlayImage = linearOverlay
        }

        guard let compositeFilter = CIFilter(name: "CISourceOverCompositing") else {
            return nil
        }

        compositeFilter.setValue(blurredImage, forKey: kCIInputBackgroundImageKey)
        compositeFilter.setValue(overlayImage, forKey: kCIInputImageKey)

        guard let finalImage = compositeFilter.outputImage?.cropped(to: canvasRect) else {
            return nil
        }

        defer {
            ciContext.clearCaches()
        }

        guard let cgImage = ciContext.createCGImage(finalImage, from: canvasRect) else {
            return nil
        }

        return cgImage
    }

    private nonisolated static func delayedMask(
        from sourceMask: CIImage,
        startThreshold: CGFloat,
        extent: CGRect
    ) -> CIImage? {
        let threshold = max(0, min(0.95, startThreshold))
        let scale = 1 / max(0.0001, 1 - threshold)
        let bias = -threshold * scale

        guard let matrixFilter = CIFilter(name: "CIColorMatrix") else {
            return nil
        }
        matrixFilter.setValue(sourceMask, forKey: kCIInputImageKey)
        matrixFilter.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrixFilter.setValue(CIVector(x: 0, y: scale, z: 0, w: 0), forKey: "inputGVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: scale, w: 0), forKey: "inputBVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: scale), forKey: "inputAVector")
        matrixFilter.setValue(
            CIVector(x: bias, y: bias, z: bias, w: bias),
            forKey: "inputBiasVector"
        )
        guard let remappedMask = matrixFilter.outputImage?.cropped(to: extent) else {
            return nil
        }

        guard let clampFilter = CIFilter(name: "CIColorClamp") else {
            return remappedMask
        }
        clampFilter.setValue(remappedMask, forKey: kCIInputImageKey)
        clampFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
        clampFilter.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
        return clampFilter.outputImage?.cropped(to: extent) ?? remappedMask
    }

    // MARK: - Render Base Image

    private nonisolated static func renderBaseImage(
        artworkCGImage: CGImage,
        canvasPixelWidth: Int,
        canvasPixelHeight: Int,
        artworkRect: CGRect,
        artworkRightEdgePixel: Int,
        config: CoverGradientBlurConfig
    ) -> CGImage? {

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: canvasPixelWidth,
            height: canvasPixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(artworkCGImage, in: artworkRect)

        guard artworkRightEdgePixel < canvasPixelWidth else {
            return context.makeImage()
        }

        switch config.edgeFillMode {
        case .pixelStretch:
            return renderPixelStretchExtension(
                context: context,
                artworkCGImage: artworkCGImage,
                artworkRect: artworkRect,
                artworkRightEdgePixel: artworkRightEdgePixel,
                canvasPixelWidth: canvasPixelWidth,
                canvasPixelHeight: canvasPixelHeight,
                config: config
            )
        case .mirroredCover:
            return renderMirroredCoverExtension(
                context: context,
                artworkCGImage: artworkCGImage,
                artworkRect: artworkRect,
                artworkRightEdgePixel: artworkRightEdgePixel,
                canvasPixelWidth: canvasPixelWidth,
                canvasPixelHeight: canvasPixelHeight
            )
        }
    }

    // MARK: - Pixel Stretch Extension (Original Method)

    private nonisolated static func renderPixelStretchExtension(
        context: CGContext,
        artworkCGImage: CGImage,
        artworkRect: CGRect,
        artworkRightEdgePixel: Int,
        canvasPixelWidth: Int,
        canvasPixelHeight: Int,
        config: CoverGradientBlurConfig
    ) -> CGImage? {

        let extensionPixelStart = artworkRightEdgePixel
        let extensionPixelWidth = canvasPixelWidth - extensionPixelStart

        let stripPixelWidth = Int(min(config.edgeStripWidth, artworkRect.width)) + 1
        let stripPixelStart = max(0, artworkRightEdgePixel - stripPixelWidth)
        let actualStripPixelWidth = artworkRightEdgePixel - stripPixelStart

        let extensionRect = CGRect(
            x: CGFloat(extensionPixelStart),
            y: 0,
            width: CGFloat(extensionPixelWidth),
            height: CGFloat(canvasPixelHeight)
        )

        let normalizedStripWidth = CGFloat(actualStripPixelWidth) / max(1, artworkRect.width)
        let sourceStripWidth = max(
            1,
            min(artworkCGImage.width, Int(ceil(normalizedStripWidth * CGFloat(artworkCGImage.width))))
        )
        let sourceStripStart = max(0, artworkCGImage.width - sourceStripWidth)
        let sourceStripRect = CGRect(
            x: sourceStripStart,
            y: 0,
            width: sourceStripWidth,
            height: artworkCGImage.height
        )

        guard artworkRightEdgePixel > 0,
              let stripCGImage = artworkCGImage.cropping(to: sourceStripRect) else {
            return context.makeImage()
        }

        context.interpolationQuality = .none
        context.draw(stripCGImage, in: extensionRect)

        return context.makeImage()
    }

    // MARK: - Mirrored Cover Extension

    private nonisolated static func renderMirroredCoverExtension(
        context: CGContext,
        artworkCGImage: CGImage,
        artworkRect: CGRect,
        artworkRightEdgePixel: Int,
        canvasPixelWidth: Int,
        canvasPixelHeight: Int
    ) -> CGImage? {

        let extensionPixelStart = artworkRightEdgePixel
        let extensionPixelWidth = canvasPixelWidth - extensionPixelStart

        guard extensionPixelWidth > 0 else {
            return context.makeImage()
        }

        // Mirror the displayed artwork horizontally, then stretch it to 2x width.
        // The mirrored copy's left edge must sit exactly on the artwork's right edge,
        // while the canvas clips any overflow beyond the available right-side region.
        let artworkHeight = artworkRect.height
        let stretchRatio: CGFloat = 2.0
        let stretchedWidth = artworkRect.width * stretchRatio
        let targetRect = CGRect(
            x: CGFloat(extensionPixelStart),
            y: 0,
            width: stretchedWidth,
            height: artworkHeight
        )
        let extensionClipRect = CGRect(
            x: CGFloat(extensionPixelStart),
            y: 0,
            width: CGFloat(extensionPixelWidth),
            height: CGFloat(canvasPixelHeight)
        )

        context.interpolationQuality = .high
        context.saveGState()
        context.clip(to: extensionClipRect)
        context.translateBy(x: targetRect.minX + targetRect.width, y: targetRect.minY)
        context.scaleBy(x: -1, y: 1)
        context.draw(
            artworkCGImage,
            in: CGRect(x: 0, y: 0, width: targetRect.width, height: targetRect.height)
        )
        context.restoreGState()

        return context.makeImage()
    }

    private nonisolated static func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}

private final class CoverGradientBlurRenderedImageBox: NSObject, @unchecked Sendable {
    nonisolated let image: CGImage
    nonisolated let cost: Int

    nonisolated init(image: CGImage) {
        self.image = image
        self.cost = image.bytesPerRow * image.height
        super.init()
    }
}

private actor CoverGradientBlurRenderStore {
    static let shared = CoverGradientBlurRenderStore()

    private let cache: NSCache<NSString, CoverGradientBlurRenderedImageBox> = {
        let cache = NSCache<NSString, CoverGradientBlurRenderedImageBox>()
        cache.countLimit = 2
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private var inFlightKeys: Set<String> = []
    private var waitingContinuations:
        [String: [CheckedContinuation<CoverGradientBlurRenderedImageBox?, Never>]] = [:]

    func image(
        for key: String,
        producer: @Sendable @escaping () async -> CoverGradientBlurRenderedImageBox?
    ) async -> CoverGradientBlurRenderedImageBox? {
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        if inFlightKeys.contains(key) {
            return await withCheckedContinuation { continuation in
                waitingContinuations[key, default: []].append(continuation)
            }
        }

        inFlightKeys.insert(key)
        let result = await producer()

        if let result {
            cache.setObject(result, forKey: key as NSString, cost: result.cost)
        }

        inFlightKeys.remove(key)
        if let waiters = waitingContinuations.removeValue(forKey: key) {
            for continuation in waiters {
                continuation.resume(returning: result)
            }
        }

        return result
    }
}

// MARK: - NSColor Extension

private extension NSColor {
    var hexString: String {
        guard let color = self.usingColorSpace(.sRGB) else { return "unknown" }
        return String(format: "#%02X%02X%02X",
                      Int(color.redComponent * 255),
                      Int(color.greenComponent * 255),
                      Int(color.blueComponent * 255))
    }
}

// MARK: - Preview

#Preview {
    CoverGradientBlurBackgroundView(
        artworkData: nil,
        artworkImage: nil,
        artworkChecksum: 0,
        dominantColor: NSColor.systemBlue,
        config: .fullscreen
    )
    .frame(width: 800, height: 600)
}
