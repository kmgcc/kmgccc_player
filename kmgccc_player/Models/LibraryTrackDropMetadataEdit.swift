import Foundation

nonisolated enum LibraryTrackDropMetadataEdit {
    case artist(name: String, canonicalName: String)
    case album(title: String, artist: String, key: String, musicBrainzReleaseID: String?)

    func apply(to track: Track) {
        var correction = track.userMetadataOverride ?? UserMetadataOverride(editedAt: Date())
        switch self {
        case let .artist(name, canonicalName):
            track.artist = name
            // Preserve composer/producer credits while replacing every artist contributor.
            let otherCredits = track.artistCredits.filter { !$0.role.isArtistContributor }
            let existing = track.artistCredits.first {
                $0.canonicalName == canonicalName && $0.role == .primary
            }
            var primary = existing ?? TrackCredit(displayName: name, canonicalName: canonicalName)
            primary.displayName = name
            track.artistCredits = [primary] + otherCredits
            correction.artistDisplay = name
        case let .album(title, artist, key, releaseID):
            track.album = title
            track.albumArtist = LibraryNormalization.isUnknownArtist(artist) ? nil : artist
            track.musicBrainzReleaseID = releaseID
            correction.album = title
            correction.albumArtist = track.albumArtist
            correction.albumGroupKey = key
        }
        if track.userMetadataOverride != correction {
            correction.editedAt = Date()
            track.userMetadataOverride = correction
        }
    }
}

/// Roll back only fields owned by the drop when a sidecar write fails.
nonisolated struct LibraryTrackDropMetadataSnapshot {
    let artist: String
    let artistCredits: [TrackCredit]
    let album: String
    let albumArtist: String?
    let musicBrainzReleaseID: String?
    let correction: UserMetadataOverride?

    init(_ track: Track) {
        artist = track.artist
        artistCredits = track.artistCredits
        album = track.album
        albumArtist = track.albumArtist
        musicBrainzReleaseID = track.musicBrainzReleaseID
        correction = track.userMetadataOverride
    }

    func matches(_ track: Track) -> Bool {
        artist == track.artist && artistCredits == track.artistCredits && album == track.album
            && albumArtist == track.albumArtist && musicBrainzReleaseID == track.musicBrainzReleaseID
            && correction == track.userMetadataOverride
    }

    func restore(to track: Track) {
        track.artist = artist
        track.artistCredits = artistCredits
        track.album = album
        track.albumArtist = albumArtist
        track.musicBrainzReleaseID = musicBrainzReleaseID
        track.userMetadataOverride = correction
    }
}
