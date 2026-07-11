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

private let coverGradientBlurRendererCacheVersion = "smoothStretchV15"

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

enum CoverGradientBlurArtworkPlacement: String, Sendable {
    case leading
    case centeredSymmetric
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
    var artworkPlacement: CoverGradientBlurArtworkPlacement = .leading

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
            format: "%@-%.1f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%.3f-%@-%@-%@-%@-%.3f-%@-%.3f",
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
            config.artworkPlacement.rawValue,
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

// MARK: - Rendered frame publication

/// A guarded final render that may be downsampled and uploaded by the
/// fullscreen Bokeh transition. The render-store actor remains private; this
/// value is published only after the existing artwork/render-key guards pass.
struct CoverGradientBlurRenderedFrame: @unchecked Sendable {
    let artworkChecksum: UInt64
    let renderKey: String
    let placement: CoverGradientBlurReadabilityPlacement
    let image: CGImage
    let logicalCanvasSize: CGSize
}

// MARK: - Main View

struct CoverGradientBlurBackgroundView: View {
    let artworkData: Data?
    let artworkImage: NSImage?
    let artworkChecksum: UInt64
    let dominantColor: NSColor?
    let config: CoverGradientBlurConfig
    let preferAdaptiveArtworkSizing: Bool
    /// When non-nil, the view publishes a readability snapshot (with a
    /// luminance map built from the final render) each time a render completes.
    /// Only the fullscreen Cover Blur bridge sets this.
    var readabilityPlacement: CoverGradientBlurReadabilityPlacement? = nil
    var onReadabilitySnapshot: (@MainActor (CoverGradientBlurReadabilitySnapshot) -> Void)? = nil
    /// Optional final-frame hook for the low-resolution fullscreen transition
    /// surface. It receives no cache or mutable render-store references.
    var onRenderedFrame: (@MainActor (CoverGradientBlurRenderedFrame) -> Void)? = nil

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
        preferAdaptiveArtworkSizing: Bool = false,
        readabilityPlacement: CoverGradientBlurReadabilityPlacement? = nil,
        onReadabilitySnapshot: (@MainActor (CoverGradientBlurReadabilitySnapshot) -> Void)? = nil,
        onRenderedFrame: (@MainActor (CoverGradientBlurRenderedFrame) -> Void)? = nil
    ) {
        self.artworkData = artworkData
        self.artworkImage = artworkImage
        self.artworkChecksum = artworkChecksum
        self.dominantColor = dominantColor
        self.config = config
        self.preferAdaptiveArtworkSizing = preferAdaptiveArtworkSizing
        self.readabilityPlacement = readabilityPlacement
        self.onReadabilitySnapshot = onReadabilitySnapshot
        self.onRenderedFrame = onRenderedFrame
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
            ColorRenderingAdapter.makeSwiftUIColor(dominantColor)
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
                    // Build the readability map from the final render in the
                    // same detached task - never on the main thread.
                    let map = RenderedBackdropReadabilityMap.make(from: image)
                    return CoverGradientBlurRenderedImageBox(image: image, readabilityMap: map)
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
            publishReadabilitySnapshot(
                image: renderedImage,
                map: renderedBox?.readabilityMap,
                forKey: key
            )
            publishRenderedFrame(image: renderedImage, forKey: key)
        } else {
            updateSourceImage(preparedArtwork, forKey: key)
            updateRenderedImage(nil, forKey: key)
        }
    }

    @MainActor
    private func publishReadabilitySnapshot(
        image: CGImage,
        map: RenderedBackdropReadabilityMap?,
        forKey key: RenderKey
    ) {
        guard let placement = readabilityPlacement,
              let map,
              let onReadabilitySnapshot else { return }
        // Stale-render guard: only publish if this render is still current.
        guard key == renderKey else { return }
        let snapshot = CoverGradientBlurReadabilitySnapshot(
            artworkChecksum: resolvedArtworkChecksum,
            renderKey: key.cacheKey,
            canvasPixelSize: CGSize(width: image.width, height: image.height),
            placement: placement,
            readabilityMap: map
        )
        onReadabilitySnapshot(snapshot)
    }

    @MainActor
    private func publishRenderedFrame(image: CGImage, forKey key: RenderKey) {
        guard let placement = readabilityPlacement,
              let onRenderedFrame else { return }
        // Match the readability hand-off contract: never publish a result from
        // a render that became stale while its background task was running.
        guard key == renderKey else { return }
        onRenderedFrame(
            CoverGradientBlurRenderedFrame(
                artworkChecksum: resolvedArtworkChecksum,
                renderKey: key.cacheKey,
                placement: placement,
                image: image,
                logicalCanvasSize: key.size
            )
        )
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
        let artworkX: CGFloat
        switch config.artworkPlacement {
        case .leading:
            artworkX = 0
        case .centeredSymmetric:
            artworkX = max(0, (canvasLogicalWidth - drawWidth) * 0.5)
        }
        let artworkRect = CGRect(x: artworkX, y: 0, width: drawWidth, height: canvasLogicalHeight)
        let artworkLeftEdgeX = max(0, min(canvasLogicalWidth, artworkRect.minX))
        let artworkRightEdgeX = max(artworkLeftEdgeX, min(artworkRect.maxX, canvasLogicalWidth))
        let artworkLeftEdgePixel = Int(artworkLeftEdgeX)
        let artworkRightEdgePixel = Int(artworkRightEdgeX)

        // Step 1: Render Artwork + Edge Extension
        guard let baseImage = renderBaseImage(
            artworkCGImage: artworkCGImage,
            canvasPixelWidth: canvasPixelWidth,
            canvasPixelHeight: canvasPixelHeight,
            artworkRect: artworkRect,
            artworkLeftEdgePixel: artworkLeftEdgePixel,
            artworkRightEdgePixel: artworkRightEdgePixel,
            config: config
        ) else {
            return nil
        }

        let visibleArtworkWidth = max(1, artworkRightEdgeX - artworkLeftEdgeX)

        let blurEndInsetRatioFromRight: CGFloat = 0.04
        let rightBlurStartX = artworkRightEdgeX - (visibleArtworkWidth * config.blurStartRatioFromEdge)
        let rightBlurEndX = max(
            rightBlurStartX + 1,
            canvasLogicalWidth - (visibleArtworkWidth * blurEndInsetRatioFromRight)
        )
        let leftBlurStartX = artworkLeftEdgeX + (visibleArtworkWidth * config.blurStartRatioFromEdge)
        let leftBlurEndX = min(
            leftBlurStartX - 1,
            visibleArtworkWidth * blurEndInsetRatioFromRight
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
            switch config.artworkPlacement {
            case .leading:
                nonLinearMask = progressiveRampMask(
                    blurStartX: rightBlurStartX,
                    blurEndX: rightBlurEndX,
                    canvasRect: canvasRect,
                    canvasLogicalHeight: canvasLogicalHeight,
                    alphaCoefficients: config.blurAlphaCoefficients
                )
            case .centeredSymmetric:
                nonLinearMask = symmetricProgressiveRampMask(
                    leftBlurStartX: leftBlurStartX,
                    leftBlurEndX: leftBlurEndX,
                    rightBlurStartX: rightBlurStartX,
                    rightBlurEndX: rightBlurEndX,
                    canvasRect: canvasRect,
                    canvasLogicalHeight: canvasLogicalHeight,
                    alphaCoefficients: config.blurAlphaCoefficients
                )
            }
        case .extensionOnly:
            switch config.artworkPlacement {
            case .leading:
                nonLinearMask = extensionOnlyMask(
                    artworkRightEdgeX: artworkRightEdgeX,
                    canvasRect: canvasRect,
                    canvasLogicalHeight: canvasLogicalHeight
                )
            case .centeredSymmetric:
                nonLinearMask = symmetricExtensionOnlyMask(
                    artworkLeftEdgeX: artworkLeftEdgeX,
                    artworkRightEdgeX: artworkRightEdgeX,
                    canvasRect: canvasRect,
                    canvasLogicalHeight: canvasLogicalHeight
                )
            }
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

        // Extension blur ramp. The cover-anchored masks (pass 0 + staggered)
        // are at or near 0 alpha exactly at the cover's right edge, so on their
        // own the fill region just past the cover is barely blurred and most of
        // the growth is saved for the far right. This extra masked-blur pass is
        // 0 across the cover (so the cover interior is untouched) and ramps up
        // CONTINUOUSLY across the fill region — 0 at the cover edge, easing up
        // to `floorRadius` toward the right — so blur builds up promptly after
        // the edge while still connecting to the cover at a low value with no
        // step. (The earlier version snapped to full in ~23px and then
        // plateaued, which read as a hard blur seam right at the cover→fill
        // boundary.) Gated by `extensionFloorStrength` so non-opted-in consumers
        // are unchanged.
        if config.extensionFloorStrength > 0,
           artworkLeftEdgePixel > 0 || artworkRightEdgePixel < canvasPixelWidth {
            let floorRadius = min(120, totalRadius * config.extensionFloorStrength)
            let floorMask: CIImage?
            switch config.artworkPlacement {
            case .leading:
                floorMask = extensionFloorMask(
                    coverEdgeX: artworkRightEdgeX,
                    // Linear rise from the cover edge: blur starts increasing at
                    // the very left end of the fill (no smoothstep dwell, so the
                    // wide stretch bands get buried from the start) and climbs
                    // continuously. ~18% of the cover-edge→blurEnd distance to the
                    // cap. Smaller = buries the bands faster; larger = gentler.
                    rampSpan: max(12, (rightBlurEndX - artworkRightEdgeX) * 0.18),
                    canvasRect: canvasRect,
                    canvasLogicalHeight: canvasLogicalHeight
                )
            case .centeredSymmetric:
                floorMask = symmetricExtensionFloorMask(
                    leftCoverEdgeX: artworkLeftEdgeX,
                    rightCoverEdgeX: artworkRightEdgeX,
                    leftRampSpan: max(12, (artworkLeftEdgeX - leftBlurEndX) * 0.18),
                    rightRampSpan: max(12, (rightBlurEndX - artworkRightEdgeX) * 0.18),
                    canvasRect: canvasRect,
                    canvasLogicalHeight: canvasLogicalHeight
                )
            }

            if floorRadius > 0,
               let floorMask,
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
                switch config.artworkPlacement {
                case .leading:
                    passMask = staggeredOnsetMask(
                        passIndex: passIndex,
                        featherPassCount: passRadii.count - 1,
                        coverEdgeX: artworkRightEdgeX,
                        blurEndX: rightBlurEndX,
                        canvasRect: canvasRect,
                        canvasLogicalHeight: canvasLogicalHeight
                    ) ?? nonLinearMask
                case .centeredSymmetric:
                    passMask = symmetricStaggeredOnsetMask(
                        passIndex: passIndex,
                        featherPassCount: passRadii.count - 1,
                        leftCoverEdgeX: artworkLeftEdgeX,
                        rightCoverEdgeX: artworkRightEdgeX,
                        leftBlurEndX: leftBlurEndX,
                        rightBlurEndX: rightBlurEndX,
                        canvasRect: canvasRect,
                        canvasLogicalHeight: canvasLogicalHeight
                    ) ?? nonLinearMask
                }
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

        let overlayAlphaMax = config.colorOverlayOpacity

        let overlayColor: CIColor
        if let dominant = dominantColor {
            overlayColor = CIColor(cgColor: ColorRenderingAdapter.makeCGColor(dominant))
        } else {
            overlayColor = CIColor(red: 0.15, green: 0.15, blue: 0.15)
        }

        let linearOverlay: CIImage?
        switch config.artworkPlacement {
        case .leading:
            linearOverlay = colorOverlayGradient(
                startX: artworkRightEdgeX - (visibleArtworkWidth * config.overlayStartRatioFromEdge),
                endX: canvasLogicalWidth,
                color: overlayColor,
                alphaMax: overlayAlphaMax,
                canvasRect: canvasRect,
                canvasLogicalHeight: canvasLogicalHeight
            )
        case .centeredSymmetric:
            linearOverlay = symmetricColorOverlayGradient(
                leftStartX: artworkLeftEdgeX + (visibleArtworkWidth * config.overlayStartRatioFromEdge),
                leftEndX: 0,
                rightStartX: artworkRightEdgeX - (visibleArtworkWidth * config.overlayStartRatioFromEdge),
                rightEndX: canvasLogicalWidth,
                color: overlayColor,
                alphaMax: overlayAlphaMax,
                canvasRect: canvasRect,
                canvasLogicalHeight: canvasLogicalHeight
            )
        }

        guard let linearOverlay else { return nil }

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

        let outputSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgImage = ciContext.createCGImage(
            finalImage,
            from: canvasRect,
            format: .RGBA8,
            colorSpace: outputSpace
        ) else {
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

    private nonisolated static func symmetricProgressiveRampMask(
        leftBlurStartX: CGFloat,
        leftBlurEndX: CGFloat,
        rightBlurStartX: CGFloat,
        rightBlurEndX: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat,
        alphaCoefficients: (CGFloat, CGFloat, CGFloat, CGFloat)?
    ) -> CIImage? {
        let leftMask = progressiveRampMask(
            blurStartX: leftBlurStartX,
            blurEndX: leftBlurEndX,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight,
            alphaCoefficients: alphaCoefficients
        )
        let rightMask = progressiveRampMask(
            blurStartX: rightBlurStartX,
            blurEndX: rightBlurEndX,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight,
            alphaCoefficients: alphaCoefficients
        )
        return maximumComposite(leftMask, rightMask, canvasRect: canvasRect)
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

    private nonisolated static func leftExtensionOnlyMask(
        artworkLeftEdgeX: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        guard let linearGradientFilter = CIFilter(name: "CILinearGradient") else {
            return nil
        }

        let point0 = CIVector(x: artworkLeftEdgeX + 0.5, y: canvasLogicalHeight / 2)
        let point1 = CIVector(x: artworkLeftEdgeX - 1.5, y: canvasLogicalHeight / 2)
        let color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        linearGradientFilter.setValue(point0, forKey: "inputPoint0")
        linearGradientFilter.setValue(point1, forKey: "inputPoint1")
        linearGradientFilter.setValue(color0, forKey: "inputColor0")
        linearGradientFilter.setValue(color1, forKey: "inputColor1")

        return linearGradientFilter.outputImage?.cropped(to: canvasRect)
    }

    private nonisolated static func symmetricExtensionOnlyMask(
        artworkLeftEdgeX: CGFloat,
        artworkRightEdgeX: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        let leftMask = leftExtensionOnlyMask(
            artworkLeftEdgeX: artworkLeftEdgeX,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight
        )
        let rightMask = extensionOnlyMask(
            artworkRightEdgeX: artworkRightEdgeX,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight
        )
        return maximumComposite(leftMask, rightMask, canvasRect: canvasRect)
    }

    /// Mask for the extension blur ramp pass. A LINEAR gradient (alpha 0→1) from
    /// the cover's right edge over `rampSpan`. Linear — not smoothstep — because
    /// the blur has to start INCREASING at the very left end of the fill:
    /// smoothstep leaves 0 with zero slope, so the floor dwelt near 0 for the
    /// first stretch of the fill (the wide stretch bands stayed fully visible) and
    /// only ramped up some distance in, which read as "the blur suddenly kicks in
    /// to the right of the start". A linear ramp rises immediately at a constant
    /// rate, so blur grows continuously from the fill's left edge. The value is
    /// still 0 exactly at the cover edge (alpha clamps to 0 to the left), so it
    /// joins pass 0's raised edge value without a step — pass 0 supplies the base
    /// blur at the junction while this climbs.
    private nonisolated static func extensionFloorMask(
        coverEdgeX: CGFloat,
        rampSpan: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        guard let gradientFilter = CIFilter(name: "CILinearGradient") else {
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

    private nonisolated static func leftExtensionFloorMask(
        coverEdgeX: CGFloat,
        rampSpan: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        guard let gradientFilter = CIFilter(name: "CILinearGradient") else {
            return nil
        }

        let point0 = CIVector(x: coverEdgeX, y: canvasLogicalHeight / 2)
        let point1 = CIVector(x: coverEdgeX - max(1, rampSpan), y: canvasLogicalHeight / 2)
        let color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        gradientFilter.setValue(point0, forKey: "inputPoint0")
        gradientFilter.setValue(point1, forKey: "inputPoint1")
        gradientFilter.setValue(color0, forKey: "inputColor0")
        gradientFilter.setValue(color1, forKey: "inputColor1")

        return gradientFilter.outputImage?.cropped(to: canvasRect)
    }

    private nonisolated static func symmetricExtensionFloorMask(
        leftCoverEdgeX: CGFloat,
        rightCoverEdgeX: CGFloat,
        leftRampSpan: CGFloat,
        rightRampSpan: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        let leftMask = leftExtensionFloorMask(
            coverEdgeX: leftCoverEdgeX,
            rampSpan: leftRampSpan,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight
        )
        let rightMask = extensionFloorMask(
            coverEdgeX: rightCoverEdgeX,
            rampSpan: rightRampSpan,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight
        )
        return maximumComposite(leftMask, rightMask, canvasRect: canvasRect)
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

        // Onsets are spread EVENLY (exponent 1.0) from the cover's right edge
        // out to `onsetSpanRatio` of the fill, so a new blur layer keeps turning
        // on across the whole fill — including the right half — and the blur
        // keeps climbing to several hundred px all the way to the right edge
        // instead of saturating in the first half. (The earlier 0.55 span with a
        // cover-edge-biased 1.4 exponent turned every extra layer on within the
        // first ~55%, which read as "the right side stops getting blurrier".)
        // The near-edge fast onset is handled by the extension floor pass, not
        // here, so these onsets don't need to be biased toward the cover edge.
        // Each pass ramps over `rampWidthRatio` of the fill; the latest onset's
        // ramp is clamped to end at blurEndX so every pass reaches full there.
        let onsetSpanRatio: CGFloat = 0.85
        let rampWidthRatio: CGFloat = 0.45
        let onsetExponent: CGFloat = 1.0
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

    private nonisolated static func leftStaggeredOnsetMask(
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

        let onsetSpanRatio: CGFloat = 0.85
        let rampWidthRatio: CGFloat = 0.45
        let onsetExponent: CGFloat = 1.0
        let stretchWidth = max(1, coverEdgeX - blurEndX)
        let onsetFraction: CGFloat
        if featherPassCount <= 1 {
            onsetFraction = 0
        } else {
            let linearStep = CGFloat(passIndex - 1) / CGFloat(featherPassCount - 1)
            onsetFraction = onsetSpanRatio * pow(linearStep, onsetExponent)
        }
        let onsetX = coverEdgeX - stretchWidth * onsetFraction
        let endX = min(onsetX - 1, max(onsetX - stretchWidth * rampWidthRatio, blurEndX))

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

    private nonisolated static func symmetricStaggeredOnsetMask(
        passIndex: Int,
        featherPassCount: Int,
        leftCoverEdgeX: CGFloat,
        rightCoverEdgeX: CGFloat,
        leftBlurEndX: CGFloat,
        rightBlurEndX: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        let leftMask = leftStaggeredOnsetMask(
            passIndex: passIndex,
            featherPassCount: featherPassCount,
            coverEdgeX: leftCoverEdgeX,
            blurEndX: leftBlurEndX,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight
        )
        let rightMask = staggeredOnsetMask(
            passIndex: passIndex,
            featherPassCount: featherPassCount,
            coverEdgeX: rightCoverEdgeX,
            blurEndX: rightBlurEndX,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight
        )
        return maximumComposite(leftMask, rightMask, canvasRect: canvasRect)
    }

    private nonisolated static func colorOverlayGradient(
        startX: CGFloat,
        endX: CGFloat,
        color: CIColor,
        alphaMax: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        guard let overlayGradientFilter = CIFilter(name: "CILinearGradient") else {
            return nil
        }

        let overlayPoint0 = CIVector(x: startX, y: canvasLogicalHeight / 2)
        let overlayPoint1 = CIVector(x: endX, y: canvasLogicalHeight / 2)
        let overlayColor0 = CIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 0
        )
        let overlayColor1 = CIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: alphaMax
        )

        overlayGradientFilter.setValue(overlayPoint0, forKey: "inputPoint0")
        overlayGradientFilter.setValue(overlayPoint1, forKey: "inputPoint1")
        overlayGradientFilter.setValue(overlayColor0, forKey: "inputColor0")
        overlayGradientFilter.setValue(overlayColor1, forKey: "inputColor1")

        return overlayGradientFilter.outputImage?.cropped(to: canvasRect)
    }

    private nonisolated static func symmetricColorOverlayGradient(
        leftStartX: CGFloat,
        leftEndX: CGFloat,
        rightStartX: CGFloat,
        rightEndX: CGFloat,
        color: CIColor,
        alphaMax: CGFloat,
        canvasRect: CGRect,
        canvasLogicalHeight: CGFloat
    ) -> CIImage? {
        let leftOverlay = colorOverlayGradient(
            startX: leftStartX,
            endX: leftEndX,
            color: color,
            alphaMax: alphaMax,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight
        )
        let rightOverlay = colorOverlayGradient(
            startX: rightStartX,
            endX: rightEndX,
            color: color,
            alphaMax: alphaMax,
            canvasRect: canvasRect,
            canvasLogicalHeight: canvasLogicalHeight
        )
        return maximumComposite(leftOverlay, rightOverlay, canvasRect: canvasRect)
    }

    private nonisolated static func maximumComposite(
        _ first: CIImage?,
        _ second: CIImage?,
        canvasRect: CGRect
    ) -> CIImage? {
        switch (first, second) {
        case let (first?, second?):
            guard let maxFilter = CIFilter(name: "CIMaximumCompositing") else {
                return first.cropped(to: canvasRect)
            }
            maxFilter.setValue(second, forKey: kCIInputImageKey)
            maxFilter.setValue(first, forKey: kCIInputBackgroundImageKey)
            return maxFilter.outputImage?.cropped(to: canvasRect)
        case let (first?, nil):
            return first.cropped(to: canvasRect)
        case let (nil, second?):
            return second.cropped(to: canvasRect)
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Render Base Image

    private nonisolated static func renderBaseImage(
        artworkCGImage: CGImage,
        canvasPixelWidth: Int,
        canvasPixelHeight: Int,
        artworkRect: CGRect,
        artworkLeftEdgePixel: Int,
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

        let hasLeftExtension = artworkLeftEdgePixel > 0
        let hasRightExtension = artworkRightEdgePixel < canvasPixelWidth

        guard hasLeftExtension || hasRightExtension else {
            return context.makeImage()
        }

        switch config.edgeFillMode {
        case .pixelStretch:
            return renderPixelStretchExtensions(
                context: context,
                artworkCGImage: artworkCGImage,
                artworkRect: artworkRect,
                artworkLeftEdgePixel: artworkLeftEdgePixel,
                artworkRightEdgePixel: artworkRightEdgePixel,
                canvasPixelWidth: canvasPixelWidth,
                canvasPixelHeight: canvasPixelHeight,
                config: config
            )
        case .mirroredCover:
            return renderMirroredCoverExtensions(
                context: context,
                artworkCGImage: artworkCGImage,
                artworkRect: artworkRect,
                artworkLeftEdgePixel: artworkLeftEdgePixel,
                artworkRightEdgePixel: artworkRightEdgePixel,
                canvasPixelWidth: canvasPixelWidth,
                canvasPixelHeight: canvasPixelHeight
            )
        }
    }

    // MARK: - Pixel Stretch Extension (Original Method)

    private nonisolated static func renderPixelStretchExtensions(
        context: CGContext,
        artworkCGImage: CGImage,
        artworkRect: CGRect,
        artworkLeftEdgePixel: Int,
        artworkRightEdgePixel: Int,
        canvasPixelWidth: Int,
        canvasPixelHeight: Int,
        config: CoverGradientBlurConfig
    ) -> CGImage? {

        if artworkLeftEdgePixel > 0 {
            let extensionPixelStart = 0
            let extensionPixelWidth = artworkLeftEdgePixel
            let stripPixelWidth = Int(min(config.edgeStripWidth, artworkRect.width)) + 1
            let stripPixelEnd = min(canvasPixelWidth, artworkLeftEdgePixel + stripPixelWidth)
            let actualStripPixelWidth = max(0, stripPixelEnd - artworkLeftEdgePixel)

            if actualStripPixelWidth > 0 {
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
                let sourceStripRect = CGRect(
                    x: 0,
                    y: 0,
                    width: sourceStripWidth,
                    height: artworkCGImage.height
                )

                if let stripCGImage = artworkCGImage.cropping(to: sourceStripRect) {
                    context.interpolationQuality = .high
                    context.draw(stripCGImage, in: extensionRect)
                }
            }
        }

        let extensionPixelStart = artworkRightEdgePixel
        let extensionPixelWidth = canvasPixelWidth - extensionPixelStart

        guard extensionPixelWidth > 0 else {
            return context.makeImage()
        }

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

    private nonisolated static func renderMirroredCoverExtensions(
        context: CGContext,
        artworkCGImage: CGImage,
        artworkRect: CGRect,
        artworkLeftEdgePixel: Int,
        artworkRightEdgePixel: Int,
        canvasPixelWidth: Int,
        canvasPixelHeight: Int
    ) -> CGImage? {

        if artworkLeftEdgePixel > 0 {
            let extensionPixelWidth = artworkLeftEdgePixel
            let artworkHeight = artworkRect.height
            let stretchRatio: CGFloat = 2.0
            let stretchedWidth = artworkRect.width * stretchRatio
            let targetRect = CGRect(
                x: CGFloat(artworkLeftEdgePixel) - stretchedWidth,
                y: 0,
                width: stretchedWidth,
                height: artworkHeight
            )
            let extensionClipRect = CGRect(
                x: 0,
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
        }

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
    nonisolated let readabilityMap: RenderedBackdropReadabilityMap?
    nonisolated let cost: Int

    nonisolated init(image: CGImage, readabilityMap: RenderedBackdropReadabilityMap?) {
        self.image = image
        self.readabilityMap = readabilityMap
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
