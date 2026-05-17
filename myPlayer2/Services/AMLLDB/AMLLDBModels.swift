//
//  AMLLDBModels.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB Data Models
//  Search results and response models for AMLLDB integration.
//

import Foundation

// MARK: - Update Progress (kept for backward compatibility)

/// Represents the current state of an index update operation.
enum AMLLDBUpdateState: Equatable {
    case checking       // Checking if update is needed
    case downloading(progress: Double)  // Downloading index file
    case parsing        // Parsing JSON Lines
    case completed      // Update completed successfully
    case failed(String) // Update failed with error message

    var description: String {
        switch self {
        case .checking:
            return "检查更新..."
        case .downloading:
            return "正在下载索引..."
        case .parsing:
            return "正在解析数据..."
        case .completed:
            return "更新完成"
        case .failed(let msg):
            return "更新失败: \(msg)"
        }
    }
}

/// Progress information for index updates.
struct AMLLDBUpdateProgress: Equatable {
    let state: AMLLDBUpdateState
    let currentItem: Int
    let totalItems: Int

    var progressPercentage: Double {
        guard totalItems > 0 else { return 0 }
        return Double(currentItem) / Double(totalItems)
    }

    static let initial = AMLLDBUpdateProgress(
        state: .checking,
        currentItem: 0,
        totalItems: 0
    )
}

// MARK: - Update Error

enum AMLLDBUpdateError: LocalizedError {
    case download(String)
    case parse(String)
    case storage(String)
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .download(let message):
            return "AMLLDB 索引下载失败: \(message)"
        case .parse(let message):
            return "AMLLDB 索引解析失败: \(message)"
        case .storage(let message):
            return "AMLLDB 索引存储失败: \(message)"
        case .validation(let message):
            return "AMLLDB 索引校验失败: \(message)"
        }
    }

    var logStage: String {
        switch self {
        case .download:
            return "download failed"
        case .parse:
            return "parse failed"
        case .storage:
            return "storage failed"
        case .validation:
            return "validation failed"
        }
    }
}

// MARK: - Update Reason

enum AMLLDBUpdateReason: String {
    case emptyIndex
    case expired
    case forcedRebuild
    case corruptedStore
    case missingLastUpdatedAt

    var logDescription: String {
        switch self {
        case .emptyIndex:
            return "empty index"
        case .expired:
            return "expired"
        case .forcedRebuild:
            return "forced rebuild"
        case .corruptedStore:
            return "corrupted store"
        case .missingLastUpdatedAt:
            return "missing lastUpdatedAt"
        }
    }
}

// MARK: - Raw JSONL Entry

/// Raw JSONL entry format where metadata is array of key-value pairs
nonisolated struct AMLLDBJsonlRawEntry: Decodable, Sendable {
    nonisolated struct MetadataPair: Decodable, Sendable {
        let key: String
        let values: [String]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            key = try container.decode(String.self)
            values = try container.decode([String].self)
        }
    }

    let metadata: [MetadataPair]
    let rawLyricFile: String

    /// Convert to AMLLDBRawIndexEntry
    nonisolated func toIndexEntry() -> AMLLDBRawIndexEntry? {
        // Extract values from metadata pairs
        func getValue(key: String) -> String? {
            metadata.first(where: { $0.key == key })?.values.first
        }

        func getValues(key: String) -> [String] {
            metadata.first(where: { $0.key == key })?.values ?? []
        }

        func getIntValue(key: String) -> Int? {
            getValue(key: key).flatMap { Int($0) }
        }

        // Require at least one title
        let titles = getValues(key: "musicName").isEmpty
            ? getValues(key: "titles")
            : getValues(key: "musicName")

        guard !titles.isEmpty else {
            return nil
        }

        return AMLLDBRawIndexEntry(
            titles: titles,
            artists: getValues(key: "artists"),
            albums: getValues(key: "album"),
            ncmMusicId: getValue(key: "ncmMusicId"),
            qqMusicId: getValue(key: "qqMusicId"),
            appleMusicId: getValue(key: "appleMusicId"),
            spotifyId: getValue(key: "spotifyId"),
            rawLyricFile: rawLyricFile,
            durationMs: getIntValue(key: "duration")
        )
    }
}

// MARK: - Raw Index Entry

/// Represents a raw entry from AMLLDB's raw-lyrics-index.jsonl file.
/// This is the primary data structure for in-memory search.
nonisolated struct AMLLDBRawIndexEntry: Equatable, Sendable {

    /// Song titles (may have multiple variants)
    let titles: [String]

    /// Primary song name (first title)
    var musicName: String {
        titles.first ?? ""
    }

    /// Artist names
    let artists: [String]

    /// Album names (may have multiple)
    let albums: [String]

    /// Primary album name
    var album: String {
        albums.first ?? ""
    }

    /// NetEase Cloud Music ID
    let ncmMusicId: String?

    /// QQ Music ID
    let qqMusicId: String?

    /// Apple Music ID
    let appleMusicId: String?

    /// Spotify ID
    let spotifyId: String?

    /// Raw lyric file name for TTML download
    let rawLyricFile: String

    /// Duration in milliseconds (if available)
    let durationMs: Int?

    init(
        titles: [String],
        artists: [String],
        albums: [String],
        ncmMusicId: String?,
        qqMusicId: String?,
        appleMusicId: String?,
        spotifyId: String?,
        rawLyricFile: String,
        durationMs: Int?
    ) {
        self.titles = titles
        self.artists = artists
        self.albums = albums
        self.ncmMusicId = ncmMusicId
        self.qqMusicId = qqMusicId
        self.appleMusicId = appleMusicId
        self.spotifyId = spotifyId
        self.rawLyricFile = rawLyricFile
        self.durationMs = durationMs
    }

    /// All searchable title variants (normalized)
    var searchableTitles: [String] {
        titles.map { AMLLDBTitleNormalizer.normalize($0) }
    }

    /// Titles with version suffixes stripped
    var strippedTitles: [String] {
        titles.map { AMLLDBTitleNormalizer.stripVersionSuffix($0) }
    }

    /// Check if entry has any platform ID for deduplication
    var hasPlatformId: Bool {
        ncmMusicId != nil || qqMusicId != nil || appleMusicId != nil || spotifyId != nil
    }

    /// Primary platform ID for deduplication (prefer NCM)
    var primaryPlatformId: String? {
        ncmMusicId ?? qqMusicId ?? appleMusicId ?? spotifyId
    }

    /// Combined artists string for display
    var artistsDisplay: String {
        artists.joined(separator: " / ")
    }
}

// MARK: - Search Candidate

/// Represents a scored candidate during AMLLDB search
struct AMLLDBSearchCandidate: Identifiable, Equatable {
    let id: String // rawLyricFile as unique ID
    let entry: AMLLDBRawIndexEntry
    let matchScore: AMLLDBMatchScore

    var bestTitle: String {
        entry.musicName
    }

    var displayArtists: String {
        entry.artistsDisplay
    }

    var displayAlbum: String {
        entry.album
    }

    var totalScore: Double {
        matchScore.totalScore
    }

    var matchLevel: AMLLDBMatchLevel {
        matchScore.level
    }
}

// MARK: - Match Score

/// Multi-dimensional match score for AMLLDB search results
struct AMLLDBMatchScore: Equatable {
    let titleScore: Double      // 0.0 - 1.0, weight 50%
    let artistScore: Double     // 0.0 - 1.0, weight 30%
    let durationScore: Double   // 0.0 - 1.0, weight 15%
    let albumScore: Double      // 0.0 - 1.0, weight 5%

    var totalScore: Double {
        let hasDuration = durationScore > 0
        let hasAlbum = albumScore > 0

        var weights: [Double] = [0.5, 0.3]
        var scores: [Double] = [titleScore, artistScore]

        if hasDuration {
            weights.append(0.15)
            scores.append(durationScore)
        }

        if hasAlbum {
            weights.append(0.05)
            scores.append(albumScore)
        }

        let totalWeight = weights.reduce(0, +)
        let weightedSum = zip(weights, scores).map { w, s in w * s }.reduce(0, +)

        return totalWeight > 0 ? weightedSum / totalWeight : 0
    }

    var level: AMLLDBMatchLevel {
        if totalScore >= 0.95 { return .perfect }
        if totalScore >= 0.85 { return .veryHigh }
        if totalScore >= 0.70 { return .high }
        if totalScore >= 0.50 { return .medium }
        if totalScore >= 0.30 { return .low }
        return .none
    }

    init(titleScore: Double, artistScore: Double, durationScore: Double = 0, albumScore: Double = 0) {
        self.titleScore = min(1.0, max(0.0, titleScore))
        self.artistScore = min(1.0, max(0.0, artistScore))
        self.durationScore = min(1.0, max(0.0, durationScore))
        self.albumScore = min(1.0, max(0.0, albumScore))
    }
}

// MARK: - Match Level

enum AMLLDBMatchLevel: String, Equatable {
    case perfect = "Perfect"
    case veryHigh = "VeryHigh"
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    case none = "None"

    var displayColor: String {
        switch self {
        case .perfect, .veryHigh: return "green"
        case .high: return "blue"
        case .medium: return "yellow"
        case .low: return "orange"
        case .none: return "red"
        }
    }
}

// MARK: - Search Params

/// AMLLDB search input parameters
struct AMLLDBSearchParams: Equatable {
    let title: String
    let artists: [String]
    let album: String?
    let durationMs: Int?

    init(title: String, artists: [String] = [], album: String? = nil, durationMs: Int? = nil) {
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMs = durationMs
    }
}
