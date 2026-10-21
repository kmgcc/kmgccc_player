import Foundation

/// Window-local drags carry identities, never audio URLs or copied media.
/// The session identity prevents a drop from writing into a different library.
nonisolated struct LibraryTrackDragPayload: Equatable, Sendable {
    let sessionID: UUID
    let sourceSelectionIdentity: String?
    let trackIDs: [UUID]

    init(sessionID: UUID, sourceSelectionIdentity: String? = nil, trackIDs: [UUID]) {
        self.sessionID = sessionID
        self.sourceSelectionIdentity = sourceSelectionIdentity
        var seen: Set<UUID> = []
        self.trackIDs = trackIDs.filter { seen.insert($0).inserted }
    }

    static func draggedIDs(startingAt id: UUID, selectedIDs: Set<UUID>, orderedIDs: [UUID]) -> [UUID] {
        selectedIDs.contains(id) ? orderedIDs.filter { selectedIDs.contains($0) } : [id]
    }
}

nonisolated enum LibraryTrackDropTarget: Equatable, Sendable {
    case playlist(UUID)
    case artist(String)
    case album(String)
    case playNow
}

nonisolated struct LibraryTrackDropOutcome {
    var changedCount = 0
    var unchangedCount = 0
    var failedCount = 0
}
