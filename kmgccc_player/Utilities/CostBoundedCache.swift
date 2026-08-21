//
//  CostBoundedCache.swift
//  myPlayer2
//
//  Small deterministic LRU used by strongly-held runtime caches.
//

import Foundation

nonisolated struct CostBoundedCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let cost: Int
    }

    private let countLimit: Int
    private let totalCostLimit: Int
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []

    private(set) var totalCost = 0

    init(countLimit: Int, totalCostLimit: Int) {
        self.countLimit = max(1, countLimit)
        self.totalCostLimit = max(1, totalCostLimit)
    }

    var count: Int {
        entries.count
    }

    mutating func value(forKey key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    mutating func insert(_ value: Value, forKey key: Key, cost: Int) {
        if let previous = entries.removeValue(forKey: key) {
            totalCost -= previous.cost
            recency.removeAll { $0 == key }
        }

        let resolvedCost = max(1, cost)
        entries[key] = Entry(value: value, cost: resolvedCost)
        recency.append(key)
        totalCost += resolvedCost
        evictIfNeeded()
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let removed = entries.removeValue(forKey: key) else { return nil }
        totalCost -= removed.cost
        recency.removeAll { $0 == key }
        return removed.value
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        recency.removeAll(keepingCapacity: keepingCapacity)
        totalCost = 0
    }

    private mutating func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private mutating func evictIfNeeded() {
        while entries.count > countLimit || totalCost > totalCostLimit {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalCost -= removed.cost
            }
        }
    }
}
