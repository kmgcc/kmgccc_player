//
//  LDDCModels.swift
//  myPlayer2
//
//  kmgccc_player - LDDC Data Models
//  Models for LDDC lyrics search API responses.
//

import Foundation

// MARK: - API Models

/// Source platforms for lyrics search
enum LDDCSource: String, CaseIterable, Identifiable, Codable {
    case LRCLIB
    case QM
    case KG
    case NE

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .LRCLIB: return "LRCLIB"
        case .QM: return NSLocalizedString("search.lddc.qm", comment: "")
        case .KG: return NSLocalizedString("search.lddc.kg", comment: "")
        case .NE: return NSLocalizedString("search.lddc.ne", comment: "")
        }
    }
}

/// Lyrics mode - line-by-line or verbatim (word-by-word)
enum LDDCMode: String, CaseIterable, Identifiable, Codable {
    case line
    case verbatim

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .line: return NSLocalizedString("search.lddc.mode_line", comment: "")
        case .verbatim: return NSLocalizedString("search.lddc.mode_verbatim", comment: "")
        }
    }
}

/// A lyrics search result candidate from /search API
struct LDDCCandidate: Identifiable, Codable, Equatable {
    let source: String
    let songId: String
    let score: Double
    let title: String
    let artist: String?
    let album: String?
    let durationMs: Int?
    let extra: [String: String]?

    var id: String { "\(source)-\(songId)" }

    enum CodingKeys: String, CodingKey {
        case source
        case songId = "id"
        case score
        case title
        case artist
        case album
        case durationMs = "duration_ms"
        case extra
    }

    var sourceEnum: LDDCSource? {
        LDDCSource(rawValue: source)
    }
}

/// Response from /search API
struct LDDCSearchResponse: Codable {
    let results: [LDDCCandidate]
    let errors: [String]?
}

/// Response from /fetch_by_id API
struct LDDCFetchResponse: Codable {
    let lrc: String?
    let error: String?
}

/// Response from /fetch_by_id_separate API
struct LDDCFetchSeparateResponse: Codable {
    let lrcOrig: String?
    let lrcTrans: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case lrcOrig = "lrc_orig"
        case lrcTrans = "lrc_trans"
        case error
    }
}

// MARK: - Error Types

enum LDDCError: LocalizedError {
    case serverNotRunning
    case healthCheckFailed
    case startupFailed(String)
    case portUnavailable
    case requestFailed(String)
    case noResults
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return NSLocalizedString("error.lddc.not_running", comment: "")
        case .healthCheckFailed:
            return NSLocalizedString("error.lddc.health_failed", comment: "")
        case .startupFailed(let msg):
            return String(format: NSLocalizedString("error.lddc.startup_failed", comment: ""), msg)
        case .portUnavailable:
            return NSLocalizedString("error.lddc.port_failed", comment: "")
        case .requestFailed(let msg):
            return String(format: NSLocalizedString("error.lddc.request_failed", comment: ""), msg)
        case .noResults:
            return NSLocalizedString("search.lddc.not_found", comment: "")
        case .invalidResponse:
            return NSLocalizedString("error.lddc.invalid_resp", comment: "")
        }
    }
}
