//
//  CoverGradientBlurBackgroundView.swift
//  myPlayer2
//
//  kmgccc_player - Variable Blur Background for Fullscreen Player
//

import AppKit
import CoreImage
import SwiftUI

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
        overlayCurveGamma: 3.0
    )
}

// MARK: - Render Key

private struct RenderKey: Equatable {
    let trackID: UUID?
    let size: CGSize
    let configHash: String
    let dominantColorHash: String
    
    init(trackID: UUID?, size: CGSize, config: CoverGradientBlurConfig, dominantColor: NSColor?) {
        self.trackID = trackID
        let quantizedWidth = max(100, CGFloat(Int(size.width / 10) * 10))
        let quantizedHeight = max(100, CGFloat(Int(size.height / 10) * 10))
        self.size = CGSize(width: quantizedWidth, height: quantizedHeight)
        self.configHash = "\(Int(config.blurRadius))-\(Int(config.blurCurveGamma * 10))"
        self.dominantColorHash = dominantColor?.hexString ?? "nil"
    }
}

// MARK: - Main View

struct CoverGradientBlurBackgroundView: View {
    let artworkData: Data?
    let dominantColor: NSColor?
    let trackID: UUID?
    let config: CoverGradientBlurConfig

    @State private var renderedCGImage: CGImage?
    @State private var visibleRenderedImage: Bool = false
    @State private var lastRenderKey: RenderKey?

    private var logPrefix: String { "[CoverGradientBlur]" }
    
    private var renderKey: RenderKey {
        RenderKey(trackID: trackID, size: currentSize, config: config, dominantColor: dominantColor)
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
                Task { @MainActor in
                    currentSize = geometry.size
                }
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
        if let cgImage = createRawCGImage() {
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

    private func createRawCGImage() -> CGImage? {
        guard let data = artworkData else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func performRender() async {
        let key = renderKey
        
        if lastRenderKey == key, renderedCGImage != nil { return }
        
        guard let data = artworkData else {
            await updateRenderedImage(nil, forKey: key)
            return
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        if let result = CoverGradientBlurRenderer.render(
            artworkData: data,
            targetSize: key.size,
            dominantColor: dominantColor,
            config: config,
            trackID: trackID
        ) {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            NSLog("\(logPrefix) Render SUCCESS in \(elapsed * 1000)ms for trackID: \(trackID?.uuidString.prefix(8) ?? "nil")")
            await updateRenderedImage(result, forKey: key)
        } else {
            NSLog("\(logPrefix) Render FAILED")
            await updateRenderedImage(nil, forKey: key)
        }
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
}

// MARK: - Renderer

enum CoverGradientBlurRenderer {
    
    static func render(
        artworkData: Data,
        targetSize: CGSize,
        dominantColor: NSColor?,
        config: CoverGradientBlurConfig,
        trackID: UUID?
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

        guard let source = CGImageSourceCreateWithData(artworkData as CFData, nil),
              let artworkCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let artworkWidth = CGFloat(artworkCGImage.width)
        let artworkHeight = CGFloat(artworkCGImage.height)

        let scale = canvasLogicalHeight / artworkHeight
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
            NSLog("[BlurFinal] ERROR: Failed to render base image")
            return nil
        }

        let visibleArtworkWidth = artworkRightEdgeX
        let blurStartRatioFromEdge: CGFloat = 0.42
        let overlayStartRatioFromEdge: CGFloat = 0.28
        let blurStartX = artworkRightEdgeX - (visibleArtworkWidth * blurStartRatioFromEdge)
        let blurEndX = canvasLogicalWidth
        let blurRegionWidth = blurEndX - blurStartX

        NSLog("[Tune] artworkRightEdgeX = \(artworkRightEdgeX)")
        NSLog("[Tune] blurStartX = \(blurStartX) (\(Int(blurStartRatioFromEdge * 100))% from edge)")
        NSLog("[Tune] blurEndX = \(blurEndX)")
        NSLog("[Tune] blur region width = \(blurRegionWidth)")

        let ciContext = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false
        ])
        
        let baseCIImage = CIImage(cgImage: baseImage)
        
        // Clamp the image to extend edge pixels infinitely - prevents blur from sampling transparent/black at boundaries
        guard let clampFilter = CIFilter(name: "CIAffineClamp") else {
            NSLog("[BlurClamp] ERROR: Failed to create CIAffineClamp filter")
            return nil
        }
        clampFilter.setValue(baseCIImage, forKey: kCIInputImageKey)
        clampFilter.setValue(CGAffineTransform.identity, forKey: kCIInputTransformKey)
        
        guard let clampedImage = clampFilter.outputImage else {
            NSLog("[BlurClamp] ERROR: Clamped image is nil")
            return nil
        }
        
        NSLog("[BlurClamp] baseImage extent = \(baseCIImage.extent)")
        NSLog("[BlurClamp] clampedImage extent = \(clampedImage.extent) (infinite)")
        
        guard let linearGradientFilter = CIFilter(name: "CILinearGradient") else {
            NSLog("[BlurCurve] ERROR: Failed to create gradient filter")
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
            NSLog("[BlurCurve] ERROR: Linear gradient mask is nil")
            return nil
        }
        
        // CIColorPolynomial: t' = a + b*t + c*t² + d*t³, using 0.5*t² + 0.5*t³ for alpha gives moderate ease-in curve
        guard let polynomialFilter = CIFilter(name: "CIColorPolynomial") else {
            NSLog("[BlurCurve] ERROR: Failed to create polynomial filter")
            return nil
        }
        
        let rCoeff = CIVector(x: 0, y: 0, z: 0, w: 1)
        let gCoeff = CIVector(x: 0, y: 0, z: 0, w: 1)
        let bCoeff = CIVector(x: 0, y: 0, z: 0, w: 1)
        let aCoeff = CIVector(x: 0, y: 0, z: 0.5, w: 0.5)
        
        polynomialFilter.setValue(linearMask, forKey: kCIInputImageKey)
        polynomialFilter.setValue(rCoeff, forKey: "inputRedCoefficients")
        polynomialFilter.setValue(gCoeff, forKey: "inputGreenCoefficients")
        polynomialFilter.setValue(bCoeff, forKey: "inputBlueCoefficients")
        polynomialFilter.setValue(aCoeff, forKey: "inputAlphaCoefficients")
        
        guard let nonLinearMask = polynomialFilter.outputImage?.cropped(to: canvasRect) else {
            NSLog("[BlurCurve] ERROR: Non-linear mask is nil")
            return nil
        }
        
        NSLog("[BlurCurve] blurStartX = \(blurStartX)")
        NSLog("[BlurCurve] blurEndX = \(blurEndX)")
        NSLog("[BlurCurve] blurProgress curve type = 0.5t² + 0.5t³ - moderate ease-in")

        // Apply variable blur with non-linear mask
        guard let blurFilter = CIFilter(name: "CIMaskedVariableBlur") else {
            NSLog("[BlurCurve] ERROR: Failed to create blur filter")
            return nil
        }

        blurFilter.setValue(clampedImage, forKey: kCIInputImageKey)
        blurFilter.setValue(config.blurRadius, forKey: kCIInputRadiusKey)
        blurFilter.setValue(nonLinearMask, forKey: "inputMask")

        guard let blurredImage = blurFilter.outputImage?.cropped(to: canvasRect) else {
            NSLog("[BlurCurve] ERROR: Blur output is nil")
            return nil
        }
        
        NSLog("[BlurEdge] blurred extent before crop = \(blurFilter.outputImage?.extent ?? .null)")
        NSLog("[BlurEdge] final cropped extent = \(blurredImage.extent)")

        let overlayStartX = artworkRightEdgeX - (visibleArtworkWidth * overlayStartRatioFromEdge)
        let overlayEndX = canvasLogicalWidth
        let overlayAlphaMax = config.colorOverlayOpacity
        let overlayRegionWidth = overlayEndX - overlayStartX

        NSLog("[Tune] overlayStartX = \(overlayStartX) (\(Int(overlayStartRatioFromEdge * 100))% from artwork edge)")
        NSLog("[Tune] overlayEndX = \(overlayEndX)")
        NSLog("[Tune] overlayGamma = \(config.overlayCurveGamma)")
        NSLog("[Tune] overlay region width = \(overlayRegionWidth)")

        let overlayColor: CIColor
        if let dominant = dominantColor {
            overlayColor = CIColor(cgColor: dominant.cgColor)
        } else {
            overlayColor = CIColor(red: 0.15, green: 0.15, blue: 0.15)
        }

        guard let overlayGradientFilter = CIFilter(name: "CILinearGradient") else {
            NSLog("[BlurFinal] ERROR: Failed to create overlay gradient filter")
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
            NSLog("[BlurFinal] ERROR: Overlay gradient is nil")
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
            NSLog("[BlurFinal] ERROR: Failed to create composite filter")
            return nil
        }

        compositeFilter.setValue(blurredImage, forKey: kCIInputBackgroundImageKey)
        compositeFilter.setValue(overlayImage, forKey: kCIInputImageKey)

        guard let finalImage = compositeFilter.outputImage?.cropped(to: canvasRect) else {
            NSLog("[BlurFinal] ERROR: Final composite is nil")
            return nil
        }

        // Log Parameters
        NSLog("[BlurFinal] trackID = \(trackID?.uuidString.prefix(8) ?? "nil")")
        NSLog("[BlurFinal] canvas logical size = \(canvasLogicalWidth)x\(canvasLogicalHeight)")
        NSLog("[BlurFinal] canvas bitmap pixels = \(canvasPixelWidth)x\(canvasPixelHeight)")
        NSLog("[BlurFinal] artworkRect = \(artworkRect)")
        NSLog("[BlurFinal] artworkRightEdgeX = \(artworkRightEdgeX)")
        NSLog("[BlurFinal] blurStartX = \(blurStartX)")
        NSLog("[BlurFinal] blurEndX = \(blurEndX)")
        NSLog("[BlurFinal] overlayStartX = \(overlayStartX) (linked to blur)")
        NSLog("[BlurFinal] overlayEndX = \(overlayEndX)")
        NSLog("[BlurFinal] overlayAlphaMax = \(overlayAlphaMax)")
        NSLog("[BlurFinal] dominantColor = \(dominantColor?.hexString ?? "nil")")

        guard let cgImage = ciContext.createCGImage(finalImage, from: canvasRect) else {
            NSLog("[BlurFinal] ERROR: createCGImage returned nil")
            return nil
        }

        NSLog("[BlurFinal] output pixel size: \(cgImage.width)x\(cgImage.height)")
        return cgImage
    }

    // MARK: - Render Base Image (Pixel-Perfect Extension)

    private static func renderBaseImage(
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
            NSLog("[BlurFinal] ERROR: Failed to create CGContext")
            return nil
        }
        
        // DO NOT FLIP: CGImage pixel order (top-to-bottom) matches CG context
        // Flipping Y would rotate image 180°
        
        context.interpolationQuality = .high
        context.draw(artworkCGImage, in: artworkRect)
        
        guard artworkRightEdgePixel < canvasPixelWidth else {
            let result = context.makeImage()
            NSLog("[BlurFinal] No extension needed. artworkRightEdgePixel=\(artworkRightEdgePixel), canvasPixelWidth=\(canvasPixelWidth)")
            return result
        }
        
        let extensionPixelStart = artworkRightEdgePixel
        let extensionPixelWidth = canvasPixelWidth - extensionPixelStart
        
        let stripPixelWidth = Int(min(config.edgeStripWidth, artworkRect.width)) + 1
        let stripPixelStart = max(0, artworkRightEdgePixel - stripPixelWidth)
        let actualStripPixelWidth = artworkRightEdgePixel - stripPixelStart
        
        let stripSourceRect = CGRect(
            x: CGFloat(stripPixelStart),
            y: 0,
            width: CGFloat(actualStripPixelWidth),
            height: CGFloat(canvasPixelHeight)
        )
        
        let extensionRect = CGRect(
            x: CGFloat(extensionPixelStart),
            y: 0,
            width: CGFloat(extensionPixelWidth),
            height: CGFloat(canvasPixelHeight)
        )
        
        NSLog("[BlurFinal] Extension: startPixel=\(extensionPixelStart), widthPixels=\(extensionPixelWidth)")
        
        guard let fullBitmap = context.makeImage(),
              let stripCGImage = fullBitmap.cropping(to: stripSourceRect) else {
            NSLog("[BlurFinal] ERROR: Failed to crop strip for extension")
            return context.makeImage()
        }
        
        context.interpolationQuality = .none
        context.draw(stripCGImage, in: extensionRect)
        
        guard let result = context.makeImage() else {
            NSLog("[BlurFinal] ERROR: Failed to create result image")
            return nil
        }
        
        NSLog("[BlurFinal] Base image result: \(result.width)x\(result.height) pixels")
        
        if result.width != canvasPixelWidth {
            NSLog("[BlurFinal] WARNING: Result width \(result.width) != canvasPixelWidth \(canvasPixelWidth)")
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
        dominantColor: NSColor.systemBlue,
        trackID: UUID(),
        config: .fullscreen
    )
    .frame(width: 800, height: 600)
}
