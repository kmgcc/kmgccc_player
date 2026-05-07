#!/usr/bin/env swift

/// Standalone test: verify duplicate-track-id dedup logic does not crash.
/// Run:  swift test_shuffle_dedup.swift
/// This tests the same algorithm used in ShuffleSession.start(from:tracks:).

import Foundation

// Minimal Track stand-in for the dedup algorithm.
struct TestTrack {
    let id: UUID
    let title: String
}

func buildCacheAndDedup(_ tracks: [TestTrack]) -> (cache: [UUID: TestTrack], deduped: [TestTrack], duplicateIDs: Set<UUID>) {
    var cache: [UUID: TestTrack] = [:]
    var duplicateIDs: Set<UUID> = []
    var dedupedTracks: [TestTrack] = []
    var seen: Set<UUID> = []

    for track in tracks {
        if cache[track.id] == nil {
            cache[track.id] = track
        } else {
            duplicateIDs.insert(track.id)
        }
        if seen.insert(track.id).inserted {
            dedupedTracks.append(track)
        }
    }

    return (cache, dedupedTracks, duplicateIDs)
}

// ── Test 1: No duplicates ──────────────────────────────────────────
do {
    let t1 = TestTrack(id: UUID(), title: "A")
    let t2 = TestTrack(id: UUID(), title: "B")
    let t3 = TestTrack(id: UUID(), title: "C")
    let result = buildCacheAndDedup([t1, t2, t3])
    assert(result.cache.count == 3, "cache should have 3 entries")
    assert(result.deduped.count == 3, "deduped should have 3 entries")
    assert(result.duplicateIDs.isEmpty, "should have no duplicates")
    print("✅ Test 1 passed: no duplicates")
}

// ── Test 2: Duplicates present ─────────────────────────────────────
do {
    let dupID = UUID()
    let t1 = TestTrack(id: dupID, title: "First")
    let t2 = TestTrack(id: UUID(), title: "B")
    let t3 = TestTrack(id: dupID, title: "Second (dup)")
    let result = buildCacheAndDedup([t1, t2, t3])
    assert(result.cache.count == 2, "cache should have 2 entries (one dup removed)")
    assert(result.deduped.count == 2, "deduped should have 2 entries")
    assert(result.duplicateIDs.count == 1, "should have 1 duplicate ID")
    assert(result.duplicateIDs.contains(dupID), "dupID should be flagged")
    // First occurrence must be kept.
    assert(result.cache[dupID]?.title == "First", "first occurrence should be preserved")
    assert(result.deduped[0].title == "First", "first occurrence should be first in deduped")
    print("✅ Test 2 passed: duplicates detected and first preserved")
}

// ── Test 3: Multiple duplicates of same ID ─────────────────────────
do {
    let dupID = UUID()
    let tracks = [
        TestTrack(id: dupID, title: "A1"),
        TestTrack(id: dupID, title: "A2"),
        TestTrack(id: dupID, title: "A3"),
        TestTrack(id: UUID(), title: "B"),
    ]
    let result = buildCacheAndDedup(tracks)
    assert(result.cache.count == 2)
    assert(result.deduped.count == 2)
    assert(result.duplicateIDs.count == 1)
    assert(result.cache[dupID]?.title == "A1")
    print("✅ Test 3 passed: multiple duplicates handled")
}

// ── Test 4: All same ID ─────────────────────────────────────────────
do {
    let dupID = UUID()
    let tracks = (0..<5).map { TestTrack(id: dupID, title: "dup-\($0)") }
    let result = buildCacheAndDedup(tracks)
    assert(result.cache.count == 1)
    assert(result.deduped.count == 1)
    assert(result.duplicateIDs.count == 1)
    assert(result.cache[dupID]?.title == "dup-0")
    print("✅ Test 4 passed: all-same-ID handled")
}

// ── Test 5: Empty array ─────────────────────────────────────────────
do {
    let result = buildCacheAndDedup([])
    assert(result.cache.isEmpty)
    assert(result.deduped.isEmpty)
    assert(result.duplicateIDs.isEmpty)
    print("✅ Test 5 passed: empty input")
}

// ── Test 6: Simulate Dictionary(uniqueKeysWithValues:) crash scenario
do {
    // This is the exact scenario that caused the crash:
    // duplicate IDs in the array fed to the old code.
    let crashID = UUID(uuidString: "F64A889B-FAB8-41A3-93B5-A01C3D9DDBDE")!
    let tracks = [
        TestTrack(id: crashID, title: "First"),
        TestTrack(id: UUID(), title: "Other"),
        TestTrack(id: crashID, title: "Duplicate"),
    ]
    let result = buildCacheAndDedup(tracks)
    assert(result.duplicateIDs.contains(crashID), "crashID should be detected as duplicate")
    assert(result.cache[crashID]?.title == "First", "first copy kept")
    assert(!result.duplicateIDs.isEmpty, "duplicates should be logged")
    print("✅ Test 6 passed: original crash scenario handled without crash")
}

print("\n🎉 All tests passed — duplicate Track.id no longer causes fatal crash.")
