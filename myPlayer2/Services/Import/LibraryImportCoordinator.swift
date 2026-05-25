//
//  LibraryImportCoordinator.swift
//  myPlayer2
//
//  Tracks active library import writes so startup/maintenance cleanup never
//  races a track folder that is still being created.
//

import Foundation

actor LibraryImportCoordinator {
    static let shared = LibraryImportCoordinator()

    private var activeBatchCount = 0
    private var activeTrackIDs: Set<UUID> = []

    private init() {}

    func beginBatch(reason: String) {
        activeBatchCount += 1
        Log.info(
            "[LibraryImportCoordinator] beginBatch reason=\(reason) activeBatches=\(activeBatchCount)",
            category: .import
        )
    }

    func endBatch(reason: String) {
        activeBatchCount = max(0, activeBatchCount - 1)
        if activeBatchCount == 0 {
            activeTrackIDs.removeAll()
        }
        Log.info(
            "[LibraryImportCoordinator] endBatch reason=\(reason) activeBatches=\(activeBatchCount) activeTracks=\(activeTrackIDs.count)",
            category: .import
        )
    }

    func beginTrack(_ trackID: UUID) {
        activeTrackIDs.insert(trackID)
    }

    func endTrack(_ trackID: UUID) {
        activeTrackIDs.remove(trackID)
    }

    func snapshot() -> LibraryImportActivitySnapshot {
        LibraryImportActivitySnapshot(
            isImporting: activeBatchCount > 0,
            activeTrackIDs: activeTrackIDs
        )
    }
}

struct LibraryImportActivitySnapshot: Sendable {
    let isImporting: Bool
    let activeTrackIDs: Set<UUID>
}
