//
//  HomePerf.swift
//  myPlayer2
//
//  Debug-only performance instrumentation for the Home page.
//  Zero behavior change when overlay is off. All call sites compile
//  unconditionally in both Debug and Release; Release builds use no-op shims.
//

import OSLog
import Foundation

#if DEBUG
enum HomePerf {
    static let signposter = OSSignposter(
        subsystem: "kmg.myplayer2",
        category: "home_perf"
    )

    static let bodyCounters = HomePerfCounters()
    static let imageMetrics = HomePerfImageMetrics()

    /// Reset all counters. Call on Home mount.
    static func reset() {
        bodyCounters.reset()
        imageMetrics.reset()
    }
}

final class HomePerfCounters: @unchecked Sendable {
    private let queue = DispatchQueue(label: "home.perf.counters", qos: .utility)
    private var counts: [String: Int] = [:]

    func bump(_ key: String) {
        queue.sync { counts[key, default: 0] += 1 }
    }

    func snapshot() -> [String: Int] {
        queue.sync { counts }
    }

    func reset() {
        queue.sync { counts.removeAll(keepingCapacity: true) }
    }
}

final class HomePerfImageMetrics: @unchecked Sendable {
    struct Snapshot {
        var inflight: Int
        var totalStarted: Int
        var totalEnded: Int
        var totalCancelled: Int
    }

    private let queue = DispatchQueue(label: "home.perf.image-metrics", qos: .utility)
    private var started = 0
    private var ended = 0
    private var cancelled = 0

    func recordStart() {
        queue.sync { started += 1 }
    }

    func recordEnd() {
        queue.sync { ended += 1 }
    }

    func recordCancel() {
        queue.sync { cancelled += 1 }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                inflight: started - ended - cancelled,
                totalStarted: started,
                totalEnded: ended,
                totalCancelled: cancelled
            )
        }
    }

    func reset() {
        queue.sync {
            started = 0
            ended = 0
            cancelled = 0
        }
    }
}
#else
enum HomePerf {
    @inlinable static func bump(_ key: String) {}
    @inlinable static func reset() {}
    static let bodyCounters = HomePerfNoOpCounters()
    static let imageMetrics = HomePerfNoOpImageMetrics()
}

struct HomePerfNoOpCounters: Sendable {
    @inlinable func bump(_ key: String) {}
    @inlinable func snapshot() -> [String: Int] { [:] }
    @inlinable func reset() {}
}

struct HomePerfNoOpImageMetrics: Sendable {
    @inlinable func recordStart() {}
    @inlinable func recordEnd() {}
    @inlinable func recordCancel() {}
    @inlinable func snapshot() -> (inflight: Int, totalStarted: Int, totalEnded: Int, totalCancelled: Int) {
        (0, 0, 0, 0)
    }
    @inlinable func reset() {}
}
#endif
