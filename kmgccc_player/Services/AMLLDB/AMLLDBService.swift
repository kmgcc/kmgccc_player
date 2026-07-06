//
//  AMLLDBService.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB Service
//  Main service for AMLLDB lyrics search and download.
//  Uses file-based index cache for reliable search availability.
//

import Foundation
import SwiftData
import Combine
import os.log

/// Main service for AMLLDB lyrics operations.
/// Provides search and download functionality using the raw index cache.
@MainActor
final class AMLLDBService: ObservableObject {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.kmgccc.player", category: "AMLLDB")

    // MARK: - Singleton

    static let shared = AMLLDBService()

    // MARK: - Published State

    /// Whether AMLLDB is ready for search
    @Published private(set) var isReady = false

    /// Number of entries available
    @Published private(set) var entryCount = 0

    /// Last error message
    @Published private(set) var lastError: String?

    /// Whether currently initializing
    @Published private(set) var isInitializing = false

    // MARK: - Dependencies

    private let cache = AMLLDBRawIndexCache.shared
    private let client = AMLLDBClient()

    // MARK: - Initialization

    private init() {
        // Observe cache state
        Task {
            await observeCacheState()
        }
    }

    // MARK: - Setup

    /// Setup with SwiftData context (optional, for backward compatibility)
    func setupModelContext(_ context: ModelContext) {
        Self.logger.info("[AMLLDB] Model context setup (SwiftData is optional storage)")
        // We don't require SwiftData for search anymore
        // But we keep this for backward compatibility
    }

    // MARK: - Index Availability

    /// Check if index is available (either from cache or SwiftData)
    func getIndexStatus() -> AMLLDBIndexStatus {
        let hasCache = cache.hasLocalCache()
        let cacheReady = cache.isReady
        let count = cache.entryCount

        Self.logger.info("[AMLLDB] Index status: hasCache=\(hasCache), isReady=\(cacheReady), count=\(count)")

        return AMLLDBIndexStatus(
            available: cacheReady || hasCache,
            entryCount: count,
            lastUpdatedAt: nil, // Not tracked at service level anymore
            needsUpdate: false,
            isCorruptedOrEmpty: !hasCache && !cacheReady,
            reason: cacheReady ? "ready" : (hasCache ? "cache exists" : "no cache")
        )
    }

    /// Ensure index is ready for search
    func ensureIndexReady() async -> Bool {
        Self.logger.info("[AMLLDB] Ensuring index ready...")

        isInitializing = true
        defer { isInitializing = false }

        let ready = await cache.ensureReady()
        isReady = ready
        entryCount = cache.entryCount

        if !ready {
            lastError = cache.lastError
        }

        Self.logger.info("[AMLLDB] Index ready: \(ready), entries: \(self.entryCount)")
        return ready
    }

    // MARK: - Search

    /// Search for lyrics by track info
    /// - Parameters:
    ///   - title: Song title
    ///   - artist: Artist name (optional)
    ///   - album: Album name (optional)
    ///   - duration: Duration in seconds (optional)
    ///   - limit: Maximum results (default 20)
    /// - Returns: Array of search results
    func search(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        limit: Int = 20
    ) -> [AMLLDBSearchResult] {
        Self.logger.debug("[AMLLDB] Search called - title: '\(title)', artist: '\(artist ?? "nil")', album: '\(album ?? "nil")'")

        // Ensure we have entries
        let entries = cache.getEntries()
        if entries.isEmpty {
            Self.logger.warning("[AMLLDB] No entries available for search")
            return []
        }

        Self.logger.debug("[AMLLDB] Searching \(entries.count) entries")

        // Prepare search params
        let artists: [String] = artist.map { [$0] } ?? []
        let durationMs = duration.map { Int($0 * 1000) }

        let params = AMLLDBSearchParams(
            title: title,
            artists: artists,
            album: album,
            durationMs: durationMs
        )

        // Perform search
        let candidates = AMLLDBSearcher.search(entries: entries, params: params)

        Self.logger.debug("[AMLLDB] Search returned \(candidates.count) results")

        // Convert to result format
        return candidates.prefix(limit).map { candidate in
            AMLLDBSearchResult(
                rawLyricFile: candidate.entry.rawLyricFile,
                musicName: candidate.bestTitle,
                artists: candidate.displayArtists,
                album: candidate.displayAlbum,
                matchScore: candidate.totalScore,
                matchLevel: candidate.matchLevel,
                ncmMusicId: candidate.entry.ncmMusicId,
                qqMusicId: candidate.entry.qqMusicId,
                appleMusicId: candidate.entry.appleMusicId
            )
        }
    }

    // MARK: - Lyrics Download

    /// Download TTML lyrics by raw lyric file name
    /// - Parameter rawLyricFile: The raw lyric file name
    /// - Returns: TTML lyrics content
    func downloadLyricsByRawFile(_ rawLyricFile: String) async throws -> String {
        Self.logger.info("[AMLLDB] Downloading lyrics via rawLyricFile: \(rawLyricFile)")
        return try await client.downloadLyricsByRawFile(rawLyricFile)
    }

    /// Download TTML lyrics by NCM ID (legacy method)
    /// - Parameter ncmMusicId: NetEase Cloud Music ID
    /// - Returns: TTML lyrics content
    func downloadLyrics(ncmMusicId: String) async throws -> String {
        Self.logger.info("[AMLLDB] Downloading lyrics for NCM ID: \(ncmMusicId)")
        return try await client.downloadLyrics(ncmMusicId: ncmMusicId)
    }

    // MARK: - Index Management

    /// Check and update index if needed
    @discardableResult
    func checkAndUpdateIfNeeded(forceRebuild: Bool = false) async throws -> AMLLDBIndexStatus {
        Self.logger.info("[AMLLDB] checkAndUpdateIfNeeded called, force=\(forceRebuild)")

        if forceRebuild {
            let success = await cache.refreshIndex()
            isReady = success
            entryCount = cache.entryCount
        } else {
            let ready = await cache.ensureReady()
            isReady = ready
            entryCount = cache.entryCount
        }

        return getIndexStatus()
    }

    /// Clear all cached data
    func clearIndex() async throws {
        try cache.clearCache()
        isReady = false
        entryCount = 0
    }

    // MARK: - Backward Compatibility

    /// Backwards-compatible check
    func isIndexAvailable() -> Bool {
        cache.isReady || cache.hasLocalCache()
    }

    /// Get entry count
    func getIndexEntryCount() -> Int {
        cache.entryCount
    }

    /// Get last update time (not used in new implementation)
    func getLastUpdateTime() -> Date? {
        nil
    }

    /// Check if update is needed
    func shouldUpdateIndex() -> Bool {
        !cache.isReady && !cache.hasLocalCache()
    }

    // MARK: - Private

    private func observeCacheState() async {
        // Periodically sync state with cache
        while true {
            await Task.yield()

            isReady = cache.isReady
            entryCount = cache.entryCount

            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// MARK: - Result Model

/// AMLLDB search result for UI display
struct AMLLDBSearchResult: Identifiable, Equatable {
    let id: String // rawLyricFile
    let rawLyricFile: String
    let musicName: String
    let artists: String
    let album: String
    let matchScore: Double
    let matchLevel: AMLLDBMatchLevel
    let ncmMusicId: String?
    let qqMusicId: String?
    let appleMusicId: String?

    init(
        rawLyricFile: String,
        musicName: String,
        artists: String,
        album: String,
        matchScore: Double,
        matchLevel: AMLLDBMatchLevel,
        ncmMusicId: String?,
        qqMusicId: String?,
        appleMusicId: String?
    ) {
        self.id = rawLyricFile
        self.rawLyricFile = rawLyricFile
        self.musicName = musicName
        self.artists = artists
        self.album = album
        self.matchScore = matchScore
        self.matchLevel = matchLevel
        self.ncmMusicId = ncmMusicId
        self.qqMusicId = qqMusicId
        self.appleMusicId = appleMusicId
    }

    /// Convert to LDDCCandidate for UI compatibility
    func toLDDCCandidate() -> LDDCCandidate {
        LDDCCandidate(
            source: "AMLLDB",
            songId: rawLyricFile, // Use rawLyricFile as songId for download
            score: matchScore,
            title: musicName,
            artist: artists,
            album: album,
            durationMs: nil,
            extra: [
                "platform": "amll-db",
                "sourceType": "amll-ttml-database",
                "ncmMusicId": ncmMusicId ?? "",
                "matchLevel": matchLevel.rawValue
            ]
        )
    }
}

// MARK: - Index Status

struct AMLLDBIndexStatus: Equatable {
    let available: Bool
    let entryCount: Int
    let lastUpdatedAt: Date?
    let needsUpdate: Bool
    let isCorruptedOrEmpty: Bool
    let reason: String

    var hasIndexData: Bool {
        available && entryCount > 0
    }
}