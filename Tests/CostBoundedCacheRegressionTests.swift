//
//  CostBoundedCacheRegressionTests.swift
//  kmgccc_player/Tests
//
//  Run with:
//    swiftc -parse-as-library \
//      kmgccc_player/Utilities/CostBoundedCache.swift \
//      Tests/CostBoundedCacheRegressionTests.swift \
//      -o /tmp/cost_bounded_cache_regression && /tmp/cost_bounded_cache_regression
//

import Foundation

@main
struct CostBoundedCacheRegressionTests {
    static func main() {
        evictsLeastRecentlyUsedEntryByCost()
        replacementUpdatesCost()
        preservesCachedNilSemantics()
        print("CostBoundedCacheRegressionTests passed")
    }

    private static func evictsLeastRecentlyUsedEntryByCost() {
        var cache = CostBoundedCache<String, String>(countLimit: 4, totalCostLimit: 10)
        cache.insert("a", forKey: "a", cost: 4)
        cache.insert("b", forKey: "b", cost: 4)
        expect(cache.value(forKey: "a") == "a", "Expected read to promote a")
        cache.insert("c", forKey: "c", cost: 4)

        expect(cache.value(forKey: "b") == nil, "Expected least-recently-used b to be evicted")
        expect(cache.value(forKey: "a") == "a", "Expected promoted a to remain")
        expect(cache.value(forKey: "c") == "c", "Expected newest c to remain")
        expect(cache.totalCost == 8, "Expected total cost to track evictions")
    }

    private static func replacementUpdatesCost() {
        var cache = CostBoundedCache<String, String>(countLimit: 2, totalCostLimit: 10)
        cache.insert("large", forKey: "same", cost: 9)
        cache.insert("small", forKey: "same", cost: 2)

        expect(cache.count == 1, "Expected replacement not to grow entry count")
        expect(cache.totalCost == 2, "Expected replacement to subtract previous cost")
        expect(cache.value(forKey: "same") == "small", "Expected replacement value")
    }

    private static func preservesCachedNilSemantics() {
        var cache = CostBoundedCache<String, Data?>(countLimit: 2, totalCostLimit: 10)
        cache.insert(nil, forKey: "miss", cost: 1)

        let cached: Data?? = cache.value(forKey: "miss")
        expect(cached != nil, "Expected outer optional to distinguish a cached miss")
        expect(cached! == nil, "Expected cached value to remain nil")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
