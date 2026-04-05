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
        libraryService: LocalLibraryService
    ) -> (artists: [ArtistEntry], albums: [AlbumEntry]) {
        let artists = syncArtists(
            derived: derivedArtists,
            allTracks: allTracks,
            libraryService: libraryService
        )
        let albums = syncAlbums(
            derived: derivedAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        return (artists, albums)
    }

    // MARK: - Artist Sync

    private func syncArtists(
        derived: [ArtistSection],
        allTracks: [Track],
        libraryService: LocalLibraryService
    ) -> [ArtistEntry] {
        let loaded = libraryService.loadArtistSidecarsFromDisk()
        var existing: [String: (sidecar: ArtistSidecar, folderURL: URL)] =
            Dictionary(uniqueKeysWithValues: loaded.map { ($0.sidecar.canonicalName, $0) })
        let now = Date()

        // Compute album counts per artist canonical key
        var albumCountByArtist: [String: Set<String>] = [:]
        for track in allTracks {
            let artistKey = LibraryNormalization.normalizeArtist(track.artist)
            let albumKey = LibraryNormalization.normalizedAlbumKey(
                album: track.album, artist: track.artist)
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
        libraryService: LocalLibraryService
    ) -> [AlbumEntry] {
        let loaded = libraryService.loadAlbumSidecarsFromDisk()
        var existing: [String: (sidecar: AlbumSidecar, folderURL: URL)] =
            Dictionary(uniqueKeysWithValues: loaded.map { ($0.sidecar.canonicalKey, $0) })
        let now = Date()

        var result: [AlbumEntry] = []

        for section in derived {
            let matchingTracks = allTracks.filter {
                LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist)
                    == section.key
            }
            let totalDuration = matchingTracks.reduce(0) { $0 + $1.duration }
            let firstArtwork = matchingTracks.first?.artworkData
            let primaryArtistKey = LibraryNormalization.normalizeArtist(section.artistName)

            if let (sidecar, folderURL) = existing[section.key] {
                existing.removeValue(forKey: section.key)
                let artworkData: Data?
                if let fileName = sidecar.artworkFileName {
                    artworkData = try? Data(contentsOf: folderURL.appendingPathComponent(fileName))
                } else {
                    artworkData = firstArtwork
                }
                result.append(AlbumEntry(
                    id: sidecar.id,
                    canonicalKey: sidecar.canonicalKey,
                    displayTitle: sidecar.displayTitle,
                    primaryArtistCanonicalName: sidecar.primaryArtistCanonicalName,
                    primaryArtistDisplayName: section.artistName,
                    artworkFileName: sidecar.artworkFileName,
                    description: sidecar.description ?? "",
                    year: sidecar.year,
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: section.trackCount,
                    totalDuration: totalDuration,
                    isOrphaned: false
                ))
            } else {
                let newID = UUID()
                let newSidecar = AlbumSidecar(
                    id: newID,
                    canonicalKey: section.key,
                    displayTitle: section.name,
                    primaryArtistCanonicalName: primaryArtistKey,
                    createdAt: now,
                    updatedAt: now
                )
                libraryService.writeAlbumSidecar(newSidecar, artworkData: nil)
                result.append(AlbumEntry(
                    id: newID,
                    canonicalKey: section.key,
                    displayTitle: section.name,
                    primaryArtistCanonicalName: primaryArtistKey,
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
}
