//
//  LibrarySidecars.swift
//  myPlayer2
//
//  kmgccc_player - Library sidecar models (extracted to avoid MainActor inference).
//

import Foundation

nonisolated struct PlaylistSidecar: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let name: String
    let createdAt: Date
    let items: [PlaylistItemSidecar]
    let legacyTrackIDs: [UUID]?
    let description: String?
    let customHeaderArtworkFileName: String?
    let generatedHeaderArtworkFileName: String?
    let headerArtworkSource: PlaylistArtworkSource?
    let generatedArtworkSignature: String?
    let artworkRevision: String?

    var trackIDs: [UUID] {
        if schemaVersion >= 2 {
            return items.map(\.trackID)
        }
        return legacyTrackIDs ?? []
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case createdAt
        case items
        case trackIDs
        case trackIds
        case description
        case customHeaderArtworkFileName
        case generatedHeaderArtworkFileName
        case headerArtworkSource
        case generatedArtworkSignature
        case artworkRevision
        case legacyHeaderArtworkSignature = "headerArtworkSignature"
    }

    init(
        schemaVersion: Int = 4,
        id: UUID,
        name: String,
        description: String? = nil,
        createdAt: Date,
        items: [PlaylistItemSidecar],
        customHeaderArtworkFileName: String? = nil,
        generatedHeaderArtworkFileName: String? = nil,
        headerArtworkSource: PlaylistArtworkSource? = nil,
        generatedArtworkSignature: String? = nil,
        artworkRevision: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.items = items
        self.legacyTrackIDs = nil
        self.customHeaderArtworkFileName = customHeaderArtworkFileName
        self.generatedHeaderArtworkFileName = generatedHeaderArtworkFileName
        self.headerArtworkSource = headerArtworkSource
        self.generatedArtworkSignature = generatedArtworkSignature
        self.artworkRevision = artworkRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        schemaVersion = version
        description = try c.decodeIfPresent(String.self, forKey: .description)
        customHeaderArtworkFileName = try c.decodeIfPresent(
            String.self,
            forKey: .customHeaderArtworkFileName
        )
        generatedHeaderArtworkFileName = try c.decodeIfPresent(
            String.self,
            forKey: .generatedHeaderArtworkFileName
        )
        headerArtworkSource = try c.decodeIfPresent(PlaylistArtworkSource.self, forKey: .headerArtworkSource)
        generatedArtworkSignature =
            try c.decodeIfPresent(String.self, forKey: .generatedArtworkSignature)
            ?? c.decodeIfPresent(String.self, forKey: .legacyHeaderArtworkSignature)
        artworkRevision = try c.decodeIfPresent(String.self, forKey: .artworkRevision)

        if version >= 2 {
            items = try c.decodeIfPresent([PlaylistItemSidecar].self, forKey: .items) ?? []
            legacyTrackIDs = nil
        } else {
            let ids =
                try c.decodeIfPresent([UUID].self, forKey: .trackIDs)
                ?? c.decodeIfPresent([UUID].self, forKey: .trackIds)
                ?? []
            items = []
            legacyTrackIDs = ids
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(4, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(customHeaderArtworkFileName, forKey: .customHeaderArtworkFileName)
        try c.encodeIfPresent(generatedHeaderArtworkFileName, forKey: .generatedHeaderArtworkFileName)
        try c.encodeIfPresent(headerArtworkSource, forKey: .headerArtworkSource)
        try c.encodeIfPresent(generatedArtworkSignature, forKey: .generatedArtworkSignature)
        try c.encodeIfPresent(artworkRevision, forKey: .artworkRevision)
    }
}

nonisolated struct PlaylistItemSidecar: Codable, Sendable {
    let trackID: UUID
    let addedAt: Date
}

nonisolated enum PlaylistArtworkSource: String, Codable, Sendable {
    case none
    case custom
    case generated
}

nonisolated struct ArtistSidecar: Codable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var canonicalName: String
    var displayName: String
    var artworkFileName: String?
    var description: String?
    var genreTags: [String]
    var region: String?
    var foreignName: String?
    var qqMusicSingerMid: String?
    var metadataSource: String?
    var metadataFetchedAt: Date?
    var metadataConfidence: Double?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case canonicalName
        case displayName
        case artworkFileName
        case description
        case genreTags
        case region
        case foreignName
        case qqMusicSingerMid
        case metadataSource
        case metadataFetchedAt
        case metadataConfidence
        case createdAt
        case updatedAt
    }

    init(
        schemaVersion: Int = 2,
        id: UUID,
        canonicalName: String,
        displayName: String,
        artworkFileName: String? = nil,
        description: String? = nil,
        genreTags: [String] = [],
        region: String? = nil,
        foreignName: String? = nil,
        qqMusicSingerMid: String? = nil,
        metadataSource: String? = nil,
        metadataFetchedAt: Date? = nil,
        metadataConfidence: Double? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.artworkFileName = artworkFileName
        self.description = description
        self.genreTags = genreTags
        self.region = region
        self.foreignName = foreignName
        self.qqMusicSingerMid = qqMusicSingerMid
        self.metadataSource = metadataSource
        self.metadataFetchedAt = metadataFetchedAt
        self.metadataConfidence = metadataConfidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        canonicalName = try c.decode(String.self, forKey: .canonicalName)
        displayName = try c.decode(String.self, forKey: .displayName)
        artworkFileName = try c.decodeIfPresent(String.self, forKey: .artworkFileName)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        if let decodedTags = try? c.decode([String].self, forKey: .genreTags) {
            genreTags = decodedTags
        } else if let decodedTags = try? c.decode(String.self, forKey: .genreTags) {
            genreTags = decodedTags
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            genreTags = []
        }
        region = try c.decodeIfPresent(String.self, forKey: .region)
        foreignName = try c.decodeIfPresent(String.self, forKey: .foreignName)
        qqMusicSingerMid = try c.decodeIfPresent(String.self, forKey: .qqMusicSingerMid)
        metadataSource = try c.decodeIfPresent(String.self, forKey: .metadataSource)
        metadataFetchedAt = try c.decodeIfPresent(Date.self, forKey: .metadataFetchedAt)
        metadataConfidence = try c.decodeIfPresent(Double.self, forKey: .metadataConfidence)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(canonicalName, forKey: .canonicalName)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(artworkFileName, forKey: .artworkFileName)
        try c.encodeIfPresent(description, forKey: .description)
        if !genreTags.isEmpty {
            try c.encode(genreTags, forKey: .genreTags)
        }
        try c.encodeIfPresent(region, forKey: .region)
        try c.encodeIfPresent(foreignName, forKey: .foreignName)
        try c.encodeIfPresent(qqMusicSingerMid, forKey: .qqMusicSingerMid)
        try c.encodeIfPresent(metadataSource, forKey: .metadataSource)
        try c.encodeIfPresent(metadataFetchedAt, forKey: .metadataFetchedAt)
        try c.encodeIfPresent(metadataConfidence, forKey: .metadataConfidence)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

nonisolated struct AlbumSidecar: Codable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var canonicalKey: String
    var displayTitle: String
    var primaryArtistCanonicalName: String
    var primaryArtistDisplayName: String?
    var artworkFileName: String?
    var description: String?
    var year: Int?
    var releaseYear: Int?
    var releaseDate: Date?
    var albumType: String?
    var genreTags: [String]
    var language: String?
    var labelOrCompany: String?
    var qqMusicAlbumMid: String?
    var metadataSource: String?
    var metadataFetchedAt: Date?
    var metadataConfidence: Double?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case canonicalKey
        case displayTitle
        case primaryArtistCanonicalName
        case primaryArtistDisplayName
        case artworkFileName
        case description
        case year
        case releaseYear
        case releaseDate
        case albumType
        case genreTags
        case language
        case labelOrCompany
        case qqMusicAlbumMid
        case metadataSource
        case metadataFetchedAt
        case metadataConfidence
        case createdAt
        case updatedAt
    }

    init(
        schemaVersion: Int = 2,
        id: UUID,
        canonicalKey: String,
        displayTitle: String,
        primaryArtistCanonicalName: String,
        primaryArtistDisplayName: String? = nil,
        artworkFileName: String? = nil,
        description: String? = nil,
        year: Int? = nil,
        releaseYear: Int? = nil,
        releaseDate: Date? = nil,
        albumType: String? = nil,
        genreTags: [String] = [],
        language: String? = nil,
        labelOrCompany: String? = nil,
        qqMusicAlbumMid: String? = nil,
        metadataSource: String? = nil,
        metadataFetchedAt: Date? = nil,
        metadataConfidence: Double? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        canonicalKey = try c.decode(String.self, forKey: .canonicalKey)
        displayTitle = try c.decode(String.self, forKey: .displayTitle)
        primaryArtistCanonicalName = try c.decode(String.self, forKey: .primaryArtistCanonicalName)
        primaryArtistDisplayName = try c.decodeIfPresent(String.self, forKey: .primaryArtistDisplayName)
        artworkFileName = try c.decodeIfPresent(String.self, forKey: .artworkFileName)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        releaseYear = try c.decodeIfPresent(Int.self, forKey: .releaseYear) ?? year
        releaseDate = try c.decodeIfPresent(Date.self, forKey: .releaseDate)
        albumType = try c.decodeIfPresent(String.self, forKey: .albumType)
        if let decodedTags = try? c.decode([String].self, forKey: .genreTags) {
            genreTags = decodedTags
        } else if let decodedTags = try? c.decode(String.self, forKey: .genreTags) {
            genreTags = decodedTags
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            genreTags = []
        }
        language = try c.decodeIfPresent(String.self, forKey: .language)
        labelOrCompany = try c.decodeIfPresent(String.self, forKey: .labelOrCompany)
        qqMusicAlbumMid = try c.decodeIfPresent(String.self, forKey: .qqMusicAlbumMid)
        metadataSource = try c.decodeIfPresent(String.self, forKey: .metadataSource)
        metadataFetchedAt = try c.decodeIfPresent(Date.self, forKey: .metadataFetchedAt)
        metadataConfidence = try c.decodeIfPresent(Double.self, forKey: .metadataConfidence)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(canonicalKey, forKey: .canonicalKey)
        try c.encode(displayTitle, forKey: .displayTitle)
        try c.encode(primaryArtistCanonicalName, forKey: .primaryArtistCanonicalName)
        try c.encodeIfPresent(primaryArtistDisplayName, forKey: .primaryArtistDisplayName)
        try c.encodeIfPresent(artworkFileName, forKey: .artworkFileName)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(releaseYear ?? year, forKey: .releaseYear)
        try c.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try c.encodeIfPresent(albumType, forKey: .albumType)
        if !genreTags.isEmpty {
            try c.encode(genreTags, forKey: .genreTags)
        }
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(labelOrCompany, forKey: .labelOrCompany)
        try c.encodeIfPresent(qqMusicAlbumMid, forKey: .qqMusicAlbumMid)
        try c.encodeIfPresent(metadataSource, forKey: .metadataSource)
        try c.encodeIfPresent(metadataFetchedAt, forKey: .metadataFetchedAt)
        try c.encodeIfPresent(metadataConfidence, forKey: .metadataConfidence)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}
