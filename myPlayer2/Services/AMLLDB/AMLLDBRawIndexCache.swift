//
//  AMLLDBRawIndexCache.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB Raw Index Cache Manager
//  Manages downloading, caching, and parsing raw-lyrics-index.jsonl
//

import Combine
import Foundation
import os.log

/// Manages the AMLLDB raw lyrics index file.
/// Downloads, caches to disk, and parses into memory for search.
@MainActor
final class AMLLDBRawIndexCache: ObservableObject {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.kmgccc.player", category: "AMLLDB")

    // MARK: - Singleton

    static let shared = AMLLDBRawIndexCache()

    // MARK: - Published State

    /// Whether index is ready for search
    @Published private(set) var isReady = false

    /// Number of entries loaded
    @Published private(set) var entryCount = 0

    /// Last error message if any
    @Published private(set) var lastError: String?

    /// Whether currently downloading
    @Published private(set) var isDownloading = false

    /// Download progress (0.0 - 1.0)
    @Published private(set) var downloadProgress: Double = 0

    // MARK: - Constants

    /// Index file URL
    private let indexURL: URL = URL(
        string: "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl"
    )!

    /// Local cache directory
    private var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("AMLLDB", isDirectory: true)
    }

    /// Local index file path
    private var localIndexURL: URL {
        cacheDirectory.appendingPathComponent("raw-lyrics-index.jsonl")
    }

    /// Last update timestamp file
    private var lastUpdateFileURL: URL {
        cacheDirectory.appendingPathComponent("last_update.txt")
    }

    /// Update interval: 24 hours
    private let updateInterval: TimeInterval = 86400

    // MARK: - Private State

    /// In-memory parsed entries
    private var entries: [AMLLDBRawIndexEntry] = []

    /// URL session for downloads
    private let session: URLSession

    /// Background update task
    private var updateTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Check if local cache exists
    func hasLocalCache() -> Bool {
        FileManager.default.fileExists(atPath: localIndexURL.path)
    }

    /// Get cached entries (loads from disk if needed)
    func getEntries() -> [AMLLDBRawIndexEntry] {
        if entries.isEmpty && hasLocalCache() {
            Task {
                await loadFromCache()
            }
        }
        return entries
    }

    /// Ensure index is ready for search
    /// - Returns: true if index is ready (either from cache or downloaded)
    @discardableResult
    func ensureReady() async -> Bool {
        // Already ready
        if isReady && !entries.isEmpty {
            Self.logger.info("[AMLLDB] Index already ready with \(self.entries.count) entries")
            return true
        }

        // Try loading from cache first
        if hasLocalCache() {
            Self.logger.info("[AMLLDB] Local cache exists, loading...")
            if await loadFromCache() {
                // Start background update check
                startBackgroundUpdateCheck()
                return true
            }
        }

        // Need to download
        Self.logger.info("[AMLLDB] No local cache, downloading...")
        return await downloadIndex()
    }

    /// Force refresh the index
    func refreshIndex() async -> Bool {
        Self.logger.info("[AMLLDB] Force refresh requested")
        return await downloadIndex()
    }

    // MARK: - Cache Loading

    /// Load index from local cache
    private func loadFromCache() async -> Bool {
        let indexURL = localIndexURL
        Self.logger.info("[AMLLDB] Loading from cache: \(indexURL.path)")

        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            Self.logger.info("[AMLLDB] Cache file does not exist")
            lastError = "缓存文件不存在"
            return false
        }

        do {
            let result = try await Task.detached(priority: .utility) { @Sendable in
                let token = FirstUseHitchDiagnostics.begin(
                    "AMLLDBRawIndexCache.loadFromCache.background",
                    detail: indexURL.lastPathComponent
                )
                do {
                    let result = try loadAMLLDBRawIndexEntries(from: indexURL)
                    FirstUseHitchDiagnostics.end(
                        token,
                        detail: "bytes=\(result.byteCount), entries=\(result.entries.count), parseErrors=\(result.parseErrorCount)"
                    )
                    return result
                } catch {
                    FirstUseHitchDiagnostics.end(token, detail: "error=\(error.localizedDescription)")
                    throw error
                }
            }.value

            let commitToken = FirstUseHitchDiagnostics.begin(
                "AMLLDBRawIndexCache.loadFromCache.commit",
                detail: "entries=\(result.entries.count)"
            )
            entries = result.entries
            entryCount = result.entries.count
            isReady = !result.entries.isEmpty
            lastError = nil
            FirstUseHitchDiagnostics.end(commitToken)

            Self.logger.info("[AMLLDB] Loaded \(result.entries.count) entries from cache")
            return isReady

        } catch {
            Self.logger.error("[AMLLDB] Failed to load cache: \(error.localizedDescription)")
            lastError = "加载缓存失败: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Index Download

    /// Download index from remote
    private func downloadIndex() async -> Bool {
        isDownloading = true
        downloadProgress = 0
        lastError = nil

        Self.logger.info("[AMLLDB] Starting index download from \(self.indexURL.absoluteString)")

        do {
            // Create cache directory if needed
            try ensureCacheDirectory()

            // Download with progress
            let request = URLRequest(url: indexURL, timeoutInterval: 120)
            let (asyncBytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AMLLDBCacheError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw AMLLDBCacheError.httpError(httpResponse.statusCode)
            }

            // Collect data with progress
            var data = Data()
            let expectedLength = response.expectedContentLength
            var receivedLength: Int64 = 0

            for try await byte in asyncBytes {
                data.append(byte)
                receivedLength += 1

                // Update progress every 100KB
                if receivedLength % 102400 == 0 {
                    let progress = expectedLength > 0 ? Double(receivedLength) / Double(expectedLength) : 0
                    await MainActor.run {
                        self.downloadProgress = min(progress, 1.0)
                    }
                }
            }

            Self.logger.info("[AMLLDB] Downloaded \(data.count) bytes")

            // Parse the data
            let downloadedData = data
            let parseResult = try await Task.detached(priority: .utility) { @Sendable in
                let token = FirstUseHitchDiagnostics.begin(
                    "AMLLDBRawIndexCache.parseDownloadedIndex.background",
                    detail: "bytes=\(downloadedData.count)"
                )
                do {
                    let (entries, parseErrorCount) = try parseAMLLDBRawIndexData(downloadedData)
                    FirstUseHitchDiagnostics.end(
                        token,
                        detail: "entries=\(entries.count), parseErrors=\(parseErrorCount)"
                    )
                    return (entries, parseErrorCount)
                } catch {
                    FirstUseHitchDiagnostics.end(token, detail: "error=\(error.localizedDescription)")
                    throw error
                }
            }.value

            // Save to cache
            try data.write(to: localIndexURL)

            // Save timestamp
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try timestamp.write(to: lastUpdateFileURL, atomically: true, encoding: .utf8)

            // Update state
            entries = parseResult.0
            entryCount = parseResult.0.count
            isReady = !parseResult.0.isEmpty
            downloadProgress = 1.0
            isDownloading = false
            lastError = nil

            Self.logger.info("[AMLLDB] Index download complete: \(parseResult.0.count) entries cached")
            return isReady

        } catch {
            Self.logger.error("[AMLLDB] Index download failed: \(error.localizedDescription)")
            lastError = "下载失败: \(error.localizedDescription)"
            isDownloading = false
            return false
        }
    }

    /// Ensure cache directory exists
    private func ensureCacheDirectory() throws {
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            Self.logger.info("[AMLLDB] Created cache directory: \(self.cacheDirectory.path)")
        }
    }

    // MARK: - Background Update

    /// Start background update check
    private func startBackgroundUpdateCheck() {
        // Check if update is needed
        if !shouldUpdate() {
            Self.logger.info("[AMLLDB] Index is fresh, no update needed")
            return
        }

        Self.logger.info("[AMLLDB] Starting background index update")

        updateTask = Task { [weak self] in
            guard let self = self else { return }

            let success = await self.downloadIndex()
            if success {
                Self.logger.info("[AMLLDB] Background update completed successfully")
            } else {
                Self.logger.warning("[AMLLDB] Background update failed")
            }
        }
    }

    /// Check if index should be updated
    private func shouldUpdate() -> Bool {
        guard let lastUpdateString = try? String(contentsOf: lastUpdateFileURL, encoding: .utf8),
              let lastUpdate = ISO8601DateFormatter().date(from: lastUpdateString)
        else {
            return true
        }

        let elapsed = Date().timeIntervalSince(lastUpdate)
        return elapsed > updateInterval
    }

    // MARK: - Cache Management

    /// Clear local cache
    func clearCache() throws {
        if FileManager.default.fileExists(atPath: localIndexURL.path) {
            try FileManager.default.removeItem(at: localIndexURL)
        }
        if FileManager.default.fileExists(atPath: lastUpdateFileURL.path) {
            try FileManager.default.removeItem(at: lastUpdateFileURL)
        }

        entries = []
        entryCount = 0
        isReady = false

        Self.logger.info("[AMLLDB] Cache cleared")
    }

    /// Get cache size in bytes
    func getCacheSize() -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: localIndexURL.path),
              let size = attributes[.size] as? Int64
        else {
            return 0
        }
        return size
    }
}

private struct AMLLDBRawIndexLoadResult: Sendable {
    let entries: [AMLLDBRawIndexEntry]
    let byteCount: Int
    let parseErrorCount: Int
}

private nonisolated func loadAMLLDBRawIndexEntries(from url: URL) throws -> AMLLDBRawIndexLoadResult {
    let data = try Data(contentsOf: url)
    let (entries, parseErrorCount) = try parseAMLLDBRawIndexData(data)
    return AMLLDBRawIndexLoadResult(
        entries: entries,
        byteCount: data.count,
        parseErrorCount: parseErrorCount
    )
}

private nonisolated func parseAMLLDBRawIndexData(_ data: Data) throws -> ([AMLLDBRawIndexEntry], Int) {
    guard let text = String(data: data, encoding: .utf8) else {
        throw AMLLDBCacheError.invalidEncoding
    }

    let logger = Logger(subsystem: "com.kmgccc.player", category: "AMLLDB")
    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    logger.info("[AMLLDB] Parsing \(lines.count) lines from index")

    var entries: [AMLLDBRawIndexEntry] = []
    entries.reserveCapacity(lines.count)

    var parseErrorCount = 0
    let decoder = JSONDecoder()

    for (index, line) in lines.enumerated() {
        guard let lineData = line.data(using: .utf8) else { continue }

        do {
            let rawEntry = try decoder.decode(AMLLDBJsonlRawEntry.self, from: lineData)
            if let entry = rawEntry.toIndexEntry() {
                entries.append(entry)
            }
        } catch {
            parseErrorCount += 1
            if parseErrorCount <= 5 {
                logger.warning("[AMLLDB] Parse error on line \(index + 1): \(error.localizedDescription)")
            }
        }
    }

    logger.info("[AMLLDB] Parsed \(entries.count) valid entries, \(parseErrorCount) errors")

    if entries.isEmpty {
        throw AMLLDBCacheError.noValidEntries
    }

    return (entries, parseErrorCount)
}

// MARK: - Errors

enum AMLLDBCacheError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case invalidEncoding
    case noValidEntries
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "无效的响应"
        case .httpError(let code):
            return "HTTP 错误: \(code)"
        case .invalidEncoding:
            return "无效的编码格式"
        case .noValidEntries:
            return "没有有效的索引条目"
        case .downloadFailed(let message):
            return "下载失败: \(message)"
        }
    }
}
