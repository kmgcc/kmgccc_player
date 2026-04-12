//
//  FileImportService.swift
//  myPlayer2
//
//  kmgccc_player - File Import Service
//  Imports audio files into a SPECIFIC PLAYLIST using NSOpenPanel.
//  Creates security-scoped bookmarks for sandbox access.
//

import AVFoundation
import AppKit
import Combine
import CoreServices
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared Types

nonisolated struct ImportPreview: Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let lyrics: String?
    let artworkData: Data?
}

nonisolated struct TrackPreview: Sendable {
    let title: String
    let artist: String
    let artworkData: Data?
}

nonisolated struct DuplicatePairRow: Identifiable, Sendable {
    let id: String
    let fileURL: URL
    let incoming: ImportPreview
    let existing: TrackPreview?
    let existingCount: Int
    let dedupKey: String
}

enum ArtworkExtractor {
    // Removed
}

nonisolated private enum BatchImportItemStage: Sendable {
    case scanning
    case ncmConversion
    case metadata
    case duplicateCheck
    case importing
    case enrichingMetadata
    case completed

    var title: String {
        switch self {
        case .scanning:
            return "扫描文件"
        case .ncmConversion:
            return "NCM 转换"
        case .metadata:
            return "解析信息"
        case .duplicateCheck:
            return "重复检查"
        case .importing:
            return "导入歌曲"
        case .enrichingMetadata:
            return "补全信息"
        case .completed:
            return "导入完成"
        }
    }
}

nonisolated private enum BatchImportItemStatus: Sendable {
    case waiting
    case active
    case success
    case warning
    case skipped
    case failed

    var title: String {
        switch self {
        case .waiting:
            return "等待中"
        case .active:
            return "进行中"
        case .success:
            return "已完成"
        case .warning:
            return "有提示"
        case .skipped:
            return "已跳过"
        case .failed:
            return "失败"
        }
    }
}

nonisolated private enum BatchImportStage {
    case scanning
    case convertingNCM
    case readingMetadata
    case waitingForDuplicateChoice
    case importingFiles
    case enrichingMetadata
    case savingLibrary
    case completed

    var title: String {
        switch self {
        case .scanning:
            return "正在扫描文件"
        case .convertingNCM:
            return "正在转换 NCM"
        case .readingMetadata:
            return "正在解析元数据"
        case .waitingForDuplicateChoice:
            return "等待处理重复歌曲"
        case .importingFiles:
            return "正在导入歌曲"
        case .enrichingMetadata:
            return "正在补全导入信息"
        case .savingLibrary:
            return "正在保存到资料库"
        case .completed:
            return "导入完成"
        }
    }

    var progressRange: ClosedRange<Double> {
        switch self {
        case .scanning:
            return 0.0...0.08
        case .convertingNCM:
            return 0.08...0.28
        case .readingMetadata:
            return 0.28...0.48
        case .waitingForDuplicateChoice:
            return 0.48...0.48
        case .importingFiles:
            return 0.48...0.82
        case .enrichingMetadata:
            return 0.82...0.96
        case .savingLibrary:
            return 0.96...0.995
        case .completed:
            return 1.0...1.0
        }
    }
}

nonisolated private enum ImportEnrichmentMode: Sendable {
    case immediate
    case deferred

    var defersEnrichment: Bool {
        self == .deferred
    }
}

nonisolated private enum ImportLyricsLookupOutcome: Sendable {
    case completed(String)
    case noResults
    case failed(String)
}

nonisolated private enum ImportCoverLookupOutcome: Sendable {
    case completed(Data)
    case noResults
    case failed(String)
}

nonisolated private enum ImportEnrichmentPart: String, Sendable, Hashable {
    case lyrics
    case cover

    var label: String {
        switch self {
        case .lyrics: return "歌词"
        case .cover: return "封面"
        }
    }
}

nonisolated private enum ImportEnrichmentPartState: String, Sendable {
    case pending
    case running
    case flushPending
    case completed
    case failed
    case noResults
    case skipped

    var isOutstanding: Bool {
        self == .pending || self == .running || self == .flushPending
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .noResults, .skipped:
            return true
        case .pending, .running, .flushPending:
            return false
        }
    }

    var countsAsFailure: Bool {
        self == .failed || self == .noResults
    }
}

nonisolated private struct ImportEnrichmentPartRequest: Sendable, Hashable {
    let trackID: UUID
    let part: ImportEnrichmentPart
}

nonisolated private struct ImportEnrichmentItemState: Sendable {
    let trackID: UUID
    var title: String
    var artist: String
    var album: String
    var lyricsState: ImportEnrichmentPartState
    var coverState: ImportEnrichmentPartState
    var lyricAttempts: Int
    var coverAttempts: Int

    func state(for part: ImportEnrichmentPart) -> ImportEnrichmentPartState {
        switch part {
        case .lyrics: return lyricsState
        case .cover: return coverState
        }
    }

    mutating func setState(_ state: ImportEnrichmentPartState, for part: ImportEnrichmentPart) {
        switch part {
        case .lyrics:
            lyricsState = state
        case .cover:
            coverState = state
        }
    }

    func attempts(for part: ImportEnrichmentPart) -> Int {
        switch part {
        case .lyrics: return lyricAttempts
        case .cover: return coverAttempts
        }
    }

    mutating func incrementAttempts(for part: ImportEnrichmentPart) {
        switch part {
        case .lyrics:
            lyricAttempts += 1
        case .cover:
            coverAttempts += 1
        }
    }

    var hasOutstandingWork: Bool {
        lyricsState.isOutstanding || coverState.isOutstanding
    }

    var isTerminal: Bool {
        lyricsState.isTerminal && coverState.isTerminal
    }

    var hasTerminalFailure: Bool {
        lyricsState.countsAsFailure || coverState.countsAsFailure
    }

    var flushPendingPartCount: Int {
        [lyricsState, coverState].filter { $0 == .flushPending }.count
    }
}

nonisolated struct ImportEnrichmentProgressSnapshot: Sendable, Equatable {
    let totalEnqueued: Int
    let completedCount: Int
    let failedCount: Int
    let pendingLyricsCount: Int
    let pendingCoverCount: Int
    let runningCount: Int
    let flushPendingCount: Int

    var hasOutstandingWork: Bool {
        pendingLyricsCount > 0 || pendingCoverCount > 0 || runningCount > 0 || flushPendingCount > 0
    }

    var sidebarText: String {
        var parts: [String] = [
            "补全中 \(completedCount)/\(totalEnqueued)"
        ]
        if runningCount > 0 {
            parts.append("进行中 \(runningCount)")
        }
        if flushPendingCount > 0 {
            parts.append("待提交 \(flushPendingCount)")
        }
        if pendingLyricsCount > 0 || pendingCoverCount > 0 {
            parts.append("词\(pendingLyricsCount) 封\(pendingCoverCount)")
        }
        if failedCount > 0 {
            parts.append("失败 \(failedCount)")
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated private struct PendingTrackEnrichmentPatch: Sendable {
    let trackID: UUID
    var ttmlLyricText: String?
    var artworkData: Data?
    var lyricShouldFlush: Bool
    var coverShouldFlush: Bool

    init(trackID: UUID) {
        self.trackID = trackID
        self.ttmlLyricText = nil
        self.artworkData = nil
        self.lyricShouldFlush = false
        self.coverShouldFlush = false
    }
}

nonisolated private enum ImportEnrichmentWorker {
    /// Fetch lyrics using the shared search pipeline that matches manual "Find Lyrics" behavior.
    /// Uses both AMLLDB and LDDC sources with proper ranking/merging logic.
    /// Automatically selects the top-ranked candidate from the merged result list.
    /// - Parameters:
    ///   - title: Song title to search
    ///   - artist: Artist name (optional)
    ///   - album: Album name (optional, improves AMLLDB matching)
    ///   - duration: Duration in seconds (optional, improves AMLLDB matching)
    /// - Returns: ImportLyricsLookupOutcome with TTML lyrics or failure status
    static func fetchLyrics(
        title: String,
        artist: String,
        album: String? = nil,
        duration: Double? = nil
    ) async -> ImportLyricsLookupOutcome {
        // Use shared helper that matches manual "Find Lyrics" ranking logic
        // This ensures import flow uses the same AMLLDB + LDDC search with proper merging
        let ttml = await LyricsSearchHelper.searchAndFetchBestLyrics(
            title: title,
            artist: artist.isEmpty ? nil : artist,
            album: album?.isEmpty == true ? nil : album,
            duration: duration
        )

        if let ttml {
            return .completed(ttml)
        } else {
            return .noResults
        }
    }

    static func fetchCover(
        artist: String,
        album: String
    ) async -> ImportCoverLookupOutcome {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedArtist.isEmpty || !normalizedAlbum.isEmpty else {
            return .noResults
        }

        do {
            let coverData = try await downloadCoverViaSacad(
                artist: normalizedArtist,
                album: normalizedAlbum,
                size: 1200
            )
            return .completed(coverData)
        } catch {
            Log.warning(
                "sacad cover fetch failed for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                category: .import
            )
        }

        do {
            let coverData = try await downloadNetEaseCover(
                artist: normalizedArtist,
                album: normalizedAlbum
            )
            return .completed(coverData)
        } catch let error as NetEaseCoverError {
            if case .noResults = error {
                return .noResults
            }
            Log.warning(
                "NetEase cover fetch failed for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        } catch {
            Log.warning(
                "NetEase cover fetch failed for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        }
    }

    private static func downloadCoverViaSacad(
        artist: String,
        album: String,
        size: Int
    ) async throws -> Data {
        let executablePath = "/Users/kmg/.cargo/bin/sacad"
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: executablePath) else {
            throw CoverDownloadError.executableMissing(path: executablePath)
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("temp_\(UUID().uuidString).jpg")

        defer {
            try? fileManager.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [artist, album, String(size), tempURL.path]

        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else {
                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: CoverDownloadError.processFailed(
                            exitCode: process.terminationStatus,
                            message: stderrText?.isEmpty == false
                                ? stderrText!
                                : "sacad exited with an error"
                        )
                    )
                    return
                }
                continuation.resume()
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: CoverDownloadError.processFailed(
                        exitCode: -1,
                        message: error.localizedDescription
                    )
                )
            }
        }

        guard fileManager.fileExists(atPath: tempURL.path) else {
            throw CoverDownloadError.outputMissing
        }

        let imageData = try Data(contentsOf: tempURL)
        guard !imageData.isEmpty, NSImage(data: imageData) != nil else {
            throw CoverDownloadError.invalidImageData
        }
        return imageData
    }

    private static func downloadNetEaseCover(
        artist: String,
        album: String
    ) async throws -> Data {
        let query = "\(artist) \(album)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            throw NetEaseCoverError.badURL
        }

        let searchURLString =
            "https://music.163.com/api/search/get/web?type=10&s=\(encodedQuery)&limit=5"
        guard let searchURL = URL(string: searchURLString) else {
            throw NetEaseCoverError.badURL
        }

        let searchData: Data
        do {
            let (data, response) = try await URLSession.shared.data(from: searchURL)
            try validateNetEaseHTTP(response: response)
            searchData = data
        } catch let error as NetEaseCoverError {
            throw error
        } catch {
            throw NetEaseCoverError.requestFailed(underlying: error)
        }

        let result: NetEaseSearchResponse
        do {
            result = try JSONDecoder().decode(NetEaseSearchResponse.self, from: searchData)
        } catch {
            throw NetEaseCoverError.decodingFailed(underlying: error)
        }

        guard let picURLString = result.result.albums.first?.picURL else {
            throw NetEaseCoverError.noResults
        }

        let finalCoverURLString = makeLargeCoverURLString(from: picURLString)
        guard let coverURL = URL(string: finalCoverURLString) else {
            throw NetEaseCoverError.badURL
        }

        do {
            let (imageData, response) = try await URLSession.shared.data(from: coverURL)
            try validateNetEaseHTTP(response: response)
            guard !imageData.isEmpty, NSImage(data: imageData) != nil else {
                throw NetEaseCoverError.imageDownloadFailed(
                    underlying: CoverDownloadError.invalidImageData
                )
            }
            return imageData
        } catch let error as NetEaseCoverError {
            throw error
        } catch {
            throw NetEaseCoverError.imageDownloadFailed(underlying: error)
        }
    }

    private static func validateNetEaseHTTP(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let error = NSError(
                domain: "NetEaseCoverService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
            throw NetEaseCoverError.requestFailed(underlying: error)
        }
    }

    private static func makeLargeCoverURLString(from picURLString: String) -> String {
        if picURLString.contains("?") {
            return "\(picURLString)&param=1200y1200"
        }
        return "\(picURLString)?param=1200y1200"
    }

    private struct NetEaseSearchResponse: Decodable, Sendable {
        let result: ResultPayload

        struct ResultPayload: Decodable, Sendable {
            let albums: [Album]
        }

        struct Album: Decodable, Sendable {
            let picURL: String

            enum CodingKeys: String, CodingKey {
                case picURL = "picUrl"
            }
        }
    }
}

@MainActor
@Observable
final class ImportEnrichmentService {
    private let repository: LibraryRepositoryProtocol
    private let maxConcurrent: Int
    private let maxAttemptsPerPart = 2
    private let flushBatchSize = 4
    private let flushDebounceNanoseconds: UInt64 = 900_000_000

    private var queue: [ImportEnrichmentPartRequest] = []
    private var queuedRequests: Set<ImportEnrichmentPartRequest> = []
    private var runningRequests: Set<ImportEnrichmentPartRequest> = []
    private var trackByID: [UUID: Track] = [:]
    private var itemStates: [UUID: ImportEnrichmentItemState] = [:]
    private var pendingFlushPatches: [UUID: PendingTrackEnrichmentPatch] = [:]
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private(set) var progress = ImportEnrichmentProgressSnapshot(
        totalEnqueued: 0,
        completedCount: 0,
        failedCount: 0,
        pendingLyricsCount: 0,
        pendingCoverCount: 0,
        runningCount: 0,
        flushPendingCount: 0
    )

    var hasOutstandingWork: Bool { progress.hasOutstandingWork }

    init(repository: LibraryRepositoryProtocol, maxConcurrent: Int = 2) {
        self.repository = repository
        self.maxConcurrent = max(1, maxConcurrent)
        Log.info("[ImportEnrichment] service init", category: .import)
    }

    deinit {
        Log.info("[ImportEnrichment] service deinit", category: .import)
    }

    func enqueueTracks(_ tracks: [Track]) {
        if hasOutstandingWork == false {
            resetProgressIfIdle()
        }

        Log.info("[ImportEnrichment] queue wake requested for \(tracks.count) tracks", category: .import)

        for track in tracks {
            guard let itemState = makeInitialItemState(for: track) else { continue }
            if itemStates[track.id] == nil {
                itemStates[track.id] = itemState
            } else {
                itemStates[track.id]?.title = track.title
                itemStates[track.id]?.artist = track.artist
                itemStates[track.id]?.album = track.album
            }

            trackByID[track.id] = track

            if track.ttmlLyricText == nil {
                enqueuePart(.lyrics, for: track.id)
            } else if var state = itemStates[track.id], state.lyricsState != .completed {
                state.lyricsState = .skipped
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already present",
                    category: .lyrics
                )
            }

            if track.artworkData == nil {
                enqueuePart(.cover, for: track.id)
            } else if var state = itemStates[track.id], state.coverState != .completed {
                state.coverState = .skipped
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
            }

            guard let state = itemStates[track.id] else {
                continue
            }
            Log.info(
                "[ImportEnrichment] track queued \(track.title) - \(track.artist) | lyrics=\(state.lyricsState.rawValue) cover=\(state.coverState.rawValue)",
                category: .import
            )
        }

        refreshProgress()
        drainQueueIfPossible()
        diagnoseStalledQueue(context: "enqueue")
    }

    private func makeInitialItemState(for track: Track) -> ImportEnrichmentItemState? {
        let needsLyrics = track.ttmlLyricText == nil
        let needsCover = track.artworkData == nil
        guard needsLyrics || needsCover else { return nil }

        return ImportEnrichmentItemState(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            lyricsState: needsLyrics ? .pending : .skipped,
            coverState: needsCover ? .pending : .skipped,
            lyricAttempts: 0,
            coverAttempts: 0
        )
    }

    private func enqueuePart(_ part: ImportEnrichmentPart, for trackID: UUID) {
        let request = ImportEnrichmentPartRequest(trackID: trackID, part: part)
        guard queuedRequests.contains(request) == false, runningRequests.contains(request) == false
        else { return }
        guard var state = itemStates[trackID] else { return }
        let currentState = state.state(for: part)
        guard currentState == .pending || currentState == .failed else { return }

        state.setState(.pending, for: part)
        itemStates[trackID] = state
        queue.append(request)
        queuedRequests.insert(request)
        Log.info(
            "[ImportEnrichment] \(part.rawValue) enqueued \(state.title) - \(state.artist)",
            category: part == .lyrics ? .lyrics : .import
        )
    }

    private func refreshProgress() {
        let values = Array(itemStates.values)
        let completedCount = values.filter(\.isTerminal).count
        let failedCount = values.filter(\.hasTerminalFailure).count
        let pendingLyricsCount = values.filter {
            $0.lyricsState == .pending || $0.lyricsState == .running
        }.count
        let pendingCoverCount = values.filter {
            $0.coverState == .pending || $0.coverState == .running
        }.count
        let flushPendingCount = values.reduce(0) { $0 + $1.flushPendingPartCount }

        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: values.count,
            completedCount: completedCount,
            failedCount: failedCount,
            pendingLyricsCount: pendingLyricsCount,
            pendingCoverCount: pendingCoverCount,
            runningCount: runningRequests.count,
            flushPendingCount: flushPendingCount
        )
    }

    private func resetProgressIfIdle() {
        flushTask?.cancel()
        flushTask = nil
        queue.removeAll()
        queuedRequests.removeAll()
        runningRequests.removeAll()
        trackByID.removeAll()
        itemStates.removeAll()
        pendingFlushPatches.removeAll()
        isFlushing = false
        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: 0,
            completedCount: 0,
            failedCount: 0,
            pendingLyricsCount: 0,
            pendingCoverCount: 0,
            runningCount: 0,
            flushPendingCount: 0
        )
    }

    private func drainQueueIfPossible() {
        if queue.isEmpty == false {
            Log.debug(
                "[ImportEnrichment] queue wake | queued=\(queue.count) running=\(runningRequests.count)",
                category: .import
            )
        }
        while runningRequests.count < maxConcurrent, queue.isEmpty == false {
            let request = queue.removeFirst()
            queuedRequests.remove(request)

            guard let track = trackByID[request.trackID], var state = itemStates[request.trackID] else {
                continue
            }

            if request.part == .lyrics, track.ttmlLyricText != nil {
                state.setState(.skipped, for: .lyrics)
                itemStates[request.trackID] = state
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already present",
                    category: .lyrics
                )
                refreshProgress()
                continue
            }

            if request.part == .cover, track.artworkData != nil {
                state.setState(.skipped, for: .cover)
                itemStates[request.trackID] = state
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
                refreshProgress()
                continue
            }

            state.setState(.running, for: request.part)
            state.incrementAttempts(for: request.part)
            itemStates[request.trackID] = state
            runningRequests.insert(request)
            refreshProgress()
            start(request: request, track: track, state: state)
        }
        diagnoseStalledQueue(context: "drain")
    }

    private func start(
        request: ImportEnrichmentPartRequest,
        track: Track,
        state: ImportEnrichmentItemState
    ) {
        let title = state.title
        let artist = state.artist
        let album = state.album
        let duration = track.duration > 0 ? track.duration : nil
        let attempt = state.attempts(for: request.part)
        Log.info(
            "[ImportEnrichment] \(request.part.rawValue) started \(title) - \(artist) | attempt \(attempt)/\(maxAttemptsPerPart)",
            category: request.part == .lyrics ? .lyrics : .import
        )

        Task(priority: .utility) {
            let taskStart = ContinuousClock.now

            switch request.part {
            case .lyrics:
                let outcome = await ImportEnrichmentWorker.fetchLyrics(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
                await self.completeLyrics(request: request, outcome: outcome)
            case .cover:
                let outcome = await ImportEnrichmentWorker.fetchCover(
                    artist: artist,
                    album: album
                )
                await self.completeCover(request: request, outcome: outcome)
            }

            let elapsed = taskStart.duration(to: ContinuousClock.now)
            let elapsedMs = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            Log.info(
                "[ImportEnrichment] \(request.part.rawValue) task end \(title) - \(artist) | \(String(format: "%.1f", elapsedMs))ms",
                category: request.part == .lyrics ? .lyrics : .import
            )
        }
    }

    private func completeLyrics(
        request: ImportEnrichmentPartRequest,
        outcome: ImportLyricsLookupOutcome
    ) async {
        guard let track = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let ttml):
            if track.ttmlLyricText == nil {
                bufferFlushPatch(
                    trackID: request.trackID,
                    title: state.title,
                    artist: state.artist
                ) { patch in
                    patch.ttmlLyricText = ttml
                    patch.lyricShouldFlush = true
                }
                state.setState(.flushPending, for: .lyrics)
                Log.info(
                    "[ImportEnrichment] lyrics buffered \(state.title) - \(state.artist)",
                    category: .lyrics
                )
            } else {
                state.setState(.skipped, for: .lyrics)
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already filled before save",
                    category: .lyrics
                )
            }
        case .noResults:
            state.setState(.noResults, for: .lyrics)
            Log.warning(
                "[ImportEnrichment] lyrics no-results \(state.title) - \(state.artist)",
                category: .lyrics
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .lyrics, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .lyrics)
                Log.warning(
                    "[ImportEnrichment] lyrics failed \(state.title) - \(state.artist) | retrying: \(message)",
                    category: .lyrics
                )
            } else {
                state.setState(.failed, for: .lyrics)
                Log.warning(
                    "[ImportEnrichment] lyrics failed \(state.title) - \(state.artist): \(message)",
                    category: .lyrics
                )
            }
        }

        itemStates[request.trackID] = state
        scheduleFlushIfNeeded(reason: "lyrics_result")
        finish(request, requeue: shouldRequeue)
    }

    private func completeCover(
        request: ImportEnrichmentPartRequest,
        outcome: ImportCoverLookupOutcome
    ) async {
        guard let track = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let data):
            if track.artworkData == nil {
                bufferFlushPatch(
                    trackID: request.trackID,
                    title: state.title,
                    artist: state.artist
                ) { patch in
                    patch.artworkData = data
                    patch.coverShouldFlush = true
                }
                state.setState(.flushPending, for: .cover)
                Log.info(
                    "[ImportEnrichment] cover buffered \(state.title) - \(state.artist)",
                    category: .import
                )
            } else {
                state.setState(.skipped, for: .cover)
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already filled before save",
                    category: .import
                )
            }
        case .noResults:
            state.setState(.noResults, for: .cover)
            Log.warning(
                "[ImportEnrichment] cover no-results \(state.title) - \(state.artist)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .cover, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .cover)
                Log.warning(
                    "[ImportEnrichment] cover failed \(state.title) - \(state.artist) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .cover)
                Log.warning(
                    "[ImportEnrichment] cover failed \(state.title) - \(state.artist): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        scheduleFlushIfNeeded(reason: "cover_result")
        finish(request, requeue: shouldRequeue)
    }

    private func shouldRetry(part: ImportEnrichmentPart, state: ImportEnrichmentItemState) -> Bool {
        state.attempts(for: part) < maxAttemptsPerPart
    }

    private func bufferFlushPatch(
        trackID: UUID,
        title: String,
        artist: String,
        mutate: (inout PendingTrackEnrichmentPatch) -> Void
    ) {
        var patch = pendingFlushPatches[trackID] ?? PendingTrackEnrichmentPatch(trackID: trackID)
        mutate(&patch)
        pendingFlushPatches[trackID] = patch
        Log.info(
            "[ImportEnrichment] batch buffered \(title) - \(artist) | pendingTracks=\(pendingFlushPatches.count)",
            category: .import
        )
    }

    private func scheduleFlushIfNeeded(reason: String) {
        guard pendingFlushPatches.isEmpty == false else { return }

        if pendingFlushPatches.count >= flushBatchSize {
            flushTask?.cancel()
            flushTask = nil
            Task { @MainActor in
                await flushBufferedUpdates(reason: "threshold:\(reason)")
            }
            return
        }

        if queue.isEmpty && runningRequests.isEmpty {
            flushTask?.cancel()
            flushTask = nil
            Task { @MainActor in
                await flushBufferedUpdates(reason: "idle:\(reason)")
            }
            return
        }

        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: flushDebounceNanoseconds)
            await flushBufferedUpdates(reason: "debounce:\(reason)")
        }
    }

    private func flushBufferedUpdates(reason: String) async {
        guard isFlushing == false else { return }
        guard pendingFlushPatches.isEmpty == false else { return }

        isFlushing = true
        flushTask?.cancel()
        flushTask = nil

        let patches = pendingFlushPatches
        let trackIDs = Array(patches.keys).sorted { $0.uuidString < $1.uuidString }
        Log.info(
            "[ImportEnrichment] batch flush start reason=\(reason) tracks=\(trackIDs.count)",
            category: .import
        )

        struct PendingRevert {
            let lyrics: String?
            let artworkData: Data?
        }

        var touchedTracks: [Track] = []
        var revertByTrackID: [UUID: PendingRevert] = [:]
        var effectivePatches: [UUID: PendingTrackEnrichmentPatch] = [:]

        for trackID in trackIDs {
            guard let track = trackByID[trackID], let patch = patches[trackID] else { continue }
            var effectivePatch = patch
            revertByTrackID[trackID] = PendingRevert(
                lyrics: track.ttmlLyricText,
                artworkData: track.artworkData
            )

            if patch.lyricShouldFlush {
                if track.ttmlLyricText == nil, let ttml = patch.ttmlLyricText {
                    track.ttmlLyricText = ttml
                } else {
                    effectivePatch.ttmlLyricText = nil
                    effectivePatch.lyricShouldFlush = false
                }
            }
            if patch.coverShouldFlush {
                if track.artworkData == nil, let artworkData = patch.artworkData {
                    track.artworkData = artworkData
                } else {
                    effectivePatch.artworkData = nil
                    effectivePatch.coverShouldFlush = false
                }
            }

            if effectivePatch.lyricShouldFlush || effectivePatch.coverShouldFlush {
                touchedTracks.append(track)
                effectivePatches[trackID] = effectivePatch
            } else {
                if var state = itemStates[trackID] {
                    if patch.lyricShouldFlush, state.lyricsState == .flushPending {
                        state.lyricsState = .skipped
                    }
                    if patch.coverShouldFlush, state.coverState == .flushPending {
                        state.coverState = .skipped
                    }
                    itemStates[trackID] = state
                    if state.isTerminal {
                        trackByID[trackID] = nil
                    }
                }
                pendingFlushPatches.removeValue(forKey: trackID)
            }
        }

        guard !touchedTracks.isEmpty else {
            refreshProgress()
            Log.info(
                "[ImportEnrichment] batch flush complete reason=\(reason) persisted=0 failed=0",
                category: .import
            )
            isFlushing = false
            return
        }

        let result = await repository.persistTrackUpdates(touchedTracks)
        let persistedTrackIDs = Set(result.persistedTrackIDs)
        let failedTrackIDs = Set(result.failedTrackIDs)

        for trackID in persistedTrackIDs {
            guard let patch = effectivePatches[trackID], var state = itemStates[trackID] else { continue }
            if patch.lyricShouldFlush, state.lyricsState == .flushPending {
                state.lyricsState = .completed
            }
            if patch.coverShouldFlush, state.coverState == .flushPending {
                state.coverState = .completed
            }
            itemStates[trackID] = state
            pendingFlushPatches.removeValue(forKey: trackID)
            if state.isTerminal {
                trackByID[trackID] = nil
            }
        }

        for trackID in failedTrackIDs {
            guard let patch = effectivePatches[trackID], let revert = revertByTrackID[trackID] else { continue }
            if let track = trackByID[trackID] {
                track.ttmlLyricText = revert.lyrics
                track.artworkData = revert.artworkData
            }
            if var state = itemStates[trackID] {
                if patch.lyricShouldFlush, state.lyricsState == .flushPending {
                    state.lyricsState = .failed
                }
                if patch.coverShouldFlush, state.coverState == .flushPending {
                    state.coverState = .failed
                }
                itemStates[trackID] = state
                if state.isTerminal {
                    trackByID[trackID] = nil
                }
            }
            pendingFlushPatches.removeValue(forKey: trackID)
        }

        refreshProgress()
        Log.info(
            "[ImportEnrichment] batch flush complete reason=\(reason) persisted=\(result.persistedTrackIDs.count) failed=\(result.failedTrackIDs.count)",
            category: .import
        )
        if !result.persistedTrackIDs.isEmpty {
            Log.info(
                "[ImportEnrichment] visible refresh notified for \(result.persistedTrackIDs.count) persisted tracks",
                category: .import
            )
            Log.info(
                "[ImportEnrichmentReload] flush success with \(result.persistedTrackIDs.count) updated tracks",
                category: .import
            )
        }
        if !result.failedTrackIDs.isEmpty {
            Log.warning(
                "[ImportEnrichment] persistence flush failed for \(result.failedTrackIDs.count) tracks",
                category: .import
            )
        }

        isFlushing = false

        if pendingFlushPatches.isEmpty == false {
            scheduleFlushIfNeeded(reason: "post_flush")
        }
    }

    private func diagnoseStalledQueue(context: String) {
        if queue.isEmpty == false && runningRequests.isEmpty {
            Log.warning(
                "[ImportEnrichment] queue stalled after \(context) | queued=\(queue.count) running=0",
                category: .import
            )
        }
    }

    private func finish(_ request: ImportEnrichmentPartRequest, requeue: Bool = false) {
        runningRequests.remove(request)

        if requeue {
            queue.append(request)
            queuedRequests.insert(request)
        }

        Log.debug(
            "[ImportEnrichment] finish \(request.part.rawValue) | requeue=\(requeue) queued=\(queue.count) running=\(runningRequests.count)",
            category: .import
        )

        refreshProgress()

        if let state = itemStates[request.trackID], state.isTerminal {
            trackByID[request.trackID] = nil
        }

        if queue.isEmpty && runningRequests.isEmpty {
            scheduleFlushIfNeeded(reason: "queue_idle")
        }
        drainQueueIfPossible()
    }
}

// MARK: - Service

/// Service for importing audio files into a playlist.
/// Supports mp3, m4a, aac, alac, flac, wav.
@MainActor
final class FileImportService: FileImportServiceProtocol {
    private struct ImportCandidate: Sendable {
        let progressID: String
        let displayName: String
        let fileURL: URL
        let metadata: ImportPreview
    }

    private struct ResolvedImportFile: Sendable {
        let progressID: String
        let displayName: String
        let fileURL: URL
        let ncmResult: NCMConversionResult?
    }

    private struct ImportedTrackRecord {
        let progressID: String
        let displayName: String
        let track: Track
        let needsLyricsEnrichment: Bool
        let needsCoverEnrichment: Bool

        var needsAnyEnrichment: Bool {
            needsLyricsEnrichment || needsCoverEnrichment
        }
    }

    private struct ImportedTrackPayload: Sendable {
        let id: UUID
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let importedAt: Date
        let originalFilePath: String
        let libraryRelativePath: String
        let artworkData: Data?
        let ttmlLyricText: String?
        let lyricsText: String?
    }

    private struct ExistingTrackMatchSnapshot: Sendable {
        let preview: TrackPreview?
        let count: Int
    }

    private struct CandidatePreparationResult: Sendable {
        let index: Int
        let candidate: ImportCandidate
        let duplicateRow: DuplicatePairRow?
    }

    private struct NCMConversionTaskOutput: Sendable {
        let sourceURL: URL
        let displayName: String
        let result: NCMConversionResult?
        let errorDescription: String?
    }

    private struct ImportTaskOutput: Sendable {
        let index: Int
        let progressID: String
        let displayName: String
        let metadata: ImportPreview
        let payload: ImportedTrackPayload?
        let needsLyricsEnrichment: Bool
        let needsCoverEnrichment: Bool
        let errorDescription: String?
    }

    private struct ImportEnrichmentSnapshot: Sendable {
        let progressID: String
        let id: UUID
        let title: String
        let artist: String
        let album: String
        let duration: Double?
        let needsLyrics: Bool
        let needsCover: Bool
    }

    private struct ImportEnrichmentTaskOutput: Sendable {
        let progressID: String
        let trackID: UUID
        let title: String
        let artist: String
        let album: String
        let lyricOutcome: ImportLyricsLookupOutcome?
        let coverOutcome: ImportCoverLookupOutcome?
    }

    // MARK: - Supported Types

    nonisolated static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ncm",
    ]

    static let supportedUTTypes: [UTType] = [
        .mp3,
        .mpeg4Audio,
        .aiff,
        .wav,
        UTType(filenameExtension: "flac") ?? .audio,
        UTType(filenameExtension: "m4a") ?? .mpeg4Audio,
        UTType(filenameExtension: "alac") ?? .audio,
        UTType(filenameExtension: "ncm") ?? .audio,
    ].compactMap { $0 }

    // MARK: - Properties

    private let repository: LibraryRepositoryProtocol
    private let libraryService: LocalLibraryService
    private let importEnrichmentService: ImportEnrichmentService

    // MARK: - Initialization

    init(
        repository: LibraryRepositoryProtocol,
        libraryService: LocalLibraryService? = nil,
        importEnrichmentService: ImportEnrichmentService
    ) {
        self.repository = repository
        self.libraryService = libraryService ?? LocalLibraryService.shared
        self.importEnrichmentService = importEnrichmentService
        Log.debug("FileImportService initialized", category: .import)
    }

    // MARK: - Public Methods

    func pickImportURLs(triggeredAt: Date) async -> [URL]? {
        let clickClock = ContinuousClock.now
        Log.info("[ImportPanel] click timestamp: \(triggeredAt)", category: .import)
        let creationTimestamp = Date()
        Log.info("[ImportPanel] panel creation timestamp: \(creationTimestamp)", category: .import)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.supportedUTTypes
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        let beginTimestamp = Date()
        let clickToPresentationMs = Self.durationMilliseconds(since: clickClock)
        Log.info("[ImportPanel] panel begin timestamp: \(beginTimestamp)", category: .import)
        Log.info(
            "[ImportPanel] click -> presentation requested: \(String(format: "%.1f", clickToPresentationMs))ms",
            category: .import
        )

        let response: NSApplication.ModalResponse
        guard let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        else {
            Log.error("[ImportPanel] no host window available for attached sheet presentation", category: .import)
            return nil
        }
        response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { modalResponse in
                continuation.resume(returning: modalResponse)
            }
        }

        let selectionTimestamp = Date()
        let clickToSelectionMs = Self.durationMilliseconds(since: clickClock)
        Log.info("[ImportPanel] selection returned timestamp: \(selectionTimestamp)", category: .import)
        Log.info(
            "[ImportPanel] click -> selection return: \(String(format: "%.1f", clickToSelectionMs))ms",
            category: .import
        )

        guard response == .OK else {
            Log.debug("NSOpenPanel cancelled by user", category: .import)
            return nil
        }

        Log.debug("NSOpenPanel returned \(panel.urls.count) URLs", category: .import)
        if let first = panel.urls.first {
            Log.debug("   ↳ First URL: \(first.lastPathComponent)", category: .import)
        }
        return panel.urls
    }

    /// Import selected files/folders into a specific playlist.
    @discardableResult
    func importSelectedURLs(_ selectedURLs: [URL], to playlist: Playlist) async -> Int {
        Log.debug(
            "importSelectedURLs called for playlist: '\(playlist.name)' (id=\(playlist.id)) count=\(selectedURLs.count)",
            category: .import
        )
        let progressController = BatchImportProgressDialogController()
        defer { progressController.closeNow() }
        progressController.update(
            stage: .scanning,
            progress: Self.progress(for: .scanning, completed: 0, total: selectedURLs.count),
            detail: "正在扫描所选文件和文件夹中的音频文件",
            completedCount: 0,
            totalCount: selectedURLs.count
        )

        // CRITICAL: Start accessing security-scoped resources IMMEDIATELY
        // NSOpenPanel returns security-scoped URLs that expire if not accessed
        var accessingURLs: [URL] = []
        for url in selectedURLs {
            let didStart = url.startAccessingSecurityScopedResource()
            Log.trace("startAccessingSecurityScopedResource for '\(url.lastPathComponent)': \(didStart)", category: .import)

            // Additional diagnostics
            Log.trace("   ↳ URL.isFileURL: \(url.isFileURL)", category: .import)
            Log.trace("   ↳ URL.path: \(url.path)", category: .import)
            let isReadable = FileManager.default.isReadableFile(atPath: url.path)
            Log.trace("   ↳ FileManager.isReadableFile: \(isReadable)", category: .import)

            if didStart {
                accessingURLs.append(url)
            } else {
                Log.warning("Failed to start accessing security-scoped resource!", category: .import)
            }
        }

        // Ensure we stop accessing at the end
        defer {
            for url in accessingURLs {
                url.stopAccessingSecurityScopedResource()
                Log.trace("stopAccessingSecurityScopedResource for '\(url.lastPathComponent)'", category: .import)
            }
        }

        // Collect all audio files (including from directories) - OFF MAIN THREAD
        let (filesToImport, ncmFiles) = await Task.detached(priority: .userInitiated) { 
            var filesToImport: [URL] = []
            var ncmFiles: [URL] = []

            for url in selectedURLs {
                if url.hasDirectoryPath {
                    let audioFiles = FileImportService.findAudioFiles(in: url)
                    for file in audioFiles {
                        if FileImportService.isNCMFile(file) {
                            ncmFiles.append(file)
                        } else {
                            filesToImport.append(file)
                        }
                    }
                } else if FileImportService.isAudioFile(url) {
                    if FileImportService.isNCMFile(url) {
                        ncmFiles.append(url)
                    } else {
                        filesToImport.append(url)
                    }
                }
            }
            return (filesToImport, ncmFiles)
        }.value
        let discoveredFileCount = filesToImport.count + ncmFiles.count
        progressController.update(
            stage: .scanning,
            progress: Self.progress(for: .scanning, completed: discoveredFileCount, total: max(discoveredFileCount, 1)),
            detail: discoveredFileCount > 0 ? "已找到 \(discoveredFileCount) 个可导入文件" : "未找到支持的音频文件",
            completedCount: discoveredFileCount,
            totalCount: discoveredFileCount
        )

        guard discoveredFileCount > 0 else {
            Log.info("No supported audio files found in selection", category: .import)
            return 0
        }

        let discoveredItems = (filesToImport + ncmFiles).map {
            BatchImportProgressItemSeed(id: $0.path, fileName: $0.lastPathComponent)
        }
        progressController.setItems(discoveredItems)
        for fileURL in filesToImport {
            progressController.updateItem(
                id: fileURL.path,
                stage: .metadata,
                status: .waiting,
                detail: "等待解析歌曲信息"
            )
        }
        for sourceURL in ncmFiles {
            progressController.updateItem(
                id: sourceURL.path,
                stage: .ncmConversion,
                status: .waiting,
                detail: "等待转换 NCM 文件"
            )
        }

        var resolvedFiles: [ResolvedImportFile] = filesToImport.map {
            ResolvedImportFile(
                progressID: $0.path,
                displayName: $0.lastPathComponent,
                fileURL: $0,
                ncmResult: nil
            )
        }

        if !ncmFiles.isEmpty {
            Log.debug("Found \(ncmFiles.count) NCM files to convert", category: .import)
            let results = await convertNCMFiles(ncmFiles, progressController: progressController)
            for output in results {
                guard let result = output.result else { continue }
                resolvedFiles.append(
                    ResolvedImportFile(
                        progressID: output.sourceURL.path,
                        displayName: output.displayName,
                        fileURL: result.audioFileURL,
                        ncmResult: result
                    )
                )
            }
        } else {
            progressController.update(
                stage: .convertingNCM,
                progress: Self.progress(for: .convertingNCM, completed: 0, total: 0),
                detail: "未检测到 NCM 文件，跳过转换阶段",
                completedCount: 0,
                totalCount: 0
            )
        }

        Log.debug("Found \(resolvedFiles.count) audio files to import to '\(playlist.name)'", category: .import)

        let libraryTracks = await repository.fetchTracks(in: nil)
        let existingByDedupKey = Dictionary(grouping: libraryTracks) {
            LibraryNormalization.normalizedDedupKey(title: $0.title, artist: $0.artist)
        }
        let existingSnapshots = existingByDedupKey.mapValues { matches in
            ExistingTrackMatchSnapshot(
                preview: matches.first.map {
                    TrackPreview(
                        title: $0.title,
                        artist: $0.artist,
                        artworkData: $0.artworkData
                    )
                },
                count: matches.count
            )
        }

        let preparedCandidates = await prepareImportCandidates(
            files: resolvedFiles,
            existingMatches: existingSnapshots,
            progressController: progressController
        )
        let uniqueCandidates = preparedCandidates.unique
        let duplicateRows = preparedCandidates.duplicates

        var selectedDuplicates: [ImportCandidate] = []
        if !duplicateRows.isEmpty {
            Log.debug("Found \(duplicateRows.count) duplicates, presenting dialog...", category: .import)
            progressController.update(
                stage: .waitingForDuplicateChoice,
                progress: Self.progress(for: .waitingForDuplicateChoice, completed: duplicateRows.count, total: duplicateRows.count),
                detail: "发现 \(duplicateRows.count) 首重复歌曲，等待选择是否继续导入",
                completedCount: duplicateRows.count,
                totalCount: duplicateRows.count
            )
            if let selectedRows = presentDuplicateSelectionDialog(duplicateRows) {
                Log.info("Dialog confirmed. Selected duplicates to import: \(selectedRows.count)", category: .import)
                let selectedIDSet = Set(selectedRows.map(\.id))
                selectedDuplicates = duplicateRows.compactMap { row in
                    if selectedIDSet.contains(row.id) {
                        progressController.updateItem(
                            id: row.id,
                            title: row.incoming.title,
                            artist: row.incoming.artist,
                            stage: .duplicateCheck,
                            status: .success,
                            detail: "已选择继续导入重复歌曲"
                        )
                        return ImportCandidate(
                            progressID: row.id,
                            displayName: row.fileURL.lastPathComponent,
                            fileURL: row.fileURL,
                            metadata: row.incoming
                        )
                    }

                    progressController.updateItem(
                        id: row.id,
                        title: row.incoming.title,
                        artist: row.incoming.artist,
                        stage: .duplicateCheck,
                        status: .skipped,
                        detail: "检测到重复，已跳过导入"
                    )
                    return nil
                }
            } else {
                Log.debug("User cancelled import via duplicate dialog (result was nil)", category: .import)
                return 0
            }
        }

        // Logic Verification Logs
        Log.debug("--------------------------------------------------", category: .import)
        Log.debug("Import Logic Verification:", category: .import)
        Log.debug("   Unique Candidates : \(uniqueCandidates.count)", category: .import)
        Log.debug("   Duplicate Rows    : \(duplicateRows.count)", category: .import)
        Log.debug("   Selected Dups     : \(selectedDuplicates.count)", category: .import)

        let finalCandidates = uniqueCandidates + selectedDuplicates
        Log.debug("   -> FINAL Candidates: \(finalCandidates.count)", category: .import)
        Log.debug("--------------------------------------------------", category: .import)

        progressController.update(
            stage: .importingFiles,
            progress: Self.progress(for: .importingFiles, completed: 0, total: finalCandidates.count),
            detail: finalCandidates.isEmpty
                ? "没有需要导入的新歌曲"
                : "准备导入 \(finalCandidates.count) 首歌曲",
            completedCount: 0,
            totalCount: finalCandidates.count
        )

        let enrichmentMode: ImportEnrichmentMode =
            AppSettings.shared.deferImportEnrichment ? .deferred : .immediate
        let importedRecords = await importCandidatesWithProgress(
            finalCandidates,
            progressController: progressController,
            enrichmentMode: enrichmentMode
        )

        guard !importedRecords.isEmpty else {
            print("⚠️ No tracks to import")
            return 0
        }

        let importedTracks = importedRecords.map(\.track)

        switch enrichmentMode {
        case .immediate:
            let recordsNeedingEnrichment = importedRecords.filter(\.needsAnyEnrichment)
            if !recordsNeedingEnrichment.isEmpty {
                await enrichImportedRecordsWithProgress(
                    importedRecords: recordsNeedingEnrichment,
                    progressController: progressController
                )
            } else {
                progressController.update(
                    stage: .enrichingMetadata,
                    progress: Self.progress(for: .enrichingMetadata, completed: 0, total: 0),
                    detail: "所有歌曲已有歌词与封面，跳过在线补全",
                    completedCount: 0,
                    totalCount: 0
                )
            }

            await saveImportedTracks(
                importedTracks,
                to: playlist,
                progressController: progressController
            )
        case .deferred:
            let recordsNeedingEnrichment = importedRecords.filter(\.needsAnyEnrichment)
            if !recordsNeedingEnrichment.isEmpty {
                progressController.update(
                    stage: .enrichingMetadata,
                    progress: Self.progress(
                        for: .enrichingMetadata,
                        completed: 0,
                        total: recordsNeedingEnrichment.count
                    ),
                    detail: "导入完成后将在后台补全 \(recordsNeedingEnrichment.count) 首歌曲的歌词与封面",
                    completedCount: 0,
                    totalCount: recordsNeedingEnrichment.count
                )
            } else {
                progressController.update(
                    stage: .enrichingMetadata,
                    progress: Self.progress(for: .enrichingMetadata, completed: 0, total: 0),
                    detail: "所有歌曲已有歌词与封面，无需后台补全",
                    completedCount: 0,
                    totalCount: 0
                )
            }

            await saveImportedTracks(
                importedTracks,
                to: playlist,
                progressController: progressController
            )

            if !recordsNeedingEnrichment.isEmpty {
                importEnrichmentService.enqueueTracks(recordsNeedingEnrichment.map(\.track))
            }
        }

        for record in importedRecords {
            progressController.completeImportedItem(id: record.progressID)
        }

        progressController.update(
            stage: .savingLibrary,
            progress: Self.progress(for: .savingLibrary, completed: 2, total: 2),
            detail: "资料库与播放列表保存完成",
            completedCount: 2,
            totalCount: 2
        )

        progressController.update(
            stage: .completed,
            progress: 1.0,
            detail: "已成功导入 \(importedRecords.count) 首歌曲到“\(playlist.name)”",
            completedCount: importedTracks.count,
            totalCount: finalCandidates.count
        )
        try? await Task.sleep(nanoseconds: 500_000_000)

        print("✅ Import complete: \(importedRecords.count) imported")
        return importedRecords.count
    }

    // MARK: - Private Methods

    /// Import a single audio file, creating a Track with bookmark.
    /// ASSUMES: Parent caller has already started accessing security-scoped resource.
    private func importFile(
        url: URL,
        metadata: (title: String, artist: String, album: String, duration: Double, lyrics: String?),
        preloadedArtworkData: Data?
    ) async -> Track? {
        let candidate = ImportCandidate(
            progressID: url.path,
            displayName: url.lastPathComponent,
            fileURL: url,
            metadata: ImportPreview(
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                duration: metadata.duration,
                lyrics: metadata.lyrics,
                artworkData: preloadedArtworkData
            )
        )

        let output = await Self.performImportTask(index: 0, candidate: candidate)
        guard let payload = output.payload else {
            if let errorDescription = output.errorDescription {
                print("❌ Failed to import \(url.lastPathComponent): \(errorDescription)")
            }
            return nil
        }
        return makeTrack(from: payload)
    }

    private func importCandidatesWithProgress(
        _ candidates: [ImportCandidate],
        progressController: BatchImportProgressDialogController,
        enrichmentMode: ImportEnrichmentMode
    ) async -> [ImportedTrackRecord] {
        guard !candidates.isEmpty else { return [] }

        var orderedRecords = Array<ImportedTrackRecord?>(repeating: nil, count: candidates.count)
        var iterator = Array(candidates.enumerated()).makeIterator()
        let maxConcurrent = Self.importConcurrency(for: candidates.count)
        var processedCount = 0
        var importedCount = 0
        var failedCount = 0

        await withTaskGroup(of: ImportTaskOutput.self) { group in
            for _ in 0..<min(maxConcurrent, candidates.count) {
                guard let (index, candidate) = iterator.next() else { break }
                progressController.updateItem(
                    id: candidate.progressID,
                    title: candidate.metadata.title,
                    artist: candidate.metadata.artist,
                    stage: .importing,
                    status: .active,
                    detail: "正在导入歌曲文件与内嵌信息"
                )
                group.addTask {
                    await Self.performImportTask(index: index, candidate: candidate)
                }
            }

            while let output = await group.next() {
                processedCount += 1

                if let payload = output.payload {
                    importedCount += 1
                    let track = makeTrack(from: payload)
                    orderedRecords[output.index] = ImportedTrackRecord(
                        progressID: output.progressID,
                        displayName: output.displayName,
                        track: track,
                        needsLyricsEnrichment: output.needsLyricsEnrichment,
                        needsCoverEnrichment: output.needsCoverEnrichment
                    )

                    let needsEnrichment = output.needsLyricsEnrichment || output.needsCoverEnrichment
                    let detail = needsEnrichment
                        ? Self.pendingEnrichmentDetail(
                            needsLyrics: output.needsLyricsEnrichment,
                            needsCover: output.needsCoverEnrichment,
                            deferred: enrichmentMode.defersEnrichment
                        )
                        : "歌曲文件已就绪，已有歌词与封面"
                    progressController.updateItem(
                        id: output.progressID,
                        title: output.metadata.title,
                        artist: output.metadata.artist,
                        stage: needsEnrichment ? .enrichingMetadata : .importing,
                        status: needsEnrichment ? .waiting : .success,
                        detail: detail
                    )
                } else {
                    failedCount += 1
                    progressController.updateItem(
                        id: output.progressID,
                        title: output.metadata.title,
                        artist: output.metadata.artist,
                        stage: .importing,
                        status: .failed,
                        detail: "导入失败",
                        issueMessage: output.errorDescription ?? "文件复制或解析阶段失败"
                    )
                }

                let detail =
                    failedCount == 0
                    ? "已导入 \(importedCount) / \(candidates.count)"
                    : "已导入 \(importedCount) / \(candidates.count)，失败 \(failedCount) 首"
                progressController.update(
                    stage: .importingFiles,
                    progress: Self.progress(
                        for: .importingFiles,
                        completed: processedCount,
                        total: candidates.count
                    ),
                    detail: detail,
                    completedCount: processedCount,
                    totalCount: candidates.count
                )

                if let (index, candidate) = iterator.next() {
                    progressController.updateItem(
                        id: candidate.progressID,
                        title: candidate.metadata.title,
                        artist: candidate.metadata.artist,
                        stage: .importing,
                        status: .active,
                        detail: "正在导入歌曲文件与内嵌信息"
                    )
                    group.addTask {
                        await Self.performImportTask(index: index, candidate: candidate)
                    }
                }
            }
        }

        return orderedRecords.compactMap { $0 }
    }

    private func saveImportedTracks(
        _ importedTracks: [Track],
        to playlist: Playlist,
        progressController: BatchImportProgressDialogController
    ) async {
        progressController.update(
            stage: .savingLibrary,
            progress: Self.progress(for: .savingLibrary, completed: 0, total: 2),
            detail: "正在写入资料库和播放列表",
            completedCount: 0,
            totalCount: 2
        )

        await repository.addTracks(importedTracks)
        progressController.update(
            stage: .savingLibrary,
            progress: Self.progress(for: .savingLibrary, completed: 1, total: 2),
            detail: "歌曲已写入资料库，正在加入播放列表",
            completedCount: 1,
            totalCount: 2
        )

        if !importedTracks.isEmpty {
            print("🔗 Adding \(importedTracks.count) tracks to playlist '\(playlist.name)'")
            await repository.addTracks(importedTracks, to: playlist)
        }

        progressController.update(
            stage: .savingLibrary,
            progress: Self.progress(for: .savingLibrary, completed: 2, total: 2),
            detail: "资料库与播放列表保存完成",
            completedCount: 2,
            totalCount: 2
        )
    }

    private func makeTrack(from payload: ImportedTrackPayload) -> Track {
        Track(
            id: payload.id,
            title: payload.title,
            artist: payload.artist,
            album: payload.album,
            duration: payload.duration,
            importedAt: payload.importedAt,
            fileBookmarkData: Data(),
            originalFilePath: payload.originalFilePath,
            libraryRelativePath: payload.libraryRelativePath,
            artworkData: payload.artworkData,
            ttmlLyricText: payload.ttmlLyricText,
            lyricsText: payload.lyricsText
        )
    }
    
    private func prepareImportCandidates(
        files: [ResolvedImportFile],
        existingMatches: [String: ExistingTrackMatchSnapshot],
        progressController: BatchImportProgressDialogController
    ) async -> (unique: [ImportCandidate], duplicates: [DuplicatePairRow]) {
        guard !files.isEmpty else { return ([], []) }

        progressController.update(
            stage: .readingMetadata,
            progress: Self.progress(for: .readingMetadata, completed: 0, total: files.count),
            detail: "正在解析歌曲元数据并检查重复项",
            completedCount: 0,
            totalCount: files.count
        )

        var orderedResults = Array<CandidatePreparationResult?>(repeating: nil, count: files.count)
        var iterator = Array(files.enumerated()).makeIterator()
        let maxConcurrent = Self.metadataConcurrency(for: files.count)
        var completedCount = 0

        await withTaskGroup(of: CandidatePreparationResult.self) { group in
            for _ in 0..<min(maxConcurrent, files.count) {
                guard let (index, file) = iterator.next() else { break }
                progressController.updateItem(
                    id: file.progressID,
                    stage: .metadata,
                    status: .active,
                    detail: "正在读取歌曲标题、歌手和专辑信息"
                )
                group.addTask {
                    await Self.buildCandidatePreparationResult(
                        index: index,
                        file: file,
                        existingMatches: existingMatches
                    )
                }
            }

            while let output = await group.next() {
                orderedResults[output.index] = output
                completedCount += 1

                progressController.update(
                    stage: .readingMetadata,
                    progress: Self.progress(
                        for: .readingMetadata,
                        completed: completedCount,
                        total: files.count
                    ),
                    detail: "已解析 \(completedCount) / \(files.count) 首歌曲",
                    completedCount: completedCount,
                    totalCount: files.count
                )

                let itemStatus: BatchImportItemStatus = output.duplicateRow == nil ? .success : .warning
                let itemDetail = output.duplicateRow == nil ? "歌曲信息解析完成，未发现重复" : "检测到重复歌曲，等待用户选择"
                progressController.updateItem(
                    id: output.candidate.progressID,
                    title: output.candidate.metadata.title,
                    artist: output.candidate.metadata.artist,
                    stage: .duplicateCheck,
                    status: itemStatus,
                    detail: itemDetail
                )

                if let (index, file) = iterator.next() {
                    progressController.updateItem(
                        id: file.progressID,
                        stage: .metadata,
                        status: .active,
                        detail: "正在读取歌曲标题、歌手和专辑信息"
                    )
                    group.addTask {
                        await Self.buildCandidatePreparationResult(
                            index: index,
                            file: file,
                            existingMatches: existingMatches
                        )
                    }
                }
            }
        }

        var uniqueCandidates: [ImportCandidate] = []
        var duplicateRows: [DuplicatePairRow] = []

        for output in orderedResults.compactMap({ $0 }) {
            if let duplicateRow = output.duplicateRow {
                duplicateRows.append(duplicateRow)
            } else {
                uniqueCandidates.append(output.candidate)
            }
        }

        return (uniqueCandidates, duplicateRows)
    }

    nonisolated private static func buildCandidatePreparationResult(
        index: Int,
        file: ResolvedImportFile,
        existingMatches: [String: ExistingTrackMatchSnapshot]
    ) async -> CandidatePreparationResult {
        let preview: ImportPreview
        if let ncmResult = file.ncmResult {
            preview = ImportPreview(
                title: ncmResult.metadata.title,
                artist: ncmResult.metadata.artistName,
                album: ncmResult.metadata.album,
                duration: ncmResult.metadata.durationSeconds,
                lyrics: nil,
                artworkData: ncmResult.coverData
            )
        } else {
            let raw = await Self.extractMetadata(from: file.fileURL)
            preview = ImportPreview(
                title: raw.title,
                artist: raw.artist,
                album: raw.album,
                duration: raw.duration,
                lyrics: raw.lyrics,
                artworkData: nil
            )
        }

        let candidate = ImportCandidate(
            progressID: file.progressID,
            displayName: file.displayName,
            fileURL: file.fileURL,
            metadata: preview
        )
        let dedupKey = LibraryNormalization.normalizedDedupKey(
            title: preview.title,
            artist: preview.artist
        )

        guard let existingMatch = existingMatches[dedupKey], existingMatch.count > 0 else {
            return CandidatePreparationResult(index: index, candidate: candidate, duplicateRow: nil)
        }

        let duplicateRow = DuplicatePairRow(
            id: file.progressID,
            fileURL: file.fileURL,
            incoming: preview,
            existing: existingMatch.preview,
            existingCount: existingMatch.count,
            dedupKey: dedupKey
        )
        return CandidatePreparationResult(
            index: index,
            candidate: candidate,
            duplicateRow: duplicateRow
        )
    }

    // MARK: - Immediate Enrichment

    private func enrichImportedRecordsWithProgress(
        importedRecords: [ImportedTrackRecord],
        progressController: BatchImportProgressDialogController
    ) async {
        guard !importedRecords.isEmpty else { return }

        progressController.update(
            stage: .enrichingMetadata,
            progress: Self.progress(
                for: .enrichingMetadata,
                completed: 0,
                total: importedRecords.count
            ),
            detail: "准备补全 \(importedRecords.count) 首歌曲的歌词与封面",
            completedCount: 0,
            totalCount: importedRecords.count
        )

        let snapshots = importedRecords.map {
            ImportEnrichmentSnapshot(
                progressID: $0.progressID,
                id: $0.track.id,
                title: $0.track.title,
                artist: $0.track.artist,
                album: $0.track.album,
                duration: $0.track.duration > 0 ? $0.track.duration : nil,
                needsLyrics: $0.needsLyricsEnrichment,
                needsCover: $0.needsCoverEnrichment
            )
        }
        let recordsByTrackID = Dictionary(
            uniqueKeysWithValues: importedRecords.map { ($0.track.id, $0) }
        )
        let maxConcurrent = Self.enrichmentConcurrency(for: snapshots.count)
        var iterator = snapshots.makeIterator()
        var completedCount = 0
        var lyricSuccessCount = 0
        var coverSuccessCount = 0
        var noResultCount = 0
        var failedCount = 0

        await withTaskGroup(of: ImportEnrichmentTaskOutput.self) { group in
            for _ in 0..<min(maxConcurrent, snapshots.count) {
                guard let snapshot = iterator.next() else { break }
                progressController.updateItem(
                    id: snapshot.progressID,
                    title: snapshot.title,
                    artist: snapshot.artist,
                    stage: .enrichingMetadata,
                    status: .active,
                    detail: Self.activeEnrichmentDetail(
                        needsLyrics: snapshot.needsLyrics,
                        needsCover: snapshot.needsCover
                    )
                )
                group.addTask {
                    await Self.performImmediateEnrichmentTask(snapshot: snapshot)
                }
            }

            while let output = await group.next() {
                completedCount += 1

                let (status, detail, lyricStats, coverStats, misses, failures) =
                    Self.applyImmediateEnrichmentResult(
                        output,
                        to: recordsByTrackID[output.trackID]
                    )
                lyricSuccessCount += lyricStats
                coverSuccessCount += coverStats
                noResultCount += misses
                failedCount += failures

                progressController.updateItem(
                    id: output.progressID,
                    title: output.title,
                    artist: output.artist,
                    stage: .enrichingMetadata,
                    status: status,
                    detail: detail
                )

                if case .warning = status, detail.contains("失败") {
                    Log.warning(
                        "Immediate import enrichment completed with warning for \(output.title) - \(output.artist)",
                        category: .import
                    )
                }

                progressController.update(
                    stage: .enrichingMetadata,
                    progress: Self.progress(
                        for: .enrichingMetadata,
                        completed: completedCount,
                        total: snapshots.count
                    ),
                    detail: Self.enrichmentProgressDetail(
                        completed: completedCount,
                        total: snapshots.count,
                        lyricSuccessCount: lyricSuccessCount,
                        coverSuccessCount: coverSuccessCount,
                        noResultCount: noResultCount,
                        failedCount: failedCount
                    ),
                    completedCount: completedCount,
                    totalCount: snapshots.count
                )

                if let snapshot = iterator.next() {
                    progressController.updateItem(
                        id: snapshot.progressID,
                        title: snapshot.title,
                        artist: snapshot.artist,
                        stage: .enrichingMetadata,
                        status: .active,
                        detail: Self.activeEnrichmentDetail(
                            needsLyrics: snapshot.needsLyrics,
                            needsCover: snapshot.needsCover
                        )
                    )
                    group.addTask {
                        await Self.performImmediateEnrichmentTask(snapshot: snapshot)
                    }
                }
            }
        }
    }

    nonisolated private static func performImmediateEnrichmentTask(
        snapshot: ImportEnrichmentSnapshot
    ) async -> ImportEnrichmentTaskOutput {
        let lyricTask = snapshot.needsLyrics
            ? Task {
                await ImportEnrichmentWorker.fetchLyrics(
                    title: snapshot.title,
                    artist: snapshot.artist,
                    album: snapshot.album,
                    duration: snapshot.duration
                )
            }
            : nil
        let coverTask = snapshot.needsCover
            ? Task {
                await ImportEnrichmentWorker.fetchCover(
                    artist: snapshot.artist,
                    album: snapshot.album
                )
            }
            : nil

        return ImportEnrichmentTaskOutput(
            progressID: snapshot.progressID,
            trackID: snapshot.id,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            lyricOutcome: await lyricTask?.value,
            coverOutcome: await coverTask?.value
        )
    }

    private static func applyImmediateEnrichmentResult(
        _ output: ImportEnrichmentTaskOutput,
        to record: ImportedTrackRecord?
    ) -> (BatchImportItemStatus, String, Int, Int, Int, Int) {
        guard let record else {
            return (.warning, "补全结果未能写回，歌曲已保留导入", 0, 0, 0, 1)
        }

        var detailParts: [String] = []
        var status: BatchImportItemStatus = .success
        var lyricSuccessCount = 0
        var coverSuccessCount = 0
        var noResultCount = 0
        var failedCount = 0

        if let lyricOutcome = output.lyricOutcome {
            switch lyricOutcome {
            case .completed(let ttml):
                if record.track.ttmlLyricText == nil {
                    record.track.ttmlLyricText = ttml
                }
                lyricSuccessCount += 1
                detailParts.append("歌词已补全")
            case .noResults:
                noResultCount += 1
                status = .warning
                detailParts.append("未找到歌词")
            case .failed:
                failedCount += 1
                status = .warning
                detailParts.append("歌词补全失败")
            }
        }

        if let coverOutcome = output.coverOutcome {
            switch coverOutcome {
            case .completed(let artworkData):
                if record.track.artworkData == nil {
                    record.track.artworkData = artworkData
                }
                coverSuccessCount += 1
                detailParts.append("封面已补全")
            case .noResults:
                noResultCount += 1
                status = .warning
                detailParts.append("未找到封面")
            case .failed:
                failedCount += 1
                status = .warning
                detailParts.append("封面补全失败")
            }
        }

        if detailParts.isEmpty {
            detailParts.append("歌曲已导入")
        }

        return (
            status,
            detailParts.joined(separator: "，"),
            lyricSuccessCount,
            coverSuccessCount,
            noResultCount,
            failedCount
        )
    }

    nonisolated private static func enrichmentProgressDetail(
        completed: Int,
        total: Int,
        lyricSuccessCount: Int,
        coverSuccessCount: Int,
        noResultCount: Int,
        failedCount: Int
    ) -> String {
        var parts = ["已处理 \(completed) / \(total)"]
        if lyricSuccessCount > 0 {
            parts.append("歌词 \(lyricSuccessCount)")
        }
        if coverSuccessCount > 0 {
            parts.append("封面 \(coverSuccessCount)")
        }
        if noResultCount > 0 {
            parts.append("未找到 \(noResultCount)")
        }
        if failedCount > 0 {
            parts.append("失败 \(failedCount)")
        }
        return parts.joined(separator: "，")
    }

    nonisolated private static func pendingEnrichmentDetail(
        needsLyrics: Bool,
        needsCover: Bool,
        deferred: Bool
    ) -> String {
        let work = enrichmentWorkLabel(needsLyrics: needsLyrics, needsCover: needsCover)
        if deferred {
            return "歌曲文件已就绪，导入后将在后台补全\(work)"
        }
        return "歌曲文件已就绪，等待补全\(work)"
    }

    nonisolated private static func activeEnrichmentDetail(
        needsLyrics: Bool,
        needsCover: Bool
    ) -> String {
        "正在补全\(enrichmentWorkLabel(needsLyrics: needsLyrics, needsCover: needsCover))"
    }

    nonisolated private static func enrichmentWorkLabel(
        needsLyrics: Bool,
        needsCover: Bool
    ) -> String {
        switch (needsLyrics, needsCover) {
        case (true, true):
            return "歌词与封面"
        case (true, false):
            return "歌词"
        case (false, true):
            return "封面"
        case (false, false):
            return "导入信息"
        }
    }

    /// Extract metadata from audio file using AVAsset.
    /// Made nonisolated static to allow concurrent execution from TaskGroup.
    nonisolated private static func extractMetadata(from url: URL) async -> (
        title: String, artist: String, album: String, duration: Double, lyrics: String?
    ) {
        let asset = AVURLAsset(url: url)

        // Default values
        var title: String?
        var artist: String?
        var album: String?
        var lyrics: String?
        var duration: Double = 0

        // Get duration
        do {
            let durationTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(durationTime)
        } catch {
            print("⚠️ Failed to load duration: \(error)")
        }

        // Collect all metadata items: common first, then full set as fallback
        var allItems: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) {
            allItems.append(contentsOf: common)
        }
        if let full = try? await asset.load(.metadata) {
            allItems.append(contentsOf: full)
        }

        for item in allItems {
            // 1. Try Common Key
            if let key = item.commonKey?.rawValue {
                switch key {
                case "title":
                    if title == nil { title = try? await item.load(.stringValue) }
                case "artist":
                    if artist == nil { artist = try? await item.load(.stringValue) }
                case "albumName":
                    if album == nil { album = try? await item.load(.stringValue) }
                case "lyrics":
                    if lyrics == nil { lyrics = try? await item.load(.stringValue) }
                default:
                    break
                }
            }

            // 2. Try raw key string (fallback for FLAC / Vorbis Comment tags)
            if let keyString = (item.key as? String)?.uppercased() {
                if title == nil && keyString == "TITLE" {
                    title = try? await item.load(.stringValue)
                }
                if artist == nil && keyString == "ARTIST" {
                    artist = try? await item.load(.stringValue)
                }
                if album == nil && (keyString == "ALBUM" || keyString == "ALBUMTITLE") {
                    album = try? await item.load(.stringValue)
                }
                if lyrics == nil
                    && (keyString == "LYRICS" || keyString == "UNSYNCEDLYRICS"
                        || keyString == "USLT")
                {
                    lyrics = try? await item.load(.stringValue)
                }
            }

            // 3. ID3 USLT via identifier
            if lyrics == nil,
                let identifier = item.identifier?.rawValue,
                identifier == "id3/USLT"
            {
                lyrics = try? await item.load(.stringValue)
            }
        }

        // 4. Fallback: Try Spotlight Metadata (MDItem) if AVAsset failed
        // This handles cases where file has atypical tags or is only recognized by system indexers
        if title == nil || artist == nil {
            if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
                // Title
                if title == nil {
                    if let mdTitle = MDItemCopyAttribute(mdItem, kMDItemTitle) as? String {
                        title = mdTitle
                    }
                }

                // Artist (Authors)
                if artist == nil {
                    if let mdAuthors = MDItemCopyAttribute(mdItem, kMDItemAuthors) as? [String],
                        let firstAuthor = mdAuthors.first
                    {
                        artist = firstAuthor
                    }
                }

                // Album
                if album == nil {
                    if let mdAlbum = MDItemCopyAttribute(mdItem, kMDItemAlbum) as? String {
                        album = mdAlbum
                    }
                }
            }
        }

        // Apply defaults
        let finalTitle = title ?? url.deletingPathExtension().lastPathComponent
        let finalArtist = artist ?? NSLocalizedString("library.unknown_artist", comment: "")
        let finalAlbum = album ?? NSLocalizedString("library.unknown_album", comment: "")

        return (finalTitle, finalArtist, finalAlbum, duration, lyrics)
    }

    /// Extract artwork from audio file.
    nonisolated static func extractArtwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)

        // Collect all metadata items
        var allItems: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) {
            allItems.append(contentsOf: common)
        }
        if let full = try? await asset.load(.metadata) {
            allItems.append(contentsOf: full)
        }

        for item in allItems {
            if let key = item.commonKey?.rawValue, key == "artwork" {
                if let data = try? await item.load(.dataValue) {
                    return data
                }
            }
        }

        return nil
    }

    /// Recursively find audio files in a directory.
    /// Made nonisolated static to allow calling from background tasks.
    nonisolated private static func findAudioFiles(in directory: URL) -> [URL] {
        var audioFiles: [URL] = []

        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return audioFiles
        }

        for case let fileURL as URL in enumerator {
            if Self.isAudioFile(fileURL) {
                audioFiles.append(fileURL)
            }
        }

        return audioFiles
    }

    /// Check if a URL is a supported audio file.
    /// Made nonisolated static to allow calling from background tasks.
    nonisolated private static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.supportedExtensions.contains(ext)
    }

    /// Check if a URL is an NCM file.
    /// Made nonisolated static to allow calling from background tasks.
    nonisolated private static func isNCMFile(_ url: URL) -> Bool {
        return url.pathExtension.lowercased() == "ncm"
    }

    /// Convert NCM files and return conversion results with metadata.
    private func convertNCMFiles(
        _ ncmFiles: [URL],
        progressController: BatchImportProgressDialogController
    ) async -> [NCMConversionTaskOutput] {
        guard !ncmFiles.isEmpty else { return [] }

        progressController.update(
            stage: .convertingNCM,
            progress: Self.progress(for: .convertingNCM, completed: 0, total: ncmFiles.count),
            detail: "准备转换 \(ncmFiles.count) 个 NCM 文件",
            completedCount: 0,
            totalCount: ncmFiles.count
        )

        var results: [NCMConversionTaskOutput] = []
        var iterator = ncmFiles.makeIterator()
        let maxConcurrent = Self.ncmConcurrency(for: ncmFiles.count)
        var completedCount = 0
        var failureCount = 0

        await withTaskGroup(of: NCMConversionTaskOutput.self) { group in
            for _ in 0..<min(maxConcurrent, ncmFiles.count) {
                guard let sourceURL = iterator.next() else { break }
                progressController.updateItem(
                    id: sourceURL.path,
                    stage: .ncmConversion,
                    status: .active,
                    detail: "正在解密并转换 NCM 文件"
                )
                group.addTask {
                    await Self.runNCMConversionTask(sourceURL: sourceURL)
                }
            }

            while let output = await group.next() {
                completedCount += 1
                results.append(output)
                if output.result != nil {
                    progressController.updateItem(
                        id: output.sourceURL.path,
                        title: output.result?.metadata.title,
                        artist: output.result?.metadata.artistName,
                        stage: .ncmConversion,
                        status: .success,
                        detail: "NCM 转换完成，等待导入"
                    )
                } else {
                    failureCount += 1
                    progressController.updateItem(
                        id: output.sourceURL.path,
                        stage: .ncmConversion,
                        status: .failed,
                        detail: "NCM 转换失败",
                        issueMessage: output.errorDescription
                    )
                }

                let detail =
                    failureCount == 0
                    ? "已转换 \(completedCount) / \(ncmFiles.count)"
                    : "已处理 \(completedCount) / \(ncmFiles.count)，失败 \(failureCount) 个"
                progressController.update(
                    stage: .convertingNCM,
                    progress: Self.progress(
                        for: .convertingNCM,
                        completed: completedCount,
                        total: ncmFiles.count
                    ),
                    detail: detail,
                    completedCount: completedCount,
                    totalCount: ncmFiles.count
                )

                if let sourceURL = iterator.next() {
                    progressController.updateItem(
                        id: sourceURL.path,
                        stage: .ncmConversion,
                        status: .active,
                        detail: "正在解密并转换 NCM 文件"
                    )
                    group.addTask {
                        await Self.runNCMConversionTask(sourceURL: sourceURL)
                    }
                }
            }
        }

        return results
    }

    nonisolated private static func runNCMConversionTask(sourceURL: URL) async -> NCMConversionTaskOutput {
        do {
            let converter = NCMConverter()
            let result = try await converter.convert(
                from: sourceURL,
                fetchCover: true,
                progressHandler: nil
            )
            return NCMConversionTaskOutput(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                result: result,
                errorDescription: nil
            )
        } catch {
            Log.warning("NCM conversion failed for \(sourceURL.lastPathComponent): \(error)", category: .import)
            return NCMConversionTaskOutput(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                result: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    nonisolated private static func progress(
        for stage: BatchImportStage,
        completed: Int,
        total: Int
    ) -> Double {
        let range = stage.progressRange
        guard total > 0 else { return range.upperBound }
        let ratio = min(max(Double(completed) / Double(total), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * ratio
    }

    nonisolated private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    nonisolated private static func performImportTask(
        index: Int,
        candidate: ImportCandidate
    ) async -> ImportTaskOutput {
        let trackId = UUID()
        let importedAt = Date()

        async let extractedArtworkTask: Data? = {
            if let preloadedArtworkData = candidate.metadata.artworkData {
                return preloadedArtworkData
            }
            return await Self.extractArtwork(from: candidate.fileURL)
        }()
        async let embeddedLyricsTask = Self.prepareEmbeddedTTMLLyrics(candidate.metadata.lyrics)

        do {
            let libraryRelativePath = try Self.importAudioFileToLibrary(
                from: candidate.fileURL,
                trackId: trackId
            )

            let artworkData = await extractedArtworkTask
            let ttmlLyricText = await embeddedLyricsTask

            return ImportTaskOutput(
                index: index,
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: ImportedTrackPayload(
                    id: trackId,
                    title: candidate.metadata.title,
                    artist: candidate.metadata.artist,
                    album: candidate.metadata.album,
                    duration: candidate.metadata.duration,
                    importedAt: importedAt,
                    originalFilePath: candidate.fileURL.path,
                    libraryRelativePath: libraryRelativePath,
                    artworkData: artworkData,
                    ttmlLyricText: ttmlLyricText,
                    lyricsText: nil
                ),
                needsLyricsEnrichment: ttmlLyricText == nil,
                needsCoverEnrichment: artworkData == nil,
                errorDescription: nil
            )
        } catch {
            let _ = await extractedArtworkTask
            let _ = await embeddedLyricsTask
            return ImportTaskOutput(
                index: index,
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: nil,
                needsLyricsEnrichment: false,
                needsCoverEnrichment: false,
                errorDescription: error.localizedDescription
            )
        }
    }

    nonisolated private static func prepareEmbeddedTTMLLyrics(_ embeddedLyrics: String?) async -> String? {
        guard let embeddedLyrics, !embeddedLyrics.isEmpty else { return nil }
        if embeddedLyrics.lowercased().contains("<tt") {
            return embeddedLyrics
        }
        return try? await TTMLConverter.shared.convertToTTML(
            rawLyrics: embeddedLyrics,
            stripMetadata: true
        )
    }

    nonisolated private static func importAudioFileToLibrary(
        from sourceURL: URL,
        trackId: UUID
    ) throws -> String {
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: LocalLibraryPaths.libraryRootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: LocalLibraryPaths.tracksRootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: LocalLibraryPaths.playlistsRootURL,
            withIntermediateDirectories: true
        )

        let trackFolder = LocalLibraryPaths.trackFolderURL(for: trackId)
        try fileManager.createDirectory(at: trackFolder, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeExt = ext.isEmpty ? "audio" : ext
        let audioFileName = "audio.\(safeExt)"
        let destURL = trackFolder.appendingPathComponent(audioFileName)

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)

        return "Tracks/\(trackId.uuidString)/\(audioFileName)"
    }

    nonisolated private static func metadataConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(12, max(4, cpuCount * 2)))
    }

    nonisolated private static func ncmConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(6, max(2, cpuCount)))
    }

    nonisolated private static func importConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(6, max(3, cpuCount)))
    }

    nonisolated private static func enrichmentConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(4, max(2, cpuCount / 2)))
    }

    @MainActor
    private func presentDuplicateSelectionDialog(_ duplicateRows: [DuplicatePairRow])
        -> [DuplicatePairRow]?
    {
        return DuplicateImportDialogPresenter.present(
            rows: duplicateRows
        )
    }
}

// MARK: - Batch Import Progress

private struct BatchImportProgressItemSeed {
    let id: String
    let fileName: String
}

@MainActor
@Observable
private final class BatchImportProgressItemModel: Identifiable {
    let id: String
    let fileName: String
    var title: String = ""
    var artist: String = ""
    var stage: BatchImportItemStage = .scanning
    var status: BatchImportItemStatus = .waiting
    var detail: String = ""
    var issueMessage: String?

    init(id: String, fileName: String) {
        self.id = id
        self.fileName = fileName
    }
}

@MainActor
@Observable
private final class BatchImportProgressViewModel {
    var stage: BatchImportStage = .scanning
    var progress: Double = 0
    var detail: String = ""
    var completedCount: Int = 0
    var totalCount: Int = 0
    var items: [BatchImportProgressItemModel] = []

    var sortedItems: [BatchImportProgressItemModel] {
        items
    }
}

@MainActor
private final class BatchImportProgressDialogController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let viewModel = BatchImportProgressViewModel()
    private var isClosed = false

    override init() {
        super.init()

        let windowSize = NSSize(width: 600, height: 560)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.frame = NSRect(origin: .zero, size: windowSize)
        visualEffect.autoresizingMask = [.width, .height]
        panel.contentView = visualEffect

        let rootView = BatchImportProgressDialogView(viewModel: viewModel)
            .frame(width: windowSize.width, height: windowSize.height)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hostingView)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func setItems(_ items: [BatchImportProgressItemSeed]) {
        guard !isClosed else { return }
        viewModel.items = items.map { BatchImportProgressItemModel(id: $0.id, fileName: $0.fileName) }
    }

    func update(
        stage: BatchImportStage,
        progress: Double,
        detail: String,
        completedCount: Int,
        totalCount: Int
    ) {
        guard !isClosed else { return }
        viewModel.stage = stage
        viewModel.progress = min(max(progress, 0), 1)
        viewModel.detail = detail
        viewModel.completedCount = completedCount
        viewModel.totalCount = totalCount
    }

    func updateItem(
        id: String,
        title: String? = nil,
        artist: String? = nil,
        stage: BatchImportItemStage,
        status: BatchImportItemStatus,
        detail: String,
        issueMessage: String? = nil
    ) {
        guard !isClosed, let item = viewModel.items.first(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty {
            item.title = title
        }
        if let artist {
            item.artist = artist
        }
        item.stage = stage
        item.status = status
        item.detail = detail
        item.issueMessage = issueMessage
    }

    func completeImportedItem(id: String) {
        guard !isClosed, let item = viewModel.items.first(where: { $0.id == id }) else { return }

        let status: BatchImportItemStatus
        let detail: String
        switch item.status {
        case .warning:
            status = .warning
            if item.detail.isEmpty {
                detail = "歌曲已导入，但歌词未完全就绪"
            } else if item.detail.hasPrefix("歌曲已") {
                detail = item.detail
            } else {
                detail = "歌曲已导入，\(item.detail)"
            }
        case .failed:
            status = .failed
            detail = item.detail.isEmpty ? "导入失败" : item.detail
        case .skipped:
            status = .skipped
            detail = item.detail.isEmpty ? "已跳过导入" : item.detail
        default:
            status = .success
            if item.detail.isEmpty {
                detail = "歌曲已成功导入"
            } else if item.detail.hasPrefix("歌曲已") {
                detail = item.detail
            } else {
                detail = "歌曲已导入，\(item.detail)"
            }
        }

        item.stage = .completed
        item.status = status
        item.detail = detail
    }

    func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        panel = nil
    }
}

private struct BatchImportProgressDialogView: View {
    @Bindable var viewModel: BatchImportProgressViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()
                .opacity(0.45)

            contentView
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.stage.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                if viewModel.totalCount > 0 {
                    Text("\(viewModel.completedCount)/\(viewModel.totalCount)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: viewModel.progress)
                .progressViewStyle(.linear)

            Text(viewModel.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(.thinMaterial)
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            if viewModel.sortedItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("歌曲列表将在扫描完成后显示。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(viewModel.sortedItems) { item in
                            BatchImportProgressRowView(item: item)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

private struct BatchImportProgressRowView: View {
    @Bindable var item: BatchImportProgressItemModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title.isEmpty ? item.fileName : item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if !item.artist.isEmpty {
                        Text("- \(item.artist)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    Text(item.stage.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(item.status.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)

                if let issueMessage = item.issueMessage, !issueMessage.isEmpty {
                    Text(issueMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
        )
    }

    private var statusColor: Color {
        switch item.status {
        case .waiting:
            return .secondary
        case .active:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .skipped:
            return .secondary
        case .failed:
            return .red
        }
    }

    private var statusIcon: some View {
        Group {
            switch item.status {
            case .waiting:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .active:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .skipped:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 16))
        .frame(width: 20, height: 20)
    }
}

// MARK: - Presenter & UI Components

final class DuplicateImportDialogPresenter: NSObject, NSWindowDelegate {
    private var result: [DuplicatePairRow]?
    private let panel: NSPanel

    init(panel: NSPanel) {
        self.panel = panel
        super.init()
    }

    @MainActor
    static func present(
        rows: [DuplicatePairRow]
    ) -> [DuplicatePairRow]? {
        // Height Calculation Strategy (Compact Mode):
        // Header: 20 (top) + 24 (title) + 4 (gap) + 14 (subtitle) + 8 (gap) + 16 (columns) + 12 (bottom) ≈ 98
        // Footer: 20 (top) + 28 (button) + 20 (bottom) ≈ 68
        // Row: 56 (height) + 4 (spacing) = 60

        // Compact Layout Constants
        let headerHeight: CGFloat = 98
        let footerHeight: CGFloat = 68
        let rowHeight: CGFloat = 48
        let listVerticalPadding: CGFloat = 16
        let maxItemsWithoutScroll = 9

        let visibleRows = CGFloat(min(rows.count, maxItemsWithoutScroll))
        let contentHeight = (visibleRows * rowHeight) + (listVerticalPadding * 2)
        let idealHeight = headerHeight + contentHeight + footerHeight
        
        let clampedHeight = idealHeight

        // Width: 760 (Balanced)
        let windowSize = NSSize(width: 760, height: clampedHeight)

        // Create Panel + Visual Effect
        let (panel, visualEffect) = AppDialogTokens.makePanel(
            width: windowSize.width,
            height: windowSize.height
        )

        let presenter = DuplicateImportDialogPresenter(panel: panel)
        panel.delegate = presenter

        let viewModel = DuplicateImportDialogViewModel(rows: rows)

        let customAction: (Bool) -> Void = { shouldImport in
            if shouldImport {
                presenter.result = viewModel.selectedRows
            } else {
                presenter.result = nil
            }
            NSApp.stopModal()
            panel.close()
        }

        let rootView = DuplicateImportDialogView(viewModel: viewModel, onFinish: customAction)
            .environmentObject(ThemeStore.shared)
            .frame(width: 760, height: clampedHeight)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]

        visualEffect.addSubview(hostingView)
        panel.center()

        NSApp.runModal(for: panel)
        panel.orderOut(nil)

        // Directly return the result.
        // If result is nil, it means user Cancelled.
        // If result is [], it means user Confirmed but selected nothing (which is valid).
        return presenter.result
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}

@MainActor
final class DuplicateImportDialogViewModel: ObservableObject {
    let rows: [DuplicatePairRow]

    @Published var selectedIDs: Set<String>

    init(rows: [DuplicatePairRow]) {
        self.rows = rows
        self.selectedIDs = []
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    var buttonTitle: String {
        if selectedIDs.isEmpty {
            return "忽略重复项导入"
        } else {
            return "导入所选重复项"
        }
    }

    var selectedRows: [DuplicatePairRow] {
        rows.filter { selectedIDs.contains($0.id) }
    }
}

struct DuplicateImportDialogView: View {
    @ObservedObject var viewModel: DuplicateImportDialogViewModel
    let onFinish: (Bool) -> Void
    @EnvironmentObject var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    private let maxItemsWithoutScroll = 9

    // LAYOUT CONSTANTS (Width: 760)
    // Left: 306 (~43%) | Spacing: 12 | Right: 394 (~55%)
    private let leftColumnWidth: CGFloat = 306
    private let rightColumnWidth: CGFloat = 394
    private let horizontalPadding: CGFloat = AppDialogTokens.headerHorizontalPadding

    var body: some View {
        VStack(spacing: 0) {
            headerView
            listContent
            footerView
        }
        .task {
            print("🎬 Duplicate Dialog Appeared. Total rows: \(viewModel.rows.count)")
        }
    }
    
    private var listContent: some View {
        let rowsView = VStack(spacing: 0) {
            ForEach(viewModel.rows) { row in
                DuplicateRowView(
                    row: row,
                    isSelected: viewModel.selectedIDs.contains(row.id),
                    leftWidth: leftColumnWidth,
                    rightWidth: rightColumnWidth,
                    themeAccent: themeStore.accentColor
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.toggleSelection(row.id)
                    }
                }
            }
        }
        
        let paddedView = rowsView
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 16)
        
        if viewModel.rows.count > maxItemsWithoutScroll {
            return AnyView(
                ScrollView {
                    paddedView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        } else {
            return AnyView(
                paddedView
                    .frame(maxWidth: .infinity)
            )
        }
    }
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发现重复歌曲")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Text("点击右侧条目选择是否重复导入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 12) {
                Text("资料库中已存在")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: leftColumnWidth, alignment: .leading)
                
                Divider()
                    .frame(height: 12)
                    .overlay(Color.secondary.opacity(0.3))
                
                Text("本次待导入")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: rightColumnWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            AppDialogDivider()
        }
        .zIndex(1)
    }

    private var footerView: some View {
        HStack {
            Button("取消") {
                onFinish(false)
            }
            .keyboardShortcut(.cancelAction)
            .controlSize(.large)

            Spacer()

            Button(viewModel.buttonTitle) {
                onFinish(true)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(themeStore.accentColor)
        }
        .padding(.vertical, AppDialogTokens.footerVerticalPadding)
        .padding(.horizontal, horizontalPadding)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            AppDialogDivider()
        }
    }
}

struct DuplicateRowView: View {
    let row: DuplicatePairRow
    let isSelected: Bool
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    let themeAccent: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {  // Tighter horizontal spacing
            // Left Column (Existing)
            columnView(
                title: row.existing?.title ?? "未知标题",
                artist: row.existing?.artist ?? "未知艺术家",
                artworkData: row.existing?.artworkData,
                badge: "库中",
                isIncoming: false,
                isSelected: false,
                width: leftWidth
            )

            Divider()
                .frame(height: 32)  // Shorter divider for compact row
                .overlay(Color.secondary.opacity(0.1))

            // Right Column (Incoming)
            columnView(
                title: row.incoming.title,
                artist: row.incoming.artist,
                artworkData: nil,
                badge: isSelected ? "导入" : "跳过",
                isIncoming: true,
                isSelected: isSelected,
                width: rightWidth
            )
        }
        .frame(height: 48)  // Ultra Compact Row Height
    }

    private func columnView(
        title: String,
        artist: String,
        artworkData: Data?,
        badge: String,
        isIncoming: Bool,
        isSelected: Bool,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 12) {
            // Artwork
            if isIncoming {
                // Simplified static icon for incoming files (Stable & Fast)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(themeAccent)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(themeAccent.opacity(0.08))
                    )
            } else if let data = artworkData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)  // Compact artwork
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))  // Larger radius
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Metadata
            VStack(alignment: .leading, spacing: 1) {  // Tighter vertical text spacing
                HStack {
                    Text(title)
                        .font(.body)  // Default size covers 13pt
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isSelected || !isIncoming {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))  // Smaller badge text
                            .foregroundStyle(isSelected ? themeAccent : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(
                                        isSelected
                                            ? themeAccent.opacity(0.15)
                                            : Color.primary.opacity(0.05))
                            )
                    }
                }

                Text(artist)
                    .font(.caption)  // Smaller artist text
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)  // Slightly reduced internal padding
        .padding(.vertical, 6)  // Tighter vertical padding
        .frame(width: width, alignment: .leading)
        .background {
            // Background Logic
            if isIncoming {
                if isSelected {
                    // Stronger highlight for selection
                    RoundedRectangle(cornerRadius: AppDialogTokens.rowCornerRadius, style: .continuous)
                        .fill(themeAccent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                } else {
                    // Subtle background for incoming candidates
                    RoundedRectangle(cornerRadius: AppDialogTokens.rowCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                }
            } else {
                // Simple transparent for existing, or very subtle
                RoundedRectangle(cornerRadius: AppDialogTokens.rowCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.01))
            }
        }
    }
}
