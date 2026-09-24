//
//  ArtistEntry.swift
//  myPlayer2
//
//  In-memory artist metadata loaded from disk sidecar + derived stats from song library.
//

import Foundation

struct ArtistEntry: Identifiable {
    // Persistent fields (from sidecar)
    let id: UUID
    var canonicalName: String
    var displayName: String
    var artworkFileName: String?
    var artworkFileURL: URL?
    var description: String
    var genreTags: [String]
    var region: String
    var foreignName: String
    var qqMusicSingerMid: String?
    var metadataSource: String?
    var metadataFetchedAt: Date?
    var metadataConfidence: Double?
    var artworkData: Data?
    var createdAt: Date
    var updatedAt: Date

    // Derived fields (populated at sync time, not persisted)
    var trackCount: Int
    var albumCount: Int
    var totalDuration: Double
    var isOrphaned: Bool        // runtime-only: true if no matching songs exist

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

    init(
        id: UUID,
        canonicalName: String,
        displayName: String,
        artworkFileName: String? = nil,
        artworkFileURL: URL? = nil,
        description: String = "",
        genreTags: [String] = [],
        region: String = "",
        foreignName: String = "",
        qqMusicSingerMid: String? = nil,
        metadataSource: String? = nil,
        metadataFetchedAt: Date? = nil,
        metadataConfidence: Double? = nil,
        artworkData: Data? = nil,
        createdAt: Date,
        updatedAt: Date,
        trackCount: Int,
        albumCount: Int,
        totalDuration: Double,
        isOrphaned: Bool
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.artworkFileName = artworkFileName
        self.artworkFileURL = artworkFileURL
        self.description = description
        self.genreTags = genreTags
        self.region = region
        self.foreignName = foreignName
        self.qqMusicSingerMid = qqMusicSingerMid
        self.metadataSource = metadataSource
        self.metadataFetchedAt = metadataFetchedAt
        self.metadataConfidence = metadataConfidence
        self.artworkData = artworkData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.totalDuration = totalDuration
        self.isOrphaned = isOrphaned
    }
}
