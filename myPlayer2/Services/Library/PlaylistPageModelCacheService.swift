//
//  PlaylistPageModelCacheService.swift
//  myPlayer2
//
//  In-memory cache for playlist detail page models.
//

import Foundation

struct PlaylistPageModelCacheEntry: Sendable {
    let key: String
    let selectionIdentity: String
    let sourceFingerprint: String
    let searchText: String
    let sortKeyRawValue: String
    let sortOrderRawValue: String
    let displayedTrackIDs: [UUID]
    let filteredTrackIDs: [UUID]
    let sortedTrackIDs: [UUID]
    let parentSortedTrackIDs: [UUID]
    let sortedTrackIndexMap: [UUID: Int]
    let parentSortedTrackIndexMap: [UUID: Int]
    let snapshot: PlaylistViewSnapshot
    let cachedAt: Date
}

private final class PlaylistPageModelCacheBox: NSObject {
    let entry: PlaylistPageModelCacheEntry

    nonisolated init(_ entry: PlaylistPageModelCacheEntry) {
        self.entry = entry
    }
}

actor PlaylistPageModelCacheService {
    static let shared = PlaylistPageModelCacheService()

    private let cache = NSCache<NSString, PlaylistPageModelCacheBox>()
    private let ttl: TimeInterval = 240
    private var keysBySelection: [String: Set<String>] = [:]

    private init() {
        cache.countLimit = 14
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func cacheKey(
        selectionIdentity: String,
        sourceFingerprint: String,
        searchText: String,
        sortKeyRawValue: String,
        sortOrderRawValue: String
    ) -> String {
        [
            selectionIdentity,
            sourceFingerprint,
            normalizedSearch(searchText),
            sortKeyRawValue,
            sortOrderRawValue,
        ].joined(separator: "|")
    }

    func model(for key: String) -> PlaylistPageModelCacheEntry? {
        guard let box = cache.object(forKey: key as NSString) else { return nil }
        let age = Date().timeIntervalSince(box.entry.cachedAt)
        guard age <= ttl else {
            cache.removeObject(forKey: key as NSString)
            removeKeyIndex(key, selectionIdentity: box.entry.selectionIdentity)
            return nil
        }
        return box.entry
    }

    func store(_ entry: PlaylistPageModelCacheEntry) {
        let box = PlaylistPageModelCacheBox(entry)
        cache.setObject(box, forKey: entry.key as NSString, cost: estimatedCost(for: entry))
        keysBySelection[entry.selectionIdentity, default: []].insert(entry.key)
    }

    func invalidate(selectionIdentity: String) {
        guard let keys = keysBySelection.removeValue(forKey: selectionIdentity) else { return }
        for key in keys {
            cache.removeObject(forKey: key as NSString)
        }
    }

    func remove(key: String, selectionIdentity: String) {
        cache.removeObject(forKey: key as NSString)
        removeKeyIndex(key, selectionIdentity: selectionIdentity)
    }

    func removeAll() {
        cache.removeAllObjects()
        keysBySelection.removeAll()
    }

    private func normalizedSearch(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func estimatedCost(for entry: PlaylistPageModelCacheEntry) -> Int {
        let tracks = max(entry.snapshot.trackCount, entry.sortedTrackIDs.count)
        let mapCost = (entry.sortedTrackIndexMap.count + entry.parentSortedTrackIndexMap.count) * 16
        return tracks * 112 + mapCost
    }

    private func removeKeyIndex(_ key: String, selectionIdentity: String) {
        guard var existing = keysBySelection[selectionIdentity] else { return }
        existing.remove(key)
        if existing.isEmpty {
            keysBySelection.removeValue(forKey: selectionIdentity)
        } else {
            keysBySelection[selectionIdentity] = existing
        }
    }
}
