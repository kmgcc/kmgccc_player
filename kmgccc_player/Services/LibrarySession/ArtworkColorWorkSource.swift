import Foundation

/// Backlog of per-song artwork accent colours, pulled by the background
/// scheduler as idle work. The remaining work is derived from the library: any
/// song not yet processed in this session is outstanding, so songs added while
/// the pass runs are picked up when the order is rebuilt. Colours themselves
/// are cached by `TrackArtworkCache`; a song whose colour is already cached
/// costs almost nothing here.
@MainActor
final class ArtworkColorWorkSource: BackgroundWorkSource {
    nonisolated let sourceID: String
    nonisolated var domain: BackgroundWorkDomain { .artworkColors }
    nonisolated var resources: BackgroundWorkResources { [.compute, .disk] }
    let owner: BackgroundWorkOwner

    private static let batchSize = 24
    private static let orderRefreshSeconds: TimeInterval = 60

    private let artworkCache: TrackArtworkCache
    private let trackIDsProvider: @MainActor () -> [UUID]
    private let revisionProvider: @MainActor () -> Int
    private let sourcesProvider: @MainActor ([UUID]) -> [TrackArtworkSource]
    private let isEnabled: @MainActor () -> Bool

    private var order: [UUID] = []
    private var cursor = 0
    private var orderRevision: Int?
    private var orderBuiltAt: TimeInterval = 0
    private var processed: Set<UUID> = []

    init(
        libraryID: UUID,
        owner: BackgroundWorkOwner,
        artworkCache: TrackArtworkCache,
        trackIDs: @escaping @MainActor () -> [UUID],
        revision: @escaping @MainActor () -> Int,
        sources: @escaping @MainActor ([UUID]) -> [TrackArtworkSource],
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        sourceID = "artwork-colors:\(libraryID.uuidString)"
        self.owner = owner
        self.artworkCache = artworkCache
        trackIDsProvider = trackIDs
        revisionProvider = revision
        sourcesProvider = sources
        self.isEnabled = isEnabled
    }

    var progress: BackgroundWorkProgress {
        let total = order.count
        let done = min(total, processed.count)
        return BackgroundWorkProgress(completed: done, failed: 0, remaining: max(0, total - done))
    }

    func hasWork(priority: BackgroundWorkPriority, excluding: Set<String>) -> Bool {
        nextBatch(priority: priority, excluding: excluding) != nil
    }

    func nextUnit(priority: BackgroundWorkPriority, excluding: Set<String>) -> BackgroundWorkUnit? {
        guard let batch = nextBatch(priority: priority, excluding: excluding) else { return nil }
        let artworkCache = artworkCache
        let ids = batch.ids
        return BackgroundWorkUnit(id: batch.unitID, priority: priority) { [weak self] context in
            // A batch is a handful of songs; the checkpoint between songs lets
            // a more urgent unit take over.
            for startIndex in stride(from: 0, to: ids.count, by: 4) {
                guard (try? await context.checkpoint()) != nil else { return .cancelled }
                let slice = Array(ids[startIndex..<min(startIndex + 4, ids.count)])
                let sources = await MainActor.run { () -> [TrackArtworkSource]? in
                    guard let self, self.isEnabled() else { return nil }
                    return self.sourcesProvider(slice)
                }
                guard let sources else { return .cancelled }
                for source in sources {
                    guard (try? await context.checkpoint()) != nil else { return .cancelled }
                    _ = await artworkCache.artworkAccentColor(
                        for: source,
                        purpose: "idle-artwork-color",
                        priority: context.taskPriority
                    )
                }
            }
            await MainActor.run { self?.markProcessed(ids) }
            return .completed
        }
    }

    private func markProcessed(_ ids: [UUID]) {
        processed.formUnion(ids)
    }

    private func nextBatch(
        priority: BackgroundWorkPriority,
        excluding: Set<String>
    ) -> (ids: [UUID], unitID: String)? {
        guard priority == .idleBatch, isEnabled() else { return nil }
        refreshOrderIfNeeded()
        while cursor < order.count, processed.contains(order[cursor]) { cursor += 1 }
        var ids: [UUID] = []
        var probe = cursor
        while probe < order.count, ids.count < Self.batchSize {
            let id = order[probe]
            if !processed.contains(id) { ids.append(id) }
            probe += 1
        }
        guard let first = ids.first else { return nil }
        let unitID = "colors:\(first.uuidString)"
        return excluding.contains(unitID) ? nil : (ids, unitID)
    }

    private func refreshOrderIfNeeded() {
        let revision = revisionProvider()
        let now = ProcessInfo.processInfo.systemUptime
        let exhausted = cursor >= order.count
        if let built = orderRevision {
            guard built != revision, exhausted || now - orderBuiltAt >= Self.orderRefreshSeconds else { return }
        }
        order = trackIDsProvider()
        cursor = 0
        orderRevision = revision
        orderBuiltAt = now
    }
}
