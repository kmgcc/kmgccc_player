import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import kmgccc_player

final class CoverGradientBlurRenderStoreTests: XCTestCase {
    @MainActor
    func testBokehSourceIsCenterSquareOfOffSquareArtwork() throws {
        // Red, green and blue thirds: only the green middle may survive.
        let context = try bitmapContext(width: 96, height: 32)
        for (index, color) in [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                               CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                               CGColor(red: 0, green: 0, blue: 1, alpha: 1)].enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: CGFloat(index * 32), y: 0, width: 32, height: 32))
        }
        let artwork = try XCTUnwrap(context.makeImage())
        let request = BokehTransitionSourceRequest(
            artworkData: try encodedArtwork(artwork, type: UTType.png.identifier),
            artworkImage: nil,
            viewport: CGSize(width: 1200, height: 780),
            displayScale: 2,
            checksum: 1,
            sourceKey: "square",
            tier: .balanced,
            style: BokehTransitionSourceStyle(
                leading: .leading, centered: .centered, edgeFill: .stretch, overlay: nil
            )
        )
        let prepared = try XCTUnwrap(request.prepare())

        XCTAssertEqual(prepared.cover.width, prepared.cover.height)
        let bytes = try rgbaBytes(from: prepared.cover)
        let bytesPerRow = bytes.count / prepared.cover.height
        for (x, y) in [(0, 0), (prepared.cover.width - 1, prepared.cover.height / 2)] {
            let offset = y * bytesPerRow + x * 4
            XCTAssertGreaterThan(Int(bytes[offset + 1]), 200, "(\(x), \(y)) should be green")
            XCTAssertLessThan(Int(bytes[offset]), 40, "(\(x), \(y)) should be green")
            XCTAssertLessThan(Int(bytes[offset + 2]), 40, "(\(x), \(y)) should be green")
        }

        // The drawable keeps the viewport's aspect to the pixel and its budget.
        let size = prepared.identity.renderSize
        XCTAssertLessThanOrEqual(abs(Double(size.width) / Double(size.height) - 1200.0 / 780.0), 0.005)
        XCTAssertLessThanOrEqual(size.pixelCount, BokehTransitionRenderTier.balanced.pixelBudget + size.width + size.height)
        XCTAssertTrue(BokehTransitionRenderTier.balanced.shortEdgeRange.contains(min(size.width, size.height)))
    }

    @MainActor
    func testLiveMotionBlurRemainsPixelCloseWithoutIntermediateMaterialization() throws {
        let artwork = try stripedArtwork(width: 320, height: 160)
        var failures: [String] = []

        for placement in [CoverGradientBlurArtworkPlacement.leading, .centeredSymmetric] {
            for edgeFillMode in [CoverEdgeFillMode.pixelStretch, .mirroredCover] {
                var config = CoverGradientBlurConfig.default
                config.blurRadius = 1_600
                config.colorOverlayOpacity = 0.5
                config.extensionFloorStrength = placement == .leading ? 0.2 : 0.16
                config.artworkPlacement = placement
                config.edgeFillMode = edgeFillMode

                let render: (Bool) throws -> CGImage = { materializePasses in
                    try XCTUnwrap(CoverGradientBlurRenderer.render(
                        artworkCGImage: artwork,
                        targetSize: CGSize(width: 240, height: 80),
                        dominantColor: nil,
                        config: config,
                        displayScale: 1,
                        materializeIntermediateBlurPasses: materializePasses
                    ))
                }
                let reference = try render(true)
                let live = try render(false)

                XCTAssertEqual(reference.width, live.width)
                XCTAssertEqual(reference.height, live.height)
                let referenceBytes = try rgbaBytes(from: reference)
                let liveBytes = try rgbaBytes(from: live)
                let channelDifferences = zip(referenceBytes, liveBytes)
                    .map { abs(Int($0.0) - Int($0.1)) }
                let maximumChannelDifference = channelDifferences
                    .max() ?? 0
                let meanChannelDifference = Double(channelDifferences.reduce(0, +))
                    / Double(max(1, channelDifferences.count))
                if maximumChannelDifference > 3 || meanChannelDifference > 0.5 {
                    failures.append(
                        "\(placement), \(edgeFillMode), max=\(maximumChannelDifference), "
                            + "mean=\(meanChannelDifference)"
                    )
                }
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "Live output exceeded the 3/255 maximum or 0.5/255 mean channel tolerance: "
                + failures.joined(separator: "; ")
        )
    }

    @MainActor
    func testRetinaRenderKeepsFineLinesInClearCoverForBothPlacements() throws {
        let artwork = try stripedArtwork(width: 320, height: 160)
        for placement in [CoverGradientBlurArtworkPlacement.leading, .centeredSymmetric] {
            var config = CoverGradientBlurConfig.default
            config.artworkPlacement = placement
            config.blurStartRatioFromEdge = placement == .centeredSymmetric ? 0.22 : 0.48
            config.colorOverlayOpacity = 0
            let result = try XCTUnwrap(CoverGradientBlurRenderer.render(
                artworkCGImage: artwork,
                targetSize: CGSize(width: 240, height: 80),
                dominantColor: nil,
                config: config,
                displayScale: 2
            ))
            XCTAssertEqual(result.width, 480)
            XCTAssertEqual(result.height, 160)
            let context = try bitmapContext(width: result.width, height: result.height)
            context.draw(result, in: CGRect(x: 0, y: 0, width: CGFloat(result.width), height: CGFloat(result.height)))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            // Both positions are well inside the unblurred cover. Half-size
            // rendering averages these alternating one-pixel stripes away.
            let x = placement == .leading ? 40 : 240
            let first = Int(bytes[80 * context.bytesPerRow + x * 4])
            let second = Int(bytes[80 * context.bytesPerRow + (x + 1) * 4])
            XCTAssertGreaterThan(abs(first - second), 180, "\(placement)")
        }
    }

    @MainActor
    func testProgressiveProfileKeepsClearCoverAndSmoothsFarFill() throws {
        try XCTSkipUnless(CoverProgressiveBlurRenderer.isAvailable, "Metal unavailable")
        let artwork = try stripedArtwork(width: 320, height: 160)
        for (placement, profile) in [
            (CoverGradientBlurArtworkPlacement.leading, CoverProgressiveBlurProfile.leading),
            (.centeredSymmetric, .centered),
        ] {
            var config = CoverGradientBlurConfig.default
            config.artworkPlacement = placement
            config.colorOverlayOpacity = 0
            config.progressiveProfile = profile
            let result = try XCTUnwrap(CoverGradientBlurRenderer.render(
                artworkCGImage: artwork,
                targetSize: CGSize(width: 240, height: 80),
                dominantColor: nil,
                config: config,
                displayScale: 2
            ))
            XCTAssertEqual(result.width, 480)
            XCTAssertEqual(result.height, 160)
            let context = try bitmapContext(width: result.width, height: result.height)
            context.draw(result, in: CGRect(x: 0, y: 0, width: CGFloat(result.width), height: CGFloat(result.height)))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            func red(_ x: Int) -> Int { Int(bytes[80 * context.bytesPerRow + x * 4]) }
            // Inside the clear cover the one-pixel stripes survive intact.
            let clearX = placement == .leading ? 40 : 240
            XCTAssertGreaterThan(abs(red(clearX) - red(clearX + 1)), 180, "\(placement)")
            // Near the canvas edge the stretched fill is fully blurred.
            XCTAssertLessThan(abs(red(470) - red(471)), 8, "\(placement)")
        }
    }

    func testPreparedCoverUsesStoredDataInsteadOfSmallPlaybackDerivative() throws {
        let artwork = try stripedArtwork(width: 320, height: 160)
        let data = try encodedArtwork(artwork, type: UTType.png.identifier)
        let derivative = NSImage(cgImage: try stripedArtwork(width: 32, height: 16), size: .zero)
        let prepared = try XCTUnwrap(CoverGradientBlurRenderer.preparedArtworkImage(
            artworkData: data,
            artworkImage: derivative,
            targetSize: CGSize(width: 480, height: 160)
        ))
        XCTAssertEqual(prepared.width, 320)
        XCTAssertEqual(prepared.height, 160)
    }

    func testSourceArtworkPreservesJPEGAndPNGRegardlessOfLegacyBudget() throws {
        let artwork = try stripedArtwork(width: 320, height: 160)
        let jpeg = try encodedArtwork(artwork, type: UTType.jpeg.identifier)
        XCTAssertEqual(ArtworkDataNormalizer.normalizedJPEGData(from: jpeg), jpeg)
        let bounded = try XCTUnwrap(ArtworkDataNormalizer.normalizedJPEGData(from: jpeg, maxPixelSize: 160))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bounded as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(bounded, jpeg)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 160)
        let png = try encodedArtwork(artwork, type: UTType.png.identifier)
        XCTAssertEqual(ArtworkDataNormalizer.normalizedJPEGData(from: png, maxPixelSize: 80), png)
        XCTAssertEqual(ArtworkDataNormalizer.fileExtension(for: png), "png")
        XCTAssertEqual(ArtworkDataNormalizer.fileExtension(for: jpeg), "jpg")
    }

    func testOriginalAboveFormerStorageLimitKeepsFullResolution() throws {
        let jpeg = try encodedArtwork(try stripedArtwork(width: 4096, height: 1024), type: UTType.jpeg.identifier)
        let imported = try XCTUnwrap(ArtworkDataNormalizer.normalizedJPEGData(
            from: jpeg, maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
        ))
        let stored = try XCTUnwrap(ArtworkDataNormalizer.normalizedJPEGData(from: imported))
        XCTAssertEqual(stored, jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(stored as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 4096)
        XCTAssertEqual(image.height, 1024)
    }

    func testOrientedJPEGKeepsEncodedPixelsAndOrientation() throws {
        let image = try stripedArtwork(width: 320, height: 160)
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = encoded as Data
        XCTAssertEqual(ArtworkDataNormalizer.normalizedJPEGData(from: original, maxPixelSize: 80), original)
    }

    private func bitmapContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
    }

    private func rgbaBytes(from image: CGImage) throws -> [UInt8] {
        let context = try bitmapContext(width: image.width, height: image.height)
        context.draw(image, in: CGRect(
            x: 0, y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        ))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: context.bytesPerRow * image.height))
    }

    private func stripedArtwork(width: Int, height: Int) throws -> CGImage {
        let context = try bitmapContext(width: width, height: height)
        for x in 0..<width {
            context.setFillColor(CGColor(gray: x.isMultiple(of: 2) ? 1 : 0, alpha: 1))
            context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(height)))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func encodedArtwork(_ image: CGImage, type: String) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testClearingDuringRenderFinishesLiveRequestWithoutReusingItsGeneration() async throws {
        let store = CoverGradientBlurRenderStore()
        let gate = CoverGradientBlurRenderGate()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let staleImage = CoverGradientBlurRenderedImageBox(image: image, readabilityMap: nil)
        let currentImage = CoverGradientBlurRenderedImageBox(image: image, readabilityMap: nil)

        let staleRequest = Task {
            await store.image(for: "cover") {
                await gate.waitUntilReleased()
                return staleImage
            }
        }
        await gate.waitUntilStarted()

        await store.clearMemory()
        let currentRequest = Task {
            await store.image(for: "cover") {
                currentImage
            }
        }
        await gate.release()

        let staleResult = await staleRequest.value
        let currentResult = await currentRequest.value
        let cachedResult = await store.image(for: "cover") { nil }

        XCTAssertTrue(staleResult === staleImage)
        XCTAssertTrue(currentResult === currentImage)
        XCTAssertTrue(cachedResult === currentImage)
    }

    func testCancellingOneConsumerKeepsSharedRenderAlive() async throws {
        let store = CoverGradientBlurRenderStore()
        let gate = CoverGradientBlurRenderGate()
        let image = try renderedImageBox()
        let duplicate = try renderedImageBox()
        let first = Task {
            await store.image(for: "shared") {
                await gate.waitUntilReleased()
                return image
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            await store.image(for: "shared") { duplicate }
        }
        defer {
            first.cancel()
            second.cancel()
            Task { await gate.release() }
        }
        try await waitForConsumers(2, in: store)

        first.cancel()
        try await waitForConsumers(1, in: store)
        let cancelledResult = await first.value
        XCTAssertNil(cancelledResult)
        await gate.release()
        let remainingResult = await second.value
        XCTAssertTrue(remainingResult === image)
    }

    func testCancelledRunningRenderFinishesBeforeSameKeyReplacementStarts() async throws {
        let store = CoverGradientBlurRenderStore()
        let gate = CoverGradientBlurRenderGate()
        let starts = CoverGradientBlurRenderCounter()
        let oldImage = try renderedImageBox()
        let newImage = try renderedImageBox()
        let retiring = Task {
            await store.image(for: "cover") {
                // Model a Core Image call that cannot stop until it returns.
                await gate.waitUntilReleased()
                return oldImage
            }
        }
        defer {
            retiring.cancel()
            Task { await gate.release() }
        }
        await gate.waitUntilStarted()
        retiring.cancel()
        try await waitForConsumers(0, in: store)
        let retiredResult = await retiring.value
        XCTAssertNil(retiredResult)

        let replacement = Task {
            await store.image(for: "cover") {
                await starts.record()
                return newImage
            }
        }
        defer {
            replacement.cancel()
        }
        try await waitForConsumers(1, in: store)
        let earlyStarts = await starts.count
        XCTAssertEqual(earlyStarts, 0)

        await gate.release()
        let result = await replacement.value
        let cached = await store.image(for: "cover") { nil }
        let completedStarts = await starts.count
        XCTAssertTrue(result === newImage)
        XCTAssertTrue(cached === newImage)
        XCTAssertEqual(completedStarts, 1)
    }

    func testCancellingQueuedRenderSkipsItsProducer() async throws {
        let store = CoverGradientBlurRenderStore()
        let gate = CoverGradientBlurRenderGate()
        let obsoleteStarts = CoverGradientBlurRenderCounter()
        let image = try renderedImageBox()
        let running = Task {
            await store.image(for: "running") {
                await gate.waitUntilReleased()
                return image
            }
        }
        await gate.waitUntilStarted()
        let queued = Task {
            await store.image(for: "obsolete") {
                await obsoleteStarts.record()
                return image
            }
        }
        defer {
            running.cancel()
            queued.cancel()
            Task { await gate.release() }
        }
        try await waitForConsumers(2, in: store)
        queued.cancel()
        try await waitForConsumers(1, in: store)
        let cancelledResult = await queued.value
        XCTAssertNil(cancelledResult)

        await gate.release()
        let runningResult = await running.value
        // Drain a later request before checking that obsolete work never ran.
        let barrier = await store.image(for: "barrier") { image }
        let startCount = await obsoleteStarts.count
        XCTAssertTrue(runningResult === image)
        XCTAssertTrue(barrier === image)
        XCTAssertEqual(startCount, 0)
    }

    private func renderedImageBox() throws -> CoverGradientBlurRenderedImageBox {
        CoverGradientBlurRenderedImageBox(
            image: try stripedArtwork(width: 2, height: 2),
            readabilityMap: nil
        )
    }

    private func waitForConsumers(_ expected: Int, in store: CoverGradientBlurRenderStore) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while true {
            let count = await store.waitingConsumerCountForTesting
            if count == expected { return }
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(expected) render consumers; found \(count)")
                throw RenderWaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private enum RenderWaitError: Error {
        case timedOut
    }
}

private actor CoverGradientBlurRenderCounter {
    private(set) var count = 0

    func record() { count += 1 }
}

private actor CoverGradientBlurRenderGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
