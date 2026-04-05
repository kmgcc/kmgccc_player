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

extension DetailHeaderConfig {
    /// Stable string identity used to detect config changes in SwiftUI `.onChange`.
    var identity: String {
        switch self {
        case .playlist(let p, _): return "playlist-\(p.id)"
        case .artist(let e, _): return "artist-\(e.id)"
        case .album(let e, _): return "album-\(e.id)"
        }
    }
}
