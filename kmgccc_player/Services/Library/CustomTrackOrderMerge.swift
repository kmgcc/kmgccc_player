//
//  CustomTrackOrderMerge.swift
//  myPlayer2
//
//  Placement of tracks that a custom order does not know about yet.
//

import Foundation

/// Places newly added tracks inside a custom order.
///
/// The persisted custom order stays the source of truth for the manual
/// arrangement. Tracks that appear after it was recorded join by their real
/// add time: ascending appends them to the end, descending puts the latest
/// additions on top and pushes the existing order down.
nonisolated enum CustomTrackOrderMerge {
    nonisolated static func merging(
        customOrder: [UUID],
        availableIDs: [UUID],
        addedAt: [UUID: Date],
        placesNewTracksOnTop: Bool
    ) -> [UUID] {
        let available = Set(availableIDs)
        var seen = Set<UUID>()
        var merged = customOrder.filter { available.contains($0) && seen.insert($0).inserted }
        let additions = availableIDs.filter { seen.insert($0).inserted }
        guard !additions.isEmpty else { return merged }

        let ordered: [UUID]
        if additions.count == 1 {
            ordered = additions
        } else {
            var position: [UUID: Int] = [:]
            for (index, trackID) in availableIDs.enumerated() where position[trackID] == nil {
                position[trackID] = index
            }
            ordered = additions.sorted { lhs, rhs in
                let lhsDate = addedAt[lhs] ?? .distantPast
                let rhsDate = addedAt[rhs] ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return (position[lhs] ?? 0) < (position[rhs] ?? 0)
            }
        }

        if placesNewTracksOnTop {
            merged.insert(contentsOf: ordered.reversed(), at: 0)
        } else {
            merged.append(contentsOf: ordered)
        }
        return merged
    }
}
