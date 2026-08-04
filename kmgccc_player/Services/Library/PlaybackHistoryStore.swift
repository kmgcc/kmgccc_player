//
//  PlaybackHistoryStore.swift
//  myPlayer2
//
//  Main-actor access to the durable playback history event store.
//

import Foundation
import Observation
import SwiftData

struct PlaybackHistoryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let trackID: UUID
    let playedAt: Date
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let playedSeconds: Double
}

@Observable
@MainActor
final class PlaybackHistoryStore {
    static let shared = PlaybackHistoryStore()

    /// A bounded event log keeps launch and day queries predictable even for
    /// libraries that have been played for years.
    static let maximumStoredRecords = 10_000

    @ObservationIgnored private var modelContainer: ModelContainer
    @ObservationIgnored private var modelContext: ModelContext
    @ObservationIgnored private var activeStoreURL: URL
    @ObservationIgnored private var dailyCountsCache: [Date: Int]?
    private(set) var revision: Int = 0

    init(modelContainer: ModelContainer? = nil) {
        let storeURL = PlaybackHistoryStorePaths.storeURL
        let container = modelContainer ?? Self.makeContainer(at: storeURL)
        self.modelContainer = container
        self.modelContext = ModelContext(container)
        self.activeStoreURL = storeURL
    }

    func record(
        track: Track,
        playedAt: Date,
        playedSeconds: Double
    ) {
        record(
            trackID: track.id,
            playedAt: playedAt,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            playedSeconds: playedSeconds
        )
    }

    func record(
        trackID: UUID,
        playedAt: Date,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        playedSeconds: Double
    ) {
        let record = PlaybackHistoryRecord(
            trackID: trackID,
            playedAt: playedAt,
            title: title,
            artist: artist,
            album: album,
            duration: max(0, duration),
            playedSeconds: max(0, playedSeconds)
        )
        modelContext.insert(record)

        do {
            try trimIfNeeded()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            Log.error("[PlaybackHistory] save failed: \(error)", category: .library)
            return
        }

        // A trim can remove records from the same day as the new event, so
        // invalidate rather than incrementing a potentially stale aggregate.
        dailyCountsCache = nil
        revision &+= 1
        NotificationCenter.default.post(name: .playbackHistoryDidChange, object: nil)
    }

    func fetchItems(limit: Int? = nil) -> [PlaybackHistoryItem] {
        fetchRecords(sortAscending: false, limit: limit).map(Self.makeItem)
    }

    /// Rebind the event store after the user switches the active music library.
    /// The history timeline belongs to the library root, so records from the
    /// previous library must not leak into the newly selected library.
    func reconfigureForCurrentLibrary() {
        let newStoreURL = PlaybackHistoryStorePaths.storeURL
        guard newStoreURL.standardizedFileURL != activeStoreURL.standardizedFileURL else { return }

        let container = Self.makeContainer(at: newStoreURL)
        modelContainer = container
        modelContext = ModelContext(container)
        activeStoreURL = newStoreURL
        dailyCountsCache = nil
        revision &+= 1
        NotificationCenter.default.post(name: .playbackHistoryDidChange, object: nil)
    }

    func fetchItems(on date: Date) -> [PlaybackHistoryItem] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return []
        }

        var descriptor = FetchDescriptor<PlaybackHistoryRecord>(
            predicate: #Predicate { record in
                record.playedAt >= start && record.playedAt < end
            },
            sortBy: [SortDescriptor(\PlaybackHistoryRecord.playedAt, order: .reverse)]
        )
        return fetchItems(using: &descriptor)
    }

    func fetchItems(from start: Date, to end: Date? = nil, limit: Int? = nil) -> [PlaybackHistoryItem] {
        var descriptor: FetchDescriptor<PlaybackHistoryRecord>
        if let end {
            descriptor = FetchDescriptor(
                predicate: #Predicate { record in
                    record.playedAt >= start && record.playedAt < end
                },
                sortBy: [SortDescriptor(\PlaybackHistoryRecord.playedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { record in
                    record.playedAt >= start
                },
                sortBy: [SortDescriptor(\PlaybackHistoryRecord.playedAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = limit
        return fetchItems(using: &descriptor)
    }

    func countItems(before date: Date) -> Int {
        let descriptor = FetchDescriptor<PlaybackHistoryRecord>(
            predicate: #Predicate { record in
                record.playedAt < date
            }
        )
        do {
            return try modelContext.fetchCount(descriptor)
        } catch {
            Log.warning("[PlaybackHistory] count failed: \(error)", category: .library)
            return 0
        }
    }

    @discardableResult
    func delete(itemID: UUID) -> Bool {
        delete(itemIDs: [itemID])
    }

    @discardableResult
    func delete(itemIDs: some Collection<UUID>) -> Bool {
        let ids = Set(itemIDs)
        guard !ids.isEmpty else { return true }

        guard let allRecords = fetchAllRecordsForMutation() else { return false }
        let records = allRecords.filter { ids.contains($0.id) }
        guard !records.isEmpty else { return true }
        records.forEach { modelContext.delete($0) }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            Log.error("[PlaybackHistory] delete failed: \(error)", category: .library)
            return false
        }

        dailyCountsCache = nil
        revision &+= 1
        NotificationCenter.default.post(name: .playbackHistoryDidChange, object: nil)
        return true
    }

    @discardableResult
    func clearAll() -> Bool {
        guard let records = fetchAllRecordsForMutation() else { return false }
        guard !records.isEmpty else { return true }
        records.forEach { modelContext.delete($0) }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            Log.error("[PlaybackHistory] clear failed: \(error)", category: .library)
            return false
        }

        dailyCountsCache = nil
        revision &+= 1
        NotificationCenter.default.post(name: .playbackHistoryDidChange, object: nil)
        return true
    }

    func dailyPlayCounts() -> [Date: Int] {
        if let dailyCountsCache {
            return dailyCountsCache
        }

        var counts: [Date: Int] = [:]
        for item in fetchItems() {
            let day = Calendar.current.startOfDay(for: item.playedAt)
            counts[day, default: 0] += 1
        }
        dailyCountsCache = counts
        return counts
    }

    private func fetchRecords(
        sortAscending: Bool,
        limit: Int?
    ) -> [PlaybackHistoryRecord] {
        var descriptor = FetchDescriptor<PlaybackHistoryRecord>(
            sortBy: [
                SortDescriptor(
                    \PlaybackHistoryRecord.playedAt,
                    order: sortAscending ? .forward : .reverse
                )
            ]
        )
        descriptor.fetchLimit = limit
        return fetchRecords(using: &descriptor)
    }

    private func fetchItems(
        using descriptor: inout FetchDescriptor<PlaybackHistoryRecord>
    ) -> [PlaybackHistoryItem] {
        fetchRecords(using: &descriptor).map(Self.makeItem)
    }

    private func fetchRecords(
        using descriptor: inout FetchDescriptor<PlaybackHistoryRecord>
    ) -> [PlaybackHistoryRecord] {
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            Log.warning("[PlaybackHistory] fetch failed: \(error)", category: .library)
            return []
        }
    }

    private func fetchAllRecordsForMutation() -> [PlaybackHistoryRecord]? {
        do {
            return try modelContext.fetch(FetchDescriptor<PlaybackHistoryRecord>())
        } catch {
            Log.error("[PlaybackHistory] mutation fetch failed: \(error)", category: .library)
            return nil
        }
    }

    private func trimIfNeeded() throws {
        let count = try modelContext.fetchCount(FetchDescriptor<PlaybackHistoryRecord>())
        guard count > Self.maximumStoredRecords else { return }

        var descriptor = FetchDescriptor<PlaybackHistoryRecord>(
            sortBy: [SortDescriptor(\PlaybackHistoryRecord.playedAt, order: .forward)]
        )
        descriptor.fetchLimit = count - Self.maximumStoredRecords
        for record in try modelContext.fetch(descriptor) {
            modelContext.delete(record)
        }
    }

    private static func makeItem(_ record: PlaybackHistoryRecord) -> PlaybackHistoryItem {
        PlaybackHistoryItem(
            id: record.id,
            trackID: record.trackID,
            playedAt: record.playedAt,
            title: record.title,
            artist: record.artist,
            album: record.album,
            duration: record.duration,
            playedSeconds: record.playedSeconds
        )
    }

    private static func makeContainer(at storeURL: URL) -> ModelContainer {
        let schema = Schema([PlaybackHistoryRecord.self])
        let libraryRootURL = storeURL.deletingLastPathComponent().deletingLastPathComponent()
        let persistentStoreURL = PlaybackHistoryStorePaths.prepareStoreURL(at: libraryRootURL)

        let initialAttempt = makePersistentContainer(schema: schema, storeURL: persistentStoreURL)
        if let container = initialAttempt.container {
            return container
        }

        if let error = initialAttempt.error,
           isConfirmedStoreCorruption(error),
           isolateDamagedStore(at: persistentStoreURL),
           let container = makePersistentContainer(schema: schema, storeURL: persistentStoreURL).container {
            Log.warning("[PlaybackHistory] recovered by rebuilding a damaged history store", category: .library)
            return container
        }

        Log.error("[PlaybackHistory] using an in-memory history store for this launch", category: .library)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }

    private static func makePersistentContainer(
        schema: Schema,
        storeURL: URL
    ) -> (container: ModelContainer?, error: Error?) {
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return (try ModelContainer(for: schema, configurations: [configuration]), nil)
        } catch {
            Log.error("[PlaybackHistory] persistent store unavailable: \(error)", category: .library)
            return (nil, error)
        }
    }

    private static func isConfirmedStoreCorruption(_ error: Error) -> Bool {
        var pending = [error as NSError]
        var inspected = 0
        while let current = pending.popLast(), inspected < 16 {
            inspected += 1
            if current.domain == "NSSQLiteErrorDomain",
               [11, 24, 26].contains(current.code) {
                return true
            }

            let description = [
                current.localizedDescription,
                current.localizedFailureReason ?? ""
            ].joined(separator: " ").lowercased()
            if description.contains("database disk image is malformed")
                || description.contains("file is not a database")
                || description.contains("database corruption") {
                return true
            }

            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
            if let detailed = current.userInfo["NSDetailedErrors"] as? [NSError] {
                pending.append(contentsOf: detailed)
            }
        }
        return false
    }

    @discardableResult
    private static func isolateDamagedStore(at storeURL: URL) -> Bool {
        let fileManager = FileManager.default
        let recoveryID = UUID().uuidString.lowercased()
        var movedStore = false
        var movedFiles: [(source: URL, isolated: URL)] = []

        for suffix in ["", "-wal", "-shm"] {
            let sourceURL = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            let isolatedURL = URL(fileURLWithPath: storeURL.path + ".corrupt-\(recoveryID)\(suffix)")
            do {
                try fileManager.moveItem(at: sourceURL, to: isolatedURL)
                movedStore = true
                movedFiles.append((sourceURL, isolatedURL))
            } catch {
                for movedFile in movedFiles.reversed() {
                    try? fileManager.moveItem(at: movedFile.isolated, to: movedFile.source)
                }
                Log.error(
                    "[PlaybackHistory] could not isolate \(sourceURL.lastPathComponent): \(error)",
                    category: .library
                )
                return false
            }
        }

        return movedStore
    }
}

extension Notification.Name {
    static let playbackHistoryDidChange = Notification.Name("playbackHistoryDidChange")
}
