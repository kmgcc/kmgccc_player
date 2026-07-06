//
//  AMLLDBClient.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB HTTP API Client
//  Downloads lyrics index and TTML files from AMLLDB GitHub repository.
//

import Foundation
import os.log

/// HTTP client for AMLLDB lyrics database.
/// Downloads index files and TTML lyrics from GitHub raw content.
actor AMLLDBClient {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.kmgccc.player", category: "AMLLDB")

    // MARK: - Constants

    /// GitHub raw content base URL for AMLLDB repository
    private let baseURL = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main"

    /// URL for the lyrics index file (JSON Lines format)
    var indexURL: URL {
        URL(string: "\(baseURL)/metadata/raw-lyrics-index.jsonl")!
    }

    /// Timeout for index download (60 seconds for ~10MB file)
    private let indexDownloadTimeout: TimeInterval = 60

    /// Timeout for individual lyrics download (10 seconds)
    private let lyricsDownloadTimeout: TimeInterval = 10

    // MARK: - URLSession

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Downloads the AMLLDB lyrics index file.
    /// - Returns: Raw Data containing JSON Lines format index
    /// - Throws: Network errors, timeout errors
    func downloadIndex() async throws -> Data {
        Self.logger.info("[AMLLDB] Downloading index from \(self.indexURL.absoluteString)")

        let request = URLRequest(
            url: indexURL,
            timeoutInterval: indexDownloadTimeout
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AMLLDBError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw AMLLDBError.networkError("HTTP \(httpResponse.statusCode)")
        }

        Self.logger.info("[AMLLDB] Index download complete: \(data.count) bytes")
        return data
    }

    /// Downloads a specific TTML lyrics file by raw lyric file name.
    /// This is the preferred method for downloading AMLLDB lyrics.
    /// - Parameter rawLyricFile: The raw lyric file name (e.g., "1740814274356-146098469-efb9e56e.ttml")
    /// - Returns: TTML lyrics content as String
    /// - Throws: Network errors, not found errors
    func downloadLyricsByRawFile(_ rawLyricFile: String) async throws -> String {
        let lyricsURL = URL(string: "\(baseURL)/raw-lyrics/\(rawLyricFile)")!

        Self.logger.info("[AMLLDB] Fetching raw lyric file: \(rawLyricFile)")
        Self.logger.info("[AMLLDB] URL: \(lyricsURL.absoluteString)")

        let request = URLRequest(
            url: lyricsURL,
            timeoutInterval: lyricsDownloadTimeout
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AMLLDBError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            guard let ttml = String(data: data, encoding: .utf8) else {
                throw AMLLDBError.parseError("Invalid UTF-8 encoding")
            }
            Self.logger.info("[AMLLDB] TTML download success: \(ttml.count) bytes")
            return ttml

        case 404:
            Self.logger.error("[AMLLDB] TTML download failed: 404 Not Found")
            throw AMLLDBError.notFound("Lyrics not found: \(rawLyricFile)")

        default:
            Self.logger.error("[AMLLDB] TTML download failed: HTTP \(httpResponse.statusCode)")
            throw AMLLDBError.networkError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Downloads a specific TTML lyrics file by NetEase Cloud Music ID.
    /// Legacy method - prefer downloadLyricsByRawFile instead.
    /// - Parameter ncmMusicId: The NetEase Cloud Music song ID
    /// - Returns: TTML lyrics content as String
    /// - Throws: Network errors, not found errors
    func downloadLyrics(ncmMusicId: String) async throws -> String {
        let lyricsURL = URL(string: "\(baseURL)/ncm-lyrics/\(ncmMusicId).ttml")!

        Self.logger.info("[AMLLDB] Downloading lyrics for NCM ID: \(ncmMusicId)")

        let request = URLRequest(
            url: lyricsURL,
            timeoutInterval: lyricsDownloadTimeout
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AMLLDBError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            guard let ttml = String(data: data, encoding: .utf8) else {
                throw AMLLDBError.parseError("Invalid UTF-8 encoding")
            }
            Self.logger.info("[AMLLDB] Downloaded \(ttml.count) bytes of TTML")
            return ttml

        case 404:
            throw AMLLDBError.notFound("Lyrics not found for ID: \(ncmMusicId)")

        default:
            throw AMLLDBError.networkError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Checks if the AMLLDB index is accessible.
    /// - Returns: True if index URL returns 200
    func checkIndexAvailability() async -> Bool {
        var request = URLRequest(url: indexURL)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Errors

enum AMLLDBError: LocalizedError {
    case networkError(String)
    case parseError(String)
    case storageError(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg):
            return "网络错误: \(msg)"
        case .parseError(let msg):
            return "解析错误: \(msg)"
        case .storageError(let msg):
            return "存储错误: \(msg)"
        case .notFound(let msg):
            return "未找到: \(msg)"
        }
    }
}
