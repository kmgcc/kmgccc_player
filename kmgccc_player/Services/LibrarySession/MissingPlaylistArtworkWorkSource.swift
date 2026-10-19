import Foundation

/// Backlog of playlists that have songs but no saved cover. The scheduler pulls
/// them one at a time as idle work, so a playlist opens with its cover already
/// made. What is outstanding is derived from the library: a playlist counts
/// until it has a cover on disk or one attempt has ended.
@MainActor
final class MissingPlaylistArtworkWorkSource: BackgroundWorkSource {
    nonisolated let sourceID: String
    nonisolated var domain: BackgroundWorkDomain { .missingArtwork }
    nonisolated var resources: BackgroundWorkResources { [.compute, .disk] }
    let owner: BackgroundWorkOwner

    private let playlistsProvider: @MainActor () -> [Playlist]
    private let lacksCover: @MainActor (Playlist) -> Bool
    private let generate: @MainActor (UUID, TaskPriority) async -> Bool
    private let isEnabled: @MainActor () -> Bool

    /// Playlists known to have a cover, or whose attempt has ended.
    private var settled: Set<UUID> = []
    private var completedCount = 0
    private var failedCount = 0

    init(
        libraryID: UUID,
        owner: BackgroundWorkOwner,
        playlists: @escaping @MainActor () -> [Playlist],
        lacksCover: @escaping @MainActor (Playlist) -> Bool,
        generate: @escaping @MainActor (UUID, TaskPriority) async -> Bool,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        sourceID = "missing-playlist-artwork:\(libraryID.uuidString)"
        self.owner = owner
        playlistsProvider = playlists
        self.lacksCover = lacksCover
        self.generate = generate
        self.isEnabled = isEnabled
    }

    var progress: BackgroundWorkProgress {
        let outstanding = playlistsProvider().filter { !settled.contains($0.id) && lacksCover($0) }.count
        return BackgroundWorkProgress(completed: completedCount, failed: failedCount, remaining: outstanding)
    }

    func hasWork(priority: BackgroundWorkPriority, excluding: Set<String>) -> Bool {
        nextPlaylistID(priority: priority, excluding: excluding) != nil
    }

    func nextUnit(priority: BackgroundWorkPriority, excluding: Set<String>) -> BackgroundWorkUnit? {
        guard let id = nextPlaylistID(priority: priority, excluding: excluding) else { return nil }
        return BackgroundWorkUnit(id: Self.unitID(for: id), priority: priority) { [weak self] context in
            guard (try? await context.checkpoint()) != nil else { return .cancelled }
            guard let self else { return .cancelled }
            return await self.makeCover(for: id, priority: context.taskPriority)
        }
    }

    private func makeCover(for playlistID: UUID, priority: TaskPriority) async -> BackgroundWorkOutcome {
        guard isEnabled() else { return .cancelled }
        let made = await generate(playlistID, priority)
        if Task.isCancelled { return .cancelled }
        settled.insert(playlistID)
        if made {
            completedCount += 1
            return .completed
        }
        failedCount += 1
        return .failed("playlist cover")
    }

    private func nextPlaylistID(priority: BackgroundWorkPriority, excluding: Set<String>) -> UUID? {
        guard priority == .idleBatch, isEnabled() else { return nil }
        for playlist in playlistsProvider() where !settled.contains(playlist.id) {
            guard lacksCover(playlist) else {
                settled.insert(playlist.id)
                continue
            }
            if excluding.contains(Self.unitID(for: playlist.id)) { continue }
            return playlist.id
        }
        return nil
    }

    private static func unitID(for playlistID: UUID) -> String {
        "playlist-cover:\(playlistID.uuidString)"
    }
}
