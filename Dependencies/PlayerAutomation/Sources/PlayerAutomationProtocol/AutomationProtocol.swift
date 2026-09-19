import Foundation

public enum AutomationProtocol {
    public static let currentVersion = 1
    public static let supportedVersions = [currentVersion]
    public static let schemaVersion = 1
}

/// JSON values are kept deliberately small and Foundation-only so the wire
/// contract does not expose an App model or a third-party JSON library.
public enum AutomationJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([AutomationJSONValue])
    case object([String: AutomationJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw AutomationCodingError.nonFiniteNumber
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AutomationJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AutomationJSONValue].self) {
            self = .object(value)
        } else {
            throw AutomationCodingError.invalidJSONValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw AutomationCodingError.nonFiniteNumber
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public enum AutomationCodingError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSONValue
    case nonFiniteNumber

    public var errorDescription: String? {
        switch self {
        case .invalidJSONValue:
            return "The payload is not a supported JSON value."
        case .nonFiniteNumber:
            return "JSON numbers must be finite."
        }
    }
}

public struct AutomationClientHello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let clientIDHint: String
    public let displayName: String
    public let credential: Data?

    public init(
        clientIDHint: String,
        displayName: String,
        credential: Data? = nil,
        protocolVersion: Int = AutomationProtocol.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.clientIDHint = clientIDHint
        self.displayName = displayName
        self.credential = credential
    }
}

public struct AutomationRequestContext: Codable, Equatable, Sendable {
    public let principalSessionID: UUID?
    public let libraryID: UUID?
    public let idempotencyKey: String?
    public let deadline: Date?
    /// Identifies the control plane for audit purposes. This is metadata, not
    /// an authorization boundary; the App-owned policy remains authoritative.
    public let caller: String?

    public init(
        principalSessionID: UUID? = nil,
        libraryID: UUID? = nil,
        idempotencyKey: String? = nil,
        deadline: Date? = nil,
        caller: String? = nil
    ) {
        self.principalSessionID = principalSessionID
        self.libraryID = libraryID
        self.idempotencyKey = idempotencyKey
        self.deadline = deadline
        self.caller = caller
    }
}

/// Versioned request envelope shared by the CLI, MCP adapter and App.
/// Unknown JSON fields are intentionally ignored by Codable for forward
/// compatibility; unknown methods are rejected by the App service.
public struct AutomationRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let method: String
    public let context: AutomationRequestContext
    public let params: AutomationJSONValue?

    public init(
        method: String,
        params: AutomationJSONValue? = nil,
        context: AutomationRequestContext = AutomationRequestContext(),
        requestID: UUID = UUID(),
        protocolVersion: Int = AutomationProtocol.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.method = method
        self.context = context
        self.params = params
    }
}

public enum AutomationErrorCode: String, Codable, Equatable, Sendable {
    case unsupportedVersion
    case invalidRequest
    case methodNotFound
    case serverUnavailable
    case libraryNotActive
    case interactionRequired
    case authorizationRequired
    case permissionDenied
    case conflict
    case internalError
}

/// Coarse capability names shared by the App policy, CLI and MCP adapters.
/// These are intentionally domain-oriented rather than tool-oriented so a
/// future caller can request a useful bundle of operations without inventing
/// a second permission vocabulary.
public enum AutomationScope: String, Codable, CaseIterable, Sendable {
    case libraryRead = "library.read"
    case libraryWrite = "library.write"
    case libraryManage = "library.manage"
    case libraryDelete = "library.delete"
    case sourceRead = "source.read"
    case sourceWrite = "source.write"
    case playlistRead = "playlist.read"
    case playlistWrite = "playlist.write"
    case lyricsRead = "lyrics.read"
    case lyricsWrite = "lyrics.write"
    case metadataRead = "metadata.read"
    case metadataWrite = "metadata.write"
    case artworkRead = "artwork.read"
    case artworkWrite = "artwork.write"
    case playbackRead = "playback.read"
    case playbackControl = "playback.control"
    case queueRead = "queue.read"
    case queueWrite = "queue.write"
    case historyRead = "history.read"
    case historyWrite = "history.write"
    case settingsRead = "settings.read"
    case settingsWrite = "settings.write"
    case audioRead = "audio.read"
    case audioWrite = "audio.write"
    case diagnosticsRead = "diagnostics.read"
    case diagnosticsRepair = "diagnostics.repair"
    case filesRead = "files.read"
    case filesWrite = "files.write"
    case filesDelete = "files.delete"
    case storageRead = "storage.read"
    case storageWrite = "storage.write"
}

public enum AutomationRiskLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

public struct AutomationError: Codable, Equatable, Sendable {
    public let code: AutomationErrorCode
    public let message: String
    public let retryable: Bool
    public let details: AutomationJSONValue?

    public init(
        code: AutomationErrorCode,
        message: String,
        retryable: Bool = false,
        details: AutomationJSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

public struct AutomationResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let result: AutomationJSONValue?
    public let error: AutomationError?
    public let serverTime: Date

    public init(
        requestID: UUID,
        result: AutomationJSONValue? = nil,
        error: AutomationError? = nil,
        serverTime: Date = Date(),
        protocolVersion: Int = AutomationProtocol.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = result
        self.error = error
        self.serverTime = serverTime
    }

    public static func success(
        for request: AutomationRequest,
        result: AutomationJSONValue
    ) -> Self {
        Self(requestID: request.requestID, result: result)
    }

    public static func failure(
        for request: AutomationRequest,
        error: AutomationError
    ) -> Self {
        Self(requestID: request.requestID, error: error)
    }
}

public enum AutomationMethod {
    public static let systemPing = "system.ping"
    public static let systemInfo = "system.info"
    public static let libraryList = "library.list"
    public static let libraryCreate = "library.create"
    public static let libraryOpen = "library.open"
    public static let librarySwitch = "library.switch"
    public static let libraryRename = "library.rename"
    public static let libraryRelocate = "library.relocate"
    public static let libraryRemove = "library.remove"
    public static let libraryTracks = "library.tracks"
    public static let playlistList = "playlist.list"
    public static let playlistCreate = "playlist.create"
    public static let playlistAddTracks = "playlist.addTracks"
    public static let playlistRemoveTracks = "playlist.removeTracks"
    public static let sourceList = "source.list"
    public static let sourceRefresh = "source.refresh"
    public static let sourceCreate = "source.create"
    public static let sourceBindPlaylist = "source.bindPlaylist"
    public static let sourceSetExcludedPath = "source.setExcludedPath"
    public static let sourceSetMonitorPolicy = "source.setMonitorPolicy"
    public static let sourceRemove = "source.remove"
    public static let filesInspect = "files.inspect"
    public static let filesRename = "files.rename"
    public static let filesMove = "files.move"
    public static let filesDelete = "files.delete"
    public static let playlistGet = "playlist.get"
    public static let playlistRename = "playlist.rename"
    public static let playlistDelete = "playlist.delete"
    public static let playlistReplaceTracks = "playlist.replaceTracks"
    public static let playlistReorder = "playlist.reorder"
    public static let playbackState = "playback.state"
    public static let playbackPlay = "playback.play"
    public static let playbackPause = "playback.pause"
    public static let playbackNext = "playback.next"
    public static let playbackPrevious = "playback.previous"
    public static let playbackSeek = "playback.seek"
    public static let playbackSetVolume = "playback.setVolume"
    public static let playbackSetMode = "playback.setMode"
    public static let queueGet = "queue.get"
    public static let queueReplace = "queue.replace"
    public static let queueEnqueue = "queue.enqueue"
    public static let queueEnqueueNext = "queue.enqueueNext"
    public static let queueClear = "queue.clear"
    public static let historyList = "history.list"
    public static let historyClear = "history.clear"
    public static let metadataGet = "metadata.get"
    public static let metadataPatch = "metadata.patch"
    public static let artworkGet = "artwork.get"
    public static let artworkApply = "artwork.apply"
    public static let lyricsGet = "lyrics.get"
    public static let lyricsSearch = "lyrics.search"
    public static let lyricsCandidates = "lyrics.candidates"
    public static let lyricsCompare = "lyrics.compare"
    public static let lyricsApply = "lyrics.apply"
    public static let lyricsRefresh = "lyrics.refresh"
    public static let jobsList = "jobs.list"
    public static let jobsGet = "jobs.get"
    public static let jobsCancel = "jobs.cancel"
    public static let jobsRetry = "jobs.retry"
    public static let diagnosticsHealth = "diagnostics.health"
    public static let settingsGet = "settings.get"
    public static let settingsPatch = "settings.patch"
    public static let storageInspect = "storage.inspect"
    public static let storageValidate = "storage.validate"
    public static let storageRepair = "storage.repair"
    public static let storageOrphans = "storage.orphans"
    public static let storageBackup = "storage.backup"
    public static let storageDiff = "storage.diff"
    public static let storageReload = "storage.reload"
    public static let automationCapabilities = "automation.capabilities"
    public static let automationScopes = "automation.scopes"
    public static let automationGrantScope = "automation.grantScope"
    public static let automationRevokeScope = "automation.revokeScope"
}

public struct AutomationPingResult: Codable, Equatable, Sendable {
    public let serverTime: Date
    public let protocolVersion: Int

    public init(
        serverTime: Date = Date(),
        protocolVersion: Int = AutomationProtocol.currentVersion
    ) {
        self.serverTime = serverTime
        self.protocolVersion = protocolVersion
    }
}

public struct AutomationSystemInfo: Codable, Equatable, Sendable {
    public let appName: String
    public let appVersion: String
    public let protocolVersion: Int
    public let capabilities: [String]
    public let isReady: Bool
    public let activeLibraryID: UUID?

    public init(
        appName: String,
        appVersion: String,
        protocolVersion: Int = AutomationProtocol.currentVersion,
        capabilities: [String],
        isReady: Bool,
        activeLibraryID: UUID?
    ) {
        self.appName = appName
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities.sorted()
        self.isReady = isReady
        self.activeLibraryID = activeLibraryID
    }
}

public enum AutomationLibraryMode: String, Codable, Equatable, Sendable {
    case managed
    case referenced
}

public struct AutomationLibrarySummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let mode: AutomationLibraryMode
    public let isActive: Bool

    public init(id: UUID, displayName: String, mode: AutomationLibraryMode, isActive: Bool) {
        self.id = id
        self.displayName = displayName
        self.mode = mode
        self.isActive = isActive
    }
}

public struct AutomationLibraryListResult: Codable, Equatable, Sendable {
    public let libraries: [AutomationLibrarySummary]
    public let activeLibraryID: UUID?

    public init(libraries: [AutomationLibrarySummary], activeLibraryID: UUID?) {
        self.libraries = libraries.sorted { lhs, rhs in
            switch lhs.displayName.localizedStandardCompare(rhs.displayName) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        self.activeLibraryID = activeLibraryID
    }
}

public struct AutomationLibraryLifecycleResult: Codable, Equatable, Sendable {
    public let operation: String
    public let applied: Bool
    public let dryRun: Bool
    public let confirmed: Bool
    public let libraryID: UUID?
    public let library: AutomationLibrarySummary?
    public let activeLibraryID: UUID?
    public let path: String?
    public let unavailableSourceIDs: [UUID]
    public let message: String

    public init(
        operation: String,
        applied: Bool,
        dryRun: Bool,
        confirmed: Bool = false,
        libraryID: UUID? = nil,
        library: AutomationLibrarySummary? = nil,
        activeLibraryID: UUID? = nil,
        path: String? = nil,
        unavailableSourceIDs: [UUID] = [],
        message: String
    ) {
        self.operation = operation
        self.applied = applied
        self.dryRun = dryRun
        self.confirmed = confirmed
        self.libraryID = libraryID
        self.library = library
        self.activeLibraryID = activeLibraryID
        self.path = path
        self.unavailableSourceIDs = unavailableSourceIDs.sorted { $0.uuidString < $1.uuidString }
        self.message = message
    }
}

public struct AutomationTrackSourceMembership: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let relativePath: String

    public init(sourceID: UUID, relativePath: String) {
        self.sourceID = sourceID
        self.relativePath = relativePath
    }
}

public struct AutomationTrackCredit: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let canonicalName: String?
    public let role: String

    public init(
        id: UUID,
        displayName: String,
        canonicalName: String? = nil,
        role: String = "primary"
    ) {
        self.id = id
        self.displayName = displayName
        self.canonicalName = canonicalName
        self.role = role
    }
}

public struct AutomationTrackSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Double
    public let availability: String
    public let addedAt: Date
    public let importedAt: Date?
    public let sourceMemberships: [AutomationTrackSourceMembership]
    public let artistCredits: [AutomationTrackCredit]
    public let albumArtist: String?
    public let userDescription: String
    public let genreTags: [String]
    public let language: String
    public let labelOrCompany: String
    public let releaseDate: Date?
    public let qqMusicSongMid: String?
    public let metadataSource: String?
    public let metadataFetchedAt: Date?
    public let metadataConfidence: Double?
    public let musicBrainzReleaseID: String?
    public let lyricsTimeOffsetMs: Double
    public let lyricsStatus: String
    public let artworkAvailable: Bool
    public let artworkFileName: String?
    public let format: String?
    public let codec: String?
    public let sampleRateHz: Int?
    public let bitDepth: Int?
    public let channelCount: Int?
    public let filePath: String?
    public let playlistIDs: [UUID]

    public init(
        id: UUID,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        availability: String,
        addedAt: Date,
        importedAt: Date?,
        sourceMemberships: [AutomationTrackSourceMembership] = [],
        artistCredits: [AutomationTrackCredit] = [],
        albumArtist: String? = nil,
        userDescription: String = "",
        genreTags: [String] = [],
        language: String = "",
        labelOrCompany: String = "",
        releaseDate: Date? = nil,
        qqMusicSongMid: String? = nil,
        metadataSource: String? = nil,
        metadataFetchedAt: Date? = nil,
        metadataConfidence: Double? = nil,
        musicBrainzReleaseID: String? = nil,
        lyricsTimeOffsetMs: Double = 0,
        lyricsStatus: String = "none",
        artworkAvailable: Bool = false,
        artworkFileName: String? = nil,
        format: String? = nil,
        codec: String? = nil,
        sampleRateHz: Int? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil,
        filePath: String? = nil,
        playlistIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.availability = availability
        self.addedAt = addedAt
        self.importedAt = importedAt
        self.sourceMemberships = sourceMemberships
        self.artistCredits = artistCredits
        self.albumArtist = albumArtist
        self.userDescription = userDescription
        self.genreTags = genreTags
        self.language = language
        self.labelOrCompany = labelOrCompany
        self.releaseDate = releaseDate
        self.qqMusicSongMid = qqMusicSongMid
        self.metadataSource = metadataSource
        self.metadataFetchedAt = metadataFetchedAt
        self.metadataConfidence = metadataConfidence
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.lyricsTimeOffsetMs = lyricsTimeOffsetMs
        self.lyricsStatus = lyricsStatus
        self.artworkAvailable = artworkAvailable
        self.artworkFileName = artworkFileName
        self.format = format
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.filePath = filePath
        self.playlistIDs = playlistIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, availability, addedAt, importedAt
        case sourceMemberships, artistCredits, albumArtist, userDescription
        case genreTags, language, labelOrCompany, releaseDate, qqMusicSongMid
        case metadataSource, metadataFetchedAt, metadataConfidence, musicBrainzReleaseID
        case lyricsTimeOffsetMs, lyricsStatus, artworkAvailable, artworkFileName
        case format, codec
        case sampleRateHz, bitDepth, channelCount, filePath, playlistIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decode(String.self, forKey: .album)
        duration = try container.decode(Double.self, forKey: .duration)
        availability = try container.decode(String.self, forKey: .availability)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        sourceMemberships = try container.decodeIfPresent(
            [AutomationTrackSourceMembership].self,
            forKey: .sourceMemberships
        ) ?? []
        artistCredits = try container.decodeIfPresent(
            [AutomationTrackCredit].self,
            forKey: .artistCredits
        ) ?? []
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        userDescription = try container.decodeIfPresent(String.self, forKey: .userDescription) ?? ""
        genreTags = try container.decodeIfPresent([String].self, forKey: .genreTags) ?? []
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? ""
        labelOrCompany = try container.decodeIfPresent(String.self, forKey: .labelOrCompany) ?? ""
        releaseDate = try container.decodeIfPresent(Date.self, forKey: .releaseDate)
        qqMusicSongMid = try container.decodeIfPresent(String.self, forKey: .qqMusicSongMid)
        metadataSource = try container.decodeIfPresent(String.self, forKey: .metadataSource)
        metadataFetchedAt = try container.decodeIfPresent(Date.self, forKey: .metadataFetchedAt)
        metadataConfidence = try container.decodeIfPresent(Double.self, forKey: .metadataConfidence)
        musicBrainzReleaseID = try container.decodeIfPresent(String.self, forKey: .musicBrainzReleaseID)
        lyricsTimeOffsetMs = try container.decodeIfPresent(Double.self, forKey: .lyricsTimeOffsetMs) ?? 0
        lyricsStatus = try container.decodeIfPresent(String.self, forKey: .lyricsStatus) ?? "none"
        artworkAvailable = try container.decodeIfPresent(Bool.self, forKey: .artworkAvailable) ?? false
        artworkFileName = try container.decodeIfPresent(String.self, forKey: .artworkFileName)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        sampleRateHz = try container.decodeIfPresent(Int.self, forKey: .sampleRateHz)
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        playlistIDs = try container.decodeIfPresent([UUID].self, forKey: .playlistIDs) ?? []
    }
}

public struct AutomationLibraryTracksResult: Codable, Equatable, Sendable {
    public let tracks: [AutomationTrackSummary]
    public let total: Int
    public let offset: Int
    public let limit: Int
    public let nextOffset: Int?
    /// Opaque snapshot token for safe pagination. A later page may send this
    /// value as `expectedRevision` and receive a conflict if the library
    /// changed in between requests.
    public let revision: String

    public init(
        tracks: [AutomationTrackSummary],
        total: Int,
        offset: Int,
        limit: Int,
        nextOffset: Int? = nil,
        revision: String = "v1-unknown"
    ) {
        self.tracks = tracks
        self.total = total
        self.offset = offset
        self.limit = limit
        self.nextOffset = nextOffset
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case tracks
        case total
        case offset
        case limit
        case nextOffset
        case revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try container.decode([AutomationTrackSummary].self, forKey: .tracks)
        total = try container.decode(Int.self, forKey: .total)
        offset = try container.decode(Int.self, forKey: .offset)
        limit = try container.decode(Int.self, forKey: .limit)
        nextOffset = try container.decodeIfPresent(Int.self, forKey: .nextOffset)
        revision = try container.decodeIfPresent(String.self, forKey: .revision) ?? "v1-unknown"
    }
}

public struct AutomationFileSummary: Codable, Equatable, Sendable, Identifiable {
    public let trackID: UUID
    public let path: String
    public let exists: Bool
    public let availability: String
    public let sourceIDs: [UUID]
    public let relativePaths: [String]

    public var id: UUID { trackID }

    public init(
        trackID: UUID,
        path: String,
        exists: Bool,
        availability: String,
        sourceIDs: [UUID],
        relativePaths: [String]
    ) {
        self.trackID = trackID
        self.path = path
        self.exists = exists
        self.availability = availability
        self.sourceIDs = sourceIDs.sorted { $0.uuidString < $1.uuidString }
        self.relativePaths = relativePaths.sorted()
    }
}

public struct AutomationFileOperationResult: Codable, Equatable, Sendable {
    public let operation: String
    public let applied: Bool
    public let dryRun: Bool
    public let confirmed: Bool
    public let affectedTrackIDs: [UUID]
    public let files: [AutomationFileSummary]
    public let jobs: [AutomationJobSummary]
    public let failures: [String]
    public let message: String

    public init(
        operation: String,
        applied: Bool,
        dryRun: Bool,
        confirmed: Bool = false,
        affectedTrackIDs: [UUID] = [],
        files: [AutomationFileSummary] = [],
        jobs: [AutomationJobSummary] = [],
        failures: [String] = [],
        message: String
    ) {
        self.operation = operation
        self.applied = applied
        self.dryRun = dryRun
        self.confirmed = confirmed
        self.affectedTrackIDs = affectedTrackIDs
        self.files = files
        self.jobs = jobs
        self.failures = failures
        self.message = message
    }
}

public struct AutomationPlaylistSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let description: String
    public let createdAt: Date
    public let trackCount: Int
    public let totalDuration: Double
    /// Opaque, stable-for-the-current-library revision used for optimistic
    /// concurrency checks. Callers must treat it as an opaque token.
    public let revision: String

    public init(
        id: UUID,
        name: String,
        description: String,
        createdAt: Date,
        trackCount: Int,
        totalDuration: Double,
        revision: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.trackCount = trackCount
        self.totalDuration = totalDuration
        self.revision = revision
    }
}

public struct AutomationPlaylistListResult: Codable, Equatable, Sendable {
    public let playlists: [AutomationPlaylistSummary]

    public init(playlists: [AutomationPlaylistSummary]) {
        self.playlists = playlists.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}

public struct AutomationPlaylistMutationResult: Codable, Equatable, Sendable {
    public let operation: String
    public let applied: Bool
    public let dryRun: Bool
    public let playlist: AutomationPlaylistSummary?
    public let requestedTrackIDs: [UUID]
    public let changedTrackIDs: [UUID]
    public let skippedTrackIDs: [UUID]
    public let message: String?

    public init(
        operation: String,
        applied: Bool,
        dryRun: Bool,
        playlist: AutomationPlaylistSummary?,
        requestedTrackIDs: [UUID] = [],
        changedTrackIDs: [UUID] = [],
        skippedTrackIDs: [UUID] = [],
        message: String? = nil
    ) {
        self.operation = operation
        self.applied = applied
        self.dryRun = dryRun
        self.playlist = playlist
        self.requestedTrackIDs = requestedTrackIDs
        self.changedTrackIDs = changedTrackIDs
        self.skippedTrackIDs = skippedTrackIDs
        self.message = message
    }
}

public struct AutomationSourceSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let mode: String
    public let displayName: String
    public let path: String
    public let status: String
    public let lastScan: Date?
    public let playlistIDs: [UUID]
    public let excludedRelativePaths: [String]
    public let monitorPolicy: String

    public init(
        id: UUID,
        mode: String,
        displayName: String,
        path: String,
        status: String,
        lastScan: Date?,
        playlistIDs: [UUID],
        excludedRelativePaths: [String] = [],
        monitorPolicy: String = "on"
    ) {
        self.id = id
        self.mode = mode
        self.displayName = displayName
        self.path = path
        self.status = status
        self.lastScan = lastScan
        self.playlistIDs = playlistIDs
        self.excludedRelativePaths = excludedRelativePaths.sorted()
        self.monitorPolicy = monitorPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case id, mode, displayName, path, status, lastScan, playlistIDs
        case excludedRelativePaths, monitorPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            mode: try container.decode(String.self, forKey: .mode),
            displayName: try container.decode(String.self, forKey: .displayName),
            path: try container.decode(String.self, forKey: .path),
            status: try container.decode(String.self, forKey: .status),
            lastScan: try container.decodeIfPresent(Date.self, forKey: .lastScan),
            playlistIDs: try container.decodeIfPresent([UUID].self, forKey: .playlistIDs) ?? [],
            excludedRelativePaths: try container.decodeIfPresent(
                [String].self,
                forKey: .excludedRelativePaths
            ) ?? [],
            monitorPolicy: try container.decodeIfPresent(
                String.self,
                forKey: .monitorPolicy
            ) ?? "on"
        )
    }
}

public struct AutomationSourceListResult: Codable, Equatable, Sendable {
    public let sources: [AutomationSourceSummary]

    public init(sources: [AutomationSourceSummary]) {
        self.sources = sources.sorted { lhs, rhs in
            switch lhs.displayName.localizedStandardCompare(rhs.displayName) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}

public struct AutomationSourceRefreshResult: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let applied: Bool
    public let dryRun: Bool
    public let completed: Bool
    public let source: AutomationSourceSummary?
    public let libraryTrackCount: Int
    public let issues: [String]
    public let job: AutomationJobSummary?
    public let message: String?

    public init(
        sourceID: UUID,
        applied: Bool,
        dryRun: Bool,
        source: AutomationSourceSummary?,
        libraryTrackCount: Int,
        issues: [String] = [],
        completed: Bool = true,
        job: AutomationJobSummary? = nil,
        message: String? = nil
    ) {
        self.sourceID = sourceID
        self.applied = applied
        self.dryRun = dryRun
        self.completed = completed
        self.source = source
        self.libraryTrackCount = libraryTrackCount
        self.issues = issues
        self.job = job
        self.message = message
    }
}

public struct AutomationSourceCreateResult: Codable, Equatable, Sendable {
    public let applied: Bool
    /// True only when this request also bound an already-existing Source to
    /// the requested Playlist. A newly queued import reports false because
    /// binding completes with the Job.
    public let playlistBindingApplied: Bool
    public let completed: Bool
    public let source: AutomationSourceSummary?
    public let selectedPath: String?
    public let importedTrackCount: Int
    public let failures: [String]
    public let job: AutomationJobSummary?
    public let message: String?

    public init(
        applied: Bool,
        playlistBindingApplied: Bool = false,
        completed: Bool = true,
        source: AutomationSourceSummary? = nil,
        selectedPath: String? = nil,
        importedTrackCount: Int = 0,
        failures: [String] = [],
        job: AutomationJobSummary? = nil,
        message: String? = nil
    ) {
        self.applied = applied
        self.playlistBindingApplied = playlistBindingApplied
        self.completed = completed
        self.source = source
        self.selectedPath = selectedPath
        self.importedTrackCount = importedTrackCount
        self.failures = failures
        self.job = job
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case applied
        case playlistBindingApplied
        case completed
        case source
        case selectedPath
        case importedTrackCount
        case failures
        case job
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applied = try container.decode(Bool.self, forKey: .applied)
        playlistBindingApplied = try container.decodeIfPresent(
            Bool.self,
            forKey: .playlistBindingApplied
        ) ?? false
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? true
        source = try container.decodeIfPresent(AutomationSourceSummary.self, forKey: .source)
        selectedPath = try container.decodeIfPresent(String.self, forKey: .selectedPath)
        importedTrackCount = try container.decodeIfPresent(Int.self, forKey: .importedTrackCount) ?? 0
        failures = try container.decodeIfPresent([String].self, forKey: .failures) ?? []
        job = try container.decodeIfPresent(AutomationJobSummary.self, forKey: .job)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

public struct AutomationPlaylistDetailResult: Codable, Equatable, Sendable {
    public let playlist: AutomationPlaylistSummary
    public let trackIDs: [UUID]

    public init(playlist: AutomationPlaylistSummary, trackIDs: [UUID]) {
        self.playlist = playlist
        self.trackIDs = trackIDs
    }
}

public struct AutomationPlaybackState: Codable, Equatable, Sendable {
    public let source: String
    public let isPlaying: Bool
    public let currentTrackID: UUID?
    public let currentTitle: String?
    public let currentArtist: String?
    public let position: Double
    public let duration: Double
    public let volume: Double
    public let playbackMode: String

    public init(
        source: String,
        isPlaying: Bool,
        currentTrackID: UUID?,
        currentTitle: String?,
        currentArtist: String?,
        position: Double,
        duration: Double,
        volume: Double,
        playbackMode: String
    ) {
        self.source = source
        self.isPlaying = isPlaying
        self.currentTrackID = currentTrackID
        self.currentTitle = currentTitle
        self.currentArtist = currentArtist
        self.position = position
        self.duration = duration
        self.volume = volume
        self.playbackMode = playbackMode
    }
}

public struct AutomationQueueResult: Codable, Equatable, Sendable {
    public let trackIDs: [UUID]
    public let currentTrackID: UUID?
    public let revision: String

    public init(trackIDs: [UUID], currentTrackID: UUID?, revision: String) {
        self.trackIDs = trackIDs
        self.currentTrackID = currentTrackID
        self.revision = revision
    }
}

public struct AutomationHistoryItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let trackID: UUID
    public let playedAt: Date
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Double
    public let playedSeconds: Double

    public init(
        id: UUID,
        trackID: UUID,
        playedAt: Date,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        playedSeconds: Double
    ) {
        self.id = id
        self.trackID = trackID
        self.playedAt = playedAt
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.playedSeconds = playedSeconds
    }
}

public struct AutomationHistoryListResult: Codable, Equatable, Sendable {
    public let items: [AutomationHistoryItem]
    public let revision: String

    public init(items: [AutomationHistoryItem], revision: String) {
        self.items = items
        self.revision = revision
    }
}

public struct AutomationMetadataMutationResult: Codable, Equatable, Sendable {
    public let applied: Bool
    public let dryRun: Bool
    public let updatedTrackIDs: [UUID]
    public let skippedTrackIDs: [UUID]
    public let conflictedTrackIDs: [UUID]
    public let message: String

    public init(
        applied: Bool,
        dryRun: Bool,
        updatedTrackIDs: [UUID] = [],
        skippedTrackIDs: [UUID] = [],
        conflictedTrackIDs: [UUID] = [],
        message: String
    ) {
        self.applied = applied
        self.dryRun = dryRun
        self.updatedTrackIDs = updatedTrackIDs
        self.skippedTrackIDs = skippedTrackIDs
        self.conflictedTrackIDs = conflictedTrackIDs
        self.message = message
    }
}

public struct AutomationArtworkInfo: Codable, Equatable, Sendable, Identifiable {
    public let trackID: UUID
    public let available: Bool
    public let fileName: String?
    public let byteCount: Int?
    public let sha256: String?
    public let revision: String?

    public var id: UUID { trackID }

    public init(
        trackID: UUID,
        available: Bool,
        fileName: String? = nil,
        byteCount: Int? = nil,
        sha256: String? = nil,
        revision: String? = nil
    ) {
        self.trackID = trackID
        self.available = available
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.revision = revision
    }
}

public struct AutomationArtworkGetResult: Codable, Equatable, Sendable {
    public let artworks: [AutomationArtworkInfo]
    public let revision: String

    public init(artworks: [AutomationArtworkInfo], revision: String) {
        self.artworks = artworks.sorted { $0.trackID.uuidString < $1.trackID.uuidString }
        self.revision = revision
    }
}

public struct AutomationArtworkMutationResult: Codable, Equatable, Sendable {
    public let applied: Bool
    public let dryRun: Bool
    public let confirmed: Bool
    public let input: String
    public let updatedTrackIDs: [UUID]
    public let skippedTrackIDs: [UUID]
    public let conflictedTrackIDs: [UUID]
    public let message: String

    public init(
        applied: Bool,
        dryRun: Bool,
        confirmed: Bool = false,
        input: String,
        updatedTrackIDs: [UUID] = [],
        skippedTrackIDs: [UUID] = [],
        conflictedTrackIDs: [UUID] = [],
        message: String
    ) {
        self.applied = applied
        self.dryRun = dryRun
        self.confirmed = confirmed
        self.input = input
        self.updatedTrackIDs = updatedTrackIDs
        self.skippedTrackIDs = skippedTrackIDs
        self.conflictedTrackIDs = conflictedTrackIDs
        self.message = message
    }
}

public struct AutomationLyricsCandidate: Codable, Equatable, Sendable, Identifiable {
    public let source: String
    public let songID: String
    public let score: Double
    public let normalizedScore: Double
    public let title: String
    public let artist: String?
    public let album: String?
    public let durationMs: Int?
    public let mode: String
    public let extra: [String: String]?

    public var id: String { "\(source)-\(songID)" }

    public init(
        source: String,
        songID: String,
        score: Double,
        normalizedScore: Double,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        durationMs: Int? = nil,
        mode: String,
        extra: [String: String]? = nil
    ) {
        self.source = source
        self.songID = songID
        self.score = score
        self.normalizedScore = normalizedScore
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.mode = mode
        self.extra = extra
    }
}

public struct AutomationLyricsSearchResult: Codable, Equatable, Sendable {
    public let trackID: UUID
    public let queryTitle: String
    public let queryArtist: String?
    public let queryAlbum: String?
    public let mode: String
    public let candidates: [AutomationLyricsCandidate]
    public let amlldbCount: Int
    public let lddcCount: Int
    public let message: String

    public init(
        trackID: UUID,
        queryTitle: String,
        queryArtist: String? = nil,
        queryAlbum: String? = nil,
        mode: String,
        candidates: [AutomationLyricsCandidate],
        amlldbCount: Int,
        lddcCount: Int,
        message: String
    ) {
        self.trackID = trackID
        self.queryTitle = queryTitle
        self.queryArtist = queryArtist
        self.queryAlbum = queryAlbum
        self.mode = mode
        self.candidates = candidates
        self.amlldbCount = amlldbCount
        self.lddcCount = lddcCount
        self.message = message
    }
}

public struct AutomationLyricsComparisonResult: Codable, Equatable, Sendable {
    public let trackID: UUID
    public let currentStatus: String
    public let currentQuality: Int
    public let candidate: AutomationLyricsCandidate
    public let candidateQuality: Int
    public let shouldReplace: Bool
    public let message: String

    public init(
        trackID: UUID,
        currentStatus: String,
        currentQuality: Int,
        candidate: AutomationLyricsCandidate,
        candidateQuality: Int,
        shouldReplace: Bool,
        message: String
    ) {
        self.trackID = trackID
        self.currentStatus = currentStatus
        self.currentQuality = currentQuality
        self.candidate = candidate
        self.candidateQuality = candidateQuality
        self.shouldReplace = shouldReplace
        self.message = message
    }
}

public struct AutomationLyricsApplyResult: Codable, Equatable, Sendable {
    public let trackID: UUID
    public let applied: Bool
    public let dryRun: Bool
    public let force: Bool
    public let candidate: AutomationLyricsCandidate
    public let currentQuality: Int
    public let candidateQuality: Int
    public let message: String

    public init(
        trackID: UUID,
        applied: Bool,
        dryRun: Bool,
        force: Bool,
        candidate: AutomationLyricsCandidate,
        currentQuality: Int,
        candidateQuality: Int,
        message: String
    ) {
        self.trackID = trackID
        self.applied = applied
        self.dryRun = dryRun
        self.force = force
        self.candidate = candidate
        self.currentQuality = currentQuality
        self.candidateQuality = candidateQuality
        self.message = message
    }
}

public struct AutomationLyricsDetail: Codable, Equatable, Sendable {
    public let trackID: UUID
    public let status: String
    public let ttml: String?
    public let plainText: String?

    public init(
        trackID: UUID,
        status: String,
        ttml: String? = nil,
        plainText: String? = nil
    ) {
        self.trackID = trackID
        self.status = status
        self.ttml = ttml
        self.plainText = plainText
    }
}

public struct AutomationLyricsRefreshResult: Codable, Equatable, Sendable {
    public let applied: Bool
    public let dryRun: Bool
    public let selectedTrackIDs: [UUID]
    public let job: AutomationJobSummary?
    public let message: String

    public init(
        applied: Bool,
        dryRun: Bool,
        selectedTrackIDs: [UUID],
        job: AutomationJobSummary? = nil,
        message: String
    ) {
        self.applied = applied
        self.dryRun = dryRun
        self.selectedTrackIDs = selectedTrackIDs
        self.job = job
        self.message = message
    }
}

public enum AutomationJobState: String, Codable, Sendable {
    case queued
    case running
    case checkpointed
    case completed
    case partialFailure
    case failed
    case cancelled
}

public struct AutomationJobSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: String
    public let libraryID: UUID?
    public let state: AutomationJobState
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let checkpoint: String?
    public let completedCount: Int
    public let totalCount: Int?
    public let currentPhase: String?
    public let failures: [String]
    public let failedItemIDs: [UUID]
    public let retryable: Bool

    public init(
        id: UUID,
        kind: String,
        libraryID: UUID?,
        state: AutomationJobState,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        checkpoint: String? = nil,
        completedCount: Int = 0,
        totalCount: Int? = nil,
        currentPhase: String? = nil,
        failures: [String] = [],
        failedItemIDs: [UUID] = [],
        retryable: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.libraryID = libraryID
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.checkpoint = checkpoint
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.currentPhase = currentPhase
        self.failures = failures
        self.failedItemIDs = failedItemIDs
        self.retryable = retryable
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, libraryID, state, createdAt, startedAt, finishedAt, checkpoint
        case completedCount, totalCount, currentPhase, failures, failedItemIDs, retryable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        libraryID = try container.decodeIfPresent(UUID.self, forKey: .libraryID)
        state = try container.decode(AutomationJobState.self, forKey: .state)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        checkpoint = try container.decodeIfPresent(String.self, forKey: .checkpoint)
        completedCount = try container.decodeIfPresent(Int.self, forKey: .completedCount) ?? 0
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount)
        currentPhase = try container.decodeIfPresent(String.self, forKey: .currentPhase)
        failures = try container.decodeIfPresent([String].self, forKey: .failures) ?? []
        failedItemIDs = try container.decodeIfPresent([UUID].self, forKey: .failedItemIDs) ?? []
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
    }
}

public struct AutomationJobRetryResult: Codable, Equatable, Sendable {
    public let originalJobID: UUID
    public let accepted: Bool
    public let job: AutomationJobSummary?
    public let message: String

    public init(
        originalJobID: UUID,
        accepted: Bool,
        job: AutomationJobSummary? = nil,
        message: String
    ) {
        self.originalJobID = originalJobID
        self.accepted = accepted
        self.job = job
        self.message = message
    }
}

public struct AutomationJobListResult: Codable, Equatable, Sendable {
    public let jobs: [AutomationJobSummary]

    public init(jobs: [AutomationJobSummary]) {
        self.jobs = jobs.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

public struct AutomationDiagnosticsResult: Codable, Equatable, Sendable {
    public let healthy: Bool
    public let libraryID: UUID?
    public let trackCount: Int
    public let playlistCount: Int
    public let missingTrackCount: Int
    public let unavailableTrackCount: Int
    public let sourceCount: Int
    public let sourceIssues: [String]
    public let runningJobCount: Int
    public let checks: [String: String]
    public let failedJobCount: Int
    public let failedJobSummaries: [String]
    public let playlistReferenceIssues: [AutomationPlaylistReferenceIssue]
    public let storageValidation: String
    public let storageValidationMessage: String?

    public init(
        healthy: Bool,
        libraryID: UUID?,
        trackCount: Int,
        playlistCount: Int,
        missingTrackCount: Int,
        unavailableTrackCount: Int,
        sourceCount: Int,
        sourceIssues: [String] = [],
        runningJobCount: Int = 0,
        checks: [String: String] = [:],
        failedJobCount: Int = 0,
        failedJobSummaries: [String] = [],
        playlistReferenceIssues: [AutomationPlaylistReferenceIssue] = [],
        storageValidation: String = "notRun",
        storageValidationMessage: String? = nil
    ) {
        self.healthy = healthy
        self.libraryID = libraryID
        self.trackCount = trackCount
        self.playlistCount = playlistCount
        self.missingTrackCount = missingTrackCount
        self.unavailableTrackCount = unavailableTrackCount
        self.sourceCount = sourceCount
        self.sourceIssues = sourceIssues.sorted()
        self.runningJobCount = runningJobCount
        self.checks = checks
        self.failedJobCount = failedJobCount
        self.failedJobSummaries = failedJobSummaries
        self.playlistReferenceIssues = playlistReferenceIssues
        self.storageValidation = storageValidation
        self.storageValidationMessage = storageValidationMessage
    }

    private enum CodingKeys: String, CodingKey {
        case healthy, libraryID, trackCount, playlistCount, missingTrackCount
        case unavailableTrackCount, sourceCount, sourceIssues, runningJobCount, checks
        case failedJobCount, failedJobSummaries, playlistReferenceIssues
        case storageValidation, storageValidationMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        healthy = try container.decode(Bool.self, forKey: .healthy)
        libraryID = try container.decodeIfPresent(UUID.self, forKey: .libraryID)
        trackCount = try container.decode(Int.self, forKey: .trackCount)
        playlistCount = try container.decode(Int.self, forKey: .playlistCount)
        missingTrackCount = try container.decode(Int.self, forKey: .missingTrackCount)
        unavailableTrackCount = try container.decode(Int.self, forKey: .unavailableTrackCount)
        sourceCount = try container.decode(Int.self, forKey: .sourceCount)
        sourceIssues = try container.decodeIfPresent([String].self, forKey: .sourceIssues) ?? []
        runningJobCount = try container.decodeIfPresent(Int.self, forKey: .runningJobCount) ?? 0
        checks = try container.decodeIfPresent([String: String].self, forKey: .checks) ?? [:]
        failedJobCount = try container.decodeIfPresent(Int.self, forKey: .failedJobCount) ?? 0
        failedJobSummaries = try container.decodeIfPresent([String].self, forKey: .failedJobSummaries) ?? []
        playlistReferenceIssues = try container.decodeIfPresent(
            [AutomationPlaylistReferenceIssue].self,
            forKey: .playlistReferenceIssues
        ) ?? []
        storageValidation = try container.decodeIfPresent(String.self, forKey: .storageValidation) ?? "notRun"
        storageValidationMessage = try container.decodeIfPresent(String.self, forKey: .storageValidationMessage)
    }
}

public struct AutomationPlaylistReferenceIssue: Codable, Equatable, Sendable, Identifiable {
    public let playlistID: UUID
    public let playlistName: String
    public let missingTrackIDs: [UUID]

    public var id: UUID { playlistID }

    public init(playlistID: UUID, playlistName: String, missingTrackIDs: [UUID]) {
        self.playlistID = playlistID
        self.playlistName = playlistName
        self.missingTrackIDs = missingTrackIDs.sorted { $0.uuidString < $1.uuidString }
    }
}

public struct AutomationSettingsResult: Codable, Equatable, Sendable {
    public let libraryID: UUID?
    public let values: [String: AutomationJSONValue]
    public let revision: String
    public let applied: Bool
    public let dryRun: Bool
    public let message: String

    public init(
        libraryID: UUID?,
        values: [String: AutomationJSONValue],
        revision: String,
        applied: Bool = false,
        dryRun: Bool = false,
        message: String
    ) {
        self.libraryID = libraryID
        self.values = values
        self.revision = revision
        self.applied = applied
        self.dryRun = dryRun
        self.message = message
    }
}

public struct AutomationStorageResult: Codable, Equatable, Sendable {
    public let libraryID: UUID?
    public let mode: String?
    public let rootPath: String?
    public let schemaVersion: Int?
    public let manifestPresent: Bool
    public let missingRequiredDirectories: [String]
    public let validation: String
    public let validationMessage: String?
    public let message: String

    public init(
        libraryID: UUID?,
        mode: String?,
        rootPath: String?,
        schemaVersion: Int?,
        manifestPresent: Bool,
        missingRequiredDirectories: [String] = [],
        validation: String,
        validationMessage: String? = nil,
        message: String
    ) {
        self.libraryID = libraryID
        self.mode = mode
        self.rootPath = rootPath
        self.schemaVersion = schemaVersion
        self.manifestPresent = manifestPresent
        self.missingRequiredDirectories = missingRequiredDirectories.sorted()
        self.validation = validation
        self.validationMessage = validationMessage
        self.message = message
    }
}

public struct AutomationStorageOrphansResult: Codable, Equatable, Sendable {
    public let libraryID: UUID?
    public let playlistReferenceIssues: [AutomationPlaylistReferenceIssue]
    public let orphanReferenceCount: Int
    public let message: String

    public init(
        libraryID: UUID?,
        playlistReferenceIssues: [AutomationPlaylistReferenceIssue],
        message: String
    ) {
        self.libraryID = libraryID
        self.playlistReferenceIssues = playlistReferenceIssues
        self.orphanReferenceCount = playlistReferenceIssues.reduce(0) {
            $0 + $1.missingTrackIDs.count
        }
        self.message = message
    }
}

public struct AutomationStorageBackupResult: Codable, Equatable, Sendable {
    public let libraryID: UUID?
    public let backupPath: String
    public let createdAt: Date
    public let copiedFileCount: Int
    public let omittedFileCount: Int
    public let copiedBytes: Int64
    public let failures: [String]
    public let message: String

    public init(
        libraryID: UUID?,
        backupPath: String,
        createdAt: Date,
        copiedFileCount: Int,
        omittedFileCount: Int,
        copiedBytes: Int64,
        failures: [String] = [],
        message: String
    ) {
        self.libraryID = libraryID
        self.backupPath = backupPath
        self.createdAt = createdAt
        self.copiedFileCount = copiedFileCount
        self.omittedFileCount = omittedFileCount
        self.copiedBytes = copiedBytes
        self.failures = failures
        self.message = message
    }
}

public struct AutomationStorageDiffResult: Codable, Equatable, Sendable {
    public let libraryID: UUID?
    public let backupPath: String
    public let added: [String]
    public let removed: [String]
    public let changed: [String]
    public let unchangedCount: Int
    public let truncated: Bool
    public let message: String

    public init(
        libraryID: UUID?,
        backupPath: String,
        added: [String],
        removed: [String],
        changed: [String],
        unchangedCount: Int,
        truncated: Bool = false,
        message: String
    ) {
        self.libraryID = libraryID
        self.backupPath = backupPath
        self.added = added.sorted()
        self.removed = removed.sorted()
        self.changed = changed.sorted()
        self.unchangedCount = unchangedCount
        self.truncated = truncated
        self.message = message
    }
}

public struct AutomationCapabilityResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let scopes: [AutomationScope]
    public let grantedScopes: [AutomationScope]
    public let deniedScopes: [AutomationScope]
    public let tools: [AutomationToolDescriptor]
    public let notes: [String]

    public init(
        protocolVersion: Int = AutomationProtocol.currentVersion,
        scopes: [AutomationScope] = AutomationScope.allCases,
        grantedScopes: [AutomationScope] = AutomationScope.allCases,
        deniedScopes: [AutomationScope] = [],
        tools: [AutomationToolDescriptor] = AutomationToolCatalog.all,
        notes: [String] = []
    ) {
        self.protocolVersion = protocolVersion
        self.scopes = scopes.sorted { $0.rawValue < $1.rawValue }
        self.grantedScopes = grantedScopes.sorted { $0.rawValue < $1.rawValue }
        self.deniedScopes = deniedScopes.sorted { $0.rawValue < $1.rawValue }
        self.tools = tools
        self.notes = notes
    }
}

public struct AutomationScopeMutationResult: Codable, Equatable, Sendable {
    public let scope: AutomationScope
    public let granted: Bool
    public let persistent: Bool
    public let expiresAt: Date?
    public let message: String

    public init(
        scope: AutomationScope,
        granted: Bool,
        persistent: Bool = true,
        expiresAt: Date? = nil,
        message: String
    ) {
        self.scope = scope
        self.granted = granted
        self.persistent = persistent
        self.expiresAt = expiresAt
        self.message = message
    }
}

/// Shared short-form guidance used by MCP Resources and the public Agent
/// documentation. Keep this focused on stable product semantics; the full
/// examples and troubleshooting material live under `docs/`.
public enum AutomationDocumentation {
    public static let agentBehaviorGuide = """
    kmgccc_player automation semantics:
    - Track, Library membership, Playlist membership, Source membership and a real audio File are different relationships.
    - Removing a Track from a Playlist does not remove it from the Library or delete its file. Deleting a Playlist also retains Tracks and files.
    - When a referenced Source file disappears, the default is to preserve the Track, metadata, history and Playlist membership while marking it missing/unavailable.
    - Low-risk mutations may execute directly after authorization. Use dryRun for impact inspection. High-risk file deletion, destructive mirroring, mass deletion, history clearing and direct storage writes require App-owned foreground confirmation.
    - Prefer the formal Automation API, then diagnostics/repair, then the current-version source and storage documentation. Back up before any controlled storage fallback and validate/reload afterward.
    - Query first, preserve the returned revision, apply with expectedRevision when offered, and verify the result. Use idempotencyKey when retrying a mutation.
    - Metadata is App-owned and sidecar-backed: `metadata.get`/`metadata.patch` cover the editable Track fields, while embedded audio-file tags remain a separate capability. Use `dryRun` before a batch; batches of 10 or more require `confirm` plus foreground confirmation.
    - Artwork is App-owned and sidecar-backed: `artwork.get` reports availability and a digest without returning image bytes; `artwork.apply` accepts an App picker, an image path hint, base64 image data, or an explicit clear. Batches of 10 or more require `confirm` plus foreground confirmation.
    """

    public static let capabilityOverview = """
    The shared automation layer is App-owned. CLI and MCP are adapters over the same AF_UNIX IPC contract. `library.tracks` is the composable query entry point: combine text, IDs, Source/Playlist membership, availability, lyric/artwork/metadata state, technical audio fields, boolean all/any/not predicates, stable sort and offset pagination. Library Track identity is resolved before Playlist membership mutations, so an existing Track can be added to any Playlist without being imported again. Source exclusions, supported persistent settings, App-owned metadata/artwork, and App-owned storage inspect/validate/orphans/backup/diff/reload/repair are exposed as separate capabilities; arbitrary file or JSON writes are not ordinary tools.
    """
}

/// Provider-neutral capability metadata shared by CLI, MCP and a future
/// in-process Agent. The catalog describes the operation; the App remains the
/// only owner of validation, authorization, persistence and side effects.
public struct AutomationToolDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let readOnly: Bool
    public let requiresConfirmation: Bool
    public let scopes: [AutomationScope]
    public let risk: AutomationRiskLevel
    public let supportsDryRun: Bool
    public let supportsJobs: Bool
    public let supportsTasks: Bool
    public let inputSchema: AutomationJSONValue

    public init(
        name: String,
        title: String,
        description: String,
        readOnly: Bool,
        requiresConfirmation: Bool = false,
        scopes: [AutomationScope] = [],
        risk: AutomationRiskLevel = .medium,
        supportsDryRun: Bool = false,
        supportsJobs: Bool = false,
        supportsTasks: Bool = false,
        inputSchema: AutomationJSONValue
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.readOnly = readOnly
        self.requiresConfirmation = requiresConfirmation
        self.scopes = scopes.sorted { $0.rawValue < $1.rawValue }
        self.risk = risk
        self.supportsDryRun = supportsDryRun
        self.supportsJobs = supportsJobs
        self.supportsTasks = supportsTasks
        self.inputSchema = inputSchema
    }
}

public enum AutomationToolCatalog {
    public static let all: [AutomationToolDescriptor] = [
        AutomationToolDescriptor(
            name: AutomationMethod.systemPing,
            title: "Ping Player",
            description: "Check whether the local player automation endpoint is reachable.",
            readOnly: true,
            requiresConfirmation: false,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.systemInfo,
            title: "Player Info",
            description: "Read the player version, protocol capabilities and active library.",
            readOnly: true,
            requiresConfirmation: false,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryList,
            title: "List Libraries",
            description: "List registered local music libraries without switching the active library.",
            readOnly: true,
            requiresConfirmation: false,
            scopes: [.libraryRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryCreate,
            title: "Create Library",
            description: "Create and activate a new managed or referenced music library through the App-owned lifecycle transaction. The parent path is only a picker hint; the App owns authorization and destination validation.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.libraryManage],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: libraryCreateInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryOpen,
            title: "Open Library",
            description: "Open and register an existing music library selected through the App picker, then activate it as the current library.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.libraryManage],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: libraryOpenInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.librarySwitch,
            title: "Switch Library",
            description: "Activate a registered library by ID using the App-owned session switch and recovery transaction.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.libraryManage],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: librarySwitchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryRename,
            title: "Rename Library",
            description: "Update the display name of a registered library without changing its files or mode.",
            readOnly: false,
            scopes: [.libraryManage],
            risk: .low,
            supportsDryRun: true,
            inputSchema: libraryRenameInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryRelocate,
            title: "Relocate Library",
            description: "Move a registered library to a new parent directory through the App-owned relocation and recovery transaction.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.libraryManage],
            risk: .high,
            supportsDryRun: true,
            inputSchema: libraryRelocateInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryRemove,
            title: "Move Library to Trash",
            description: "Move a registered library root to the macOS Trash and update the registry. The App selects a successor or factory-default library when the removed library was active.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.libraryDelete],
            risk: .high,
            supportsDryRun: true,
            inputSchema: libraryRemoveInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryTracks,
            title: "Find Tracks",
            description: "Compose ID, text, source, playlist, availability, date, technical and metadata filters, then page and sort tracks.",
            readOnly: true,
            requiresConfirmation: false,
            scopes: [.libraryRead],
            risk: .low,
            inputSchema: libraryTracksInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistList,
            title: "List Playlists",
            description: "List playlists and opaque revisions in the active library.",
            readOnly: true,
            requiresConfirmation: false,
            scopes: [.playlistRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistCreate,
            title: "Create Playlist",
            description: "Create an empty playlist. This normal library mutation is direct and idempotent by request key when supplied; use dryRun for a preview.",
            readOnly: false,
            requiresConfirmation: false,
            scopes: [.playlistWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: playlistCreateInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistAddTracks,
            title: "Add Tracks to Playlist",
            description: "Add existing library tracks to a playlist without importing or copying files; duplicate membership is skipped.",
            readOnly: false,
            requiresConfirmation: false,
            scopes: [.playlistWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: playlistTrackMutationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistRemoveTracks,
            title: "Remove Tracks from Playlist",
            description: "Preview or remove playlist membership without deleting library tracks or files.",
            readOnly: false,
            requiresConfirmation: false,
            scopes: [.playlistWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: playlistTrackMutationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceList,
            title: "List Sources",
            description: "List authorized referenced-library sources and their current scan status.",
            readOnly: true,
            requiresConfirmation: false,
            scopes: [.sourceRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceRefresh,
            title: "Refresh Source",
            description: "Start a Job that scans an authorized Source and reconciles added, renamed and missing files; existing Track identities are reused and missing Tracks are preserved.",
            readOnly: false,
            requiresConfirmation: false,
            scopes: [.sourceWrite, .libraryWrite],
            risk: .low,
            supportsDryRun: true,
            supportsJobs: true,
            inputSchema: sourceRefreshInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.automationCapabilities,
            title: "Automation Capabilities",
            description: "Read the shared capability catalog, scopes, risk levels and supported composition features.",
            readOnly: true,
            requiresConfirmation: false,
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistGet,
            title: "Get Playlist",
            description: "Read one playlist's ordered Track IDs and opaque revision.",
            readOnly: true,
            scopes: [.playlistRead],
            risk: .low,
            inputSchema: playlistIDInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistRename,
            title: "Rename Playlist",
            description: "Rename a playlist without changing membership.",
            readOnly: false,
            scopes: [.playlistWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: playlistRenameInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistDelete,
            title: "Delete Playlist",
            description: "Delete a playlist and its memberships; Tracks and physical files are retained. This is a medium-risk mutation and supports preview.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.playlistWrite],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: destructiveIDInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistReplaceTracks,
            title: "Replace Playlist Tracks",
            description: "Replace the ordered membership of a playlist using existing library Track IDs.",
            readOnly: false,
            scopes: [.playlistWrite],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: playlistReplaceInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistReorder,
            title: "Reorder Playlist",
            description: "Reorder existing playlist membership without importing or deleting Tracks.",
            readOnly: false,
            scopes: [.playlistWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: playlistReplaceInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceCreate,
            title: "Add Source",
            description: "Request an authorized folder or file Source through the App picker, then start an import/reconcile Job. The Agent can initiate the whole permission flow.",
            readOnly: false,
            scopes: [.sourceWrite, .libraryWrite],
            risk: .medium,
            supportsDryRun: true,
            supportsJobs: true,
            inputSchema: sourceCreateInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceBindPlaylist,
            title: "Bind Source to Playlist",
            description: "Bind an authorized Source to an existing Playlist; source scans then keep that Playlist synchronized under its configured policy.",
            readOnly: false,
            scopes: [.sourceWrite, .playlistWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: sourceBindPlaylistInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceSetExcludedPath,
            title: "Set Source Exclusion",
            description: "Include or exclude a safe directory-relative path from a directory Source scan without deleting existing Tracks.",
            readOnly: false,
            scopes: [.sourceWrite, .libraryWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: sourceExcludedPathInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceSetMonitorPolicy,
            title: "Set Source Monitor Policy",
            description: "Enable or disable automatic filesystem reconciliation for a Source; manual refresh remains available when disabled.",
            readOnly: false,
            scopes: [.sourceWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: sourceMonitorPolicyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceRemove,
            title: "Remove Source",
            description: "Remove a Source authority and its source contribution. Preview first; the App policy decides how orphaned Tracks are retained.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.sourceWrite, .libraryWrite],
            risk: .high,
            supportsDryRun: true,
            inputSchema: destructiveIDInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.filesInspect,
            title: "Inspect Track Files",
            description: "Inspect the current or last-known physical file path, availability and Source memberships for existing Tracks.",
            readOnly: true,
            scopes: [.filesRead, .libraryRead],
            risk: .low,
            inputSchema: fileInspectInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.filesRename,
            title: "Rename Track Files",
            description: "Rename authorized referenced audio files in place. A single rename is direct; bulk renames require a preview and App foreground confirmation, then trigger Source reconciliation.",
            readOnly: false,
            scopes: [.filesWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            supportsJobs: true,
            inputSchema: fileRenameInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.filesMove,
            title: "Move Track Files",
            description: "Move authorized referenced audio files to a directory Source-relative destination. Parent folders may be created; bulk moves require a preview and App foreground confirmation.",
            readOnly: false,
            scopes: [.filesWrite, .libraryRead, .sourceRead],
            risk: .medium,
            supportsDryRun: true,
            supportsJobs: true,
            inputSchema: fileMoveInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.filesDelete,
            title: "Move Track Files to Trash",
            description: "Preview and move real referenced audio files to the macOS Trash. The App always asks for foreground confirmation; Tracks remain in the Library and Source refresh marks them missing.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.filesDelete, .libraryRead],
            risk: .high,
            supportsDryRun: true,
            supportsJobs: true,
            inputSchema: fileDeleteInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playbackState,
            title: "Playback State",
            description: "Read current playback source, Track, position, volume and playback mode.",
            readOnly: true,
            scopes: [.playbackRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playbackPlay,
            title: "Play",
            description: "Play one existing Track or an ordered set of existing Tracks from the active library.",
            readOnly: false,
            scopes: [.playbackControl, .libraryRead],
            risk: .low,
            inputSchema: playbackPlayInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playbackPause,
            title: "Pause",
            description: "Pause the active playback provider.",
            readOnly: false,
            scopes: [.playbackControl],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playbackNext,
            title: "Next Track",
            description: "Advance to the next item in the active playback queue/provider.",
            readOnly: false,
            scopes: [.playbackControl],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playbackPrevious,
            title: "Previous Track",
            description: "Go to the previous item in the active playback queue/provider.",
            readOnly: false,
            scopes: [.playbackControl],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playbackSeek,
            title: "Seek",
            description: "Seek the active playback provider to a position in seconds.",
            readOnly: false,
            scopes: [.playbackControl],
            risk: .low,
            inputSchema: playbackSeekInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playbackSetVolume,
            title: "Set Volume",
            description: "Set the active provider volume between 0 and 1.",
            readOnly: false,
            scopes: [.playbackControl, .audioWrite],
            risk: .low,
            inputSchema: playbackVolumeInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playbackSetMode,
            title: "Set Playback Mode",
            description: "Set sequence, shuffle, repeat-one or stop-after-track playback mode.",
            readOnly: false,
            scopes: [.playbackControl, .audioWrite],
            risk: .low,
            inputSchema: playbackModeInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.queueGet,
            title: "Get Queue",
            description: "Read the current local queue, current Track and opaque queue revision.",
            readOnly: true,
            scopes: [.queueRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.queueReplace,
            title: "Replace Queue",
            description: "Replace the local queue with existing Track IDs using an optional expected queue revision.",
            readOnly: false,
            scopes: [.queueWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: queueMutationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.queueEnqueue,
            title: "Enqueue Tracks",
            description: "Append existing Tracks to the local queue.",
            readOnly: false,
            scopes: [.queueWrite, .libraryRead],
            risk: .low,
            inputSchema: queueMutationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.queueEnqueueNext,
            title: "Enqueue Next",
            description: "Insert existing Tracks after the currently playing Track.",
            readOnly: false,
            scopes: [.queueWrite, .libraryRead],
            risk: .low,
            inputSchema: queueMutationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.queueClear,
            title: "Clear Queue",
            description: "Clear the local queue. The currently playing item may remain provider-defined.",
            readOnly: false,
            scopes: [.queueWrite],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: queueClearInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.historyList,
            title: "List History",
            description: "Read recent listening history with optional limit and date bounds.",
            readOnly: true,
            scopes: [.historyRead],
            risk: .low,
            inputSchema: historyListInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.historyClear,
            title: "Clear History",
            description: "Delete all listening history. The App must require foreground confirmation.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.historyWrite],
            risk: .high,
            supportsDryRun: true,
            inputSchema: confirmationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.metadataGet,
            title: "Get Metadata",
            description: "Read authoritative App metadata and technical fields for one or more existing Tracks.",
            readOnly: true,
            scopes: [.metadataRead, .libraryRead],
            risk: .low,
            inputSchema: metadataGetInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.metadataPatch,
            title: "Patch Metadata",
            description: "Patch the editable App-owned Track metadata, including credits, language, label, provider IDs, confidence, fetch time and lyric offset. This does not write embedded tags into the original audio file; batches of 10 or more require foreground confirmation.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.metadataWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: metadataPatchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.artworkGet,
            title: "Get Artwork",
            description: "Read App-owned Track artwork availability, stored filename, size and digest without returning image bytes.",
            readOnly: true,
            scopes: [.artworkRead, .libraryRead],
            risk: .low,
            inputSchema: artworkGetInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.artworkApply,
            title: "Apply Artwork",
            description: "Replace or clear App-owned Track artwork using an App-owned picker, an image path hint or base64 data. Batches of 10 or more require foreground confirmation; original audio-file tags are not changed.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.artworkWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: artworkApplyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.lyricsGet,
            title: "Get Lyrics",
            description: "Read the current persisted TTML/plain lyrics and normalized lyrics status for a Track.",
            readOnly: true,
            scopes: [.lyricsRead, .libraryRead],
            risk: .low,
            inputSchema: lyricsGetInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.lyricsSearch,
            title: "Search Lyrics",
            description: "Search the existing AMLLDB and LDDC providers and return ranked, selectable lyrics candidates for one Track.",
            readOnly: true,
            scopes: [.lyricsRead, .libraryRead],
            risk: .low,
            inputSchema: lyricsSearchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.lyricsCandidates,
            title: "List Lyrics Candidates",
            description: "Return the last ranked lyrics candidates for a Track, or run a fresh provider search when no cached result exists.",
            readOnly: true,
            scopes: [.lyricsRead, .libraryRead],
            risk: .low,
            inputSchema: lyricsCandidatesInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.lyricsCompare,
            title: "Compare Lyrics Candidate",
            description: "Compare a selected lyrics candidate's synchronization quality with the Track's current lyrics without changing the Library.",
            readOnly: true,
            scopes: [.lyricsRead, .libraryRead],
            risk: .low,
            inputSchema: lyricsCompareInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.lyricsApply,
            title: "Apply Lyrics Candidate",
            description: "Fetch and apply one selected lyrics candidate through the existing provider pipeline; without force, a lower-quality result is never used.",
            readOnly: false,
            scopes: [.lyricsWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: lyricsApplyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.lyricsRefresh,
            title: "Refresh Lyrics",
            description: "Search selected Tracks through the existing lyrics providers and return a tracked batch Job; only a better result replaces the current lyrics.",
            readOnly: false,
            scopes: [.lyricsWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            supportsJobs: true,
            inputSchema: lyricsRefreshInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.jobsList,
            title: "List Jobs",
            description: "Read active long-running library operations and their checkpoints.",
            readOnly: true,
            scopes: [.diagnosticsRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.jobsGet,
            title: "Get Job",
            description: "Read one active library operation by ID.",
            readOnly: true,
            scopes: [.diagnosticsRead],
            risk: .low,
            inputSchema: jobIDInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.jobsCancel,
            title: "Cancel Job",
            description: "Request cancellation of an active library operation.",
            readOnly: false,
            scopes: [.diagnosticsRepair],
            risk: .medium,
            inputSchema: jobIDInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.jobsRetry,
            title: "Retry Job",
            description: "Retry a failed, partially failed or cancelled Source scan or lyrics refresh when the App has a durable retry specification.",
            readOnly: false,
            scopes: [.diagnosticsRepair],
            risk: .medium,
            inputSchema: jobIDInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.diagnosticsHealth,
            title: "Library Health",
            description: "Inspect Library, Source, missing Track and active Job health with actionable evidence.",
            readOnly: true,
            scopes: [.diagnosticsRead, .libraryRead, .sourceRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.settingsGet,
            title: "Get Automation Settings",
            description: "Read the small set of persistent library settings currently safe to automate, including referenced-track deletion policy.",
            readOnly: true,
            scopes: [.settingsRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.settingsPatch,
            title: "Patch Automation Settings",
            description: "Preview or update supported persistent library settings. Unsupported UI-only preferences are rejected instead of being guessed.",
            readOnly: false,
            scopes: [.settingsWrite],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: settingsPatchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.storageInspect,
            title: "Inspect Library Storage",
            description: "Read the active Library storage mode, schema, root and required-directory health without writing files or exposing secrets.",
            readOnly: true,
            scopes: [.storageRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.storageValidate,
            title: "Validate Library Storage",
            description: "Run the App-owned storage, sidecar, index, manifest and playback-history integrity validator against the active Library.",
            readOnly: true,
            scopes: [.storageRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.storageRepair,
            title: "Repair Library Scaffolding",
            description: "Repair only missing App-owned Library directories and the default scoped-settings file, then leave domain data untouched.",
            readOnly: false,
            scopes: [.storageWrite, .diagnosticsRepair],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: storageMutationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.storageOrphans,
            title: "Find Storage Orphans",
            description: "Report Playlist memberships that reference missing Track sidecars without changing the Library.",
            readOnly: true,
            scopes: [.storageRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.storageBackup,
            title: "Back Up Library Metadata",
            description: "Create an App-owned, machine-readable backup of Library JSON sidecars and enrichment assets without copying audio files, indexes or caches.",
            readOnly: false,
            scopes: [.storageRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.storageDiff,
            title: "Compare Library Metadata",
            description: "Compare the current App-owned JSON/sidecar snapshot with a backup previously created by storage.backup.",
            readOnly: true,
            scopes: [.storageRead],
            risk: .low,
            inputSchema: storageDiffInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.storageReload,
            title: "Reload Library Storage",
            description: "Reload the active Library from its current App-owned storage after an external, controlled change; no arbitrary write is performed by this capability.",
            readOnly: false,
            scopes: [.storageRead, .diagnosticsRepair],
            risk: .medium,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.automationScopes,
            title: "Automation Scope Status",
            description: "Read the App-owned granted and denied automation scopes.",
            readOnly: true,
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.automationGrantScope,
            title: "Grant Automation Scope",
            description: "Request an App-owned scope grant. The App requires foreground confirmation, especially for file deletion or storage writes.",
            readOnly: false,
            requiresConfirmation: true,
            risk: .high,
            supportsDryRun: true,
            inputSchema: scopeMutationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.automationRevokeScope,
            title: "Revoke Automation Scope",
            description: "Revoke one App-owned automation scope for future calls.",
            readOnly: false,
            risk: .low,
            inputSchema: scopeInputSchema
        )
    ].sorted { $0.name < $1.name }

    public static func descriptor(for name: String) -> AutomationToolDescriptor? {
        all.first { $0.name == name }
    }

    /// Return unknown top-level parameter names for a tool whose schema opts
    /// into strict object validation. Nested objects can remain open when the
    /// schema deliberately uses them as extension points (for example the
    /// metadata patch payload).
    public static func unknownParameterKeys(
        for name: String,
        params: AutomationJSONValue?
    ) -> [String] {
        guard case let .object(values)? = params,
              let descriptor = descriptor(for: name),
              case let .object(schema) = descriptor.inputSchema,
              case .boolean(false)? = schema["additionalProperties"] else {
            return []
        }
        guard case let .object(properties)? = schema["properties"] else {
            return values.keys.sorted()
        }
        return values.keys.filter { properties[$0] == nil }.sorted()
    }

    private static let emptyInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false)
    ])

    private static let libraryTracksInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "query": .object(["type": .string("string")]),
            "playlistID": .object(["type": .string("string")]),
            "sourceID": .object(["type": .string("string")]),
            "relativePathPrefix": .object(["type": .string("string")]),
            "ids": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "filter": .object([
                "type": .string("object"),
                "description": .string("Composable filter object: all/any/not plus id, ids, text, titleContains, artistContains, albumContains, genreContains, sourceID, playlistID, availability, missing, addedAfter, addedBefore, releaseAfter, releaseBefore, durationMin, durationMax, hasLyrics, lyricsStatus, hasArtwork, metadataConfidenceMin, codec, format, sampleRateHz and bitDepth.")
            ]),
            "sort": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "field": .object(["type": .string("string")]),
                        "direction": .object(["type": .string("string"), "enum": .array([.string("asc"), .string("desc")])])
                    ])
                ])
            ]),
            "limit": .object([
                "type": .string("integer"),
                "minimum": .number(1),
                "maximum": .number(500)
            ]),
            "offset": .object([
                "type": .string("integer"),
                "minimum": .number(0)
            ]),
            "expectedRevision": .object([
                "type": .string("string")
            ])
        ])
    ])

    private static let libraryCreateInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("mode"), .string("displayName")]),
        "properties": .object([
            "mode": .object([
                "type": .string("string"),
                "enum": .array([.string("managed"), .string("referenced")])
            ]),
            "displayName": .object(["type": .string("string"), "minLength": .number(1)]),
            "parentPath": .object(["type": .string("string")]),
            "allowAlternateDestinationWhenOccupied": .object(["type": .string("boolean")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let libraryOpenInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "path": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let librarySwitchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("libraryID")]),
        "properties": .object([
            "libraryID": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let libraryRenameInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("libraryID"), .string("displayName")]),
        "properties": .object([
            "libraryID": .object(["type": .string("string")]),
            "displayName": .object(["type": .string("string"), "minLength": .number(1)]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let libraryRelocateInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("libraryID")]),
        "properties": .object([
            "libraryID": .object(["type": .string("string")]),
            "parentPath": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let libraryRemoveInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("libraryID")]),
        "properties": .object([
            "libraryID": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let playlistCreateInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("name")]),
        "properties": .object([
            "name": .object(["type": .string("string"), "minLength": .number(1)]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let playlistTrackMutationInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("playlistID"), .string("trackIDs")]),
        "properties": .object([
            "playlistID": .object(["type": .string("string")]),
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "items": .object(["type": .string("string")])
            ]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let sourceRefreshInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("sourceID")]),
        "properties": .object([
            "sourceID": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
        ])
    ])

    private static let queueClearInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let metadataGetInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "trackIDs": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ])
        ])
    ])

    private static let metadataPatchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackIDs"), .string("patch")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "items": .object(["type": .string("string")])
            ]),
            "patch": .object(["type": .string("object")]),
            "expectedRevisions": .object(["type": .string("object")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let artworkGetInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackIDs")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "items": .object(["type": .string("string")])
            ])
        ])
    ])

    private static let artworkApplyInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackIDs")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "items": .object(["type": .string("string")])
            ]),
            "imagePath": .object(["type": .string("string")]),
            "imageBase64": .object(["type": .string("string")]),
            "clear": .object(["type": .string("boolean")]),
            "expectedRevisions": .object(["type": .string("object")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let lyricsGetInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackID")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")])
        ])
    ])

    private static let lyricsCandidateSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([
            .string("source"),
            .string("songID"),
            .string("title"),
            .string("mode")
        ]),
        "properties": .object([
            "source": .object(["type": .string("string")]),
            "songID": .object(["type": .string("string")]),
            "score": .object(["type": .string("number")]),
            "normalizedScore": .object(["type": .string("number")]),
            "title": .object(["type": .string("string")]),
            "artist": .object(["type": .string("string")]),
            "album": .object(["type": .string("string")]),
            "durationMs": .object(["type": .string("integer")]),
            "mode": .object(["type": .string("string"), "enum": .array([.string("line"), .string("verbatim")])]),
            "extra": .object(["type": .string("object")])
        ])
    ])

    private static let lyricsSearchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackID")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "mode": .object(["type": .string("string"), "enum": .array([.string("line"), .string("verbatim")])]),
            "translation": .object(["type": .string("boolean")])
        ])
    ])

    private static let lyricsCandidatesInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackID")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "mode": .object(["type": .string("string"), "enum": .array([.string("line"), .string("verbatim")])]),
            "translation": .object(["type": .string("boolean")]),
            "refresh": .object(["type": .string("boolean")])
        ])
    ])

    private static let lyricsCompareInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackID"), .string("candidate")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "candidate": lyricsCandidateSchema
        ])
    ])

    private static let lyricsApplyInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackID"), .string("candidate")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "candidate": lyricsCandidateSchema,
            "force": .object(["type": .string("boolean")]),
            "translation": .object(["type": .string("boolean")]),
            "dryRun": .object(["type": .string("boolean")]),
            "expectedRevision": .object(["type": .string("string")])
        ])
    ])

    private static let lyricsRefreshInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackIDs")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "items": .object(["type": .string("string")])
            ]),
            "force": .object(["type": .string("boolean")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let playlistIDInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("playlistID")]),
        "properties": .object([
            "playlistID": .object(["type": .string("string")])
        ])
    ])

    private static let playlistRenameInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("playlistID"), .string("name")]),
        "properties": .object([
            "playlistID": .object(["type": .string("string")]),
            "name": .object(["type": .string("string"), "minLength": .number(1)]),
            "description": .object(["type": .string("string")]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let playlistReplaceInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("playlistID"), .string("trackIDs")]),
        "properties": .object([
            "playlistID": .object(["type": .string("string")]),
            "trackIDs": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let destructiveIDInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("id")]),
        "properties": .object([
            "id": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let sourceCreateInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "path": .object(["type": .string("string")]),
            "mode": .object(["type": .string("string"), "enum": .array([.string("directory"), .string("file")])]),
            "playlistID": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let scopeInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("scope")]),
        "properties": .object([
            "scope": .object([
                "type": .string("string"),
                "enum": .array(AutomationScope.allCases.map { .string($0.rawValue) })
            ])
        ])
    ])

    private static let scopeMutationInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("scope")]),
        "properties": .object([
            "scope": .object([
                "type": .string("string"),
                "enum": .array(AutomationScope.allCases.map { .string($0.rawValue) })
            ]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let sourceBindPlaylistInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("sourceID"), .string("playlistID")]),
        "properties": .object([
            "sourceID": .object(["type": .string("string")]),
            "playlistID": .object(["type": .string("string")]),
            "relativePath": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let sourceExcludedPathInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("sourceID"), .string("relativePath")]),
        "properties": .object([
            "sourceID": .object(["type": .string("string")]),
            "relativePath": .object(["type": .string("string"), "minLength": .number(1)]),
            "excluded": .object(["type": .string("boolean")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let sourceMonitorPolicyInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("sourceID"), .string("policy")]),
        "properties": .object([
            "sourceID": .object(["type": .string("string")]),
            "policy": .object([
                "type": .string("string"),
                "enum": .array([.string("on"), .string("off")])
            ]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let fileInspectInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackIDs")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(5_000),
                "items": .object(["type": .string("string")])
            ])
        ])
    ])

    private static let fileRenameInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("operations")]),
        "properties": .object([
            "operations": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(5_000),
                "items": .object([
                    "type": .string("object"),
                    "required": .array([.string("trackID"), .string("name")]),
                    "properties": .object([
                        "trackID": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")])
                    ])
                ])
            ]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let fileMoveInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("operations")]),
        "properties": .object([
            "operations": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(5_000),
                "items": .object([
                    "type": .string("object"),
                    "required": .array([.string("trackID"), .string("sourceID"), .string("relativePath")]),
                    "properties": .object([
                        "trackID": .object(["type": .string("string")]),
                        "sourceID": .object(["type": .string("string")]),
                        "relativePath": .object(["type": .string("string"), "minLength": .number(1)])
                    ])
                ])
            ]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let fileDeleteInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackIDs")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(5_000),
                "items": .object(["type": .string("string")])
            ]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let settingsPatchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("values")]),
        "properties": .object([
            "values": .object([
                "type": .string("object"),
                "description": .string("Currently supported: referencedTrackDeletePolicy = onlyLibrary or recycleSource.")
            ]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let storageMutationInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let storageDiffInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("backupPath")]),
        "properties": .object([
            "backupPath": .object(["type": .string("string"), "minLength": .number(1)])
        ])
    ])

    private static let playbackPlayInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "trackIDs": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "startIndex": .object(["type": .string("integer"), "minimum": .number(0)])
        ])
    ])

    private static let playbackSeekInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("seconds")]),
        "properties": .object([
            "seconds": .object(["type": .string("number"), "minimum": .number(0)])
        ])
    ])

    private static let playbackVolumeInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("volume")]),
        "properties": .object([
            "volume": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)])
        ])
    ])

    private static let playbackModeInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("mode")]),
        "properties": .object([
            "mode": .object([
                "type": .string("string"),
                "enum": .array([.string("sequence"), .string("shuffle"), .string("repeatOne"), .string("stopAfterTrack")])
            ])
        ])
    ])

    private static let queueMutationInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackIDs")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "items": .object(["type": .string("string")])
            ]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let historyListInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(500)]),
            "from": .object(["type": .string("string")]),
            "to": .object(["type": .string("string")])
        ])
    ])

    private static let confirmationInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let jobIDInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("jobID")]),
        "properties": .object([
            "jobID": .object(["type": .string("string")])
        ])
    ])
}

public enum AutomationWireCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
