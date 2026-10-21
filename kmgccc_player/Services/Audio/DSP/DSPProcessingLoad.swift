import Foundation
import Observation

/// Elapsed processing time divided by source audio duration. This includes
/// scheduling interruptions, and is independent of the app's CPU percentage.
nonisolated struct DSPProcessingLoad: Equatable, Sendable {
    let averageRatio: Double
    let sampledPeakRatio: Double

    /// Fixed budget references, never normalized against other nodes in a chain.
    func colorPosition(isChain: Bool) -> Double {
        let stops = isChain ? [0.0, 0.25, 0.5, 0.8] : [0.0, 0.05, 0.15, 0.3]
        let ratio = max(0, averageRatio)
        for index in 1..<stops.count where ratio < stops[index] {
            return (Double(index - 1) + (ratio - stops[index - 1]) / (stops[index] - stops[index - 1])) / 3
        }
        return 1
    }
}

nonisolated struct DSPProcessingLoadSnapshot: Sendable {
    let requestID: UUID?
    let revision: String
    let format: DSPAudioFormat
    let nodes: [UUID: DSPProcessingLoad]
    let chain: DSPProcessingLoad
    let sampleCount: Int
}

nonisolated struct DSPProcessingLoadUpdate: Sendable {
    let monitoringGeneration: UUID
    let snapshot: DSPProcessingLoadSnapshot?
}

/// Confined to the producer queue. Allocate once per processor/monitoring session;
/// sampled blocks only mutate these fixed arrays, with no locks or callbacks.
nonisolated final class DSPProcessingLoadAccumulator {
    static let sampleIntervalSeconds = 0.125
    static let publishIntervalNanoseconds: UInt64 = 500_000_000

    private let nodeIDs: [UUID]
    private var blockNodeNanoseconds: [UInt64]
    private var nodeNanoseconds: [UInt64]
    private var nodePeaks: [Double]
    private var smoothedNodeRatios: [Double]
    private var smoothedChainRatio = 0.0
    private var framesUntilSample = 0
    private var blockSeconds = 0.0
    private var sampledSeconds = 0.0
    private var chainNanoseconds: UInt64 = 0
    private var chainPeak = 0.0
    private var sampleCount = 0
    private var latestSampleTime: UInt64 = 0
    private var lastPublishTime: UInt64 = 0
    private var firstSampleTime: UInt64?
    private var hasPublished = false

    init(nodeIDs: [UUID]) {
        self.nodeIDs = nodeIDs
        blockNodeNanoseconds = Array(repeating: 0, count: nodeIDs.count)
        nodeNanoseconds = Array(repeating: 0, count: nodeIDs.count)
        nodePeaks = Array(repeating: 0, count: nodeIDs.count)
        smoothedNodeRatios = Array(repeating: 0, count: nodeIDs.count)
    }

    func beginBlock(frames: Int, sampleRate: Double) -> Bool {
        guard frames > 0, sampleRate.isFinite, sampleRate > 0 else { return false }
        framesUntilSample -= frames
        guard framesUntilSample <= 0 else { return false }
        framesUntilSample = max(frames, Int((sampleRate * Self.sampleIntervalSeconds).rounded()))
        blockSeconds = Double(frames) / sampleRate
        for index in blockNodeNanoseconds.indices { blockNodeNanoseconds[index] = 0 }
        return true
    }

    /// Main processing and required lookahead both accumulate into the same
    /// block; the denominator remains the source block's duration, counted once.
    func recordNode(at index: Int, nanoseconds: UInt64) {
        blockNodeNanoseconds[index] += nanoseconds
    }

    func finishBlock(nanoseconds: UInt64, at uptimeNanoseconds: UInt64, succeeded: Bool) {
        guard succeeded else { return }
        let denominator = blockSeconds * 1_000_000_000
        for index in nodeIDs.indices {
            nodeNanoseconds[index] += blockNodeNanoseconds[index]
            nodePeaks[index] = max(nodePeaks[index], Double(blockNodeNanoseconds[index]) / denominator)
        }
        chainNanoseconds += nanoseconds
        chainPeak = max(chainPeak, Double(nanoseconds) / denominator)
        sampledSeconds += blockSeconds
        sampleCount += 1
        latestSampleTime = uptimeNanoseconds
        if firstSampleTime == nil { firstSampleTime = uptimeNanoseconds }
    }

    /// Called after processing, but reads no clock and allocates nothing until
    /// fresh sampled data is ready for the twice-per-second publication.
    func takeSnapshotIfDue(
        requestID: UUID?, revision: String, format: DSPAudioFormat,
        idleNodeIDs: @autoclosure () -> [UUID] = [],
        excludedNodeIDs: @autoclosure () -> Set<UUID> = []
    ) -> DSPProcessingLoadSnapshot? {
        guard sampleCount > 0,
              let firstSampleTime,
              latestSampleTime >= (hasPublished ? lastPublishTime : firstSampleTime),
              latestSampleTime - (hasPublished ? lastPublishTime : firstSampleTime) >= Self.publishIntervalNanoseconds else { return nil }
        let denominator = sampledSeconds * 1_000_000_000
        let elapsed = hasPublished ? Double(latestSampleTime - lastPublishTime) / 1_000_000_000 : 0
        let blend = hasPublished ? 1 - exp(-elapsed) : 1
        let excluded = excludedNodeIDs()
        var loads: [UUID: DSPProcessingLoad] = [:]
        loads.reserveCapacity(nodeIDs.count)
        for index in nodeIDs.indices {
            let ratio = Double(nodeNanoseconds[index]) / denominator
            smoothedNodeRatios[index] += (ratio - smoothedNodeRatios[index]) * blend
            if !excluded.contains(nodeIDs[index]) {
                loads[nodeIDs[index]] = DSPProcessingLoad(averageRatio: smoothedNodeRatios[index], sampledPeakRatio: nodePeaks[index])
            }
            nodeNanoseconds[index] = 0
            nodePeaks[index] = 0
        }
        // Valid zero-wet/identity effects are intentionally skipped by the
        // audio processor. Their actual node cost is zero, not unavailable.
        for id in idleNodeIDs() where !excluded.contains(id) {
            loads[id] = DSPProcessingLoad(averageRatio: 0, sampledPeakRatio: 0)
        }
        smoothedChainRatio += (Double(chainNanoseconds) / denominator - smoothedChainRatio) * blend
        let snapshot = DSPProcessingLoadSnapshot(requestID: requestID, revision: revision, format: format,
            nodes: loads, chain: DSPProcessingLoad(averageRatio: smoothedChainRatio, sampledPeakRatio: chainPeak), sampleCount: sampleCount)
        sampleCount = 0
        sampledSeconds = 0
        chainNanoseconds = 0
        chainPeak = 0
        lastPublishTime = latestSampleTime
        hasPublished = true
        return snapshot
    }
}

/// Observed only by load badges and card backgrounds. Publishing a measurement
/// must not invalidate the settings page, EQ plots or node drag geometry.
@Observable
@MainActor
final class DSPProcessingLoadPresentation {
    private(set) var snapshot: DSPProcessingLoadSnapshot?
    /// Read by automation to wait for a fresh measurement; views never observe it.
    @ObservationIgnored private(set) var publishedCount = 0
    @ObservationIgnored private(set) var publishedAt: Date?

    /// An interrupted measurement leaves the last result on screen. Merge by
    /// node ID so a temporarily disabled node recovers its color immediately.
    func update(_ snapshot: DSPProcessingLoadSnapshot?, retainingNodeIDs: Set<UUID>? = nil) {
        guard let snapshot else { return }
        publishedCount += 1
        publishedAt = Date()
        var loads = self.snapshot?.nodes ?? [:]
        if let retainingNodeIDs {
            loads = loads.filter { retainingNodeIDs.contains($0.key) }
        }
        loads.merge(snapshot.nodes) { _, fresh in fresh }
        self.snapshot = DSPProcessingLoadSnapshot(requestID: snapshot.requestID, revision: snapshot.revision,
            format: snapshot.format, nodes: loads, chain: snapshot.chain, sampleCount: snapshot.sampleCount)
    }

    /// Playback owner/source boundaries explicitly retire the previous result.
    func clear() {
        guard snapshot != nil else { return }
        snapshot = nil
    }
}
