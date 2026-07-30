//
//  MusicLibraryScanner.swift
//  myPlayer2
//
//  Scan authoritative Music Library sidecars with the shared tolerant model.
//

import Foundation

nonisolated struct ScannedTrackMeta: Sendable {
    let schemaVersion: Int
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
    let description: String
    let genreTags: [String]
    let language: String
    let labelOrCompany: String
    let releaseDate: Date?
    let qqMusicSongMid: String?
    let metadataSource: String?
    let metadataFetchedAt: Date?
    let metadataConfidence: Double?
    let duration: Double
    let addedAt: Date
    let importedAt: Date
    let lyricsTimeOffsetMs: Double
    let originalFilePath: String
    let mediaLocator: TrackMediaLocator
    let availability: TrackAvailability
    let audioFileName: String
    let artworkFileName: String?
    let lyricsFileName: String?
    let ttmlLyricsFileName: String?
    let ncmConversionAssociation: NCMConversionAssociation?
    let playCount: Int?
    let preferenceStats: TrackPreferenceStats?
    let folderURL: URL

    var libraryRelativePath: String {
        mediaLocator.managedLibraryRelativePath ?? ""
    }
}

nonisolated struct MusicLibraryScanner: Sendable {
    private let paths: LibraryPaths

    init(paths: LibraryPaths) {
        self.paths = paths
    }

    func scanTracks() -> [ScannedTrackMeta] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: paths.tracksRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return dirs.filter(\.hasDirectoryPath).compactMap { folder in
            autoreleasepool { parseTrackMeta(in: folder) }
        }
    }

    func scanTracks(ids: [UUID]) -> [ScannedTrackMeta] {
        ids.compactMap { id in
            autoreleasepool { parseTrackMeta(in: paths.trackFolderURL(for: id)) }
        }
    }

    func scanTrackFolder(_ folderURL: URL) -> ScannedTrackMeta? {
        parseTrackMeta(in: folderURL)
    }

    private func parseTrackMeta(in folderURL: URL) -> ScannedTrackMeta? {
        let metaURL = folderURL.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sidecar = try? decoder.decode(TrackSidecar.self, from: data) else { return nil }

        let audioFileName: String
        switch sidecar.mediaLocator {
        case let .managed(relativePath):
            audioFileName = sidecar.audioFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? URL(fileURLWithPath: relativePath).lastPathComponent
            guard !audioFileName.isEmpty else { return nil }
        case .referenced:
            audioFileName = sidecar.audioFileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        return ScannedTrackMeta(
            schemaVersion: sidecar.schemaVersion,
            id: sidecar.id,
            title: LibraryNormalization.displayTitle(sidecar.title),
            artist: LibraryNormalization.displayArtist(sidecar.artist),
            album: LibraryNormalization.displayAlbum(sidecar.album),
            albumArtist: normalizedOptional(sidecar.albumArtist),
            description: sidecar.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            genreTags: sidecar.genreTags.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty },
            language: sidecar.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            labelOrCompany: sidecar.labelOrCompany?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            releaseDate: sidecar.releaseDate,
            qqMusicSongMid: normalizedOptional(sidecar.qqMusicSongMid),
            metadataSource: normalizedOptional(sidecar.metadataSource),
            metadataFetchedAt: sidecar.metadataFetchedAt,
            metadataConfidence: sidecar.metadataConfidence,
            duration: sidecar.duration,
            addedAt: sidecar.addedAt,
            importedAt: sidecar.importedAt ?? sidecar.addedAt,
            lyricsTimeOffsetMs: sidecar.lyricsTimeOffsetMs ?? 0,
            originalFilePath: sidecar.originalFilePath ?? sidecar.mediaLocator.referencedFile?.lastKnownPath ?? "",
            mediaLocator: sidecar.mediaLocator,
            availability: sidecar.availability,
            audioFileName: audioFileName,
            artworkFileName: resolveArtworkFileName(
                in: folderURL,
                preferredFileName: sidecar.artworkFileName
            ),
            lyricsFileName: normalizedOptional(sidecar.lyricsFileName),
            ttmlLyricsFileName: normalizedOptional(sidecar.ttmlLyricsFileName),
            ncmConversionAssociation: sidecar.ncmConversionAssociation,
            playCount: sidecar.playCount,
            preferenceStats: sidecar.preferenceStats,
            folderURL: folderURL
        )
    }

    private func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private func resolveArtworkFileName(in folder: URL, preferredFileName: String?) -> String? {
        for fileName in paths.trackArtworkCandidateFileNames(preferredFileName: preferredFileName) {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path) {
                return fileName
            }
        }
        return normalizedOptional(preferredFileName)
    }
}
