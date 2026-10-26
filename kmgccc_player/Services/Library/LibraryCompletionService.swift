//
//  LibraryCompletionService.swift
//  myPlayer2
//
//  Manual library-wide metadata and lyrics completion.
//

import Foundation
import Observation

struct LibraryCompletionOptions: Equatable, Sendable {
    var fillMetadata = true
    var fillLyrics = true
    var fillMotionArtwork = true

    var hasSelection: Bool {
        fillMetadata || fillLyrics || fillMotionArtwork
    }

    var selectedItemTitles: [String] {
        var titles: [String] = []
        if fillMetadata {
            titles.append("元数据、封面、专辑信息与艺人信息")
        }
        if fillLyrics {
            titles.append("缺失歌词")
        }
        if fillMotionArtwork { titles.append("动态封面") }
        return titles
    }
}

struct LibraryCompletionProgressEvent: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let detail: String
}

enum LibraryCompletionPhase: String, Sendable {
    case idle
    case scanning
    case metadata
    case lyrics
    case motionArtwork
    case cancelled
    case completed

    var title: String {
        switch self {
        case .idle: return "等待开始"
        case .scanning: return "正在扫描本地曲库"
        case .metadata: return "正在补全缺失元数据"
        case .lyrics: return "正在补全缺失歌词"
        case .motionArtwork: return "正在按专辑补全动态封面"
        case .cancelled: return "已取消"
        case .completed: return "已完成"
        }
    }
}

struct LibraryCompletionProgress: Sendable {
    let phase: LibraryCompletionPhase
    let processedCount: Int
    let totalCount: Int
    let currentTrackTitle: String?
    let currentArtist: String?
    let currentAlbum: String?
    let currentTaskLabel: String?
    let recentEvents: [LibraryCompletionProgressEvent]
    let detail: String

    init(
        phase: LibraryCompletionPhase,
        processedCount: Int,
        totalCount: Int,
        currentTrackTitle: String?,
        currentArtist: String? = nil,
        currentAlbum: String? = nil,
        currentTaskLabel: String? = nil,
        recentEvents: [LibraryCompletionProgressEvent] = [],
        detail: String
    ) {
        self.phase = phase
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.currentTrackTitle = currentTrackTitle
        self.currentArtist = currentArtist
        self.currentAlbum = currentAlbum
        self.currentTaskLabel = currentTaskLabel
        self.recentEvents = recentEvents
        self.detail = detail
    }

    static let idle = LibraryCompletionProgress(
        phase: .idle,
        processedCount: 0,
        totalCount: 0,
        currentTrackTitle: nil,
        currentArtist: nil,
        currentAlbum: nil,
        currentTaskLabel: nil,
        recentEvents: [],
        detail: "等待开始"
    )

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(processedCount) / Double(totalCount)))
    }
}

struct LibraryCompletionFailure: Identifiable, Sendable {
    let id = UUID()
    let trackID: UUID?
    let title: String
    let reason: String
}

struct LibraryCompletionResult: Sendable {
    let processedTrackCount: Int
    let metadataItemsFilledCount: Int
    let lyricsFilledTrackCount: Int
    var motionArtworkAlbumCount = 0
    var motionArtworkTrackCount = 0
    let skippedExistingDataCount: Int
    let failureCount: Int
    let failures: [LibraryCompletionFailure]
    let updatedTrackIDs: [UUID]
    let cancelled: Bool
}

private enum LibraryCompletionCachedCover {
    case found(Data)
    case missing(String)
}

private struct TrackMetadataFieldSnapshot {
    let album: String
    let userDescription: String
    let genreTags: [String]
    let language: String
    let labelOrCompany: String
    let releaseDate: Date?
    let qqMusicSongMid: String?

    init(_ track: Track) {
        album = track.album
        userDescription = track.userDescription
        genreTags = track.genreTags
        language = track.language
        labelOrCompany = track.labelOrCompany
        releaseDate = track.releaseDate
        qqMusicSongMid = track.qqMusicSongMid
    }

    func filledFieldCount(comparedWith after: TrackMetadataFieldSnapshot) -> Int {
        var count = 0
        if MetadataDetailApplicator.shouldFillMissingAlbum(album),
           !MetadataDetailApplicator.shouldFillMissingAlbum(after.album) {
            count += 1
        }
        if Self.isBlank(userDescription), !Self.isBlank(after.userDescription) { count += 1 }
        if genreTags.isEmpty, !after.genreTags.isEmpty { count += 1 }
        if Self.isBlank(language), !Self.isBlank(after.language) { count += 1 }
        if Self.isBlank(labelOrCompany), !Self.isBlank(after.labelOrCompany) { count += 1 }
        if releaseDate == nil, after.releaseDate != nil { count += 1 }
        if Self.isBlank(qqMusicSongMid), !Self.isBlank(after.qqMusicSongMid) { count += 1 }
        return count
    }

    func existingFieldCount() -> Int {
        var count = 0
        if !MetadataDetailApplicator.shouldFillMissingAlbum(album) { count += 1 }
        if !Self.isBlank(userDescription) { count += 1 }
        if !genreTags.isEmpty { count += 1 }
        if !Self.isBlank(language) { count += 1 }
        if !Self.isBlank(labelOrCompany) { count += 1 }
        if releaseDate != nil { count += 1 }
        if !Self.isBlank(qqMusicSongMid) { count += 1 }
        return count
    }

    func hasMissingFields() -> Bool {
        MetadataDetailApplicator.shouldFillMissingAlbum(album)
            || Self.isBlank(userDescription)
            || genreTags.isEmpty
            || Self.isBlank(language)
            || Self.isBlank(labelOrCompany)
            || releaseDate == nil
            || Self.isBlank(qqMusicSongMid)
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

private struct ArtistMetadataFieldSnapshot {
    let description: String
    let genreTags: [String]
    let region: String
    let foreignName: String
    let qqMusicSingerMid: String?
    let hasArtwork: Bool

    init(_ entry: ArtistEntry) {
        description = entry.description
        genreTags = entry.genreTags
        region = entry.region
        foreignName = entry.foreignName
        qqMusicSingerMid = entry.qqMusicSingerMid
        hasArtwork = entry.hasArtwork
    }

    func existingFieldCount() -> Int {
        var count = 0
        if !Self.isBlank(description) { count += 1 }
        if !genreTags.isEmpty { count += 1 }
        if !Self.isBlank(region) { count += 1 }
        if !Self.isBlank(foreignName) { count += 1 }
        if !Self.isBlank(qqMusicSingerMid) { count += 1 }
        if hasArtwork { count += 1 }
        return count
    }

    func metadataMissingCount() -> Int {
        var count = 0
        if Self.isBlank(description) { count += 1 }
        if genreTags.isEmpty { count += 1 }
        if Self.isBlank(region) { count += 1 }
        if Self.isBlank(foreignName) { count += 1 }
        if Self.isBlank(qqMusicSingerMid) { count += 1 }
        return count
    }

    func filledMetadataCount(comparedWith after: ArtistMetadataFieldSnapshot) -> Int {
        var count = 0
        if Self.isBlank(description), !Self.isBlank(after.description) { count += 1 }
        if genreTags.isEmpty, !after.genreTags.isEmpty { count += 1 }
        if Self.isBlank(region), !Self.isBlank(after.region) { count += 1 }
        if Self.isBlank(foreignName), !Self.isBlank(after.foreignName) { count += 1 }
        if Self.isBlank(qqMusicSingerMid), !Self.isBlank(after.qqMusicSingerMid) { count += 1 }
        return count
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

private struct AlbumMetadataFieldSnapshot {
    let description: String
    let hasYear: Bool
    let albumType: String
    let genreTags: [String]
    let language: String
    let labelOrCompany: String
    let qqMusicAlbumMid: String?
    let hasArtwork: Bool

    init(_ entry: AlbumEntry) {
        description = entry.description
        hasYear = entry.year != nil || entry.releaseYear != nil || entry.releaseDate != nil
        albumType = entry.albumType
        genreTags = entry.genreTags
        language = entry.language
        labelOrCompany = entry.labelOrCompany
        qqMusicAlbumMid = entry.qqMusicAlbumMid
        hasArtwork = entry.hasArtwork
    }

    func existingFieldCount() -> Int {
        var count = 0
        if !Self.isBlank(description) { count += 1 }
        if hasYear { count += 1 }
        if !Self.isBlank(albumType) { count += 1 }
        if !genreTags.isEmpty { count += 1 }
        if !Self.isBlank(language) { count += 1 }
        if !Self.isBlank(labelOrCompany) { count += 1 }
        if !Self.isBlank(qqMusicAlbumMid) { count += 1 }
        if hasArtwork { count += 1 }
        return count
    }

    func metadataMissingCount() -> Int {
        var count = 0
        if Self.isBlank(description) { count += 1 }
        if !hasYear { count += 1 }
        if Self.isBlank(albumType) { count += 1 }
        if genreTags.isEmpty { count += 1 }
        if Self.isBlank(language) { count += 1 }
        if Self.isBlank(labelOrCompany) { count += 1 }
        if Self.isBlank(qqMusicAlbumMid) { count += 1 }
        return count
    }

    func filledMetadataCount(comparedWith after: AlbumMetadataFieldSnapshot) -> Int {
        var count = 0
        if Self.isBlank(description), !Self.isBlank(after.description) { count += 1 }
        if !hasYear, after.hasYear { count += 1 }
        if Self.isBlank(albumType), !Self.isBlank(after.albumType) { count += 1 }
        if genreTags.isEmpty, !after.genreTags.isEmpty { count += 1 }
        if Self.isBlank(language), !Self.isBlank(after.language) { count += 1 }
        if Self.isBlank(labelOrCompany), !Self.isBlank(after.labelOrCompany) { count += 1 }
        if Self.isBlank(qqMusicAlbumMid), !Self.isBlank(after.qqMusicAlbumMid) { count += 1 }
        return count
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

@MainActor
@Observable
final class LibraryCompletionService {
    private static let maxProgressEventCount = 4
    private static let maxTrackCoverCacheEntryCount = 32
    private static let maxTrackCoverCacheBytes = 16 * 1_024 * 1_024

    var progress: LibraryCompletionProgress = .idle

    @ObservationIgnored private let libraryVM: LibraryViewModel
    @ObservationIgnored private let qqMusicCoverService: QQMusicCoverService
    @ObservationIgnored private let lyricsSearchCoordinator: LyricsSearchCoordinator
    @ObservationIgnored private let amllDBService: AMLLDBService
    @ObservationIgnored private let musicEnrichmentService: MusicEnrichmentService?
    @ObservationIgnored private var processedArtistKeys: Set<String> = []
    @ObservationIgnored private var processedAlbumKeys: Set<String> = []
    @ObservationIgnored private var artistEntryCache: [String: ArtistEntry] = [:]
    @ObservationIgnored private var albumEntryCache: [String: AlbumEntry] = [:]
    @ObservationIgnored private var trackCoverCache: [String: LibraryCompletionCachedCover] = [:]
    @ObservationIgnored private var trackCoverCacheBytes = 0
    @ObservationIgnored private var progressEvents: [LibraryCompletionProgressEvent] = []
    @ObservationIgnored private var stopRequested = false

    /// Stops after the songs in flight are saved, so nothing found is lost.
    func requestStop() { stopRequested = true }

    private var shouldStop: Bool { stopRequested || Task.isCancelled }

    init(
        libraryVM: LibraryViewModel,
        qqMusicCoverService: QQMusicCoverService,
        lyricsSearchCoordinator: LyricsSearchCoordinator,
        amllDBService: AMLLDBService,
        musicEnrichmentService: MusicEnrichmentService? = nil
    ) {
        self.libraryVM = libraryVM
        self.qqMusicCoverService = qqMusicCoverService
        self.lyricsSearchCoordinator = lyricsSearchCoordinator
        self.amllDBService = amllDBService
        self.musicEnrichmentService = musicEnrichmentService
    }

    func completeLibrary(
        options: LibraryCompletionOptions,
        progress progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async -> LibraryCompletionResult {
        clearCompletionCaches()
        stopRequested = false
        defer { clearCompletionCaches() }
        artistEntryCache = Dictionary(uniqueKeysWithValues: libraryVM.artistEntries.map { ($0.canonicalName, $0) })
        albumEntryCache = Dictionary(uniqueKeysWithValues: libraryVM.albumEntries.map { ($0.canonicalKey, $0) })

        let tracks = libraryVM.allTracks.sorted {
            if $0.title.localizedStandardCompare($1.title) == .orderedSame {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        var metadataItemsFilledCount = 0
        var lyricsFilledTrackCount = 0
        var skippedExistingDataCount = 0
        var failures: [LibraryCompletionFailure] = []
        var updatedTrackIDs: Set<UUID> = []
        var processedTrackCount = 0
        var motion = EnrichmentOutcome()

        await report(
            LibraryCompletionProgress(
                phase: .scanning,
                processedCount: 0,
                totalCount: tracks.count,
                currentTrackTitle: nil,
                currentArtist: nil,
                currentAlbum: nil,
                currentTaskLabel: nil,
                detail: "已读取本地曲库，共 \(tracks.count) 首"
            ),
            progressHandler
        )

        // Song information and lyrics come from per-song searches; motion
        // artwork alone needs no pass over every song.
        for (index, track) in tracks.enumerated() where options.fillMetadata || options.fillLyrics {
            if shouldStop { break }

            let currentTrack = libraryVM.allTracks.first { $0.id == track.id } ?? track
            var trackUpdated = false

            if options.fillMetadata {
                await report(
                    LibraryCompletionProgress(
                        phase: .metadata,
                        processedCount: index,
                        totalCount: tracks.count,
                        currentTrackTitle: currentTrack.title,
                        currentArtist: currentTrack.artist,
                        currentAlbum: currentTrack.album,
                        currentTaskLabel: "歌曲信息",
                        detail: "正在检查歌曲信息"
                    ),
                    progressHandler
                )
                let outcome = await completeMetadata(
                    for: currentTrack,
                    index: index,
                    totalCount: tracks.count,
                    progressHandler: progressHandler
                )
                metadataItemsFilledCount += outcome.filledCount
                skippedExistingDataCount += outcome.skippedExistingCount
                failures.append(contentsOf: outcome.failures)
                trackUpdated = trackUpdated || outcome.trackUpdated
            }

            if options.fillLyrics, !shouldStop {
                await report(
                    LibraryCompletionProgress(
                        phase: .lyrics,
                        processedCount: index,
                        totalCount: tracks.count,
                        currentTrackTitle: currentTrack.title,
                        currentArtist: currentTrack.artist,
                        currentAlbum: currentTrack.album,
                        currentTaskLabel: "歌词",
                        detail: "正在检查歌词"
                    ),
                    progressHandler
                )
                let outcome = await completeLyrics(
                    for: currentTrack,
                    index: index,
                    totalCount: tracks.count,
                    progressHandler: progressHandler
                )
                lyricsFilledTrackCount += outcome.filled ? 1 : 0
                skippedExistingDataCount += outcome.skippedExisting ? 1 : 0
                failures.append(contentsOf: outcome.failure.map { [$0] } ?? [])
                trackUpdated = trackUpdated || outcome.filled
            }

            if trackUpdated {
                updatedTrackIDs.insert(currentTrack.id)
            }
            processedTrackCount = index + 1

            await report(
                LibraryCompletionProgress(
                    phase: options.fillLyrics ? .lyrics : .metadata,
                    processedCount: index + 1,
                    totalCount: tracks.count,
                    currentTrackTitle: currentTrack.title,
                    currentArtist: currentTrack.artist,
                    currentAlbum: currentTrack.album,
                    currentTaskLabel: nil,
                    detail: "已处理 \(index + 1) / \(tracks.count)"
                ),
                progressHandler
            )
        }

        if !(options.fillMetadata || options.fillLyrics) { processedTrackCount = tracks.count }
        if let musicEnrichmentService, options.fillMetadata || options.fillMotionArtwork, !shouldStop {
            motion = await completeEnrichment(
                tracks: tracks, options: options, service: musicEnrichmentService, progressHandler: progressHandler
            )
            updatedTrackIDs.formUnion(motion.filledTrackIDs)
            failures.append(contentsOf: motion.failures)
        }

        // Whatever was found before a stop is already saved; show it.
        if !updatedTrackIDs.isEmpty {
            libraryVM.notifyTrackAuxiliaryDataChanged(trackIDs: Array(updatedTrackIDs))
        }
        await libraryVM.refresh()

        let stopped = shouldStop
        if stopped {
            await reportCancelled(processedCount: processedTrackCount, totalCount: tracks.count, progressHandler)
        } else {
            await report(
                LibraryCompletionProgress(
                    phase: .completed,
                    processedCount: tracks.count,
                    totalCount: tracks.count,
                    currentTrackTitle: nil,
                    currentArtist: nil,
                    currentAlbum: nil,
                    currentTaskLabel: nil,
                    detail: "全库补全任务完成"
                ),
                progressHandler
            )
        }

        var result = makeResult(
            processedTrackCount: processedTrackCount,
            metadataItemsFilledCount: metadataItemsFilledCount,
            lyricsFilledTrackCount: lyricsFilledTrackCount,
            skippedExistingDataCount: skippedExistingDataCount,
            failures: failures,
            updatedTrackIDs: updatedTrackIDs,
            cancelled: stopped
        )
        result.motionArtworkAlbumCount = motion.motionAlbumCount
        result.motionArtworkTrackCount = motion.motionTrackCount
        return result
    }

    private struct MetadataOutcome {
        var filledCount = 0
        var skippedExistingCount = 0
        var failures: [LibraryCompletionFailure] = []
        var trackUpdated = false
    }

    private struct LyricsOutcome {
        var filled = false
        var skippedExisting = false
        var failure: LibraryCompletionFailure?
    }

    private struct EnrichmentOutcome {
        var filledTrackIDs: Set<UUID> = []
        var failures: [LibraryCompletionFailure] = []
        var motionAlbumCount = 0
        var motionTrackCount = 0
    }

    /// One song, or one album for motion artwork.
    nonisolated private struct EnrichmentItem: Sendable {
        var trackID: UUID
        var queries: [MusicEnrichmentQuery]
        var title: String
        var artist: String
        var album: String
    }

    /// A pass the user started runs several items at once; the idle queue stays serial.
    private static let parallelLimit = 4

    /// Catalog details for every song, then motion artwork once per album.
    private func completeEnrichment(
        tracks: [Track],
        options: LibraryCompletionOptions,
        service: MusicEnrichmentService,
        progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async -> EnrichmentOutcome {
        var outcome = EnrichmentOutcome()
        let motionBefore = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.motionArtwork) })
        if options.fillMetadata {
            let items = tracks.map { track in
                EnrichmentItem(trackID: track.id, queries: [MusicEnrichmentWorkSource.query(track)],
                    title: track.title, artist: track.artist, album: track.album)
            }
            outcome.failures += await runParallel(items, phase: .metadata, label: "歌曲资料", progressHandler: progressHandler) { item in
                _ = try await service.completeIndependently(query: item.queries[0], includeMotion: false)
            }
        }
        if options.fillMotionArtwork, !shouldStop {
            var order: [String] = []
            var albums: [String: [Track]] = [:]
            for track in tracks {
                let key = MusicEnrichmentWorkSource.albumKey(track) ?? "track:\(track.id.uuidString)"
                if albums[key] == nil { order.append(key) }
                albums[key, default: []].append(track)
            }
            let items = order.compactMap { albums[$0] }.compactMap { songs -> EnrichmentItem? in
                guard let first = songs.first else { return nil }
                return EnrichmentItem(trackID: first.id, queries: songs.map(MusicEnrichmentWorkSource.query),
                    title: first.album.isEmpty ? first.title : first.album, artist: first.albumArtist ?? first.artist, album: first.album)
            }
            outcome.failures += await runParallel(items, phase: .motionArtwork, label: "动态封面", progressHandler: progressHandler) { item in
                _ = try await service.completeAlbumMotion(queries: item.queries)
            }
        }
        let current = Dictionary(libraryVM.allTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = tracks.compactMap { current[$0.id] }.filter { $0.motionArtwork != motionBefore[$0.id] ?? nil }
        let gained = changed.filter { $0.motionArtwork != nil && motionBefore[$0.id] ?? nil == nil }
        outcome.filledTrackIDs = Set(changed.map(\.id))
        outcome.motionTrackCount = gained.count
        outcome.motionAlbumCount = Set(gained.map { MusicEnrichmentWorkSource.albumKey($0) ?? $0.id.uuidString }).count
        return outcome
    }

    private func runParallel(
        _ items: [EnrichmentItem],
        phase: LibraryCompletionPhase,
        label: String,
        progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void,
        work: @escaping @Sendable @MainActor (EnrichmentItem) async throws -> Void
    ) async -> [LibraryCompletionFailure] {
        var failures: [LibraryCompletionFailure] = []
        var finished = 0
        await withTaskGroup(of: (EnrichmentItem, String?).self) { group in
            var pending = items.makeIterator()
            for _ in 0..<Self.parallelLimit {
                guard let item = pending.next() else { break }
                group.addTask { await Self.attempt(item, label: label, work) }
            }
            for await (item, error) in group {
                finished += 1
                if let error {
                    failures.append(LibraryCompletionFailure(trackID: item.trackID, title: item.title, reason: error))
                }
                await report(LibraryCompletionProgress(
                    phase: phase, processedCount: finished, totalCount: items.count,
                    currentTrackTitle: item.title, currentArtist: item.artist, currentAlbum: item.album,
                    currentTaskLabel: label, detail: "已处理 \(finished) / \(items.count)"
                ), progressHandler)
                if !shouldStop, let next = pending.next() {
                    group.addTask { await Self.attempt(next, label: label, work) }
                }
            }
        }
        return failures
    }

    /// Nothing found is not a failure; only trouble the user can act on is listed.
    private static func attempt(
        _ item: EnrichmentItem, label: String, _ work: @Sendable @MainActor (EnrichmentItem) async throws -> Void
    ) async -> (EnrichmentItem, String?) {
        do {
            try await work(item)
            return (item, nil)
        } catch is CancellationError {
            return (item, nil)
        } catch {
            return (item, MusicEnrichmentHelperError.isRetryable(error) ? "\(label)联网失败，稍后再试" : "暂未补全\(label)")
        }
    }

    private func metadataEventDetail(filledCount: Int) -> String {
        filledCount > 0 ? "补全 \(filledCount) 项内容" : "已找到可用内容"
    }

    private func completeMetadata(
        for track: Track,
        index: Int,
        totalCount: Int,
        progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async -> MetadataOutcome {
        var outcome = MetadataOutcome()
        let artworkAlreadyPresent = await trackHasArtwork(track)
        let beforeTrack = TrackMetadataFieldSnapshot(track)
        outcome.skippedExistingCount += beforeTrack.existingFieldCount()
        if artworkAlreadyPresent {
            outcome.skippedExistingCount += 1
        }

        if beforeTrack.hasMissingFields() {
            switch await MetadataEnrichmentWorker.fetchTrackMetadata(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration > 0 ? track.duration : nil
            ) {
            case .completed(let detail):
                guard !Task.isCancelled else { return outcome }
                let changed = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: track)
                if changed {
                    let filled = beforeTrack.filledFieldCount(comparedWith: TrackMetadataFieldSnapshot(track))
                    outcome.filledCount += filled
                    outcome.trackUpdated = true
                    await libraryVM.saveTrackEdits(track, mode: .metaOnly, reason: "manualLibraryCompletionMetadata")
                    await recordProgressEvent(
                        title: "歌曲信息",
                        detail: metadataEventDetail(filledCount: filled),
                        phase: .metadata,
                        index: index,
                        totalCount: totalCount,
                        track: track,
                        taskLabel: "歌曲信息",
                        progressHandler
                    )
                }
            case .noResults:
                outcome.failures.append(failure(track: track, reason: "暂未找到歌曲信息"))
            case .failed(_):
                outcome.failures.append(failure(track: track, reason: "暂未补全歌曲信息"))
            }
        }

        if !artworkAlreadyPresent && track.artworkIsUserSelected != true {
            await reportTrackProgress(
                phase: .metadata,
                index: index,
                totalCount: totalCount,
                track: track,
                taskLabel: "封面",
                progressHandler
            )
            switch await coverData(for: track) {
            case .found(let data):
                guard !Task.isCancelled else { return outcome }
                let hasArtwork = await trackHasArtwork(track)
                if track.artworkIsUserSelected != true && !hasArtwork {
                    track.artworkData = data
                    track.artworkIsUserSelected = false
                    outcome.filledCount += 1
                    outcome.trackUpdated = true
                    await libraryVM.saveTrackEdits(track, mode: .metaAndArtwork, reason: "manualLibraryCompletionArtwork")
                    await recordProgressEvent(
                        title: "封面",
                        detail: "已找到歌曲封面",
                        phase: .metadata,
                        index: index,
                        totalCount: totalCount,
                        track: track,
                        taskLabel: "封面",
                        progressHandler
                    )
                } else {
                    outcome.skippedExistingCount += 1
                }
            case .missing(let reason):
                outcome.failures.append(failure(track: track, reason: reason))
            }
        }

        let artistResult = await completeArtistMetadataIfNeeded(
            for: track,
            index: index,
            totalCount: totalCount,
            progressHandler: progressHandler
        )
        outcome.filledCount += artistResult.filledCount
        outcome.skippedExistingCount += artistResult.skippedExistingCount
        outcome.failures.append(contentsOf: artistResult.failures)

        let albumResult = await completeAlbumMetadataIfNeeded(
            for: track,
            index: index,
            totalCount: totalCount,
            progressHandler: progressHandler
        )
        outcome.filledCount += albumResult.filledCount
        outcome.skippedExistingCount += albumResult.skippedExistingCount
        outcome.failures.append(contentsOf: albumResult.failures)

        return outcome
    }

    private func completeLyrics(
        for track: Track,
        index: Int,
        totalCount: Int,
        progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async -> LyricsOutcome {
        if !track.allowsAutomaticLyrics || trackHasLyrics(track) {
            return LyricsOutcome(filled: false, skippedExisting: true, failure: nil)
        }

        switch await ImportEnrichmentWorker.fetchLyrics(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration > 0 ? track.duration : nil,
            lyricsSearchCoordinator: lyricsSearchCoordinator,
            amllDBService: amllDBService
        ) {
        case .completed(let ttml):
            guard !Task.isCancelled else { return LyricsOutcome() }
            if track.allowsAutomaticLyrics && !trackHasLyrics(track) {
                track.ttmlLyricText = ttml
                await libraryVM.saveTrackEdits(track, mode: .metaAndLyrics, reason: "manualLibraryCompletionLyrics")
                await recordProgressEvent(
                    title: "歌词",
                    detail: "已找到歌词",
                    phase: .lyrics,
                    index: index,
                    totalCount: totalCount,
                    track: track,
                    taskLabel: "歌词",
                    progressHandler
                )
                return LyricsOutcome(filled: true, skippedExisting: false, failure: nil)
            }
            return LyricsOutcome(filled: false, skippedExisting: true, failure: nil)
        case .noResults:
            return LyricsOutcome(filled: false, skippedExisting: false, failure: failure(track: track, reason: "暂未找到歌词"))
        case .failed(_):
            return LyricsOutcome(filled: false, skippedExisting: false, failure: failure(track: track, reason: "暂未补全歌词"))
        }
    }

    private func completeArtistMetadataIfNeeded(
        for track: Track,
        index: Int,
        totalCount: Int,
        progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async -> MetadataOutcome {
        var outcome = MetadataOutcome()
        let canonical = LibraryNormalization.normalizeArtist(track.artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil),
              !processedArtistKeys.contains(canonical)
        else { return outcome }
        processedArtistKeys.insert(canonical)

        var entry = artistEntry(for: track.artist)
        let before = ArtistMetadataFieldSnapshot(entry)
        outcome.skippedExistingCount += before.existingFieldCount()

        if before.metadataMissingCount() > 0 {
            await reportTrackProgress(
                phase: .metadata,
                index: index,
                totalCount: totalCount,
                track: track,
                taskLabel: "艺人",
                progressHandler
            )
            switch await MetadataEnrichmentWorker.fetchArtistMetadata(name: entry.displayName) {
            case .completed(let detail):
                guard !Task.isCancelled else { return outcome }
                entry = libraryVM.artistEntries.first { $0.canonicalName == canonical } ?? entry
                let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
                if result.changed {
                    let filled = before.filledMetadataCount(comparedWith: ArtistMetadataFieldSnapshot(result.value))
                    entry = result.value
                    artistEntryCache[canonical] = entry
                    outcome.filledCount += filled
                    await libraryVM.saveArtistEntry(entry)
                    await recordProgressEvent(
                        title: "艺人",
                        detail: "\(entry.displayName)  \(metadataEventDetail(filledCount: filled))",
                        phase: .metadata,
                        index: index,
                        totalCount: totalCount,
                        track: track,
                        taskLabel: "艺人",
                        progressHandler
                    )
                }
            case .noResults:
                outcome.failures.append(failure(track: track, reason: "暂未找到艺人信息：\(entry.displayName)"))
            case .failed(_):
                outcome.failures.append(failure(track: track, reason: "暂未补全艺人信息：\(entry.displayName)"))
            }
        }

        if !ArtistMetadataFieldSnapshot(entry).hasArtwork {
            await reportTrackProgress(
                phase: .metadata,
                index: index,
                totalCount: totalCount,
                track: track,
                taskLabel: "艺人封面",
                progressHandler
            )
            let changed = await libraryVM.autofillArtistArtworkIfMissing(entry)
            if changed {
                outcome.filledCount += 1
                await recordProgressEvent(
                    title: "艺人封面",
                    detail: entry.displayName,
                    phase: .metadata,
                    index: index,
                    totalCount: totalCount,
                    track: track,
                    taskLabel: "艺人封面",
                    progressHandler
                )
            } else {
                outcome.failures.append(failure(track: track, reason: "暂未找到艺人封面：\(entry.displayName)"))
            }
        }

        return outcome
    }

    private func completeAlbumMetadataIfNeeded(
        for track: Track,
        index: Int,
        totalCount: Int,
        progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async -> MetadataOutcome {
        var outcome = MetadataOutcome()
        guard !LibraryNormalization.isUnknownAlbum(track.album) else { return outcome }
        let key = LibraryNormalization.normalizedAlbumKey(album: track.album)
        guard !processedAlbumKeys.contains(key) else { return outcome }
        processedAlbumKeys.insert(key)

        var entry = albumEntry(for: track)
        let before = AlbumMetadataFieldSnapshot(entry)
        outcome.skippedExistingCount += before.existingFieldCount()

        if before.metadataMissingCount() > 0 {
            await reportTrackProgress(
                phase: .metadata,
                index: index,
                totalCount: totalCount,
                track: track,
                taskLabel: "专辑",
                progressHandler
            )
            switch await MetadataEnrichmentWorker.fetchAlbumMetadata(album: entry.displayTitle, artist: entry.primaryArtistDisplayName) {
            case .completed(let detail):
                guard !Task.isCancelled else { return outcome }
                entry = libraryVM.albumEntries.first { $0.canonicalKey == key } ?? entry
                let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
                if result.changed {
                    let filled = before.filledMetadataCount(comparedWith: AlbumMetadataFieldSnapshot(result.value))
                    entry = result.value
                    albumEntryCache[key] = entry
                    outcome.filledCount += filled
                    await libraryVM.saveAlbumEntry(entry)
                    await recordProgressEvent(
                        title: "专辑",
                        detail: "\(entry.displayTitle)  \(metadataEventDetail(filledCount: filled))",
                        phase: .metadata,
                        index: index,
                        totalCount: totalCount,
                        track: track,
                        taskLabel: "专辑",
                        progressHandler
                    )
                }
            case .noResults:
                outcome.failures.append(failure(track: track, reason: "暂未找到专辑信息：\(entry.displayTitle)"))
            case .failed(_):
                outcome.failures.append(failure(track: track, reason: "暂未补全专辑信息：\(entry.displayTitle)"))
            }
        }

        if !AlbumMetadataFieldSnapshot(entry).hasArtwork {
            await reportTrackProgress(
                phase: .metadata,
                index: index,
                totalCount: totalCount,
                track: track,
                taskLabel: "专辑封面",
                progressHandler
            )
            switch await MetadataEnrichmentWorker.fetchAlbumArtwork(
                album: entry.displayTitle,
                artist: entry.primaryArtistDisplayName,
                qqMusicCoverService: qqMusicCoverService
            ) {
            case .completed(let data):
                guard !Task.isCancelled else { return outcome }
                var latest = albumEntryCache[key] ?? entry
                if !latest.hasArtwork {
                    latest.artworkData = data
                    latest.artworkFileName = "artwork.png"
                    latest.updatedAt = Date()
                    albumEntryCache[key] = latest
                    outcome.filledCount += 1
                    await libraryVM.saveAlbumEntry(latest)
                    await recordProgressEvent(
                        title: "专辑封面",
                        detail: latest.displayTitle,
                        phase: .metadata,
                        index: index,
                        totalCount: totalCount,
                        track: track,
                        taskLabel: "专辑封面",
                        progressHandler
                    )
                } else {
                    outcome.skippedExistingCount += 1
                }
            case .noResults:
                outcome.failures.append(failure(track: track, reason: "暂未找到专辑封面：\(entry.displayTitle)"))
            case .failed(_):
                outcome.failures.append(failure(track: track, reason: "暂未补全专辑封面：\(entry.displayTitle)"))
            }
        }

        return outcome
    }

    private func coverData(for track: Track) async -> LibraryCompletionCachedCover {
        let key = trackCoverCacheKey(for: track)
        if let cached = trackCoverCache[key] {
            return cached
        }

        let result: LibraryCompletionCachedCover
        switch await ImportEnrichmentWorker.fetchCover(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration > 0 ? track.duration : nil,
            qqMusicCoverService: qqMusicCoverService
        ) {
        case .completed(let data):
            result = .found(data)
        case .noResults:
            result = .missing("暂未找到歌曲封面")
        case .failed(_):
            result = .missing("暂未补全歌曲封面")
        }
        storeTrackCoverResult(result, for: key)
        return result
    }

    private func storeTrackCoverResult(_ result: LibraryCompletionCachedCover, for key: String) {
        let resultBytes: Int
        switch result {
        case .found(let data):
            resultBytes = data.count
        case .missing:
            resultBytes = 0
        }

        guard resultBytes <= Self.maxTrackCoverCacheBytes else {
            if let previous = trackCoverCache.removeValue(forKey: key),
               case .found(let data) = previous {
                trackCoverCacheBytes -= data.count
            }
            return
        }

        if let previous = trackCoverCache.updateValue(result, forKey: key),
           case .found(let data) = previous {
            trackCoverCacheBytes -= data.count
        }
        trackCoverCacheBytes += resultBytes

        while trackCoverCache.count > Self.maxTrackCoverCacheEntryCount
            || trackCoverCacheBytes > Self.maxTrackCoverCacheBytes {
            guard let evictedKey = trackCoverCache.keys.first(where: { $0 != key }),
                  let evicted = trackCoverCache.removeValue(forKey: evictedKey)
            else {
                trackCoverCache.removeValue(forKey: key)
                trackCoverCacheBytes -= resultBytes
                return
            }
            if case .found(let data) = evicted {
                trackCoverCacheBytes -= data.count
            }
        }
    }

    private func clearCompletionCaches() {
        processedArtistKeys.removeAll(keepingCapacity: false)
        processedAlbumKeys.removeAll(keepingCapacity: false)
        artistEntryCache.removeAll(keepingCapacity: false)
        albumEntryCache.removeAll(keepingCapacity: false)
        trackCoverCache.removeAll(keepingCapacity: false)
        trackCoverCacheBytes = 0
        progressEvents.removeAll(keepingCapacity: false)
    }

    private func trackCoverCacheKey(for track: Track) -> String {
        let albumKey = LibraryNormalization.normalizedAlbumKey(album: track.album)
        if !LibraryNormalization.isUnknownAlbum(track.album) {
            return "album:\(LibraryNormalization.normalizeArtist(track.artist)):\(albumKey)"
        }
        return "track:\(track.id.uuidString)"
    }

    private func artistEntry(for artist: String) -> ArtistEntry {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        if let cached = artistEntryCache[canonical] {
            return cached
        }
        let now = Date()
        let entry = ArtistEntry(
            id: UUID(),
            canonicalName: canonical,
            displayName: LibraryNormalization.displayArtist(artist),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            albumCount: 0,
            totalDuration: 0,
            isOrphaned: false
        )
        artistEntryCache[canonical] = entry
        return entry
    }

    private func albumEntry(for track: Track) -> AlbumEntry {
        let key = LibraryNormalization.normalizedAlbumKey(album: track.album)
        if let cached = albumEntryCache[key] {
            return cached
        }
        let now = Date()
        let entry = AlbumEntry(
            id: UUID(),
            canonicalKey: key,
            displayTitle: LibraryNormalization.displayAlbum(track.album),
            primaryArtistCanonicalName: LibraryNormalization.normalizeArtist(track.artist),
            primaryArtistDisplayName: LibraryNormalization.displayArtist(track.artist),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            totalDuration: 0,
            isOrphaned: false
        )
        albumEntryCache[key] = entry
        return entry
    }

    private func trackHasArtwork(_ track: Track) async -> Bool {
        if let data = track.artworkData, !data.isEmpty {
            return true
        }
        if track.existingArtworkURL() != nil {
            return true
        }
        return await track.loadArtworkDataOffMainIfNeeded()?.isEmpty == false
    }

    private func trackHasLyrics(_ track: Track) -> Bool {
        if LyricsFormatSupport.normalizedTTMLText(track.ttmlLyricText) != nil {
            return true
        }
        if track.ttmlLyricsFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return false
    }

    private func failure(track: Track, reason: String) -> LibraryCompletionFailure {
        LibraryCompletionFailure(trackID: track.id, title: track.title, reason: reason)
    }

    private func report(
        _ newProgress: LibraryCompletionProgress,
        _ progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async {
        let eventfulProgress = LibraryCompletionProgress(
            phase: newProgress.phase,
            processedCount: newProgress.processedCount,
            totalCount: newProgress.totalCount,
            currentTrackTitle: newProgress.currentTrackTitle,
            currentArtist: newProgress.currentArtist,
            currentAlbum: newProgress.currentAlbum,
            currentTaskLabel: newProgress.currentTaskLabel,
            recentEvents: newProgress.recentEvents.isEmpty ? progressEvents : newProgress.recentEvents,
            detail: newProgress.detail
        )
        progress = eventfulProgress
        progressHandler(eventfulProgress)
    }

    private func recordProgressEvent(
        title: String,
        detail: String,
        phase: LibraryCompletionPhase,
        index: Int,
        totalCount: Int,
        track: Track,
        taskLabel: String,
        _ progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async {
        progressEvents.append(
            LibraryCompletionProgressEvent(title: title, detail: detail)
        )
        if progressEvents.count > Self.maxProgressEventCount {
            progressEvents.removeFirst(progressEvents.count - Self.maxProgressEventCount)
        }
        await report(
            LibraryCompletionProgress(
                phase: phase,
                processedCount: index,
                totalCount: totalCount,
                currentTrackTitle: track.title,
                currentArtist: track.artist,
                currentAlbum: track.album,
                currentTaskLabel: taskLabel,
                recentEvents: progressEvents,
                detail: detail
            ),
            progressHandler
        )
    }

    private func reportTrackProgress(
        phase: LibraryCompletionPhase,
        index: Int,
        totalCount: Int,
        track: Track,
        taskLabel: String,
        _ progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async {
        await report(
            LibraryCompletionProgress(
                phase: phase,
                processedCount: index,
                totalCount: totalCount,
                currentTrackTitle: track.title,
                currentArtist: track.artist,
                currentAlbum: track.album,
                currentTaskLabel: taskLabel,
                recentEvents: progressEvents,
                detail: taskLabel
            ),
            progressHandler
        )
    }

    private func reportCancelled(
        processedCount: Int,
        totalCount: Int,
        _ progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async {
        await report(
            LibraryCompletionProgress(
                phase: .cancelled,
                processedCount: processedCount,
                totalCount: totalCount,
                currentTrackTitle: nil,
                currentArtist: nil,
                currentAlbum: nil,
                currentTaskLabel: nil,
                detail: "已取消，已完成的写入会保留"
            ),
            progressHandler
        )
    }

    private func makeResult(
        processedTrackCount: Int,
        metadataItemsFilledCount: Int,
        lyricsFilledTrackCount: Int,
        skippedExistingDataCount: Int,
        failures: [LibraryCompletionFailure],
        updatedTrackIDs: Set<UUID>,
        cancelled: Bool
    ) -> LibraryCompletionResult {
        LibraryCompletionResult(
            processedTrackCount: processedTrackCount,
            metadataItemsFilledCount: metadataItemsFilledCount,
            lyricsFilledTrackCount: lyricsFilledTrackCount,
            skippedExistingDataCount: skippedExistingDataCount,
            failureCount: failures.count,
            failures: failures,
            updatedTrackIDs: Array(updatedTrackIDs).sorted { $0.uuidString < $1.uuidString },
            cancelled: cancelled
        )
    }
}
