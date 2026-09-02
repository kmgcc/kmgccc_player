//
//  LibrarySidecars.swift
//  myPlayer2
//
//  kmgccc_player - Library sidecar models (extracted to avoid MainActor inference).
//

import Foundation

nonisolated struct NCMConversionAssociation: Codable, Sendable, Equatable {
    let operationID: UUID
    let sourceIdentity: ReferencedFileIdentity?
    let sourcePath: String
    let outputIdentity: ReferencedFileIdentity?
    let outputPath: String
}

// MARK: - Schema 9 Metadata Layers

/// Technical properties of the physical audio file at one location.
/// Different copies of the same recording may carry different encodes,
/// so these live per-location rather than on the track.
nonisolated struct TrackAudioProperties: Codable, Equatable, Hashable, Sendable {
    var format: String?
    /// Codec carried by the audio stream (for example AAC, ALAC, FLAC or
    /// PCM). `format` remains the container/filename format for compatibility.
    var codec: String?
    var bitrateKbps: Int?
    var sampleRateHz: Int?
    var bitDepth: Int?
    var channelCount: Int?

    init(
        format: String? = nil,
        codec: String? = nil,
        bitrateKbps: Int? = nil,
        sampleRateHz: Int? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil
    ) {
        self.format = format
        self.codec = codec
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.channelCount = channelCount
    }
}

/// Raw values captured from the file's embedded tags at a point in time.
/// This is the 文件标签 layer; the display strings are stored verbatim and
/// are not normalized here.
nonisolated struct EmbeddedMetadataSnapshot: Codable, Equatable, Sendable {
    var title: String?
    var artistDisplay: String?
    var album: String?
    var albumArtist: String?
    var releaseYear: Int?
    var compilation: Bool?
    var musicBrainzReleaseID: String?
    var durationSeconds: Double?
    var capturedAt: Date

    init(
        title: String? = nil,
        artistDisplay: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        releaseYear: Int? = nil,
        compilation: Bool? = nil,
        musicBrainzReleaseID: String? = nil,
        durationSeconds: Double? = nil,
        capturedAt: Date
    ) {
        self.title = title
        self.artistDisplay = artistDisplay
        self.album = album
        self.albumArtist = albumArtist
        self.releaseYear = releaseYear
        self.compilation = compilation
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.durationSeconds = durationSeconds
        self.capturedAt = capturedAt
    }
}

/// Values the user corrected by hand. This is the 用户修正 layer and always
/// wins over every automatic source. Fields are optional so an edit session
/// may correct only some values.
nonisolated struct UserMetadataOverride: Codable, Equatable, Sendable {
    var title: String?
    var artistDisplay: String?
    var album: String?
    var albumArtist: String?
    var releaseYear: Int?
    var editedAt: Date

    init(
        title: String? = nil,
        artistDisplay: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        releaseYear: Int? = nil,
        editedAt: Date
    ) {
        self.title = title
        self.artistDisplay = artistDisplay
        self.album = album
        self.albumArtist = albumArtist
        self.releaseYear = releaseYear
        self.editedAt = editedAt
    }
}

/// One trusted completion candidate (e.g. "qq-music", "folder-inference").
/// This is the 可信补全 layer. Candidates are advisory: the projection picks
/// the most confident one and the user can always override it.
nonisolated struct EnrichmentSuggestion: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var source: String
    var title: String?
    var artistDisplay: String?
    var album: String?
    var albumArtist: String?
    var releaseYear: Int?
    var compilation: Bool?
    var musicBrainzReleaseID: String?
    var confidence: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        source: String,
        title: String? = nil,
        artistDisplay: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        releaseYear: Int? = nil,
        compilation: Bool? = nil,
        musicBrainzReleaseID: String? = nil,
        confidence: Double,
        createdAt: Date
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.artistDisplay = artistDisplay
        self.album = album
        self.albumArtist = albumArtist
        self.releaseYear = releaseYear
        self.compilation = compilation
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.confidence = confidence
        self.createdAt = createdAt
    }
}

extension Array where Element == EnrichmentSuggestion {
    /// Deterministic winner for the 可信补全 layer: highest confidence first,
    /// then the newest candidate, then the stable id ordering as a final
    /// tie-break so equal candidates always project identically.
    nonisolated var bestByConfidence: EnrichmentSuggestion? {
        self.max { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Appends candidates without duplicating ids, so re-running an inference
    /// pass over already-suggested tracks never grows the stored set.
    nonisolated mutating func appendDeduplicatingByIDs(_ candidates: [EnrichmentSuggestion]) {
        let knownIDs = Set(map(\.id))
        for candidate in candidates where !knownIDs.contains(candidate.id) {
            append(candidate)
        }
    }
}

/// The resolved display metadata for a track after applying the §10.1 layer
/// priority. Pure value projection: no I/O, no normalization.
nonisolated struct EffectiveMetadata: Equatable, Sendable {
    var title: String
    var artistDisplay: String?
    var album: String?
    var albumArtist: String?
    var releaseYear: Int?
    var compilation: Bool?
    var musicBrainzReleaseID: String?
}

extension EffectiveMetadata {
    /// Projects layered values that do not yet live on a persisted sidecar
    /// (candidate preparation) through the exact same §10.1 priority chain.
    /// When every layer is nil the result equals the plain filename-fallback
    /// projection, so callers keep their existing behavior until a layer
    /// actually contributes a value.
    nonisolated static func project(
        embedded: EmbeddedMetadataSnapshot?,
        override: UserMetadataOverride? = nil,
        suggestions: [EnrichmentSuggestion]? = nil,
        rootMusicBrainzReleaseID: String? = nil,
        fileNameFallback: String? = nil
    ) -> EffectiveMetadata {
        let sidecar = TrackSidecar(
            id: UUID(),
            title: "",
            artist: "",
            album: "",
            musicBrainzReleaseID: rootMusicBrainzReleaseID,
            duration: 0,
            addedAt: Date(),
            importedAt: nil,
            lyricsTimeOffsetMs: nil,
            originalFilePath: nil,
            audioFileName: nil,
            artworkFileName: nil,
            lyricsFileName: nil,
            lyricsType: nil,
            ttmlLyricsFileName: nil,
            ncmSourcePath: nil,
            embeddedMetadataSnapshot: embedded,
            userMetadataOverride: override,
            enrichmentSuggestions: suggestions
        )
        return project(sidecar: sidecar, fileNameFallback: fileNameFallback)
    }

    /// Projects the layered sidecar fields onto effective display values.
    ///
    /// Priority per field: 用户修正 (`userMetadataOverride`) > 文件标签
    /// (`embeddedMetadataSnapshot`) > 可信补全 (highest-confidence
    /// `enrichmentSuggestions` entry) > 文件名兜底 (`fileNameFallback`,
    /// applied to the title only). When every layer is absent the projection
    /// is empty apart from the filename fallback, so callers can keep their
    /// existing behavior until a layer actually contributes a value. The
    /// root-level `musicBrainzReleaseID` stays ahead of the layers because it
    /// is already a promoted, authoritative value.
    nonisolated static func project(
        sidecar: TrackSidecar,
        fileNameFallback: String? = nil
    ) -> EffectiveMetadata {
        let override = sidecar.userMetadataOverride
        let embedded = sidecar.embeddedMetadataSnapshot
        let suggestion = sidecar.enrichmentSuggestions?.bestByConfidence

        return EffectiveMetadata(
            title: firstNonEmpty(
                override?.title,
                embedded?.title,
                suggestion?.title,
                fileNameFallback
            ) ?? "",
            artistDisplay: firstNonEmpty(
                override?.artistDisplay,
                embedded?.artistDisplay,
                suggestion?.artistDisplay
            ),
            album: firstNonEmpty(
                override?.album,
                embedded?.album,
                suggestion?.album
            ),
            albumArtist: firstNonEmpty(
                override?.albumArtist,
                embedded?.albumArtist,
                suggestion?.albumArtist
            ),
            releaseYear: override?.releaseYear ?? embedded?.releaseYear ?? suggestion?.releaseYear,
            compilation: embedded?.compilation ?? suggestion?.compilation,
            musicBrainzReleaseID: sidecar.musicBrainzReleaseID
                ?? embedded?.musicBrainzReleaseID
                ?? suggestion?.musicBrainzReleaseID
        )
    }

    nonisolated private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// Root-level import identity capture for managed tracks (schema 9). Managed
/// copies have no referenced location struct, so the fingerprint of the
/// original scanned file — plus any content digest computed on demand by the
/// identity resolver during a later re-import — lives here.
nonisolated struct ImportProvenance: Codable, Equatable, Sendable {
    var originalFingerprint: ReferencedFileFingerprint?
    var contentDigest: String?

    init(
        originalFingerprint: ReferencedFileFingerprint? = nil,
        contentDigest: String? = nil
    ) {
        self.originalFingerprint = originalFingerprint
        self.contentDigest = contentDigest
    }
}

nonisolated struct TrackSidecar: Codable, Sendable {
    static let currentSchemaVersion = 9

    let schemaVersion: Int
    let id: UUID
    let title: String
    let artist: String
    let artistCredits: [TrackCredit]?
    let album: String
    let albumArtist: String?
    let description: String?
    let genreTags: [String]
    let language: String?
    let labelOrCompany: String?
    let releaseDate: Date?
    let qqMusicSongMid: String?
    let metadataSource: String?
    let metadataFetchedAt: Date?
    let metadataConfidence: Double?
    /// MusicBrainz release identifier for the recording (schema 9). Storage
    /// only until the enrichment wave populates it.
    let musicBrainzReleaseID: String?
    let duration: Double
    let addedAt: Date
    let importedAt: Date?
    let lyricsTimeOffsetMs: Double?
    let originalFilePath: String?
    let audioFileName: String?
    let artworkFileName: String?
    let lyricsFileName: String?
    let lyricsType: String?
    let ttmlLyricsFileName: String?
    let ncmSourcePath: String?
    let ncmSourceIdentity: ReferencedFileIdentity?
    let ncmConversionAssociation: NCMConversionAssociation?
    let playCount: Int?
    let preferenceStats: TrackPreferenceStats?
    let mediaLocator: TrackMediaLocator
    let availability: TrackAvailability
    // Schema 9 metadata layers. All optional with nil defaults so v1-v8
    // payloads decode unchanged; producers arrive in later waves.
    let embeddedMetadataSnapshot: EmbeddedMetadataSnapshot?
    let userMetadataOverride: UserMetadataOverride?
    let enrichmentSuggestions: [EnrichmentSuggestion]?
    let importProvenance: ImportProvenance?
    /// Technical properties of the managed audio copy (schema 9). Referenced
    /// tracks keep these on their locator instead; managed copies have no
    /// location struct, so the root slot carries them.
    let audioProperties: TrackAudioProperties?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, artist, artistCredits, album, albumArtist, description, genreTags
        case language, labelOrCompany, releaseDate, qqMusicSongMid, metadataSource
        case metadataFetchedAt, metadataConfidence, musicBrainzReleaseID, duration, addedAt, importedAt
        case lyricsTimeOffsetMs, originalFilePath, audioFileName, artworkFileName
        case lyricsFileName, lyricsType, ttmlLyricsFileName, ncmSourcePath
        case ncmSourceIdentity, ncmConversionAssociation, playCount, preferenceStats, mediaLocator, availability
        case embeddedMetadataSnapshot, userMetadataOverride, enrichmentSuggestions
        case importProvenance
        case audioProperties
    }

    init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID,
        title: String,
        artist: String,
        artistCredits: [TrackCredit]? = nil,
        album: String,
        albumArtist: String? = nil,
        description: String? = nil,
        genreTags: [String] = [],
        language: String? = nil,
        labelOrCompany: String? = nil,
        releaseDate: Date? = nil,
        qqMusicSongMid: String? = nil,
        metadataSource: String? = nil,
        metadataFetchedAt: Date? = nil,
        metadataConfidence: Double? = nil,
        musicBrainzReleaseID: String? = nil,
        duration: Double,
        addedAt: Date,
        importedAt: Date?,
        lyricsTimeOffsetMs: Double?,
        originalFilePath: String?,
        audioFileName: String?,
        artworkFileName: String?,
        lyricsFileName: String?,
        lyricsType: String?,
        ttmlLyricsFileName: String?,
        ncmSourcePath: String?,
        ncmSourceIdentity: ReferencedFileIdentity? = nil,
        ncmConversionAssociation: NCMConversionAssociation? = nil,
        playCount: Int? = 0,
        preferenceStats: TrackPreferenceStats? = nil,
        mediaLocator: TrackMediaLocator? = nil,
        availability: TrackAvailability = .available,
        embeddedMetadataSnapshot: EmbeddedMetadataSnapshot? = nil,
        userMetadataOverride: UserMetadataOverride? = nil,
        enrichmentSuggestions: [EnrichmentSuggestion]? = nil,
        importProvenance: ImportProvenance? = nil,
        audioProperties: TrackAudioProperties? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.artist = artist
        self.artistCredits = artistCredits
        self.album = album
        self.albumArtist = albumArtist
        self.description = description
        self.genreTags = genreTags
        self.language = language
        self.labelOrCompany = labelOrCompany
        self.releaseDate = releaseDate
        self.qqMusicSongMid = qqMusicSongMid
        self.metadataSource = metadataSource
        self.metadataFetchedAt = metadataFetchedAt
        self.metadataConfidence = metadataConfidence
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.duration = duration
        self.addedAt = addedAt
        self.importedAt = importedAt
        self.lyricsTimeOffsetMs = lyricsTimeOffsetMs
        self.originalFilePath = originalFilePath
        self.audioFileName = audioFileName
        self.artworkFileName = artworkFileName
        self.lyricsFileName = lyricsFileName
        self.lyricsType = lyricsType
        self.ttmlLyricsFileName = ttmlLyricsFileName
        self.ncmSourcePath = ncmSourcePath
        self.ncmSourceIdentity = ncmSourceIdentity
        self.ncmConversionAssociation = ncmConversionAssociation
        self.playCount = playCount
        self.preferenceStats = preferenceStats
        self.mediaLocator = mediaLocator ?? .managed(
            libraryRelativePath: "Tracks/\(id.uuidString)/\(audioFileName ?? "audio")"
        )
        self.availability = availability
        self.embeddedMetadataSnapshot = embeddedMetadataSnapshot
        self.userMetadataOverride = userMetadataOverride
        self.enrichmentSuggestions = enrichmentSuggestions
        self.importProvenance = importProvenance
        self.audioProperties = audioProperties
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: c,
                debugDescription: "Unsupported track sidecar schema \(schemaVersion)"
            )
        }
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        artistCredits = try c.decodeIfPresent([TrackCredit].self, forKey: .artistCredits)
        album = try c.decode(String.self, forKey: .album)
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        if let tags = try? c.decode([String].self, forKey: .genreTags) {
            genreTags = tags
        } else if let tags = try? c.decode(String.self, forKey: .genreTags) {
            genreTags = tags.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        } else {
            genreTags = []
        }
        language = try c.decodeIfPresent(String.self, forKey: .language)
        labelOrCompany = try c.decodeIfPresent(String.self, forKey: .labelOrCompany)
        releaseDate = try c.decodeIfPresent(Date.self, forKey: .releaseDate)
        qqMusicSongMid = try c.decodeIfPresent(String.self, forKey: .qqMusicSongMid)
        metadataSource = try c.decodeIfPresent(String.self, forKey: .metadataSource)
        metadataFetchedAt = try c.decodeIfPresent(Date.self, forKey: .metadataFetchedAt)
        metadataConfidence = try c.decodeIfPresent(Double.self, forKey: .metadataConfidence)
        musicBrainzReleaseID = try c.decodeIfPresent(String.self, forKey: .musicBrainzReleaseID)
        duration = try c.decode(Double.self, forKey: .duration)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt)
        lyricsTimeOffsetMs = try c.decodeIfPresent(Double.self, forKey: .lyricsTimeOffsetMs)
        originalFilePath = try c.decodeIfPresent(String.self, forKey: .originalFilePath)
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        artworkFileName = try c.decodeIfPresent(String.self, forKey: .artworkFileName)
        lyricsFileName = try c.decodeIfPresent(String.self, forKey: .lyricsFileName)
        lyricsType = try c.decodeIfPresent(String.self, forKey: .lyricsType)
        ttmlLyricsFileName = try c.decodeIfPresent(String.self, forKey: .ttmlLyricsFileName)
        ncmSourcePath = try c.decodeIfPresent(String.self, forKey: .ncmSourcePath)
        ncmSourceIdentity = try c.decodeIfPresent(ReferencedFileIdentity.self, forKey: .ncmSourceIdentity)
        ncmConversionAssociation = try c.decodeIfPresent(NCMConversionAssociation.self, forKey: .ncmConversionAssociation)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        if let stats = try c.decodeIfPresent(TrackPreferenceStats.self, forKey: .preferenceStats) {
            preferenceStats = stats
        } else if schemaVersion < 3, let playCount, playCount > 0 {
            preferenceStats = TrackPreferenceStats.fromLegacy(playCount: playCount)
        } else {
            preferenceStats = nil
        }
        // Schema 7 introduced the locator/availability payload; schema 8 only
        // adds structured artist credits and must not downgrade schema-7
        // referenced tracks to the legacy managed-path branch. Schema 9 adds
        // the metadata layers and per-location fields, which decode
        // tolerantly above and below without touching this branch.
        if schemaVersion >= 7 {
            mediaLocator = try c.decode(TrackMediaLocator.self, forKey: .mediaLocator)
            availability = try c.decodeIfPresent(TrackAvailability.self, forKey: .availability) ?? .available
        } else {
            guard let audioFileName, !audioFileName.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .audioFileName,
                    in: c,
                    debugDescription: "Legacy managed sidecar has no audio file name"
                )
            }
            mediaLocator = .managed(
                libraryRelativePath: "Tracks/\(id.uuidString)/\(audioFileName)"
            )
            availability = .available
        }
        embeddedMetadataSnapshot = try c.decodeIfPresent(EmbeddedMetadataSnapshot.self, forKey: .embeddedMetadataSnapshot)
        userMetadataOverride = try c.decodeIfPresent(UserMetadataOverride.self, forKey: .userMetadataOverride)
        enrichmentSuggestions = try c.decodeIfPresent([EnrichmentSuggestion].self, forKey: .enrichmentSuggestions) ?? []
        importProvenance = try c.decodeIfPresent(ImportProvenance.self, forKey: .importProvenance)
        audioProperties = try c.decodeIfPresent(TrackAudioProperties.self, forKey: .audioProperties)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encodeIfPresent(artistCredits, forKey: .artistCredits)
        try c.encode(album, forKey: .album)
        try c.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try c.encodeIfPresent(description, forKey: .description)
        if !genreTags.isEmpty { try c.encode(genreTags, forKey: .genreTags) }
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(labelOrCompany, forKey: .labelOrCompany)
        try c.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try c.encodeIfPresent(qqMusicSongMid, forKey: .qqMusicSongMid)
        try c.encodeIfPresent(metadataSource, forKey: .metadataSource)
        try c.encodeIfPresent(metadataFetchedAt, forKey: .metadataFetchedAt)
        try c.encodeIfPresent(metadataConfidence, forKey: .metadataConfidence)
        try c.encodeIfPresent(musicBrainzReleaseID, forKey: .musicBrainzReleaseID)
        try c.encode(duration, forKey: .duration)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(importedAt, forKey: .importedAt)
        try c.encodeIfPresent(lyricsTimeOffsetMs, forKey: .lyricsTimeOffsetMs)
        try c.encodeIfPresent(originalFilePath, forKey: .originalFilePath)
        try c.encodeIfPresent(audioFileName, forKey: .audioFileName)
        try c.encodeIfPresent(artworkFileName, forKey: .artworkFileName)
        try c.encodeIfPresent(lyricsFileName, forKey: .lyricsFileName)
        try c.encodeIfPresent(lyricsType, forKey: .lyricsType)
        try c.encodeIfPresent(ttmlLyricsFileName, forKey: .ttmlLyricsFileName)
        try c.encodeIfPresent(ncmSourcePath, forKey: .ncmSourcePath)
        try c.encodeIfPresent(ncmSourceIdentity, forKey: .ncmSourceIdentity)
        try c.encodeIfPresent(ncmConversionAssociation, forKey: .ncmConversionAssociation)
        try c.encodeIfPresent(preferenceStats, forKey: .preferenceStats)
        try c.encode(mediaLocator, forKey: .mediaLocator)
        try c.encode(availability, forKey: .availability)
        try c.encodeIfPresent(embeddedMetadataSnapshot, forKey: .embeddedMetadataSnapshot)
        try c.encodeIfPresent(userMetadataOverride, forKey: .userMetadataOverride)
        if let enrichmentSuggestions, !enrichmentSuggestions.isEmpty {
            try c.encode(enrichmentSuggestions, forKey: .enrichmentSuggestions)
        }
        try c.encodeIfPresent(importProvenance, forKey: .importProvenance)
        try c.encodeIfPresent(audioProperties, forKey: .audioProperties)
    }
}

/// Track-level ordering state owned by one music library. The optional raw
/// values keep this file forward-compatible with libraries created before
/// sorting became library data.
nonisolated struct LibraryTrackSortState: Codable, Sendable, Equatable {
    var sortKey: String?
    var sortOrder: String?

    init(sortKey: String? = nil, sortOrder: String? = nil) {
        self.sortKey = sortKey
        self.sortOrder = sortOrder
    }
}

/// Collection-page ordering state owned by one music library.
nonisolated struct LibraryCollectionSortState: Codable, Sendable, Equatable {
    var sortKey: String?
    var sortOrder: String?
    var customItemOrder: [UUID]?

    init(
        sortKey: String? = nil,
        sortOrder: String? = nil,
        customItemOrder: [UUID]? = nil
    ) {
        self.sortKey = sortKey
        self.sortOrder = sortOrder
        self.customItemOrder = customItemOrder
    }
}

/// Library-scoped sorting defaults and collection ordering. This must live
/// under the selected library, never in the app-wide UserDefaults domain.
nonisolated struct LibraryOrderingSidecar: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var allSongs: LibraryTrackSortState?
    var allPlaylists: LibraryCollectionSortState?
    var allAlbums: LibraryCollectionSortState?
    var allArtists: LibraryCollectionSortState?
    var legacyUserDefaultsMigrationCompleted: Bool

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        allSongs: LibraryTrackSortState? = nil,
        allPlaylists: LibraryCollectionSortState? = nil,
        allAlbums: LibraryCollectionSortState? = nil,
        allArtists: LibraryCollectionSortState? = nil,
        legacyUserDefaultsMigrationCompleted: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.allSongs = allSongs
        self.allPlaylists = allPlaylists
        self.allAlbums = allAlbums
        self.allArtists = allArtists
        self.legacyUserDefaultsMigrationCompleted = legacyUserDefaultsMigrationCompleted
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case allSongs
        case allPlaylists
        case allAlbums
        case allArtists
        case legacyUserDefaultsMigrationCompleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        allSongs = try c.decodeIfPresent(LibraryTrackSortState.self, forKey: .allSongs)
        allPlaylists = try c.decodeIfPresent(LibraryCollectionSortState.self, forKey: .allPlaylists)
        allAlbums = try c.decodeIfPresent(LibraryCollectionSortState.self, forKey: .allAlbums)
        allArtists = try c.decodeIfPresent(LibraryCollectionSortState.self, forKey: .allArtists)
        legacyUserDefaultsMigrationCompleted = try c.decodeIfPresent(
            Bool.self,
            forKey: .legacyUserDefaultsMigrationCompleted
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(allSongs, forKey: .allSongs)
        try c.encodeIfPresent(allPlaylists, forKey: .allPlaylists)
        try c.encodeIfPresent(allAlbums, forKey: .allAlbums)
        try c.encodeIfPresent(allArtists, forKey: .allArtists)
        try c.encode(
            legacyUserDefaultsMigrationCompleted,
            forKey: .legacyUserDefaultsMigrationCompleted
        )
    }
}

nonisolated struct PlaylistSidecar: Codable, Sendable {
    static let currentSchemaVersion = 6

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
    let trackSortKey: String?
    let trackSortOrder: String?
    let customTrackOrder: [UUID]?

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
        case trackSortKey
        case trackSortOrder
        case customTrackOrder
        case legacyHeaderArtworkSignature = "headerArtworkSignature"
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID,
        name: String,
        description: String? = nil,
        createdAt: Date,
        items: [PlaylistItemSidecar],
        customHeaderArtworkFileName: String? = nil,
        generatedHeaderArtworkFileName: String? = nil,
        headerArtworkSource: PlaylistArtworkSource? = nil,
        generatedArtworkSignature: String? = nil,
        artworkRevision: String? = nil,
        trackSortKey: String? = nil,
        trackSortOrder: String? = nil,
        customTrackOrder: [UUID]? = nil
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
        self.trackSortKey = trackSortKey
        self.trackSortOrder = trackSortOrder
        self.customTrackOrder = customTrackOrder
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
        trackSortKey = try c.decodeIfPresent(String.self, forKey: .trackSortKey)
        trackSortOrder = try c.decodeIfPresent(String.self, forKey: .trackSortOrder)
        customTrackOrder = try c.decodeIfPresent([UUID].self, forKey: .customTrackOrder)

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
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
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
        try c.encodeIfPresent(trackSortKey, forKey: .trackSortKey)
        try c.encodeIfPresent(trackSortOrder, forKey: .trackSortOrder)
        try c.encodeIfPresent(customTrackOrder, forKey: .customTrackOrder)
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
    var trackSortKey: String?
    var trackSortOrder: String?
    var customTrackOrder: [UUID]?

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
        case trackSortKey
        case trackSortOrder
        case customTrackOrder
    }

    init(
        schemaVersion: Int = 3,
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
        updatedAt: Date,
        trackSortKey: String? = nil,
        trackSortOrder: String? = nil,
        customTrackOrder: [UUID]? = nil
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
        self.trackSortKey = trackSortKey
        self.trackSortOrder = trackSortOrder
        self.customTrackOrder = customTrackOrder
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
        trackSortKey = try c.decodeIfPresent(String.self, forKey: .trackSortKey)
        trackSortOrder = try c.decodeIfPresent(String.self, forKey: .trackSortOrder)
        customTrackOrder = try c.decodeIfPresent([UUID].self, forKey: .customTrackOrder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(3, forKey: .schemaVersion)
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
        try c.encodeIfPresent(trackSortKey, forKey: .trackSortKey)
        try c.encodeIfPresent(trackSortOrder, forKey: .trackSortOrder)
        try c.encodeIfPresent(customTrackOrder, forKey: .customTrackOrder)
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
    var trackSortKey: String?
    var trackSortOrder: String?
    var customTrackOrder: [UUID]?

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
        case trackSortKey
        case trackSortOrder
        case customTrackOrder
    }

    init(
        schemaVersion: Int = 3,
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
        updatedAt: Date,
        trackSortKey: String? = nil,
        trackSortOrder: String? = nil,
        customTrackOrder: [UUID]? = nil
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
        self.trackSortKey = trackSortKey
        self.trackSortOrder = trackSortOrder
        self.customTrackOrder = customTrackOrder
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
        trackSortKey = try c.decodeIfPresent(String.self, forKey: .trackSortKey)
        trackSortOrder = try c.decodeIfPresent(String.self, forKey: .trackSortOrder)
        customTrackOrder = try c.decodeIfPresent([UUID].self, forKey: .customTrackOrder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(3, forKey: .schemaVersion)
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
        try c.encodeIfPresent(trackSortKey, forKey: .trackSortKey)
        try c.encodeIfPresent(trackSortOrder, forKey: .trackSortOrder)
        try c.encodeIfPresent(customTrackOrder, forKey: .customTrackOrder)
    }
}
