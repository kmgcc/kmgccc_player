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

/// Track availability status based on bookmark resolution.
/// Using String raw values for SwiftData compatibility.
enum TrackAvailability: String, Codable {
    case available = "available"
    case stale = "stale"  // Bookmark outdated but file still exists
    case missing = "missing"  // File cannot be located
}

@Model
final class Track {
    // MARK: - Identifiers

    @Attribute(.unique) var id: UUID

    // MARK: - Metadata

    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
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

    /// Availability status (updated on bookmark resolution).
    /// Stored as String for SwiftData compatibility.
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

    // MARK: - Playback Stats (Deprecated)
    /// DEPRECATED: All playback stats now live in preferenceStats via PreferenceStatsService.
    /// This property is kept for backward compatibility during migration only.
    /// Use `PreferenceStatsService.shared.getStats(for: id).playCount` instead.
    @MainActor
    var playCount: Int {
        get {
            PreferenceStatsService.shared.getStats(for: id).playCount
        }
        set {
            // No-op: stats are managed through PreferenceStatsService
            // This setter exists to prevent breaking old code during migration
        }
    }

    // MARK: - Lyrics

    /// Directly pasted or imported TTML lyrics text (embedded).
    var ttmlLyricText: String?

    /// Imported lyrics text (legacy format from external file).
    /// Deprecated: Use ttmlLyricText instead.
    var lyricsText: String?

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "",
        album: String = "",
        albumArtist: String? = nil,
        albumGroupKey: String = "",
        duration: Double = 0,
        addedAt: Date = Date(),
        importedAt: Date? = nil,
        lyricsTimeOffsetMs: Double = 0,
        fileBookmarkData: Data,
        originalFilePath: String = "",
        libraryRelativePath: String = "",
        availability: TrackAvailability = .available,
        artworkData: Data? = nil,
        ttmlLyricText: String? = nil,
        lyricsText: String? = nil,
        libraryRootSnapshot: String = "",
        audioFileName: String = "",
        artworkFileName: String? = nil,
        lyricsFileName: String? = nil,
        ttmlLyricsFileName: String? = nil,
        playCount: Int? = nil  // DEPRECATED: Ignored, use PreferenceStatsService instead
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.albumGroupKey = albumGroupKey
        self.duration = duration
        self.addedAt = addedAt
        self.importedAt = importedAt ?? addedAt
        self.lyricsTimeOffsetMs = lyricsTimeOffsetMs
        self.fileBookmarkData = fileBookmarkData
        self.originalFilePath = originalFilePath
        self.libraryRelativePath = libraryRelativePath
        self.availabilityRaw = availability.rawValue
        self.artworkData = artworkData
        self.ttmlLyricText = ttmlLyricText
        self.lyricsText = lyricsText
        self.libraryRootSnapshot = libraryRootSnapshot
        self.audioFileName = audioFileName
        self.artworkFileName = artworkFileName
        self.lyricsFileName = lyricsFileName
        self.ttmlLyricsFileName = ttmlLyricsFileName
        // NOTE: playCount parameter is deprecated. If provided, it's stored in preferenceStats via sidecar.
    }

    // MARK: - Bookmark Resolution

    /// Resolve result with optional refreshed bookmark data.
    struct ResolveResult {
        let url: URL?
        let refreshedBookmarkData: Data?
        let newAvailability: TrackAvailability
    }

    /// Resolve the security-scoped bookmark to get a usable file URL.
    /// - Returns: ResolveResult containing URL (if accessible), refreshed bookmark (if stale), and new availability status.
    func resolveFileURL() -> ResolveResult {
        if !libraryRelativePath.isEmpty {
            let localURL = LocalLibraryPaths.libraryURL(from: libraryRelativePath)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return ResolveResult(
                    url: localURL, refreshedBookmarkData: nil, newAvailability: .available)
            }
            return ResolveResult(url: nil, refreshedBookmarkData: nil, newAvailability: .missing)
        }

        if fileBookmarkData.isEmpty {
            return ResolveResult(url: nil, refreshedBookmarkData: nil, newAvailability: .missing)
        }

        var isStale = false

        do {
            let url = try URL(
                resolvingBookmarkData: fileBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                print("❌ Failed to access security-scoped resource: \(title)")
                return ResolveResult(
                    url: nil, refreshedBookmarkData: nil, newAvailability: .missing)
            }

            // If stale, try to refresh the bookmark
            var refreshedData: Data? = nil
            if isStale {
                print("⚠️ Track bookmark is stale, refreshing: \(title)")
                do {
                    refreshedData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                } catch {
                    print("⚠️ Failed to refresh bookmark: \(error)")
                    // File is accessible but bookmark couldn't be refreshed
                }
            }

            return ResolveResult(
                url: url,
                refreshedBookmarkData: refreshedData,
                newAvailability: isStale ? .stale : .available
            )

        } catch {
            print("❌ Failed to resolve bookmark for track \(title): \(error)")
            return ResolveResult(url: nil, refreshedBookmarkData: nil, newAvailability: .missing)
        }
    }

    /// Stop accessing the security-scoped resource.
    /// Call this when done using the file URL.
    func stopAccessingFile(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - Computed Properties

    /// Whether the track is currently playable.
    var isPlayable: Bool {
        availability != .missing
    }

    /// Drop heavyweight in-memory payloads once a track is removed from the library.
    func releaseTransientMediaResources() {
        artworkData = nil
        ttmlLyricText = nil
        lyricsText = nil
    }

    // MARK: - Persistence URL Resolution (root-snapshot aware)

    /// Resolve the track folder URL using the stored root snapshot.
    /// Falls back to the current active library root if no snapshot is stored.
    func resolvedTrackFolderURL() -> URL? {
        let root: URL
        if !libraryRootSnapshot.isEmpty {
            root = URL(fileURLWithPath: libraryRootSnapshot)
        } else {
            root = LocalLibraryPaths.libraryRootURL
        }
        return root.appendingPathComponent("Tracks", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func resolvedAudioURL() -> URL? {
        guard !audioFileName.isEmpty else {
            guard !libraryRelativePath.isEmpty else { return nil }
            return LocalLibraryPaths.libraryURL(from: libraryRelativePath)
        }
        return resolvedTrackFolderURL()?.appendingPathComponent(audioFileName)
    }

    func resolvedArtworkURL() -> URL? {
        guard let artworkFileName else { return nil }
        return resolvedTrackFolderURL()?.appendingPathComponent(artworkFileName)
    }

    func resolvedLyricsURL() -> URL? {
        guard let lyricsFileName else { return nil }
        return resolvedTrackFolderURL()?.appendingPathComponent(lyricsFileName)
    }

    func resolvedTTMLURL() -> URL? {
        guard let ttmlLyricsFileName else { return nil }
        return resolvedTrackFolderURL()?.appendingPathComponent(ttmlLyricsFileName)
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

        if looksLikeTTML(trimmed) {
            return Storage(ttmlText: trimmed, plainText: nil)
        }

        return Storage(ttmlText: nil, plainText: trimmed)
    }

    static func differs(from track: Track, editorText: String) -> Bool {
        let draft = storage(from: editorText)
        return draft.ttmlText != track.loadTTMLLyricsIfNeeded() || draft.plainText != track.loadLyricsIfNeeded()
    }

    static func assign(editorText: String, to track: Track) {
        let draft = storage(from: editorText)
        track.ttmlLyricText = draft.ttmlText
        track.lyricsText = draft.plainText
    }

    private static func looksLikeTTML(_ text: String) -> Bool {
        text.lowercased().contains("<tt")
    }
}
