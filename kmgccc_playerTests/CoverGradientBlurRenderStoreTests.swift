import CoreGraphics
import XCTest
@testable import kmgccc_player

final class CoverGradientBlurRenderStoreTests: XCTestCase {
    func testClearingDuringRenderDoesNotReuseStaleInFlightResult() async throws {
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

        XCTAssertNil(staleResult)
        XCTAssertTrue(currentResult === currentImage)
        XCTAssertTrue(cachedResult === currentImage)
    }
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
