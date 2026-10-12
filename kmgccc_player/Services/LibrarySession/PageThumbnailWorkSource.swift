import CoreGraphics
import Foundation

/// A cover a page shows at a known size.
nonisolated struct PageThumbnailCandidate: Sendable {
    let id: UUID
    let artworkData: Data?
    let artworkFileURL: URL?
    let pixelSide: Int

    nonisolated var identity: String { "\(id.uuidString)|\(pixelSide)" }
}

/// The sizes the Home rails last asked for. Idle preparation makes thumbnails
/// at exactly these sizes, so the page finds them under the keys it uses. Kept
/// across launches; until a rail has been shown there is nothing to prepare.
nonisolated enum PageThumbnailSizeHints {
    nonisolated static let albumRailKey = "pageThumbnailHint.albumRail"
    nonisolated static let artistRailKey = "pageThumbnailHint.artistRail"

    nonisolated static func record(albumRail: Int, artistRail: Int, defaults: UserDefaults = .standard) {
        if defaults.integer(forKey: albumRailKey) != albumRail { defaults.set(albumRail, forKey: albumRailKey) }
        if defaults.integer(forKey: artistRailKey) != artistRail { defaults.set(artistRail, forKey: artistRailKey) }
    }

    nonisolated static func albumRail(defaults: UserDefaults = .standard) -> Int? {
        let value = defaults.integer(forKey: albumRailKey)
        return value > 0 ? value : nil
    }

    nonisolated static func artistRail(defaults: UserDefaults = .standard) -> Int? {
        let value = defaults.integer(forKey: artistRailKey)
        return value > 0 ? value : nil
    }
}

/// Backlog of page thumbnails for the albums and artists the Home page shows,
/// in the order it shows them. The scheduler pulls a few at a time as idle
/// work; each is written to the derivative cache, which the page reads from.
/// Nothing is made once the derivative cache is close to its budget, so
/// preparation never pushes out thumbnails the listener has seen recently.
@MainActor
final class PageThumbnailWorkSource: BackgroundWorkSource {
    nonisolated let sourceID: String
    nonisolated var domain: BackgroundWorkDomain { .pageThumbnails }
    nonisolated var resources: BackgroundWorkResources { [.compute, .disk] }
    let owner: BackgroundWorkOwner

    private static let batchSize = 4
    private static let listRefreshSeconds: TimeInterval = 30
    private static let fullDiskPauseSeconds: TimeInterval = 600

    private let derivativeStore: ArtworkDerivativeCacheStore
    private let candidatesProvider: @MainActor () -> [PageThumbnailCandidate]
    private let isEnabled: @MainActor () -> Bool

    private var candidates: [PageThumbnailCandidate] = []
    private var listBuiltAt: TimeInterval = -.infinity
    private var processed: Set<String> = []
    private var pausedUntil: TimeInterval = 0

    init(
        libraryID: UUID,
        owner: BackgroundWorkOwner,
        derivativeStore: ArtworkDerivativeCacheStore,
        candidates: @escaping @MainActor () -> [PageThumbnailCandidate],
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        sourceID = "page-thumbnails:\(libraryID.uuidString)"
        self.owner = owner
        self.derivativeStore = derivativeStore
        candidatesProvider = candidates
        self.isEnabled = isEnabled
    }

    var progress: BackgroundWorkProgress {
        let remaining = candidates.filter { !processed.contains($0.identity) }.count
        return BackgroundWorkProgress(completed: processed.count, failed: 0, remaining: remaining)
    }

    func hasWork(priority: BackgroundWorkPriority, excluding: Set<String>) -> Bool {
        nextBatch(priority: priority, excluding: excluding) != nil
    }

    func nextUnit(priority: BackgroundWorkPriority, excluding: Set<String>) -> BackgroundWorkUnit? {
        guard let batch = nextBatch(priority: priority, excluding: excluding) else { return nil }
        let store = derivativeStore
        let items = batch.items
        return BackgroundWorkUnit(id: batch.unitID, priority: priority) { [weak self] context in
            guard await store.hasDiskRoom() else {
                await MainActor.run { self?.pauseForFullDisk() }
                return .completed
            }
            for item in items {
                guard (try? await context.checkpoint()) != nil else { return .cancelled }
                await Self.prepare(item, in: store)
            }
            await MainActor.run { self?.markProcessed(items) }
            return .completed
        }
    }

    private func pauseForFullDisk() {
        pausedUntil = ProcessInfo.processInfo.systemUptime + Self.fullDiskPauseSeconds
    }

    private func markProcessed(_ items: [PageThumbnailCandidate]) {
        processed.formUnion(items.map(\.identity))
    }

    private nonisolated static func prepare(
        _ item: PageThumbnailCandidate,
        in store: ArtworkDerivativeCacheStore
    ) async {
        let target = CGSize(width: item.pixelSide, height: item.pixelSide)
        if let data = item.artworkData, !data.isEmpty {
            let key = ArtworkLoader.cacheKey(
                trackID: item.id,
                checksum: ArtworkLoader.checksum(for: data),
                targetPixelSize: target
            )
            if await store.hasDiskDerivative(for: key) { return }
            _ = await store.image(for: key, artworkData: data, targetPixelSize: target)
        } else if let url = item.artworkFileURL {
            let key = ArtworkLoader.fileCacheKey(fileURL: url, targetPixelSize: target)
            if await store.hasDiskDerivative(for: key) { return }
            _ = await store.image(for: key, sourceURL: url, targetPixelSize: target)
        }
    }

    private func nextBatch(
        priority: BackgroundWorkPriority,
        excluding: Set<String>
    ) -> (items: [PageThumbnailCandidate], unitID: String)? {
        guard priority == .idleBatch, isEnabled() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= pausedUntil else { return nil }
        if now - listBuiltAt >= Self.listRefreshSeconds {
            candidates = candidatesProvider()
            listBuiltAt = now
        }
        let items = candidates
            .filter { !processed.contains($0.identity) }
            .prefix(Self.batchSize)
        guard let first = items.first else { return nil }
        let unitID = "thumbnails:\(first.identity)"
        return excluding.contains(unitID) ? nil : (Array(items), unitID)
    }
}
