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

    var hasSelection: Bool {
        fillMetadata || fillLyrics
    }

    var selectedItemTitles: [String] {
        var titles: [String] = []
        if fillMetadata {
            titles.append("元数据、封面、专辑信息与艺人信息")
        }
        if fillLyrics {
            titles.append("缺失歌词")
        }
        return titles
    }
}

enum LibraryCompletionPhase: String, Sendable {
    case idle
    case scanning
    case metadata
    case lyrics
    case cancelled
    case completed

    var title: String {
        switch self {
        case .idle: return "等待开始"
        case .scanning: return "正在扫描本地曲库"
        case .metadata: return "正在补全缺失元数据"
        case .lyrics: return "正在补全缺失歌词"
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
    let detail: String

    static let idle = LibraryCompletionProgress(
        phase: .idle,
        processedCount: 0,
        totalCount: 0,
        currentTrackTitle: nil,
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
        hasArtwork = entry.artworkFileName != nil || entry.artworkData?.isEmpty == false
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
        hasArtwork = entry.artworkFileName != nil || entry.artworkData?.isEmpty == false
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
    var progress: LibraryCompletionProgress = .idle

    @ObservationIgnored private let libraryVM: LibraryViewModel
    @ObservationIgnored private var processedArtistKeys: Set<String> = []
    @ObservationIgnored private var processedAlbumKeys: Set<String> = []
    @ObservationIgnored private var artistEntryCache: [String: ArtistEntry] = [:]
    @ObservationIgnored private var albumEntryCache: [String: AlbumEntry] = [:]
    @ObservationIgnored private var trackCoverCache: [String: LibraryCompletionCachedCover] = [:]

    init(libraryVM: LibraryViewModel) {
        self.libraryVM = libraryVM
    }

    func completeLibrary(
        options: LibraryCompletionOptions,
        progress progressHandler: @escaping @MainActor (LibraryCompletionProgress) -> Void
    ) async -> LibraryCompletionResult {
        processedArtistKeys.removeAll()
        processedAlbumKeys.removeAll()
        artistEntryCache = Dictionary(uniqueKeysWithValues: libraryVM.artistEntries.map { ($0.canonicalName, $0) })
        albumEntryCache = Dictionary(uniqueKeysWithValues: libraryVM.albumEntries.map { ($0.canonicalKey, $0) })
        trackCoverCache.removeAll()

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

        await report(
            LibraryCompletionProgress(
                phase: .scanning,
                processedCount: 0,
                totalCount: tracks.count,
                currentTrackTitle: nil,
                detail: "已读取本地曲库，共 \(tracks.count) 首"
            ),
            progressHandler
        )

        for (index, track) in tracks.enumerated() {
            if Task.isCancelled {
                await reportCancelled(processedCount: index, totalCount: tracks.count, progressHandler)
                return makeResult(
                    processedTrackCount: index,
                    metadataItemsFilledCount: metadataItemsFilledCount,
                    lyricsFilledTrackCount: lyricsFilledTrackCount,
                    skippedExistingDataCount: skippedExistingDataCount,
                    failures: failures,
                    updatedTrackIDs: updatedTrackIDs,
                    cancelled: true
                )
            }

            let currentTrack = libraryVM.allTracks.first { $0.id == track.id } ?? track
            var trackUpdated = false

            if options.fillMetadata {
                await report(
                    LibraryCompletionProgress(
                        phase: .metadata,
                        processedCount: index,
                        totalCount: tracks.count,
                        currentTrackTitle: currentTrack.title,
                        detail: "正在检查元数据、封面、专辑和艺人信息"
                    ),
                    progressHandler
                )
                let outcome = await completeMetadata(for: currentTrack)
                metadataItemsFilledCount += outcome.filledCount
                skippedExistingDataCount += outcome.skippedExistingCount
                failures.append(contentsOf: outcome.failures)
                trackUpdated = trackUpdated || outcome.trackUpdated
            }

            if Task.isCancelled {
                await reportCancelled(processedCount: index, totalCount: tracks.count, progressHandler)
                return makeResult(
                    processedTrackCount: index,
                    metadataItemsFilledCount: metadataItemsFilledCount,
                    lyricsFilledTrackCount: lyricsFilledTrackCount,
                    skippedExistingDataCount: skippedExistingDataCount,
                    failures: failures,
                    updatedTrackIDs: updatedTrackIDs,
                    cancelled: true
                )
            }

            if options.fillLyrics {
                await report(
                    LibraryCompletionProgress(
                        phase: .lyrics,
                        processedCount: index,
                        totalCount: tracks.count,
                        currentTrackTitle: currentTrack.title,
                        detail: "正在检查歌词"
                    ),
                    progressHandler
                )
                let outcome = await completeLyrics(for: currentTrack)
                lyricsFilledTrackCount += outcome.filled ? 1 : 0
                skippedExistingDataCount += outcome.skippedExisting ? 1 : 0
                failures.append(contentsOf: outcome.failure.map { [$0] } ?? [])
                trackUpdated = trackUpdated || outcome.filled
            }

            if trackUpdated {
                updatedTrackIDs.insert(currentTrack.id)
            }

            await report(
                LibraryCompletionProgress(
                    phase: options.fillLyrics ? .lyrics : .metadata,
                    processedCount: index + 1,
                    totalCount: tracks.count,
                    currentTrackTitle: currentTrack.title,
                    detail: "已处理 \(index + 1) / \(tracks.count)"
                ),
                progressHandler
            )
        }

        if !updatedTrackIDs.isEmpty {
            libraryVM.notifyTrackAuxiliaryDataChanged(trackIDs: Array(updatedTrackIDs))
        }
        await libraryVM.refresh()

        await report(
            LibraryCompletionProgress(
                phase: .completed,
                processedCount: tracks.count,
                totalCount: tracks.count,
                currentTrackTitle: nil,
                detail: "全库补全任务完成"
            ),
            progressHandler
        )

        return makeResult(
            processedTrackCount: tracks.count,
            metadataItemsFilledCount: metadataItemsFilledCount,
            lyricsFilledTrackCount: lyricsFilledTrackCount,
            skippedExistingDataCount: skippedExistingDataCount,
            failures: failures,
            updatedTrackIDs: updatedTrackIDs,
            cancelled: false
        )
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

    private func completeMetadata(for track: Track) async -> MetadataOutcome {
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
                }
            case .noResults:
                outcome.failures.append(failure(track: track, reason: "歌曲信息未找到可用结果"))
            case .failed(let message):
                outcome.failures.append(failure(track: track, reason: "歌曲信息补全失败：\(message)"))
            }
        }

        if !artworkAlreadyPresent {
            switch await coverData(for: track) {
            case .found(let data):
                guard !Task.isCancelled else { return outcome }
                if !(await trackHasArtwork(track)) {
                    track.artworkData = data
                    outcome.filledCount += 1
                    outcome.trackUpdated = true
                    await libraryVM.saveTrackEdits(track, mode: .metaAndArtwork, reason: "manualLibraryCompletionArtwork")
                } else {
                    outcome.skippedExistingCount += 1
                }
            case .missing(let reason):
                outcome.failures.append(failure(track: track, reason: reason))
            }
        }

        let artistResult = await completeArtistMetadataIfNeeded(for: track)
        outcome.filledCount += artistResult.filledCount
        outcome.skippedExistingCount += artistResult.skippedExistingCount
        outcome.failures.append(contentsOf: artistResult.failures)

        let albumResult = await completeAlbumMetadataIfNeeded(for: track)
        outcome.filledCount += albumResult.filledCount
        outcome.skippedExistingCount += albumResult.skippedExistingCount
        outcome.failures.append(contentsOf: albumResult.failures)

        return outcome
    }

    private func completeLyrics(for track: Track) async -> LyricsOutcome {
        if trackHasLyrics(track) {
            return LyricsOutcome(filled: false, skippedExisting: true, failure: nil)
        }

        switch await ImportEnrichmentWorker.fetchLyrics(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration > 0 ? track.duration : nil
        ) {
        case .completed(let ttml):
            guard !Task.isCancelled else { return LyricsOutcome() }
            if !trackHasLyrics(track) {
                track.ttmlLyricText = ttml
                await libraryVM.saveTrackEdits(track, mode: .metaAndLyrics, reason: "manualLibraryCompletionLyrics")
                return LyricsOutcome(filled: true, skippedExisting: false, failure: nil)
            }
            return LyricsOutcome(filled: false, skippedExisting: true, failure: nil)
        case .noResults:
            return LyricsOutcome(filled: false, skippedExisting: false, failure: failure(track: track, reason: "歌词未找到可用结果"))
        case .failed(let message):
            return LyricsOutcome(filled: false, skippedExisting: false, failure: failure(track: track, reason: "歌词补全失败：\(message)"))
        }
    }

    private func completeArtistMetadataIfNeeded(for track: Track) async -> MetadataOutcome {
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
            switch await MetadataEnrichmentWorker.fetchArtistMetadata(name: entry.displayName) {
            case .completed(let detail):
                guard !Task.isCancelled else { return outcome }
                let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
                if result.changed {
                    let filled = before.filledMetadataCount(comparedWith: ArtistMetadataFieldSnapshot(result.value))
                    entry = result.value
                    artistEntryCache[canonical] = entry
                    outcome.filledCount += filled
                    await libraryVM.saveArtistEntry(entry)
                }
            case .noResults:
                outcome.failures.append(failure(track: track, reason: "艺人信息未找到可用结果：\(entry.displayName)"))
            case .failed(let message):
                outcome.failures.append(failure(track: track, reason: "艺人信息补全失败：\(entry.displayName)，\(message)"))
            }
        }

        if !ArtistMetadataFieldSnapshot(entry).hasArtwork {
            let changed = await libraryVM.autofillArtistArtworkIfMissing(entry)
            if changed {
                outcome.filledCount += 1
            } else {
                outcome.failures.append(failure(track: track, reason: "艺人封面未找到可用结果：\(entry.displayName)"))
            }
        }

        return outcome
    }

    private func completeAlbumMetadataIfNeeded(for track: Track) async -> MetadataOutcome {
        var outcome = MetadataOutcome()
        guard !LibraryNormalization.isUnknownAlbum(track.album) else { return outcome }
        let key = LibraryNormalization.normalizedAlbumKey(album: track.album)
        guard !processedAlbumKeys.contains(key) else { return outcome }
        processedAlbumKeys.insert(key)

        var entry = albumEntry(for: track)
        let before = AlbumMetadataFieldSnapshot(entry)
        outcome.skippedExistingCount += before.existingFieldCount()

        if before.metadataMissingCount() > 0 {
            switch await MetadataEnrichmentWorker.fetchAlbumMetadata(album: entry.displayTitle, artist: entry.primaryArtistDisplayName) {
            case .completed(let detail):
                guard !Task.isCancelled else { return outcome }
                let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
                if result.changed {
                    let filled = before.filledMetadataCount(comparedWith: AlbumMetadataFieldSnapshot(result.value))
                    entry = result.value
                    albumEntryCache[key] = entry
                    outcome.filledCount += filled
                    await libraryVM.saveAlbumEntry(entry)
                }
            case .noResults:
                outcome.failures.append(failure(track: track, reason: "专辑信息未找到可用结果：\(entry.displayTitle)"))
            case .failed(let message):
                outcome.failures.append(failure(track: track, reason: "专辑信息补全失败：\(entry.displayTitle)，\(message)"))
            }
        }

        if !AlbumMetadataFieldSnapshot(entry).hasArtwork {
            switch await MetadataEnrichmentWorker.fetchAlbumArtwork(album: entry.displayTitle, artist: entry.primaryArtistDisplayName) {
            case .completed(let data):
                guard !Task.isCancelled else { return outcome }
                var latest = albumEntryCache[key] ?? entry
                if latest.artworkFileName == nil && latest.artworkData?.isEmpty != false {
                    latest.artworkData = data
                    latest.artworkFileName = "artwork.png"
                    latest.updatedAt = Date()
                    albumEntryCache[key] = latest
                    outcome.filledCount += 1
                    await libraryVM.saveAlbumEntry(latest)
                } else {
                    outcome.skippedExistingCount += 1
                }
            case .noResults:
                outcome.failures.append(failure(track: track, reason: "专辑封面未找到可用结果：\(entry.displayTitle)"))
            case .failed(let message):
                outcome.failures.append(failure(track: track, reason: "专辑封面补全失败：\(entry.displayTitle)，\(message)"))
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
            duration: track.duration > 0 ? track.duration : nil
        ) {
        case .completed(let data):
            result = .found(data)
        case .noResults:
            result = .missing("歌曲封面未找到可用结果")
        case .failed(let message):
            result = .missing("歌曲封面补全失败：\(message)")
        }
        trackCoverCache[key] = result
        return result
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
        if track.artworkFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return await track.loadArtworkDataOffMainIfNeeded()?.isEmpty == false
    }

    private func trackHasLyrics(_ track: Track) -> Bool {
        if track.ttmlLyricText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if track.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if track.ttmlLyricsFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if track.lyricsFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
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
        progress = newProgress
        progressHandler(newProgress)
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
