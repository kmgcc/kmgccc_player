//
//  AlbumTrackOrderingService.swift
//  myPlayer2
//
//  After an import, asks the catalog for each imported album's track order and
//  stores that order as the album's custom order. A partial import keeps only
//  the tracks it has; an album that already has a custom order receives the
//  new tracks at their catalog positions without disturbing the old order.
//

import Foundation

/// One album whose catalog order could not be resolved. The import finishes
/// normally; these are collected and surfaced together after the task.
nonisolated struct AlbumOrderingFailure: Identifiable, Equatable, Sendable {
    nonisolated enum Reason: String, Sendable {
        case albumNotFound
        case artistMismatch
        case albumMismatch
        case trackNumbersUnavailable
        case lowMatch
        case requestFailed
        case writeFailed
        case timedOut
    }

    let albumKey: String
    let albumTitle: String
    let artist: String
    let reason: Reason
    let detail: String

    var id: String { albumKey }
}

nonisolated struct AlbumOrderingOutcome: Sendable {
    var updatedAlbumCount: Int = 0
    var orderedTrackCount: Int = 0
    var updatedAlbumKeys: [String] = []
    var failures: [AlbumOrderingFailure] = []

    static let empty = AlbumOrderingOutcome()
}

/// Pure track/catalog matching. Kept separate from the service so the order
/// decision can be exercised without the helper process or a library.
nonisolated enum AlbumTrackOrderResolver {
    nonisolated struct LocalTrack: Equatable, Sendable {
        let id: UUID
        let title: String
        let duration: Double
        /// Catalog song id captured by metadata enrichment, when available.
        /// A match here outranks every title comparison.
        var songMid: String? = nil
        /// Original embedded title when the listener edited the display title.
        var alternativeTitles: [String] = []
    }

    nonisolated struct CatalogSong: Equatable, Sendable {
        let title: String
        let duration: Double?
        var songMid: String? = nil
        var alternativeTitles: [String] = []
    }

    nonisolated struct Resolution: Equatable, Sendable {
        let orderedTrackIDs: [UUID]
        /// Catalog index + 1 for every matched local track. These are absolute
        /// album positions and intentionally keep gaps for absent tracks.
        let catalogPositionByTrackID: [UUID: Int]
        let matchedCount: Int
    }

    /// Returns the local tracks in the order the album page should show.
    /// `existingOrder` is the album's stored custom order, when present:
    /// tracks already ordered keep their relative positions and new tracks are
    /// inserted at their catalog positions. Nil means the match is not
    /// trustworthy enough to replace the album's current order.
    nonisolated static func orderedTrackIDs(
        localTracks: [LocalTrack],
        catalog: [CatalogSong],
        existingOrder: [UUID]? = nil
    ) -> [UUID]? {
        resolve(
            localTracks: localTracks,
            catalog: catalog,
            existingOrder: existingOrder
        )?.orderedTrackIDs
    }

    nonisolated static func resolve(
        localTracks: [LocalTrack],
        catalog: [CatalogSong],
        existingOrder: [UUID]? = nil
    ) -> Resolution? {
        guard localTracks.count >= 2, catalog.count >= 2 else { return nil }

        let localTitles = localTracks.map { titleVariants(for: $0) }
        let catalogTitles = catalog.map { titleVariants(for: $0) }
        var localToCatalog: [Int: Int] = [:]
        var claimedCatalog = Set<Int>()

        // A persisted QQ Music song id survives user-edited titles and album
        // names, so it is the strongest possible match.
        for (localIndex, track) in localTracks.enumerated() {
            guard let mid = normalizedMid(track.songMid) else { continue }
            let matches = catalog.indices.filter {
                normalizedMid(catalog[$0].songMid) == mid
            }
            guard matches.count == 1, let catalogIndex = matches.first else { continue }
            localToCatalog[localIndex] = catalogIndex
            claimedCatalog.insert(catalogIndex)
        }

        var pairs: [(local: Int, catalog: Int, score: Double)] = []
        for (localIndex, track) in localTracks.enumerated() where localToCatalog[localIndex] == nil {
            for (catalogIndex, song) in catalog.enumerated() where !claimedCatalog.contains(catalogIndex) {
                if let score = matchScore(
                    localTitleVariants: localTitles[localIndex],
                    localDuration: track.duration,
                    catalogTitleVariants: catalogTitles[catalogIndex],
                    catalogDuration: song.duration
                ) {
                    pairs.append((localIndex, catalogIndex, score))
                }
            }
        }
        pairs.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.local < rhs.local : lhs.score > rhs.score
        }

        for pair in pairs where localToCatalog[pair.local] == nil && !claimedCatalog.contains(pair.catalog) {
            localToCatalog[pair.local] = pair.catalog
            claimedCatalog.insert(pair.catalog)
        }

        let requiredMatches = max(2, Int((Double(localTracks.count) * 0.6).rounded(.up)))
        guard localToCatalog.count >= requiredMatches else { return nil }

        let ranks = Dictionary(
            uniqueKeysWithValues: localToCatalog.map { (localTracks[$0.key].id, $0.value) }
        )
        let catalogPositionByTrackID = Dictionary(
            uniqueKeysWithValues: localToCatalog.map {
                (localTracks[$0.key].id, $0.value + 1)
            }
        )
        let catalogMatchedIDs = localTracks
            .filter { ranks[$0.id] != nil }
            .sorted { ranks[$0.id]! < ranks[$1.id]! }
            .map(\.id)
        let unmatchedIDs = localTracks.filter { ranks[$0.id] == nil }.map(\.id)
        let fullOrder = catalogMatchedIDs + unmatchedIDs
        let matchedCount = localToCatalog.count

        guard let existingOrder else {
            return Resolution(
                orderedTrackIDs: fullOrder,
                catalogPositionByTrackID: catalogPositionByTrackID,
                matchedCount: matchedCount
            )
        }
        let localIDs = Set(localTracks.map(\.id))
        var seen = Set<UUID>()
        let existing = existingOrder.filter {
            localIDs.contains($0) && seen.insert($0).inserted
        }
        guard !existing.isEmpty else {
            return Resolution(
                orderedTrackIDs: fullOrder,
                catalogPositionByTrackID: catalogPositionByTrackID,
                matchedCount: matchedCount
            )
        }

        let existingSet = Set(existing)
        let matchedExisting = existing.filter { ranks[$0] != nil }
        let matchedExistingInCatalogOrder = matchedExisting
            .sorted { ranks[$0]! < ranks[$1]! }
        let lastMatchedIndex = existing.lastIndex(where: { ranks[$0] != nil }) ?? -1
        let unmatchedAreTrailing = existing.indices.allSatisfy { index in
            ranks[existing[index]] != nil || index > lastMatchedIndex
        }

        if matchedExisting.count >= 2,
           matchedExisting == matchedExistingInCatalogOrder,
           unmatchedAreTrailing {
            // The stored order is already catalog order. Recompute it so new
            // tracks land in place while trailing bonus tracks keep their order.
            let existingUnmatched = existing.filter { ranks[$0] == nil }
            let newUnmatched = localTracks
                .filter { !existingSet.contains($0.id) && ranks[$0.id] == nil }
                .map(\.id)
            return Resolution(
                orderedTrackIDs: catalogMatchedIDs + existingUnmatched + newUnmatched,
                catalogPositionByTrackID: catalogPositionByTrackID,
                matchedCount: matchedCount
            )
        }

        return Resolution(
            orderedTrackIDs: mergedOrder(
                existing: existing,
                localTracks: localTracks,
                existingSet: existingSet,
                ranks: ranks
            ),
            catalogPositionByTrackID: catalogPositionByTrackID,
            matchedCount: matchedCount
        )
    }

    /// Keeps the existing relative order and inserts new catalog matches at
    /// their catalog position; new unmatched tracks follow at the end.
    nonisolated private static func mergedOrder(
        existing: [UUID],
        localTracks: [LocalTrack],
        existingSet: Set<UUID>,
        ranks: [UUID: Int]
    ) -> [UUID] {
        var merged = existing
        let newMatched = localTracks
            .filter { !existingSet.contains($0.id) && ranks[$0.id] != nil }
            .sorted { ranks[$0.id]! < ranks[$1.id]! }
        for track in newMatched {
            let rank = ranks[track.id]!
            if let index = merged.firstIndex(where: { ranks[$0].map { $0 > rank } ?? false }) {
                merged.insert(track.id, at: index)
            } else if let lastMatched = merged.lastIndex(where: { ranks[$0] != nil }) {
                merged.insert(track.id, at: lastMatched + 1)
            } else {
                merged.append(track.id)
            }
        }
        let newUnmatched = localTracks
            .filter { !existingSet.contains($0.id) && ranks[$0.id] == nil }
            .map(\.id)
        return merged + newUnmatched
    }

    private struct TitleVariant {
        let text: ExternalPlaybackTextNormalizer.NormalizedText
        /// Pinyin is a fallback for traditional/simplified or translated
        /// variants; it must not outrank an exact title match.
        let phonetic: Bool
    }

    nonisolated private static func titleVariants(for track: LocalTrack) -> [TitleVariant] {
        normalizedVariants([track.title] + track.alternativeTitles)
    }

    nonisolated private static func titleVariants(for song: CatalogSong) -> [TitleVariant] {
        normalizedVariants([song.title] + song.alternativeTitles)
    }

    nonisolated private static func normalizedVariants(_ values: [String]) -> [TitleVariant] {
        var variants: [TitleVariant] = []
        var seen = Set<String>()
        func append(_ text: ExternalPlaybackTextNormalizer.NormalizedText, phonetic: Bool) {
            guard !text.compact.isEmpty else { return }
            let key = "\(phonetic ? "p" : "t"):\(text.compact)"
            guard seen.insert(key).inserted else { return }
            variants.append(TitleVariant(text: text, phonetic: phonetic))
        }

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            append(ExternalPlaybackTextNormalizer.normalize(trimmed), phonetic: false)
            let stripped = strippingLeadingCatalogNumber(trimmed)
            if stripped != trimmed {
                append(ExternalPlaybackTextNormalizer.normalize(stripped), phonetic: false)
            }
            if let pinyin = pinyinVariant(trimmed) {
                append(pinyin, phonetic: true)
            }
        }
        return variants
    }

    /// Strips common file-name prefixes such as `01 -`, `1-01`, `[01]`.
    /// Bare numbers are only stripped when zero-padded so titles like
    /// "7 Rings" and "1979" survive.
    nonisolated static func strippingLeadingCatalogNumber(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let patterns = [
            #"^\s*(?:(?:cd|disc|disk)\s*)?\d{1,2}\s*[-._–—:]\s*\d{1,3}[\s._–—:-]+"#,
            #"^\s*[\[(（]\s*\d{1,3}\s*[\])）]\s*[-._–—:.]?\s*"#,
            #"^\s*\d{1,3}\s*[-._–—:]\s+"#,
            #"^\s*0\d{1,2}\s+"#
        ]
        for pattern in patterns {
            guard let range = trimmed.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            let remainder = String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty { return remainder }
        }
        return trimmed
    }

    nonisolated private static func pinyinVariant(
        _ value: String
    ) -> ExternalPlaybackTextNormalizer.NormalizedText? {
        let hasHan = value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
        guard hasHan,
              let latin = value.applyingTransform(.mandarinToLatin, reverse: false)
        else { return nil }
        let normalized = ExternalPlaybackTextNormalizer.normalize(latin)
        return normalized.compact.isEmpty ? nil : normalized
    }

    nonisolated private static func normalizedMid(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    nonisolated private static func matchScore(
        localTitleVariants: [TitleVariant],
        localDuration: Double,
        catalogTitleVariants: [TitleVariant],
        catalogDuration: Double?
    ) -> Double? {
        let durationScore: Double
        if localDuration > 0, let catalogDuration, catalogDuration > 0 {
            durationScore = ExternalPlaybackTextNormalizer.durationScore(
                source: localDuration,
                candidate: catalogDuration
            )
            guard durationScore >= 0.5 else { return nil }
        } else {
            durationScore = 0.5
        }

        var best: Double?
        for localTitle in localTitleVariants {
            for catalogTitle in catalogTitleVariants {
                if ExternalPlaybackTextNormalizer.hasShortTitleConflict(
                    localTitle.text,
                    catalogTitle.text
                ) {
                    continue
                }
                var titleScore = ExternalPlaybackTextNormalizer.stringSimilarity(
                    localTitle.text,
                    catalogTitle.text
                )
                if localTitle.phonetic || catalogTitle.phonetic {
                    titleScore *= 0.94
                }
                guard titleScore >= 0.68 else { continue }
                let score = titleScore * 0.78 + durationScore * 0.22
                if score >= 0.65 {
                    best = max(best ?? 0, score)
                }
            }
        }
        return best
    }
}

@MainActor
final class AlbumTrackOrderingService {
    private struct AlbumCandidate {
        let sidecar: AlbumSidecar
        let tracks: [Track]

        var key: String { sidecar.canonicalKey }
        var title: String { sidecar.displayTitle }
        var artist: String {
            trimmed(sidecar.primaryArtistDisplayName)
                ?? trimmed(tracks.first?.albumArtist)
                ?? trimmed(tracks.first?.artist)
                ?? ""
        }

        var isCompilation: Bool {
            tracks.contains { $0.embeddedCompilation == true }
                || LibraryNormalization.isCompilationAlbumType(
                    sidecar.albumType,
                    primaryArtist: artist
                )
        }

        var localAlbumTitles: [String] {
            uniqueNonEmpty(
                [sidecar.displayTitle, tracks.first?.album]
                    + tracks.compactMap { $0.embeddedMetadataSnapshot?.album }
            )
        }

        var localAlbumArtists: [String] {
            uniqueNonEmpty(
                [artist]
                    + tracks.compactMap { $0.albumArtist }
                    + tracks.compactMap { $0.embeddedMetadataSnapshot?.albumArtist }
                    + tracks.compactMap { $0.embeddedMetadataSnapshot?.artistDisplay }
            )
        }
    }

    private enum AlbumResolution {
        case ordered(order: [UUID], positions: [UUID: Int])
        case ignored
        case failed(AlbumOrderingFailure)
    }

    private struct CatalogQuery: Hashable {
        let album: String
        let artist: String
        let albumMid: String?
    }

    private let libraryService: LocalLibraryService
    private let repository: LibraryRepositoryProtocol
    private let helper: QQMusicHelperProcess
    private let maxDuration: TimeInterval = 15

    /// An album the listener explicitly sorted by something other than custom
    /// order keeps that choice. Unknown legacy keys are ignored as before.
    static func allowsCatalogOrder(sortKey: String?) -> Bool {
        let trimmed = sortKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let knownSort = TrackSortKey(rawValue: trimmed) else { return true }
        return knownSort == .custom
    }

    init(
        libraryService: LocalLibraryService,
        repository: LibraryRepositoryProtocol,
        helper: QQMusicHelperProcess = .shared
    ) {
        self.libraryService = libraryService
        self.repository = repository
        self.helper = helper
    }

    func applyCatalogOrder(
        toImportedTracks importedTracks: [Track],
        force: Bool = false,
        isCancelled: (() -> Bool)? = nil,
        progress: ((_ completed: Int, _ total: Int, _ albumTitle: String) -> Void)? = nil
    ) async -> AlbumOrderingOutcome {
        let importedAlbumKeys = Set(importedTracks.map(\.albumGroupKey).filter { !$0.isEmpty })
        return await applyCatalogOrder(
            toAlbumKeys: importedAlbumKeys,
            force: force,
            isCancelled: isCancelled,
            progress: progress
        )
    }

    /// Resolves catalog order for the given album keys. Used by the import
    /// pipeline and by the album editor's manual action.
    func applyCatalogOrder(
        toAlbumKeys albumKeys: Set<String>,
        force: Bool = false,
        isCancelled: (() -> Bool)? = nil,
        progress: ((_ completed: Int, _ total: Int, _ albumTitle: String) -> Void)? = nil
    ) async -> AlbumOrderingOutcome {
        // XCTest imports use synthetic libraries; never reach QQ Music from them.
        guard !KmgcccPlayerApp.isRunningTests else { return .empty }
        guard !albumKeys.isEmpty else { return .empty }

        let allTracks = await repository.fetchTracks(in: nil)
        let tracksByAlbum = Dictionary(grouping: allTracks, by: \.albumGroupKey)
        let sidecars = libraryService.loadAlbumSidecarsFromDisk().map(\.sidecar)
        var candidates: [AlbumCandidate] = []
        var outcome = AlbumOrderingOutcome()

        for key in albumKeys.sorted() {
            guard let tracks = tracksByAlbum[key], !tracks.isEmpty else { continue }
            guard let first = tracks.first else { continue }
            let title = trimmed(first.album) ?? key
            let artist = trimmed(first.albumArtist) ?? trimmed(first.artist) ?? ""
            guard !LibraryNormalization.isUnknownAlbum(first.album) else { continue }
            guard tracks.count >= 2 else {
                if force {
                    outcome.failures.append(
                        failure(
                            key: key,
                            title: title,
                            artist: artist,
                            reason: .albumNotFound,
                            detail: "专辑内不足两首歌曲，未整理曲序"
                        )
                    )
                }
                continue
            }
            let matchingSidecars = sidecars.filter { $0.canonicalKey == key }
            let sidecar = matchingSidecars.first {
                sidecarArtistMatches($0, tracks: tracks)
            } ?? matchingSidecars.first
            guard let sidecar else {
                outcome.failures.append(
                    failure(
                        key: key,
                        title: title,
                        artist: artist,
                        reason: .albumNotFound,
                        detail: "没有找到这张专辑的本地记录"
                    )
                )
                continue
            }
            candidates.append(AlbumCandidate(sidecar: sidecar, tracks: tracks))
        }

        candidates.sort {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        guard !candidates.isEmpty else { return outcome }

        var consecutiveRequestFailures = 0
        let deadline = Date().addingTimeInterval(maxDuration)

        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled || isCancelled?() == true { break }
            if Date() >= deadline {
                outcome.failures.append(
                    failure(
                        candidate: candidate,
                        reason: .timedOut,
                        detail: "查询专辑曲序超时，未整理"
                    )
                )
                break
            }
            progress?(index, candidates.count, candidate.title)
            let resolution = await resolveOrder(for: candidate, force: force)
            switch resolution {
            case .ignored:
                continue
            case .failed(let failure):
                outcome.failures.append(failure)
                if failure.reason == .requestFailed {
                    consecutiveRequestFailures += 1
                } else {
                    consecutiveRequestFailures = 0
                }
                if consecutiveRequestFailures >= 2 { break }
            case .ordered(let order, let positions):
                consecutiveRequestFailures = 0
                if Task.isCancelled || isCancelled?() == true { break }
                if candidate.sidecar.customTrackOrder == order,
                   candidate.sidecar.trackSortKey == TrackSortKey.custom.rawValue,
                   (candidate.sidecar.catalogTrackNumbers ?? [:]) == positions {
                    // A retry that finds the album already correct still
                    // resolves any older failure for it.
                    outcome.updatedAlbumKeys.append(candidate.key)
                    continue
                }
                let availableTrackIDs = candidate.tracks.map(\.id)
                guard libraryService.updateAlbumTrackOrdering(
                    albumID: candidate.sidecar.id,
                    orderedTrackIDs: order,
                    sortOrder: TrackSortOrder.ascending.rawValue,
                    availableTrackIDs: availableTrackIDs,
                    catalogTrackNumbers: positions
                ) else {
                    outcome.failures.append(
                        failure(
                            candidate: candidate,
                            reason: .writeFailed,
                            detail: "专辑曲序写入失败"
                        )
                    )
                    continue
                }
                outcome.updatedAlbumCount += 1
                outcome.orderedTrackCount += order.count
                outcome.updatedAlbumKeys.append(candidate.key)
                await repository.updateAlbumCatalogTrackNumbers(
                    albumKey: candidate.key,
                    numbers: positions
                )
                Log.info(
                    "[AlbumTrackOrdering] event=album-order-applied album=\(candidate.title) tracks=\(order.count) positions=\(positions.count)",
                    category: .import
                )
            }
        }

        return outcome
    }

    private func resolveOrder(
        for candidate: AlbumCandidate,
        force: Bool
    ) async -> AlbumResolution {
        let sortKey = candidate.sidecar.trackSortKey?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !force, !Self.allowsCatalogOrder(sortKey: sortKey) {
            // The listener chose this album's sort explicitly; leave it alone.
            Log.info(
                "[AlbumTrackOrdering] event=album-order-user-sort album=\(candidate.title) sort=\(sortKey)",
                category: .import
            )
            return .ignored
        }
        if let conflict = artistConflictFailure(for: candidate) {
            return .failed(conflict)
        }

        let queries = catalogQueries(for: candidate)
        guard !queries.isEmpty else {
            return .failed(
                failure(
                    candidate: candidate,
                    reason: .albumNotFound,
                    detail: "专辑名或艺人信息为空，无法查询"
                )
            )
        }

        var lastFailure: AlbumOrderingFailure?
        for query in queries {
            if Task.isCancelled { return .ignored }
            let songs: [QQMusicAlbumSong]
            do {
                songs = try await helper.fetchAlbumSongs(
                    album: query.album.isEmpty ? nil : query.album,
                    artist: query.artist.isEmpty ? nil : query.artist,
                    albumMid: query.albumMid
                )
            } catch is CancellationError {
                return .ignored
            } catch {
                Log.warning(
                    "[AlbumTrackOrdering] event=album-order-failed album=\(candidate.title) errorType=\(String(describing: type(of: error)))",
                    category: .import
                )
                return .failed(
                    failure(
                        candidate: candidate,
                        reason: .requestFailed,
                        detail: "无法连接 QQ 音乐，请稍后重试"
                    )
                )
            }
            guard songs.count >= 2 else {
                lastFailure = failure(
                    candidate: candidate,
                    reason: .albumNotFound,
                    detail: "未在 QQ 音乐找到这张专辑"
                )
                continue
            }

            // Without distinct catalog track numbers the payload order is not
            // authoritative (some compilations tag every row as track 1).
            let trackNumbers = songs.compactMap { $0.trackNumber }.filter { $0 > 0 }
            guard trackNumbers.count >= 2, Set(trackNumbers).count >= 2 else {
                lastFailure = failure(
                    candidate: candidate,
                    reason: .trackNumbersUnavailable,
                    detail: "QQ 音乐没有提供可用的曲目序号"
                )
                continue
            }
            guard catalogMatchesLocalAlbum(songs, titles: candidate.localAlbumTitles) else {
                lastFailure = failure(
                    candidate: candidate,
                    reason: .albumMismatch,
                    detail: "找到的专辑与本地专辑信息不一致"
                )
                continue
            }
            guard catalogMatchesLocalArtist(
                songs,
                localArtists: candidate.localAlbumArtists,
                isCompilation: candidate.isCompilation
            ) else {
                lastFailure = failure(
                    candidate: candidate,
                    reason: .artistMismatch,
                    detail: "找到的专辑与本地艺人信息不一致"
                )
                continue
            }

            let orderedSongs = songs.sorted { lhs, rhs in
                let lhsDisc = lhs.discNumber ?? 0
                let rhsDisc = rhs.discNumber ?? 0
                if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }
                let lhsTrack = lhs.trackNumber.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
                let rhsTrack = rhs.trackNumber.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
                return lhsTrack < rhsTrack
            }
            let catalog = orderedSongs.map {
                AlbumTrackOrderResolver.CatalogSong(
                    title: $0.title ?? "",
                    duration: $0.duration.map { Double($0) },
                    songMid: $0.songMid
                )
            }
            let local = candidate.tracks.map { track in
                AlbumTrackOrderResolver.LocalTrack(
                    id: track.id,
                    title: track.title,
                    duration: track.duration,
                    songMid: track.qqMusicSongMid,
                    alternativeTitles: uniqueNonEmpty([
                        track.embeddedMetadataSnapshot?.title,
                        track.userMetadataOverride?.title
                    ].filter { title in
                        trimmed(title) != trimmed(track.title)
                    })
                )
            }
            // Large compilations make the pairwise title comparison expensive;
            // keep it off the main actor during the import dialog.
            let existingOrder = candidate.sidecar.customTrackOrder
            let resolution = await Task.detached(priority: .utility) {
                AlbumTrackOrderResolver.resolve(
                    localTracks: local,
                    catalog: catalog,
                    existingOrder: existingOrder
                )
            }.value
            guard let resolution else {
                return .failed(
                    failure(
                        candidate: candidate,
                        reason: .lowMatch,
                        detail: "曲目匹配不足，未改动曲序"
                    )
                )
            }
            Log.info(
                "[AlbumTrackOrdering] event=album-order-resolved album=\(candidate.title) matched=\(resolution.matchedCount) local=\(candidate.tracks.count)",
                category: .import
            )
            let discNumbers = Set(orderedSongs.compactMap(\.discNumber).filter { $0 > 0 })
            let usesPerDiscNumbers = discNumbers.count <= 1
            let catalogPositions = orderedSongs.enumerated().map { index, song -> Int in
                if usesPerDiscNumbers, let trackNumber = song.trackNumber, trackNumber > 0 {
                    return trackNumber
                }
                return index + 1
            }
            let positions = resolution.catalogPositionByTrackID.mapValues { position in
                let index = position - 1
                guard catalogPositions.indices.contains(index) else { return position }
                return catalogPositions[index]
            }
            return .ordered(
                order: resolution.orderedTrackIDs,
                positions: positions
            )
        }

        return .failed(
            lastFailure ?? failure(
                candidate: candidate,
                reason: .albumNotFound,
                detail: "未在 QQ 音乐找到这张专辑"
            )
        )
    }

    /// Same-title albums by different artists must not share one catalog
    /// lookup. The album group itself is already artist-aware when tags allow;
    /// this guard also catches partially tagged merges.
    private func artistConflictFailure(
        for candidate: AlbumCandidate
    ) -> AlbumOrderingFailure? {
        guard !candidate.isCompilation else { return nil }
        let values = uniqueNonEmpty(
            [candidate.artist] + candidate.tracks.compactMap { $0.albumArtist }
        )
        guard values.count > 1 else { return nil }
        let normalized = values.map { ExternalPlaybackTextNormalizer.normalizeArtist($0) }
        for index in normalized.indices {
            for other in normalized.indices where other > index {
                if ExternalPlaybackTextNormalizer.artistSimilarity(
                    normalized[index],
                    normalized[other]
                ) < 0.9 {
                    return failure(
                        candidate: candidate,
                        reason: .artistMismatch,
                        detail: "专辑内的艺人信息不一致，未整理曲序"
                    )
                }
            }
        }
        return nil
    }

    private func catalogQueries(for candidate: AlbumCandidate) -> [CatalogQuery] {
        let albumValues = candidate.localAlbumTitles
        let artistValues = candidate.localAlbumArtists
        guard !albumValues.isEmpty else { return [] }
        let mid = trimmed(candidate.sidecar.qqMusicAlbumMid)
        let primaryAlbum = albumValues[0]
        let primaryArtist = artistValues.first ?? ""

        var queries: [CatalogQuery] = []
        var seen = Set<String>()
        func append(album: String, artist: String, mid: String?) {
            let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !album.isEmpty || !artist.isEmpty || mid != nil else { return }
            let key = "\(LibraryNormalization.normalizeAlbum(album))|\(LibraryNormalization.normalizeArtist(artist))|\(mid ?? "")"
            guard seen.insert(key).inserted else { return }
            queries.append(CatalogQuery(album: album, artist: artist, albumMid: mid))
        }

        if let mid {
            append(album: primaryAlbum, artist: primaryArtist, mid: mid)
        }
        append(album: primaryAlbum, artist: primaryArtist, mid: nil)
        for artist in artistValues.prefix(3) where artist != primaryArtist {
            append(album: primaryAlbum, artist: artist, mid: nil)
        }
        for album in albumValues.dropFirst().prefix(2) {
            append(album: album, artist: primaryArtist, mid: nil)
        }
        return queries
    }

    /// Search-resolved album mids can name a different release with the same
    /// title. The returned album name must agree before the order is stored.
    private func catalogMatchesLocalAlbum(
        _ songs: [QQMusicAlbumSong],
        titles: [String]
    ) -> Bool {
        let localTitles = titles
            .compactMap { trimmed($0) }
            .map { ExternalPlaybackTextNormalizer.normalize($0) }
        guard !localTitles.isEmpty else { return true }
        var bestScore = 0.0
        var hasAlbumName = false
        for song in songs {
            guard let album = trimmed(song.album) else { continue }
            hasAlbumName = true
            let normalizedAlbum = ExternalPlaybackTextNormalizer.normalize(album)
            for localTitle in localTitles {
                bestScore = max(
                    bestScore,
                    ExternalPlaybackTextNormalizer.stringSimilarity(localTitle, normalizedAlbum)
                )
            }
        }
        return !hasAlbumName || bestScore >= 0.72
    }

    private func catalogMatchesLocalArtist(
        _ songs: [QQMusicAlbumSong],
        localArtists: [String],
        isCompilation: Bool
    ) -> Bool {
        guard !isCompilation else { return true }
        let local = localArtists
            .compactMap { trimmed($0) }
            .filter { !LibraryNormalization.isCompilationAlbumType(nil, primaryArtist: $0) }
            .map { ExternalPlaybackTextNormalizer.normalizeArtist($0) }
        guard !local.isEmpty else { return true }
        let songArtists = songs
            .compactMap { trimmed($0.artist) }
            .map { ExternalPlaybackTextNormalizer.normalizeArtist($0) }
        guard !songArtists.isEmpty else { return true }
        var matchCount = 0
        for songArtist in songArtists {
            if local.contains(where: {
                ExternalPlaybackTextNormalizer.artistSimilarity($0, songArtist) >= 0.86
            }) {
                matchCount += 1
            }
        }
        guard matchCount > 0 else { return false }
        if songs.count >= 3,
           Double(matchCount) / Double(songArtists.count) < 0.25 {
            return false
        }
        return true
    }

    private func sidecarArtistMatches(
        _ sidecar: AlbumSidecar,
        tracks: [Track]
    ) -> Bool {
        let sidecarArtist = trimmed(sidecar.primaryArtistDisplayName)
            ?? trimmed(sidecar.primaryArtistCanonicalName)
        guard let sidecarArtist else { return true }
        let trackArtists = uniqueNonEmpty(
            tracks.compactMap { $0.albumArtist }
        )
        guard !trackArtists.isEmpty else { return true }
        let sidecarNormalized = ExternalPlaybackTextNormalizer.normalizeArtist(sidecarArtist)
        return trackArtists.contains {
            ExternalPlaybackTextNormalizer.artistSimilarity(
                sidecarNormalized,
                ExternalPlaybackTextNormalizer.normalizeArtist($0)
            ) >= 0.86
        }
    }

    private func failure(
        candidate: AlbumCandidate,
        reason: AlbumOrderingFailure.Reason,
        detail: String
    ) -> AlbumOrderingFailure {
        failure(
            key: candidate.key,
            title: candidate.title,
            artist: candidate.artist,
            reason: reason,
            detail: detail
        )
    }

    private func failure(
        key: String,
        title: String,
        artist: String,
        reason: AlbumOrderingFailure.Reason,
        detail: String
    ) -> AlbumOrderingFailure {
        AlbumOrderingFailure(
            albumKey: key,
            albumTitle: title,
            artist: artist,
            reason: reason,
            detail: detail
        )
    }
}

private func trimmed(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty ?? true) ? nil : trimmed
}

private func uniqueNonEmpty(_ values: [String?]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
        guard let value = trimmed(value) else { continue }
        let key = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        guard seen.insert(key).inserted else { continue }
        result.append(value)
    }
    return result
}
