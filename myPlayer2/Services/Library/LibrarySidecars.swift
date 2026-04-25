//
//  LibrarySidecars.swift
//  myPlayer2
//
//  kmgccc_player - Library sidecar models (extracted to avoid MainActor inference).
//

import Foundation

struct PlaylistSidecar: Codable, Sendable {
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

struct PlaylistItemSidecar: Codable, Sendable {
    let trackID: UUID
    let addedAt: Date
}

enum PlaylistArtworkSource: String, Codable {
    case none
    case custom
    case generated
}

struct ArtistSidecar: Codable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var canonicalName: String
    var displayName: String
    var artworkFileName: String?
    var description: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        id: UUID,
        canonicalName: String,
        displayName: String,
        artworkFileName: String? = nil,
        description: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.artworkFileName = artworkFileName
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AlbumSidecar: Codable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var canonicalKey: String
    var displayTitle: String
    var primaryArtistCanonicalName: String
    var artworkFileName: String?
    var description: String?
    var year: Int?
    var createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        id: UUID,
        canonicalKey: String,
        displayTitle: String,
        primaryArtistCanonicalName: String,
        artworkFileName: String? = nil,
        description: String? = nil,
        year: Int? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canonicalKey = canonicalKey
        self.displayTitle = displayTitle
        self.primaryArtistCanonicalName = primaryArtistCanonicalName
        self.artworkFileName = artworkFileName
        self.description = description
        self.year = year
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
