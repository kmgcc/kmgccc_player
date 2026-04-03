//
//  AMLLDBModels.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB Data Models
//  Search results and response models for AMLLDB integration.
//

import Foundation

// MARK: - Search Result

/// Represents a search result from AMLLDB.
/// Used to display search results in the UI and convert to LDDCCandidate for compatibility.
struct AMLLDBSearchResult: Identifiable, Codable, Equatable {
    
    /// NetEase Cloud Music ID
    let ncmMusicId: String
    
    /// Song title
    let musicName: String
    
    /// Artist name(s)
    let artists: String
    
    /// Album name
    let album: String
    
    /// Match score (0.0 - 1.0, higher is better)
    let matchScore: Double
    
    /// Unique identifier (same as ncmMusicId)
    var id: String { ncmMusicId }
    
    // MARK: - Conversion
    
    /// Converts this AMLLDB result to an LDDCCandidate for UI compatibility.
    /// This allows AMLLDB results to be displayed alongside LDDC results.
    func toLDDCCandidate() -> LDDCCandidate {
        LDDCCandidate(
            source: "AMLLDB",
            songId: ncmMusicId,
            score: matchScore,
            title: musicName,
            artist: artists,
            album: album,
            durationMs: nil,
            extra: [
                "platform": "ncm",
                "sourceType": "amll-db"
            ]
        )
    }
}

// MARK: - Update Progress

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

// MARK: - Index Entry (Raw)

/// Raw index entry structure as received from AMLLDB JSON Lines.
/// Used for parsing the index file.
struct AMLLDBRawIndexEntry: Codable {
    let metadata: [AMLMetadataPair]
    let rawLyricFile: String
    
    enum CodingKeys: String, CodingKey {
        case metadata
        case rawLyricFile = "rawLyricFile"
    }
}

struct AMLMetadataPair: Codable {
    let key: String
    let values: [String]
    
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        key = try container.decode(String.self)
        let valuesJson = try container.decode(String.self)
        let valuesData = valuesJson.data(using: .utf8)!
        values = try JSONDecoder().decode([String].self, from: valuesData)
    }
}

// MARK: - Metadata Parsing Helpers

extension AMLLDBRawIndexEntry {
    /// Extracts a string value from metadata by key.
    func stringValue(for key: String) -> String? {
        for pair in metadata where pair.key == key {
            return pair.values.first
        }
        return nil
    }
    
    /// Extracts array value from metadata by key.
    func arrayValue(for key: String) -> [String]? {
        for pair in metadata where pair.key == key {
            return pair.values
        }
        return nil
    }
}
