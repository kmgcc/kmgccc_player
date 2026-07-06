//
//  PlaybackScheduling.swift
//  myPlayer2
//
//  kmgccc_player - Gapless playback scheduling primitives.
//
//  Pure value types with no AVAudioEngine references. They model the queue of
//  audio segments scheduled onto a single `AVAudioPlayerNode` so that the node's
//  monotonic render clock can be mapped back to a per-track playback time, and so
//  the natural track boundary can be committed without stopping the node.
//
//  Ownership: this file owns no `AVAudioFile` and no security scope. Resource and
//  scope lifetime are managed by `AVAudioPlaybackService`.
//

import AVFoundation
import Foundation

/// One audio segment scheduled onto the shared `AVAudioPlayerNode`.
///
/// `startNodeSample` is measured on the player node's own render clock
/// (`playerTime(forNodeTime:).sampleTime`), which counts continuously from the
/// last `play()` after a stop and does NOT reset at file boundaries. Items
/// scheduled back-to-back (gapless) therefore occupy contiguous, non-overlapping
/// ranges `[startNodeSample, endNodeSample)`.
struct ScheduledItem {
    let trackID: UUID
    /// Completion token for this segment's scheduled completion callback.
    let token: UUID
    /// Node-clock sample at which this item's first frame is rendered.
    let startNodeSample: AVAudioFramePosition
    /// Frame offset inside the file where this segment starts (seek offset; 0 for
    /// a full file scheduled from the beginning).
    let startFrameInFile: AVAudioFramePosition
    /// Number of frames scheduled for this segment.
    let frameCount: AVAudioFrameCount
    let sampleRate: Double
    let duration: Double

    /// Node-clock sample one past this item's last rendered frame.
    var endNodeSample: AVAudioFramePosition {
        startNodeSample + AVAudioFramePosition(frameCount)
    }
}

/// Ordered queue of items scheduled onto the player node. Index 0 is the
/// committed-current item; index 1 (when present) is the prefetched next item
/// already scheduled for gapless playback. In practice it holds at most these two.
struct GaplessScheduleQueue {
    private(set) var items: [ScheduledItem] = []

    /// The committed-current item (the one the UI / progress reflects).
    var current: ScheduledItem? { items.first }
    /// The prefetched next item already scheduled on the node, if any.
    var pendingNext: ScheduledItem? { items.count > 1 ? items[1] : nil }
    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    /// Node sample at which a freshly appended item would begin (the end of the
    /// last scheduled item). `nil` when the queue is empty.
    var nextStartNodeSample: AVAudioFramePosition? {
        items.last?.endNodeSample
    }

    /// Replace the queue with a single current item. Used after any path that
    /// (re)starts the node from a stopped state, where the node clock restarts at
    /// 0 — callers pass `startNodeSample == 0`.
    mutating func setCurrent(_ item: ScheduledItem) {
        items = [item]
    }

    /// Append a gapless next item after the current one (the node is not stopped).
    mutating func append(_ item: ScheduledItem) {
        items.append(item)
    }

    /// Drop the committed-current item after the audible boundary has crossed,
    /// promoting `pendingNext` to current.
    mutating func advance() {
        if !items.isEmpty { items.removeFirst() }
    }

    mutating func reset() {
        items.removeAll()
    }

    /// Map the node-clock sample to the committed-current item's track time.
    /// Returns `nil` when there is no current item or its sample rate is invalid,
    /// in which case the caller falls back to its single-track formula.
    func currentTime(nodeSample: AVAudioFramePosition) -> Double? {
        guard let cur = items.first, cur.sampleRate > 0 else { return nil }
        let frameInFile = cur.startFrameInFile + (nodeSample - cur.startNodeSample)
        return Double(frameInFile) / cur.sampleRate
    }
}
