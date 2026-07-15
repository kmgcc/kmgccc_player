//
//  ImportEnrichmentService.swift
//  myPlayer2
//
//  kmgccc_player - Import enrichment queue coordination
//

import AVFoundation
import AppKit
import Combine
import CoreServices
import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum ImportEnrichmentMode: Sendable {
    case immediate
    case deferred

    var defersEnrichment: Bool {
        self == .deferred
    }
}

nonisolated enum ImportLyricsLookupOutcome: Sendable {
    case completed(String)
    case noResults
    case failed(String)
}

nonisolated enum ImportCoverLookupOutcome: Sendable {
    case completed(Data)
    case noResults
    case failed(String)
}

nonisolated private enum ImportEnrichmentPart: String, Sendable, Hashable, CaseIterable {
    case lyrics
    case cover
    case trackMetadata
    case artistMetadata
    case albumMetadata
    case artistArtwork
    case albumArtwork

    var label: String {
        switch self {
        case .lyrics: return "歌词"
        case .cover: return "封面"
        case .trackMetadata: return "歌曲信息"
        case .artistMetadata: return "歌手信息"
        case .albumMetadata: return "专辑信息"
        case .artistArtwork: return "歌手封面"
        case .albumArtwork: return "专辑封面"
        }
    }

}

nonisolated private enum ImportEnrichmentPartState: String, Sendable {
    case pending
    case running
    case flushPending
    case completed
    case failed
    case noResults
    case skipped

    var isOutstanding: Bool {
        self == .pending || self == .running || self == .flushPending
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .noResults, .skipped:
            return true
        case .pending, .running, .flushPending:
            return false
        }
    }

    var countsAsFailure: Bool {
        self == .failed || self == .noResults
    }
}

nonisolated private struct ImportEnrichmentPartRequest: Sendable, Hashable {
    let trackID: UUID
    let part: ImportEnrichmentPart
}

nonisolated private struct ImportEnrichmentItemState: Sendable {
    let trackID: UUID
    var title: String
    var artist: String
    var album: String
    private var partStates: [ImportEnrichmentPart: ImportEnrichmentPartState] = [:]
    private var partAttempts: [ImportEnrichmentPart: Int] = [:]

    init(
        trackID: UUID,
        title: String,
        artist: String,
        album: String,
        partStates: [ImportEnrichmentPart: ImportEnrichmentPartState] = [:],
        partAttempts: [ImportEnrichmentPart: Int] = [:]
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.partStates = partStates
        self.partAttempts = partAttempts
    }

    func state(for part: ImportEnrichmentPart) -> ImportEnrichmentPartState {
        partStates[part] ?? .pending
    }

    mutating func setState(_ state: ImportEnrichmentPartState, for part: ImportEnrichmentPart) {
        partStates[part] = state
    }

    func attempts(for part: ImportEnrichmentPart) -> Int {
        partAttempts[part] ?? 0
    }

    mutating func incrementAttempts(for part: ImportEnrichmentPart) {
        partAttempts[part, default: 0] += 1
    }

    var hasOutstandingWork: Bool {
        ImportEnrichmentPart.allCases.contains { partStates[$0]?.isOutstanding ?? false }
    }

    var isTerminal: Bool {
        ImportEnrichmentPart.allCases.allSatisfy { partStates[$0]?.isTerminal ?? false }
    }

    var hasTerminalFailure: Bool {
        ImportEnrichmentPart.allCases.contains { partStates[$0]?.countsAsFailure ?? false }
    }

    var flushPendingPartCount: Int {
        partStates.values.filter { $0 == .flushPending }.count
    }

    // Legacy accessors for backward compatibility in existing code
    var lyricsState: ImportEnrichmentPartState {
        get { state(for: .lyrics) }
        set { setState(newValue, for: .lyrics) }
    }
    var coverState: ImportEnrichmentPartState {
        get { state(for: .cover) }
        set { setState(newValue, for: .cover) }
    }
    var lyricAttempts: Int {
        get { attempts(for: .lyrics) }
        set { partAttempts[.lyrics] = newValue }
    }
    var coverAttempts: Int {
        get { attempts(for: .cover) }
        set { partAttempts[.cover] = newValue }
    }
}

nonisolated struct ImportEnrichmentProgressSnapshot: Sendable, Equatable {
    let totalEnqueued: Int
    let completedCount: Int
    let failedCount: Int
    let pendingLyricsCount: Int
    let pendingCoverCount: Int
    let pendingTrackMetadataCount: Int
    let pendingArtistMetadataCount: Int
    let pendingAlbumMetadataCount: Int
    let pendingArtistArtworkCount: Int
    let pendingAlbumArtworkCount: Int
    let runningCount: Int
    let flushPendingCount: Int

    var hasOutstandingWork: Bool {
        pendingLyricsCount > 0 || pendingCoverCount > 0
            || pendingTrackMetadataCount > 0 || pendingArtistMetadataCount > 0
            || pendingAlbumMetadataCount > 0 || pendingArtistArtworkCount > 0
            || pendingAlbumArtworkCount > 0
            || runningCount > 0 || flushPendingCount > 0
    }

    var sidebarText: String {
        var parts: [String] = [
            "补全中 \(completedCount)/\(totalEnqueued)"
        ]
        if runningCount > 0 {
            parts.append("进行中 \(runningCount)")
        }
        if flushPendingCount > 0 {
            parts.append("待提交 \(flushPendingCount)")
        }
        let pendingMeta = pendingTrackMetadataCount + pendingArtistMetadataCount + pendingAlbumMetadataCount
        let pendingArt = pendingArtistArtworkCount + pendingAlbumArtworkCount
        if pendingLyricsCount > 0 || pendingCoverCount > 0 || pendingMeta > 0 || pendingArt > 0 {
            var detailParts: [String] = []
            if pendingLyricsCount > 0 { detailParts.append("词\(pendingLyricsCount)") }
            if pendingCoverCount > 0 { detailParts.append("封\(pendingCoverCount)") }
            if pendingMeta > 0 { detailParts.append("信息\(pendingMeta)") }
            if pendingArt > 0 { detailParts.append("图\(pendingArt)") }
            parts.append(detailParts.joined(separator: " "))
        }
        if failedCount > 0 {
            parts.append("失败 \(failedCount)")
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated private struct PendingTrackEnrichmentPatch: Sendable {
    let trackID: UUID
    var ttmlLyricText: String?
    var artworkData: Data?
    var lyricShouldFlush: Bool
    var coverShouldFlush: Bool
    var trackMetadataShouldFlush: Bool

    // Track metadata fields (filled by metadata enrichment)
    var album: String?
    var userDescription: String?
    var genreTags: [String]?
    var language: String?
    var labelOrCompany: String?
    var releaseDate: Date?
    var qqMusicSongMid: String?

    init(trackID: UUID) {
        self.trackID = trackID
        self.ttmlLyricText = nil
        self.artworkData = nil
        self.lyricShouldFlush = false
        self.coverShouldFlush = false
        self.trackMetadataShouldFlush = false
        self.album = nil
        self.userDescription = nil
        self.genreTags = nil
        self.language = nil
        self.labelOrCompany = nil
        self.releaseDate = nil
        self.qqMusicSongMid = nil
    }
}

@MainActor
@Observable
final class ImportEnrichmentService {
    private let repository: LibraryRepositoryProtocol
    private let maxConcurrent: Int
    private let maxAttemptsPerPart = 2
    private let flushBatchSize = 4
    private let flushDebounceNanoseconds: UInt64 = 900_000_000

    private var queue: [ImportEnrichmentPartRequest] = []
    private var queuedRequests: Set<ImportEnrichmentPartRequest> = []
    private var runningRequests: Set<ImportEnrichmentPartRequest> = []
    private var activeTasks: [ImportEnrichmentPartRequest: Task<Void, Never>] = [:]
    private var trackByID: [UUID: Track] = [:]
    private var itemStates: [UUID: ImportEnrichmentItemState] = [:]
    private var pendingFlushPatches: [UUID: PendingTrackEnrichmentPatch] = [:]
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var entryUpdateLocks: Set<String> = []
    private var entryUpdateWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    // Batch-level deduplication for artist/album enrichment
    private var enqueuedArtistMetadata: Set<String> = []
    private var enqueuedAlbumMetadata: Set<String> = []
    private var enqueuedArtistArtwork: Set<String> = []
    private var enqueuedAlbumArtwork: Set<String> = []
    private(set) var progress = ImportEnrichmentProgressSnapshot(
        totalEnqueued: 0,
        completedCount: 0,
        failedCount: 0,
        pendingLyricsCount: 0,
        pendingCoverCount: 0,
        pendingTrackMetadataCount: 0,
        pendingArtistMetadataCount: 0,
        pendingAlbumMetadataCount: 0,
        pendingArtistArtworkCount: 0,
        pendingAlbumArtworkCount: 0,
        runningCount: 0,
        flushPendingCount: 0
    )

    var hasOutstandingWork: Bool { progress.hasOutstandingWork }

    init(repository: LibraryRepositoryProtocol, maxConcurrent: Int = 2) {
        self.repository = repository
        self.maxConcurrent = max(1, maxConcurrent)
        Log.info("[ImportEnrichment] service init", category: .import)
    }

    deinit {
        Log.info("[ImportEnrichment] service deinit", category: .import)
    }

    func cancelEnrichment(for trackIDs: Set<UUID>) async {
        guard !trackIDs.isEmpty else { return }

        queue.removeAll { trackIDs.contains($0.trackID) }
        queuedRequests = queuedRequests.filter { !trackIDs.contains($0.trackID) }
        runningRequests = runningRequests.filter { !trackIDs.contains($0.trackID) }
        for (request, task) in activeTasks where trackIDs.contains(request.trackID) {
            task.cancel()
            activeTasks[request] = nil
        }

        for trackID in trackIDs {
            trackByID[trackID] = nil
            itemStates[trackID] = nil
            pendingFlushPatches[trackID] = nil
        }

        if queue.isEmpty, runningRequests.isEmpty, pendingFlushPatches.isEmpty {
            flushTask?.cancel()
            flushTask = nil
            isFlushing = false
            enqueuedArtistMetadata.removeAll()
            enqueuedAlbumMetadata.removeAll()
            enqueuedArtistArtwork.removeAll()
            enqueuedAlbumArtwork.removeAll()
        }

        refreshProgress()
        Log.info(
            "[ImportEnrichment] cancelled deleted tracks count=\(trackIDs.count)",
            category: .import
        )
    }

    func enqueueTracks(_ tracks: [Track]) async {
        if hasOutstandingWork == false {
            resetProgressIfIdle()
        }

        Log.info("[ImportEnrichment] queue wake requested for \(tracks.count) tracks", category: .import)

        let artistEntriesByCanonical = ImportEnrichmentService.artistEntriesByCanonical(
            await repository.fetchArtistEntries()
        )
        let albumEntriesByCanonical = ImportEnrichmentService.albumEntriesByCanonical(
            await repository.fetchAlbumEntries()
        )

        for track in tracks {
            guard let itemState = makeInitialItemState(
                for: track,
                artistEntriesByCanonical: artistEntriesByCanonical,
                albumEntriesByCanonical: albumEntriesByCanonical
            ) else { continue }
            if itemStates[track.id] == nil {
                itemStates[track.id] = itemState
            } else {
                itemStates[track.id]?.title = track.title
                itemStates[track.id]?.artist = track.artist
                itemStates[track.id]?.album = track.album
            }

            trackByID[track.id] = track

            if track.ttmlLyricText == nil {
                enqueuePart(.lyrics, for: track.id)
            } else if var state = itemStates[track.id], state.state(for: .lyrics) != .completed {
                state.setState(.skipped, for: .lyrics)
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already present",
                    category: .lyrics
                )
            }

            if track.artworkData == nil {
                enqueuePart(.cover, for: track.id)
            } else if var state = itemStates[track.id], state.state(for: .cover) != .completed {
                state.setState(.skipped, for: .cover)
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
            }

            // Track metadata
            if trackMetadataIsMissing(track) {
                enqueuePart(.trackMetadata, for: track.id)
            } else if var state = itemStates[track.id], state.state(for: .trackMetadata) != .completed {
                state.setState(.skipped, for: .trackMetadata)
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] trackMetadata skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
            }

            // Artist metadata (dedup across batch)
            let artistCanonical = LibraryNormalization.normalizeArtist(track.artist)
            if itemState.state(for: .artistMetadata) == .pending,
               !enqueuedArtistMetadata.contains(artistCanonical) {
                enqueuedArtistMetadata.insert(artistCanonical)
                enqueuePart(.artistMetadata, for: track.id)
            } else if var state = itemStates[track.id] {
                state.setState(.skipped, for: .artistMetadata)
                itemStates[track.id] = state
            }

            // Album metadata (dedup across batch)
            let albumCanonical = LibraryNormalization.normalizedAlbumKey(album: track.album)
            let albumDedupKey = "\(artistCanonical)•\(albumCanonical)"
            if itemState.state(for: .albumMetadata) == .pending,
               !enqueuedAlbumMetadata.contains(albumDedupKey) {
                enqueuedAlbumMetadata.insert(albumDedupKey)
                enqueuePart(.albumMetadata, for: track.id)
            } else if var state = itemStates[track.id] {
                state.setState(.skipped, for: .albumMetadata)
                itemStates[track.id] = state
            }

            // Artist artwork (dedup across batch)
            if itemState.state(for: .artistArtwork) == .pending,
               !enqueuedArtistArtwork.contains(artistCanonical) {
                enqueuedArtistArtwork.insert(artistCanonical)
                enqueuePart(.artistArtwork, for: track.id)
            } else if var state = itemStates[track.id] {
                state.setState(.skipped, for: .artistArtwork)
                itemStates[track.id] = state
            }

            // Album artwork (dedup across batch)
            if itemState.state(for: .albumArtwork) == .pending,
               !enqueuedAlbumArtwork.contains(albumDedupKey) {
                enqueuedAlbumArtwork.insert(albumDedupKey)
                enqueuePart(.albumArtwork, for: track.id)
            } else if var state = itemStates[track.id] {
                state.setState(.skipped, for: .albumArtwork)
                itemStates[track.id] = state
            }

            guard let state = itemStates[track.id] else {
                continue
            }
            let states = ImportEnrichmentPart.allCases.map { "\($0.rawValue)=\(state.state(for: $0).rawValue)" }.joined(separator: " ")
            Log.info(
                "[ImportEnrichment] track queued \(track.title) - \(track.artist) | \(states)",
                category: .import
            )
        }

        refreshProgress()
        drainQueueIfPossible()
        diagnoseStalledQueue(context: "enqueue")
    }

    private func makeInitialItemState(
        for track: Track,
        artistEntriesByCanonical: [String: ArtistEntry],
        albumEntriesByCanonical: [String: AlbumEntry]
    ) -> ImportEnrichmentItemState? {
        let needsLyrics = track.ttmlLyricText == nil
        let needsCover = track.artworkData == nil
        let needsTrackMetadata = trackMetadataIsMissing(track)
        let needsArtistMetadata = Self.artistMetadataNeedsEnrichment(
            artist: track.artist,
            entriesByCanonical: artistEntriesByCanonical
        )
        let needsAlbumMetadata = Self.albumMetadataNeedsEnrichment(
            album: track.album,
            entriesByCanonical: albumEntriesByCanonical
        )
        let needsArtistArtwork = Self.artistArtworkNeedsEnrichment(
            artist: track.artist,
            entriesByCanonical: artistEntriesByCanonical
        )
        let needsAlbumArtwork = Self.albumArtworkNeedsEnrichment(
            album: track.album,
            entriesByCanonical: albumEntriesByCanonical
        )
        let needsAny = needsLyrics || needsCover || needsTrackMetadata
            || needsArtistMetadata || needsAlbumMetadata || needsArtistArtwork || needsAlbumArtwork
        guard needsAny else { return nil }

        var partStates: [ImportEnrichmentPart: ImportEnrichmentPartState] = [:]
        partStates[.lyrics] = needsLyrics ? .pending : .skipped
        partStates[.cover] = needsCover ? .pending : .skipped
        partStates[.trackMetadata] = needsTrackMetadata ? .pending : .skipped
        partStates[.artistMetadata] = needsArtistMetadata ? .pending : .skipped
        partStates[.albumMetadata] = needsAlbumMetadata ? .pending : .skipped
        partStates[.artistArtwork] = needsArtistArtwork ? .pending : .skipped
        partStates[.albumArtwork] = needsAlbumArtwork ? .pending : .skipped

        return ImportEnrichmentItemState(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            partStates: partStates,
            partAttempts: [:]
        )
    }

    private func trackMetadataIsMissing(_ track: Track) -> Bool {
        if MetadataDetailApplicator.shouldFillMissingAlbum(track.album) {
            return true
        }
        if track.genreTags.isEmpty == false,
           track.language.isEmpty == false,
           track.labelOrCompany.isEmpty == false,
           track.releaseDate != nil {
            return false
        }
        return true
    }

    static func artistEntriesByCanonical(_ entries: [ArtistEntry]) -> [String: ArtistEntry] {
        var result: [String: ArtistEntry] = [:]
        for entry in entries where result[entry.canonicalName] == nil {
            result[entry.canonicalName] = entry
        }
        return result
    }

    static func albumEntriesByCanonical(_ entries: [AlbumEntry]) -> [String: AlbumEntry] {
        var result: [String: AlbumEntry] = [:]
        for entry in entries where result[entry.canonicalKey] == nil {
            result[entry.canonicalKey] = entry
        }
        return result
    }

    static func artistMetadataNeedsEnrichment(
        artist: String,
        entriesByCanonical: [String: ArtistEntry]
    ) -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        guard let entry = entriesByCanonical[canonical] else { return true }
        return entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.genreTags.isEmpty
            || entry.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.foreignName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func artistArtworkNeedsEnrichment(
        artist: String,
        entriesByCanonical: [String: ArtistEntry]
    ) -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        guard let entry = entriesByCanonical[canonical] else { return true }
        return entry.artworkData == nil
    }

    static func albumMetadataNeedsEnrichment(
        album: String,
        entriesByCanonical: [String: AlbumEntry]
    ) -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        let canonical = LibraryNormalization.normalizedAlbumKey(album: album)
        guard let entry = entriesByCanonical[canonical] else { return true }
        return entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (entry.year == nil && entry.releaseYear == nil && entry.releaseDate == nil)
            || entry.albumType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.genreTags.isEmpty
            || entry.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func albumArtworkNeedsEnrichment(
        album: String,
        entriesByCanonical: [String: AlbumEntry]
    ) -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        let canonical = LibraryNormalization.normalizedAlbumKey(album: album)
        guard let entry = entriesByCanonical[canonical] else { return true }
        return entry.artworkData == nil
    }

    private func enqueuePart(_ part: ImportEnrichmentPart, for trackID: UUID) {
        let request = ImportEnrichmentPartRequest(trackID: trackID, part: part)
        guard queuedRequests.contains(request) == false, runningRequests.contains(request) == false
        else { return }
        guard var state = itemStates[trackID] else { return }
        let currentState = state.state(for: part)
        guard currentState == .pending || currentState == .failed else { return }

        state.setState(.pending, for: part)
        itemStates[trackID] = state
        queue.append(request)
        queuedRequests.insert(request)
        Log.info(
            "[ImportEnrichment] \(part.rawValue) enqueued \(state.title) - \(state.artist)",
            category: part == .lyrics ? .lyrics : .import
        )
    }

    private func withEntryUpdateLock<T>(_ key: String, operation: () async -> T) async -> T {
        await acquireEntryUpdateLock(key)
        let result = await operation()
        releaseEntryUpdateLock(key)
        return result
    }

    private func acquireEntryUpdateLock(_ key: String) async {
        while entryUpdateLocks.contains(key) {
            await withCheckedContinuation { continuation in
                entryUpdateWaiters[key, default: []].append(continuation)
            }
        }
        entryUpdateLocks.insert(key)
    }

    private func releaseEntryUpdateLock(_ key: String) {
        if var waiters = entryUpdateWaiters[key], !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            entryUpdateWaiters[key] = waiters.isEmpty ? nil : waiters
            entryUpdateLocks.remove(key)
            continuation.resume()
        } else {
            entryUpdateLocks.remove(key)
        }
    }

    private static func artistUpdateLockKey(_ artist: String) -> String? {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return nil }
        return "artist:\(canonical)"
    }

    private static func albumUpdateLockKey(_ album: String) -> String? {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return nil }
        return "album:\(LibraryNormalization.normalizedAlbumKey(album: album))"
    }

    private func applyArtistMetadataDetail(
        _ detail: ArtistMetadataDetail,
        artist: String
    ) async -> Bool {
        guard let lockKey = Self.artistUpdateLockKey(artist) else { return false }
        return await withEntryUpdateLock(lockKey) {
            await self.applyArtistMetadataDetailUnlocked(detail, artist: artist)
        }
    }

    private func applyArtistArtworkData(_ data: Data, artist: String) async -> Bool {
        guard let lockKey = Self.artistUpdateLockKey(artist) else { return false }
        return await withEntryUpdateLock(lockKey) {
            await self.applyArtistArtworkDataUnlocked(data, artist: artist)
        }
    }

    private func applyAlbumMetadataDetail(
        _ detail: AlbumMetadataDetail,
        album: String,
        artist: String
    ) async -> Bool {
        guard let lockKey = Self.albumUpdateLockKey(album) else { return false }
        return await withEntryUpdateLock(lockKey) {
            await self.applyAlbumMetadataDetailUnlocked(detail, album: album, artist: artist)
        }
    }

    private func applyAlbumArtworkData(_ data: Data, album: String, artist: String) async -> Bool {
        guard let lockKey = Self.albumUpdateLockKey(album) else { return false }
        return await withEntryUpdateLock(lockKey) {
            await self.applyAlbumArtworkDataUnlocked(data, album: album, artist: artist)
        }
    }

    private func applyArtistMetadataDetailUnlocked(
        _ detail: ArtistMetadataDetail,
        artist: String
    ) async -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        let entry = await latestArtistEntry(canonical: canonical, displayName: artist)
        let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
        guard result.changed else { return false }
        await repository.updateArtistEntry(result.value)
        return true
    }

    private func applyArtistArtworkDataUnlocked(_ data: Data, artist: String) async -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        var entry = await latestArtistEntry(canonical: canonical, displayName: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        await repository.updateArtistEntry(entry)
        return true
    }

    private func applyAlbumMetadataDetailUnlocked(
        _ detail: AlbumMetadataDetail,
        album: String,
        artist: String
    ) async -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        let entry = await latestAlbumEntry(album: album, artist: artist)
        let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
        guard result.changed else { return false }
        await repository.updateAlbumEntry(result.value)
        return true
    }

    private func applyAlbumArtworkDataUnlocked(_ data: Data, album: String, artist: String) async -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        var entry = await latestAlbumEntry(album: album, artist: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        await repository.updateAlbumEntry(entry)
        return true
    }

    private func latestArtistEntry(canonical: String, displayName: String) async -> ArtistEntry {
        let entries = await repository.fetchArtistEntries()
        if let entry = entries.first(where: { $0.canonicalName == canonical }) {
            return entry
        }

        let now = Date()
        return ArtistEntry(
            id: UUID(),
            canonicalName: canonical,
            displayName: LibraryNormalization.displayArtist(displayName),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            albumCount: 0,
            totalDuration: 0,
            isOrphaned: true
        )
    }

    private func latestAlbumEntry(album: String, artist: String) async -> AlbumEntry {
        let albumKey = LibraryNormalization.normalizedAlbumKey(album: album)
        let entries = await repository.fetchAlbumEntries()
        if let entry = entries.first(where: { $0.canonicalKey == albumKey }) {
            return entry
        }

        let now = Date()
        return AlbumEntry(
            id: UUID(),
            canonicalKey: albumKey,
            displayTitle: LibraryNormalization.displayAlbum(album),
            primaryArtistCanonicalName: LibraryNormalization.normalizeArtist(artist),
            primaryArtistDisplayName: LibraryNormalization.displayArtist(artist),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            totalDuration: 0,
            isOrphaned: true
        )
    }

    private func refreshProgress() {
        let values = Array(itemStates.values)
        let completedCount = values.filter(\.isTerminal).count
        let failedCount = values.filter(\.hasTerminalFailure).count
        let pendingLyricsCount = values.filter {
            $0.state(for: .lyrics) == .pending || $0.state(for: .lyrics) == .running
        }.count
        let pendingCoverCount = values.filter {
            $0.state(for: .cover) == .pending || $0.state(for: .cover) == .running
        }.count
        let pendingTrackMetadataCount = values.filter {
            $0.state(for: .trackMetadata) == .pending || $0.state(for: .trackMetadata) == .running
        }.count
        let pendingArtistMetadataCount = values.filter {
            $0.state(for: .artistMetadata) == .pending || $0.state(for: .artistMetadata) == .running
        }.count
        let pendingAlbumMetadataCount = values.filter {
            $0.state(for: .albumMetadata) == .pending || $0.state(for: .albumMetadata) == .running
        }.count
        let pendingArtistArtworkCount = values.filter {
            $0.state(for: .artistArtwork) == .pending || $0.state(for: .artistArtwork) == .running
        }.count
        let pendingAlbumArtworkCount = values.filter {
            $0.state(for: .albumArtwork) == .pending || $0.state(for: .albumArtwork) == .running
        }.count
        let flushPendingCount = values.reduce(0) { $0 + $1.flushPendingPartCount }

        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: values.count,
            completedCount: completedCount,
            failedCount: failedCount,
            pendingLyricsCount: pendingLyricsCount,
            pendingCoverCount: pendingCoverCount,
            pendingTrackMetadataCount: pendingTrackMetadataCount,
            pendingArtistMetadataCount: pendingArtistMetadataCount,
            pendingAlbumMetadataCount: pendingAlbumMetadataCount,
            pendingArtistArtworkCount: pendingArtistArtworkCount,
            pendingAlbumArtworkCount: pendingAlbumArtworkCount,
            runningCount: runningRequests.count,
            flushPendingCount: flushPendingCount
        )
    }

    private func resetProgressIfIdle() {
        flushTask?.cancel()
        flushTask = nil
        queue.removeAll()
        queuedRequests.removeAll()
        runningRequests.removeAll()
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        trackByID.removeAll()
        itemStates.removeAll()
        pendingFlushPatches.removeAll()
        isFlushing = false
        enqueuedArtistMetadata.removeAll()
        enqueuedAlbumMetadata.removeAll()
        enqueuedArtistArtwork.removeAll()
        enqueuedAlbumArtwork.removeAll()
        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: 0,
            completedCount: 0,
            failedCount: 0,
            pendingLyricsCount: 0,
            pendingCoverCount: 0,
            pendingTrackMetadataCount: 0,
            pendingArtistMetadataCount: 0,
            pendingAlbumMetadataCount: 0,
            pendingArtistArtworkCount: 0,
            pendingAlbumArtworkCount: 0,
            runningCount: 0,
            flushPendingCount: 0
        )
    }

    private func drainQueueIfPossible() {
        if queue.isEmpty == false {
            Log.debug(
                "[ImportEnrichment] queue wake | queued=\(queue.count) running=\(runningRequests.count)",
                category: .import
            )
        }
        while runningRequests.count < maxConcurrent, queue.isEmpty == false {
            let request = queue.removeFirst()
            queuedRequests.remove(request)

            guard let track = trackByID[request.trackID], var state = itemStates[request.trackID] else {
                continue
            }

            if request.part == .lyrics, track.ttmlLyricText != nil {
                state.setState(.skipped, for: .lyrics)
                itemStates[request.trackID] = state
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already present",
                    category: .lyrics
                )
                refreshProgress()
                continue
            }

            if request.part == .cover, track.artworkData != nil {
                state.setState(.skipped, for: .cover)
                itemStates[request.trackID] = state
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
                refreshProgress()
                continue
            }

            if request.part == .trackMetadata, !trackMetadataIsMissing(track) {
                state.setState(.skipped, for: .trackMetadata)
                itemStates[request.trackID] = state
                Log.info(
                    "[ImportEnrichment] trackMetadata skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
                refreshProgress()
                continue
            }

            state.setState(.running, for: request.part)
            state.incrementAttempts(for: request.part)
            itemStates[request.trackID] = state
            runningRequests.insert(request)
            refreshProgress()
            start(request: request, track: track, state: state)
        }
        diagnoseStalledQueue(context: "drain")
    }

    private func start(
        request: ImportEnrichmentPartRequest,
        track: Track,
        state: ImportEnrichmentItemState
    ) {
        let title = state.title
        let artist = state.artist
        let album = state.album
        let duration = track.duration > 0 ? track.duration : nil
        let attempt = state.attempts(for: request.part)
        Log.info(
            "[ImportEnrichment] \(request.part.rawValue) started \(title) - \(artist) | attempt \(attempt)/\(maxAttemptsPerPart)",
            category: request.part == .lyrics ? .lyrics : .import
        )

        let task = Task(priority: .utility) {
            let taskStart = ContinuousClock.now
            guard !Task.isCancelled else {
                self.finish(request)
                return
            }

            switch request.part {
            case .lyrics:
                let outcome = await ImportEnrichmentWorker.fetchLyrics(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
                await self.completeLyrics(request: request, outcome: outcome)
            case .cover:
                let outcome = await ImportEnrichmentWorker.fetchCover(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
                await self.completeCover(request: request, outcome: outcome)
            case .trackMetadata:
                let outcome = await MetadataEnrichmentWorker.fetchTrackMetadata(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
                await self.completeTrackMetadata(request: request, outcome: outcome)
            case .artistMetadata:
                let outcome = await MetadataEnrichmentWorker.fetchArtistMetadata(name: artist)
                await self.completeArtistMetadata(request: request, outcome: outcome)
            case .albumMetadata:
                let outcome = await MetadataEnrichmentWorker.fetchAlbumMetadata(album: album, artist: artist)
                await self.completeAlbumMetadata(request: request, outcome: outcome)
            case .artistArtwork:
                let outcome = await MetadataEnrichmentWorker.fetchArtistArtwork(artist: artist)
                await self.completeArtistArtwork(request: request, outcome: outcome)
            case .albumArtwork:
                let outcome = await MetadataEnrichmentWorker.fetchAlbumArtwork(album: album, artist: artist)
                await self.completeAlbumArtwork(request: request, outcome: outcome)
            }

            let elapsed = taskStart.duration(to: ContinuousClock.now)
            let elapsedMs = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            Log.info(
                "[ImportEnrichment] \(request.part.rawValue) task end \(title) - \(artist) | \(String(format: "%.1f", elapsedMs))ms",
                category: request.part == .lyrics ? .lyrics : .import
            )
        }
        activeTasks[request] = task
    }

    private func completeLyrics(
        request: ImportEnrichmentPartRequest,
        outcome: ImportLyricsLookupOutcome
    ) async {
        guard let track = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let ttml):
            if track.ttmlLyricText == nil {
                bufferFlushPatch(
                    trackID: request.trackID,
                    title: state.title,
                    artist: state.artist
                ) { patch in
                    patch.ttmlLyricText = ttml
                    patch.lyricShouldFlush = true
                }
                state.setState(.flushPending, for: .lyrics)
                Log.info(
                    "[ImportEnrichment] lyrics buffered \(state.title) - \(state.artist)",
                    category: .lyrics
                )
            } else {
                state.setState(.skipped, for: .lyrics)
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already filled before save",
                    category: .lyrics
                )
            }
        case .noResults:
            state.setState(.noResults, for: .lyrics)
            Log.warning(
                "[ImportEnrichment] lyrics no-results \(state.title) - \(state.artist)",
                category: .lyrics
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .lyrics, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .lyrics)
                Log.warning(
                    "[ImportEnrichment] lyrics failed \(state.title) - \(state.artist) | retrying: \(message)",
                    category: .lyrics
                )
            } else {
                state.setState(.failed, for: .lyrics)
                Log.warning(
                    "[ImportEnrichment] lyrics failed \(state.title) - \(state.artist): \(message)",
                    category: .lyrics
                )
            }
        }

        itemStates[request.trackID] = state
        scheduleFlushIfNeeded(reason: "lyrics_result")
        finish(request, requeue: shouldRequeue)
    }

    private func completeCover(
        request: ImportEnrichmentPartRequest,
        outcome: ImportCoverLookupOutcome
    ) async {
        guard let track = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let data):
            if track.artworkData == nil {
                bufferFlushPatch(
                    trackID: request.trackID,
                    title: state.title,
                    artist: state.artist
                ) { patch in
                    patch.artworkData = data
                    patch.coverShouldFlush = true
                }
                state.setState(.flushPending, for: .cover)
                Log.info(
                    "[ImportEnrichment] cover buffered \(state.title) - \(state.artist)",
                    category: .import
                )
            } else {
                state.setState(.skipped, for: .cover)
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already filled before save",
                    category: .import
                )
            }
        case .noResults:
            state.setState(.noResults, for: .cover)
            Log.warning(
                "[ImportEnrichment] cover no-results \(state.title) - \(state.artist)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .cover, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .cover)
                Log.warning(
                    "[ImportEnrichment] cover failed \(state.title) - \(state.artist) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .cover)
                Log.warning(
                    "[ImportEnrichment] cover failed \(state.title) - \(state.artist): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        scheduleFlushIfNeeded(reason: "cover_result")
        finish(request, requeue: shouldRequeue)
    }

    private func completeTrackMetadata(
        request: ImportEnrichmentPartRequest,
        outcome: ImportTrackMetadataOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        var shouldEnqueueDiscoveredAlbumMetadata = false
        var shouldEnqueueDiscoveredAlbumArtwork = false
        switch outcome {
        case .completed(let detail):
            if let freshTrack = trackByID[request.trackID] {
                let previousAlbum = state.album
                let changed = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: freshTrack)
                if changed {
                    bufferFlushPatch(
                        trackID: request.trackID,
                        title: state.title,
                        artist: state.artist
                    ) { patch in
                        patch.album = freshTrack.album
                        patch.userDescription = freshTrack.userDescription
                        patch.genreTags = freshTrack.genreTags
                        patch.language = freshTrack.language
                        patch.labelOrCompany = freshTrack.labelOrCompany
                        patch.releaseDate = freshTrack.releaseDate
                        patch.qqMusicSongMid = freshTrack.qqMusicSongMid
                        patch.trackMetadataShouldFlush = true
                    }
                    state.setState(.flushPending, for: .trackMetadata)
                    if MetadataDetailApplicator.shouldFillMissingAlbum(previousAlbum),
                       !LibraryNormalization.isUnknownAlbum(freshTrack.album) {
                        state.album = freshTrack.album
                        let albumDedupKey = "\(LibraryNormalization.normalizeArtist(state.artist))•\(LibraryNormalization.normalizedAlbumKey(album: freshTrack.album))"
                        let albumEntries = Self.albumEntriesByCanonical(await repository.fetchAlbumEntries())
                        shouldEnqueueDiscoveredAlbumMetadata =
                            state.state(for: .albumMetadata) == .skipped
                            && !enqueuedAlbumMetadata.contains(albumDedupKey)
                            && Self.albumMetadataNeedsEnrichment(
                                album: freshTrack.album,
                                entriesByCanonical: albumEntries
                            )
                        shouldEnqueueDiscoveredAlbumArtwork =
                            state.state(for: .albumArtwork) == .skipped
                            && !enqueuedAlbumArtwork.contains(albumDedupKey)
                            && Self.albumArtworkNeedsEnrichment(
                                album: freshTrack.album,
                                entriesByCanonical: albumEntries
                            )
                        if shouldEnqueueDiscoveredAlbumMetadata {
                            enqueuedAlbumMetadata.insert(albumDedupKey)
                            state.setState(.pending, for: .albumMetadata)
                        }
                        if shouldEnqueueDiscoveredAlbumArtwork {
                            enqueuedAlbumArtwork.insert(albumDedupKey)
                            state.setState(.pending, for: .albumArtwork)
                        }
                    }
                    Log.info(
                        "[ImportEnrichment] trackMetadata buffered \(state.title) - \(state.artist)",
                        category: .import
                    )
                } else {
                    state.setState(.skipped, for: .trackMetadata)
                    Log.info(
                        "[ImportEnrichment] trackMetadata skipped \(state.title) - \(state.artist) | no fields to fill",
                        category: .import
                    )
                }
            } else {
                state.setState(.skipped, for: .trackMetadata)
            }
        case .noResults:
            state.setState(.noResults, for: .trackMetadata)
            Log.warning(
                "[ImportEnrichment] trackMetadata no-results \(state.title) - \(state.artist)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .trackMetadata, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .trackMetadata)
                Log.warning(
                    "[ImportEnrichment] trackMetadata failed \(state.title) - \(state.artist) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .trackMetadata)
                Log.warning(
                    "[ImportEnrichment] trackMetadata failed \(state.title) - \(state.artist): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        if shouldEnqueueDiscoveredAlbumMetadata {
            enqueuePart(.albumMetadata, for: request.trackID)
        }
        if shouldEnqueueDiscoveredAlbumArtwork {
            enqueuePart(.albumArtwork, for: request.trackID)
        }
        scheduleFlushIfNeeded(reason: "trackMetadata_result")
        finish(request, requeue: shouldRequeue)
    }

    private func completeArtistMetadata(
        request: ImportEnrichmentPartRequest,
        outcome: ImportArtistMetadataOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let detail):
            if await applyArtistMetadataDetail(detail, artist: state.artist) {
                Log.info(
                    "[ImportEnrichment] artistMetadata applied \(state.artist)",
                    category: .import
                )
            } else {
                Log.info(
                    "[ImportEnrichment] artistMetadata skipped \(state.artist) | no fields to fill",
                    category: .import
                )
            }
            state.setState(.completed, for: .artistMetadata)
        case .noResults:
            state.setState(.noResults, for: .artistMetadata)
            Log.warning(
                "[ImportEnrichment] artistMetadata no-results \(state.artist)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .artistMetadata, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .artistMetadata)
                Log.warning(
                    "[ImportEnrichment] artistMetadata failed \(state.artist) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .artistMetadata)
                Log.warning(
                    "[ImportEnrichment] artistMetadata failed \(state.artist): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        finish(request, requeue: shouldRequeue)
    }

    private func completeAlbumMetadata(
        request: ImportEnrichmentPartRequest,
        outcome: ImportAlbumMetadataOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let detail):
            if await applyAlbumMetadataDetail(detail, album: state.album, artist: state.artist) {
                Log.info(
                    "[ImportEnrichment] albumMetadata applied \(state.album)",
                    category: .import
                )
            } else {
                Log.info(
                    "[ImportEnrichment] albumMetadata skipped \(state.album) | no fields to fill",
                    category: .import
                )
            }
            state.setState(.completed, for: .albumMetadata)
        case .noResults:
            state.setState(.noResults, for: .albumMetadata)
            Log.warning(
                "[ImportEnrichment] albumMetadata no-results \(state.album)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .albumMetadata, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .albumMetadata)
                Log.warning(
                    "[ImportEnrichment] albumMetadata failed \(state.album) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .albumMetadata)
                Log.warning(
                    "[ImportEnrichment] albumMetadata failed \(state.album): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        finish(request, requeue: shouldRequeue)
    }

    private func completeArtistArtwork(
        request: ImportEnrichmentPartRequest,
        outcome: ImportArtistArtworkOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let data):
            if await applyArtistArtworkData(data, artist: state.artist) {
                Log.info(
                    "[ImportEnrichment] artistArtwork applied \(state.artist)",
                    category: .import
                )
            } else {
                Log.info(
                    "[ImportEnrichment] artistArtwork skipped \(state.artist) | already present",
                    category: .import
                )
            }
            state.setState(.completed, for: .artistArtwork)
        case .noResults:
            state.setState(.noResults, for: .artistArtwork)
            Log.warning(
                "[ImportEnrichment] artistArtwork no-results \(state.artist)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .artistArtwork, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .artistArtwork)
                Log.warning(
                    "[ImportEnrichment] artistArtwork failed \(state.artist) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .artistArtwork)
                Log.warning(
                    "[ImportEnrichment] artistArtwork failed \(state.artist): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        finish(request, requeue: shouldRequeue)
    }

    private func completeAlbumArtwork(
        request: ImportEnrichmentPartRequest,
        outcome: ImportAlbumArtworkOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let data):
            if await applyAlbumArtworkData(data, album: state.album, artist: state.artist) {
                Log.info(
                    "[ImportEnrichment] albumArtwork applied \(state.album)",
                    category: .import
                )
            } else {
                Log.info(
                    "[ImportEnrichment] albumArtwork skipped \(state.album) | already present",
                    category: .import
                )
            }
            state.setState(.completed, for: .albumArtwork)
        case .noResults:
            state.setState(.noResults, for: .albumArtwork)
            Log.warning(
                "[ImportEnrichment] albumArtwork no-results \(state.album)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .albumArtwork, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .albumArtwork)
                Log.warning(
                    "[ImportEnrichment] albumArtwork failed \(state.album) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .albumArtwork)
                Log.warning(
                    "[ImportEnrichment] albumArtwork failed \(state.album): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        finish(request, requeue: shouldRequeue)
    }

    private func shouldRetry(part: ImportEnrichmentPart, state: ImportEnrichmentItemState) -> Bool {
        state.attempts(for: part) < maxAttemptsPerPart
    }

    private func bufferFlushPatch(
        trackID: UUID,
        title: String,
        artist: String,
        mutate: (inout PendingTrackEnrichmentPatch) -> Void
    ) {
        var patch = pendingFlushPatches[trackID] ?? PendingTrackEnrichmentPatch(trackID: trackID)
        mutate(&patch)
        pendingFlushPatches[trackID] = patch
        Log.info(
            "[ImportEnrichment] batch buffered \(title) - \(artist) | pendingTracks=\(pendingFlushPatches.count)",
            category: .import
        )
    }

    private func scheduleFlushIfNeeded(reason: String) {
        guard pendingFlushPatches.isEmpty == false else { return }

        if pendingFlushPatches.count >= flushBatchSize {
            flushTask?.cancel()
            flushTask = nil
            Task { @MainActor in
                await flushBufferedUpdates(reason: "threshold:\(reason)")
            }
            return
        }

        if queue.isEmpty && runningRequests.isEmpty {
            flushTask?.cancel()
            flushTask = nil
            Task { @MainActor in
                await flushBufferedUpdates(reason: "idle:\(reason)")
            }
            return
        }

        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: flushDebounceNanoseconds)
            await flushBufferedUpdates(reason: "debounce:\(reason)")
        }
    }

    private func flushBufferedUpdates(reason: String) async {
        guard isFlushing == false else { return }
        guard pendingFlushPatches.isEmpty == false else { return }

        isFlushing = true
        flushTask?.cancel()
        flushTask = nil

        let patches = pendingFlushPatches
        let trackIDs = Array(patches.keys).sorted { $0.uuidString < $1.uuidString }
        Log.info(
            "[ImportEnrichment] batch flush start reason=\(reason) tracks=\(trackIDs.count)",
            category: .import
        )

        struct PendingRevert {
            let lyrics: String?
            let artworkData: Data?
            let album: String
            let userDescription: String
            let genreTags: [String]
            let language: String
            let labelOrCompany: String
            let releaseDate: Date?
            let qqMusicSongMid: String?
        }

        var touchedTracks: [Track] = []
        var revertByTrackID: [UUID: PendingRevert] = [:]
        var effectivePatches: [UUID: PendingTrackEnrichmentPatch] = [:]

        for trackID in trackIDs {
            guard let track = trackByID[trackID], let patch = patches[trackID] else { continue }
            var effectivePatch = patch
            revertByTrackID[trackID] = PendingRevert(
                lyrics: track.ttmlLyricText,
                artworkData: track.artworkData,
                album: track.album,
                userDescription: track.userDescription,
                genreTags: track.genreTags,
                language: track.language,
                labelOrCompany: track.labelOrCompany,
                releaseDate: track.releaseDate,
                qqMusicSongMid: track.qqMusicSongMid
            )

            if patch.lyricShouldFlush {
                if track.ttmlLyricText == nil, let ttml = patch.ttmlLyricText {
                    track.ttmlLyricText = ttml
                } else {
                    effectivePatch.ttmlLyricText = nil
                    effectivePatch.lyricShouldFlush = false
                }
            }
            if patch.coverShouldFlush {
                if track.artworkData == nil, let artworkData = patch.artworkData {
                    track.artworkData = artworkData
                } else {
                    effectivePatch.artworkData = nil
                    effectivePatch.coverShouldFlush = false
                }
            }
            if patch.trackMetadataShouldFlush {
                var hasMetadataFieldToFlush = false
                if let album = patch.album {
                    if track.album == album || MetadataDetailApplicator.shouldFillMissingAlbum(track.album) {
                        track.album = album
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.album = nil
                    }
                }
                if let desc = patch.userDescription {
                    if track.userDescription == desc || track.userDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        track.userDescription = desc
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.userDescription = nil
                    }
                }
                if let tags = patch.genreTags {
                    if track.genreTags == tags || track.genreTags.isEmpty {
                        track.genreTags = tags
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.genreTags = nil
                    }
                }
                if let lang = patch.language {
                    if track.language == lang || track.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        track.language = lang
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.language = nil
                    }
                }
                if let label = patch.labelOrCompany {
                    if track.labelOrCompany == label || track.labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        track.labelOrCompany = label
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.labelOrCompany = nil
                    }
                }
                if let date = patch.releaseDate {
                    if track.releaseDate == date || track.releaseDate == nil {
                        track.releaseDate = date
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.releaseDate = nil
                    }
                }
                if let mid = patch.qqMusicSongMid {
                    if track.qqMusicSongMid == mid || (track.qqMusicSongMid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                        track.qqMusicSongMid = mid
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.qqMusicSongMid = nil
                    }
                }
                effectivePatch.trackMetadataShouldFlush = hasMetadataFieldToFlush
            }

            let hasEffectiveFlush = effectivePatch.lyricShouldFlush
                || effectivePatch.coverShouldFlush
                || effectivePatch.trackMetadataShouldFlush

            if hasEffectiveFlush {
                touchedTracks.append(track)
                effectivePatches[trackID] = effectivePatch
            } else {
                if var state = itemStates[trackID] {
                    if patch.lyricShouldFlush, state.state(for: .lyrics) == .flushPending {
                        state.setState(.skipped, for: .lyrics)
                    }
                    if patch.coverShouldFlush, state.state(for: .cover) == .flushPending {
                        state.setState(.skipped, for: .cover)
                    }
                    if patch.trackMetadataShouldFlush, state.state(for: .trackMetadata) == .flushPending {
                        state.setState(.skipped, for: .trackMetadata)
                    }
                    itemStates[trackID] = state
                    if state.isTerminal {
                        trackByID[trackID] = nil
                    }
                }
                pendingFlushPatches.removeValue(forKey: trackID)
            }
        }

        guard !touchedTracks.isEmpty else {
            refreshProgress()
            Log.info(
                "[ImportEnrichment] batch flush complete reason=\(reason) persisted=0 failed=0",
                category: .import
            )
            isFlushing = false
            return
        }

        let metaOnlyTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.trackMetadataShouldFlush && !patch.lyricShouldFlush && !patch.coverShouldFlush
        }
        let lyricOnlyTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.lyricShouldFlush && !patch.coverShouldFlush && !patch.trackMetadataShouldFlush
        }
        let coverOnlyTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return !patch.lyricShouldFlush && patch.coverShouldFlush && !patch.trackMetadataShouldFlush
        }
        let lyricAndCoverTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.lyricShouldFlush && patch.coverShouldFlush && !patch.trackMetadataShouldFlush
        }
        let metaAndLyricTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.trackMetadataShouldFlush && patch.lyricShouldFlush && !patch.coverShouldFlush
        }
        let metaAndCoverTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.trackMetadataShouldFlush && !patch.lyricShouldFlush && patch.coverShouldFlush
        }
        let metaLyricAndCoverTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.trackMetadataShouldFlush && patch.lyricShouldFlush && patch.coverShouldFlush
        }

        var persistedTrackIDs: Set<UUID> = []
        var failedTrackIDs: Set<UUID> = []

        if !metaOnlyTracks.isEmpty {
            let result = await repository.persistTrackMetaOnly(metaOnlyTracks, reason: "importEnrichmentMetadata")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !lyricOnlyTracks.isEmpty {
            let result = await repository.persistTrackMetaAndLyrics(lyricOnlyTracks, reason: "importEnrichmentLyrics")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !coverOnlyTracks.isEmpty {
            let result = await repository.persistTrackMetaAndArtwork(coverOnlyTracks, reason: "importEnrichmentArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !lyricAndCoverTracks.isEmpty {
            let result = await repository.persistTrackMetaLyricsAndArtwork(lyricAndCoverTracks, reason: "importEnrichmentLyricsArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !metaAndLyricTracks.isEmpty {
            let result = await repository.persistTrackMetaAndLyrics(metaAndLyricTracks, reason: "importEnrichmentMetadataLyrics")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !metaAndCoverTracks.isEmpty {
            let result = await repository.persistTrackMetaAndArtwork(metaAndCoverTracks, reason: "importEnrichmentMetadataArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !metaLyricAndCoverTracks.isEmpty {
            let result = await repository.persistTrackMetaLyricsAndArtwork(metaLyricAndCoverTracks, reason: "importEnrichmentMetadataLyricsArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }

        for trackID in persistedTrackIDs {
            guard let patch = effectivePatches[trackID], var state = itemStates[trackID] else { continue }
            if patch.lyricShouldFlush, state.state(for: .lyrics) == .flushPending {
                state.setState(.completed, for: .lyrics)
            }
            if patch.coverShouldFlush, state.state(for: .cover) == .flushPending {
                state.setState(.completed, for: .cover)
            }
            if patch.trackMetadataShouldFlush, state.state(for: .trackMetadata) == .flushPending {
                state.setState(.completed, for: .trackMetadata)
            }
            itemStates[trackID] = state
            pendingFlushPatches.removeValue(forKey: trackID)
            if state.isTerminal {
                trackByID[trackID] = nil
            }
        }

        for trackID in failedTrackIDs {
            guard let patch = effectivePatches[trackID], let revert = revertByTrackID[trackID] else { continue }
            if let track = trackByID[trackID] {
                track.ttmlLyricText = revert.lyrics
                track.artworkData = revert.artworkData
                track.album = revert.album
                track.userDescription = revert.userDescription
                track.genreTags = revert.genreTags
                track.language = revert.language
                track.labelOrCompany = revert.labelOrCompany
                track.releaseDate = revert.releaseDate
                track.qqMusicSongMid = revert.qqMusicSongMid
            }
            if var state = itemStates[trackID] {
                if patch.lyricShouldFlush, state.state(for: .lyrics) == .flushPending {
                    state.setState(.failed, for: .lyrics)
                }
                if patch.coverShouldFlush, state.state(for: .cover) == .flushPending {
                    state.setState(.failed, for: .cover)
                }
                if patch.trackMetadataShouldFlush, state.state(for: .trackMetadata) == .flushPending {
                    state.setState(.failed, for: .trackMetadata)
                }
                itemStates[trackID] = state
                if state.isTerminal {
                    trackByID[trackID] = nil
                }
            }
            pendingFlushPatches.removeValue(forKey: trackID)
        }

        refreshProgress()
        Log.info(
            "[ImportEnrichment] batch flush complete reason=\(reason) persisted=\(persistedTrackIDs.count) failed=\(failedTrackIDs.count)",
            category: .import
        )
        if !persistedTrackIDs.isEmpty {
            Log.info(
                "[ImportEnrichment] visible refresh notified for \(persistedTrackIDs.count) persisted tracks",
                category: .import
            )
            Log.info(
                "[ImportEnrichmentReload] flush success with \(persistedTrackIDs.count) updated tracks",
                category: .import
            )
        }
        if !failedTrackIDs.isEmpty {
            Log.warning(
                "[ImportEnrichment] persistence flush failed for \(failedTrackIDs.count) tracks",
                category: .import
            )
        }

        isFlushing = false

        if pendingFlushPatches.isEmpty == false {
            scheduleFlushIfNeeded(reason: "post_flush")
        } else {
            releaseCompletedSessionIfIdle()
        }
    }

    private func releaseCompletedSessionIfIdle() {
        guard queue.isEmpty, runningRequests.isEmpty, pendingFlushPatches.isEmpty, isFlushing == false
        else { return }

        trackByID.removeAll()
        queuedRequests.removeAll()
        runningRequests.removeAll()

        guard itemStates.values.allSatisfy(\.isTerminal) else { return }
        itemStates.removeAll()
        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: 0,
            completedCount: 0,
            failedCount: 0,
            pendingLyricsCount: 0,
            pendingCoverCount: 0,
            pendingTrackMetadataCount: 0,
            pendingArtistMetadataCount: 0,
            pendingAlbumMetadataCount: 0,
            pendingArtistArtworkCount: 0,
            pendingAlbumArtworkCount: 0,
            runningCount: 0,
            flushPendingCount: 0
        )
        Log.info("[ImportEnrichment] idle session released", category: .import)
    }

    private func diagnoseStalledQueue(context: String) {
        if queue.isEmpty == false && runningRequests.isEmpty {
            Log.warning(
                "[ImportEnrichment] queue stalled after \(context) | queued=\(queue.count) running=0",
                category: .import
            )
        }
    }

    private func finish(_ request: ImportEnrichmentPartRequest, requeue: Bool = false) {
        runningRequests.remove(request)
        activeTasks[request] = nil

        if requeue {
            queue.append(request)
            queuedRequests.insert(request)
        }

        Log.debug(
            "[ImportEnrichment] finish \(request.part.rawValue) | requeue=\(requeue) queued=\(queue.count) running=\(runningRequests.count)",
            category: .import
        )

        refreshProgress()

        if let state = itemStates[request.trackID], state.isTerminal {
            trackByID[request.trackID] = nil
        }

        if queue.isEmpty && runningRequests.isEmpty {
            scheduleFlushIfNeeded(reason: "queue_idle")
            releaseCompletedSessionIfIdle()
        }
        drainQueueIfPossible()
    }
}
