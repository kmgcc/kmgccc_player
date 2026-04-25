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
    ) -> (artists: [ArtistEntry], albums: [AlbumEntry]) {
        let artists = syncArtists(
            derived: derivedArtists,
            allTracks: allTracks,
            sidecars: artistSidecars,
            libraryService: libraryService
        )
        let albums = syncAlbums(
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
    ) -> [ArtistEntry] {
        var existing: [String: (sidecar: ArtistSidecar, folderURL: URL)] =
            Dictionary(uniqueKeysWithValues: sidecars.map { ($0.sidecar.canonicalName, $0) })
        let now = Date()

        // Compute album counts per artist canonical key
        var albumCountByArtist: [String: Set<String>] = [:]
        for track in allTracks {
            let artistKey = LibraryNormalization.normalizeArtist(track.artist)
            let albumKey = track.albumGroupKey
            albumCountByArtist[artistKey, default: []].insert(albumKey)
        }

        var result: [ArtistEntry] = []

        for section in derived {
            let totalDuration = allTracks
                .filter { LibraryNormalization.normalizeArtist($0.artist) == section.key }
                .reduce(0) { $0 + $1.duration }
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
                libraryService.writeArtistSidecar(newSidecar, artworkData: nil)
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
                !(sidecar.description ?? "").isEmpty || sidecar.artworkFileName != nil
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
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: 0,
                    albumCount: 0,
                    totalDuration: 0,
                    isOrphaned: true
                ))
            } else {
                try? FileManager.default.removeItem(at: folderURL)
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
    ) -> [AlbumEntry] {
        var existing: [String: (sidecar: AlbumSidecar, folderURL: URL)] =
            Dictionary(uniqueKeysWithValues: sidecars.map { ($0.sidecar.canonicalKey, $0) })
        let now = Date()

        var result: [AlbumEntry] = []

        for section in derived {
            let matchingTracks = allTracks.filter { $0.albumGroupKey == section.key }
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

            if let entry = mergedAlbumEntry(
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
                libraryService.writeAlbumSidecar(newSidecar, artworkData: nil)
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
            if hasUserContent {
                let artworkData = sidecar.artworkFileName.flatMap { fileName in
                    try? Data(contentsOf: folderURL.appendingPathComponent(fileName))
                }
                result.append(AlbumEntry(
                    id: sidecar.id,
                    canonicalKey: sidecar.canonicalKey,
                    displayTitle: sidecar.displayTitle,
                    primaryArtistCanonicalName: sidecar.primaryArtistCanonicalName,
                    primaryArtistDisplayName: "",
                    artworkFileName: sidecar.artworkFileName,
                    description: sidecar.description ?? "",
                    year: sidecar.year,
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: 0,
                    totalDuration: 0,
                    isOrphaned: true
                ))
            } else {
                try? FileManager.default.removeItem(at: folderURL)
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

    private func mergedAlbumEntry(
        from candidates: [(sidecar: AlbumSidecar, folderURL: URL)],
        section: AlbumSection,
        firstArtwork: Data?,
        totalDuration: Double,
        now: Date,
        libraryService: LocalLibraryService
    ) -> AlbumEntry? {
        guard !candidates.isEmpty else { return nil }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            let lhsHasUserContent =
                !(lhs.sidecar.description ?? "").isEmpty
                || lhs.sidecar.artworkFileName != nil
                || lhs.sidecar.year != nil
            let rhsHasUserContent =
                !(rhs.sidecar.description ?? "").isEmpty
                || rhs.sidecar.artworkFileName != nil
                || rhs.sidecar.year != nil

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

        let mergedSidecar = AlbumSidecar(
            id: keeper.sidecar.id,
            canonicalKey: section.key,
            displayTitle: section.name,
            primaryArtistCanonicalName: section.artistCanonicalName,
            artworkFileName: artworkSource?.sidecar.artworkFileName,
            description: mergedDescription,
            year: mergedYear,
            createdAt: sortedCandidates.map { $0.sidecar.createdAt }.min() ?? keeper.sidecar.createdAt,
            updatedAt: now
        )
        libraryService.writeAlbumSidecar(
            mergedSidecar,
            artworkData: mergedSidecar.artworkFileName != nil ? artworkData : nil
        )

        for candidate in sortedCandidates.dropFirst() {
            libraryService.deleteAlbumEntry(id: candidate.sidecar.id)
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
            artworkData: artworkData ?? firstArtwork,
            createdAt: mergedSidecar.createdAt,
            updatedAt: mergedSidecar.updatedAt,
            trackCount: section.trackCount,
            totalDuration: totalDuration,
            isOrphaned: false
        )
    }
}
