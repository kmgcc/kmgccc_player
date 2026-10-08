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
    case selectionWrite = "selection.write"
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
    public static let libraryGet = "library.get"
    public static let libraryCreate = "library.create"
    public static let libraryOpen = "library.open"
    public static let librarySwitch = "library.switch"
    public static let libraryRename = "library.rename"
    public static let libraryRelocate = "library.relocate"
    public static let libraryRemove = "library.remove"
    public static let libraryTracks = "library.tracks"
    public static let libraryImport = "library.import"
    public static let libraryStats = "library.stats"
    public static let libraryReport = "library.report"
    public static let libraryBundleExport = "library.bundle.export"
    public static let librarySelectionList = "library.selection.list"
    public static let librarySelectionCreate = "library.selection.create"
    public static let librarySelectionGet = "library.selection.get"
    public static let librarySelectionDelete = "library.selection.delete"
    public static let playlistList = "playlist.list"
    public static let playlistCreate = "playlist.create"
    public static let playlistAddTracks = "playlist.addTracks"
    public static let playlistAddSelection = "playlist.addSelection"
    public static let playlistRemoveTracks = "playlist.removeTracks"
    public static let sourceList = "source.list"
    public static let sourceGet = "source.get"
    public static let sourceConfigExport = "source.config.export"
    public static let sourceConfigImport = "source.config.import"
    public static let sourceRename = "source.rename"
    public static let sourceRefresh = "source.refresh"
    public static let sourceCreate = "source.create"
    public static let sourceBindPlaylist = "source.bindPlaylist"
    public static let sourceSetExcludedPath = "source.setExcludedPath"
    public static let sourceSetMonitorPolicy = "source.setMonitorPolicy"
    public static let sourceRemove = "source.remove"
    public static let filesInspect = "files.inspect"
    public static let filesReveal = "files.reveal"
    public static let filesExport = "files.export"
    public static let filesRename = "files.rename"
    public static let filesMove = "files.move"
    public static let filesDelete = "files.delete"
    public static let playlistGet = "playlist.get"
    public static let playlistRename = "playlist.rename"
    public static let playlistDelete = "playlist.delete"
    public static let playlistReplaceTracks = "playlist.replaceTracks"
    public static let playlistReorder = "playlist.reorder"
    public static let playlistDiff = "playlist.diff"
    public static let playlistImport = "playlist.import"
    public static let playlistExport = "playlist.export"
    public static let playbackState = "playback.state"
    public static let playbackPlay = "playback.play"
    public static let playbackPlayPlaylist = "playback.playPlaylist"
    public static let playbackToggle = "playback.toggle"
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
    public static let queueRemove = "queue.remove"
    public static let queueReorder = "queue.reorder"
    public static let queueUpcoming = "queue.upcoming"
    public static let historyList = "history.list"
    public static let historyStats = "history.stats"
    public static let historyClear = "history.clear"
    public static let metadataGet = "metadata.get"
    public static let metadataEmbeddedGet = "metadata.embedded.get"
    public static let metadataEmbeddedPatch = "metadata.embedded.patch"
    public static let metadataExport = "metadata.export"
    public static let metadataImport = "metadata.import"
    public static let metadataSearch = "metadata.search"
    public static let metadataApplyCandidate = "metadata.applyCandidate"
    public static let metadataPatch = "metadata.patch"
    public static let artworkSearch = "artwork.search"
    public static let artworkGet = "artwork.get"
    public static let artworkApply = "artwork.apply"
    public static let artworkApplyCandidate = "artwork.applyCandidate"
    public static let lyricsGet = "lyrics.get"
    public static let lyricsSearch = "lyrics.search"
    public static let lyricsCandidates = "lyrics.candidates"
    public static let lyricsCompare = "lyrics.compare"
    public static let lyricsApply = "lyrics.apply"
    public static let lyricsClean = "lyrics.clean"
    public static let lyricsRefresh = "lyrics.refresh"
    public static let jobsList = "jobs.list"
    public static let jobsGet = "jobs.get"
    public static let jobsWait = "jobs.wait"
    public static let jobsCancel = "jobs.cancel"
    public static let jobsRetry = "jobs.retry"
    public static let operationsBatch = "operations.batch"
    public static let diagnosticsHealth = "diagnostics.health"
    public static let settingsGet = "settings.get"
    public static let settingsSchema = "settings.schema"
    public static let settingsPatch = "settings.patch"
    public static let settingsValidate = "settings.validate"
    public static let settingsReset = "settings.reset"
    public static let audioGet = "audio.get"
    public static let audioPatch = "audio.patch"
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

public struct AutomationLibraryImportFileTrackMapping: Codable, Equatable, Sendable {
    public let filePath: String
    public let trackID: UUID

    public init(filePath: String, trackID: UUID) {
        self.filePath = filePath
        self.trackID = trackID
    }
}

public struct AutomationLibraryImportResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let mode: String
    public let filePaths: [String]
    public let targetPlaylistID: UUID?
    public let dryRun: Bool
    public let job: AutomationJobSummary?
    public let enrichmentPolicy: String
    public let fileTrackMappings: [AutomationLibraryImportFileTrackMapping]
    public let message: String

    public init(libraryID: UUID, mode: String, filePaths: [String],
                targetPlaylistID: UUID? = nil, dryRun: Bool = false,
                job: AutomationJobSummary? = nil,
                enrichmentPolicy: String = "standard",
                fileTrackMappings: [AutomationLibraryImportFileTrackMapping] = [],
                message: String) {
        self.libraryID = libraryID
        self.mode = mode
        self.filePaths = filePaths
        self.targetPlaylistID = targetPlaylistID
        self.dryRun = dryRun
        self.job = job
        self.enrichmentPolicy = enrichmentPolicy
        self.fileTrackMappings = fileTrackMappings
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case libraryID, mode, filePaths, targetPlaylistID, dryRun, job
        case enrichmentPolicy, fileTrackMappings, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryID = try container.decode(UUID.self, forKey: .libraryID)
        mode = try container.decode(String.self, forKey: .mode)
        filePaths = try container.decode([String].self, forKey: .filePaths)
        targetPlaylistID = try container.decodeIfPresent(UUID.self, forKey: .targetPlaylistID)
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        job = try container.decodeIfPresent(AutomationJobSummary.self, forKey: .job)
        enrichmentPolicy = try container.decodeIfPresent(String.self, forKey: .enrichmentPolicy) ?? "standard"
        fileTrackMappings = try container.decodeIfPresent(
            [AutomationLibraryImportFileTrackMapping].self,
            forKey: .fileTrackMappings
        ) ?? []
        message = try container.decode(String.self, forKey: .message)
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

public struct AutomationLibraryGetResult: Codable, Equatable, Sendable {
    public let library: AutomationLibrarySummary
    public let activeLibraryID: UUID?

    public init(library: AutomationLibrarySummary, activeLibraryID: UUID?) {
        self.library = library
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

/// The file-tag values captured at import time. This is a historical snapshot,
/// not a live read of a file that may have been edited outside the App.
public struct AutomationEmbeddedMetadataSnapshot: Codable, Equatable, Sendable {
    public let title: String?
    public let artistDisplay: String?
    public let album: String?
    public let albumArtist: String?
    public let releaseYear: Int?
    public let compilation: Bool?
    public let musicBrainzReleaseID: String?
    public let durationSeconds: Double?
    public let capturedAt: Date

    public init(
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

public struct AutomationTrackPreferenceSummary: Codable, Equatable, Sendable {
    public let playCount: Int
    public let completePlayCount: Int
    public let skipCount: Int
    public let quickSkipCount: Int
    public let totalPlayedSeconds: Double
    public let lastPlayedAt: Date?
    public let lastCompletedAt: Date?
    public let lastSkippedAt: Date?
    public let likeState: String
    public let preferenceScore: Double
    public let effectiveWeight: Double

    public init(
        playCount: Int,
        completePlayCount: Int,
        skipCount: Int,
        quickSkipCount: Int,
        totalPlayedSeconds: Double,
        lastPlayedAt: Date?,
        lastCompletedAt: Date?,
        lastSkippedAt: Date?,
        likeState: String,
        preferenceScore: Double,
        effectiveWeight: Double
    ) {
        self.playCount = playCount
        self.completePlayCount = completePlayCount
        self.skipCount = skipCount
        self.quickSkipCount = quickSkipCount
        self.totalPlayedSeconds = totalPlayedSeconds
        self.lastPlayedAt = lastPlayedAt
        self.lastCompletedAt = lastCompletedAt
        self.lastSkippedAt = lastSkippedAt
        self.likeState = likeState
        self.preferenceScore = preferenceScore
        self.effectiveWeight = effectiveWeight
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
    public let embeddedMetadataSnapshot: AutomationEmbeddedMetadataSnapshot?
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
    public let preferenceStats: AutomationTrackPreferenceSummary?

    public init(
        id: UUID,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        availability: String,
        addedAt: Date,
        importedAt: Date?,
        embeddedMetadataSnapshot: AutomationEmbeddedMetadataSnapshot? = nil,
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
        playlistIDs: [UUID] = [],
        preferenceStats: AutomationTrackPreferenceSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.availability = availability
        self.addedAt = addedAt
        self.importedAt = importedAt
        self.embeddedMetadataSnapshot = embeddedMetadataSnapshot
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
        self.preferenceStats = preferenceStats
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, availability, addedAt, importedAt
        case embeddedMetadataSnapshot
        case sourceMemberships, artistCredits, albumArtist, userDescription
        case genreTags, language, labelOrCompany, releaseDate, qqMusicSongMid
        case metadataSource, metadataFetchedAt, metadataConfidence, musicBrainzReleaseID
        case lyricsTimeOffsetMs, lyricsStatus, artworkAvailable, artworkFileName
        case format, codec
        case sampleRateHz, bitDepth, channelCount, filePath, playlistIDs, preferenceStats
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
        embeddedMetadataSnapshot = try container.decodeIfPresent(
            AutomationEmbeddedMetadataSnapshot.self,
            forKey: .embeddedMetadataSnapshot
        )
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
        preferenceStats = try container.decodeIfPresent(
            AutomationTrackPreferenceSummary.self,
            forKey: .preferenceStats
        )
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

public struct AutomationLibraryStatsResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let mode: String
    public let trackCount: Int
    public let availableTrackCount: Int
    public let missingTrackCount: Int
    public let recoverableTrackCount: Int
    public let playlistCount: Int
    public let linkedSourceCount: Int
    public let artistCount: Int
    public let albumCount: Int
    public let lyricsTrackCount: Int
    public let artworkTrackCount: Int
    public let totalDurationSeconds: Double
    public let revision: String

    public init(libraryID: UUID, mode: String, trackCount: Int, availableTrackCount: Int,
                missingTrackCount: Int, recoverableTrackCount: Int, playlistCount: Int,
                linkedSourceCount: Int, artistCount: Int, albumCount: Int, lyricsTrackCount: Int,
                artworkTrackCount: Int, totalDurationSeconds: Double, revision: String) {
        self.libraryID = libraryID
        self.mode = mode
        self.trackCount = trackCount
        self.availableTrackCount = availableTrackCount
        self.missingTrackCount = missingTrackCount
        self.recoverableTrackCount = recoverableTrackCount
        self.playlistCount = playlistCount
        self.linkedSourceCount = linkedSourceCount
        self.artistCount = artistCount
        self.albumCount = albumCount
        self.lyricsTrackCount = lyricsTrackCount
        self.artworkTrackCount = artworkTrackCount
        self.totalDurationSeconds = totalDurationSeconds
        self.revision = revision
    }
}

public struct AutomationLibraryReportResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let stats: AutomationLibraryStatsResult
    public let tracks: [AutomationTrackSummary]
    public let playlists: [AutomationPlaylistSummary]
    public let offset: Int
    public let limit: Int
    public let nextOffset: Int?
    public let playlistOffset: Int
    public let playlistLimit: Int
    public let nextPlaylistOffset: Int?
    public let revision: String

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        stats: AutomationLibraryStatsResult,
        tracks: [AutomationTrackSummary],
        playlists: [AutomationPlaylistSummary],
        offset: Int,
        limit: Int,
        nextOffset: Int?,
        playlistOffset: Int = 0,
        playlistLimit: Int = 100,
        nextPlaylistOffset: Int? = nil,
        revision: String
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.stats = stats
        self.tracks = tracks
        self.playlists = playlists
        self.offset = offset
        self.limit = limit
        self.nextOffset = nextOffset
        self.playlistOffset = playlistOffset
        self.playlistLimit = playlistLimit
        self.nextPlaylistOffset = nextPlaylistOffset
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, stats, tracks, playlists
        case offset, limit, nextOffset, playlistOffset, playlistLimit, nextPlaylistOffset, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date(timeIntervalSince1970: 0)
        stats = try container.decode(AutomationLibraryStatsResult.self, forKey: .stats)
        tracks = try container.decode([AutomationTrackSummary].self, forKey: .tracks)
        playlists = try container.decode([AutomationPlaylistSummary].self, forKey: .playlists)
        offset = try container.decode(Int.self, forKey: .offset)
        limit = try container.decode(Int.self, forKey: .limit)
        nextOffset = try container.decodeIfPresent(Int.self, forKey: .nextOffset)
        playlistOffset = try container.decodeIfPresent(Int.self, forKey: .playlistOffset) ?? 0
        playlistLimit = try container.decodeIfPresent(Int.self, forKey: .playlistLimit) ?? max(1, playlists.count)
        nextPlaylistOffset = try container.decodeIfPresent(Int.self, forKey: .nextPlaylistOffset)
        revision = try container.decodeIfPresent(String.self, forKey: .revision) ?? "v1-unknown"
    }
}

public struct AutomationLibraryBundleExportResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let dryRun: Bool
    public let applied: Bool
    public let confirmed: Bool
    public let trackCount: Int
    public let estimatedBytes: Int64
    public let copiedFileCount: Int
    public let copiedBytes: Int64
    public let outputDirectory: String?
    public let job: AutomationJobSummary?
    public let failures: [String]
    public let message: String

    public init(
        libraryID: UUID,
        dryRun: Bool,
        applied: Bool = false,
        confirmed: Bool = false,
        trackCount: Int,
        estimatedBytes: Int64 = 0,
        copiedFileCount: Int = 0,
        copiedBytes: Int64 = 0,
        outputDirectory: String? = nil,
        job: AutomationJobSummary? = nil,
        failures: [String] = [],
        message: String
    ) {
        self.libraryID = libraryID
        self.dryRun = dryRun
        self.applied = applied
        self.confirmed = confirmed
        self.trackCount = trackCount
        self.estimatedBytes = estimatedBytes
        self.copiedFileCount = copiedFileCount
        self.copiedBytes = copiedBytes
        self.outputDirectory = outputDirectory
        self.job = job
        self.failures = failures
        self.message = message
    }
}

public struct AutomationSelectionSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String?
    public let trackCount: Int
    public let revision: String
    public let createdAt: Date
    public let expiresAt: Date
    public let isDynamic: Bool

    public init(
        id: UUID,
        name: String?,
        trackCount: Int,
        revision: String,
        createdAt: Date,
        expiresAt: Date,
        isDynamic: Bool = false
    ) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.revision = revision
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isDynamic = isDynamic
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, trackCount, revision, createdAt, expiresAt, isDynamic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        trackCount = try container.decode(Int.self, forKey: .trackCount)
        revision = try container.decode(String.self, forKey: .revision)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        isDynamic = try container.decodeIfPresent(Bool.self, forKey: .isDynamic) ?? false
    }
}

public struct AutomationSelectionListResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let currentRevision: String
    public let selections: [AutomationSelectionSummary]

    public init(libraryID: UUID, currentRevision: String, selections: [AutomationSelectionSummary]) {
        self.libraryID = libraryID
        self.currentRevision = currentRevision
        self.selections = selections.sorted { $0.createdAt > $1.createdAt }
    }
}

public struct AutomationSelectionDetailResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let selection: AutomationSelectionSummary
    public let trackIDs: [UUID]
    public let filter: AutomationJSONValue?

    public init(
        libraryID: UUID,
        selection: AutomationSelectionSummary,
        trackIDs: [UUID],
        filter: AutomationJSONValue? = nil
    ) {
        self.libraryID = libraryID
        self.selection = selection
        self.trackIDs = trackIDs
        self.filter = filter
    }
}

public struct AutomationSelectionCreateResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let selection: AutomationSelectionSummary
    public let trackIDs: [UUID]
    public let applied: Bool
    public let dryRun: Bool

    public init(
        libraryID: UUID,
        selection: AutomationSelectionSummary,
        trackIDs: [UUID],
        applied: Bool,
        dryRun: Bool
    ) {
        self.libraryID = libraryID
        self.selection = selection
        self.trackIDs = trackIDs
        self.applied = applied
        self.dryRun = dryRun
    }
}

public struct AutomationSelectionDeleteResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let selectionID: UUID
    public let deleted: Bool
    public let dryRun: Bool

    public init(libraryID: UUID, selectionID: UUID, deleted: Bool, dryRun: Bool) {
        self.libraryID = libraryID
        self.selectionID = selectionID
        self.deleted = deleted
        self.dryRun = dryRun
    }
}

public struct AutomationPlaylistSelectionMutationResult: Codable, Equatable, Sendable {
    public let selectionID: UUID
    public let selectionRevision: String
    public let mutation: AutomationPlaylistMutationResult

    public init(selectionID: UUID, selectionRevision: String, mutation: AutomationPlaylistMutationResult) {
        self.selectionID = selectionID
        self.selectionRevision = selectionRevision
        self.mutation = mutation
    }
}

public struct AutomationPlaylistDiffResult: Codable, Equatable, Sendable {
    public let operation: String
    public let inputPlaylistIDs: [UUID]
    public let trackIDs: [UUID]
    public let total: Int
    public let revision: String

    public init(operation: String, inputPlaylistIDs: [UUID], trackIDs: [UUID], total: Int, revision: String) {
        self.operation = operation
        self.inputPlaylistIDs = inputPlaylistIDs
        self.trackIDs = trackIDs
        self.total = total
        self.revision = revision
    }
}

public struct AutomationPlaylistExportResult: Codable, Equatable, Sendable {
    public let playlist: AutomationPlaylistSummary
    public let format: String
    public let m3uText: String
    public let exportedTrackCount: Int
    public let filePathEntryCount: Int

    public init(playlist: AutomationPlaylistSummary, m3uText: String, exportedTrackCount: Int, filePathEntryCount: Int) {
        self.playlist = playlist
        self.format = "m3u8"
        self.m3uText = m3uText
        self.exportedTrackCount = exportedTrackCount
        self.filePathEntryCount = filePathEntryCount
    }
}

public struct AutomationPlaylistImportResult: Codable, Equatable, Sendable {
    public let playlist: AutomationPlaylistSummary
    public let operation: String
    public let applied: Bool
    public let dryRun: Bool
    public let matchedTrackIDs: [UUID]
    public let unmatchedEntries: [String]

    public init(playlist: AutomationPlaylistSummary, operation: String, applied: Bool, dryRun: Bool, matchedTrackIDs: [UUID], unmatchedEntries: [String]) {
        self.playlist = playlist
        self.operation = operation
        self.applied = applied
        self.dryRun = dryRun
        self.matchedTrackIDs = matchedTrackIDs
        self.unmatchedEntries = unmatchedEntries
    }
}

public struct AutomationHistoryDimensionSummary: Codable, Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public let playCount: Int
    public let playedSeconds: Double
    public var id: String { key }

    public init(key: String, name: String, playCount: Int, playedSeconds: Double) {
        self.key = key
        self.name = name
        self.playCount = playCount
        self.playedSeconds = playedSeconds
    }
}

public struct AutomationHistoryStatsResult: Codable, Equatable, Sendable {
    public let from: Date?
    public let to: Date?
    public let playCount: Int
    public let distinctTrackCount: Int
    public let distinctArtistCount: Int
    public let distinctAlbumCount: Int
    public let playedSeconds: Double
    public let topTracks: [AutomationHistoryDimensionSummary]
    public let topArtists: [AutomationHistoryDimensionSummary]
    public let topAlbums: [AutomationHistoryDimensionSummary]
    public let revision: String

    public init(from: Date?, to: Date?, playCount: Int, distinctTrackCount: Int,
                distinctArtistCount: Int, distinctAlbumCount: Int, playedSeconds: Double,
                topTracks: [AutomationHistoryDimensionSummary], topArtists: [AutomationHistoryDimensionSummary],
                topAlbums: [AutomationHistoryDimensionSummary], revision: String) {
        self.from = from
        self.to = to
        self.playCount = playCount
        self.distinctTrackCount = distinctTrackCount
        self.distinctArtistCount = distinctArtistCount
        self.distinctAlbumCount = distinctAlbumCount
        self.playedSeconds = playedSeconds
        self.topTracks = topTracks
        self.topArtists = topArtists
        self.topAlbums = topAlbums
        self.revision = revision
    }
}

public struct AutomationQueueUpcomingResult: Codable, Equatable, Sendable {
    public let currentTrackID: UUID?
    public let trackIDs: [UUID]
    public let offset: Int
    public let total: Int
    public let revision: String

    public init(currentTrackID: UUID?, trackIDs: [UUID], offset: Int, total: Int, revision: String) {
        self.currentTrackID = currentTrackID
        self.trackIDs = trackIDs
        self.offset = offset
        self.total = total
        self.revision = revision
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
    public let artworkAvailable: Bool
    public let artworkSource: String
    public let artworkFileName: String?
    public let artworkRevision: String?
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
        revision: String,
        artworkAvailable: Bool = false,
        artworkSource: String = "none",
        artworkFileName: String? = nil,
        artworkRevision: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.trackCount = trackCount
        self.totalDuration = totalDuration
        self.revision = revision
        self.artworkAvailable = artworkAvailable
        self.artworkSource = artworkSource
        self.artworkFileName = artworkFileName
        self.artworkRevision = artworkRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, createdAt, trackCount, totalDuration
        case artworkAvailable, artworkSource, artworkFileName, artworkRevision, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0),
            trackCount: try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0,
            totalDuration: try container.decodeIfPresent(Double.self, forKey: .totalDuration) ?? 0,
            revision: try container.decodeIfPresent(String.self, forKey: .revision) ?? "v1-unknown",
            artworkAvailable: try container.decodeIfPresent(Bool.self, forKey: .artworkAvailable) ?? false,
            artworkSource: try container.decodeIfPresent(String.self, forKey: .artworkSource) ?? "none",
            artworkFileName: try container.decodeIfPresent(String.self, forKey: .artworkFileName),
            artworkRevision: try container.decodeIfPresent(String.self, forKey: .artworkRevision)
        )
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

public struct AutomationSourceGetResult: Codable, Equatable, Sendable {
    public let source: AutomationSourceSummary

    public init(source: AutomationSourceSummary) {
        self.source = source
    }
}

/// Portable Source policy only. Security-scoped bookmarks, filesystem paths,
/// scan state and Playlist binding edges intentionally remain local.
public struct AutomationSourceConfiguration: Codable, Equatable, Sendable, Identifiable {
    public let sourceID: UUID
    public let displayName: String
    public let monitorPolicy: String
    public let excludedRelativePaths: [String]

    public var id: UUID { sourceID }

    public init(
        sourceID: UUID,
        displayName: String,
        monitorPolicy: String,
        excludedRelativePaths: [String]
    ) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.monitorPolicy = monitorPolicy
        self.excludedRelativePaths = Array(Set(excludedRelativePaths)).sorted()
    }
}

public struct AutomationSourceConfigurationDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let originLibraryID: UUID
    public let sources: [AutomationSourceConfiguration]

    public init(
        schemaVersion: Int = 1,
        originLibraryID: UUID,
        sources: [AutomationSourceConfiguration]
    ) {
        self.schemaVersion = schemaVersion
        self.originLibraryID = originLibraryID
        self.sources = sources.sorted { $0.sourceID.uuidString < $1.sourceID.uuidString }
    }
}

public struct AutomationSourceConfigurationExportResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let revision: String
    public let document: AutomationSourceConfigurationDocument

    public init(
        libraryID: UUID,
        revision: String,
        document: AutomationSourceConfigurationDocument
    ) {
        self.libraryID = libraryID
        self.revision = revision
        self.document = document
    }
}

public struct AutomationSourceConfigurationFailure: Codable, Equatable, Sendable, Identifiable {
    public let sourceID: UUID
    public let message: String

    public var id: UUID { sourceID }

    public init(sourceID: UUID, message: String) {
        self.sourceID = sourceID
        self.message = message
    }
}

public struct AutomationSourceConfigurationImportResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let applied: Bool
    public let dryRun: Bool
    public let revision: String
    public let configurations: [AutomationSourceConfiguration]
    public let updatedSourceIDs: [UUID]
    public let unchangedSourceIDs: [UUID]
    public let failures: [AutomationSourceConfigurationFailure]

    public init(
        libraryID: UUID,
        applied: Bool,
        dryRun: Bool,
        revision: String,
        configurations: [AutomationSourceConfiguration],
        updatedSourceIDs: [UUID] = [],
        unchangedSourceIDs: [UUID] = [],
        failures: [AutomationSourceConfigurationFailure] = []
    ) {
        self.libraryID = libraryID
        self.applied = applied
        self.dryRun = dryRun
        self.revision = revision
        self.configurations = configurations.sorted { $0.sourceID.uuidString < $1.sourceID.uuidString }
        self.updatedSourceIDs = updatedSourceIDs.sorted { $0.uuidString < $1.uuidString }
        self.unchangedSourceIDs = unchangedSourceIDs.sorted { $0.uuidString < $1.uuidString }
        self.failures = failures.sorted { $0.sourceID.uuidString < $1.sourceID.uuidString }
    }
}

public struct AutomationSourceRenameResult: Codable, Equatable, Sendable {
    public let source: AutomationSourceSummary
    public let applied: Bool
    public let dryRun: Bool

    public init(source: AutomationSourceSummary, applied: Bool, dryRun: Bool) {
        self.source = source
        self.applied = applied
        self.dryRun = dryRun
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
    public let total: Int?
    public let offset: Int?
    public let limit: Int?
    public let nextOffset: Int?

    public init(
        items: [AutomationHistoryItem],
        revision: String,
        total: Int? = nil,
        offset: Int? = nil,
        limit: Int? = nil,
        nextOffset: Int? = nil
    ) {
        self.items = items
        self.revision = revision
        self.total = total
        self.offset = offset
        self.limit = limit
        self.nextOffset = nextOffset
    }
}

public struct AutomationMetadataMutationResult: Codable, Equatable, Sendable {
    public let applied: Bool
    public let dryRun: Bool
    public let updatedTrackIDs: [UUID]
    public let skippedTrackIDs: [UUID]
    public let conflictedTrackIDs: [UUID]
    public let updatedArtistIDs: [UUID]
    public let skippedArtistIDs: [UUID]
    public let conflictedArtistIDs: [UUID]
    public let updatedAlbumIDs: [UUID]
    public let skippedAlbumIDs: [UUID]
    public let conflictedAlbumIDs: [UUID]
    public let updatedPlaylistIDs: [UUID]
    public let skippedPlaylistIDs: [UUID]
    public let conflictedPlaylistIDs: [UUID]
    public let message: String

    public init(
        applied: Bool,
        dryRun: Bool,
        updatedTrackIDs: [UUID] = [],
        skippedTrackIDs: [UUID] = [],
        conflictedTrackIDs: [UUID] = [],
        updatedArtistIDs: [UUID] = [],
        skippedArtistIDs: [UUID] = [],
        conflictedArtistIDs: [UUID] = [],
        updatedAlbumIDs: [UUID] = [],
        skippedAlbumIDs: [UUID] = [],
        conflictedAlbumIDs: [UUID] = [],
        updatedPlaylistIDs: [UUID] = [],
        skippedPlaylistIDs: [UUID] = [],
        conflictedPlaylistIDs: [UUID] = [],
        message: String
    ) {
        self.applied = applied
        self.dryRun = dryRun
        self.updatedTrackIDs = updatedTrackIDs
        self.skippedTrackIDs = skippedTrackIDs
        self.conflictedTrackIDs = conflictedTrackIDs
        self.updatedArtistIDs = updatedArtistIDs
        self.skippedArtistIDs = skippedArtistIDs
        self.conflictedArtistIDs = conflictedArtistIDs
        self.updatedAlbumIDs = updatedAlbumIDs
        self.skippedAlbumIDs = skippedAlbumIDs
        self.conflictedAlbumIDs = conflictedAlbumIDs
        self.updatedPlaylistIDs = updatedPlaylistIDs
        self.skippedPlaylistIDs = skippedPlaylistIDs
        self.conflictedPlaylistIDs = conflictedPlaylistIDs
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case applied, dryRun
        case updatedTrackIDs, skippedTrackIDs, conflictedTrackIDs
        case updatedArtistIDs, skippedArtistIDs, conflictedArtistIDs
        case updatedAlbumIDs, skippedAlbumIDs, conflictedAlbumIDs
        case updatedPlaylistIDs, skippedPlaylistIDs, conflictedPlaylistIDs
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            applied: try container.decode(Bool.self, forKey: .applied),
            dryRun: try container.decode(Bool.self, forKey: .dryRun),
            updatedTrackIDs: try container.decodeIfPresent([UUID].self, forKey: .updatedTrackIDs) ?? [],
            skippedTrackIDs: try container.decodeIfPresent([UUID].self, forKey: .skippedTrackIDs) ?? [],
            conflictedTrackIDs: try container.decodeIfPresent([UUID].self, forKey: .conflictedTrackIDs) ?? [],
            updatedArtistIDs: try container.decodeIfPresent([UUID].self, forKey: .updatedArtistIDs) ?? [],
            skippedArtistIDs: try container.decodeIfPresent([UUID].self, forKey: .skippedArtistIDs) ?? [],
            conflictedArtistIDs: try container.decodeIfPresent([UUID].self, forKey: .conflictedArtistIDs) ?? [],
            updatedAlbumIDs: try container.decodeIfPresent([UUID].self, forKey: .updatedAlbumIDs) ?? [],
            skippedAlbumIDs: try container.decodeIfPresent([UUID].self, forKey: .skippedAlbumIDs) ?? [],
            conflictedAlbumIDs: try container.decodeIfPresent([UUID].self, forKey: .conflictedAlbumIDs) ?? [],
            updatedPlaylistIDs: try container.decodeIfPresent([UUID].self, forKey: .updatedPlaylistIDs) ?? [],
            skippedPlaylistIDs: try container.decodeIfPresent([UUID].self, forKey: .skippedPlaylistIDs) ?? [],
            conflictedPlaylistIDs: try container.decodeIfPresent([UUID].self, forKey: .conflictedPlaylistIDs) ?? [],
            message: try container.decode(String.self, forKey: .message)
        )
    }
}

public struct AutomationArtistMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let canonicalName: String
    public let displayName: String
    public let createdAt: Date
    public let updatedAt: Date
    public let description: String
    public let genreTags: [String]
    public let region: String
    public let foreignName: String
    public let qqMusicSingerMid: String?
    public let metadataSource: String?
    public let metadataFetchedAt: Date?
    public let metadataConfidence: Double?
    public let artworkAvailable: Bool
    public let artworkFileName: String?
    public let trackCount: Int
    public let albumCount: Int
    public let totalDuration: Double
    public let isOrphaned: Bool
    public let revision: String

    public init(
        id: UUID,
        canonicalName: String,
        displayName: String,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        description: String,
        genreTags: [String],
        region: String,
        foreignName: String,
        qqMusicSingerMid: String?,
        metadataSource: String?,
        metadataFetchedAt: Date?,
        metadataConfidence: Double?,
        artworkAvailable: Bool,
        artworkFileName: String?,
        trackCount: Int,
        albumCount: Int,
        totalDuration: Double,
        isOrphaned: Bool,
        revision: String
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.description = description
        self.genreTags = genreTags
        self.region = region
        self.foreignName = foreignName
        self.qqMusicSingerMid = qqMusicSingerMid
        self.metadataSource = metadataSource
        self.metadataFetchedAt = metadataFetchedAt
        self.metadataConfidence = metadataConfidence
        self.artworkAvailable = artworkAvailable
        self.artworkFileName = artworkFileName
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.totalDuration = totalDuration
        self.isOrphaned = isOrphaned
        self.revision = revision
    }
}

public struct AutomationAlbumMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let canonicalKey: String
    public let displayTitle: String
    public let createdAt: Date
    public let updatedAt: Date
    public let primaryArtistCanonicalName: String
    public let primaryArtistDisplayName: String
    public let description: String
    public let year: Int?
    public let releaseYear: Int?
    public let releaseDate: Date?
    public let albumType: String
    public let genreTags: [String]
    public let language: String
    public let labelOrCompany: String
    public let qqMusicAlbumMid: String?
    public let metadataSource: String?
    public let metadataFetchedAt: Date?
    public let metadataConfidence: Double?
    public let artworkAvailable: Bool
    public let artworkFileName: String?
    public let trackCount: Int
    public let totalDuration: Double
    public let isOrphaned: Bool
    public let revision: String

    public init(
        id: UUID,
        canonicalKey: String,
        displayTitle: String,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        primaryArtistCanonicalName: String,
        primaryArtistDisplayName: String,
        description: String,
        year: Int?,
        releaseYear: Int?,
        releaseDate: Date?,
        albumType: String,
        genreTags: [String],
        language: String,
        labelOrCompany: String,
        qqMusicAlbumMid: String?,
        metadataSource: String?,
        metadataFetchedAt: Date?,
        metadataConfidence: Double?,
        artworkAvailable: Bool,
        artworkFileName: String?,
        trackCount: Int,
        totalDuration: Double,
        isOrphaned: Bool,
        revision: String
    ) {
        self.id = id
        self.canonicalKey = canonicalKey
        self.displayTitle = displayTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.primaryArtistCanonicalName = primaryArtistCanonicalName
        self.primaryArtistDisplayName = primaryArtistDisplayName
        self.description = description
        self.year = year
        self.releaseYear = releaseYear
        self.releaseDate = releaseDate
        self.albumType = albumType
        self.genreTags = genreTags
        self.language = language
        self.labelOrCompany = labelOrCompany
        self.qqMusicAlbumMid = qqMusicAlbumMid
        self.metadataSource = metadataSource
        self.metadataFetchedAt = metadataFetchedAt
        self.metadataConfidence = metadataConfidence
        self.artworkAvailable = artworkAvailable
        self.artworkFileName = artworkFileName
        self.trackCount = trackCount
        self.totalDuration = totalDuration
        self.isOrphaned = isOrphaned
        self.revision = revision
    }
}

public struct AutomationMetadataGetResult: Codable, Equatable, Sendable {
    public let tracks: [AutomationTrackSummary]
    public let artists: [AutomationArtistMetadata]
    public let albums: [AutomationAlbumMetadata]
    public let playlists: [AutomationPlaylistSummary]
    public let total: Int
    public let offset: Int
    public let limit: Int
    public let nextOffset: Int?
    public let revision: String

    public init(
        tracks: [AutomationTrackSummary] = [],
        artists: [AutomationArtistMetadata] = [],
        albums: [AutomationAlbumMetadata] = [],
        playlists: [AutomationPlaylistSummary] = [],
        total: Int,
        offset: Int = 0,
        limit: Int = 1,
        nextOffset: Int? = nil,
        revision: String
    ) {
        self.tracks = tracks
        self.artists = artists
        self.albums = albums
        self.playlists = playlists
        self.total = total
        self.offset = offset
        self.limit = limit
        self.nextOffset = nextOffset
        self.revision = revision
    }
}

public struct AutomationEmbeddedTagTrack: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let fileName: String
    public let format: String
    public let supportedForWrite: Bool
    public let trackRevision: String
    public let values: [String: String]
    public let status: String
    public let message: String?

    public init(
        id: UUID,
        fileName: String,
        format: String,
        supportedForWrite: Bool,
        trackRevision: String,
        values: [String: String] = [:],
        status: String,
        message: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.format = format
        self.supportedForWrite = supportedForWrite
        self.trackRevision = trackRevision
        self.values = values
        self.status = status
        self.message = message
    }
}

public struct AutomationEmbeddedTagsResult: Codable, Equatable, Sendable {
    public let dryRun: Bool
    public let applied: Bool
    public let libraryRevision: String
    public let tracks: [AutomationEmbeddedTagTrack]
    public let job: AutomationJobSummary?
    public let message: String

    public init(
        dryRun: Bool,
        applied: Bool,
        libraryRevision: String,
        tracks: [AutomationEmbeddedTagTrack],
        job: AutomationJobSummary? = nil,
        message: String
    ) {
        self.dryRun = dryRun
        self.applied = applied
        self.libraryRevision = libraryRevision
        self.tracks = tracks
        self.job = job
        self.message = message
    }
}

public struct AutomationMetadataCandidate: Codable, Equatable, Sendable, Identifiable {
    public let candidateID: String?
    public let provider: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let durationSeconds: Int?
    public let confidence: Double?
    /// Provider-neutral field match score in the range 0...1.
    public let matchQuality: Double?
    public let imageURL: String?

    public var id: String { candidateID ?? "\(provider):unselectable" }

    public init(
        candidateID: String?,
        provider: String,
        title: String?,
        artist: String?,
        album: String?,
        durationSeconds: Int?,
        confidence: Double?,
        matchQuality: Double? = nil,
        imageURL: String?
    ) {
        self.candidateID = candidateID
        self.provider = provider
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.confidence = confidence
        self.matchQuality = matchQuality
        self.imageURL = imageURL
    }
}

/// Provider-neutral scoring for metadata candidates. Provider confidence is
/// retained separately because providers use different scales and meanings.
public enum AutomationMetadataQualityEvaluator {
    public static func score(
        queryTitle: String,
        queryArtist: String,
        queryAlbum: String,
        queryDurationSeconds: Double?,
        candidateTitle: String?,
        candidateArtist: String?,
        candidateAlbum: String?,
        candidateDurationSeconds: Double?
    ) -> Double? {
        var weightedScore = 0.0
        var totalWeight = 0.0
        add(queryTitle, candidateTitle, weight: 0.45)
        add(queryArtist, candidateArtist, weight: 0.30)
        add(queryAlbum, candidateAlbum, weight: 0.15)
        if let queryDurationSeconds, let candidateDurationSeconds,
           queryDurationSeconds.isFinite, candidateDurationSeconds.isFinite,
           queryDurationSeconds > 0, candidateDurationSeconds > 0 {
            let delta = abs(queryDurationSeconds - candidateDurationSeconds)
            let durationScore: Double
            switch delta {
            case ...2: durationScore = 1
            case ...5: durationScore = 0.85
            case ...10: durationScore = 0.60
            case ...20: durationScore = 0.25
            default: durationScore = 0
            }
            weightedScore += durationScore * 0.10
            totalWeight += 0.10
        }
        guard totalWeight > 0 else { return nil }
        return min(1, max(0, (weightedScore / totalWeight * 1_000).rounded() / 1_000))

        func add(_ query: String, _ candidate: String?, weight: Double) {
            let normalizedQuery = normalize(query)
            guard !normalizedQuery.isEmpty,
                  let candidate,
                  !normalize(candidate).isEmpty else { return }
            weightedScore += similarity(normalizedQuery, normalize(candidate)) * weight
            totalWeight += weight
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard lhs != rhs else { return 1 }
        let left = Array(lhs.prefix(160))
        let right = Array(rhs.prefix(160))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitutionCost = leftCharacter == rightCharacter ? 0 : 1
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    min(current[rightIndex] + 1, previous[rightIndex] + substitutionCost)
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(max(left.count, right.count))
    }
}

/// Provider-neutral artwork ranking. Metadata similarity, usable image size,
/// and square-crop suitability are combined without treating provider
/// confidence values as globally comparable.
public enum AutomationArtworkQualityEvaluator {
    public static func score(
        queryTitle: String?,
        queryArtist: String?,
        queryAlbum: String?,
        candidateTitle: String?,
        candidateArtist: String?,
        candidateAlbum: String?,
        width: Int,
        height: Int
    ) -> Double {
        let metadataScore = AutomationMetadataQualityEvaluator.score(
            queryTitle: queryTitle ?? "",
            queryArtist: queryArtist ?? "",
            queryAlbum: queryAlbum ?? "",
            queryDurationSeconds: nil,
            candidateTitle: candidateTitle,
            candidateArtist: candidateArtist,
            candidateAlbum: candidateAlbum,
            candidateDurationSeconds: nil
        )
        let largestDimension = max(width, height)
        let resolutionScore = min(Double(max(largestDimension, 0)), 2_000) / 2_000
        let shapeScore: Double
        if width > 0, height > 0 {
            shapeScore = 1 - min(Double(abs(width - height)) / Double(max(width, height)), 1)
        } else {
            shapeScore = 0
        }
        let score: Double
        if let metadataScore {
            score = metadataScore * 0.70 + resolutionScore * 0.20 + shapeScore * 0.10
        } else {
            score = resolutionScore * 0.70 + shapeScore * 0.30
        }
        return min(1, max(0, (score * 1_000).rounded() / 1_000))
    }
}

public struct AutomationMetadataSearchResult: Codable, Equatable, Sendable {
    public let trackID: UUID
    public let queryTitle: String
    public let queryArtist: String
    public let queryAlbum: String
    public let candidates: [AutomationMetadataCandidate]
    public let revision: String
    public let message: String
    /// Search failures are reported per provider so one unavailable catalog
    /// does not hide successful candidates from another provider.
    public let providerWarnings: [String: String]?

    public init(
        trackID: UUID,
        queryTitle: String,
        queryArtist: String,
        queryAlbum: String,
        candidates: [AutomationMetadataCandidate],
        revision: String,
        message: String,
        providerWarnings: [String: String]? = nil
    ) {
        self.trackID = trackID
        self.queryTitle = queryTitle
        self.queryArtist = queryArtist
        self.queryAlbum = queryAlbum
        self.candidates = candidates
        self.revision = revision
        self.message = message
        self.providerWarnings = providerWarnings
    }
}

public struct AutomationMetadataCandidateApplyResult: Codable, Equatable, Sendable {
    public let trackID: UUID
    public let candidateID: String
    public let dryRun: Bool
    public let overwriteExistingFields: Bool
    public let previewPatch: [String: AutomationJSONValue]
    public let mutation: AutomationMetadataMutationResult

    public init(
        trackID: UUID,
        candidateID: String,
        dryRun: Bool,
        overwriteExistingFields: Bool,
        previewPatch: [String: AutomationJSONValue],
        mutation: AutomationMetadataMutationResult
    ) {
        self.trackID = trackID
        self.candidateID = candidateID
        self.dryRun = dryRun
        self.overwriteExistingFields = overwriteExistingFields
        self.previewPatch = previewPatch
        self.mutation = mutation
    }
}

public struct AutomationMetadataDocumentTrack: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let revision: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Double
    public let fields: [String: AutomationJSONValue]

    public init(
        id: UUID,
        revision: String,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        fields: [String: AutomationJSONValue]
    ) {
        self.id = id
        self.revision = revision
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.fields = fields
    }
}

/// Portable Track metadata exchange. Paths, audio bytes, artwork, lyrics,
/// Source bookmarks and runtime state are deliberately outside this document.
public struct AutomationMetadataDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceLibraryID: UUID
    public let exportedAt: Date
    public let revision: String
    public let offset: Int
    public let limit: Int
    public let total: Int
    public let nextOffset: Int?
    public let tracks: [AutomationMetadataDocumentTrack]

    public init(
        schemaVersion: Int = 1,
        sourceLibraryID: UUID,
        exportedAt: Date = Date(),
        revision: String,
        offset: Int,
        limit: Int,
        total: Int,
        nextOffset: Int?,
        tracks: [AutomationMetadataDocumentTrack]
    ) {
        self.schemaVersion = schemaVersion
        self.sourceLibraryID = sourceLibraryID
        self.exportedAt = exportedAt
        self.revision = revision
        self.offset = offset
        self.limit = limit
        self.total = total
        self.nextOffset = nextOffset
        self.tracks = tracks
    }
}

public struct AutomationMetadataImportItem: Codable, Equatable, Sendable, Identifiable {
    public let sourceTrackID: UUID
    public let targetTrackID: UUID?
    public let status: String
    public let fields: [String]
    public let message: String

    public var id: UUID { sourceTrackID }

    public init(
        sourceTrackID: UUID,
        targetTrackID: UUID?,
        status: String,
        fields: [String],
        message: String
    ) {
        self.sourceTrackID = sourceTrackID
        self.targetTrackID = targetTrackID
        self.status = status
        self.fields = fields.sorted()
        self.message = message
    }
}

public struct AutomationMetadataImportResult: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let sourceLibraryID: UUID
    public let dryRun: Bool
    public let applied: Bool
    public let items: [AutomationMetadataImportItem]
    public let revision: String
    public let message: String

    public init(
        libraryID: UUID,
        sourceLibraryID: UUID,
        dryRun: Bool,
        applied: Bool,
        items: [AutomationMetadataImportItem],
        revision: String,
        message: String
    ) {
        self.libraryID = libraryID
        self.sourceLibraryID = sourceLibraryID
        self.dryRun = dryRun
        self.applied = applied
        self.items = items
        self.revision = revision
        self.message = message
    }
}

public struct AutomationArtworkInfo: Codable, Equatable, Sendable, Identifiable {
    public let targetType: String?
    public let trackID: UUID?
    public let artistID: UUID?
    public let albumKey: String?
    public let playlistID: UUID?
    public let available: Bool
    public let fileName: String?
    public let byteCount: Int?
    public let sha256: String?
    public let revision: String?

    public var id: String {
        if let trackID { return "track:\(trackID.uuidString)" }
        if let artistID { return "artist:\(artistID.uuidString)" }
        if let albumKey { return "album:\(albumKey)" }
        if let playlistID { return "playlist:\(playlistID.uuidString)" }
        return "unknown"
    }

    public init(
        targetType: String? = "track",
        trackID: UUID? = nil,
        artistID: UUID? = nil,
        albumKey: String? = nil,
        playlistID: UUID? = nil,
        available: Bool,
        fileName: String? = nil,
        byteCount: Int? = nil,
        sha256: String? = nil,
        revision: String? = nil
    ) {
        self.targetType = targetType
        self.trackID = trackID
        self.artistID = artistID
        self.albumKey = albumKey
        self.playlistID = playlistID
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
        self.artworks = artworks.sorted { $0.id < $1.id }
        self.revision = revision
    }
}

public struct AutomationArtworkCandidate: Codable, Equatable, Sendable, Identifiable {
    public let candidateID: String?
    public let source: String
    public let sourceItemID: String?
    public let imageBase64: String
    public let imageMIMEType: String?
    /// Byte count of the inline image represented by imageBase64.
    public let byteCount: Int
    /// Original provider byte count when the App normalized the inline image
    /// to keep the local IPC frame bounded.
    public let originalByteCount: Int?
    public let width: Int
    public let height: Int
    public let resolution: Int
    public let confidence: Double
    /// Cross-provider match and image suitability score in the range 0...1.
    /// `confidence` remains the source provider's original value.
    public let matchQuality: Double?
    public let matchedTitle: String?
    public let matchedArtist: String?
    public let matchedAlbum: String?
    public let imageURL: String?

    public var id: String {
        candidateID ?? "\(source):\(sourceItemID ?? "unknown")"
    }

    public init(
        candidateID: String? = nil,
        source: String,
        sourceItemID: String? = nil,
        imageBase64: String,
        imageMIMEType: String? = nil,
        byteCount: Int,
        originalByteCount: Int? = nil,
        width: Int,
        height: Int,
        resolution: Int,
        confidence: Double,
        matchQuality: Double? = nil,
        matchedTitle: String? = nil,
        matchedArtist: String? = nil,
        matchedAlbum: String? = nil,
        imageURL: String? = nil
    ) {
        self.candidateID = candidateID
        self.source = source
        self.sourceItemID = sourceItemID
        self.imageBase64 = imageBase64
        self.imageMIMEType = imageMIMEType
        self.byteCount = byteCount
        self.originalByteCount = originalByteCount
        self.width = width
        self.height = height
        self.resolution = resolution
        self.confidence = confidence
        self.matchQuality = matchQuality
        self.matchedTitle = matchedTitle
        self.matchedArtist = matchedArtist
        self.matchedAlbum = matchedAlbum
        self.imageURL = imageURL
    }
}

public struct AutomationArtworkSearchResult: Codable, Equatable, Sendable {
    public let targetType: String?
    public let trackID: UUID?
    public let artistID: UUID?
    public let albumKey: String?
    public let playlistID: UUID?
    public let queryTitle: String?
    public let queryArtist: String?
    public let queryAlbum: String?
    public let candidates: [AutomationArtworkCandidate]
    public let message: String

    public init(
        targetType: String? = "track",
        trackID: UUID? = nil,
        artistID: UUID? = nil,
        albumKey: String? = nil,
        playlistID: UUID? = nil,
        queryTitle: String? = nil,
        queryArtist: String? = nil,
        queryAlbum: String? = nil,
        candidates: [AutomationArtworkCandidate],
        message: String
    ) {
        self.targetType = targetType
        self.trackID = trackID
        self.artistID = artistID
        self.albumKey = albumKey
        self.playlistID = playlistID
        self.queryTitle = queryTitle
        self.queryArtist = queryArtist
        self.queryAlbum = queryAlbum
        self.candidates = candidates
        self.message = message
    }
}

public struct AutomationArtworkMutationResult: Codable, Equatable, Sendable {
    public let targetType: String?
    public let trackID: UUID?
    public let artistID: UUID?
    public let albumKey: String?
    public let playlistID: UUID?
    public let applied: Bool
    public let dryRun: Bool
    public let confirmed: Bool
    public let input: String
    public let updatedTrackIDs: [UUID]
    public let skippedTrackIDs: [UUID]
    public let conflictedTrackIDs: [UUID]
    public let updatedArtistIDs: [UUID]
    public let skippedArtistIDs: [UUID]
    public let conflictedArtistIDs: [UUID]
    public let updatedAlbumIDs: [UUID]
    public let skippedAlbumIDs: [UUID]
    public let conflictedAlbumIDs: [UUID]
    public let updatedPlaylistIDs: [UUID]
    public let skippedPlaylistIDs: [UUID]
    public let conflictedPlaylistIDs: [UUID]
    public let message: String

    public init(
        targetType: String? = nil,
        trackID: UUID? = nil,
        artistID: UUID? = nil,
        albumKey: String? = nil,
        playlistID: UUID? = nil,
        applied: Bool,
        dryRun: Bool,
        confirmed: Bool = false,
        input: String,
        updatedTrackIDs: [UUID] = [],
        skippedTrackIDs: [UUID] = [],
        conflictedTrackIDs: [UUID] = [],
        updatedArtistIDs: [UUID] = [],
        skippedArtistIDs: [UUID] = [],
        conflictedArtistIDs: [UUID] = [],
        updatedAlbumIDs: [UUID] = [],
        skippedAlbumIDs: [UUID] = [],
        conflictedAlbumIDs: [UUID] = [],
        updatedPlaylistIDs: [UUID] = [],
        skippedPlaylistIDs: [UUID] = [],
        conflictedPlaylistIDs: [UUID] = [],
        message: String
    ) {
        self.targetType = targetType
        self.trackID = trackID
        self.artistID = artistID
        self.albumKey = albumKey
        self.playlistID = playlistID
        self.applied = applied
        self.dryRun = dryRun
        self.confirmed = confirmed
        self.input = input
        self.updatedTrackIDs = updatedTrackIDs
        self.skippedTrackIDs = skippedTrackIDs
        self.conflictedTrackIDs = conflictedTrackIDs
        self.updatedArtistIDs = updatedArtistIDs
        self.skippedArtistIDs = skippedArtistIDs
        self.conflictedArtistIDs = conflictedArtistIDs
        self.updatedAlbumIDs = updatedAlbumIDs
        self.skippedAlbumIDs = skippedAlbumIDs
        self.conflictedAlbumIDs = conflictedAlbumIDs
        self.updatedPlaylistIDs = updatedPlaylistIDs
        self.skippedPlaylistIDs = skippedPlaylistIDs
        self.conflictedPlaylistIDs = conflictedPlaylistIDs
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case targetType, trackID, artistID, albumKey, playlistID
        case applied, dryRun, confirmed, input
        case updatedTrackIDs, skippedTrackIDs, conflictedTrackIDs
        case updatedArtistIDs, skippedArtistIDs, conflictedArtistIDs
        case updatedAlbumIDs, skippedAlbumIDs, conflictedAlbumIDs
        case updatedPlaylistIDs, skippedPlaylistIDs, conflictedPlaylistIDs
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            targetType: try container.decodeIfPresent(String.self, forKey: .targetType),
            trackID: try container.decodeIfPresent(UUID.self, forKey: .trackID),
            artistID: try container.decodeIfPresent(UUID.self, forKey: .artistID),
            albumKey: try container.decodeIfPresent(String.self, forKey: .albumKey),
            playlistID: try container.decodeIfPresent(UUID.self, forKey: .playlistID),
            applied: try container.decode(Bool.self, forKey: .applied),
            dryRun: try container.decode(Bool.self, forKey: .dryRun),
            confirmed: try container.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false,
            input: try container.decode(String.self, forKey: .input),
            updatedTrackIDs: try container.decodeIfPresent([UUID].self, forKey: .updatedTrackIDs) ?? [],
            skippedTrackIDs: try container.decodeIfPresent([UUID].self, forKey: .skippedTrackIDs) ?? [],
            conflictedTrackIDs: try container.decodeIfPresent([UUID].self, forKey: .conflictedTrackIDs) ?? [],
            updatedArtistIDs: try container.decodeIfPresent([UUID].self, forKey: .updatedArtistIDs) ?? [],
            skippedArtistIDs: try container.decodeIfPresent([UUID].self, forKey: .skippedArtistIDs) ?? [],
            conflictedArtistIDs: try container.decodeIfPresent([UUID].self, forKey: .conflictedArtistIDs) ?? [],
            updatedAlbumIDs: try container.decodeIfPresent([UUID].self, forKey: .updatedAlbumIDs) ?? [],
            skippedAlbumIDs: try container.decodeIfPresent([UUID].self, forKey: .skippedAlbumIDs) ?? [],
            conflictedAlbumIDs: try container.decodeIfPresent([UUID].self, forKey: .conflictedAlbumIDs) ?? [],
            updatedPlaylistIDs: try container.decodeIfPresent([UUID].self, forKey: .updatedPlaylistIDs) ?? [],
            skippedPlaylistIDs: try container.decodeIfPresent([UUID].self, forKey: .skippedPlaylistIDs) ?? [],
            conflictedPlaylistIDs: try container.decodeIfPresent([UUID].self, forKey: .conflictedPlaylistIDs) ?? [],
            message: try container.decode(String.self, forKey: .message)
        )
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
    public let input: String
    public let candidate: AutomationLyricsCandidate?
    public let ttmlByteCount: Int?
    public let currentQuality: Int
    public let candidateQuality: Int
    public let message: String

    public init(
        trackID: UUID,
        applied: Bool,
        dryRun: Bool,
        force: Bool,
        input: String = "candidate",
        candidate: AutomationLyricsCandidate? = nil,
        ttmlByteCount: Int? = nil,
        currentQuality: Int,
        candidateQuality: Int,
        message: String
    ) {
        self.trackID = trackID
        self.applied = applied
        self.dryRun = dryRun
        self.force = force
        self.input = input
        self.candidate = candidate
        self.ttmlByteCount = ttmlByteCount
        self.currentQuality = currentQuality
        self.candidateQuality = candidateQuality
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case trackID
        case applied
        case dryRun
        case force
        case input
        case candidate
        case ttmlByteCount
        case currentQuality
        case candidateQuality
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decode(UUID.self, forKey: .trackID)
        applied = try container.decode(Bool.self, forKey: .applied)
        dryRun = try container.decode(Bool.self, forKey: .dryRun)
        force = try container.decode(Bool.self, forKey: .force)
        input = try container.decodeIfPresent(String.self, forKey: .input) ?? "candidate"
        candidate = try container.decodeIfPresent(AutomationLyricsCandidate.self, forKey: .candidate)
        ttmlByteCount = try container.decodeIfPresent(Int.self, forKey: .ttmlByteCount)
        currentQuality = try container.decode(Int.self, forKey: .currentQuality)
        candidateQuality = try container.decode(Int.self, forKey: .candidateQuality)
        message = try container.decode(String.self, forKey: .message)
    }
}

public struct AutomationLyricsCleanResult: Codable, Equatable, Sendable {
    public let trackID: UUID
    public let cleaned: Bool
    public let dryRun: Bool
    public let removedLines: Int
    public let message: String
    public let preview: String?

    public init(
        trackID: UUID,
        cleaned: Bool,
        dryRun: Bool,
        removedLines: Int,
        message: String,
        preview: String? = nil
    ) {
        self.trackID = trackID
        self.cleaned = cleaned
        self.dryRun = dryRun
        self.removedLines = removedLines
        self.message = message
        self.preview = preview
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
    public let result: AutomationJSONValue?

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
        retryable: Bool = false,
        result: AutomationJSONValue? = nil
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
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, libraryID, state, createdAt, startedAt, finishedAt, checkpoint
        case completedCount, totalCount, currentPhase, failures, failedItemIDs, retryable, result
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
        result = try container.decodeIfPresent(AutomationJSONValue.self, forKey: .result)
    }
}

public struct AutomationJobWaitResult: Codable, Equatable, Sendable {
    public let job: AutomationJobSummary
    public let completed: Bool
    public let timedOut: Bool
    public let deadlineReached: Bool
    public let waitedMs: Int

    public init(
        job: AutomationJobSummary,
        completed: Bool,
        timedOut: Bool,
        deadlineReached: Bool = false,
        waitedMs: Int
    ) {
        self.job = job
        self.completed = completed
        self.timedOut = timedOut
        self.deadlineReached = deadlineReached
        self.waitedMs = max(0, waitedMs)
    }
}

public struct AutomationJobSubmissionResult: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let job: AutomationJobSummary
    public let message: String

    public init(accepted: Bool = true, job: AutomationJobSummary, message: String) {
        self.accepted = accepted
        self.job = job
        self.message = message
    }
}

public struct AutomationBatchOperation: Codable, Equatable, Sendable {
    public let method: String
    public let params: AutomationJSONValue?

    public init(method: String, params: AutomationJSONValue? = nil) {
        self.method = method
        self.params = params
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
    /// Tracks with no persisted local or downloaded lyrics.
    public let missingLyricsTrackCount: Int
    /// Tracks without App-owned artwork.
    public let missingArtworkTrackCount: Int
    /// Tracks missing one or more identity fields (title, artist, album).
    public let incompleteMetadataTrackCount: Int
    public let sourceCount: Int
    public let sourceIssues: [String]
    public let runningJobCount: Int
    public let checks: [String: String]
    public let failedJobCount: Int
    public let failedJobSummaries: [String]
    public let playlistReferenceIssues: [AutomationPlaylistReferenceIssue]
    public let storageValidation: String
    public let storageValidationMessage: String?
    public let issues: [AutomationDiagnosticIssue]
    public let issueCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let mediaIssues: [AutomationDiagnosticIssue]
    public let mediaIssueCount: Int
    public let mediaHasMore: Bool

    public init(
        healthy: Bool,
        libraryID: UUID?,
        trackCount: Int,
        playlistCount: Int,
        missingTrackCount: Int,
        unavailableTrackCount: Int,
        missingLyricsTrackCount: Int = 0,
        missingArtworkTrackCount: Int = 0,
        incompleteMetadataTrackCount: Int = 0,
        sourceCount: Int,
        sourceIssues: [String] = [],
        runningJobCount: Int = 0,
        checks: [String: String] = [:],
        failedJobCount: Int = 0,
        failedJobSummaries: [String] = [],
        playlistReferenceIssues: [AutomationPlaylistReferenceIssue] = [],
        storageValidation: String = "notRun",
        storageValidationMessage: String? = nil,
        issues: [AutomationDiagnosticIssue] = [],
        issueCount: Int? = nil,
        offset: Int = 0,
        limit: Int = 100,
        hasMore: Bool = false,
        mediaIssues: [AutomationDiagnosticIssue] = [],
        mediaIssueCount: Int? = nil,
        mediaHasMore: Bool = false
    ) {
        self.healthy = healthy
        self.libraryID = libraryID
        self.trackCount = trackCount
        self.playlistCount = playlistCount
        self.missingTrackCount = missingTrackCount
        self.unavailableTrackCount = unavailableTrackCount
        self.missingLyricsTrackCount = missingLyricsTrackCount
        self.missingArtworkTrackCount = missingArtworkTrackCount
        self.incompleteMetadataTrackCount = incompleteMetadataTrackCount
        self.sourceCount = sourceCount
        self.sourceIssues = sourceIssues.sorted()
        self.runningJobCount = runningJobCount
        self.checks = checks
        self.failedJobCount = failedJobCount
        self.failedJobSummaries = failedJobSummaries
        self.playlistReferenceIssues = playlistReferenceIssues
        self.storageValidation = storageValidation
        self.storageValidationMessage = storageValidationMessage
        self.issues = issues
        self.issueCount = issueCount ?? issues.count
        self.offset = max(0, offset)
        self.limit = max(1, limit)
        self.hasMore = hasMore
        self.mediaIssues = mediaIssues
        self.mediaIssueCount = mediaIssueCount ?? mediaIssues.count
        self.mediaHasMore = mediaHasMore
    }

    private enum CodingKeys: String, CodingKey {
        case healthy, libraryID, trackCount, playlistCount, missingTrackCount
        case unavailableTrackCount, missingLyricsTrackCount, missingArtworkTrackCount
        case incompleteMetadataTrackCount, sourceCount, sourceIssues, runningJobCount, checks
        case failedJobCount, failedJobSummaries, playlistReferenceIssues
        case storageValidation, storageValidationMessage
        case issues, issueCount, offset, limit, hasMore, mediaIssues, mediaIssueCount, mediaHasMore
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        healthy = try container.decode(Bool.self, forKey: .healthy)
        libraryID = try container.decodeIfPresent(UUID.self, forKey: .libraryID)
        trackCount = try container.decode(Int.self, forKey: .trackCount)
        playlistCount = try container.decode(Int.self, forKey: .playlistCount)
        missingTrackCount = try container.decode(Int.self, forKey: .missingTrackCount)
        unavailableTrackCount = try container.decode(Int.self, forKey: .unavailableTrackCount)
        missingLyricsTrackCount = try container.decodeIfPresent(Int.self, forKey: .missingLyricsTrackCount) ?? 0
        missingArtworkTrackCount = try container.decodeIfPresent(Int.self, forKey: .missingArtworkTrackCount) ?? 0
        incompleteMetadataTrackCount = try container.decodeIfPresent(Int.self, forKey: .incompleteMetadataTrackCount) ?? 0
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
        issues = try container.decodeIfPresent([AutomationDiagnosticIssue].self, forKey: .issues) ?? []
        issueCount = try container.decodeIfPresent(Int.self, forKey: .issueCount) ?? issues.count
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? max(1, issues.count)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        mediaIssues = try container.decodeIfPresent([AutomationDiagnosticIssue].self, forKey: .mediaIssues) ?? []
        mediaIssueCount = try container.decodeIfPresent(Int.self, forKey: .mediaIssueCount) ?? mediaIssues.count
        mediaHasMore = try container.decodeIfPresent(Bool.self, forKey: .mediaHasMore) ?? false
    }
}

public struct AutomationDiagnosticIssue: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let code: String
    public let trackID: UUID?
    public let playlistID: UUID?
    public let sourceID: UUID?
    public let path: String?
    public let reason: String

    public init(
        id: String,
        code: String,
        trackID: UUID? = nil,
        playlistID: UUID? = nil,
        sourceID: UUID? = nil,
        path: String? = nil,
        reason: String
    ) {
        self.id = id
        self.code = code
        self.trackID = trackID
        self.playlistID = playlistID
        self.sourceID = sourceID
        self.path = path
        self.reason = reason
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
    public let issues: [AutomationStorageIssue]
    public let issueCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let mediaIssues: [AutomationStorageIssue]
    public let mediaIssueCount: Int
    public let mediaHasMore: Bool
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
        issues: [AutomationStorageIssue] = [],
        issueCount: Int? = nil,
        offset: Int = 0,
        limit: Int = 100,
        hasMore: Bool = false,
        mediaIssues: [AutomationStorageIssue] = [],
        mediaIssueCount: Int? = nil,
        mediaHasMore: Bool = false,
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
        self.issues = issues
        self.issueCount = issueCount ?? issues.count
        self.offset = max(0, offset)
        self.limit = max(1, limit)
        self.hasMore = hasMore
        self.mediaIssues = mediaIssues
        self.mediaIssueCount = mediaIssueCount ?? mediaIssues.count
        self.mediaHasMore = mediaHasMore
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case libraryID, mode, rootPath, schemaVersion, manifestPresent
        case missingRequiredDirectories, validation, validationMessage, issues
        case issueCount, offset, limit, hasMore, mediaIssues, mediaIssueCount, mediaHasMore, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryID = try container.decodeIfPresent(UUID.self, forKey: .libraryID)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        manifestPresent = try container.decode(Bool.self, forKey: .manifestPresent)
        missingRequiredDirectories = try container.decodeIfPresent([String].self, forKey: .missingRequiredDirectories) ?? []
        validation = try container.decode(String.self, forKey: .validation)
        validationMessage = try container.decodeIfPresent(String.self, forKey: .validationMessage)
        issues = try container.decodeIfPresent([AutomationStorageIssue].self, forKey: .issues) ?? []
        issueCount = try container.decodeIfPresent(Int.self, forKey: .issueCount) ?? issues.count
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? max(1, issues.count)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        mediaIssues = try container.decodeIfPresent([AutomationStorageIssue].self, forKey: .mediaIssues) ?? []
        mediaIssueCount = try container.decodeIfPresent(Int.self, forKey: .mediaIssueCount) ?? mediaIssues.count
        mediaHasMore = try container.decodeIfPresent(Bool.self, forKey: .mediaHasMore) ?? false
        message = try container.decode(String.self, forKey: .message)
    }
}

public struct AutomationStorageIssue: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let code: String
    public let trackID: UUID?
    public let path: String?
    public let reason: String

    public init(id: String, code: String, trackID: UUID? = nil, path: String? = nil, reason: String) {
        self.id = id
        self.code = code
        self.trackID = trackID
        self.path = path
        self.reason = reason
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
    - Work from the installed App's formal tools and bundled guide; a source checkout is not expected. For a cross-Library move, export bounded metadata pages with metadata.export, import files with library.import(enrichmentPolicy:"migration"), use its fileTrackMappings with metadata.import(trackIDMap), then apply per-Track lyrics/artwork through operations.batch. Migration import reads embedded tags/lyrics and skips online enrichment; source.refresh reconciles existing Track identity and availability and does not replace saved metadata.
    - Existing APIs already batch metadata.patch(trackIDs, shared patch), artwork.apply(trackIDs, shared image), lyrics.refresh(trackIDs), and metadata.export/import pages (up to 100 Tracks per page). Use operations.batch when each Track needs different metadata, artwork or lyrics. It returns an App Job; use jobs.wait(timeoutMs) for a bounded wait, then jobs.get for persisted items at job.result.items[i].response.result. A wait completed:true means any terminal state, so check job.state; re-submit only failed items with a new idempotency key.
    - For slow provider searches, keep the default synchronous call for small work or pass background:true to receive an App Job; the original response envelope is in job.result and candidate data is nested at job.result.result. storage.validate and diagnostics.health return separately paginated consistency issues and mediaIssues with Track IDs, paths and reasons. Media checks only test recorded paths for existence/readability across known locations; they do not decode audio or repair files.
    - Prefer the formal Automation API, then actionable diagnostics and App-owned repair. A source checkout is not needed for normal operations. If a concrete issue cannot be resolved through formal tools, inspect only the official source details needed to understand it, remove any temporary checkout immediately, and use a controlled fallback only after backup and a focused validation/reload plan.
    - Query first, preserve the returned revision, apply with expectedRevision when offered, and verify the result. Use idempotencyKey when retrying a mutation.
    - `metadata.get`/`metadata.patch` cover App-owned Track, Artist, Album and Playlist fields. Use `metadata.embedded.get` for live file tags; `metadata.embedded.patch` currently writes MP3 ID3v2.3/v2.4 only and always requires `dryRun`, `confirm` and App foreground confirmation.
    - DSP uses App-wide dsp.schema/state/validate/patch/wait and dsp.presets tools. Fetch stable node IDs and desiredRevision first, patch atomically with expectedRevision, then wait on status.requestID; scheduled is queued audio, audible follows the output clock. Presets retain complete ordered configurations and disabled parameters. Use context.idempotencyKey for retries. Global fades and track loudness normalization are outside DSP presets.
    - Artwork is App-owned and sidecar-backed: `artwork.search/get/apply` use one target from Track, Artist, Album or Playlist where the operation supports it. `artwork.get` reports availability and a digest without returning image bytes; `artwork.apply` accepts an App picker, an image path hint, base64 image data, or an explicit clear. Batches of 10 or more require `confirm` plus foreground confirmation.
    """

    public static let capabilityOverview = """
    The shared automation layer is App-owned. CLI and MCP are adapters over the same local IPC contract. `library.tracks` is the composable query entry point. Batch mutations and long operations remain owned by existing Library services and are observable through durable Jobs. Health and storage validation return bounded, paginated consistency evidence plus separate cheap media-path presence checks; they never decode audio or repair files implicitly.
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
    public static let all: [AutomationToolDescriptor] = ([
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
            name: AutomationMethod.libraryGet,
            title: "Get Library",
            description: "Read one registered Library's display name, mode and active status without switching it or exposing its path.",
            readOnly: true,
            scopes: [.libraryRead],
            risk: .low,
            inputSchema: libraryIDInputSchema
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
            name: AutomationMethod.libraryImport,
            title: "Import Audio",
            description: "Import local audio files or folders through the same owner as manual UI import, including NCM conversion and duplicate handling. `enrichmentPolicy` defaults to `standard`; use `migration` to read embedded tags/lyrics and skip online enrichment. The App Job result includes a filePath-to-final-trackID mapping, including reused and converted files. Never write library sidecars yourself.",
            readOnly: false,
            scopes: [.libraryRead, .libraryWrite],
            risk: .low,
            supportsDryRun: true,
            supportsJobs: true,
            supportsTasks: true,
            inputSchema: libraryImportInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryTracks,
            title: "Find Tracks",
            description: "Compose ID, text, source, playlist, availability, date, technical, metadata and playback-preference filters, then page and sort tracks. Playback-preference filters and includePreferenceStats require history.read.",
            readOnly: true,
            requiresConfirmation: false,
            scopes: [.libraryRead],
            risk: .low,
            inputSchema: libraryTracksInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryStats,
            title: "Library Statistics",
            description: "Read counts and duration for Tracks, availability, playlists, Artists, Albums, lyrics, artwork and authorized Sources in the active Library.",
            readOnly: true,
            scopes: [.libraryRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryReport,
            title: "Read Library Report",
            description: "Read a versioned, paginated machine-readable snapshot of Library statistics, Track metadata and Playlist membership. Send expectedRevision on each page to detect changes; includeFilePaths requires files.read and includePreferenceStats requires history.read.",
            readOnly: true,
            scopes: [.libraryRead],
            risk: .low,
            inputSchema: libraryReportInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.libraryBundleExport,
            title: "Export Complete Library Bundle",
            description: "Create a path-free package containing Track metadata, Playlist membership, available audio files, artwork and lyrics. Destination is selected in the App; large exports run as a cancellable Job and require foreground confirmation.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.artworkRead, .filesRead, .libraryRead, .lyricsRead, .metadataRead, .playlistRead],
            risk: .high,
            supportsDryRun: true,
            supportsJobs: true,
            supportsTasks: true,
            inputSchema: libraryBundleExportInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.librarySelectionList,
            title: "List Selection Snapshots",
            description: "List bounded, persistent Track ID snapshots and re-evaluable filter selections in the active Library. Snapshots expire after 30 days and contain no file paths or media content.",
            readOnly: true,
            scopes: [.libraryRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.librarySelectionCreate,
            title: "Save Selection Snapshot",
            description: "Persist either an ordered set of Track IDs or a re-evaluable structured filter for later playlist operations. An optional expectedRevision protects capture from a stale library query.",
            readOnly: false,
            scopes: [.libraryRead, .selectionWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: librarySelectionCreateInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.librarySelectionGet,
            title: "Get Selection Snapshot",
            description: "Read the current Track IDs for one active-Library selection. Filter selections are re-evaluated against current metadata and Playlist membership.",
            readOnly: true,
            scopes: [.libraryRead],
            risk: .low,
            inputSchema: librarySelectionIDInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.librarySelectionDelete,
            title: "Delete Selection Snapshot",
            description: "Delete one saved selection snapshot without changing Tracks, playlists or files.",
            readOnly: false,
            scopes: [.libraryRead, .selectionWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: librarySelectionDeleteInputSchema
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
            name: AutomationMethod.playlistAddSelection,
            title: "Add Selection to Playlist",
            description: "Add an ordered saved selection to a Playlist. It reuses existing Library Tracks, skips duplicate membership, and supports preview and expected Playlist/selection revisions.",
            readOnly: false,
            scopes: [.playlistWrite, .libraryRead, .selectionWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: playlistAddSelectionInputSchema
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
            name: AutomationMethod.sourceGet,
            title: "Get Source",
            description: "Read one authorized referenced-library Source, including its monitor policy, exclusions, playlist bindings and scan status.",
            readOnly: true,
            scopes: [.sourceRead],
            risk: .low,
            inputSchema: sourceIDInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceConfigExport,
            title: "Export Source Configuration",
            description: "Export portable Source display names, monitor policies and excluded relative paths. Filesystem paths, security bookmarks, scan state and Playlist bindings stay local.",
            readOnly: true,
            scopes: [.sourceRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceConfigImport,
            title: "Apply Source Configuration",
            description: "Preview or apply a versioned Source policy document to existing authorized Sources. Cross-Library imports require an explicit sourceIDMap; excluded paths may trigger reconciliation. The App asks for foreground confirmation before applying changes.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.sourceRead, .sourceWrite],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: sourceConfigImportInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.sourceRename,
            title: "Rename Source",
            description: "Change a Source display name while preserving its bookmark, identity, playlist bindings, scan state and monitoring policy.",
            readOnly: false,
            scopes: [.sourceWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: sourceRenameInputSchema
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
            supportsTasks: true,
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
            name: AutomationMethod.playlistDiff,
            title: "Compare Playlists",
            description: "Compare two or more Playlist memberships as an ordered union, intersection or directional difference without changing any Playlist.",
            readOnly: true,
            scopes: [.playlistRead],
            risk: .low,
            inputSchema: playlistDiffInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistImport,
            title: "Import Playlist",
            description: "Import an M3U8 text payload into an existing Playlist by matching stable player-track IDs or paths of Tracks already in the active Library. Unmatched paths are reported; no audio is imported.",
            readOnly: false,
            scopes: [.playlistWrite, .libraryRead],
            risk: .low,
            supportsDryRun: true,
            inputSchema: playlistImportInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playlistExport,
            title: "Export Playlist",
            description: "Export an M3U8 text payload. Stable player-track IDs are used by default; absolute file paths are included only when explicitly requested and files.read is granted.",
            readOnly: true,
            scopes: [.playlistRead],
            risk: .low,
            inputSchema: playlistExportInputSchema
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
            supportsTasks: true,
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
            name: AutomationMethod.filesReveal,
            title: "Reveal Track Files",
            description: "Reveal authorized Track files in Finder. Managed-library paths are resolved under the active Library; referenced paths require an active authorized Source.",
            readOnly: false,
            scopes: [.filesRead, .libraryRead],
            risk: .low,
            inputSchema: fileRevealInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.filesExport,
            title: "Export Track Files",
            description: "Copy selected audio files to a folder chosen in the App. Managed files and currently authorized referenced files are supported; originals and Library membership remain unchanged.",
            readOnly: false,
            scopes: [.filesRead, .libraryRead],
            risk: .low,
            inputSchema: fileExportInputSchema
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
            supportsTasks: true,
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
            supportsTasks: true,
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
            supportsTasks: true,
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
            name: AutomationMethod.playbackPlayPlaylist,
            title: "Play Playlist",
            description: "Start playback from an existing Playlist and optional zero-based start index through PlaybackCoordinator.",
            readOnly: false,
            scopes: [.playbackControl, .playlistRead, .libraryRead],
            risk: .low,
            inputSchema: playbackPlaylistInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.playbackToggle,
            title: "Toggle Playback",
            description: "Toggle play/pause through the active playback owner.",
            readOnly: false,
            scopes: [.playbackControl],
            risk: .low,
            inputSchema: emptyInputSchema
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
            name: AutomationMethod.queueRemove,
            title: "Remove from Queue",
            description: "Remove selected existing Track occurrences from the upcoming local queue using an optional expected queue revision.",
            readOnly: false,
            scopes: [.queueWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: queueMutationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.queueReorder,
            title: "Reorder Queue",
            description: "Reorder all queued Track occurrences while preserving queue membership and the current playback item.",
            readOnly: false,
            scopes: [.queueWrite, .libraryRead],
            risk: .low,
            supportsDryRun: true,
            inputSchema: queueMutationInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.queueUpcoming,
            title: "Upcoming Queue",
            description: "Read a stable page of upcoming local queue items with the current Track and queue revision.",
            readOnly: true,
            scopes: [.queueRead],
            risk: .low,
            inputSchema: queueUpcomingInputSchema
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
            description: "Read listening history with optional date bounds, text/Track/Artist/Album filters, stable limit/offset pagination, and expectedRevision conflict detection. Results include total and nextOffset.",
            readOnly: true,
            scopes: [.historyRead],
            risk: .low,
            inputSchema: historyListInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.historyStats,
            title: "History Statistics",
            description: "Aggregate play counts and listened seconds by Track, Artist and Album in the requested time window.",
            readOnly: true,
            scopes: [.historyRead],
            risk: .low,
            inputSchema: historyStatsInputSchema
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
            description: "Read authoritative App metadata for existing Tracks, Artists, Albums or Playlists.",
            readOnly: true,
            scopes: [.metadataRead, .libraryRead],
            risk: .low,
            inputSchema: metadataGetInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.metadataEmbeddedGet,
            title: "Read Embedded Audio Tags",
            description: "Read tags directly from authorized audio files. Supported MP3 files expose ID3v2.3/v2.4 fields; other formats return App metadata extraction where available and identify write support explicitly.",
            readOnly: true,
            scopes: [.filesRead, .libraryRead, .metadataRead],
            risk: .low,
            inputSchema: metadataEmbeddedGetInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.metadataEmbeddedPatch,
            title: "Write Embedded Audio Tags",
            description: "Write selected ID3v2.3/v2.4 fields into MP3 files with an atomic staged replacement. Other formats and ID3 features that cannot be preserved safely are rejected. Requires an expected Track revision, dry-run review, confirm=true and App foreground confirmation; large batches run as Jobs.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.filesRead, .filesWrite, .libraryRead, .metadataWrite],
            risk: .high,
            supportsDryRun: true,
            supportsJobs: true,
            supportsTasks: true,
            inputSchema: metadataEmbeddedPatchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.metadataExport,
            title: "Export Track Metadata",
            description: "Export a bounded, versioned, path-free JSON page of editable Track metadata for backup or migration. Each page contains at most 100 Tracks to fit the local IPC frame.",
            readOnly: true,
            scopes: [.metadataRead, .libraryRead],
            risk: .low,
            inputSchema: metadataExportInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.metadataImport,
            title: "Import Track Metadata",
            description: "Preview or apply a versioned Track metadata document to existing Tracks through the App metadata owner.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.metadataWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: metadataImportInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.metadataSearch,
            title: "Search Metadata Candidates",
            description: "Search QQMusic and MusicBrainz for metadata candidates for one Track. Returns provider-neutral field match quality, provider warnings and the Track revision without changing the Library. Use background:true for slow searches; the App Job preserves the candidate result.",
            readOnly: true,
            scopes: [.metadataRead, .libraryRead],
            risk: .low,
            supportsJobs: true,
            supportsTasks: true,
            inputSchema: metadataSearchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.metadataApplyCandidate,
            title: "Apply Metadata Candidate",
            description: "Revalidate and fetch a selected QQMusic or MusicBrainz candidate, preview its field patch, and apply it through the App metadata owner. Existing values are preserved unless overwriteExistingFields is true; expectedRevision prevents stale writes.",
            readOnly: false,
            scopes: [.metadataWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: metadataApplyCandidateInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.metadataPatch,
            title: "Patch Metadata",
            description: "Patch editable App-owned Track, Artist, Album or Playlist metadata. This does not write embedded tags into original audio files; Track batches of 10 or more require foreground confirmation.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.metadataWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: metadataPatchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.artworkSearch,
            title: "Search Artwork",
            description: "Search the App's configured artwork providers for one Track, Artist or Album and return ranked image candidates with inline image data for Agent review. Use background:true for slow searches; the App Job preserves the candidate result.",
            readOnly: true,
            scopes: [.artworkRead, .libraryRead],
            risk: .low,
            supportsJobs: true,
            supportsTasks: true,
            inputSchema: artworkSearchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.artworkGet,
            title: "Get Artwork",
            description: "Read App-owned Track, Artist, Album or Playlist artwork availability, stored filename, size and digest without returning image bytes.",
            readOnly: true,
            scopes: [.artworkRead, .libraryRead],
            risk: .low,
            inputSchema: artworkGetInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.artworkApply,
            title: "Apply Artwork",
            description: "Replace or clear App-owned Track, Artist, Album or Playlist artwork using an App-owned picker, an image path hint or base64 data. Track batches of 10 or more require foreground confirmation; original audio-file tags are not changed.",
            readOnly: false,
            requiresConfirmation: true,
            scopes: [.artworkWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: artworkApplyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.artworkApplyCandidate,
            title: "Apply Artwork Candidate",
            description: "Apply a candidate returned by artwork.search through the App artwork owner. The opaque candidate ID is bound to its Library, target and artwork revision; stale or expired candidates are rejected. Supports dry-run preview and App foreground confirmation for qualifying batches.",
            readOnly: false,
            scopes: [.artworkWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: artworkApplyCandidateInputSchema
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
            description: "Search the existing AMLLDB and LDDC providers and return ranked, selectable lyrics candidates for one Track. Use background:true for slow searches; the App Job preserves the candidate result.",
            readOnly: true,
            scopes: [.lyricsRead, .libraryRead],
            risk: .low,
            supportsJobs: true,
            supportsTasks: true,
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
            description: "Apply either one selected provider candidate or direct custom TTML text through the existing App-owned lyrics persistence path. Candidate input keeps quality gating; ttmlText is validated and written directly.",
            readOnly: false,
            scopes: [.lyricsWrite, .libraryRead],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: lyricsApplyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.lyricsClean,
            title: "Clean Lyrics Metadata",
            description: "Strip preamble and trailing metadata/credit noise lines from a Track's persisted TTML lyrics and synchronize the start time.",
            readOnly: false,
            scopes: [.lyricsWrite, .libraryRead],
            risk: .low,
            supportsDryRun: true,
            inputSchema: lyricsCleanInputSchema
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
            supportsTasks: true,
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
            description: "Read one active or recent library Job by ID, including progress, item failures and persisted result.",
            readOnly: true,
            scopes: [.diagnosticsRead],
            risk: .low,
            inputSchema: jobIDInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.jobsWait,
            title: "Wait for Job",
            description: "Wait for one library Job to finish or for a bounded timeout. Maximum wait is 25 seconds; returns the latest snapshot on timeout. The wait can be cancelled without cancelling the Job.",
            readOnly: true,
            scopes: [.diagnosticsRead],
            risk: .low,
            inputSchema: jobWaitInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.operationsBatch,
            title: "Batch Asset Operations",
            description: "Run up to 100 metadata, artwork and lyrics mutations in order through their existing App owners. Each item has its own method and params, including expectedRevision. The App returns a durable Job with per-item results; use jobs.wait and jobs.get. Set dryRun:true to force a preview for every item. Ten or more write items or distinct write targets require confirm:true and one App foreground confirmation.",
            readOnly: false,
            scopes: [],
            risk: .medium,
            supportsDryRun: true,
            supportsJobs: true,
            supportsTasks: true,
            inputSchema: operationsBatchInputSchema
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
            description: "Retry a failed, partially failed or cancelled Source scan or lyrics refresh from its durable specification. To retry an import after restart, provide filePaths again so the App can reacquire access; file paths and bookmarks are never stored in Job history.",
            readOnly: false,
            scopes: [.diagnosticsRepair],
            risk: .medium,
            inputSchema: jobRetryInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.diagnosticsHealth,
            title: "Library Health",
            description: "Inspect Library, Source, missing/unavailable Track, Playlist reference, storage and Job health. Consistency issues and cheap media path presence issues are paginated separately and include IDs, paths and reasons where known; audio is not decoded and files are not repaired.",
            readOnly: true,
            scopes: [.diagnosticsRead, .libraryRead, .sourceRead],
            risk: .low,
            supportsJobs: true,
            supportsTasks: true,
            inputSchema: diagnosticsHealthInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.settingsGet,
            title: "Get Automation Settings",
            description: "Read supported persistent App and Library settings, including import enrichment timing, appearance and referenced-track deletion policy.",
            readOnly: true,
            scopes: [.settingsRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.settingsSchema,
            title: "Settings Schema",
            description: "Read the supported persistent App and Library settings, allowed values, defaults and applicability.",
            readOnly: true,
            scopes: [.settingsRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.settingsPatch,
            title: "Patch Automation Settings",
            description: "Preview or update supported persistent App and Library preferences. Unsupported UI-only preferences are rejected instead of being guessed.",
            readOnly: false,
            scopes: [.settingsWrite],
            risk: .medium,
            supportsDryRun: true,
            inputSchema: settingsPatchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.settingsValidate,
            title: "Validate Settings",
            description: "Validate a supported settings patch and return normalized values without writing them.",
            readOnly: true,
            scopes: [.settingsRead],
            risk: .low,
            inputSchema: settingsPatchInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.settingsReset,
            title: "Reset Supported Settings",
            description: "Preview or reset supported persistent App settings and applicable Library settings to their documented defaults.",
            readOnly: false,
            scopes: [.settingsWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: settingsResetInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.audioGet,
            title: "Get Audio Settings",
            description: "Read persistent audio scheduling and output preferences, available output devices, and live system and App output telemetry.",
            readOnly: true,
            scopes: [.audioRead],
            risk: .low,
            inputSchema: emptyInputSchema
        ),
        AutomationToolDescriptor(
            name: AutomationMethod.audioPatch,
            title: "Patch Audio Settings",
            description: "Preview or update gapless scheduling options and the App's preferred output device; pass null to follow the system default.",
            readOnly: false,
            scopes: [.audioWrite],
            risk: .low,
            supportsDryRun: true,
            inputSchema: audioPatchInputSchema
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
            description: "Run the App-owned storage, sidecar, index, manifest and playback-history consistency validator against the active Library. Returns paginated consistency issues plus separate cheap existence/readability checks for recorded media paths; it does not decode or repair audio files. Use background:true when a large Library takes too long for a synchronous result.",
            readOnly: true,
            scopes: [.storageRead],
            risk: .low,
            supportsJobs: true,
            supportsTasks: true,
            inputSchema: storageValidationInputSchema
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
            description: "Create an App-owned, machine-readable backup of Library JSON sidecars and enrichment assets without copying audio files, indexes or caches; retain only the newest backup for the Library.",
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
    ] + AutomationDSPToolCatalog.descriptors).sorted { $0.name < $1.name }

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
                "description": .string("Composable filter object: all/any/not plus id, ids, text, titleContains, artistContains, albumContains, genreContains, sourceID, playlistID, availability, missing, addedAfter, addedBefore, releaseAfter, releaseBefore, durationMin, durationMax, hasLyrics, lyricsStatus, hasArtwork, metadataConfidenceMin, codec, format, sampleRateHz and bitDepth. Playback-history predicates like likeState, playCountMin/Max, completePlayCountMin, skipCountMin, lastPlayedAfter/Before, totalPlayedSecondsMin and preferenceScoreMin require history.read.")
            ]),
            "includePreferenceStats": .object([
                "type": .string("boolean"),
                "description": .string("Include per-Track playback preference counters, like state and preference score; requires history.read.")
            ]),
            "sort": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "field": .object([
                            "type": .string("string"),
                            "description": .string("Track field or playback preference: title, artist, album, duration, addedAt, releaseDate, availability, codec, sampleRateHz, filePath, likeState, playCount, completePlayCount, skipCount, lastPlayedAt, totalPlayedSeconds or preferenceScore. Preference fields require history.read.")
                        ]),
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

    private static let libraryReportInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)]),
            "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
            "playlistLimit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)]),
            "playlistOffset": .object(["type": .string("integer"), "minimum": .number(0)]),
            "expectedRevision": .object(["type": .string("string")]),
            "includeFilePaths": .object(["type": .string("boolean")]),
            "includePreferenceStats": .object([
                "type": .string("boolean"),
                "description": .string("Include per-Track playback preference counters, like state and preference score; requires history.read.")
            ])
        ])
    ])

    private static let libraryBundleExportInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let libraryImportInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("filePaths")]),
        "properties": .object([
            "filePaths": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(5_000),
                "items": .object(["type": .string("string"), "minLength": .number(1)])
            ]),
            "targetPlaylistID": .object(["type": .string("string"), "format": .string("uuid")]),
            "enrichmentPolicy": .object([
                "type": .string("string"),
                "enum": .array([.string("standard"), .string("migration")])
            ]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let librarySelectionCreateInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "oneOf": .array([
            .object(["required": .array([.string("trackIDs")])]),
            .object(["required": .array([.string("filter")])])
        ]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(0),
                "maxItems": .number(10_000),
                "items": .object(["type": .string("string"), "format": .string("uuid")])
            ]),
            "filter": .object([
                "type": .string("object"),
                "description": .string("Same structured predicate accepted by library.tracks.filter; it is re-evaluated when the selection is read or used.")
            ]),
            "name": .object(["type": .string("string"), "maxLength": .number(120)]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let librarySelectionIDInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("selectionID")]),
        "properties": .object([
            "selectionID": .object(["type": .string("string"), "format": .string("uuid")])
        ])
    ])

    private static let librarySelectionDeleteInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("selectionID")]),
        "properties": .object([
            "selectionID": .object(["type": .string("string"), "format": .string("uuid")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let playlistAddSelectionInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("playlistID"), .string("selectionID")]),
        "properties": .object([
            "playlistID": .object(["type": .string("string"), "format": .string("uuid")]),
            "selectionID": .object(["type": .string("string"), "format": .string("uuid")]),
            "expectedRevision": .object(["type": .string("string")]),
            "expectedSelectionRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let playlistDiffInputSchema: AutomationJSONValue = .object([
        "type": .string("object"), "additionalProperties": .boolean(false),
        "required": .array([.string("playlistIDs"), .string("operation")]),
        "properties": .object([
            "playlistIDs": .object(["type": .string("array"), "minItems": .number(2), "maxItems": .number(100), "items": .object(["type": .string("string"), "format": .string("uuid")])]),
            "operation": .object(["type": .string("string"), "enum": .array([.string("union"), .string("intersection"), .string("difference")])]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(500)]),
            "offset": .object(["type": .string("integer"), "minimum": .number(0)])
        ])
    ])

    private static let playlistImportInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("playlistID"), .string("m3uText")]),
        "properties": .object([
            "playlistID": .object(["type": .string("string")]),
            "m3uText": .object(["type": .string("string"), "maxLength": .number(5_000_000)]),
            "operation": .object(["type": .string("string"), "enum": .array([.string("append"), .string("replace")])]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let playlistExportInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("playlistID")]),
        "properties": .object([
            "playlistID": .object(["type": .string("string")]),
            "includePaths": .object(["type": .string("boolean")])
        ])
    ])

    private static let playbackPlaylistInputSchema: AutomationJSONValue = .object([
        "type": .string("object"), "additionalProperties": .boolean(false),
        "required": .array([.string("playlistID")]),
        "properties": .object([
            "playlistID": .object(["type": .string("string"), "format": .string("uuid")]),
            "startIndex": .object(["type": .string("integer"), "minimum": .number(0)])
        ])
    ])

    private static let queueUpcomingInputSchema: AutomationJSONValue = .object([
        "type": .string("object"), "additionalProperties": .boolean(false),
        "properties": .object([
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(500)]),
            "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
            "expectedRevision": .object(["type": .string("string")])
        ])
    ])

    private static let historyStatsInputSchema: AutomationJSONValue = .object([
        "type": .string("object"), "additionalProperties": .boolean(false),
        "properties": .object([
            "from": .object(["type": .string("string"), "format": .string("date-time")]),
            "to": .object(["type": .string("string"), "format": .string("date-time")]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)]),
            "dimension": .object(["type": .string("string"), "enum": .array([.string("all"), .string("track"), .string("artist"), .string("album")])])
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

    private static let libraryIDInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("libraryID")]),
        "properties": .object(["libraryID": .object(["type": .string("string")])])
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
                "maxItems": .number(10_000),
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

    private static let sourceIDInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("sourceID")]),
        "properties": .object(["sourceID": .object(["type": .string("string")])])
    ])

    private static let sourceRenameInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("sourceID"), .string("displayName")]),
        "properties": .object([
            "sourceID": .object(["type": .string("string")]),
            "displayName": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(120)]),
            "dryRun": .object(["type": .string("boolean")])
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
            "entityType": .object([
                "type": .string("string"),
                "enum": .array([.string("artist"), .string("album"), .string("playlist")])
            ]),
            "trackID": .object(["type": .string("string")]),
            "trackIDs": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "artistID": .object(["type": .string("string")]),
            "albumKey": .object(["type": .string("string")]),
            "playlistID": .object(["type": .string("string")]),
            "query": .object(["type": .string("string")]),
            "limit": .object([
                "type": .string("integer"),
                "minimum": .number(1),
                "maximum": .number(500)
            ]),
            "offset": .object([
                "type": .string("integer"),
                "minimum": .number(0)
            ])
        ])
    ])

    private static let metadataEmbeddedGetInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(100),
                "items": .object(["type": .string("string")])
            ])
        ])
    ])

    private static let metadataEmbeddedPatchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("fields")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(100),
                "items": .object(["type": .string("string")])
            ]),
            "fields": .object([
                "type": .string("object"),
                "additionalProperties": .object([
                    "type": .array([.string("string"), .string("null")])
                ])
            ]),
            "expectedRevisions": .object(["type": .string("object")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let metadataPatchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("patch")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "items": .object(["type": .string("string")])
            ]),
            "trackID": .object(["type": .string("string")]),
            "artistID": .object(["type": .string("string")]),
            "albumKey": .object(["type": .string("string")]),
            "playlistID": .object(["type": .string("string")]),
            "patch": .object(["type": .string("object")]),
            "expectedRevisions": .object(["type": .string("object")]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let metadataSearchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackID")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "background": .object(["type": .string("boolean")])
        ])
    ])

    private static let metadataExportInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(100),
                "items": .object(["type": .string("string")])
            ]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)]),
            "offset": .object(["type": .string("integer"), "minimum": .number(0)])
        ])
    ])

    private static let metadataImportInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("document")]),
        "properties": .object([
            "document": .object(["type": .string("object")]),
            "trackIDMap": .object(["type": .string("object")]),
            "expectedRevision": .object(["type": .string("string")]),
            "overwriteExistingFields": .object(["type": .string("boolean")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let metadataApplyCandidateInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackID"), .string("candidateID")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "candidateID": .object(["type": .string("string"), "minLength": .number(1)]),
            "expectedRevision": .object(["type": .string("string")]),
            "overwriteExistingFields": .object(["type": .string("boolean")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let artworkGetInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "items": .object(["type": .string("string")])
            ]),
            "trackID": .object(["type": .string("string")]),
            "artistID": .object(["type": .string("string")]),
            "albumKey": .object(["type": .string("string")]),
            "playlistID": .object(["type": .string("string")])
        ])
    ])

    private static let artworkSearchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "artistID": .object(["type": .string("string")]),
            "albumKey": .object(["type": .string("string")]),
            "background": .object(["type": .string("boolean")]),
            "limit": .object([
                "type": .string("integer"),
                "minimum": .number(1),
                "maximum": .number(5)
            ])
        ])
    ])

    private static let artworkApplyInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "items": .object(["type": .string("string")])
            ]),
            "trackID": .object(["type": .string("string")]),
            "artistID": .object(["type": .string("string")]),
            "albumKey": .object(["type": .string("string")]),
            "playlistID": .object(["type": .string("string")]),
            "imagePath": .object(["type": .string("string")]),
            "imageBase64": .object(["type": .string("string")]),
            "clear": .object(["type": .string("boolean")]),
            "expectedRevisions": .object(["type": .string("object")]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let artworkApplyCandidateInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("candidateID")]),
        "properties": .object([
            "candidateID": .object(["type": .string("string")]),
            "expectedRevision": .object(["type": .string("string")]),
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
            "translation": .object(["type": .string("boolean")]),
            "background": .object(["type": .string("boolean")])
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
        "required": .array([.string("trackID")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "candidate": lyricsCandidateSchema,
            "ttmlText": .object([
                "type": .string("string"),
                "minLength": .number(1),
                "description": .string("Validated custom TTML text. Use exactly one of candidate or ttmlText.")
            ]),
            "force": .object(["type": .string("boolean")]),
            "translation": .object(["type": .string("boolean")]),
            "dryRun": .object(["type": .string("boolean")]),
            "cleanMetadata": .object([
                "type": .string("boolean"),
                "description": .string("Automatically strip preamble and trailing metadata/credit noise from TTML before applying (default true).")
            ]),
            "expectedRevision": .object(["type": .string("string")])
        ])
    ])

    private static let lyricsCleanInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackID")]),
        "properties": .object([
            "trackID": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
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

    private static let sourceConfigImportInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("document")]),
        "properties": .object([
            "document": .object([
                "type": .string("object"),
                "required": .array([.string("schemaVersion"), .string("originLibraryID"), .string("sources")]),
                "properties": .object([
                    "schemaVersion": .object(["type": .string("integer"), "const": .number(1)]),
                    "originLibraryID": .object(["type": .string("string"), "format": .string("uuid")]),
                    "sources": .object([
                        "type": .string("array"), "maxItems": .number(100),
                        "items": .object([
                            "type": .string("object"),
                            "required": .array([.string("sourceID"), .string("displayName"), .string("monitorPolicy"), .string("excludedRelativePaths")]),
                            "properties": .object([
                                "sourceID": .object(["type": .string("string"), "format": .string("uuid")]),
                                "displayName": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(120)]),
                                "monitorPolicy": .object(["type": .string("string"), "enum": .array([.string("inherit"), .string("on"), .string("off")])]),
                                "excludedRelativePaths": .object([
                                    "type": .string("array"), "maxItems": .number(100),
                                    "items": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(1024)])
                                ])
                            ])
                        ])
                    ])
                ])
            ]),
            "sourceIDMap": .object([
                "type": .string("object"), "maxProperties": .number(100),
                "additionalProperties": .object(["type": .string("string"), "format": .string("uuid")])
            ]),
            "expectedRevision": .object(["type": .string("string")]),
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

    private static let fileRevealInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackIDs")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(50),
                "items": .object(["type": .string("string")])
            ]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let fileExportInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("trackIDs")]),
        "properties": .object([
            "trackIDs": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(500),
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
                "description": .string("Supported keys: referencedTrackDeletePolicy, deferImportEnrichment, globalArtworkTintEnabled, audioVisualizationHDREnabled, dockProgressVisible, appearanceMode.")
            ]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let settingsResetInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let audioPatchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("values")]),
        "properties": .object([
            "values": .object([
                "type": .string("object"),
                "additionalProperties": .boolean(false),
                "properties": .object([
                    "gaplessSchedulingEnabled": .object(["type": .string("boolean")]),
                    "aacGaplessTrimEnabled": .object(["type": .string("boolean")]),
                    "outputDeviceID": .object([
                        "type": .array([.string("string"), .string("null")]),
                        "description": .string("An id from audio.get.availableOutputDevices, or null to follow the system default.")
                    ])
                ])
            ]),
            "expectedRevision": .object(["type": .string("string")]),
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let storageMutationInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "dryRun": .object(["type": .string("boolean")])
        ])
    ])

    private static let diagnosticsHealthInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)]),
            "background": .object(["type": .string("boolean")])
        ])
    ])

    private static let storageValidationInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "properties": .object([
            "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)]),
            "background": .object(["type": .string("boolean")])
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
            "query": .object(["type": .string("string")]),
            "trackID": .object(["type": .string("string")]),
            "artistContains": .object(["type": .string("string")]),
            "albumContains": .object(["type": .string("string")]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(500)]),
            "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
            "from": .object(["type": .string("string")]),
            "to": .object(["type": .string("string")]),
            "expectedRevision": .object(["type": .string("string")])
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

    private static let jobWaitInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("jobID")]),
        "properties": .object([
            "jobID": .object(["type": .string("string"), "format": .string("uuid")]),
            "timeoutMs": .object([
                "type": .string("integer"),
                "minimum": .number(0),
                "maximum": .number(25_000)
            ])
        ])
    ])

    private static let operationsBatchInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("operations")]),
        "properties": .object([
            "operations": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(100),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .boolean(false),
                    "required": .array([.string("method")]),
                    "properties": .object([
                        "method": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string(AutomationMethod.metadataPatch),
                                .string(AutomationMethod.metadataApplyCandidate),
                                .string(AutomationMethod.artworkApply),
                                .string(AutomationMethod.artworkApplyCandidate),
                                .string(AutomationMethod.lyricsApply),
                                .string(AutomationMethod.lyricsClean)
                            ])
                        ]),
                        "params": .object(["type": .string("object")])
                    ])
                ])
            ]),
            "dryRun": .object(["type": .string("boolean")]),
            "confirm": .object(["type": .string("boolean")])
        ])
    ])

    private static let jobRetryInputSchema: AutomationJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("jobID")]),
        "properties": .object([
            "jobID": .object(["type": .string("string")]),
            "filePaths": .object([
                "type": .string("array"),
                "minItems": .number(1),
                "maxItems": .number(5_000),
                "items": .object([
                    "type": .string("string"),
                    "minLength": .number(1)
                ])
            ])
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
