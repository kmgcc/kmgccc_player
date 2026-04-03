//
//  AMLLDBService.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB Service
//  Manages local lyrics index cache and provides search functionality.
//

import Foundation
import SwiftData

/// Manages the AMLLDB lyrics index and provides search functionality.
/// Handles index updates, caching, and fuzzy searching.
@MainActor
final class AMLLDBService: ObservableObject {
    
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
    }
    
    // MARK: - Index Availability
    
    /// Checks if the local index is available (has entries).
    func isIndexAvailable() -> Bool {
        guard let context = modelContext else { return false }
        let descriptor = FetchDescriptor<AMLLDBIndexEntry>()
        return (try? context.fetchCount(descriptor)) ?? 0 > 0
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
        guard shouldUpdateIndex() else { return false }
        
        do {
            try await updateIndex()
            return true
        } catch {
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
            
            let indexData = try await client.downloadIndex()
            
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
            
        } catch {
            updateProgress = AMLLDBUpdateProgress(
                state: .failed(error.localizedDescription),
                currentItem: 0,
                totalItems: 0
            )
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
        
        // Parse and insert in batches
        let batchSize = 1000
        var currentBatch: [AMLLDBIndexEntry] = []
        
        for (index, line) in lines.enumerated() {
            if let entry = try? parseIndexLine(line) {
                currentBatch.append(entry)
                
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
    ///   - limit: Maximum number of results (default: 20)
    /// - Returns: Array of search results sorted by relevance
    func search(title: String, artist: String? = nil, limit: Int = 20) -> [AMLLDBSearchResult] {
        guard let context = modelContext else { return [] }
        
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        
        guard !normalizedTitle.isEmpty else { return [] }
        
        // Fetch all entries (for small index, in-memory filtering is faster)
        // For large indexes, use SwiftData predicates
        let descriptor = FetchDescriptor<AMLLDBIndexEntry>()
        guard let entries = try? context.fetch(descriptor) else { return [] }
        
        // Score and filter entries
        var results: [(entry: AMLLDBIndexEntry, score: Double)] = []
        
        for entry in entries {
            let score = calculateMatchScore(
                entry: entry,
                queryTitle: normalizedTitle,
                queryArtist: normalizedArtist
            )
            
            if score > 0 {
                results.append((entry, score))
            }
        }
        
        // Sort by score (descending) and limit results
        results.sort { $0.score > $1.score }
        
        return results.prefix(limit).map { pair in
            AMLLDBSearchResult(
                ncmMusicId: pair.entry.ncmMusicId,
                musicName: pair.entry.musicName,
                artists: pair.entry.artists,
                album: pair.entry.album,
                matchScore: pair.score
            )
        }
    }
    
    /// Calculates a match score for an entry against the query.
    private func calculateMatchScore(
        entry: AMLLDBIndexEntry,
        queryTitle: String,
        queryArtist: String
    ) -> Double {
        let entryTitle = entry.musicName.lowercased()
        let entryArtists = entry.artists.lowercased()
        
        var score: Double = 0
        
        // Title matching
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
        
        return score
    }
    
    // MARK: - Lyrics Download
    
    /// Downloads TTML lyrics for a specific song.
    /// - Parameter ncmMusicId: NetEase Cloud Music ID
    /// - Returns: TTML lyrics content
    func downloadLyrics(ncmMusicId: String) async throws -> String {
        try await client.downloadLyrics(ncmMusicId: ncmMusicId)
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
