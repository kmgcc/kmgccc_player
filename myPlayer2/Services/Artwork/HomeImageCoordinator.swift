//
//  HomeImageCoordinator.swift
//  myPlayer2
//
//  Coordinates all Home-page image loads through a single priority queue
//  with a concurrency cap, deduplication, and proper cancellation handling.
//
//  Callers route through this coordinator instead of hitting ArtworkLoader
//  directly. This bounds the peak concurrent image decodes and prevents
//  mount-time bursts from thrashing the executor.
//

import AppKit

@MainActor
final class HomeImageCoordinator {
    static let shared = HomeImageCoordinator()

    enum Priority: Int, Comparable {
        case background = 0
        case normal = 1
        case high = 2
        case hero = 3

        static func < (a: Priority, b: Priority) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    struct Request: Hashable {
        /// Stable cache key (checksum + targetSize), NOT raw artwork data.
        let cacheKey: String
        let targetPixelSize: CGSize
        let artworkData: Data?
        let priority: Priority

        /// Hashable on cacheKey + targetPixelSize only — dedup key.
        func hash(into hasher: inout Hasher) {
            hasher.combine(cacheKey)
            hasher.combine(Int(targetPixelSize.width))
            hasher.combine(Int(targetPixelSize.height))
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.cacheKey == rhs.cacheKey
                && lhs.targetPixelSize.width == rhs.targetPixelSize.width
                && lhs.targetPixelSize.height == rhs.targetPixelSize.height
        }
    }

    /// Maximum concurrent image tasks. PlaylistArtworkPipeline already gates
    /// 6 internal decodes; this coordinator rate-limits upstream task spawn.
    private let cap = 6
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var inflightCount = 0
    private var queued: [QueuedRequest] = []

    private struct QueuedRequest {
        let request: Request
        let continuation: CheckedContinuation<NSImage?, Never>
    }

    func image(for request: Request) async -> NSImage? {
        // 1. Cache hit fast-path.
        if let cached = await ArtworkLoader.cachedImage(for: request.cacheKey) {
            return cached
        }

        // 2. Coalesce: if same key is inflight, await its task.
        if let existing = inflight[request.cacheKey] {
            return await existing.value
        }

        // 3. Bound: if at cap, suspend until a slot frees.
        if inflightCount >= cap {
            return await withCheckedContinuation { continuation in
                queued.append(QueuedRequest(request: request, continuation: continuation))
                queued.sort { $0.request.priority > $1.request.priority }
            }
        }

        // 4. Run the request.
        return await runRequest(request)
    }

    private func runRequest(_ request: Request) async -> NSImage? {
        inflightCount += 1
        let task = Task<NSImage?, Never> { [weak self] in
            guard !Task.isCancelled else {
                await self?.completeRequest(request.cacheKey, image: nil)
                return nil
            }
            let image = await ArtworkLoader.loadImage(
                artworkData: request.artworkData,
                cacheKey: request.cacheKey,
                targetPixelSize: request.targetPixelSize
            )
            await self?.completeRequest(request.cacheKey, image: image)
            return image
        }
        inflight[request.cacheKey] = task
        return await task.value
    }

    private func completeRequest(_ cacheKey: String, image: NSImage?) {
        inflight[cacheKey] = nil
        inflightCount -= 1
        drainQueue()
    }

    /// Start the next queued request (highest priority first) and resume
    /// its continuation with the actual result.
    private func drainQueue() {
        guard !queued.isEmpty, inflightCount < cap else { return }
        let next = queued.removeFirst()

        // Check cache again before starting — the image may have been
        // loaded by a coalesced request while this was queued.
        Task { [weak self] in
            if let cached = await ArtworkLoader.cachedImage(for: next.request.cacheKey) {
                next.continuation.resume(returning: cached)
                // Drain again since we freed a potential slot conceptually
                await self?.drainQueueAsync()
                return
            }

            // Start the real work and feed the result to the waiter.
            let image = await self?.runRequestAndResume(next)
            next.continuation.resume(returning: image)
            // runRequestAndResume freed a slot — drain the next queued item.
            self?.drainQueue()
        }
    }

    /// Run a request and return its result (without going through the
    /// normal inflight path that would call drainQueue again).
    private func runRequestAndResume(_ queued: QueuedRequest) async -> NSImage? {
        inflightCount += 1
        let cacheKey = queued.request.cacheKey
        let task = Task<NSImage?, Never> {
            guard !Task.isCancelled else { return nil }
            return await ArtworkLoader.loadImage(
                artworkData: queued.request.artworkData,
                cacheKey: queued.request.cacheKey,
                targetPixelSize: queued.request.targetPixelSize
            )
        }
        inflight[cacheKey] = task
        let image = await task.value
        inflight[cacheKey] = nil
        inflightCount -= 1
        return image
    }

    private func drainQueueAsync() async {
        drainQueue()
    }
}
