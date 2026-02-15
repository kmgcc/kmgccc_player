//
//  LibrarySections.swift
//  myPlayer2
//
//  Runtime-only artist/album sections derived from Music Library scan.
//

import Foundation

struct ArtistSection: Identifiable, Hashable {
    let key: String
    let name: String
    let trackCount: Int

    var id: String { key }
}

struct AlbumSection: Identifiable, Hashable {
    let key: String
    let name: String
    let artistName: String
    let trackCount: Int

    var id: String { key }
}
