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
    /// A bounded event log keeps launch and day queries predictable even for
    /// libraries that have been played for years.
    static let maximumStoredRecords = 10_000

    @ObservationIgnored private var modelContainer: ModelContainer
    @ObservationIgnored private var modelContext: ModelContext
    @ObservationIgnored private var activeStoreURL: URL
    @ObservationIgnored private var dailyCountsCache: [Date: Int]?
    private(set) var revision: Int = 0

    init(context: LibraryContext) {
        let container = Self.makeContainer(context: context)
        self.modelContainer = container
        self.modelContext = ModelContext(container)
        self.activeStoreURL = context.paths.playbackHistoryStoreURL
    }

    private init(inMemoryContainer: ModelContainer) {
        self.modelContainer = inMemoryContainer
        self.modelContext = ModelContext(inMemoryContainer)
        self.activeStoreURL = URL(fileURLWithPath: "/dev/null/kmgccc-playback-history")
    }

    static func inMemory() -> PlaybackHistoryStore {
        PlaybackHistoryStore(inMemoryContainer: makeInMemoryContainer())
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

    func validateReadableStore(at expectedURL: URL) throws {
        guard activeStoreURL.standardizedFileURL == expectedURL.standardizedFileURL else {
            throw LibraryUpgradeValidationError.historyStoreMismatch
        }
        _ = try modelContext.fetchCount(FetchDescriptor<PlaybackHistoryRecord>())
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

    private static func makeContainer(context: LibraryContext) -> ModelContainer {
        let schema = Schema([PlaybackHistoryRecord.self])
        let configuration = ModelConfiguration(
            schema: schema,
            url: PlaybackHistoryStorePaths.prepareStoreURL(in: context.paths)
        )
        return makeContainer(schema: schema, configuration: configuration)
    }

    private static func makeInMemoryContainer() -> ModelContainer {
        let schema = Schema([PlaybackHistoryRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return makeContainer(schema: schema, configuration: configuration)
    }

    private static func makeContainer(
        schema: Schema,
        configuration: ModelConfiguration
    ) -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create PlaybackHistory ModelContainer: \(error)")
        }
    }
}

extension Notification.Name {
    static let playbackHistoryDidChange = Notification.Name("playbackHistoryDidChange")
}
