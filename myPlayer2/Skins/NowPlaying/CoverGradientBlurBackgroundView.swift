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

private let coverGradientBlurRendererCacheVersion = "smoothStretchV8"

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

    // Strength of the extension blur floor as a fraction of blurRadius (capped
    // at one ≤120px pass). The floor is a single masked-blur pass that is 0
    // across the cover and full across the stretch extension, so the segment
    // hugging the cover's right edge is already clearly blurred instead of
    // inheriting the ramp masks' value of ~0 at the edge. 0 = disabled (the
    // default; HomeHero and other consumers stay on the pure ramp pipeline).
    var extensionFloorStrength: CGFloat = 0

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
            format: "%@-%.1f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%@-%@-%@-%.3f-%@-%.3f",
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
            alphaCoeffStr,
            config.extensionFloorStrength
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
        // Placeholder shown only before the first progressive-blur render exists
        // for this surface. Deliberately the solid base colour — NOT the prepared
        // artwork drawn `.resizable()` edge-to-edge. That stretched preview was
        // the "水平拉伸" flash: on a cold track switch `visibleRenderedImage`
        // animates false→true and, at the start of that crossfade, the stretched
        // source was momentarily fully visible between the solid base and the
        // final left-cover/right-blur render. A solid base crossfades cleanly
        // into the final render with no intermediate stretched frame.
        fallbackBackground(geometry: geometry)
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
            // Transient artwork gap on a cold track switch: the new track is
            // selected before its lazily-loaded artwork data / checksum is in
            // memory (Track.loadArtworkDataIfNeeded reads from disk), so the key
            // is briefly non-renderable. HOLD the last good cover instead of
            // clearing it — clearing here dropped the surface to the solid
            // fallback on every switch, which read as the "纯色" colour flash
            // before the new cover appeared. Only blank when there is no prior
            // cover to hold (genuine first mount).
            if renderedCGImage == nil {
                updateSourceImage(nil, forKey: key)
                updateRenderedImage(nil, forKey: key)
            }
            return
        }

        if lastRenderKey == key, renderedCGImage != nil { return }

        guard artworkData != nil || artworkImage != nil else {
            // Same hold semantics as above for the artwork-bytes gap.
            if renderedCGImage == nil {
                updateSourceImage(nil, forKey: key)
                updateRenderedImage(nil, forKey: key)
            }
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
        //   Pass 1+ — staggered smooth-onset masks. Onsets are spread from the
        //            cover's right edge into the extension region so total blur
        //            ramps up early and each additional pass (= radius slider
        //            increase) is visible across the whole gradient. The earlier
        //            power-feathered masks (a², a³, a⁴, a⁶ of the cubic base
        //            curve) confined nearly all later passes to the far right
        //            edge, which also made the radius setting appear inert.
        //            CISmoothLinearGradient keeps every mask seam-free; the
        //            zone-threshold remap before that produced visible vertical
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

        // Extension blur floor. The ramp masks (pass 0 + staggered) are all at
        // or near 0 alpha exactly at the cover's right edge, so the segment
        // hugging the cover was starved (~0.14 of one pass ≈ 21px) no matter
        // how the ramps were reshaped — a curve anchored at 0 there cannot be
        // non-zero there. This single masked-blur pass lifts the whole stretch
        // extension to a moderate floor (mask 0 in the cover, full across the
        // extension), so the start is already clearly blurred while the right
        // side keeps increasing on top via pass 0 + the staggered passes. Gated
        // by `extensionFloorStrength` so non-opted-in consumers are unchanged.
        if config.extensionFloorStrength > 0,
           artworkRightEdgePixel < canvasPixelWidth {
            let floorRadius = min(120, totalRadius * config.extensionFloorStrength)
            if floorRadius > 0,
               let floorMask = extensionFloorMask(
                   coverEdgeX: artworkRightEdgeX,
                   rampSpan: max(12, visibleArtworkWidth * 0.025),
                   canvasRect: canvasRect,
                   canvasLogicalHeight: canvasLogicalHeight
               ),
               let floorClampFilter = CIFilter(name: "CIAffineClamp") {
                floorClampFilter.setValue(currentImage, forKey: kCIInputImageKey)
                floorClampFilter.setValue(CGAffineTransform.identity, forKey: kCIInputTransformKey)
                if let clampedFloorInput = floorClampFilter.outputImage,
                   let floorBlurFilter = CIFilter(name: "CIMaskedVariableBlur") {
                    floorBlurFilter.setValue(clampedFloorInput, forKey: kCIInputImageKey)
                    floorBlurFilter.setValue(floorRadius, forKey: kCIInputRadiusKey)
                    floorBlurFilter.setValue(floorMask, forKey: "inputMask")
                    if let flooredImage = floorBlurFilter.outputImage?.cropped(to: canvasRect) {
                        currentImage = flooredImage
                    }
                }
            }
        }

        for (passIndex, passRadius) in passRadii.enumerated() {
            guard passRadius > 0 else { continue }

            let passMask: CIImage
            if passIndex == 0 || config.blurMaskMode == .extensionOnly {
                passMask = nonLinearMask
            } else {
                passMask = staggeredOnsetMask(
                    passIndex: passIndex,
                    featherPassCount: passRadii.count - 1,
                    coverEdgeX: artworkRightEdgeX,
                    blurEndX: blurEndX,
                    canvasRect: canvasRect,
                    canvasLogicalHeight: canvasLogicalHeight
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

    /// Base ramp mask for pass 0: linear gradient over the full blur span,
    /// shaped by a cubic alpha polynomial so the cover-interior transition
    /// starts gently.
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

    /// Mask for the extension blur floor pass. Modeled on `extensionOnlyMask`:
    /// alpha is 0 across the whole cover (left of `coverEdgeX`, where the
    /// gradient clamps to color0) and rises to full just past the edge, then
    /// stays full across the entire extension (right of the ramp, where it
    /// clamps to color1). A `CISmoothLinearGradient` keeps the rise seam-free
    /// so the cover→extension hand-off reads as a smooth transition, not a
    /// fault. Because alpha is exactly 0 inside the cover, this pass never adds
    /// blur to the cover interior.
    private nonisolated static func extensionFloorMask(
        coverEdgeX: CGFloat,
        rampSpan: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        guard let gradientFilter = CIFilter(name: "CISmoothLinearGradient") else {
            return nil
        }

        let point0 = CIVector(x: coverEdgeX, y: canvasLogicalHeight / 2)
        let point1 = CIVector(x: coverEdgeX + max(1, rampSpan), y: canvasLogicalHeight / 2)
        let color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        gradientFilter.setValue(point0, forKey: "inputPoint0")
        gradientFilter.setValue(point1, forKey: "inputPoint1")
        gradientFilter.setValue(color0, forKey: "inputColor0")
        gradientFilter.setValue(color1, forKey: "inputColor1")

        return gradientFilter.outputImage?.cropped(to: canvasRect)
    }

    /// Mask for later blur passes. Each pass starts at its own onset X —
    /// spread from the cover's right edge to `onsetSpanRatio` of the way into
    /// the extension region — and ramps smoothly to full strength at
    /// `blurEndX`. The cover interior (left of every onset) stays at mask 0,
    /// so only pass 0's base curve touches it.
    private nonisolated static func staggeredOnsetMask(
        passIndex: Int,
        featherPassCount: Int,
        coverEdgeX: CGFloat,
        blurEndX: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        guard let gradientFilter = CIFilter(name: "CISmoothLinearGradient") else {
            return nil
        }

        // Onsets are mildly biased toward the cover edge (power curve) and
        // each pass ramps over a fixed fraction of the extension width, so
        // blur builds up early after the cover edge instead of saving most of
        // its growth for the far right. The last onset (0.55) plus the ramp
        // width (0.45) reaches full strength exactly at blurEndX.
        let onsetSpanRatio: CGFloat = 0.55
        let rampWidthRatio: CGFloat = 0.45
        let onsetExponent: CGFloat = 1.4
        let stretchWidth = max(1, blurEndX - coverEdgeX)
        let onsetFraction: CGFloat
        if featherPassCount <= 1 {
            onsetFraction = 0
        } else {
            let linearStep = CGFloat(passIndex - 1) / CGFloat(featherPassCount - 1)
            onsetFraction = onsetSpanRatio * pow(linearStep, onsetExponent)
        }
        let onsetX = coverEdgeX + stretchWidth * onsetFraction
        let endX = max(onsetX + 1, min(onsetX + stretchWidth * rampWidthRatio, blurEndX))

        let point0 = CIVector(x: onsetX, y: canvasLogicalHeight / 2)
        let point1 = CIVector(x: endX, y: canvasLogicalHeight / 2)
        let color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        gradientFilter.setValue(point0, forKey: "inputPoint0")
        gradientFilter.setValue(point1, forKey: "inputPoint1")
        gradientFilter.setValue(color0, forKey: "inputColor0")
        gradientFilter.setValue(color1, forKey: "inputColor1")

        return gradientFilter.outputImage?.cropped(to: canvasRect)
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

        // Interpolate the stretched strip smoothly. Nearest-neighbour turned
        // the few source columns into ~100px-wide flat vertical bands; flat
        // bands are invariant under horizontal blur, so they read as blocky
        // "steps" in the gradient no matter how the blur masks are shaped.
        context.interpolationQuality = .high
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
        // Retain a small window of recent renders so re-selecting a recently
        // shown track swaps in instantly within a session. `2` evicted the
        // previous render almost immediately, forcing a cold multi-pass
        // CIMaskedVariableBlur re-render on nearly every switch.
        cache.countLimit = 6
        cache.totalCostLimit = 64 * 1024 * 1024
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
