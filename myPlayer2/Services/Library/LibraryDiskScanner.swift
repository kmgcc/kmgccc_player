//
//  LibraryDiskScanner.swift
//  myPlayer2
//
//  Sendable background disk scanner. Returns pure-data snapshot.
//  All FileManager I/O happens off-MainActor.
//

import Foundation

struct LibraryDiskSnapshot: Sendable {
    let trackMetas: [ScannedTrackMeta]
    let playlistSidecars: [PlaylistSidecar]
    let artistSidecars: [(sidecar: ArtistSidecar, folderURL: URL)]
    let albumSidecars: [(sidecar: AlbumSidecar, folderURL: URL)]
}

struct LibraryDiskScanner: Sendable {

    func scanAll() -> LibraryDiskSnapshot {
        let trackMetas = MusicLibraryScanner().scanTracks()
        let playlistSidecars = loadPlaylistSidecars()
        let artistSidecars = loadArtistSidecars()
        let albumSidecars = loadAlbumSidecars()
        return LibraryDiskSnapshot(
            trackMetas: trackMetas,
            playlistSidecars: playlistSidecars,
            artistSidecars: artistSidecars,
            albumSidecars: albumSidecars
        )
    }

    func scanTracksOnly() -> [ScannedTrackMeta] {
        MusicLibraryScanner().scanTracks()
    }

    // MARK: - Playlist Sidecars

    func loadPlaylistSidecars() -> [PlaylistSidecar] {
        let fileManager = FileManager()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var sidecars: [PlaylistSidecar] = []
        let files = (try? fileManager.contentsOfDirectory(
            at: LocalLibraryPaths.playlistsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let sidecar = try? decoder.decode(PlaylistSidecar.self, from: data)
            else { continue }
            sidecars.append(sidecar)
        }
        return sidecars
    }

    // MARK: - Artist Sidecars

    func loadArtistSidecars() -> [(sidecar: ArtistSidecar, folderURL: URL)] {
        let fileManager = FileManager()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let root = LocalLibraryPaths.artistsRootURL
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return entries.compactMap { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let metaURL = folderURL.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let sidecar = try? decoder.decode(ArtistSidecar.self, from: data)
            else { return nil }
            return (sidecar, folderURL)
        }
    }

    // MARK: - Album Sidecars

    func loadAlbumSidecars() -> [(sidecar: AlbumSidecar, folderURL: URL)] {
        let fileManager = FileManager()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let root = LocalLibraryPaths.albumsRootURL
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return entries.compactMap { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let metaURL = folderURL.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let sidecar = try? decoder.decode(AlbumSidecar.self, from: data)
            else { return nil }
            return (sidecar, folderURL)
        }
    }
}
