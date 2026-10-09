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
    var artworkFileURL: URL?
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
    var artworkData: Data?
    var createdAt: Date
    var updatedAt: Date

    // Derived fields (populated at sync time, not persisted)
    var trackCount: Int
    var totalDuration: Double
    var isOrphaned: Bool            // runtime-only: true if no matching songs exist
    var hasUserEditedContent: Bool // runtime-only: true when user-edited fields must survive zero-track cleanup

    var isCompilation: Bool {
        LibraryNormalization.isCompilationAlbumType(
            albumType,
            primaryArtist: primaryArtistDisplayName
        )
    }

    var existingArtworkURL: URL? {
        guard let artworkFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: artworkFileURL.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value > 0,
              FileManager.default.isReadableFile(atPath: artworkFileURL.path)
        else { return nil }
        return artworkFileURL
    }

    var hasArtwork: Bool {
        artworkData?.isEmpty == false || existingArtworkURL != nil
    }

    var presentationArtistDisplayName: String {
        isCompilation ? LibraryNormalization.variousArtists : primaryArtistDisplayName
    }

    init(
        id: UUID,
        canonicalKey: String,
        displayTitle: String,
        primaryArtistCanonicalName: String,
        primaryArtistDisplayName: String,
        artworkFileName: String? = nil,
        artworkFileURL: URL? = nil,
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
        isOrphaned: Bool,
        hasUserEditedContent: Bool = false
    ) {
        self.id = id
        self.canonicalKey = canonicalKey
        self.displayTitle = displayTitle
        self.primaryArtistCanonicalName = primaryArtistCanonicalName
        self.primaryArtistDisplayName = primaryArtistDisplayName
        self.artworkFileName = artworkFileName
        self.artworkFileURL = artworkFileURL
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
        self.hasUserEditedContent = hasUserEditedContent
    }
}
