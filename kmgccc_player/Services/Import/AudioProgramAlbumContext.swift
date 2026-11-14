import Foundation

nonisolated struct AudioProgramAlbumContext: Sendable {
    let id: UUID
    let key: String
    let artist: String
}

extension Track {
    nonisolated var audioProgramLookupScope: String? {
        guard let program = audioProgramAlbum else { return nil }
        if let release = musicBrainzReleaseID.flatMap(UUID.init(uuidString:)) { return "release:\(release.uuidString)" }
        return program.key
    }

    nonisolated var audioProgramAlbum: AudioProgramAlbumContext? {
        guard let selection = mediaSelection else { return nil }
        if userMetadataOverride?.albumGroupKey != nil { return nil }
        if isMetadataFieldManual("album"), let sourceAlbum = selection.albumTitle,
           LibraryNormalization.normalizedAlbumKey(album: album) != LibraryNormalization.normalizedAlbumKey(album: sourceAlbum) { return nil }
        let releaseID = musicBrainzReleaseID.flatMap(UUID.init(uuidString:))
        let key = LibraryNormalization.composeAlbumKey(album: album,
            disambiguation: .folder("program-\(selection.groupID.uuidString)"),
            musicBrainzReleaseID: releaseID?.uuidString.lowercased())
        let preferredArtist = isMetadataFieldManual("albumArtist") ? albumArtist : selection.albumArtist
        return AudioProgramAlbumContext(id: selection.albumResourceID ?? releaseID ?? selection.groupID, key: key,
            artist: preferredArtist.flatMap { $0.isEmpty ? nil : $0 } ?? albumArtist ?? artist)
    }
}
