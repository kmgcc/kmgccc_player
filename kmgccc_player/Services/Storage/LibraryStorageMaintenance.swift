//
//  LibraryStorageMaintenance.swift
//  kmgccc_player
//
//  Recurring idle-time upkeep of one open library's storage.
//

import Foundation

/// Queues a maintenance pass when the library opens and again every few
/// hours. The scheduler admits each pass only in idle time, so a long session
/// keeps its caches within budget without a launch-time cost.
@MainActor
final class LibraryStorageMaintenance {
    static let interval: Duration = .seconds(6 * 60 * 60)

    private let storage: LibraryStorageLocations
    /// Session-owned upkeep that needs live services, such as pruning
    /// loudness records and folding the search index log.
    private let sessionWork: @MainActor @Sendable () async -> Void
    private var loop: Task<Void, Never>?

    init(
        storage: LibraryStorageLocations,
        sessionWork: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.storage = storage
        self.sessionWork = sessionWork
    }

    func start(scheduler: BackgroundWorkScheduler, owner: BackgroundWorkOwner) {
        guard loop == nil else { return }
        let storage = storage
        let sessionWork = sessionWork
        loop = Task { [weak scheduler] in
            while !Task.isCancelled {
                guard let scheduler else { return }
                let handle = scheduler.submit(
                    key: "cache-maintenance:\(storage.libraryRootURL.path)",
                    owner: owner,
                    domain: .cacheMaintenance,
                    priority: .idleBatch,
                    resources: [.disk]
                ) { context in
                    guard (try? await context.checkpoint()) != nil else { return .cancelled }
                    _ = await CacheManager.trimAllDiskCaches(storage: storage)
                    guard (try? await context.checkpoint()) != nil else { return .cancelled }
                    await sessionWork()
                    return .completed
                }
                _ = await handle.value()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}
