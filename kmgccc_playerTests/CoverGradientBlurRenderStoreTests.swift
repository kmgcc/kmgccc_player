import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import kmgccc_player

final class CoverGradientBlurRenderStoreTests: XCTestCase {
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
            let x = placement == .leading ? 40 : 200
            let first = Int(bytes[80 * context.bytesPerRow + x * 4])
            let second = Int(bytes[80 * context.bytesPerRow + (x + 1) * 4])
            XCTAssertGreaterThan(abs(first - second), 180, "\(placement)")
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

    func testStoredJPEGAvoidsRepeatedCompressionAndOversizeCoverIsBounded() throws {
        let artwork = try stripedArtwork(width: 320, height: 160)
        let jpeg = try encodedArtwork(artwork, type: UTType.jpeg.identifier)
        XCTAssertEqual(ArtworkDataNormalizer.normalizedJPEGData(from: jpeg), jpeg)
        let bounded = try XCTUnwrap(ArtworkDataNormalizer.normalizedJPEGData(from: jpeg, maxPixelSize: 160))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bounded as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 80)
    }

    func testNewStorageBudgetRetainsCoverAboveLegacy1200PixelLimit() throws {
        let jpeg = try encodedArtwork(try stripedArtwork(width: 2048, height: 1024), type: UTType.jpeg.identifier)
        let imported = try XCTUnwrap(ArtworkDataNormalizer.normalizedJPEGData(
            from: jpeg, maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
        ))
        let stored = try XCTUnwrap(ArtworkDataNormalizer.normalizedJPEGData(from: imported))
        XCTAssertEqual(stored, jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(stored as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2048)
        XCTAssertEqual(image.height, 1024)
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
