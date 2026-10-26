//
//  FastArtworkMemoryCache.swift
//  myPlayer2
//
//  High-speed, thread-safe in-memory artwork cache for instantaneous (Frame 0) UI rendering.
//  Bypasses actor hops during view initialization to eliminate placeholder flashing during scrolling.
//

import AppKit
import Foundation

extension Notification.Name {
    /// One row thumbnail finished decoding. A row that is still showing its
    /// placeholder picks it up instead of staying blank until it is recycled.
    static let artworkThumbnailDidBecomeAvailable = Notification.Name(
        "kmgccc.artwork.thumbnailDidBecomeAvailable"
    )
}

/// Key of the decoded thumbnail in `artworkThumbnailDidBecomeAvailable`.
enum ArtworkThumbnailNotificationKey {
    static let cacheKey = "cacheKey"
}

/// A row's accent colour, including the answer "this cover has none".
nonisolated final class RowArtworkAccent: NSObject, @unchecked Sendable {
    let color: NSColor?

    init(color: NSColor?) {
        self.color = color
    }
}

final class FastArtworkMemoryCache: @unchecked Sendable {
    nonisolated static let shared = FastArtworkMemoryCache()

    private nonisolated(unsafe) let cache = NSCache<NSString, NSImage>()
    private nonisolated(unsafe) let accentCache = NSCache<NSString, RowArtworkAccent>()
    // Disk warmups decode outside an actor. Keep their generation check and
    // insertion atomic with clearing both caches.
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var memoryGeneration: UInt64 = 0

    nonisolated private init() {
        // Row covers are about 31 KB each at 2x. The playlist warmup keeps a
        // window of about 500 rows around the viewport resident, so the limit
        // leaves room for that window plus the covers other lists still show.
        cache.countLimit = 640
        cache.totalCostLimit = 20 * 1024 * 1024
        accentCache.countLimit = 2_000
    }

    nonisolated func image(forKey key: String) -> NSImage? {
        lock.withLock { cache.object(forKey: key as NSString) }
    }

    /// Row tint derived from the row cover, keyed like the cover itself.
    nonisolated func accent(forKey key: String) -> RowArtworkAccent? {
        lock.withLock { accentCache.object(forKey: key as NSString) }
    }

    nonisolated func currentGeneration() -> UInt64 {
        lock.withLock { memoryGeneration }
    }

    nonisolated func storeAccent(_ color: NSColor?, forKey key: String, generation: UInt64? = nil) {
        lock.withLock {
            if let generation {
                guard generation == memoryGeneration, !Task.isCancelled else { return }
            }
            accentCache.setObject(RowArtworkAccent(color: color), forKey: key as NSString)
        }
    }

    @discardableResult
    nonisolated func store(_ image: NSImage, forKey key: String, generation: UInt64? = nil) -> Bool {
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        let stored = lock.withLock {
            if let generation {
                guard generation == memoryGeneration, !Task.isCancelled else { return false }
            }
            cache.setObject(image, forKey: key as NSString, cost: cost)
            return true
        }
        guard stored else { return false }

        // Rows run on the main thread; deliver the arrival there so a row that
        // mounted before its cover was ready can adopt it.
        let cacheKey = key
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .artworkThumbnailDidBecomeAvailable,
                object: nil,
                userInfo: [ArtworkThumbnailNotificationKey.cacheKey: cacheKey]
            )
        }
        return true
    }

    nonisolated func removeAll() {
        lock.withLock {
            memoryGeneration &+= 1
            cache.removeAllObjects()
            accentCache.removeAllObjects()
        }
    }
}
