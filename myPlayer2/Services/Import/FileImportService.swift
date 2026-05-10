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
    let albumArtist: String?
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

nonisolated enum ImportLyricsLookupOutcome: Sendable {
    case completed(String)
    case noResults
    case failed(String)
}

nonisolated enum ImportCoverLookupOutcome: Sendable {
    case completed(Data)
    case noResults
    case failed(String)
}

nonisolated private enum ImportEnrichmentPart: String, Sendable, Hashable, CaseIterable {
    case lyrics
    case cover
    case trackMetadata
    case artistMetadata
    case albumMetadata
    case artistArtwork
    case albumArtwork

    var label: String {
        switch self {
        case .lyrics: return "歌词"
        case .cover: return "封面"
        case .trackMetadata: return "歌曲信息"
        case .artistMetadata: return "歌手信息"
        case .albumMetadata: return "专辑信息"
        case .artistArtwork: return "歌手封面"
        case .albumArtwork: return "专辑封面"
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
    private var partStates: [ImportEnrichmentPart: ImportEnrichmentPartState] = [:]
    private var partAttempts: [ImportEnrichmentPart: Int] = [:]

    init(
        trackID: UUID,
        title: String,
        artist: String,
        album: String,
        partStates: [ImportEnrichmentPart: ImportEnrichmentPartState] = [:],
        partAttempts: [ImportEnrichmentPart: Int] = [:]
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.partStates = partStates
        self.partAttempts = partAttempts
    }

    func state(for part: ImportEnrichmentPart) -> ImportEnrichmentPartState {
        partStates[part] ?? .pending
    }

    mutating func setState(_ state: ImportEnrichmentPartState, for part: ImportEnrichmentPart) {
        partStates[part] = state
    }

    func attempts(for part: ImportEnrichmentPart) -> Int {
        partAttempts[part] ?? 0
    }

    mutating func incrementAttempts(for part: ImportEnrichmentPart) {
        partAttempts[part, default: 0] += 1
    }

    var hasOutstandingWork: Bool {
        ImportEnrichmentPart.allCases.contains { partStates[$0]?.isOutstanding ?? false }
    }

    var isTerminal: Bool {
        ImportEnrichmentPart.allCases.allSatisfy { partStates[$0]?.isTerminal ?? false }
    }

    var hasTerminalFailure: Bool {
        ImportEnrichmentPart.allCases.contains { partStates[$0]?.countsAsFailure ?? false }
    }

    var flushPendingPartCount: Int {
        partStates.values.filter { $0 == .flushPending }.count
    }

    // Legacy accessors for backward compatibility in existing code
    var lyricsState: ImportEnrichmentPartState {
        get { state(for: .lyrics) }
        set { setState(newValue, for: .lyrics) }
    }
    var coverState: ImportEnrichmentPartState {
        get { state(for: .cover) }
        set { setState(newValue, for: .cover) }
    }
    var lyricAttempts: Int {
        get { attempts(for: .lyrics) }
        set { partAttempts[.lyrics] = newValue }
    }
    var coverAttempts: Int {
        get { attempts(for: .cover) }
        set { partAttempts[.cover] = newValue }
    }
}

nonisolated struct ImportEnrichmentProgressSnapshot: Sendable, Equatable {
    let totalEnqueued: Int
    let completedCount: Int
    let failedCount: Int
    let pendingLyricsCount: Int
    let pendingCoverCount: Int
    let pendingTrackMetadataCount: Int
    let pendingArtistMetadataCount: Int
    let pendingAlbumMetadataCount: Int
    let pendingArtistArtworkCount: Int
    let pendingAlbumArtworkCount: Int
    let runningCount: Int
    let flushPendingCount: Int

    var hasOutstandingWork: Bool {
        pendingLyricsCount > 0 || pendingCoverCount > 0
            || pendingTrackMetadataCount > 0 || pendingArtistMetadataCount > 0
            || pendingAlbumMetadataCount > 0 || pendingArtistArtworkCount > 0
            || pendingAlbumArtworkCount > 0
            || runningCount > 0 || flushPendingCount > 0
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
        let pendingMeta = pendingTrackMetadataCount + pendingArtistMetadataCount + pendingAlbumMetadataCount
        let pendingArt = pendingArtistArtworkCount + pendingAlbumArtworkCount
        if pendingLyricsCount > 0 || pendingCoverCount > 0 || pendingMeta > 0 || pendingArt > 0 {
            var detailParts: [String] = []
            if pendingLyricsCount > 0 { detailParts.append("词\(pendingLyricsCount)") }
            if pendingCoverCount > 0 { detailParts.append("封\(pendingCoverCount)") }
            if pendingMeta > 0 { detailParts.append("信息\(pendingMeta)") }
            if pendingArt > 0 { detailParts.append("图\(pendingArt)") }
            parts.append(detailParts.joined(separator: " "))
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
    var trackMetadataShouldFlush: Bool

    // Track metadata fields (filled by metadata enrichment)
    var album: String?
    var userDescription: String?
    var genreTags: [String]?
    var language: String?
    var labelOrCompany: String?
    var releaseDate: Date?
    var qqMusicSongMid: String?

    init(trackID: UUID) {
        self.trackID = trackID
        self.ttmlLyricText = nil
        self.artworkData = nil
        self.lyricShouldFlush = false
        self.coverShouldFlush = false
        self.trackMetadataShouldFlush = false
        self.album = nil
        self.userDescription = nil
        self.genreTags = nil
        self.language = nil
        self.labelOrCompany = nil
        self.releaseDate = nil
        self.qqMusicSongMid = nil
    }
}

nonisolated enum ImportEnrichmentWorker {
    private actor ContinuationState {
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

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
        title: String? = nil,
        artist: String,
        album: String,
        duration: Double? = nil
    ) async -> ImportCoverLookupOutcome {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !(normalizedTitle?.isEmpty ?? true) || !normalizedArtist.isEmpty || !normalizedAlbum.isEmpty else {
            return .noResults
        }

        do {
            let candidates = try await withCoverLookupTimeout(
                CoverLookupConfiguration.importPerTrackTimeout
            ) {
                await fetchImportCoverCandidates(
                    title: normalizedTitle,
                    artist: normalizedArtist,
                    album: normalizedAlbum,
                    duration: duration
                )
            }

            guard let selected = CoverCandidateSorter.bestAutomaticCandidate(from: candidates) else {
                return .noResults
            }

            let normalizedData = ArtworkDataNormalizer.normalizedJPEGData(
                from: selected.imageData,
                maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
            ) ?? selected.imageData
            return .completed(normalizedData)
        } catch let error as CoverLookupTimeoutError {
            Log.warning(
                "Import cover fetch timed out for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                category: .import
            )
            return .failed("封面查找超时")
        } catch {
            Log.warning(
                "Import cover fetch failed for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        }
    }

    private static func fetchImportCoverCandidates(
        title: String?,
        artist: String,
        album: String,
        duration: Double?
    ) async -> [CoverCandidate] {
        var candidates: [CoverCandidate] = []

        await withTaskGroup(of: [CoverCandidate].self) { group in
            group.addTask {
                do {
                    return try await withCoverLookupTimeout(
                        CoverLookupConfiguration.netEaseCandidatesTimeout
                    ) {
                        let data = try await downloadNetEaseCover(
                            artist: artist,
                            album: album
                        )
                        return [
                            CoverCandidate(
                                imageData: data,
                                source: .netease,
                                sourceItemId: normalizedCoverQuery(artist: artist, album: album),
                                matchedArtist: artist,
                                matchedAlbum: album
                            )
                        ]
                    }
                } catch let error as NetEaseCoverError {
                    if case .noResults = error {
                        return []
                    }
                    Log.warning(
                        "NetEase cover fetch failed for \(artist) - \(album): \(error)",
                        category: .import
                    )
                    return []
                } catch {
                    Log.warning(
                        "NetEase cover fetch failed for \(artist) - \(album): \(error)",
                        category: .import
                    )
                    return []
                }
            }

            group.addTask {
                do {
                    return try await withCoverLookupTimeout(CoverLookupConfiguration.sacadTimeout) {
                        let data = try await downloadCoverViaSacad(
                            artist: artist,
                            album: album,
                            size: 1200
                        )
                        return [
                            CoverCandidate(
                                imageData: data,
                                source: .sacad,
                                sourceItemId: normalizedCoverQuery(artist: artist, album: album),
                                matchedArtist: artist,
                                matchedAlbum: album
                            )
                        ]
                    }
                } catch {
                    Log.warning(
                        "SACAD cover fetch failed for \(artist) - \(album): \(error)",
                        category: .import
                    )
                    return []
                }
            }

            group.addTask {
                do {
                    return try await withCoverLookupTimeout(
                        CoverLookupConfiguration.qqMusicCandidatesTimeout
                    ) {
                        try await QQMusicCoverService.shared.searchCoverCandidates(
                            title: title,
                            artist: artist,
                            album: album,
                            duration: duration,
                            limit: CoverLookupConfiguration.qqMusicCandidateLimit
                        )
                    }
                } catch {
                    Log.warning(
                        "QQMusic cover fetch failed for \(artist) - \(album): \(error)",
                        category: .import
                    )
                    return []
                }
            }

            for await partial in group {
                candidates.append(contentsOf: partial)
            }
        }

        return CoverCandidateSorter.sorted(candidates)
    }

    private static func downloadCoverViaSacad(
        artist: String,
        album: String,
        size: Int
    ) async throws -> Data {
        guard
            let normalizedData = ArtworkDataNormalizer.normalizedJPEGData(
                from: try await CoverDownloadService.downloadCoverData(
                    artist: artist,
                    album: album,
                    size: size
                ),
                maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
            )
        else {
            throw CoverDownloadError.invalidImageData
        }
        return normalizedData
    }

    private static func downloadNetEaseCover(
        artist: String,
        album: String
    ) async throws -> Data {
        let session = makeNetEaseSession()
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
            let (data, response) = try await session.data(from: searchURL)
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
            let (imageData, response) = try await session.data(from: coverURL)
            try validateNetEaseHTTP(response: response)
            guard
                let normalizedData = ArtworkDataNormalizer.normalizedJPEGData(
                    from: imageData,
                    maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
                )
            else {
                throw NetEaseCoverError.imageDownloadFailed(
                    underlying: CoverDownloadError.invalidImageData
                )
            }
            return normalizedData
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

    private static func makeNetEaseSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = CoverLookupConfiguration.netEasePreferredTimeout
        configuration.timeoutIntervalForResource = CoverLookupConfiguration.netEaseCandidatesTimeout
        return URLSession(configuration: configuration)
    }

    private static func normalizedCoverQuery(artist: String, album: String) -> String {
        "\(artist)-\(album)"
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
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

// MARK: - Metadata Enrichment Outcomes

nonisolated enum ImportTrackMetadataOutcome: Sendable {
    case completed(TrackMetadataDetail)
    case noResults
    case failed(String)
}

nonisolated enum ImportArtistMetadataOutcome: Sendable {
    case completed(ArtistMetadataDetail)
    case noResults
    case failed(String)
}

nonisolated enum ImportAlbumMetadataOutcome: Sendable {
    case completed(AlbumMetadataDetail)
    case noResults
    case failed(String)
}

nonisolated enum ImportArtistArtworkOutcome: Sendable {
    case completed(Data)
    case noResults
    case failed(String)
}

nonisolated enum ImportAlbumArtworkOutcome: Sendable {
    case completed(Data)
    case noResults
    case failed(String)
}

// MARK: - Metadata Enrichment Worker

nonisolated enum MetadataEnrichmentWorker {
    static let metadataTimeout: TimeInterval = 15

    // MARK: Track Metadata

    static func fetchTrackMetadata(
        title: String,
        artist: String,
        album: String,
        duration: Double?
    ) async -> ImportTrackMetadataOutcome {
        let coordinator = await MetadataDetailCoordinator.shared
        do {
            let detail = try await withCoverLookupTimeout(metadataTimeout) {
                try await coordinator.fetchTrackDetail(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration.map { Int($0.rounded()) }
                )
            }
            return .completed(detail)
        } catch let error as CoverLookupTimeoutError {
            Log.warning(
                "Import track metadata timed out for \(artist) - \(title): \(error)",
                category: .import
            )
            return .failed("歌曲信息查找超时")
        } catch {
            Log.warning(
                "Import track metadata failed for \(artist) - \(title): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Artist Metadata

    static func fetchArtistMetadata(
        name: String
    ) async -> ImportArtistMetadataOutcome {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noResults
        }
        let coordinator = await MetadataDetailCoordinator.shared
        do {
            let detail = try await withCoverLookupTimeout(metadataTimeout) {
                try await coordinator.fetchArtistDetail(name: name)
            }
            return .completed(detail)
        } catch let error as CoverLookupTimeoutError {
            Log.warning(
                "Import artist metadata timed out for \(name): \(error)",
                category: .import
            )
            return .failed("歌手信息查找超时")
        } catch {
            Log.warning(
                "Import artist metadata failed for \(name): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Album Metadata

    static func fetchAlbumMetadata(
        album: String,
        artist: String
    ) async -> ImportAlbumMetadataOutcome {
        guard !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noResults
        }
        let coordinator = await MetadataDetailCoordinator.shared
        do {
            let detail = try await withCoverLookupTimeout(metadataTimeout) {
                try await coordinator.fetchAlbumDetail(album: album, artist: artist)
            }
            return .completed(detail)
        } catch let error as CoverLookupTimeoutError {
            Log.warning(
                "Import album metadata timed out for \(artist) - \(album): \(error)",
                category: .import
            )
            return .failed("专辑信息查找超时")
        } catch {
            Log.warning(
                "Import album metadata failed for \(artist) - \(album): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Artist Artwork

    static func fetchArtistArtwork(
        artist: String
    ) async -> ImportArtistArtworkOutcome {
        guard !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noResults
        }
        do {
            let candidates = try await withCoverLookupTimeout(metadataTimeout) {
                try await ArtistArtworkProviderCoordinator.shared.searchCandidates(artist: artist)
            }
            guard let best = CoverCandidateSorter.bestAutomaticCandidate(from: candidates) else {
                return .noResults
            }
            let normalizedData = ArtworkDataNormalizer.normalizedJPEGData(
                from: best.imageData,
                maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
            ) ?? best.imageData
            return .completed(normalizedData)
        } catch let error as CoverLookupTimeoutError {
            Log.warning(
                "Import artist artwork timed out for \(artist): \(error)",
                category: .import
            )
            return .failed("歌手封面查找超时")
        } catch {
            Log.warning(
                "Import artist artwork failed for \(artist): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Album Artwork

    static func fetchAlbumArtwork(
        album: String,
        artist: String
    ) async -> ImportAlbumArtworkOutcome {
        guard !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noResults
        }
        let outcome = await ImportEnrichmentWorker.fetchCover(
            title: nil,
            artist: artist,
            album: album,
            duration: nil
        )
        switch outcome {
        case .completed(let data):
            return .completed(data)
        case .noResults:
            return .noResults
        case .failed(let message):
            if message.contains("超时") {
                Log.warning(
                    "Import album artwork timed out for \(artist) - \(album): \(message)",
                    category: .import
                )
            } else {
                Log.warning(
                    "Import album artwork failed for \(artist) - \(album): \(message)",
                    category: .import
                )
            }
            return .failed(message)
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
    private var entryUpdateLocks: Set<String> = []
    private var entryUpdateWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    // Batch-level deduplication for artist/album enrichment
    private var enqueuedArtistMetadata: Set<String> = []
    private var enqueuedAlbumMetadata: Set<String> = []
    private var enqueuedArtistArtwork: Set<String> = []
    private var enqueuedAlbumArtwork: Set<String> = []
    private(set) var progress = ImportEnrichmentProgressSnapshot(
        totalEnqueued: 0,
        completedCount: 0,
        failedCount: 0,
        pendingLyricsCount: 0,
        pendingCoverCount: 0,
        pendingTrackMetadataCount: 0,
        pendingArtistMetadataCount: 0,
        pendingAlbumMetadataCount: 0,
        pendingArtistArtworkCount: 0,
        pendingAlbumArtworkCount: 0,
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

    func cancelEnrichment(for trackIDs: Set<UUID>) async {
        guard !trackIDs.isEmpty else { return }

        queue.removeAll { trackIDs.contains($0.trackID) }
        queuedRequests = queuedRequests.filter { !trackIDs.contains($0.trackID) }
        runningRequests = runningRequests.filter { !trackIDs.contains($0.trackID) }

        for trackID in trackIDs {
            trackByID[trackID] = nil
            itemStates[trackID] = nil
            pendingFlushPatches[trackID] = nil
        }

        if queue.isEmpty, runningRequests.isEmpty, pendingFlushPatches.isEmpty {
            flushTask?.cancel()
            flushTask = nil
            isFlushing = false
            enqueuedArtistMetadata.removeAll()
            enqueuedAlbumMetadata.removeAll()
            enqueuedArtistArtwork.removeAll()
            enqueuedAlbumArtwork.removeAll()
        }

        refreshProgress()
        Log.info(
            "[ImportEnrichment] cancelled deleted tracks count=\(trackIDs.count)",
            category: .import
        )
    }

    func enqueueTracks(_ tracks: [Track]) async {
        if hasOutstandingWork == false {
            resetProgressIfIdle()
        }

        Log.info("[ImportEnrichment] queue wake requested for \(tracks.count) tracks", category: .import)

        let artistEntriesByCanonical = ImportEnrichmentService.artistEntriesByCanonical(
            await repository.fetchArtistEntries()
        )
        let albumEntriesByCanonical = ImportEnrichmentService.albumEntriesByCanonical(
            await repository.fetchAlbumEntries()
        )

        for track in tracks {
            guard let itemState = makeInitialItemState(
                for: track,
                artistEntriesByCanonical: artistEntriesByCanonical,
                albumEntriesByCanonical: albumEntriesByCanonical
            ) else { continue }
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
            } else if var state = itemStates[track.id], state.state(for: .lyrics) != .completed {
                state.setState(.skipped, for: .lyrics)
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already present",
                    category: .lyrics
                )
            }

            if track.artworkData == nil {
                enqueuePart(.cover, for: track.id)
            } else if var state = itemStates[track.id], state.state(for: .cover) != .completed {
                state.setState(.skipped, for: .cover)
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
            }

            // Track metadata
            if trackMetadataIsMissing(track) {
                enqueuePart(.trackMetadata, for: track.id)
            } else if var state = itemStates[track.id], state.state(for: .trackMetadata) != .completed {
                state.setState(.skipped, for: .trackMetadata)
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] trackMetadata skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
            }

            // Artist metadata (dedup across batch)
            let artistCanonical = LibraryNormalization.normalizeArtist(track.artist)
            if itemState.state(for: .artistMetadata) == .pending,
               !enqueuedArtistMetadata.contains(artistCanonical) {
                enqueuedArtistMetadata.insert(artistCanonical)
                enqueuePart(.artistMetadata, for: track.id)
            } else if var state = itemStates[track.id] {
                state.setState(.skipped, for: .artistMetadata)
                itemStates[track.id] = state
            }

            // Album metadata (dedup across batch)
            let albumCanonical = LibraryNormalization.normalizedAlbumKey(album: track.album)
            let albumDedupKey = "\(artistCanonical)•\(albumCanonical)"
            if itemState.state(for: .albumMetadata) == .pending,
               !enqueuedAlbumMetadata.contains(albumDedupKey) {
                enqueuedAlbumMetadata.insert(albumDedupKey)
                enqueuePart(.albumMetadata, for: track.id)
            } else if var state = itemStates[track.id] {
                state.setState(.skipped, for: .albumMetadata)
                itemStates[track.id] = state
            }

            // Artist artwork (dedup across batch)
            if itemState.state(for: .artistArtwork) == .pending,
               !enqueuedArtistArtwork.contains(artistCanonical) {
                enqueuedArtistArtwork.insert(artistCanonical)
                enqueuePart(.artistArtwork, for: track.id)
            } else if var state = itemStates[track.id] {
                state.setState(.skipped, for: .artistArtwork)
                itemStates[track.id] = state
            }

            // Album artwork (dedup across batch)
            if itemState.state(for: .albumArtwork) == .pending,
               !enqueuedAlbumArtwork.contains(albumDedupKey) {
                enqueuedAlbumArtwork.insert(albumDedupKey)
                enqueuePart(.albumArtwork, for: track.id)
            } else if var state = itemStates[track.id] {
                state.setState(.skipped, for: .albumArtwork)
                itemStates[track.id] = state
            }

            guard let state = itemStates[track.id] else {
                continue
            }
            let states = ImportEnrichmentPart.allCases.map { "\($0.rawValue)=\(state.state(for: $0).rawValue)" }.joined(separator: " ")
            Log.info(
                "[ImportEnrichment] track queued \(track.title) - \(track.artist) | \(states)",
                category: .import
            )
        }

        refreshProgress()
        drainQueueIfPossible()
        diagnoseStalledQueue(context: "enqueue")
    }

    private func makeInitialItemState(
        for track: Track,
        artistEntriesByCanonical: [String: ArtistEntry],
        albumEntriesByCanonical: [String: AlbumEntry]
    ) -> ImportEnrichmentItemState? {
        let needsLyrics = track.ttmlLyricText == nil
        let needsCover = track.artworkData == nil
        let needsTrackMetadata = trackMetadataIsMissing(track)
        let needsArtistMetadata = Self.artistMetadataNeedsEnrichment(
            artist: track.artist,
            entriesByCanonical: artistEntriesByCanonical
        )
        let needsAlbumMetadata = Self.albumMetadataNeedsEnrichment(
            album: track.album,
            entriesByCanonical: albumEntriesByCanonical
        )
        let needsArtistArtwork = Self.artistArtworkNeedsEnrichment(
            artist: track.artist,
            entriesByCanonical: artistEntriesByCanonical
        )
        let needsAlbumArtwork = Self.albumArtworkNeedsEnrichment(
            album: track.album,
            entriesByCanonical: albumEntriesByCanonical
        )
        let needsAny = needsLyrics || needsCover || needsTrackMetadata
            || needsArtistMetadata || needsAlbumMetadata || needsArtistArtwork || needsAlbumArtwork
        guard needsAny else { return nil }

        var partStates: [ImportEnrichmentPart: ImportEnrichmentPartState] = [:]
        partStates[.lyrics] = needsLyrics ? .pending : .skipped
        partStates[.cover] = needsCover ? .pending : .skipped
        partStates[.trackMetadata] = needsTrackMetadata ? .pending : .skipped
        partStates[.artistMetadata] = needsArtistMetadata ? .pending : .skipped
        partStates[.albumMetadata] = needsAlbumMetadata ? .pending : .skipped
        partStates[.artistArtwork] = needsArtistArtwork ? .pending : .skipped
        partStates[.albumArtwork] = needsAlbumArtwork ? .pending : .skipped

        return ImportEnrichmentItemState(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            partStates: partStates,
            partAttempts: [:]
        )
    }

    private func trackMetadataIsMissing(_ track: Track) -> Bool {
        if MetadataDetailApplicator.shouldFillMissingAlbum(track.album) {
            return true
        }
        if track.genreTags.isEmpty == false,
           track.language.isEmpty == false,
           track.labelOrCompany.isEmpty == false,
           track.releaseDate != nil {
            return false
        }
        return true
    }

    fileprivate static func artistEntriesByCanonical(_ entries: [ArtistEntry]) -> [String: ArtistEntry] {
        var result: [String: ArtistEntry] = [:]
        for entry in entries where result[entry.canonicalName] == nil {
            result[entry.canonicalName] = entry
        }
        return result
    }

    fileprivate static func albumEntriesByCanonical(_ entries: [AlbumEntry]) -> [String: AlbumEntry] {
        var result: [String: AlbumEntry] = [:]
        for entry in entries where result[entry.canonicalKey] == nil {
            result[entry.canonicalKey] = entry
        }
        return result
    }

    fileprivate static func artistMetadataNeedsEnrichment(
        artist: String,
        entriesByCanonical: [String: ArtistEntry]
    ) -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        guard let entry = entriesByCanonical[canonical] else { return true }
        return entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.genreTags.isEmpty
            || entry.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.foreignName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate static func artistArtworkNeedsEnrichment(
        artist: String,
        entriesByCanonical: [String: ArtistEntry]
    ) -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        guard let entry = entriesByCanonical[canonical] else { return true }
        return entry.artworkData == nil
    }

    fileprivate static func albumMetadataNeedsEnrichment(
        album: String,
        entriesByCanonical: [String: AlbumEntry]
    ) -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        let canonical = LibraryNormalization.normalizedAlbumKey(album: album)
        guard let entry = entriesByCanonical[canonical] else { return true }
        return entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (entry.year == nil && entry.releaseYear == nil && entry.releaseDate == nil)
            || entry.albumType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.genreTags.isEmpty
            || entry.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate static func albumArtworkNeedsEnrichment(
        album: String,
        entriesByCanonical: [String: AlbumEntry]
    ) -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        let canonical = LibraryNormalization.normalizedAlbumKey(album: album)
        guard let entry = entriesByCanonical[canonical] else { return true }
        return entry.artworkData == nil
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

    private func withEntryUpdateLock<T>(_ key: String, operation: () async -> T) async -> T {
        await acquireEntryUpdateLock(key)
        let result = await operation()
        releaseEntryUpdateLock(key)
        return result
    }

    private func acquireEntryUpdateLock(_ key: String) async {
        while entryUpdateLocks.contains(key) {
            await withCheckedContinuation { continuation in
                entryUpdateWaiters[key, default: []].append(continuation)
            }
        }
        entryUpdateLocks.insert(key)
    }

    private func releaseEntryUpdateLock(_ key: String) {
        if var waiters = entryUpdateWaiters[key], !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            entryUpdateWaiters[key] = waiters.isEmpty ? nil : waiters
            entryUpdateLocks.remove(key)
            continuation.resume()
        } else {
            entryUpdateLocks.remove(key)
        }
    }

    private static func artistUpdateLockKey(_ artist: String) -> String? {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return nil }
        return "artist:\(canonical)"
    }

    private static func albumUpdateLockKey(_ album: String) -> String? {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return nil }
        return "album:\(LibraryNormalization.normalizedAlbumKey(album: album))"
    }

    private func applyArtistMetadataDetail(
        _ detail: ArtistMetadataDetail,
        artist: String
    ) async -> Bool {
        guard let lockKey = Self.artistUpdateLockKey(artist) else { return false }
        return await withEntryUpdateLock(lockKey) {
            await self.applyArtistMetadataDetailUnlocked(detail, artist: artist)
        }
    }

    private func applyArtistArtworkData(_ data: Data, artist: String) async -> Bool {
        guard let lockKey = Self.artistUpdateLockKey(artist) else { return false }
        return await withEntryUpdateLock(lockKey) {
            await self.applyArtistArtworkDataUnlocked(data, artist: artist)
        }
    }

    private func applyAlbumMetadataDetail(
        _ detail: AlbumMetadataDetail,
        album: String,
        artist: String
    ) async -> Bool {
        guard let lockKey = Self.albumUpdateLockKey(album) else { return false }
        return await withEntryUpdateLock(lockKey) {
            await self.applyAlbumMetadataDetailUnlocked(detail, album: album, artist: artist)
        }
    }

    private func applyAlbumArtworkData(_ data: Data, album: String, artist: String) async -> Bool {
        guard let lockKey = Self.albumUpdateLockKey(album) else { return false }
        return await withEntryUpdateLock(lockKey) {
            await self.applyAlbumArtworkDataUnlocked(data, album: album, artist: artist)
        }
    }

    private func applyArtistMetadataDetailUnlocked(
        _ detail: ArtistMetadataDetail,
        artist: String
    ) async -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        let entry = await latestArtistEntry(canonical: canonical, displayName: artist)
        let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
        guard result.changed else { return false }
        await repository.updateArtistEntry(result.value)
        return true
    }

    private func applyArtistArtworkDataUnlocked(_ data: Data, artist: String) async -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        var entry = await latestArtistEntry(canonical: canonical, displayName: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        await repository.updateArtistEntry(entry)
        return true
    }

    private func applyAlbumMetadataDetailUnlocked(
        _ detail: AlbumMetadataDetail,
        album: String,
        artist: String
    ) async -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        let entry = await latestAlbumEntry(album: album, artist: artist)
        let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
        guard result.changed else { return false }
        await repository.updateAlbumEntry(result.value)
        return true
    }

    private func applyAlbumArtworkDataUnlocked(_ data: Data, album: String, artist: String) async -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        var entry = await latestAlbumEntry(album: album, artist: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        await repository.updateAlbumEntry(entry)
        return true
    }

    private func latestArtistEntry(canonical: String, displayName: String) async -> ArtistEntry {
        let entries = await repository.fetchArtistEntries()
        if let entry = entries.first(where: { $0.canonicalName == canonical }) {
            return entry
        }

        let now = Date()
        return ArtistEntry(
            id: UUID(),
            canonicalName: canonical,
            displayName: LibraryNormalization.displayArtist(displayName),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            albumCount: 0,
            totalDuration: 0,
            isOrphaned: true
        )
    }

    private func latestAlbumEntry(album: String, artist: String) async -> AlbumEntry {
        let albumKey = LibraryNormalization.normalizedAlbumKey(album: album)
        let entries = await repository.fetchAlbumEntries()
        if let entry = entries.first(where: { $0.canonicalKey == albumKey }) {
            return entry
        }

        let now = Date()
        return AlbumEntry(
            id: UUID(),
            canonicalKey: albumKey,
            displayTitle: LibraryNormalization.displayAlbum(album),
            primaryArtistCanonicalName: LibraryNormalization.normalizeArtist(artist),
            primaryArtistDisplayName: LibraryNormalization.displayArtist(artist),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            totalDuration: 0,
            isOrphaned: true
        )
    }

    private func refreshProgress() {
        let values = Array(itemStates.values)
        let completedCount = values.filter(\.isTerminal).count
        let failedCount = values.filter(\.hasTerminalFailure).count
        let pendingLyricsCount = values.filter {
            $0.state(for: .lyrics) == .pending || $0.state(for: .lyrics) == .running
        }.count
        let pendingCoverCount = values.filter {
            $0.state(for: .cover) == .pending || $0.state(for: .cover) == .running
        }.count
        let pendingTrackMetadataCount = values.filter {
            $0.state(for: .trackMetadata) == .pending || $0.state(for: .trackMetadata) == .running
        }.count
        let pendingArtistMetadataCount = values.filter {
            $0.state(for: .artistMetadata) == .pending || $0.state(for: .artistMetadata) == .running
        }.count
        let pendingAlbumMetadataCount = values.filter {
            $0.state(for: .albumMetadata) == .pending || $0.state(for: .albumMetadata) == .running
        }.count
        let pendingArtistArtworkCount = values.filter {
            $0.state(for: .artistArtwork) == .pending || $0.state(for: .artistArtwork) == .running
        }.count
        let pendingAlbumArtworkCount = values.filter {
            $0.state(for: .albumArtwork) == .pending || $0.state(for: .albumArtwork) == .running
        }.count
        let flushPendingCount = values.reduce(0) { $0 + $1.flushPendingPartCount }

        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: values.count,
            completedCount: completedCount,
            failedCount: failedCount,
            pendingLyricsCount: pendingLyricsCount,
            pendingCoverCount: pendingCoverCount,
            pendingTrackMetadataCount: pendingTrackMetadataCount,
            pendingArtistMetadataCount: pendingArtistMetadataCount,
            pendingAlbumMetadataCount: pendingAlbumMetadataCount,
            pendingArtistArtworkCount: pendingArtistArtworkCount,
            pendingAlbumArtworkCount: pendingAlbumArtworkCount,
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
        enqueuedArtistMetadata.removeAll()
        enqueuedAlbumMetadata.removeAll()
        enqueuedArtistArtwork.removeAll()
        enqueuedAlbumArtwork.removeAll()
        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: 0,
            completedCount: 0,
            failedCount: 0,
            pendingLyricsCount: 0,
            pendingCoverCount: 0,
            pendingTrackMetadataCount: 0,
            pendingArtistMetadataCount: 0,
            pendingAlbumMetadataCount: 0,
            pendingArtistArtworkCount: 0,
            pendingAlbumArtworkCount: 0,
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

            if request.part == .trackMetadata, !trackMetadataIsMissing(track) {
                state.setState(.skipped, for: .trackMetadata)
                itemStates[request.trackID] = state
                Log.info(
                    "[ImportEnrichment] trackMetadata skipped \(state.title) - \(state.artist) | already present",
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
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
                await self.completeCover(request: request, outcome: outcome)
            case .trackMetadata:
                let outcome = await MetadataEnrichmentWorker.fetchTrackMetadata(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
                await self.completeTrackMetadata(request: request, outcome: outcome)
            case .artistMetadata:
                let outcome = await MetadataEnrichmentWorker.fetchArtistMetadata(name: artist)
                await self.completeArtistMetadata(request: request, outcome: outcome)
            case .albumMetadata:
                let outcome = await MetadataEnrichmentWorker.fetchAlbumMetadata(album: album, artist: artist)
                await self.completeAlbumMetadata(request: request, outcome: outcome)
            case .artistArtwork:
                let outcome = await MetadataEnrichmentWorker.fetchArtistArtwork(artist: artist)
                await self.completeArtistArtwork(request: request, outcome: outcome)
            case .albumArtwork:
                let outcome = await MetadataEnrichmentWorker.fetchAlbumArtwork(album: album, artist: artist)
                await self.completeAlbumArtwork(request: request, outcome: outcome)
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

    private func completeTrackMetadata(
        request: ImportEnrichmentPartRequest,
        outcome: ImportTrackMetadataOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        var shouldEnqueueDiscoveredAlbumMetadata = false
        var shouldEnqueueDiscoveredAlbumArtwork = false
        switch outcome {
        case .completed(let detail):
            if let freshTrack = trackByID[request.trackID] {
                let previousAlbum = state.album
                let changed = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: freshTrack)
                if changed {
                    bufferFlushPatch(
                        trackID: request.trackID,
                        title: state.title,
                        artist: state.artist
                    ) { patch in
                        patch.album = freshTrack.album
                        patch.userDescription = freshTrack.userDescription
                        patch.genreTags = freshTrack.genreTags
                        patch.language = freshTrack.language
                        patch.labelOrCompany = freshTrack.labelOrCompany
                        patch.releaseDate = freshTrack.releaseDate
                        patch.qqMusicSongMid = freshTrack.qqMusicSongMid
                        patch.trackMetadataShouldFlush = true
                    }
                    state.setState(.flushPending, for: .trackMetadata)
                    if MetadataDetailApplicator.shouldFillMissingAlbum(previousAlbum),
                       !LibraryNormalization.isUnknownAlbum(freshTrack.album) {
                        state.album = freshTrack.album
                        let albumDedupKey = "\(LibraryNormalization.normalizeArtist(state.artist))•\(LibraryNormalization.normalizedAlbumKey(album: freshTrack.album))"
                        let albumEntries = Self.albumEntriesByCanonical(await repository.fetchAlbumEntries())
                        shouldEnqueueDiscoveredAlbumMetadata =
                            state.state(for: .albumMetadata) == .skipped
                            && !enqueuedAlbumMetadata.contains(albumDedupKey)
                            && Self.albumMetadataNeedsEnrichment(
                                album: freshTrack.album,
                                entriesByCanonical: albumEntries
                            )
                        shouldEnqueueDiscoveredAlbumArtwork =
                            state.state(for: .albumArtwork) == .skipped
                            && !enqueuedAlbumArtwork.contains(albumDedupKey)
                            && Self.albumArtworkNeedsEnrichment(
                                album: freshTrack.album,
                                entriesByCanonical: albumEntries
                            )
                        if shouldEnqueueDiscoveredAlbumMetadata {
                            enqueuedAlbumMetadata.insert(albumDedupKey)
                            state.setState(.pending, for: .albumMetadata)
                        }
                        if shouldEnqueueDiscoveredAlbumArtwork {
                            enqueuedAlbumArtwork.insert(albumDedupKey)
                            state.setState(.pending, for: .albumArtwork)
                        }
                    }
                    Log.info(
                        "[ImportEnrichment] trackMetadata buffered \(state.title) - \(state.artist)",
                        category: .import
                    )
                } else {
                    state.setState(.skipped, for: .trackMetadata)
                    Log.info(
                        "[ImportEnrichment] trackMetadata skipped \(state.title) - \(state.artist) | no fields to fill",
                        category: .import
                    )
                }
            } else {
                state.setState(.skipped, for: .trackMetadata)
            }
        case .noResults:
            state.setState(.noResults, for: .trackMetadata)
            Log.warning(
                "[ImportEnrichment] trackMetadata no-results \(state.title) - \(state.artist)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .trackMetadata, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .trackMetadata)
                Log.warning(
                    "[ImportEnrichment] trackMetadata failed \(state.title) - \(state.artist) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .trackMetadata)
                Log.warning(
                    "[ImportEnrichment] trackMetadata failed \(state.title) - \(state.artist): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        if shouldEnqueueDiscoveredAlbumMetadata {
            enqueuePart(.albumMetadata, for: request.trackID)
        }
        if shouldEnqueueDiscoveredAlbumArtwork {
            enqueuePart(.albumArtwork, for: request.trackID)
        }
        scheduleFlushIfNeeded(reason: "trackMetadata_result")
        finish(request, requeue: shouldRequeue)
    }

    private func completeArtistMetadata(
        request: ImportEnrichmentPartRequest,
        outcome: ImportArtistMetadataOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let detail):
            if await applyArtistMetadataDetail(detail, artist: state.artist) {
                Log.info(
                    "[ImportEnrichment] artistMetadata applied \(state.artist)",
                    category: .import
                )
            } else {
                Log.info(
                    "[ImportEnrichment] artistMetadata skipped \(state.artist) | no fields to fill",
                    category: .import
                )
            }
            state.setState(.completed, for: .artistMetadata)
        case .noResults:
            state.setState(.noResults, for: .artistMetadata)
            Log.warning(
                "[ImportEnrichment] artistMetadata no-results \(state.artist)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .artistMetadata, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .artistMetadata)
                Log.warning(
                    "[ImportEnrichment] artistMetadata failed \(state.artist) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .artistMetadata)
                Log.warning(
                    "[ImportEnrichment] artistMetadata failed \(state.artist): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        finish(request, requeue: shouldRequeue)
    }

    private func completeAlbumMetadata(
        request: ImportEnrichmentPartRequest,
        outcome: ImportAlbumMetadataOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let detail):
            if await applyAlbumMetadataDetail(detail, album: state.album, artist: state.artist) {
                Log.info(
                    "[ImportEnrichment] albumMetadata applied \(state.album)",
                    category: .import
                )
            } else {
                Log.info(
                    "[ImportEnrichment] albumMetadata skipped \(state.album) | no fields to fill",
                    category: .import
                )
            }
            state.setState(.completed, for: .albumMetadata)
        case .noResults:
            state.setState(.noResults, for: .albumMetadata)
            Log.warning(
                "[ImportEnrichment] albumMetadata no-results \(state.album)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .albumMetadata, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .albumMetadata)
                Log.warning(
                    "[ImportEnrichment] albumMetadata failed \(state.album) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .albumMetadata)
                Log.warning(
                    "[ImportEnrichment] albumMetadata failed \(state.album): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        finish(request, requeue: shouldRequeue)
    }

    private func completeArtistArtwork(
        request: ImportEnrichmentPartRequest,
        outcome: ImportArtistArtworkOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let data):
            if await applyArtistArtworkData(data, artist: state.artist) {
                Log.info(
                    "[ImportEnrichment] artistArtwork applied \(state.artist)",
                    category: .import
                )
            } else {
                Log.info(
                    "[ImportEnrichment] artistArtwork skipped \(state.artist) | already present",
                    category: .import
                )
            }
            state.setState(.completed, for: .artistArtwork)
        case .noResults:
            state.setState(.noResults, for: .artistArtwork)
            Log.warning(
                "[ImportEnrichment] artistArtwork no-results \(state.artist)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .artistArtwork, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .artistArtwork)
                Log.warning(
                    "[ImportEnrichment] artistArtwork failed \(state.artist) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .artistArtwork)
                Log.warning(
                    "[ImportEnrichment] artistArtwork failed \(state.artist): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        finish(request, requeue: shouldRequeue)
    }

    private func completeAlbumArtwork(
        request: ImportEnrichmentPartRequest,
        outcome: ImportAlbumArtworkOutcome
    ) async {
        guard let _ = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let data):
            if await applyAlbumArtworkData(data, album: state.album, artist: state.artist) {
                Log.info(
                    "[ImportEnrichment] albumArtwork applied \(state.album)",
                    category: .import
                )
            } else {
                Log.info(
                    "[ImportEnrichment] albumArtwork skipped \(state.album) | already present",
                    category: .import
                )
            }
            state.setState(.completed, for: .albumArtwork)
        case .noResults:
            state.setState(.noResults, for: .albumArtwork)
            Log.warning(
                "[ImportEnrichment] albumArtwork no-results \(state.album)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .albumArtwork, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .albumArtwork)
                Log.warning(
                    "[ImportEnrichment] albumArtwork failed \(state.album) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .albumArtwork)
                Log.warning(
                    "[ImportEnrichment] albumArtwork failed \(state.album): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
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
            let album: String
            let userDescription: String
            let genreTags: [String]
            let language: String
            let labelOrCompany: String
            let releaseDate: Date?
            let qqMusicSongMid: String?
        }

        var touchedTracks: [Track] = []
        var revertByTrackID: [UUID: PendingRevert] = [:]
        var effectivePatches: [UUID: PendingTrackEnrichmentPatch] = [:]

        for trackID in trackIDs {
            guard let track = trackByID[trackID], let patch = patches[trackID] else { continue }
            var effectivePatch = patch
            revertByTrackID[trackID] = PendingRevert(
                lyrics: track.ttmlLyricText,
                artworkData: track.artworkData,
                album: track.album,
                userDescription: track.userDescription,
                genreTags: track.genreTags,
                language: track.language,
                labelOrCompany: track.labelOrCompany,
                releaseDate: track.releaseDate,
                qqMusicSongMid: track.qqMusicSongMid
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
            if patch.trackMetadataShouldFlush {
                var hasMetadataFieldToFlush = false
                if let album = patch.album {
                    if track.album == album || MetadataDetailApplicator.shouldFillMissingAlbum(track.album) {
                        track.album = album
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.album = nil
                    }
                }
                if let desc = patch.userDescription {
                    if track.userDescription == desc || track.userDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        track.userDescription = desc
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.userDescription = nil
                    }
                }
                if let tags = patch.genreTags {
                    if track.genreTags == tags || track.genreTags.isEmpty {
                        track.genreTags = tags
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.genreTags = nil
                    }
                }
                if let lang = patch.language {
                    if track.language == lang || track.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        track.language = lang
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.language = nil
                    }
                }
                if let label = patch.labelOrCompany {
                    if track.labelOrCompany == label || track.labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        track.labelOrCompany = label
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.labelOrCompany = nil
                    }
                }
                if let date = patch.releaseDate {
                    if track.releaseDate == date || track.releaseDate == nil {
                        track.releaseDate = date
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.releaseDate = nil
                    }
                }
                if let mid = patch.qqMusicSongMid {
                    if track.qqMusicSongMid == mid || (track.qqMusicSongMid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                        track.qqMusicSongMid = mid
                        hasMetadataFieldToFlush = true
                    } else {
                        effectivePatch.qqMusicSongMid = nil
                    }
                }
                effectivePatch.trackMetadataShouldFlush = hasMetadataFieldToFlush
            }

            let hasEffectiveFlush = effectivePatch.lyricShouldFlush
                || effectivePatch.coverShouldFlush
                || effectivePatch.trackMetadataShouldFlush

            if hasEffectiveFlush {
                touchedTracks.append(track)
                effectivePatches[trackID] = effectivePatch
            } else {
                if var state = itemStates[trackID] {
                    if patch.lyricShouldFlush, state.state(for: .lyrics) == .flushPending {
                        state.setState(.skipped, for: .lyrics)
                    }
                    if patch.coverShouldFlush, state.state(for: .cover) == .flushPending {
                        state.setState(.skipped, for: .cover)
                    }
                    if patch.trackMetadataShouldFlush, state.state(for: .trackMetadata) == .flushPending {
                        state.setState(.skipped, for: .trackMetadata)
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

        let metaOnlyTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.trackMetadataShouldFlush && !patch.lyricShouldFlush && !patch.coverShouldFlush
        }
        let lyricOnlyTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.lyricShouldFlush && !patch.coverShouldFlush && !patch.trackMetadataShouldFlush
        }
        let coverOnlyTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return !patch.lyricShouldFlush && patch.coverShouldFlush && !patch.trackMetadataShouldFlush
        }
        let lyricAndCoverTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.lyricShouldFlush && patch.coverShouldFlush && !patch.trackMetadataShouldFlush
        }
        let metaAndLyricTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.trackMetadataShouldFlush && patch.lyricShouldFlush && !patch.coverShouldFlush
        }
        let metaAndCoverTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.trackMetadataShouldFlush && !patch.lyricShouldFlush && patch.coverShouldFlush
        }
        let metaLyricAndCoverTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.trackMetadataShouldFlush && patch.lyricShouldFlush && patch.coverShouldFlush
        }

        var persistedTrackIDs: Set<UUID> = []
        var failedTrackIDs: Set<UUID> = []

        if !metaOnlyTracks.isEmpty {
            let result = await repository.persistTrackMetaOnly(metaOnlyTracks, reason: "importEnrichmentMetadata")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !lyricOnlyTracks.isEmpty {
            let result = await repository.persistTrackMetaAndLyrics(lyricOnlyTracks, reason: "importEnrichmentLyrics")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !coverOnlyTracks.isEmpty {
            let result = await repository.persistTrackMetaAndArtwork(coverOnlyTracks, reason: "importEnrichmentArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !lyricAndCoverTracks.isEmpty {
            let result = await repository.persistTrackMetaLyricsAndArtwork(lyricAndCoverTracks, reason: "importEnrichmentLyricsArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !metaAndLyricTracks.isEmpty {
            let result = await repository.persistTrackMetaAndLyrics(metaAndLyricTracks, reason: "importEnrichmentMetadataLyrics")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !metaAndCoverTracks.isEmpty {
            let result = await repository.persistTrackMetaAndArtwork(metaAndCoverTracks, reason: "importEnrichmentMetadataArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !metaLyricAndCoverTracks.isEmpty {
            let result = await repository.persistTrackMetaLyricsAndArtwork(metaLyricAndCoverTracks, reason: "importEnrichmentMetadataLyricsArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }

        for trackID in persistedTrackIDs {
            guard let patch = effectivePatches[trackID], var state = itemStates[trackID] else { continue }
            if patch.lyricShouldFlush, state.state(for: .lyrics) == .flushPending {
                state.setState(.completed, for: .lyrics)
            }
            if patch.coverShouldFlush, state.state(for: .cover) == .flushPending {
                state.setState(.completed, for: .cover)
            }
            if patch.trackMetadataShouldFlush, state.state(for: .trackMetadata) == .flushPending {
                state.setState(.completed, for: .trackMetadata)
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
                track.album = revert.album
                track.userDescription = revert.userDescription
                track.genreTags = revert.genreTags
                track.language = revert.language
                track.labelOrCompany = revert.labelOrCompany
                track.releaseDate = revert.releaseDate
                track.qqMusicSongMid = revert.qqMusicSongMid
            }
            if var state = itemStates[trackID] {
                if patch.lyricShouldFlush, state.state(for: .lyrics) == .flushPending {
                    state.setState(.failed, for: .lyrics)
                }
                if patch.coverShouldFlush, state.state(for: .cover) == .flushPending {
                    state.setState(.failed, for: .cover)
                }
                if patch.trackMetadataShouldFlush, state.state(for: .trackMetadata) == .flushPending {
                    state.setState(.failed, for: .trackMetadata)
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
            "[ImportEnrichment] batch flush complete reason=\(reason) persisted=\(persistedTrackIDs.count) failed=\(failedTrackIDs.count)",
            category: .import
        )
        if !persistedTrackIDs.isEmpty {
            Log.info(
                "[ImportEnrichment] visible refresh notified for \(persistedTrackIDs.count) persisted tracks",
                category: .import
            )
            Log.info(
                "[ImportEnrichmentReload] flush success with \(persistedTrackIDs.count) updated tracks",
                category: .import
            )
        }
        if !failedTrackIDs.isEmpty {
            Log.warning(
                "[ImportEnrichment] persistence flush failed for \(failedTrackIDs.count) tracks",
                category: .import
            )
        }

        isFlushing = false

        if pendingFlushPatches.isEmpty == false {
            scheduleFlushIfNeeded(reason: "post_flush")
        } else {
            releaseCompletedSessionIfIdle()
        }
    }

    private func releaseCompletedSessionIfIdle() {
        guard queue.isEmpty, runningRequests.isEmpty, pendingFlushPatches.isEmpty, isFlushing == false
        else { return }

        trackByID.removeAll()
        queuedRequests.removeAll()
        runningRequests.removeAll()

        guard itemStates.values.allSatisfy(\.isTerminal) else { return }
        itemStates.removeAll()
        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: 0,
            completedCount: 0,
            failedCount: 0,
            pendingLyricsCount: 0,
            pendingCoverCount: 0,
            pendingTrackMetadataCount: 0,
            pendingArtistMetadataCount: 0,
            pendingAlbumMetadataCount: 0,
            pendingArtistArtworkCount: 0,
            pendingAlbumArtworkCount: 0,
            runningCount: 0,
            flushPendingCount: 0
        )
        Log.info("[ImportEnrichment] idle session released", category: .import)
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
            releaseCompletedSessionIfIdle()
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
        let needsTrackMetadataEnrichment: Bool
        let needsArtistMetadataEnrichment: Bool
        let needsAlbumMetadataEnrichment: Bool
        let needsArtistArtworkEnrichment: Bool
        let needsAlbumArtworkEnrichment: Bool

        var needsAnyEnrichment: Bool {
            needsLyricsEnrichment
                || needsCoverEnrichment
                || needsTrackMetadataEnrichment
                || needsArtistMetadataEnrichment
                || needsAlbumMetadataEnrichment
                || needsArtistArtworkEnrichment
                || needsAlbumArtworkEnrichment
        }
    }

    private struct ImportedTrackPayload: Sendable {
        let id: UUID
        let title: String
        let artist: String
        let album: String
        let albumArtist: String?
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
        let needsTrackMetadataEnrichment: Bool
        let needsArtistMetadataEnrichment: Bool
        let needsAlbumMetadataEnrichment: Bool
        let needsArtistArtworkEnrichment: Bool
        let needsAlbumArtworkEnrichment: Bool
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
        let needsTrackMetadata: Bool
        let needsArtistMetadata: Bool
        let needsAlbumMetadata: Bool
        let needsArtistArtwork: Bool
        let needsAlbumArtwork: Bool
    }

    private struct ImportEnrichmentTaskOutput: Sendable {
        let progressID: String
        let trackID: UUID
        let title: String
        let artist: String
        let album: String
        let lyricOutcome: ImportLyricsLookupOutcome?
        let coverOutcome: ImportCoverLookupOutcome?
        let trackMetadataOutcome: ImportTrackMetadataOutcome?
        let artistMetadataOutcome: ImportArtistMetadataOutcome?
        let albumMetadataOutcome: ImportAlbumMetadataOutcome?
        let artistArtworkOutcome: ImportArtistArtworkOutcome?
        let albumArtworkOutcome: ImportAlbumArtworkOutcome?
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

    func cancelEnrichment(for trackIDs: Set<UUID>) async {
        await importEnrichmentService.cancelEnrichment(for: trackIDs)
    }

    func pickImportURLs(triggeredAt _: Date) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的音乐文件"
        panel.message = "可选择音乐文件，或包含音乐文件的文件夹。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.supportedUTTypes
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        guard let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        else {
            Log.warning("Import panel host window unavailable", category: .import)
            return nil
        }

        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { modalResponse in
                continuation.resume(returning: modalResponse)
            }
        }

        guard response == .OK else { return nil }
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
                    detail: "导入完成后将在后台补全 \(recordsNeedingEnrichment.count) 首歌曲的信息",
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
                await importEnrichmentService.enqueueTracks(recordsNeedingEnrichment.map(\.track))
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
        metadata: (
            title: String, artist: String, album: String, albumArtist: String?, duration: Double,
            lyrics: String?
        ),
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
                albumArtist: metadata.albumArtist,
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
                        needsCoverEnrichment: output.needsCoverEnrichment,
                        needsTrackMetadataEnrichment: output.needsTrackMetadataEnrichment,
                        needsArtistMetadataEnrichment: output.needsArtistMetadataEnrichment,
                        needsAlbumMetadataEnrichment: output.needsAlbumMetadataEnrichment,
                        needsArtistArtworkEnrichment: output.needsArtistArtworkEnrichment,
                        needsAlbumArtworkEnrichment: output.needsAlbumArtworkEnrichment
                    )

                    let needsEnrichment = output.needsLyricsEnrichment
                        || output.needsCoverEnrichment
                        || output.needsTrackMetadataEnrichment
                        || output.needsArtistMetadataEnrichment
                        || output.needsAlbumMetadataEnrichment
                        || output.needsArtistArtworkEnrichment
                        || output.needsAlbumArtworkEnrichment
                    let detail = needsEnrichment
                        ? Self.pendingEnrichmentDetail(
                            needsLyrics: output.needsLyricsEnrichment,
                            needsCover: output.needsCoverEnrichment,
                            needsTrackMetadata: output.needsTrackMetadataEnrichment,
                            needsArtistMetadata: output.needsArtistMetadataEnrichment,
                            needsAlbumMetadata: output.needsAlbumMetadataEnrichment,
                            needsArtistArtwork: output.needsArtistArtworkEnrichment,
                            needsAlbumArtwork: output.needsAlbumArtworkEnrichment,
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
            albumArtist: payload.albumArtist,
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
            let normalizedCoverData = ncmResult.coverData.flatMap {
                ArtworkDataNormalizer.normalizedJPEGData(
                    from: $0,
                    maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
                )
            }
            preview = ImportPreview(
                title: ncmResult.metadata.title,
                artist: ncmResult.metadata.artistName,
                album: ncmResult.metadata.album,
                albumArtist: nil,
                duration: ncmResult.metadata.durationSeconds,
                lyrics: nil,
                artworkData: normalizedCoverData
            )
        } else {
            let raw = await Self.extractMetadata(from: file.fileURL)
            preview = ImportPreview(
                title: raw.title,
                artist: raw.artist,
                album: raw.album,
                albumArtist: raw.albumArtist,
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

        let artistEntriesByCanonical = ImportEnrichmentService.artistEntriesByCanonical(
            await repository.fetchArtistEntries()
        )
        let albumEntriesByCanonical = ImportEnrichmentService.albumEntriesByCanonical(
            await repository.fetchAlbumEntries()
        )
        var claimedArtistMetadata: Set<String> = []
        var claimedArtistArtwork: Set<String> = []
        var claimedAlbumMetadata: Set<String> = []
        var claimedAlbumArtwork: Set<String> = []
        var snapshots: [ImportEnrichmentSnapshot] = []
        snapshots.reserveCapacity(importedRecords.count)

        for record in importedRecords {
            let artistKey = LibraryNormalization.normalizeArtist(record.track.artist)
            let albumKey = LibraryNormalization.normalizedAlbumKey(album: record.track.album)
            let albumDedupKey = "\(artistKey)•\(albumKey)"
            let needsArtistMetadata = record.needsArtistMetadataEnrichment
                && ImportEnrichmentService.artistMetadataNeedsEnrichment(
                    artist: record.track.artist,
                    entriesByCanonical: artistEntriesByCanonical
                )
                && claimedArtistMetadata.insert(artistKey).inserted
            let needsArtistArtwork = record.needsArtistArtworkEnrichment
                && ImportEnrichmentService.artistArtworkNeedsEnrichment(
                    artist: record.track.artist,
                    entriesByCanonical: artistEntriesByCanonical
                )
                && claimedArtistArtwork.insert(artistKey).inserted
            let needsAlbumMetadata = record.needsAlbumMetadataEnrichment
                && ImportEnrichmentService.albumMetadataNeedsEnrichment(
                    album: record.track.album,
                    entriesByCanonical: albumEntriesByCanonical
                )
                && claimedAlbumMetadata.insert(albumDedupKey).inserted
            let needsAlbumArtwork = record.needsAlbumArtworkEnrichment
                && ImportEnrichmentService.albumArtworkNeedsEnrichment(
                    album: record.track.album,
                    entriesByCanonical: albumEntriesByCanonical
                )
                && claimedAlbumArtwork.insert(albumDedupKey).inserted

            snapshots.append(ImportEnrichmentSnapshot(
                progressID: record.progressID,
                id: record.track.id,
                title: record.track.title,
                artist: record.track.artist,
                album: record.track.album,
                duration: record.track.duration > 0 ? record.track.duration : nil,
                needsLyrics: record.needsLyricsEnrichment,
                needsCover: record.needsCoverEnrichment,
                needsTrackMetadata: record.needsTrackMetadataEnrichment,
                needsArtistMetadata: needsArtistMetadata,
                needsAlbumMetadata: needsAlbumMetadata,
                needsArtistArtwork: needsArtistArtwork,
                needsAlbumArtwork: needsAlbumArtwork
            ))
        }
        let recordsByTrackID = Dictionary(
            uniqueKeysWithValues: importedRecords.map { ($0.track.id, $0) }
        )
        let maxConcurrent = Self.enrichmentConcurrency(for: snapshots.count)
        var iterator = snapshots.makeIterator()
        var completedCount = 0
        var stats = ImmediateEnrichmentStats()
        var outputs: [ImportEnrichmentTaskOutput] = []

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
                        needsCover: snapshot.needsCover,
                        needsTrackMetadata: snapshot.needsTrackMetadata,
                        needsArtistMetadata: snapshot.needsArtistMetadata,
                        needsAlbumMetadata: snapshot.needsAlbumMetadata,
                        needsArtistArtwork: snapshot.needsArtistArtwork,
                        needsAlbumArtwork: snapshot.needsAlbumArtwork
                    )
                )
                group.addTask {
                    await Self.performImmediateEnrichmentTask(snapshot: snapshot)
                }
            }

            while let output = await group.next() {
                completedCount += 1
                outputs.append(output)

                let (status, detail, outputStats) =
                    Self.applyImmediateEnrichmentResult(
                        output,
                        to: recordsByTrackID[output.trackID]
                    )
                stats.lyricSuccess += outputStats.lyricSuccess
                stats.coverSuccess += outputStats.coverSuccess
                stats.trackMetadataSuccess += outputStats.trackMetadataSuccess
                stats.artistMetadataSuccess += outputStats.artistMetadataSuccess
                stats.albumMetadataSuccess += outputStats.albumMetadataSuccess
                stats.artistArtworkSuccess += outputStats.artistArtworkSuccess
                stats.albumArtworkSuccess += outputStats.albumArtworkSuccess
                stats.noResults += outputStats.noResults
                stats.failures += outputStats.failures

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
                        stats: stats
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
                            needsCover: snapshot.needsCover,
                            needsTrackMetadata: snapshot.needsTrackMetadata,
                            needsArtistMetadata: snapshot.needsArtistMetadata,
                            needsAlbumMetadata: snapshot.needsAlbumMetadata,
                            needsArtistArtwork: snapshot.needsArtistArtwork,
                            needsAlbumArtwork: snapshot.needsAlbumArtwork
                        )
                    )
                    group.addTask {
                        await Self.performImmediateEnrichmentTask(snapshot: snapshot)
                    }
                }
            }
        }

        await persistImmediateArtistAlbumResults(outputs, recordsByTrackID: recordsByTrackID)
    }

    private func applyArtistMetadataDetail(
        _ detail: ArtistMetadataDetail,
        artist: String
    ) async -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        let entry = await latestArtistEntry(canonical: canonical, displayName: artist)
        let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
        guard result.changed else { return false }
        await repository.updateArtistEntry(result.value)
        return true
    }

    private func applyArtistArtworkData(_ data: Data, artist: String) async -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        var entry = await latestArtistEntry(canonical: canonical, displayName: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        await repository.updateArtistEntry(entry)
        return true
    }

    private func applyAlbumMetadataDetail(
        _ detail: AlbumMetadataDetail,
        album: String,
        artist: String
    ) async -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        let entry = await latestAlbumEntry(album: album, artist: artist)
        let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
        guard result.changed else { return false }
        await repository.updateAlbumEntry(result.value)
        return true
    }

    private func applyAlbumArtworkData(_ data: Data, album: String, artist: String) async -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        var entry = await latestAlbumEntry(album: album, artist: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        await repository.updateAlbumEntry(entry)
        return true
    }

    private func latestArtistEntry(canonical: String, displayName: String) async -> ArtistEntry {
        let entries = await repository.fetchArtistEntries()
        if let entry = entries.first(where: { $0.canonicalName == canonical }) {
            return entry
        }

        let now = Date()
        return ArtistEntry(
            id: UUID(),
            canonicalName: canonical,
            displayName: LibraryNormalization.displayArtist(displayName),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            albumCount: 0,
            totalDuration: 0,
            isOrphaned: true
        )
    }

    private func latestAlbumEntry(album: String, artist: String) async -> AlbumEntry {
        let albumKey = LibraryNormalization.normalizedAlbumKey(album: album)
        let entries = await repository.fetchAlbumEntries()
        if let entry = entries.first(where: { $0.canonicalKey == albumKey }) {
            return entry
        }

        let now = Date()
        return AlbumEntry(
            id: UUID(),
            canonicalKey: albumKey,
            displayTitle: LibraryNormalization.displayAlbum(album),
            primaryArtistCanonicalName: LibraryNormalization.normalizeArtist(artist),
            primaryArtistDisplayName: LibraryNormalization.displayArtist(artist),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            totalDuration: 0,
            isOrphaned: true
        )
    }

    private func persistImmediateArtistAlbumResults(
        _ outputs: [ImportEnrichmentTaskOutput],
        recordsByTrackID: [UUID: ImportedTrackRecord]
    ) async {
        var discoveredAlbumKeys: Set<String> = []
        for output in outputs {
            let effectiveAlbum = recordsByTrackID[output.trackID]?.track.album ?? output.album

            if case .completed(let detail) = output.artistMetadataOutcome {
                if await applyArtistMetadataDetail(detail, artist: output.artist) {
                    Log.info(
                        "[ImportEnrichment] immediate artistMetadata persisted \(output.artist)",
                        category: .import
                    )
                }
            }

            if case .completed(let data) = output.artistArtworkOutcome {
                if await applyArtistArtworkData(data, artist: output.artist) {
                    Log.info(
                        "[ImportEnrichment] immediate artistArtwork persisted \(output.artist)",
                        category: .import
                    )
                }
            }

            if case .completed(let detail) = output.albumMetadataOutcome {
                if await applyAlbumMetadataDetail(detail, album: effectiveAlbum, artist: output.artist) {
                    Log.info(
                        "[ImportEnrichment] immediate albumMetadata persisted \(effectiveAlbum)",
                        category: .import
                    )
                }
            }

            if case .completed(let data) = output.albumArtworkOutcome {
                if await applyAlbumArtworkData(data, album: effectiveAlbum, artist: output.artist) {
                    Log.info(
                        "[ImportEnrichment] immediate albumArtwork persisted \(effectiveAlbum)",
                        category: .import
                    )
                }
            }

            if LibraryNormalization.isUnknownAlbum(output.album),
               !LibraryNormalization.isUnknownAlbum(effectiveAlbum) {
                let albumDedupKey = "\(LibraryNormalization.normalizeArtist(output.artist))•\(LibraryNormalization.normalizedAlbumKey(album: effectiveAlbum))"
                guard discoveredAlbumKeys.insert(albumDedupKey).inserted else { continue }

                let metadataOutcome = await MetadataEnrichmentWorker.fetchAlbumMetadata(
                    album: effectiveAlbum,
                    artist: output.artist
                )
                if case .completed(let detail) = metadataOutcome {
                    _ = await applyAlbumMetadataDetail(detail, album: effectiveAlbum, artist: output.artist)
                }

                let artworkOutcome = await MetadataEnrichmentWorker.fetchAlbumArtwork(
                    album: effectiveAlbum,
                    artist: output.artist
                )
                if case .completed(let data) = artworkOutcome {
                    _ = await applyAlbumArtworkData(data, album: effectiveAlbum, artist: output.artist)
                }
            }
        }
    }

    nonisolated private static func performImmediateEnrichmentTask(
        snapshot: ImportEnrichmentSnapshot
    ) async -> ImportEnrichmentTaskOutput {
        async let lyricOutcome: ImportLyricsLookupOutcome? = snapshot.needsLyrics
            ? ImportEnrichmentWorker.fetchLyrics(
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                duration: snapshot.duration
            )
            : nil
        async let coverOutcome: ImportCoverLookupOutcome? = snapshot.needsCover
            ? ImportEnrichmentWorker.fetchCover(
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                duration: snapshot.duration
            )
            : nil

        let resolvedLyricOutcome = await lyricOutcome
        let resolvedCoverOutcome = await coverOutcome

        let trackMetadataOutcome = snapshot.needsTrackMetadata
            ? await MetadataEnrichmentWorker.fetchTrackMetadata(
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                duration: snapshot.duration
            )
            : nil
        let artistMetadataOutcome = snapshot.needsArtistMetadata
            ? await MetadataEnrichmentWorker.fetchArtistMetadata(name: snapshot.artist)
            : nil
        let albumMetadataOutcome = snapshot.needsAlbumMetadata
            ? await MetadataEnrichmentWorker.fetchAlbumMetadata(
                album: snapshot.album,
                artist: snapshot.artist
            )
            : nil
        let artistArtworkOutcome = snapshot.needsArtistArtwork
            ? await MetadataEnrichmentWorker.fetchArtistArtwork(artist: snapshot.artist)
            : nil
        let albumArtworkOutcome = snapshot.needsAlbumArtwork
            ? await MetadataEnrichmentWorker.fetchAlbumArtwork(
                album: snapshot.album,
                artist: snapshot.artist
            )
            : nil

        return ImportEnrichmentTaskOutput(
            progressID: snapshot.progressID,
            trackID: snapshot.id,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            lyricOutcome: resolvedLyricOutcome,
            coverOutcome: resolvedCoverOutcome,
            trackMetadataOutcome: trackMetadataOutcome,
            artistMetadataOutcome: artistMetadataOutcome,
            albumMetadataOutcome: albumMetadataOutcome,
            artistArtworkOutcome: artistArtworkOutcome,
            albumArtworkOutcome: albumArtworkOutcome
        )
    }

    private struct ImmediateEnrichmentStats: Sendable {
        var lyricSuccess = 0
        var coverSuccess = 0
        var trackMetadataSuccess = 0
        var artistMetadataSuccess = 0
        var albumMetadataSuccess = 0
        var artistArtworkSuccess = 0
        var albumArtworkSuccess = 0
        var noResults = 0
        var failures = 0
    }

    private static func applyImmediateEnrichmentResult(
        _ output: ImportEnrichmentTaskOutput,
        to record: ImportedTrackRecord?
    ) -> (BatchImportItemStatus, String, ImmediateEnrichmentStats) {
        guard let record else {
            var stats = ImmediateEnrichmentStats()
            stats.failures = 1
            return (.warning, "补全结果未能写回，歌曲已保留导入", stats)
        }

        var detailParts: [String] = []
        var status: BatchImportItemStatus = .success
        var stats = ImmediateEnrichmentStats()

        if let lyricOutcome = output.lyricOutcome {
            switch lyricOutcome {
            case .completed(let ttml):
                if record.track.ttmlLyricText == nil {
                    record.track.ttmlLyricText = ttml
                }
                stats.lyricSuccess += 1
                detailParts.append("歌词已补全")
            case .noResults:
                stats.noResults += 1
                status = .warning
                detailParts.append("未找到歌词")
            case .failed:
                stats.failures += 1
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
                stats.coverSuccess += 1
                detailParts.append("封面已补全")
            case .noResults:
                stats.noResults += 1
                status = .warning
                detailParts.append("未找到封面")
            case .failed:
                stats.failures += 1
                status = .warning
                detailParts.append("封面补全失败")
            }
        }

        if let trackMetadataOutcome = output.trackMetadataOutcome {
            switch trackMetadataOutcome {
            case .completed(let detail):
                let changed = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: record.track)
                if changed {
                    stats.trackMetadataSuccess += 1
                    detailParts.append("歌曲信息已补全")
                }
            case .noResults:
                stats.noResults += 1
                status = .warning
                detailParts.append("未找到歌曲信息")
            case .failed:
                stats.failures += 1
                status = .warning
                detailParts.append("歌曲信息补全失败")
            }
        }

        if let artistMetadataOutcome = output.artistMetadataOutcome {
            switch artistMetadataOutcome {
            case .completed:
                stats.artistMetadataSuccess += 1
                detailParts.append("歌手信息已补全")
            case .noResults:
                stats.noResults += 1
                status = .warning
                detailParts.append("未找到歌手信息")
            case .failed:
                stats.failures += 1
                status = .warning
                detailParts.append("歌手信息补全失败")
            }
        }

        if let albumMetadataOutcome = output.albumMetadataOutcome {
            switch albumMetadataOutcome {
            case .completed:
                stats.albumMetadataSuccess += 1
                detailParts.append("专辑信息已补全")
            case .noResults:
                stats.noResults += 1
                status = .warning
                detailParts.append("未找到专辑信息")
            case .failed:
                stats.failures += 1
                status = .warning
                detailParts.append("专辑信息补全失败")
            }
        }

        if let artistArtworkOutcome = output.artistArtworkOutcome {
            switch artistArtworkOutcome {
            case .completed:
                stats.artistArtworkSuccess += 1
                detailParts.append("歌手封面已补全")
            case .noResults:
                stats.noResults += 1
                status = .warning
                detailParts.append("未找到歌手封面")
            case .failed:
                stats.failures += 1
                status = .warning
                detailParts.append("歌手封面补全失败")
            }
        }

        if let albumArtworkOutcome = output.albumArtworkOutcome {
            switch albumArtworkOutcome {
            case .completed:
                stats.albumArtworkSuccess += 1
                detailParts.append("专辑封面已补全")
            case .noResults:
                stats.noResults += 1
                status = .warning
                detailParts.append("未找到专辑封面")
            case .failed:
                stats.failures += 1
                status = .warning
                detailParts.append("专辑封面补全失败")
            }
        }

        if detailParts.isEmpty {
            detailParts.append("歌曲已导入")
        }

        return (status, detailParts.joined(separator: "，"), stats)
    }

    nonisolated private static func enrichmentProgressDetail(
        completed: Int,
        total: Int,
        stats: ImmediateEnrichmentStats
    ) -> String {
        var parts = ["已处理 \(completed) / \(total)"]
        let metaSuccess = stats.trackMetadataSuccess + stats.artistMetadataSuccess + stats.albumMetadataSuccess
        let artSuccess = stats.coverSuccess + stats.artistArtworkSuccess + stats.albumArtworkSuccess
        if stats.lyricSuccess > 0 {
            parts.append("歌词 \(stats.lyricSuccess)")
        }
        if artSuccess > 0 {
            parts.append("封面 \(artSuccess)")
        }
        if metaSuccess > 0 {
            parts.append("信息 \(metaSuccess)")
        }
        if stats.noResults > 0 {
            parts.append("未找到 \(stats.noResults)")
        }
        if stats.failures > 0 {
            parts.append("失败 \(stats.failures)")
        }
        return parts.joined(separator: "，")
    }

    nonisolated private static func pendingEnrichmentDetail(
        needsLyrics: Bool,
        needsCover: Bool,
        needsTrackMetadata: Bool = false,
        needsArtistMetadata: Bool = false,
        needsAlbumMetadata: Bool = false,
        needsArtistArtwork: Bool = false,
        needsAlbumArtwork: Bool = false,
        deferred: Bool
    ) -> String {
        let work = enrichmentWorkLabel(
            needsLyrics: needsLyrics,
            needsCover: needsCover,
            needsTrackMetadata: needsTrackMetadata,
            needsArtistMetadata: needsArtistMetadata,
            needsAlbumMetadata: needsAlbumMetadata,
            needsArtistArtwork: needsArtistArtwork,
            needsAlbumArtwork: needsAlbumArtwork
        )
        if deferred {
            return "歌曲文件已就绪，导入后将在后台补全\(work)"
        }
        return "歌曲文件已就绪，等待补全\(work)"
    }

    nonisolated private static func activeEnrichmentDetail(
        needsLyrics: Bool,
        needsCover: Bool,
        needsTrackMetadata: Bool = false,
        needsArtistMetadata: Bool = false,
        needsAlbumMetadata: Bool = false,
        needsArtistArtwork: Bool = false,
        needsAlbumArtwork: Bool = false
    ) -> String {
        let work = enrichmentWorkLabel(
            needsLyrics: needsLyrics,
            needsCover: needsCover,
            needsTrackMetadata: needsTrackMetadata,
            needsArtistMetadata: needsArtistMetadata,
            needsAlbumMetadata: needsAlbumMetadata,
            needsArtistArtwork: needsArtistArtwork,
            needsAlbumArtwork: needsAlbumArtwork
        )
        return "正在补全\(work)"
    }

    nonisolated private static func enrichmentWorkLabel(
        needsLyrics: Bool,
        needsCover: Bool,
        needsTrackMetadata: Bool = false,
        needsArtistMetadata: Bool = false,
        needsAlbumMetadata: Bool = false,
        needsArtistArtwork: Bool = false,
        needsAlbumArtwork: Bool = false
    ) -> String {
        var parts: [String] = []
        if needsLyrics { parts.append("歌词") }
        if needsCover { parts.append("封面") }
        if needsTrackMetadata { parts.append("歌曲信息") }
        if needsArtistMetadata { parts.append("歌手信息") }
        if needsAlbumMetadata { parts.append("专辑信息") }
        if needsArtistArtwork { parts.append("歌手封面") }
        if needsAlbumArtwork { parts.append("专辑封面") }
        if parts.isEmpty {
            return "导入信息"
        }
        if parts.count == 1 {
            return parts[0]
        }
        return parts.joined(separator: "、")
    }

    /// Extract metadata from audio file using AVAsset.
    /// Made nonisolated static to allow concurrent execution from TaskGroup.
    nonisolated private static func extractMetadata(from url: URL) async -> (
        title: String, artist: String, album: String, albumArtist: String?, duration: Double,
        lyrics: String?
    ) {
        let asset = AVURLAsset(url: url)

        var fields = ExtractedMetadataFields()
        var duration: Double = 0

        do {
            let durationTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(durationTime)
        } catch {
            print("⚠️ Failed to load duration: \(error)")
        }

        if let common = try? await asset.load(.commonMetadata) {
            fields = await metadataFields(byApplying: common, to: fields)
        }
        if let full = try? await asset.load(.metadata) {
            fields = await metadataFields(byApplying: full, to: fields)
        }

        // 4. Fallback: Try Spotlight Metadata (MDItem) if AVAsset failed
        // This handles cases where file has atypical tags or is only recognized by system indexers
        if fields.title == nil || fields.artist == nil {
            if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
                // Title
                if fields.title == nil {
                    if let mdTitle = MDItemCopyAttribute(mdItem, kMDItemTitle) as? String {
                        fields.title = mdTitle
                    }
                }

                // Artist (Authors)
                if fields.artist == nil {
                    if let mdAuthors = MDItemCopyAttribute(mdItem, kMDItemAuthors) as? [String],
                        let firstAuthor = mdAuthors.first
                    {
                        fields.artist = firstAuthor
                    }
                }

                // Album
                if fields.album == nil {
                    if let mdAlbum = MDItemCopyAttribute(mdItem, kMDItemAlbum) as? String {
                        fields.album = mdAlbum
                    }
                }
            }
        }

        // Apply defaults
        let finalTitle = fields.title ?? url.deletingPathExtension().lastPathComponent
        let finalArtist = fields.artist ?? NSLocalizedString("library.unknown_artist", comment: "")
        let finalAlbum = fields.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalAlbumArtist = fields.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            finalTitle,
            finalArtist,
            finalAlbum,
            finalAlbumArtist?.isEmpty == true ? nil : finalAlbumArtist,
            duration,
            fields.lyrics
        )
    }

    /// Extract artwork from audio file.
    nonisolated static func extractArtwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)

        if let common = try? await asset.load(.commonMetadata) {
            if let data = await normalizedArtworkData(in: common) {
                return data
            }
        }
        if let full = try? await asset.load(.metadata) {
            if let data = await normalizedArtworkData(in: full) {
                return data
            }
        }

        return nil
    }

    nonisolated private struct ExtractedMetadataFields: Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var lyrics: String?
    }

    nonisolated private static func metadataFields(
        byApplying items: [AVMetadataItem],
        to existingFields: ExtractedMetadataFields
    ) async -> ExtractedMetadataFields {
        var fields = existingFields

        for item in items {
            if let key = item.commonKey?.rawValue {
                switch key {
                case "title":
                    if fields.title == nil { fields.title = try? await item.load(.stringValue) }
                case "artist":
                    if fields.artist == nil { fields.artist = try? await item.load(.stringValue) }
                case "albumName":
                    if fields.album == nil { fields.album = try? await item.load(.stringValue) }
                case "albumArtist":
                    if fields.albumArtist == nil { fields.albumArtist = try? await item.load(.stringValue) }
                case "lyrics":
                    if fields.lyrics == nil { fields.lyrics = try? await item.load(.stringValue) }
                default:
                    break
                }
            }

            if let keyString = (item.key as? String)?.uppercased() {
                if fields.title == nil && keyString == "TITLE" {
                    fields.title = try? await item.load(.stringValue)
                }
                if fields.artist == nil && keyString == "ARTIST" {
                    fields.artist = try? await item.load(.stringValue)
                }
                if fields.album == nil && (keyString == "ALBUM" || keyString == "ALBUMTITLE") {
                    fields.album = try? await item.load(.stringValue)
                }
                if fields.albumArtist == nil
                    && (keyString == "ALBUMARTIST" || keyString == "ALBUM ARTIST"
                        || keyString == "ALBUM_ARTIST")
                {
                    fields.albumArtist = try? await item.load(.stringValue)
                }
                if fields.lyrics == nil
                    && (keyString == "LYRICS" || keyString == "UNSYNCEDLYRICS"
                        || keyString == "USLT")
                {
                    fields.lyrics = try? await item.load(.stringValue)
                }
            }

            if fields.lyrics == nil,
               let identifier = item.identifier?.rawValue,
               identifier == "id3/USLT" {
                fields.lyrics = try? await item.load(.stringValue)
            }
        }

        return fields
    }

    nonisolated private static func normalizedArtworkData(in items: [AVMetadataItem]) async -> Data? {
        for item in items {
            guard let key = item.commonKey?.rawValue, key == "artwork" else { continue }
            guard let data = try? await item.load(.dataValue) else { continue }
            return ArtworkDataNormalizer.normalizedJPEGData(
                from: data,
                maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
            )
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
            autoreleasepool {
                if Self.isAudioFile(fileURL) {
                    audioFiles.append(fileURL)
                }
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
                return ArtworkDataNormalizer.normalizedJPEGData(
                    from: preloadedArtworkData,
                    maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
                )
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
                    albumArtist: candidate.metadata.albumArtist,
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
                needsTrackMetadataEnrichment: true,
                needsArtistMetadataEnrichment: true,
                needsAlbumMetadataEnrichment: true,
                needsArtistArtworkEnrichment: true,
                needsAlbumArtworkEnrichment: true,
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
                needsTrackMetadataEnrichment: false,
                needsArtistMetadataEnrichment: false,
                needsAlbumMetadataEnrichment: false,
                needsArtistArtworkEnrichment: false,
                needsAlbumArtworkEnrichment: false,
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
        return min(count, 2)
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
        viewModel.items.removeAll()
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        viewModel.items.removeAll()
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
