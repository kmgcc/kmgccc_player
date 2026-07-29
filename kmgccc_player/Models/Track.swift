//
//  Track.swift
//  myPlayer2
//
//  kmgccc_player - SwiftData Track Model
//  Represents a music file indexed in the library.
//

import AppKit
import Foundation
import SwiftData

// TrackAvailability lives in its own value-type model for resolver reuse.

@Model
final class Track {
    // MARK: - Identifiers

    @Attribute(.unique) var id: UUID

    // MARK: - Metadata

    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var userDescription: String
    var genreTags: [String] = []
    var language: String = ""
    var labelOrCompany: String = ""
    var releaseDate: Date?
    var qqMusicSongMid: String?
    var metadataSource: String?
    var metadataFetchedAt: Date?
    var metadataConfidence: Double?
    var albumGroupKey: String
    var duration: Double  // seconds
    var addedAt: Date
    var importedAt: Date?
    /// Per-track lyric time offset in milliseconds (+/-).
    var lyricsTimeOffsetMs: Double = 0

    // MARK: - File Access (security-scoped bookmark)

    /// Security-scoped bookmark data for the audio file.
    /// Used to regain access to the file after app restart (sandbox).
    var fileBookmarkData: Data

    /// Original file path (for display/debugging only - not for access!)
    var originalFilePath: String

    /// Relative path inside the local library (e.g. "Tracks/<id>/audio.m4a").
    /// Empty means the track still relies on a legacy bookmark.
    var libraryRelativePath: String = ""

    /// Stable encoded locator snapshot. Legacy path/bookmark fields remain as compatibility projections.
    var mediaLocatorData: Data = Data()

    var mediaLocator: TrackMediaLocator {
        get {
            if let decoded = try? JSONDecoder().decode(TrackMediaLocator.self, from: mediaLocatorData) {
                return decoded
            }
            if !libraryRelativePath.isEmpty {
                return .managed(libraryRelativePath: libraryRelativePath)
            }
            return .referenced(ReferencedFileLocator(
                fileBookmarkData: fileBookmarkData,
                lastKnownPath: originalFilePath
            ))
        }
        set {
            mediaLocatorData = (try? JSONEncoder().encode(newValue)) ?? Data()
            switch newValue {
            case let .managed(path):
                libraryRelativePath = path
                fileBookmarkData = Data()
            case let .referenced(locator):
                libraryRelativePath = ""
                fileBookmarkData = locator.fileBookmarkData
                originalFilePath = locator.lastKnownPath
            }
        }
    }

    /// Availability status (updated on locator resolution).
    private var availabilityRaw: String

    var availability: TrackAvailability {
        get { TrackAvailability(rawValue: availabilityRaw) ?? .available }
        set { availabilityRaw = newValue.rawValue }
    }

    // MARK: - Relationships

    /// Playlists this track belongs to.
    /// Inverse relationship for Playlist.tracks.
    @Relationship(inverse: \Playlist.tracks) var playlists: [Playlist] = []

    // MARK: - Artwork

    /// Embedded or user-edited cover art (JPEG/PNG data).
    /// Lazily loaded from disk via `loadArtworkDataIfNeeded()`.
    @Attribute(.externalStorage)
    var artworkData: Data?

    // MARK: - Persistence References (lightweight, for lazy loading)

    /// Snapshot of the library root URL at the time this track was created/scanned.
    /// Used to prevent path drift when the active library root changes.
    var libraryRootSnapshot: String = ""

    /// Audio file name inside the track folder (e.g. "audio.m4a").
    var audioFileName: String = ""

    /// Artwork file name inside the track folder (e.g. "artwork.jpg").
    var artworkFileName: String?

    /// Lyrics file name inside the track folder (e.g. "lyrics.txt").
    var lyricsFileName: String?

    /// TTML lyrics file name inside the track folder (e.g. "lyrics.ttml").
    var ttmlLyricsFileName: String?

    /// Durable referenced-NCM transaction association, mirrored into schema 7 sidecars.
    var ncmConversionAssociationData: Data?

    var ncmConversionAssociation: NCMConversionAssociation? {
        get {
            guard let data = ncmConversionAssociationData else { return nil }
            return try? JSONDecoder().decode(NCMConversionAssociation.self, from: data)
        }
        set {
            ncmConversionAssociationData = try? newValue.map { try JSONEncoder().encode($0) }
        }
    }

    // MARK: - Lyrics

    /// Directly pasted or imported TTML lyrics text (embedded).
    var ttmlLyricText: String?

    /// Imported lyrics text (legacy format from external file).
    /// Deprecated: Use ttmlLyricText instead.
    var lyricsText: String?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "",
        album: String = "",
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
        albumGroupKey: String = "",
        duration: Double = 0,
        addedAt: Date = Date(),
        importedAt: Date? = nil,
        lyricsTimeOffsetMs: Double = 0,
        fileBookmarkData: Data,
        originalFilePath: String = "",
        libraryRelativePath: String = "",
        mediaLocator: TrackMediaLocator? = nil,
        availability: TrackAvailability = .available,
        artworkData: Data? = nil,
        ttmlLyricText: String? = nil,
        lyricsText: String? = nil,
        libraryRootSnapshot: String = "",
        audioFileName: String = "",
        artworkFileName: String? = nil,
        lyricsFileName: String? = nil,
        ttmlLyricsFileName: String? = nil,
        ncmConversionAssociation: NCMConversionAssociation? = nil,
        playCount: Int? = nil  // DEPRECATED: Ignored, use PreferenceStatsService instead
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
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
        self.albumGroupKey = albumGroupKey
        self.duration = duration
        self.addedAt = addedAt
        self.importedAt = importedAt ?? addedAt
        self.lyricsTimeOffsetMs = lyricsTimeOffsetMs
        self.fileBookmarkData = fileBookmarkData
        self.originalFilePath = originalFilePath
        self.libraryRelativePath = libraryRelativePath
        self.mediaLocatorData = Data()
        self.availabilityRaw = availability.rawValue
        self.mediaLocator = mediaLocator ?? {
            if !libraryRelativePath.isEmpty {
                return .managed(libraryRelativePath: libraryRelativePath)
            }
            return .referenced(ReferencedFileLocator(
                fileBookmarkData: fileBookmarkData,
                lastKnownPath: originalFilePath
            ))
        }()
        self.artworkData = artworkData
        self.ttmlLyricText = ttmlLyricText
        self.lyricsText = lyricsText
        self.libraryRootSnapshot = libraryRootSnapshot
        self.audioFileName = audioFileName
        self.artworkFileName = artworkFileName
        self.lyricsFileName = lyricsFileName
        self.ttmlLyricsFileName = ttmlLyricsFileName
        self.ncmConversionAssociationData = try? ncmConversionAssociation.map { try JSONEncoder().encode($0) }
        // NOTE: playCount parameter is deprecated. If provided, it's stored in preferenceStats via sidecar.
    }

    // MARK: - Bookmark Resolution

    /// Resolve result with optional refreshed bookmark data.
    struct ResolveResult {
        let url: URL?
        let refreshedLocator: TrackMediaLocator?
        let lease: SecurityScopedResourceLease
        let newAvailability: TrackAvailability

        var refreshedBookmarkData: Data? {
            refreshedLocator?.referencedFile?.fileBookmarkData
        }
    }

    /// Compatibility wrapper. LocalAudioResourceResolver is the only resolution implementation.
    func resolveFileURL() -> ResolveResult {
        guard let paths = capturedLibraryPaths else {
            return ResolveResult(url: nil, refreshedLocator: nil, lease: .none, newAvailability: .missing)
        }
        do {
            let result = try LocalAudioResourceResolver(paths: paths).resolve(mediaLocator)
            return ResolveResult(
                url: result.url,
                refreshedLocator: result.refreshedLocator,
                lease: result.lease,
                newAvailability: result.availability
            )
        } catch let error as LocalAudioResolutionError {
            let availability: TrackAvailability
            switch error {
            case .permissionDenied: availability = .permissionDenied
            case .volumeUnavailable: availability = .volumeUnavailable
            case .notDownloaded: availability = .notDownloaded
            default: availability = .missing
            }
            return ResolveResult(url: nil, refreshedLocator: nil, lease: .none, newAvailability: availability)
        } catch {
            return ResolveResult(url: nil, refreshedLocator: nil, lease: .none, newAvailability: .missing)
        }
    }

    // MARK: - Computed Properties

    /// Whether the track is currently playable.
    var isPlayable: Bool {
        availability.isPlayable
    }

    /// Drop heavyweight in-memory payloads once a track is removed from the library.
    func releaseTransientMediaResources() {
        artworkData = nil
        ttmlLyricText = nil
        lyricsText = nil
    }

    // MARK: - Persistence URL Resolution (root-snapshot aware)

    /// Resolve the track folder URL using the root captured by its session.
    func resolvedTrackFolderURL() -> URL? {
        capturedLibraryPaths?.trackFolderURL(for: id)
    }

    private var capturedLibraryPaths: LibraryPaths? {
        guard !libraryRootSnapshot.isEmpty else { return nil }
        return LibraryPaths(rootURL: URL(fileURLWithPath: libraryRootSnapshot, isDirectory: true))
    }

    func resolvedAudioURL() -> URL? {
        guard let paths = capturedLibraryPaths else { return nil }
        guard !audioFileName.isEmpty else {
            guard !libraryRelativePath.isEmpty else { return nil }
            return paths.libraryURL(from: libraryRelativePath)
        }
        return paths.trackAssetURL(for: id, fileName: audioFileName)
    }

    func resolvedArtworkURL() -> URL? {
        guard let paths = capturedLibraryPaths else { return nil }
        let fileManager = FileManager.default
        for fileName in paths.trackArtworkCandidateFileNames(preferredFileName: artworkFileName) {
            guard let url = paths.trackArtworkURL(for: id, fileName: fileName) else { continue }
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        guard let artworkFileName, !artworkFileName.isEmpty else { return nil }
        return paths.trackArtworkURL(for: id, fileName: artworkFileName)
    }

    func resolvedLyricsURL() -> URL? {
        guard let lyricsFileName, let paths = capturedLibraryPaths else { return nil }
        return paths.trackAssetURL(for: id, fileName: lyricsFileName)
    }

    func resolvedTTMLURL() -> URL? {
        guard let ttmlLyricsFileName, let paths = capturedLibraryPaths else { return nil }
        return paths.trackAssetURL(for: id, fileName: ttmlLyricsFileName)
    }

    // MARK: - Lazy Loading

    /// Load artwork data from disk if not already in memory.
    func loadArtworkDataIfNeeded() -> Data? {
        if let data = artworkData, !data.isEmpty { return data }
        guard let url = resolvedArtworkURL() else { return nil }
        let data = try? Data(contentsOf: url)
        artworkData = data
        return data
    }

    /// Read the artwork file off the main actor, then preserve the existing lazy in-memory cache behavior.
    func loadArtworkDataOffMainIfNeeded() async -> Data? {
        if let data = artworkData, !data.isEmpty { return data }
        guard let url = resolvedArtworkURL() else { return nil }
        let data = await Task.detached(priority: .utility) { @Sendable in
            try? Data(contentsOf: url)
        }.value
        artworkData = data
        return data
    }

    /// Load plain lyrics from disk if not already in memory.
    func loadLyricsIfNeeded() -> String? {
        if let text = lyricsText, !text.isEmpty { return text }
        guard let url = resolvedLyricsURL() else { return nil }
        let text = try? String(contentsOf: url, encoding: .utf8)
        lyricsText = text
        return text
    }

    /// Load TTML lyrics from disk if not already in memory.
    func loadTTMLLyricsIfNeeded() -> String? {
        if let text = ttmlLyricText, !text.isEmpty { return text }
        // Try dedicated TTML file first
        if let ttmlURL = resolvedTTMLURL(),
           let text = try? String(contentsOf: ttmlURL, encoding: .utf8), !text.isEmpty {
            ttmlLyricText = text
            return text
        }
        // Fallback: lyrics file might be TTML
        if let lyricsURL = resolvedLyricsURL(),
           let text = try? String(contentsOf: lyricsURL, encoding: .utf8), !text.isEmpty,
           lyricsURL.lastPathComponent.lowercased().hasSuffix(".ttml") {
            ttmlLyricText = text
            return text
        }
        return nil
    }
}

enum TrackLyricsDraft {
    struct Storage: Equatable {
        let ttmlText: String?
        let plainText: String?
    }

    static func storage(from editorText: String) -> Storage {
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Storage(ttmlText: nil, plainText: nil)
        }

        if LyricsFormatSupport.validateTTML(trimmed).isValid {
            return Storage(ttmlText: trimmed, plainText: nil)
        }

        return Storage(ttmlText: nil, plainText: nil)
    }

    static func differs(from track: Track, editorText: String) -> Bool {
        let draft = storage(from: editorText)
        let currentTTML = LyricsFormatSupport.normalizedTTMLText(track.loadTTMLLyricsIfNeeded())
        return draft.ttmlText != currentTTML
    }

    static func assign(editorText: String, to track: Track) {
        let draft = storage(from: editorText)
        track.ttmlLyricText = draft.ttmlText
        track.lyricsText = nil
        track.lyricsFileName = nil
        if draft.ttmlText == nil {
            track.ttmlLyricsFileName = nil
        }
    }
}
