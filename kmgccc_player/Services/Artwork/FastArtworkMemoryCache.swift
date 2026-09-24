//
//  FastArtworkMemoryCache.swift
//  myPlayer2
//
//  High-speed, thread-safe in-memory artwork cache for instantaneous (Frame 0) UI rendering.
//  Bypasses actor hops during view initialization to eliminate placeholder flashing during scrolling.
//

import AppKit
import Foundation

final class FastArtworkMemoryCache: @unchecked Sendable {
    nonisolated(unsafe) static let shared = FastArtworkMemoryCache()

    private nonisolated(unsafe) let cache = NSCache<NSString, NSImage>()

    nonisolated private init() {
        // 512 thumbnails (each 40x40 @ 2x = 80x80px = ~25KB uncompressed)
        // takes ~12-16MB of RAM. Bounded to 24MB maximum.
        cache.countLimit = 512
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    nonisolated func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    nonisolated func store(_ image: NSImage, forKey key: String) {
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    nonisolated func removeAll() {
        cache.removeAllObjects()
    }
}
