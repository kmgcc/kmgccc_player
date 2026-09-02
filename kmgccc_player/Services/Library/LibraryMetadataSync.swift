//
//  LibraryMetadataSync.swift
//  myPlayer2
//
//  Merges song-derived artist/album groupings with persistent disk metadata entries.
//  Called after every library reload. Preserves user-edited fields across syncs.
//

import Foundation

@MainActor
final class LibraryMetadataSync {

    func sync(
        derivedArtists: [ArtistSection],
        derivedAlbums: [AlbumSection],
        allTracks: [Track],
        artistSidecars: [(sidecar: ArtistSidecar, folderURL: URL)],
        albumSidecars: [(sidecar: AlbumSidecar, folderURL: URL)],
        libraryService: LocalLibraryService
    ) throws -> (artists: [ArtistEntry], albums: [AlbumEntry]) {
        let artists = try syncArtists(
            derived: derivedArtists,
            allTracks: allTracks,
            sidecars: artistSidecars,
            libraryService: libraryService
        )
        let albums = try syncAlbums(
            derived: derivedAlbums,
            allTracks: allTracks,
            sidecars: albumSidecars,
            libraryService: libraryService
        )
        return (artists, albums)
    }

    // MARK: - Artist Sync

    private func syncArtists(
        derived: [ArtistSection],
        allTracks: [Track],
        sidecars: [(sidecar: ArtistSidecar, folderURL: URL)],
        libraryService: LocalLibraryService
    ) throws -> [ArtistEntry] {
        var existing = try repairedArtistSidecarsByCanonical(
            sidecars,
            libraryService: libraryService
        )
        let now = Date()

        // Compute album counts per artist canonical key
        var albumCountByArtist: [String: Set<String>] = [:]
        var totalDurationByArtist: [String: Double] = [:]
        for track in allTracks {
            for artistKey in LibraryNormalization.artistCanonicalNames(for: track) {
                albumCountByArtist[artistKey, default: []].insert(track.albumGroupKey)
                totalDurationByArtist[artistKey, default: 0] += track.duration
            }
        }

        var result: [ArtistEntry] = []

        for section in derived {
            // Single-pass aggregate computed above; the previous per-artist
            // `allTracks.filter { containsArtist(...) }` was O(artists × tracks).
            let totalDuration = totalDurationByArtist[section.key] ?? 0
            let albumCount = albumCountByArtist[section.key]?.count ?? 0

            if let (sidecar, folderURL) = existing[section.key] {
                existing.removeValue(forKey: section.key)
                let artworkData = sidecar.artworkFileName.flatMap { fileName in
                    try? Data(contentsOf: folderURL.appendingPathComponent(fileName))
                }
                result.append(ArtistEntry(
                    id: sidecar.id,
                    canonicalName: sidecar.canonicalName,
                    displayName: sidecar.displayName,
                    artworkFileName: sidecar.artworkFileName,
                    description: sidecar.description ?? "",
                    genreTags: sidecar.genreTags,
                    region: sidecar.region ?? "",
                    foreignName: sidecar.foreignName ?? "",
                    qqMusicSingerMid: sidecar.qqMusicSingerMid,
                    metadataSource: sidecar.metadataSource,
                    metadataFetchedAt: sidecar.metadataFetchedAt,
                    metadataConfidence: sidecar.metadataConfidence,
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: section.trackCount,
                    albumCount: albumCount,
                    totalDuration: totalDuration,
                    isOrphaned: false
                ))
            } else {
                let newID = UUID()
                let newSidecar = ArtistSidecar(
                    id: newID,
                    canonicalName: section.key,
                    displayName: section.name,
                    createdAt: now,
                    updatedAt: now
                )
                try libraryService.writeArtistSidecar(newSidecar, artworkData: nil)
                result.append(ArtistEntry(
                    id: newID,
                    canonicalName: section.key,
                    displayName: section.name,
                    artworkFileName: nil,
                    description: "",
                    artworkData: nil,
                    createdAt: now,
                    updatedAt: now,
                    trackCount: section.trackCount,
                    albumCount: albumCount,
                    totalDuration: totalDuration,
                    isOrphaned: false
                ))
            }
        }

        // Handle orphans: keep if user-edited content exists, otherwise delete
        for (_, (sidecar, folderURL)) in existing {
            let hasUserContent =
                !(sidecar.description ?? "").isEmpty
                || sidecar.artworkFileName != nil
                || !sidecar.genreTags.isEmpty
                || !(sidecar.region ?? "").isEmpty
                || !(sidecar.foreignName ?? "").isEmpty
                || sidecar.qqMusicSingerMid != nil
                || sidecar.metadataSource != nil
                || sidecar.trackSortKey != nil
                || sidecar.trackSortOrder != nil
                || sidecar.customTrackOrder != nil
            if hasUserContent {
                let artworkData = sidecar.artworkFileName.flatMap { fileName in
                    try? Data(contentsOf: folderURL.appendingPathComponent(fileName))
                }
                result.append(ArtistEntry(
                    id: sidecar.id,
                    canonicalName: sidecar.canonicalName,
                    displayName: sidecar.displayName,
                    artworkFileName: sidecar.artworkFileName,
                    description: sidecar.description ?? "",
                    genreTags: sidecar.genreTags,
                    region: sidecar.region ?? "",
                    foreignName: sidecar.foreignName ?? "",
                    qqMusicSingerMid: sidecar.qqMusicSingerMid,
                    metadataSource: sidecar.metadataSource,
                    metadataFetchedAt: sidecar.metadataFetchedAt,
                    metadataConfidence: sidecar.metadataConfidence,
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: 0,
                    albumCount: 0,
                    totalDuration: 0,
                    isOrphaned: true
                ))
            } else {
                if FileManager.default.fileExists(atPath: folderURL.path) {
                    try FileManager.default.removeItem(at: folderURL)
                }
            }
        }

        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Album Sync

    private func syncAlbums(
        derived: [AlbumSection],
        allTracks: [Track],
        sidecars: [(sidecar: AlbumSidecar, folderURL: URL)],
        libraryService: LocalLibraryService
    ) throws -> [AlbumEntry] {
        var existing = try repairedAlbumSidecarsByCanonical(
            sidecars,
            libraryService: libraryService
        )
        let now = Date()

        // Single-pass index by album group key; the previous per-album
        // `allTracks.filter { ... }` was O(albums × tracks).
        var tracksByAlbumKey: [String: [Track]] = [:]
        for track in allTracks {
            tracksByAlbumKey[track.albumGroupKey, default: []].append(track)
        }

        var result: [AlbumEntry] = []

        for section in derived {
            let matchingTracks = tracksByAlbumKey[section.key] ?? []
            let totalDuration = matchingTracks.reduce(0) { $0 + $1.duration }
            let firstArtwork =
                matchingTracks.first(where: { $0.artworkData != nil })?.artworkData
                ?? matchingTracks.first?.artworkData

            var matchedSidecars: [(sidecar: AlbumSidecar, folderURL: URL)] = []
            if let exact = existing.removeValue(forKey: section.key) {
                matchedSidecars.append(exact)
            }

            let migratedKeys = existing.keys.filter { key in
                guard let candidate = existing[key] else { return false }
                return shouldMigrateAlbumSidecar(candidate.sidecar, into: section)
            }
            for key in migratedKeys {
                if let candidate = existing.removeValue(forKey: key) {
                    matchedSidecars.append(candidate)
                }
            }

            if let entry = try mergedAlbumEntry(
                from: matchedSidecars,
                section: section,
                firstArtwork: firstArtwork,
                totalDuration: totalDuration,
                now: now,
                libraryService: libraryService
            ) {
                result.append(entry)
            } else {
                let newID = UUID()
                let newSidecar = AlbumSidecar(
                    id: newID,
                    canonicalKey: section.key,
                    displayTitle: section.name,
                    primaryArtistCanonicalName: section.artistCanonicalName,
                    createdAt: now,
                    updatedAt: now
                )
                try libraryService.writeAlbumSidecar(newSidecar, artworkData: nil)
                result.append(AlbumEntry(
                    id: newID,
                    canonicalKey: section.key,
                    displayTitle: section.name,
                    primaryArtistCanonicalName: section.artistCanonicalName,
                    primaryArtistDisplayName: section.artistName,
                    artworkFileName: nil,
                    description: "",
                    year: nil,
                    artworkData: firstArtwork,
                    createdAt: now,
                    updatedAt: now,
                    trackCount: section.trackCount,
                    totalDuration: totalDuration,
                    isOrphaned: false
                ))
            }
        }

        // Handle orphans
        for (_, (sidecar, folderURL)) in existing {
            let hasUserContent =
                !(sidecar.description ?? "").isEmpty
                || sidecar.artworkFileName != nil
                || sidecar.year != nil
                || sidecar.releaseYear != nil
                || sidecar.releaseDate != nil
                || !(sidecar.albumType ?? "").isEmpty
                || !sidecar.genreTags.isEmpty
                || !(sidecar.language ?? "").isEmpty
                || !(sidecar.labelOrCompany ?? "").isEmpty
                || sidecar.qqMusicAlbumMid != nil
                || sidecar.metadataSource != nil
                || sidecar.trackSortKey != nil
                || sidecar.trackSortOrder != nil
                || sidecar.customTrackOrder != nil
            if hasUserContent {
                let artworkData = sidecar.artworkFileName.flatMap { fileName in
                    try? Data(contentsOf: folderURL.appendingPathComponent(fileName))
                }
                result.append(AlbumEntry(
                    id: sidecar.id,
                    canonicalKey: sidecar.canonicalKey,
                    displayTitle: sidecar.displayTitle,
                    primaryArtistCanonicalName: sidecar.primaryArtistCanonicalName,
                    primaryArtistDisplayName: sidecar.primaryArtistDisplayName ?? "",
                    artworkFileName: sidecar.artworkFileName,
                    description: sidecar.description ?? "",
                    year: sidecar.year,
                    releaseYear: sidecar.releaseYear ?? sidecar.year,
                    releaseDate: sidecar.releaseDate,
                    albumType: sidecar.albumType ?? "",
                    genreTags: sidecar.genreTags,
                    language: sidecar.language ?? "",
                    labelOrCompany: sidecar.labelOrCompany ?? "",
                    qqMusicAlbumMid: sidecar.qqMusicAlbumMid,
                    metadataSource: sidecar.metadataSource,
                    metadataFetchedAt: sidecar.metadataFetchedAt,
                    metadataConfidence: sidecar.metadataConfidence,
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: 0,
                    totalDuration: 0,
                    isOrphaned: true
                ))
            } else {
                if FileManager.default.fileExists(atPath: folderURL.path) {
                    try FileManager.default.removeItem(at: folderURL)
                }
            }
        }

        return result.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    private func shouldMigrateAlbumSidecar(_ sidecar: AlbumSidecar, into section: AlbumSection) -> Bool {
        guard LibraryNormalization.normalizeAlbum(sidecar.displayTitle)
            == LibraryNormalization.normalizeAlbum(section.name)
        else {
            return false
        }

        let titleOnlyKey = LibraryNormalization.normalizedAlbumKey(album: section.name)
        if section.key == titleOnlyKey {
            return true
        }

        return sidecar.primaryArtistCanonicalName == section.artistCanonicalName
            || section.memberArtistCanonicalNames.contains(sidecar.primaryArtistCanonicalName)
    }

    private func repairedArtistSidecarsByCanonical(
        _ sidecars: [(sidecar: ArtistSidecar, folderURL: URL)],
        libraryService: LocalLibraryService
    ) throws -> [String: (sidecar: ArtistSidecar, folderURL: URL)] {
        var result: [String: (sidecar: ArtistSidecar, folderURL: URL)] = [:]
        let grouped = Dictionary(grouping: sidecars) { $0.sidecar.canonicalName }

        for (canonicalName, candidates) in grouped {
            guard candidates.count > 1 else {
                if let candidate = candidates.first {
                    result[canonicalName] = candidate
                }
                continue
            }

            let repaired = try repairDuplicateArtistSidecars(
                canonicalName: canonicalName,
                candidates: candidates,
                libraryService: libraryService
            )
            result[canonicalName] = repaired
        }

        return result
    }

    private func repairedAlbumSidecarsByCanonical(
        _ sidecars: [(sidecar: AlbumSidecar, folderURL: URL)],
        libraryService: LocalLibraryService
    ) throws -> [String: (sidecar: AlbumSidecar, folderURL: URL)] {
        var result: [String: (sidecar: AlbumSidecar, folderURL: URL)] = [:]
        let grouped = Dictionary(grouping: sidecars) { $0.sidecar.canonicalKey }

        for (canonicalKey, candidates) in grouped {
            guard candidates.count > 1 else {
                if let candidate = candidates.first {
                    result[canonicalKey] = candidate
                }
                continue
            }

            let repaired = try repairDuplicateAlbumSidecars(
                canonicalKey: canonicalKey,
                candidates: candidates,
                libraryService: libraryService
            )
            result[canonicalKey] = repaired
        }

        return result
    }

    private func repairDuplicateArtistSidecars(
        canonicalName: String,
        candidates: [(sidecar: ArtistSidecar, folderURL: URL)],
        libraryService: LocalLibraryService
    ) throws -> (sidecar: ArtistSidecar, folderURL: URL) {
        let sorted = sortedArtistSidecarCandidates(candidates)
        let keeper = sorted[0]
        let artworkCandidate = bestArtistArtworkCandidate(from: sorted)
        let mergedSidecar = mergedArtistSidecar(
            canonicalName: canonicalName,
            candidates: sorted,
            keeper: keeper,
            artworkFileName: artworkCandidate?.sidecar.artworkFileName
        )
        let artworkData = artworkCandidate?.data

        Log.warning(
            "[LibraryMetadataSync] duplicate artist sidecars canonical=\(canonicalName) count=\(candidates.count) ids=\(candidates.map { $0.sidecar.id.uuidString }) paths=\(candidates.map { $0.folderURL.path }) keeper=\(keeper.sidecar.id.uuidString) mergedArtwork=\(mergedSidecar.artworkFileName ?? "nil") mergedDescription=\((mergedSidecar.description ?? "").isEmpty ? "empty" : "filled") mergedTags=\(mergedSidecar.genreTags.count)",
            category: .library
        )

        try libraryService.writeArtistSidecar(
            mergedSidecar,
            artworkData: mergedSidecar.artworkFileName != nil ? artworkData : nil
        )
        for duplicate in sorted.dropFirst() {
            try libraryService.deleteArtistEntry(id: duplicate.sidecar.id)
        }
        return (mergedSidecar, keeper.folderURL)
    }

    private func repairDuplicateAlbumSidecars(
        canonicalKey: String,
        candidates: [(sidecar: AlbumSidecar, folderURL: URL)],
        libraryService: LocalLibraryService
    ) throws -> (sidecar: AlbumSidecar, folderURL: URL) {
        let sorted = sortedAlbumSidecarCandidates(candidates)
        let keeper = sorted[0]
        let artworkCandidate = bestAlbumArtworkCandidate(from: sorted)
        let mergedSidecar = mergedAlbumSidecar(
            canonicalKey: canonicalKey,
            candidates: sorted,
            keeper: keeper,
            artworkFileName: artworkCandidate?.sidecar.artworkFileName
        )
        let artworkData = artworkCandidate?.data

        Log.warning(
            "[LibraryMetadataSync] duplicate album sidecars canonicalKey=\(canonicalKey) count=\(candidates.count) ids=\(candidates.map { $0.sidecar.id.uuidString }) paths=\(candidates.map { $0.folderURL.path }) keeper=\(keeper.sidecar.id.uuidString) mergedArtwork=\(mergedSidecar.artworkFileName ?? "nil") mergedDescription=\((mergedSidecar.description ?? "").isEmpty ? "empty" : "filled") mergedTags=\(mergedSidecar.genreTags.count)",
            category: .library
        )

        try libraryService.writeAlbumSidecar(
            mergedSidecar,
            artworkData: mergedSidecar.artworkFileName != nil ? artworkData : nil
        )
        for duplicate in sorted.dropFirst() {
            try libraryService.deleteAlbumEntry(id: duplicate.sidecar.id)
        }
        return (mergedSidecar, keeper.folderURL)
    }

    private func sortedArtistSidecarCandidates(
        _ candidates: [(sidecar: ArtistSidecar, folderURL: URL)]
    ) -> [(sidecar: ArtistSidecar, folderURL: URL)] {
        candidates.sorted { lhs, rhs in
            let lhsScore = artistSidecarContentScore(lhs)
            let rhsScore = artistSidecarContentScore(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.sidecar.updatedAt > rhs.sidecar.updatedAt
        }
    }

    private func sortedAlbumSidecarCandidates(
        _ candidates: [(sidecar: AlbumSidecar, folderURL: URL)]
    ) -> [(sidecar: AlbumSidecar, folderURL: URL)] {
        candidates.sorted { lhs, rhs in
            let lhsScore = albumSidecarContentScore(lhs)
            let rhsScore = albumSidecarContentScore(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.sidecar.updatedAt > rhs.sidecar.updatedAt
        }
    }

    private func artistSidecarContentScore(_ candidate: (sidecar: ArtistSidecar, folderURL: URL)) -> Int {
        var score = 0
        if artistArtworkData(candidate) != nil { score += 8 }
        if !(candidate.sidecar.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 5 }
        score += min(candidate.sidecar.genreTags.count, 5)
        if !(candidate.sidecar.region ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 1 }
        if !(candidate.sidecar.foreignName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 1 }
        if candidate.sidecar.qqMusicSingerMid != nil { score += 2 }
        if candidate.sidecar.metadataSource != nil { score += 1 }
        if candidate.sidecar.trackSortKey != nil || candidate.sidecar.trackSortOrder != nil { score += 4 }
        if candidate.sidecar.customTrackOrder != nil { score += 6 }
        return score
    }

    private func albumSidecarContentScore(_ candidate: (sidecar: AlbumSidecar, folderURL: URL)) -> Int {
        var score = 0
        if albumArtworkData(candidate) != nil { score += 8 }
        if !(candidate.sidecar.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 5 }
        score += min(candidate.sidecar.genreTags.count, 5)
        if candidate.sidecar.year != nil || candidate.sidecar.releaseYear != nil || candidate.sidecar.releaseDate != nil { score += 2 }
        if !(candidate.sidecar.albumType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 1 }
        if !(candidate.sidecar.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 1 }
        if !(candidate.sidecar.labelOrCompany ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 1 }
        if candidate.sidecar.qqMusicAlbumMid != nil { score += 2 }
        if candidate.sidecar.metadataSource != nil { score += 1 }
        if candidate.sidecar.trackSortKey != nil || candidate.sidecar.trackSortOrder != nil { score += 4 }
        if candidate.sidecar.customTrackOrder != nil { score += 6 }
        return score
    }

    private func bestArtistArtworkCandidate(
        from candidates: [(sidecar: ArtistSidecar, folderURL: URL)]
    ) -> (sidecar: ArtistSidecar, folderURL: URL, data: Data)? {
        candidates.compactMap { candidate -> (sidecar: ArtistSidecar, folderURL: URL, data: Data)? in
            guard let data = artistArtworkData(candidate) else { return nil }
            return (candidate.sidecar, candidate.folderURL, data)
        }.max { lhs, rhs in lhs.data.count < rhs.data.count }
    }

    private func bestAlbumArtworkCandidate(
        from candidates: [(sidecar: AlbumSidecar, folderURL: URL)]
    ) -> (sidecar: AlbumSidecar, folderURL: URL, data: Data)? {
        candidates.compactMap { candidate -> (sidecar: AlbumSidecar, folderURL: URL, data: Data)? in
            guard let data = albumArtworkData(candidate) else { return nil }
            return (candidate.sidecar, candidate.folderURL, data)
        }.max { lhs, rhs in lhs.data.count < rhs.data.count }
    }

    private func artistArtworkData(_ candidate: (sidecar: ArtistSidecar, folderURL: URL)) -> Data? {
        guard let fileName = candidate.sidecar.artworkFileName else { return nil }
        return try? Data(contentsOf: candidate.folderURL.appendingPathComponent(fileName))
    }

    private func albumArtworkData(_ candidate: (sidecar: AlbumSidecar, folderURL: URL)) -> Data? {
        guard let fileName = candidate.sidecar.artworkFileName else { return nil }
        return try? Data(contentsOf: candidate.folderURL.appendingPathComponent(fileName))
    }

    private func mergedArtistSidecar(
        canonicalName: String,
        candidates: [(sidecar: ArtistSidecar, folderURL: URL)],
        keeper: (sidecar: ArtistSidecar, folderURL: URL),
        artworkFileName: String?
    ) -> ArtistSidecar {
        ArtistSidecar(
            id: keeper.sidecar.id,
            canonicalName: canonicalName,
            displayName: firstNonEmpty(candidates.map(\.sidecar.displayName)) ?? keeper.sidecar.displayName,
            artworkFileName: artworkFileName,
            description: firstNonEmpty(candidates.map(\.sidecar.description)),
            genreTags: mergedTags(candidates.flatMap(\.sidecar.genreTags)),
            region: firstNonEmpty(candidates.map(\.sidecar.region)),
            foreignName: firstNonEmpty(candidates.map(\.sidecar.foreignName)),
            qqMusicSingerMid: firstNonEmpty(candidates.map(\.sidecar.qqMusicSingerMid)),
            metadataSource: firstNonEmpty(candidates.map(\.sidecar.metadataSource)),
            metadataFetchedAt: candidates.compactMap(\.sidecar.metadataFetchedAt).max(),
            metadataConfidence: candidates.compactMap(\.sidecar.metadataConfidence).max(),
            createdAt: candidates.map(\.sidecar.createdAt).min() ?? keeper.sidecar.createdAt,
            updatedAt: Date(),
            trackSortKey: firstNonEmpty(candidates.map(\.sidecar.trackSortKey)),
            trackSortOrder: firstNonEmpty(candidates.map(\.sidecar.trackSortOrder)),
            customTrackOrder: firstNonEmptyUUIDArray(candidates.map(\.sidecar.customTrackOrder))
        )
    }

    private func mergedAlbumSidecar(
        canonicalKey: String,
        candidates: [(sidecar: AlbumSidecar, folderURL: URL)],
        keeper: (sidecar: AlbumSidecar, folderURL: URL),
        artworkFileName: String?
    ) -> AlbumSidecar {
        AlbumSidecar(
            id: keeper.sidecar.id,
            canonicalKey: canonicalKey,
            displayTitle: firstNonEmpty(candidates.map(\.sidecar.displayTitle)) ?? keeper.sidecar.displayTitle,
            primaryArtistCanonicalName: firstNonEmpty(candidates.map(\.sidecar.primaryArtistCanonicalName)) ?? keeper.sidecar.primaryArtistCanonicalName,
            primaryArtistDisplayName: firstNonEmpty(candidates.map(\.sidecar.primaryArtistDisplayName)),
            artworkFileName: artworkFileName,
            description: firstNonEmpty(candidates.map(\.sidecar.description)),
            year: candidates.compactMap(\.sidecar.year).first,
            releaseYear: candidates.compactMap { $0.sidecar.releaseYear ?? $0.sidecar.year }.first,
            releaseDate: candidates.compactMap(\.sidecar.releaseDate).max(),
            albumType: firstNonEmpty(candidates.map(\.sidecar.albumType)),
            genreTags: mergedTags(candidates.flatMap(\.sidecar.genreTags)),
            language: firstNonEmpty(candidates.map(\.sidecar.language)),
            labelOrCompany: firstNonEmpty(candidates.map(\.sidecar.labelOrCompany)),
            qqMusicAlbumMid: firstNonEmpty(candidates.map(\.sidecar.qqMusicAlbumMid)),
            metadataSource: firstNonEmpty(candidates.map(\.sidecar.metadataSource)),
            metadataFetchedAt: candidates.compactMap(\.sidecar.metadataFetchedAt).max(),
            metadataConfidence: candidates.compactMap(\.sidecar.metadataConfidence).max(),
            createdAt: candidates.map(\.sidecar.createdAt).min() ?? keeper.sidecar.createdAt,
            updatedAt: Date(),
            trackSortKey: firstNonEmpty(candidates.map(\.sidecar.trackSortKey)),
            trackSortOrder: firstNonEmpty(candidates.map(\.sidecar.trackSortOrder)),
            customTrackOrder: firstNonEmptyUUIDArray(candidates.map(\.sidecar.customTrackOrder))
        )
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }.first
    }

    private func firstNonEmpty(_ values: [String]) -> String? {
        values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private func firstNonEmptyUUIDArray(_ values: [[UUID]?]) -> [UUID]? {
        for value in values {
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func mergedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private func mergedAlbumEntry(
        from candidates: [(sidecar: AlbumSidecar, folderURL: URL)],
        section: AlbumSection,
        firstArtwork: Data?,
        totalDuration: Double,
        now: Date,
        libraryService: LocalLibraryService
    ) throws -> AlbumEntry? {
        guard !candidates.isEmpty else { return nil }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            let lhsHasUserContent =
                !(lhs.sidecar.description ?? "").isEmpty
                || lhs.sidecar.artworkFileName != nil
                || lhs.sidecar.year != nil
                || lhs.sidecar.releaseYear != nil
                || lhs.sidecar.releaseDate != nil
                || !(lhs.sidecar.albumType ?? "").isEmpty
                || !lhs.sidecar.genreTags.isEmpty
                || !(lhs.sidecar.language ?? "").isEmpty
                || !(lhs.sidecar.labelOrCompany ?? "").isEmpty
                || lhs.sidecar.qqMusicAlbumMid != nil
                || lhs.sidecar.metadataSource != nil
                || lhs.sidecar.trackSortKey != nil
                || lhs.sidecar.trackSortOrder != nil
                || lhs.sidecar.customTrackOrder != nil
            let rhsHasUserContent =
                !(rhs.sidecar.description ?? "").isEmpty
                || rhs.sidecar.artworkFileName != nil
                || rhs.sidecar.year != nil
                || rhs.sidecar.releaseYear != nil
                || rhs.sidecar.releaseDate != nil
                || !(rhs.sidecar.albumType ?? "").isEmpty
                || !rhs.sidecar.genreTags.isEmpty
                || !(rhs.sidecar.language ?? "").isEmpty
                || !(rhs.sidecar.labelOrCompany ?? "").isEmpty
                || rhs.sidecar.qqMusicAlbumMid != nil
                || rhs.sidecar.metadataSource != nil
                || rhs.sidecar.trackSortKey != nil
                || rhs.sidecar.trackSortOrder != nil
                || rhs.sidecar.customTrackOrder != nil

            if lhsHasUserContent != rhsHasUserContent {
                return lhsHasUserContent && !rhsHasUserContent
            }
            return lhs.sidecar.updatedAt > rhs.sidecar.updatedAt
        }

        guard let keeper = sortedCandidates.first else { return nil }

        let artworkSource = sortedCandidates.first { candidate in
            guard let fileName = candidate.sidecar.artworkFileName else { return false }
            return (try? Data(contentsOf: candidate.folderURL.appendingPathComponent(fileName))) != nil
        }
        let artworkData = artworkSource.flatMap { candidate in
            candidate.sidecar.artworkFileName.flatMap { fileName in
                try? Data(contentsOf: candidate.folderURL.appendingPathComponent(fileName))
            }
        }
        let mergedDescription = sortedCandidates.compactMap { candidate in
            let description = candidate.sidecar.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (description?.isEmpty ?? true) ? nil : description
        }.first
        let mergedYear = sortedCandidates.compactMap { $0.sidecar.year }.first
        let mergedReleaseYear = sortedCandidates.compactMap { $0.sidecar.releaseYear ?? $0.sidecar.year }.first
        let mergedReleaseDate = sortedCandidates.compactMap { $0.sidecar.releaseDate }.first
        let mergedAlbumType = sortedCandidates.compactMap { candidate in
            let value = candidate.sidecar.albumType?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }.first
        let mergedGenreTags = sortedCandidates.first { !$0.sidecar.genreTags.isEmpty }?.sidecar.genreTags ?? []
        let mergedLanguage = sortedCandidates.compactMap { candidate in
            let value = candidate.sidecar.language?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }.first
        let mergedLabelOrCompany = sortedCandidates.compactMap { candidate in
            let value = candidate.sidecar.labelOrCompany?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }.first
        let mergedQQMusicAlbumMid = sortedCandidates.compactMap { $0.sidecar.qqMusicAlbumMid }.first
        let mergedMetadataSource = sortedCandidates.compactMap { $0.sidecar.metadataSource }.first
        let mergedMetadataFetchedAt = sortedCandidates.compactMap { $0.sidecar.metadataFetchedAt }.first
        let mergedMetadataConfidence = sortedCandidates.compactMap { $0.sidecar.metadataConfidence }.first
        let mergedTrackSortKey = firstNonEmpty(sortedCandidates.map { $0.sidecar.trackSortKey })
        let mergedTrackSortOrder = firstNonEmpty(sortedCandidates.map { $0.sidecar.trackSortOrder })
        let mergedCustomTrackOrder = firstNonEmptyUUIDArray(
            sortedCandidates.map { $0.sidecar.customTrackOrder }
        )

        let hasMergedCandidates = sortedCandidates.count > 1
        let candidateSidecar = AlbumSidecar(
            id: keeper.sidecar.id,
            canonicalKey: section.key,
            displayTitle: section.name,
            primaryArtistCanonicalName: section.artistCanonicalName,
            artworkFileName: artworkSource?.sidecar.artworkFileName,
            description: mergedDescription,
            year: mergedYear,
            releaseYear: mergedReleaseYear,
            releaseDate: mergedReleaseDate,
            albumType: mergedAlbumType,
            genreTags: mergedGenreTags,
            language: mergedLanguage,
            labelOrCompany: mergedLabelOrCompany,
            qqMusicAlbumMid: mergedQQMusicAlbumMid,
            metadataSource: mergedMetadataSource,
            metadataFetchedAt: mergedMetadataFetchedAt,
            metadataConfidence: mergedMetadataConfidence,
            createdAt: sortedCandidates.map { $0.sidecar.createdAt }.min() ?? keeper.sidecar.createdAt,
            updatedAt: keeper.sidecar.updatedAt,
            trackSortKey: mergedTrackSortKey,
            trackSortOrder: mergedTrackSortOrder,
            customTrackOrder: mergedCustomTrackOrder
        )

        let needsSidecarWrite =
            hasMergedCandidates
            || keeper.sidecar.canonicalKey != candidateSidecar.canonicalKey
            || keeper.sidecar.displayTitle != candidateSidecar.displayTitle
            || keeper.sidecar.primaryArtistCanonicalName != candidateSidecar.primaryArtistCanonicalName
            || keeper.sidecar.artworkFileName != candidateSidecar.artworkFileName
            || keeper.sidecar.description != candidateSidecar.description
            || keeper.sidecar.year != candidateSidecar.year
            || keeper.sidecar.releaseYear != candidateSidecar.releaseYear
            || keeper.sidecar.releaseDate != candidateSidecar.releaseDate
            || keeper.sidecar.albumType != candidateSidecar.albumType
            || keeper.sidecar.genreTags != candidateSidecar.genreTags
            || keeper.sidecar.language != candidateSidecar.language
            || keeper.sidecar.labelOrCompany != candidateSidecar.labelOrCompany
            || keeper.sidecar.qqMusicAlbumMid != candidateSidecar.qqMusicAlbumMid
            || keeper.sidecar.metadataSource != candidateSidecar.metadataSource
            || keeper.sidecar.metadataFetchedAt != candidateSidecar.metadataFetchedAt
            || keeper.sidecar.metadataConfidence != candidateSidecar.metadataConfidence
            || keeper.sidecar.trackSortKey != candidateSidecar.trackSortKey
            || keeper.sidecar.trackSortOrder != candidateSidecar.trackSortOrder
            || keeper.sidecar.customTrackOrder != candidateSidecar.customTrackOrder
            || keeper.sidecar.createdAt != candidateSidecar.createdAt

        let mergedSidecar: AlbumSidecar
        if needsSidecarWrite {
            mergedSidecar = AlbumSidecar(
                id: candidateSidecar.id,
                canonicalKey: candidateSidecar.canonicalKey,
                displayTitle: candidateSidecar.displayTitle,
                primaryArtistCanonicalName: candidateSidecar.primaryArtistCanonicalName,
                artworkFileName: candidateSidecar.artworkFileName,
                description: candidateSidecar.description,
                year: candidateSidecar.year,
                releaseYear: candidateSidecar.releaseYear,
                releaseDate: candidateSidecar.releaseDate,
                albumType: candidateSidecar.albumType,
                genreTags: candidateSidecar.genreTags,
                language: candidateSidecar.language,
                labelOrCompany: candidateSidecar.labelOrCompany,
                qqMusicAlbumMid: candidateSidecar.qqMusicAlbumMid,
                metadataSource: candidateSidecar.metadataSource,
                metadataFetchedAt: candidateSidecar.metadataFetchedAt,
                metadataConfidence: candidateSidecar.metadataConfidence,
                createdAt: candidateSidecar.createdAt,
                updatedAt: now,
                trackSortKey: candidateSidecar.trackSortKey,
                trackSortOrder: candidateSidecar.trackSortOrder,
                customTrackOrder: candidateSidecar.customTrackOrder
            )
            try libraryService.writeAlbumSidecar(
                mergedSidecar,
                artworkData: mergedSidecar.artworkFileName != nil ? artworkData : nil
            )
        } else {
            mergedSidecar = keeper.sidecar
        }

        for candidate in sortedCandidates.dropFirst() {
            try libraryService.deleteAlbumEntry(id: candidate.sidecar.id)
        }

        return AlbumEntry(
            id: mergedSidecar.id,
            canonicalKey: mergedSidecar.canonicalKey,
            displayTitle: mergedSidecar.displayTitle,
            primaryArtistCanonicalName: mergedSidecar.primaryArtistCanonicalName,
            primaryArtistDisplayName: section.artistName,
            artworkFileName: mergedSidecar.artworkFileName,
            description: mergedSidecar.description ?? "",
            year: mergedSidecar.year,
            releaseYear: mergedSidecar.releaseYear ?? mergedSidecar.year,
            releaseDate: mergedSidecar.releaseDate,
            albumType: mergedSidecar.albumType ?? "",
            genreTags: mergedSidecar.genreTags,
            language: mergedSidecar.language ?? "",
            labelOrCompany: mergedSidecar.labelOrCompany ?? "",
            qqMusicAlbumMid: mergedSidecar.qqMusicAlbumMid,
            metadataSource: mergedSidecar.metadataSource,
            metadataFetchedAt: mergedSidecar.metadataFetchedAt,
            metadataConfidence: mergedSidecar.metadataConfidence,
            artworkData: artworkData ?? firstArtwork,
            createdAt: mergedSidecar.createdAt,
            updatedAt: mergedSidecar.updatedAt,
            trackCount: section.trackCount,
            totalDuration: totalDuration,
            isOrphaned: false
        )
    }
}
