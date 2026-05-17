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

private let coverGradientBlurRendererCacheVersion = "softProgressiveMaskV3"

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

enum CoverGradientBlurMaskMode: String, Sendable {
    case progressiveRamp
    case extensionOnly
}

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
    var overlayStartRatioFromEdge: CGFloat = 0.28
    var edgeFillMode: CoverEdgeFillMode = .pixelStretch
    var blurMaskMode: CoverGradientBlurMaskMode = .progressiveRamp

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
            format: "%@-%.1f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%@-%@-%@-%.3f-%@",
            coverGradientBlurRendererCacheVersion,
            config.blurRadius,
            config.colorOverlayOpacity,
            config.edgeStripWidth,
            config.blurStartRatio,
            config.blurEndRatio,
            config.overlayOffsetRatio,
            config.blurCurveGamma,
            config.overlayCurveGamma,
            config.overlayStartRatioFromEdge,
            config.edgeFillMode.rawValue,
            config.blurMaskMode.rawValue,
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

        let nonLinearMask: CIImage?
        switch config.blurMaskMode {
        case .progressiveRamp:
            nonLinearMask = progressiveRampMask(
                blurStartX: blurStartX,
                blurEndX: blurEndX,
                canvasRect: canvasRect,
                canvasLogicalHeight: canvasLogicalHeight,
                alphaCoefficients: config.blurAlphaCoefficients
            )
        case .extensionOnly:
            nonLinearMask = extensionOnlyMask(
                artworkRightEdgeX: artworkRightEdgeX,
                canvasRect: canvasRect,
                canvasLogicalHeight: canvasLogicalHeight
            )
        }

        guard let nonLinearMask else { return nil }

        // Progressive blur:
        //   Pass 0 — fixed cap ≤150, full mask — defines the base cover-edge
        //            transition and protects the left / cover-right-edge region.
        //   Pass 1+ — each pass uses a continuous power-feathered mask. The
        //            previous zone-threshold remap produced visible vertical
        //            seams where later blur passes entered/exited.
        var currentImage = clampedImage
        let basePassRadius: CGFloat = 150.0
        let totalRadius = max(0, config.blurRadius)

        // Build pass radii: pass 0 is ≤150; remaining radius is split into
        // standard ≤150 passes.
        var passRadii: [CGFloat] = []
        var remaining = totalRadius
        let p0Radius = min(basePassRadius, remaining)
        passRadii.append(p0Radius)
        remaining -= p0Radius
        while remaining > 0 {
            let r = min(basePassRadius, remaining)
            passRadii.append(r)
            remaining -= r
        }

        for (passIndex, passRadius) in passRadii.enumerated() {
            guard passRadius > 0 else { continue }

            let passMask: CIImage
            if passIndex == 0 || config.blurMaskMode == .extensionOnly {
                passMask = nonLinearMask
            } else {
                passMask = progressiveFeatherMask(
                    from: nonLinearMask,
                    passIndex: passIndex,
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

        let overlayStartX = artworkRightEdgeX - (visibleArtworkWidth * config.overlayStartRatioFromEdge)
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

    /// Continuous feather mask for later blur passes. Integer powers keep low
    /// mask values near zero and let high values gradually reach full strength
    /// without introducing threshold bands or clamp plateaus.
    private nonisolated static func progressiveRampMask(
        blurStartX: CGFloat,
        blurEndX: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat,
        alphaCoefficients: (CGFloat, CGFloat, CGFloat, CGFloat)?
    ) -> CIImage? {
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
        if let c = alphaCoefficients {
            aCoeff = CIVector(x: c.0, y: c.1, z: c.2, w: c.3)
        } else {
            // Fixed base coefficients. Zone-based blur control is handled
            // by per-pass smoothstep masks, not by reshaping this curve.
            aCoeff = CIVector(x: 0, y: 0.10, z: 0.34, w: 0.56)
        }

        polynomialFilter.setValue(linearMask, forKey: kCIInputImageKey)
        polynomialFilter.setValue(rCoeff, forKey: "inputRedCoefficients")
        polynomialFilter.setValue(gCoeff, forKey: "inputGreenCoefficients")
        polynomialFilter.setValue(bCoeff, forKey: "inputBlueCoefficients")
        polynomialFilter.setValue(aCoeff, forKey: "inputAlphaCoefficients")

        return polynomialFilter.outputImage?.cropped(to: canvasRect)
    }

    private nonisolated static func extensionOnlyMask(
        artworkRightEdgeX: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        guard let linearGradientFilter = CIFilter(name: "CILinearGradient") else {
            return nil
        }

        let point0 = CIVector(x: artworkRightEdgeX - 0.5, y: canvasLogicalHeight / 2)
        let point1 = CIVector(x: artworkRightEdgeX + 1.5, y: canvasLogicalHeight / 2)
        let color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        linearGradientFilter.setValue(point0, forKey: "inputPoint0")
        linearGradientFilter.setValue(point1, forKey: "inputPoint1")
        linearGradientFilter.setValue(color0, forKey: "inputColor0")
        linearGradientFilter.setValue(color1, forKey: "inputColor1")

        return linearGradientFilter.outputImage?.cropped(to: canvasRect)
    }

    private nonisolated static func progressiveFeatherMask(
        from sourceMask: CIImage,
        passIndex: Int,
        extent: CGRect
    ) -> CIImage? {
        switch passIndex {
        case 1:
            return polynomialMask(sourceMask, power: 2, extent: extent)
        case 2:
            return polynomialMask(sourceMask, power: 3, extent: extent)
        case 3:
            guard let squared = polynomialMask(sourceMask, power: 2, extent: extent) else { return nil }
            return polynomialMask(squared, power: 2, extent: extent)
        default:
            guard let squared = polynomialMask(sourceMask, power: 2, extent: extent) else { return nil }
            return polynomialMask(squared, power: 3, extent: extent)
        }
    }

    private nonisolated static func polynomialMask(
        _ sourceMask: CIImage,
        power: Int,
        extent: CGRect
    ) -> CIImage? {
        guard let filter = CIFilter(name: "CIColorPolynomial") else {
            return sourceMask.cropped(to: extent)
        }
        filter.setValue(sourceMask, forKey: kCIInputImageKey)
        let coefficients: CIVector = power == 3
            ? CIVector(x: 0, y: 0, z: 0, w: 1)
            : CIVector(x: 0, y: 0, z: 1, w: 0)
        filter.setValue(coefficients, forKey: "inputRedCoefficients")
        filter.setValue(coefficients, forKey: "inputGreenCoefficients")
        filter.setValue(coefficients, forKey: "inputBlueCoefficients")
        filter.setValue(coefficients, forKey: "inputAlphaCoefficients")
        return filter.outputImage?.cropped(to: extent)
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
