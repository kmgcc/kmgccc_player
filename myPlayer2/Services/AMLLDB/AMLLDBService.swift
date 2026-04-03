//
//  AMLLDBService.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB Service
//  Manages local lyrics index cache and provides search functionality.
//

import Foundation
import SwiftData
import Combine
import os.log

/// Manages the AMLLDB lyrics index and provides search functionality.
/// Handles index updates, caching, and fuzzy searching.
@MainActor
final class AMLLDBService: ObservableObject {
    
    // MARK: - Logger
    private static let logger = Logger(subsystem: "com.kmgccc.player", category: "AMLLDB")
    
    // MARK: - Singleton
    
    static let shared = AMLLDBService()
    
    // MARK: - Published State
    
    /// Current update progress
    @Published private(set) var updateProgress: AMLLDBUpdateProgress = .initial
    
    /// Whether an update is currently in progress
    @Published private(set) var isUpdating = false
    
    // MARK: - Constants
    
    private let lastUpdateKey = "amll-db-last-update"
    private let updateInterval: TimeInterval = 86400 // 24 hours
    private let maxSearchResults = 50
    
    // MARK: - Dependencies
    
    private let client = AMLLDBClient()
    private var modelContext: ModelContext?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Model Context Setup
    
    func setupModelContext(_ context: ModelContext) {
        self.modelContext = context
        Self.logger.info("[AMLLDB] Model context initialized")
    }
    
    // MARK: - Index Availability
    
    /// Checks if the local index is available (has entries).
    func isIndexAvailable() -> Bool {
        guard let context = modelContext else {
            Self.logger.warning("[AMLLDB] isIndexAvailable: modelContext is nil")
            return false
        }
        let descriptor = FetchDescriptor<AMLLDBIndexEntry>()
        let count = (try? context.fetchCount(descriptor)) ?? 0
        Self.logger.info("[AMLLDB] Index available: \(count > 0), entries: \(count)")
        return count > 0
    }
    
    /// Returns the number of entries in the local index.
    func getIndexEntryCount() -> Int {
        guard let context = modelContext else { return 0 }
        let descriptor = FetchDescriptor<AMLLDBIndexEntry>()
        return (try? context.fetchCount(descriptor)) ?? 0
    }
    
    /// Returns the timestamp of the last successful update.
    func getLastUpdateTime() -> Date? {
        UserDefaults.standard.object(forKey: lastUpdateKey) as? Date
    }
    
    /// Checks if the index should be updated (never updated or > 24 hours).
    func shouldUpdateIndex() -> Bool {
        guard let lastUpdate = getLastUpdateTime() else { return true }
        return Date().timeIntervalSince(lastUpdate) > updateInterval
    }
    
    // MARK: - Index Update
    
    /// Checks if update is needed and performs update if necessary.
    /// - Returns: True if an update was performed
    @discardableResult
    func checkAndUpdateIfNeeded() async -> Bool {
        guard shouldUpdateIndex() else {
            Self.logger.info("[AMLLDB] Index up to date, skipping update")
            return false
        }
        
        do {
            Self.logger.info("[AMLLDB] Starting index update...")
            try await updateIndex()
            return true
        } catch {
            Self.logger.error("[AMLLDB] Index update failed: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Updates the local index by downloading and parsing the latest data.
    func updateIndex() async throws {
        guard !isUpdating else { return }
        
        isUpdating = true
        defer { isUpdating = false }
        
        updateProgress = .initial
        
        do {
            updateProgress = AMLLDBUpdateProgress(
                state: .downloading(progress: 0),
                currentItem: 0,
                totalItems: 0
            )
            
            Self.logger.info("[AMLLDB] Downloading index...")
            let indexData = try await client.downloadIndex()
            Self.logger.info("[AMLLDB] Downloaded \(indexData.count) bytes")
            
            updateProgress = AMLLDBUpdateProgress(
                state: .parsing,
                currentItem: 0,
                totalItems: 0
            )
            
            try await parseAndStoreIndex(data: indexData)
            
            UserDefaults.standard.set(Date(), forKey: lastUpdateKey)
            
            updateProgress = AMLLDBUpdateProgress(
                state: .completed,
                currentItem: getIndexEntryCount(),
                totalItems: getIndexEntryCount()
            )
            
            Self.logger.info("[AMLLDB] Index update completed, total entries: \(self.getIndexEntryCount())")
            
        } catch {
            updateProgress = AMLLDBUpdateProgress(
                state: .failed(error.localizedDescription),
                currentItem: 0,
                totalItems: 0
            )
            Self.logger.error("[AMLLDB] Update failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Parses index data and stores entries in SwiftData.
    private func parseAndStoreIndex(data: Data) async throws {
        guard let context = modelContext else {
            throw AMLLDBError.storageError("Model context not initialized")
        }
        
        // Clear existing index
        try await clearIndex()
        
        // Parse JSON Lines
        guard let text = String(data: data, encoding: .utf8) else {
            throw AMLLDBError.parseError("Invalid UTF-8 encoding")
        }
        
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let totalLines = lines.count
        Self.logger.info("[AMLLDB] Parsing \(totalLines) index entries...")
        
        // Parse and insert in batches
        let batchSize = 1000
        var currentBatch: [AMLLDBIndexEntry] = []
        var parsedCount = 0
        
        for (index, line) in lines.enumerated() {
            if let entry = try? parseIndexLine(line) {
                currentBatch.append(entry)
                parsedCount += 1
                
                if currentBatch.count >= batchSize {
                    try insertBatch(currentBatch, context: context)
                    currentBatch.removeAll(keepingCapacity: true)
                }
            }
            
            // Update progress every 1000 items
            if index % 1000 == 0 {
                updateProgress = AMLLDBUpdateProgress(
                    state: .parsing,
                    currentItem: index,
                    totalItems: totalLines
                )
            }
        }
        
        // Insert remaining batch
        if !currentBatch.isEmpty {
            try insertBatch(currentBatch, context: context)
        }
        
        Self.logger.info("[AMLLDB] Parsed and stored \(parsedCount) entries")
    }
    
    /// Parses a single JSON line from the index file.
    private func parseIndexLine(_ line: String) throws -> AMLLDBIndexEntry? {
        guard let data = line.data(using: .utf8) else { return nil }
        
        let rawEntry = try JSONDecoder().decode(AMLLDBRawIndexEntry.self, from: data)
        
        guard let ncmId = rawEntry.stringValue(for: "ncmMusicId"),
              let musicName = rawEntry.stringValue(for: "musicName"),
              let artists = rawEntry.stringValue(for: "artists") else {
            return nil
        }
        
        let album = rawEntry.stringValue(for: "album") ?? ""
        
        return AMLLDBIndexEntry(
            ncmMusicId: ncmId,
            musicName: musicName,
            artists: artists,
            album: album,
            rawLyricFile: rawEntry.rawLyricFile
        )
    }
    
    /// Inserts a batch of entries into SwiftData.
    private func insertBatch(_ entries: [AMLLDBIndexEntry], context: ModelContext) throws {
        for entry in entries {
            context.insert(entry)
        }
        try context.save()
    }
    
    /// Clears all index entries from the local database.
    func clearIndex() async throws {
        guard let context = modelContext else { return }
        
        let descriptor = FetchDescriptor<AMLLDBIndexEntry>()
        let entries = try context.fetch(descriptor)
        
        for entry in entries {
            context.delete(entry)
        }
        
        try context.save()
    }
    
    // MARK: - Search
    
    /// Searches the local index for matching songs.
    /// - Parameters:
    ///   - title: Song title to search for
    ///   - artist: Artist name to search for (optional)
    ///   - album: Album name to search for (optional, for better matching)
    ///   - duration: Track duration in seconds (optional, for better matching)
    ///   - limit: Maximum number of results (default: 20)
    /// - Returns: Array of search results sorted by relevance
    func search(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        limit: Int = 20
    ) -> [AMLLDBSearchResult] {
        Self.logger.info("[AMLLDB] Search starting - title: '\(title)', artist: '\(artist ?? "nil")'")
        
        guard let context = modelContext else {
            Self.logger.error("[AMLLDB] Search failed: modelContext is nil")
            return []
        }
        
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        
        guard !normalizedTitle.isEmpty else {
            Self.logger.warning("[AMLLDB] Search failed: empty title")
            return []
        }
        
        // Fetch all entries
        let descriptor = FetchDescriptor<AMLLDBIndexEntry>()
        guard let entries = try? context.fetch(descriptor) else {
            Self.logger.error("[AMLLDB] Search failed: could not fetch from SwiftData")
            return []
        }
        
        Self.logger.info("[AMLLDB] Fetched \(entries.count) entries from local index")
        
        // Score and filter entries
        var results: [(entry: AMLLDBIndexEntry, score: Double)] = []
        
        for entry in entries {
            let score = calculateMatchScore(
                entry: entry,
                queryTitle: normalizedTitle,
                queryArtist: normalizedArtist,
                queryAlbum: normalizedAlbum,
                queryDuration: duration
            )
            
            if score > 0 {
                results.append((entry, score))
            }
        }
        
        Self.logger.info("[AMLLDB] Matched \(results.count) entries")
        
        // Sort by score (descending) and limit results
        results.sort { $0.score > $1.score }
        
        let limitedResults = results.prefix(limit).map { pair in
            AMLLDBSearchResult(
                ncmMusicId: pair.entry.ncmMusicId,
                musicName: pair.entry.musicName,
                artists: pair.entry.artists,
                album: pair.entry.album,
                matchScore: pair.score
            )
        }
        
        Self.logger.info("[AMLLDB] Returning \(limitedResults.count) results")
        return limitedResults
    }
    
    /// Calculates a match score for an entry against the query.
    private func calculateMatchScore(
        entry: AMLLDBIndexEntry,
        queryTitle: String,
        queryArtist: String,
        queryAlbum: String,
        queryDuration: Double?
    ) -> Double {
        let entryTitle = entry.musicName.lowercased()
        let entryArtists = entry.artists.lowercased()
        let entryAlbum = entry.album.lowercased()
        
        var score: Double = 0
        
        // Title matching (most important)
        if entryTitle == queryTitle {
            score += 1.0 // Exact match
        } else if entryTitle.hasPrefix(queryTitle) {
            score += 0.8 // Prefix match
        } else if entryTitle.contains(queryTitle) {
            score += 0.6 // Contains match
        }
        
        // Artist matching (if provided)
        if !queryArtist.isEmpty {
            if entryArtists == queryArtist {
                score += 0.5 // Exact artist match
            } else if entryArtists.contains(queryArtist) {
                score += 0.3 // Artist contains query
            }
        }
        
        // Album matching (if provided, bonus)
        if !queryAlbum.isEmpty && entryAlbum.contains(queryAlbum) {
            score += 0.1 // Album bonus
        }
        
        return score
    }
    
    // MARK: - Lyrics Download
    
    /// Downloads TTML lyrics for a specific song.
    /// - Parameter ncmMusicId: NetEase Cloud Music ID
    /// - Returns: TTML lyrics content
    func downloadLyrics(ncmMusicId: String) async throws -> String {
        Self.logger.info("[AMLLDB] Downloading lyrics for ID: \(ncmMusicId)")
        let ttml = try await client.downloadLyrics(ncmMusicId: ncmMusicId)
        Self.logger.info("[AMLLDB] Downloaded \(ttml.count) bytes of TTML")
        return ttml
    }
    
    // MARK: - Cache Management
    
    /// Returns the approximate cache size in bytes.
    func getCacheSize() async -> Int64 {
        // SwiftData storage size estimation
        let entryCount = getIndexEntryCount()
        // Rough estimate: ~200 bytes per entry
        return Int64(entryCount * 200)
    }
}
