import CoreGraphics
import XCTest
@testable import kmgccc_player

@MainActor
final class MotionArtworkFirstFrameCacheTests: XCTestCase {
    func testPreparedFramesUseResourceRangeAndEvictLeastRecentlyUsedWithoutResizing() async throws {
        let image = try makeFrame()
        let frame = MotionArtworkFirstFrame(image: image)
        let cache = MotionArtworkFirstFrameCache(maxCount: 2, maxBytes: image.bytesPerRow * image.height * 2) { _ in
            frame
        }
        let first = resource("album")
        var second = first
        second.startTime = 5
        let third = resource("other")
        let context = BackgroundWorkContext()

        await cache.prepare(first, context: context)
        await cache.prepare(second, context: context)
        let prepared = try XCTUnwrap(cache.cachedFrame(for: first))
        XCTAssertEqual(prepared.width, image.width)
        XCTAssertEqual(prepared.height, image.height)
        await cache.prepare(third, context: context)

        XCTAssertNotNil(cache.cachedFrame(for: first))
        XCTAssertNil(cache.cachedFrame(for: second))
        XCTAssertNotNil(cache.cachedFrame(for: third))
    }

    func testOversizedFrameIsNotRetainedAndRemoteResourcesNeverReachLoader() async throws {
        let image = try makeFrame()
        let frame = MotionArtworkFirstFrame(image: image)
        let calls = LoadCount()
        let cache = MotionArtworkFirstFrameCache(maxBytes: image.bytesPerRow * image.height - 1) { _ in
            await calls.record()
            return frame
        }
        let local = resource("large")
        await cache.prepare(local, context: BackgroundWorkContext())
        XCTAssertNil(cache.cachedFrame(for: local))

        let remote = MotionArtworkResource(url: try XCTUnwrap(URL(string: "https://example.com/video.mp4")),
                                          startTime: 0, duration: 20)
        await cache.prepare(remote, context: BackgroundWorkContext())
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testSharedAlbumPreparationDoesNotStartASecondDecoder() async throws {
        let latch = SuspendedLoad(frame: MotionArtworkFirstFrame(image: try makeFrame()))
        let cache = MotionArtworkFirstFrameCache { resource in await latch.load(resource) }
        let target = resource("shared-album")
        let first = Task { await cache.prepare(target, context: BackgroundWorkContext()) }
        await latch.waitUntilStarted()
        await cache.prepare(target, context: BackgroundWorkContext())
        let count = await latch.count
        XCTAssertEqual(count, 1)
        await latch.finish()
        await first.value
        await cache.prepare(target, context: BackgroundWorkContext())
        let finalCount = await latch.count
        XCTAssertEqual(finalCount, 1)
        XCTAssertNotNil(cache.cachedFrame(for: target))
    }

    func testClearMemoryRejectsAFirstFrameThatFinishesAfterClear() async throws {
        let latch = SuspendedLoad(frame: MotionArtworkFirstFrame(image: try makeFrame()))
        let cache = MotionArtworkFirstFrameCache { resource in await latch.load(resource) }
        let target = resource("late")
        let preparation = Task { await cache.prepare(target, context: BackgroundWorkContext()) }
        await latch.waitUntilStarted()
        cache.clearMemory()
        // Model a decoder that cannot stop until its current operation ends.
        await latch.finish()
        await preparation.value
        XCTAssertNil(cache.cachedFrame(for: target))
    }

    func testQueueCancellationDiscardsTheDecodedFrame() async throws {
        let latch = SuspendedLoad(frame: MotionArtworkFirstFrame(image: try makeFrame()))
        let cache = MotionArtworkFirstFrameCache { resource in await latch.load(resource) }
        let target = resource("cancelled")
        let context = BackgroundWorkContext()
        let preparation = Task { await cache.prepare(target, context: context) }
        await latch.waitUntilStarted()
        context.cancel()
        await latch.finish()
        await preparation.value
        XCTAssertNil(cache.cachedFrame(for: target))
    }

    func testCancelledAlbumPreparationCannotRemoveItsReplacement() async throws {
        let image = try makeFrame()
        let oldLoad = SuspendedLoad(frame: MotionArtworkFirstFrame(image: image))
        let newLoad = SuspendedLoad(frame: MotionArtworkFirstFrame(image: image))
        let calls = LoadCount()
        let cache = MotionArtworkFirstFrameCache { resource in
            let count = await calls.record()
            return await (count == 1 ? oldLoad : newLoad).load(resource)
        }
        let target = resource("same-album-after-fast-switch")
        let oldContext = BackgroundWorkContext()
        let oldPreparation = Task { await cache.prepare(target, context: oldContext) }
        await oldLoad.waitUntilStarted()
        oldContext.cancel()

        let replacement = Task { await cache.prepare(target, context: BackgroundWorkContext()) }
        await newLoad.waitUntilStarted()
        await oldLoad.finish()
        await oldPreparation.value
        XCTAssertNil(cache.cachedFrame(for: target))
        await newLoad.finish()
        await replacement.value
        XCTAssertNotNil(cache.cachedFrame(for: target))
    }

    private func resource(_ name: String) -> MotionArtworkResource {
        MotionArtworkResource(url: URL(fileURLWithPath: "/motion-artwork-test/\(name).mp4"), startTime: 0, duration: 20)
    }

    private func makeFrame() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    private actor LoadCount {
        private(set) var value = 0
        @discardableResult
        func record() -> Int { value += 1; return value }
    }

    private actor SuspendedLoad {
        let frame: MotionArtworkFirstFrame
        private(set) var count = 0
        private var result: CheckedContinuation<MotionArtworkFirstFrame?, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        init(frame: MotionArtworkFirstFrame) { self.frame = frame }

        func load(_ resource: MotionArtworkResource) async -> MotionArtworkFirstFrame? {
            count += 1
            return await withCheckedContinuation { continuation in
                result = continuation
                startWaiters.forEach { $0.resume() }
                startWaiters.removeAll()
            }
        }

        func waitUntilStarted() async {
            if result != nil { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func finish() {
            result?.resume(returning: frame)
            result = nil
        }
    }
}
