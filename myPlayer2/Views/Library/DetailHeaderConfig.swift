//
//  DetailHeaderConfig.swift
//  myPlayer2
//
//  Configuration enum for LibraryDetailHeaderView.
//  Drives content, artwork source, and edit behavior for each selection type.
//

import AppKit
import Foundation

enum DetailHeaderConfig {
    case playlist(Playlist, entry: PlaylistHeaderData)
    case artist(ArtistEntry, stats: ArtistDerivedStats)
    case album(AlbumEntry, stats: AlbumDerivedStats)
}

struct PlaylistHeaderData {
    var description: String
    var tracks: [Track]
}

struct ArtistDerivedStats {
    let trackCount: Int
    let albumCount: Int
    let totalDuration: Double
}

struct AlbumDerivedStats {
    let artistName: String
    let trackCount: Int
    let totalDuration: Double
    let artworkImage: NSImage?
}

enum DetailHeaderArtworkSelectionType: String {
    case playlist
    case artist
    case album
}

enum DetailHeaderArtworkSourceKind: String {
    case custom
    case persistedGenerated
    case newlyGenerated
    case albumFallback
    case placeholder

    var priority: Int {
        switch self {
        case .custom:
            return 500
        case .persistedGenerated:
            return 400
        case .newlyGenerated:
            return 300
        case .albumFallback:
            return 200
        case .placeholder:
            return 100
        }
    }
}

enum DetailHeaderArtworkRequest {
    case playlist(selectionIdentity: String, playlistID: UUID, tracks: [Track])
    case artist(selectionIdentity: String, entry: ArtistEntry)
    case album(selectionIdentity: String, entry: AlbumEntry, fallbackImage: NSImage?)

    var selectionIdentity: String {
        switch self {
        case .playlist(let selectionIdentity, _, _):
            return selectionIdentity
        case .artist(let selectionIdentity, _):
            return selectionIdentity
        case .album(let selectionIdentity, _, _):
            return selectionIdentity
        }
    }

    var selectionType: DetailHeaderArtworkSelectionType {
        switch self {
        case .playlist:
            return .playlist
        case .artist:
            return .artist
        case .album:
            return .album
        }
    }

    var debugSelectionID: String {
        switch self {
        case .playlist(_, let playlistID, _):
            return playlistID.uuidString
        case .artist(_, let entry):
            return entry.id.uuidString
        case .album(_, let entry, _):
            return entry.id.uuidString
        }
    }
}

struct ResolvedHeaderArtwork {
    let selectionIdentity: String
    let selectionType: DetailHeaderArtworkSelectionType
    let source: DetailHeaderArtworkSourceKind
    let image: NSImage?
    let fileURL: URL?
    let generationSignature: String?
}

extension DetailHeaderConfig {
    /// Stable identity for the selected entity.
    var selectionIdentity: String {
        switch self {
        case .playlist(let p, _): return "playlist-\(p.id)"
        case .artist(let e, _): return "artist-\(e.id)"
        case .album(let e, _): return "album-\(e.id)"
        }
    }

    /// Artwork refresh identity. Includes the selected entity and the artwork-relevant revision.
    var artworkIdentity: String {
        switch self {
        case .playlist(_, let entry):
            let signature = PlaylistArtworkGenerator.contentSignature(tracks: entry.tracks)
            return "\(selectionIdentity)-\(signature)"
        case .artist(let entry, _):
            return "\(selectionIdentity)-\(entry.updatedAt.timeIntervalSince1970)-\(entry.artworkFileName ?? "none")-\(Self.artworkFingerprint(data: entry.artworkData))"
        case .album(let entry, let stats):
            let fallbackFingerprint = Self.artworkFingerprint(data: stats.artworkImage?.tiffRepresentation)
            return "\(selectionIdentity)-\(entry.updatedAt.timeIntervalSince1970)-\(entry.artworkFileName ?? "none")-\(Self.artworkFingerprint(data: entry.artworkData))-\(fallbackFingerprint)"
        }
    }

    var selectionTypeLabel: String {
        artworkRequest.selectionType.rawValue
    }

    var artworkRequest: DetailHeaderArtworkRequest {
        switch self {
        case .playlist(let playlist, let entry):
            return .playlist(
                selectionIdentity: selectionIdentity,
                playlistID: playlist.id,
                tracks: entry.tracks
            )
        case .artist(let entry, _):
            return .artist(selectionIdentity: selectionIdentity, entry: entry)
        case .album(let entry, let stats):
            return .album(
                selectionIdentity: selectionIdentity,
                entry: entry,
                fallbackImage: stats.artworkImage
            )
        }
    }

    /// Backward-compatible alias for existing call sites.
    var identity: String { selectionIdentity }

    private static func artworkFingerprint(data: Data?) -> String {
        guard let data else { return "nil" }
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash)
    }
}
