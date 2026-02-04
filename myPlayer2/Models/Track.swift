//
//  Track.swift
//  myPlayer2
//
//  TrueMusic - SwiftData Track Model
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
    var duration: Double  // seconds
    var addedAt: Date

    // MARK: - File Access (security-scoped bookmark)

    /// Security-scoped bookmark data for the audio file.
    /// Used to regain access to the file after app restart (sandbox).
    var fileBookmarkData: Data

    /// Original file path (for display/debugging only - not for access!)
    var originalFilePath: String

    /// Availability status (updated on bookmark resolution).
    /// Stored as String for SwiftData compatibility.
    private var availabilityRaw: String

    var availability: TrackAvailability {
        get { TrackAvailability(rawValue: availabilityRaw) ?? .available }
        set { availabilityRaw = newValue.rawValue }
    }

    // MARK: - Artwork

    /// Embedded or user-edited cover art (JPEG/PNG data).
    @Attribute(.externalStorage)
    var artworkData: Data?

    // MARK: - Lyrics

    /// Directly pasted or imported TTML lyrics text (embedded).
    var ttmlLyricText: String?

    /// Imported lyrics text (LRC/TTML from external file).
    var lyricsText: String?

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "Unknown Artist",
        album: String = "Unknown Album",
        duration: Double = 0,
        addedAt: Date = Date(),
        fileBookmarkData: Data,
        originalFilePath: String = "",
        availability: TrackAvailability = .available,
        artworkData: Data? = nil,
        ttmlLyricText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.addedAt = addedAt
        self.fileBookmarkData = fileBookmarkData
        self.originalFilePath = originalFilePath
        self.availabilityRaw = availability.rawValue
        self.artworkData = artworkData
        self.ttmlLyricText = ttmlLyricText
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
}
