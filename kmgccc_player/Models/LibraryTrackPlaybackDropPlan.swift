import Foundation

nonisolated struct LibraryTrackPlaybackDropPlan {
    let initialQueue: [Track]
    let playNext: [Track]

    init(tracks: [Track], currentTrackID: UUID?, existingQueue: [Track]) {
        var seen: Set<UUID> = []
        let dragged = tracks.filter { $0.availability != .missing && seen.insert($0.id).inserted }
        guard let first = dragged.first else {
            initialQueue = []
            playNext = []
            return
        }
        let upcoming: ArraySlice<Track>
        if let currentTrackID,
           let index = existingQueue.firstIndex(where: { $0.id == currentTrackID }) {
            upcoming = existingQueue.suffix(from: index + 1)
        } else {
            upcoming = []
        }
        initialQueue = [first] + upcoming.filter {
            $0.availability != .missing && seen.insert($0.id).inserted
        }
        playNext = Array(dragged.dropFirst())
    }
}
