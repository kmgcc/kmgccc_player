//
//  ShuffleQueueManager.swift
//  myPlayer2
//
//  Stateful shuffle queue that avoids "same few songs" repetition.
//

import Foundation

@MainActor
final class ShuffleQueueManager {
    private let recentLimit: Int

    private var sourceTrackIDs: [UUID] = []
    private var pendingQueue: [UUID] = []
    private(set) var recentHistory: [UUID] = []
    private(set) var previousStack: [UUID] = []

    init(recentLimit: Int = 15) {
        self.recentLimit = max(1, recentLimit)
    }

    func reset() {
        sourceTrackIDs.removeAll()
        pendingQueue.removeAll()
        recentHistory.removeAll()
        previousStack.removeAll()
    }

    /// Rebuild queue when source tracks changed
    /// (playlist switched / search changed / import/delete changed visible track set).
    func rebuild(
        with trackIDs: [UUID],
        currentTrackID: UUID?,
        resetHistory: Bool
    ) {
        sourceTrackIDs = trackIDs

        if resetHistory {
            recentHistory.removeAll()
            previousStack.removeAll()
        } else {
            let alive = Set(trackIDs)
            recentHistory.removeAll { !alive.contains($0) }
            previousStack.removeAll { !alive.contains($0) }
        }

        pendingQueue = makeRound(excludingCurrent: currentTrackID)
    }

    func nextTrackID(currentTrackID: UUID?) -> UUID? {
        guard !sourceTrackIDs.isEmpty else { return nil }

        if sourceTrackIDs.count == 1 {
            return sourceTrackIDs[0]
        }

        if let currentTrackID {
            appendRecent(currentTrackID)
            previousStack.append(currentTrackID)
        }

        if pendingQueue.isEmpty {
            pendingQueue = makeRound(excludingCurrent: currentTrackID)
        }

        guard !pendingQueue.isEmpty else {
            return sourceTrackIDs.first(where: { $0 != currentTrackID }) ?? sourceTrackIDs.first
        }

        return pendingQueue.removeFirst()
    }

    func previousTrackID() -> UUID? {
        previousStack.popLast()
    }

    private func makeRound(excludingCurrent currentTrackID: UUID?) -> [UUID] {
        guard !sourceTrackIDs.isEmpty else { return [] }

        let candidates = sourceTrackIDs.filter { $0 != currentTrackID }
        guard !candidates.isEmpty else { return [] }

        let recent = Set(recentHistory)
        var fresh = candidates.filter { !recent.contains($0) }
        var deferred = candidates.filter { recent.contains($0) }

        fresh.shuffle()
        deferred.shuffle()
        return fresh + deferred
    }

    private func appendRecent(_ id: UUID) {
        if let idx = recentHistory.lastIndex(of: id) {
            recentHistory.remove(at: idx)
        }
        recentHistory.append(id)
        if recentHistory.count > recentLimit {
            recentHistory.removeFirst(recentHistory.count - recentLimit)
        }
    }
}

