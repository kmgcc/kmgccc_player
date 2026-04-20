//
//  ExternalPlaybackMetadata.swift
//  myPlayer2
//
//  Raw/effective metadata and cache models for external playback sources.
//

import Foundation

struct ExternalPlaybackRawMetadata: Codable, Equatable, Sendable {
    var source: PlaybackSource
    var persistentID: String?
    var title: String
    var artist: String
    var album: String?
    var duration: Double

    var stableKey: String {
        if let persistentID, !persistentID.isEmpty {
            return "\(source.rawValue):pid:\(persistentID)"
        }
        let normalizedTitle = ExternalPlaybackTextNormalizer.normalizedKey(title)
        let normalizedArtist = ExternalPlaybackTextNormalizer.normalizedKey(artist)
        let durationBucket = Int((duration / 2).rounded()) * 2
        return "\(source.rawValue):meta:\(normalizedTitle)|\(normalizedArtist)|\(durationBucket)"
    }
}

struct ExternalPlaybackEffectiveMetadata: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
    var usesOverride: Bool
}

struct ExternalPlaybackMatchOverride: Codable, Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var manuallySelectedLyrics: String?
    var manuallySelectedLyricsSource: String?
    var updatedAt: Date

    var isEmpty: Bool {
        (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (manuallySelectedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var fingerprint: String {
        [
            title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].joined(separator: "|")
    }

    var manualLyricsFingerprint: String {
        let text = manuallySelectedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = manuallySelectedLyricsSource ?? ""
        return "\(text.count):\(text.hashValue):\(source)"
    }
}

struct ExternalPlaybackMatchResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case matched
        case noResult
        case lowConfidenceRejected
    }

    var status: Status
    var trackID: UUID?
    var confidence: Double
    var reason: String
}

struct ExternalPlaybackTrackCandidate: Sendable {
    var id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

struct ExternalPlaybackCacheRecord: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var stableKey: String
    var input: ExternalPlaybackRawMetadata
    var effective: ExternalPlaybackEffectiveMetadata
    var overrideFingerprint: String?
    var libraryFingerprint: String
    var matchResult: ExternalPlaybackMatchResult
    var artworkSource: String?
    var lyricsSource: String?
    var networkArtworkFileName: String?
    var networkLyrics: String?
    var manualLyricsFingerprint: String?
    var createdAt: Date
    var updatedAt: Date

    var isCurrentVersion: Bool {
        version == Self.currentVersion
    }
}

struct ExternalPlaybackResolution {
    var raw: ExternalPlaybackRawMetadata
    var effective: ExternalPlaybackEffectiveMetadata
    var stableKey: String
    var matchedTrack: Track?
    var matchResult: ExternalPlaybackMatchResult
    var cacheRecord: ExternalPlaybackCacheRecord
    var cacheHit: Bool
}
