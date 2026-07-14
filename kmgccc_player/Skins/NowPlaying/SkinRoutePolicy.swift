import Foundation

nonisolated enum SkinRoutePolicy {
    static func resolvedID(
        requestedID: String,
        availableIDs: [String],
        defaultID: String,
        fallbackID: String
    ) -> String {
        if availableIDs.contains(requestedID) {
            return requestedID
        }
        if availableIDs.contains(defaultID) {
            return defaultID
        }
        return availableIDs.first ?? fallbackID
    }

    static func sortRank(
        for id: String,
        prioritizedID: String,
        orderedIDs: [String]
    ) -> Int {
        id == prioritizedID ? -1 : (orderedIDs.firstIndex(of: id) ?? Int.max)
    }
}
