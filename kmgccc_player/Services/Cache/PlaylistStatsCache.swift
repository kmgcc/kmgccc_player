//
//  PlaylistStatsCache.swift
//  myPlayer2
//
//  Header aggregate stats cache to avoid O(n) recalculation.
//

import Foundation

/// Cache for playlist/artist/album stats to avoid repeated O(n) calculations.
actor PlaylistStatsCache {
    static let shared = PlaylistStatsCache()

    private struct CacheKey: Hashable {
        let selectionIdentity: String
        let sourceFingerprint: String
    }

    private struct StatsEntry {
        let trackCount: Int
        let totalDuration: Double
        let albumCount: Int?
        let timestamp: Date
    }

    private var cache: [CacheKey: StatsEntry] = [:]
    private let maxEntries = 20
    private var accessOrder: [CacheKey] = []

    private init() {}

    func stats(
        selectionIdentity: String,
        sourceFingerprint: String
    ) -> (trackCount: Int, totalDuration: Double, albumCount: Int?)? {
        let key = CacheKey(selectionIdentity: selectionIdentity, sourceFingerprint: sourceFingerprint)
        guard let entry = cache[key] else { return nil }

        // Update access order for LRU
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)

        return (entry.trackCount, entry.totalDuration, entry.albumCount)
    }

    func setStats(
        selectionIdentity: String,
        sourceFingerprint: String,
        trackCount: Int,
        totalDuration: Double,
        albumCount: Int?
    ) {
        let key = CacheKey(selectionIdentity: selectionIdentity, sourceFingerprint: sourceFingerprint)

        // Evict oldest if at capacity
        if cache.count >= maxEntries, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        cache[key] = StatsEntry(
            trackCount: trackCount,
            totalDuration: totalDuration,
            albumCount: albumCount,
            timestamp: Date()
        )
        accessOrder.append(key)
    }

    func invalidate(selectionIdentity: String) {
        let keysToRemove = cache.keys.filter { $0.selectionIdentity == selectionIdentity }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
    }

    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
    }
}
