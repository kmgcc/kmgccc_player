//
//  AlbumEntry.swift
//  myPlayer2
//
//  In-memory album metadata loaded from disk sidecar + derived stats from song library.
//

import Foundation

struct AlbumEntry: Identifiable {
    // Persistent fields (from sidecar)
    let id: UUID
    var canonicalKey: String        // normalized logical album key
    var displayTitle: String
    var primaryArtistCanonicalName: String
    var primaryArtistDisplayName: String
    var artworkFileName: String?
    var description: String
    var year: Int?
    var releaseYear: Int?
    var releaseDate: Date?
    var albumType: String
    var genreTags: [String]
    var language: String
    var labelOrCompany: String
    var qqMusicAlbumMid: String?
    var metadataSource: String?
    var metadataFetchedAt: Date?
    var metadataConfidence: Double?
    var artworkData: Data?          // user-set artwork or first track's artwork (not persisted in sidecar)
    var createdAt: Date
    var updatedAt: Date

    // Derived fields (populated at sync time, not persisted)
    var trackCount: Int
    var totalDuration: Double
    var isOrphaned: Bool            // runtime-only: true if no matching songs exist

    init(
        id: UUID,
        canonicalKey: String,
        displayTitle: String,
        primaryArtistCanonicalName: String,
        primaryArtistDisplayName: String,
        artworkFileName: String? = nil,
        description: String = "",
        year: Int? = nil,
        releaseYear: Int? = nil,
        releaseDate: Date? = nil,
        albumType: String = "",
        genreTags: [String] = [],
        language: String = "",
        labelOrCompany: String = "",
        qqMusicAlbumMid: String? = nil,
        metadataSource: String? = nil,
        metadataFetchedAt: Date? = nil,
        metadataConfidence: Double? = nil,
        artworkData: Data? = nil,
        createdAt: Date,
        updatedAt: Date,
        trackCount: Int,
        totalDuration: Double,
        isOrphaned: Bool
    ) {
        self.id = id
        self.canonicalKey = canonicalKey
        self.displayTitle = displayTitle
        self.primaryArtistCanonicalName = primaryArtistCanonicalName
        self.primaryArtistDisplayName = primaryArtistDisplayName
        self.artworkFileName = artworkFileName
        self.description = description
        self.year = year
        self.releaseYear = releaseYear ?? year
        self.releaseDate = releaseDate
        self.albumType = albumType
        self.genreTags = genreTags
        self.language = language
        self.labelOrCompany = labelOrCompany
        self.qqMusicAlbumMid = qqMusicAlbumMid
        self.metadataSource = metadataSource
        self.metadataFetchedAt = metadataFetchedAt
        self.metadataConfidence = metadataConfidence
        self.artworkData = artworkData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trackCount = trackCount
        self.totalDuration = totalDuration
        self.isOrphaned = isOrphaned
    }
}
