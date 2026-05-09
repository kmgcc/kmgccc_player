//
//  QQMusicHelperProcess.swift
//  myPlayer2
//
//  On-demand stdio JSON IPC process manager for the bundled QQMusic helper.
//

import Foundation

nonisolated struct QQMusicArtworkCandidate: Codable, Equatable, Sendable {
    var source: String
    var title: String?
    var artist: String?
    var album: String?
    var artistName: String?
    var singerMid: String?
    var songMid: String?
    var albumMid: String?
    var imageURL: String?
    var duration: Int?
    var confidence: Double?
}

nonisolated enum MetadataDetailSource: String, Codable, Sendable {
    case qqmusic
}

nonisolated struct QQMusicMetadataDetail: Codable, Equatable, Sendable {
    var source: String
    var title: String?
    var artist: String?
    var album: String?
    var artistName: String?
    var singerMid: String?
    var songMid: String?
    var albumMid: String?
    var imageURL: String?
    var description: String?
    var genreTags: [String]?
    var region: String?
    var foreignName: String?
    var releaseYear: Int?
    var releaseDate: Date?
    var albumType: String?
    var language: String?
    var labelOrCompany: String?
    var duration: Int?
    var metadataSource: String?
    var metadataFetchedAt: Date?
    var metadataConfidence: Double?
    var confidence: Double?
}

nonisolated struct ArtistMetadataDetail: Equatable, Sendable {
    var source: MetadataDetailSource
    var artistName: String?
    var description: String?
    var genreTags: [String]
    var region: String?
    var foreignName: String?
    var qqMusicSingerMid: String?
    var imageURL: String?
    var fetchedAt: Date?
    var confidence: Double
}

nonisolated struct AlbumMetadataDetail: Equatable, Sendable {
    var source: MetadataDetailSource
    var album: String?
    var artist: String?
    var description: String?
    var releaseYear: Int?
    var releaseDate: Date?
    var albumType: String?
    var genreTags: [String]
    var language: String?
    var labelOrCompany: String?
    var qqMusicAlbumMid: String?
    var imageURL: String?
    var fetchedAt: Date?
    var confidence: Double
}

nonisolated struct TrackMetadataDetail: Equatable, Sendable {
    var source: MetadataDetailSource
    var title: String?
    var artist: String?
    var album: String?
    var description: String?
    var genreTags: [String]
    var language: String?
    var labelOrCompany: String?
    var releaseDate: Date?
    var qqMusicSongMid: String?
    var qqMusicAlbumMid: String?
    var imageURL: String?
    var duration: Int?
    var fetchedAt: Date?
    var confidence: Double
}

nonisolated struct MetadataApplyResult<Value>: Sendable where Value: Sendable {
    let value: Value
    let changed: Bool
}

nonisolated enum MetadataDetailApplicator {
    static func applyMissingFields(
        _ detail: ArtistMetadataDetail,
        to entry: ArtistEntry,
        minimumConfidence: Double = 0.70
    ) -> MetadataApplyResult<ArtistEntry> {
        guard detail.confidence >= minimumConfidence else {
            return MetadataApplyResult(value: entry, changed: false)
        }

        var updated = entry
        var changed = false

        fillString(&updated.description, with: detail.description, changed: &changed)
        fillStringArray(&updated.genreTags, with: detail.genreTags, changed: &changed)
        fillString(&updated.region, with: detail.region, changed: &changed)
        fillString(&updated.foreignName, with: detail.foreignName, changed: &changed)
        fillOptionalString(&updated.qqMusicSingerMid, with: detail.qqMusicSingerMid, changed: &changed)

        if changed {
            applyMetadataStamp(
                source: detail.source.rawValue,
                fetchedAt: detail.fetchedAt,
                confidence: detail.confidence,
                metadataSource: &updated.metadataSource,
                metadataFetchedAt: &updated.metadataFetchedAt,
                metadataConfidence: &updated.metadataConfidence
            )
            updated.updatedAt = Date()
        }
        return MetadataApplyResult(value: updated, changed: changed)
    }

    static func applyMissingFields(
        _ detail: AlbumMetadataDetail,
        to entry: AlbumEntry,
        minimumConfidence: Double = 0.70
    ) -> MetadataApplyResult<AlbumEntry> {
        guard detail.confidence >= minimumConfidence else {
            return MetadataApplyResult(value: entry, changed: false)
        }

        var updated = entry
        var changed = false

        fillString(&updated.description, with: detail.description, changed: &changed)
        fillOptionalInt(&updated.releaseYear, with: detail.releaseYear, changed: &changed)
        fillOptionalDate(&updated.releaseDate, with: detail.releaseDate, changed: &changed)
        fillString(&updated.albumType, with: detail.albumType, changed: &changed)
        fillStringArray(&updated.genreTags, with: detail.genreTags, changed: &changed)
        fillString(&updated.language, with: detail.language, changed: &changed)
        fillString(&updated.labelOrCompany, with: detail.labelOrCompany, changed: &changed)
        fillOptionalString(&updated.qqMusicAlbumMid, with: detail.qqMusicAlbumMid, changed: &changed)
        if updated.year == nil, let releaseYear = updated.releaseYear {
            updated.year = releaseYear
            changed = true
        }

        if changed {
            applyMetadataStamp(
                source: detail.source.rawValue,
                fetchedAt: detail.fetchedAt,
                confidence: detail.confidence,
                metadataSource: &updated.metadataSource,
                metadataFetchedAt: &updated.metadataFetchedAt,
                metadataConfidence: &updated.metadataConfidence
            )
            updated.updatedAt = Date()
        }
        return MetadataApplyResult(value: updated, changed: changed)
    }

    static func applyMissingFields(
        _ detail: TrackMetadataDetail,
        to track: Track,
        minimumConfidence: Double = 0.70
    ) -> Bool {
        guard detail.confidence >= minimumConfidence else { return false }

        var changed = false
        fillMissingAlbum(&track.album, with: detail.album, changed: &changed)
        fillString(&track.userDescription, with: detail.description, changed: &changed)
        fillStringArray(&track.genreTags, with: detail.genreTags, changed: &changed)
        fillString(&track.language, with: detail.language, changed: &changed)
        fillString(&track.labelOrCompany, with: detail.labelOrCompany, changed: &changed)
        fillOptionalDate(&track.releaseDate, with: detail.releaseDate, changed: &changed)
        fillOptionalString(&track.qqMusicSongMid, with: detail.qqMusicSongMid, changed: &changed)

        if changed {
            applyMetadataStamp(
                source: detail.source.rawValue,
                fetchedAt: detail.fetchedAt,
                confidence: detail.confidence,
                metadataSource: &track.metadataSource,
                metadataFetchedAt: &track.metadataFetchedAt,
                metadataConfidence: &track.metadataConfidence
            )
        }
        return changed
    }

    static func shouldFillMissingAlbum(_ album: String) -> Bool {
        LibraryNormalization.isUnknownAlbum(album)
    }

    private static func fillMissingAlbum(_ target: inout String, with candidate: String?, changed: inout Bool) {
        guard shouldFillMissingAlbum(target),
              let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              !LibraryNormalization.isUnknownAlbum(candidate)
        else { return }
        target = candidate
        changed = true
    }

    private static func fillString(_ target: inout String, with candidate: String?, changed: inout Bool) {
        guard target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return }
        target = candidate
        changed = true
    }

    private static func fillStringArray(_ target: inout [String], with candidate: [String], changed: inout Bool) {
        guard target.isEmpty, !candidate.isEmpty else { return }
        target = candidate
        changed = true
    }

    private static func fillOptionalString(_ target: inout String?, with candidate: String?, changed: inout Bool) {
        guard (target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return }
        target = candidate
        changed = true
    }

    private static func fillOptionalInt(_ target: inout Int?, with candidate: Int?, changed: inout Bool) {
        guard target == nil, let candidate else { return }
        target = candidate
        changed = true
    }

    private static func fillOptionalDate(_ target: inout Date?, with candidate: Date?, changed: inout Bool) {
        guard target == nil, let candidate else { return }
        target = candidate
        changed = true
    }

    private static func applyMetadataStamp(
        source: String,
        fetchedAt: Date?,
        confidence: Double,
        metadataSource: inout String?,
        metadataFetchedAt: inout Date?,
        metadataConfidence: inout Double?
    ) {
        if metadataSource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadataSource = source
        }
        if metadataFetchedAt == nil {
            metadataFetchedAt = fetchedAt ?? Date()
        }
        if metadataConfidence == nil {
            metadataConfidence = confidence
        }
    }
}

nonisolated enum MetadataDetailError: LocalizedError, Sendable {
    case noResults

    var errorDescription: String? {
        switch self {
        case .noResults:
            return "No metadata detail results"
        }
    }
}

protocol MetadataDetailProvider: Sendable {
    func fetchArtistDetail(name: String, singerMid: String?) async throws -> ArtistMetadataDetail?
    func fetchAlbumDetail(album: String, artist: String, albumMid: String?) async throws -> AlbumMetadataDetail?
    func fetchTrackDetail(
        title: String,
        artist: String,
        album: String,
        songMid: String?,
        duration: Int?
    ) async throws -> TrackMetadataDetail?
}

actor QQMusicMetadataProvider: MetadataDetailProvider {
    static let shared = QQMusicMetadataProvider()

    private let helper: QQMusicHelperProcess

    init(helper: QQMusicHelperProcess = .shared) {
        self.helper = helper
    }

    func fetchArtistDetail(name: String, singerMid: String? = nil) async throws -> ArtistMetadataDetail? {
        let detail = try await helper.fetchArtistDetail(name: name, singerMid: singerMid)
        return ArtistMetadataDetail(
            source: .qqmusic,
            artistName: detail.artistName,
            description: nonEmpty(detail.description),
            genreTags: normalizedTags(detail.genreTags),
            region: nonEmpty(detail.region),
            foreignName: nonEmpty(detail.foreignName),
            qqMusicSingerMid: nonEmpty(detail.singerMid),
            imageURL: nonEmpty(detail.imageURL),
            fetchedAt: detail.metadataFetchedAt,
            confidence: normalizedConfidence(detail)
        )
    }

    func fetchAlbumDetail(album: String, artist: String, albumMid: String? = nil) async throws -> AlbumMetadataDetail? {
        let detail = try await helper.fetchAlbumDetail(album: album, artist: artist, albumMid: albumMid)
        return AlbumMetadataDetail(
            source: .qqmusic,
            album: nonEmpty(detail.album),
            artist: nonEmpty(detail.artist),
            description: nonEmpty(detail.description),
            releaseYear: detail.releaseYear,
            releaseDate: detail.releaseDate,
            albumType: nonEmpty(detail.albumType),
            genreTags: normalizedTags(detail.genreTags),
            language: nonEmpty(detail.language),
            labelOrCompany: nonEmpty(detail.labelOrCompany),
            qqMusicAlbumMid: nonEmpty(detail.albumMid),
            imageURL: nonEmpty(detail.imageURL),
            fetchedAt: detail.metadataFetchedAt,
            confidence: normalizedConfidence(detail)
        )
    }

    func fetchTrackDetail(
        title: String,
        artist: String,
        album: String,
        songMid: String? = nil,
        duration: Int? = nil
    ) async throws -> TrackMetadataDetail? {
        let detail = try await helper.fetchSongDetail(
            title: title,
            artist: artist,
            album: album,
            songMid: songMid,
            duration: duration
        )
        return TrackMetadataDetail(
            source: .qqmusic,
            title: nonEmpty(detail.title),
            artist: nonEmpty(detail.artist),
            album: nonEmpty(detail.album),
            description: nonEmpty(detail.description),
            genreTags: normalizedTags(detail.genreTags),
            language: nonEmpty(detail.language),
            labelOrCompany: nonEmpty(detail.labelOrCompany),
            releaseDate: detail.releaseDate,
            qqMusicSongMid: nonEmpty(detail.songMid),
            qqMusicAlbumMid: nonEmpty(detail.albumMid),
            imageURL: nonEmpty(detail.imageURL),
            duration: detail.duration,
            fetchedAt: detail.metadataFetchedAt,
            confidence: normalizedConfidence(detail)
        )
    }

    private nonisolated func normalizedConfidence(_ detail: QQMusicMetadataDetail) -> Double {
        min(max(detail.confidence ?? detail.metadataConfidence ?? 0, 0), 1)
    }

    private nonisolated func normalizedTags(_ values: [String]?) -> [String] {
        var seen = Set<String>()
        return (values ?? []).compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private nonisolated func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

@MainActor
final class MetadataDetailCoordinator {
    static let shared = MetadataDetailCoordinator()

    private let providers: [any MetadataDetailProvider]

    init(providers: [any MetadataDetailProvider] = [QQMusicMetadataProvider.shared]) {
        self.providers = providers
    }

    func fetchArtistDetail(name: String, singerMid: String? = nil) async throws -> ArtistMetadataDetail {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || (singerMid?.isEmpty == false) else {
            throw MetadataDetailError.noResults
        }
        for provider in providers {
            if let detail = try await provider.fetchArtistDetail(name: name, singerMid: singerMid) {
                return detail
            }
        }
        throw MetadataDetailError.noResults
    }

    func fetchAlbumDetail(album: String, artist: String, albumMid: String? = nil) async throws -> AlbumMetadataDetail {
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty || (albumMid?.isEmpty == false) else {
            throw MetadataDetailError.noResults
        }
        for provider in providers {
            if let detail = try await provider.fetchAlbumDetail(album: album, artist: artist, albumMid: albumMid) {
                return detail
            }
        }
        throw MetadataDetailError.noResults
    }

    func fetchTrackDetail(
        title: String,
        artist: String,
        album: String,
        songMid: String? = nil,
        duration: Int? = nil
    ) async throws -> TrackMetadataDetail {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || (songMid?.isEmpty == false) else {
            throw MetadataDetailError.noResults
        }
        for provider in providers {
            if let detail = try await provider.fetchTrackDetail(
                title: title,
                artist: artist,
                album: album,
                songMid: songMid,
                duration: duration
            ) {
                return detail
            }
        }
        throw MetadataDetailError.noResults
    }

    func applyMissingFields(
        _ detail: ArtistMetadataDetail,
        to entry: ArtistEntry,
        minimumConfidence: Double = 0.70
    ) -> MetadataApplyResult<ArtistEntry> {
        MetadataDetailApplicator.applyMissingFields(detail, to: entry, minimumConfidence: minimumConfidence)
    }

    func applyMissingFields(
        _ detail: AlbumMetadataDetail,
        to entry: AlbumEntry,
        minimumConfidence: Double = 0.70
    ) -> MetadataApplyResult<AlbumEntry> {
        MetadataDetailApplicator.applyMissingFields(detail, to: entry, minimumConfidence: minimumConfidence)
    }

    func applyMissingFields(
        _ detail: TrackMetadataDetail,
        to track: Track,
        minimumConfidence: Double = 0.70
    ) -> Bool {
        MetadataDetailApplicator.applyMissingFields(detail, to: track, minimumConfidence: minimumConfidence)
    }
}

nonisolated enum QQMusicHelperError: LocalizedError, Sendable {
    case helperUnavailable(String)
    case circuitOpen(until: Date)
    case requestWriteFailed(String)
    case requestTimedOut(seconds: TimeInterval)
    case requestFailed(String)
    case invalidResponse(String)
    case processTerminated(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let message):
            return "QQMusic helper unavailable: \(message)"
        case .circuitOpen(let until):
            return "QQMusic helper circuit open until \(until)"
        case .requestWriteFailed(let message):
            return "QQMusic helper request write failed: \(message)"
        case .requestTimedOut(let seconds):
            return "QQMusic helper request timed out after \(Int(seconds)) seconds"
        case .requestFailed(let message):
            return "QQMusic helper request failed: \(message)"
        case .invalidResponse(let message):
            return "QQMusic helper returned invalid response: \(message)"
        case .processTerminated(let code):
            return "QQMusic helper terminated with exit code \(code)"
        case .cancelled:
            return "QQMusic helper request cancelled"
        }
    }
}

actor QQMusicHelperProcess {
    static let shared = QQMusicHelperProcess()

    private struct LaunchCandidate {
        let executableURL: URL
        let currentDirectoryURL: URL
        let environment: [String: String]
    }

    private struct PendingRequest {
        let method: String
        let startedAt: Date
        let continuation: CheckedContinuation<QQMusicHelperResponse, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct QQMusicHelperRequest<Params: Encodable>: Encodable {
        let id: String
        let method: String
        let params: Params
    }

    private struct QQMusicHelperResponse: Decodable, Sendable {
        let id: String?
        let ok: Bool
        let candidates: [QQMusicArtworkCandidate]?
        let detail: QQMusicMetadataDetail?
        let error: String?
    }

    private struct ArtistArtworkParams: Encodable, Sendable {
        let name: String
        let limit: Int
    }

    private struct TrackArtworkParams: Encodable, Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: Int?
        let limit: Int
    }

    private struct AlbumArtworkParams: Encodable, Sendable {
        let album: String
        let artist: String
        let limit: Int
    }

    private struct ArtistDetailParams: Encodable, Sendable {
        let name: String?
        let singerMid: String?
    }

    private struct AlbumDetailParams: Encodable, Sendable {
        let album: String?
        let artist: String?
        let albumMid: String?
    }

    private struct SongDetailParams: Encodable, Sendable {
        let title: String?
        let artist: String?
        let album: String?
        let songMid: String?
        let duration: Int?
    }

    private let requestTimeout: TimeInterval = 15
    private let idleTimeout: TimeInterval = 60
    private let failureWindow: TimeInterval = 120
    private let circuitOpenDuration: TimeInterval = 300
    private let failureThreshold = 3
    private let recentLogLimit = 8_000

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""
    private var recentStderr = ""
    private var pendingRequests: [String: PendingRequest] = [:]
    private var idleShutdownTask: Task<Void, Never>?
    private var recentFailureDates: [Date] = []
    private var circuitOpenUntil: Date?
    private var circuitLastReason = ""
    private var lastActivity = Date()
    private var lastLaunchDiagnostics = ""

    private let encoder = JSONEncoder()
    private let decoder = QQMusicHelperProcess.makeDecoder()

    func searchArtistArtwork(name: String, limit: Int = 5) async throws -> [QQMusicArtworkCandidate] {
        try await request(
            method: "search_artist_artwork",
            params: ArtistArtworkParams(name: name, limit: limit)
        )
    }

    func searchTrackArtwork(
        title: String,
        artist: String,
        album: String,
        duration: Int?,
        limit: Int = 5
    ) async throws -> [QQMusicArtworkCandidate] {
        try await request(
            method: "search_track_artwork",
            params: TrackArtworkParams(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                limit: limit
            )
        )
    }

    func searchAlbumArtwork(
        album: String,
        artist: String,
        limit: Int = 5
    ) async throws -> [QQMusicArtworkCandidate] {
        try await request(
            method: "search_album_artwork",
            params: AlbumArtworkParams(album: album, artist: artist, limit: limit)
        )
    }

    func fetchArtistDetail(
        name: String? = nil,
        singerMid: String? = nil
    ) async throws -> QQMusicMetadataDetail {
        try await requestDetail(
            method: "fetch_artist_detail",
            params: ArtistDetailParams(
                name: trimmedOptional(name),
                singerMid: trimmedOptional(singerMid)
            )
        )
    }

    func fetchAlbumDetail(
        album: String? = nil,
        artist: String? = nil,
        albumMid: String? = nil
    ) async throws -> QQMusicMetadataDetail {
        try await requestDetail(
            method: "fetch_album_detail",
            params: AlbumDetailParams(
                album: trimmedOptional(album),
                artist: trimmedOptional(artist),
                albumMid: trimmedOptional(albumMid)
            )
        )
    }

    func fetchSongDetail(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        songMid: String? = nil,
        duration: Int? = nil
    ) async throws -> QQMusicMetadataDetail {
        try await requestDetail(
            method: "fetch_song_detail",
            params: SongDetailParams(
                title: trimmedOptional(title),
                artist: trimmedOptional(artist),
                album: trimmedOptional(album),
                songMid: trimmedOptional(songMid),
                duration: duration
            )
        )
    }

    func terminate() {
        stopProcess(failingPendingWith: QQMusicHelperError.cancelled)
    }

    private func request<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> [QQMusicArtworkCandidate] {
        try checkCircuitBreaker()
        try await ensureRunning()

        let id = UUID().uuidString
        let startedAt = Date()
        let query = querySummary(params)
        Log.info("[QQMusicHelperProcess] request id=\(id) method=\(method) query=\(query)", category: .import)

        let response: QQMusicHelperResponse
        do {
            response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.enqueueRequest(
                        id: id,
                        method: method,
                        params: params,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task {
                    await self.failPendingRequest(id: id, error: QQMusicHelperError.cancelled)
                }
            }
        } catch {
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(error)", category: .import)
            throw error
        }

        guard response.ok else {
            let message = response.error ?? "unknown helper error"
            recordFailure(reason: message)
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(message)", category: .import)
            throw QQMusicHelperError.requestFailed(message)
        }

        let candidates = response.candidates ?? []
        recordSuccess()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let topConfidence = candidates.compactMap(\.confidence).max() ?? 0
        Log.info("[QQMusicHelperProcess] response id=\(id) method=\(method) candidates=\(candidates.count) topConfidence=\(String(format: "%.2f", topConfidence)) durationMs=\(durationMs)", category: .import)
        return candidates
    }

    private func requestDetail<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> QQMusicMetadataDetail {
        try checkCircuitBreaker()
        try await ensureRunning()

        let id = UUID().uuidString
        let startedAt = Date()
        let query = querySummary(params)
        Log.info("[QQMusicHelperProcess] request id=\(id) method=\(method) query=\(query)", category: .import)

        let response: QQMusicHelperResponse
        do {
            response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.enqueueRequest(
                        id: id,
                        method: method,
                        params: params,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task {
                    await self.failPendingRequest(id: id, error: QQMusicHelperError.cancelled)
                }
            }
        } catch {
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(error)", category: .import)
            throw error
        }

        guard response.ok else {
            let message = response.error ?? "unknown helper error"
            recordFailure(reason: message)
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(message)", category: .import)
            throw QQMusicHelperError.requestFailed(message)
        }

        guard let detail = response.detail else {
            let message = "missing metadata detail"
            recordFailure(reason: message)
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(message)", category: .import)
            throw QQMusicHelperError.invalidResponse(message)
        }

        recordSuccess()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let confidence = detail.confidence ?? detail.metadataConfidence ?? 0
        Log.info("[QQMusicHelperProcess] response id=\(id) method=\(method) detail=1 confidence=\(String(format: "%.2f", confidence)) durationMs=\(durationMs)", category: .import)
        return detail
    }

    private func enqueueRequest<Params: Encodable & Sendable>(
        id: String,
        method: String,
        params: Params,
        continuation: CheckedContinuation<QQMusicHelperResponse, Error>
    ) {
        guard let stdinHandle else {
            continuation.resume(
                throwing: QQMusicHelperError.helperUnavailable("stdin pipe is not available")
            )
            return
        }

        let timeout = requestTimeout
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            await self?.failPendingRequest(
                id: id,
                error: QQMusicHelperError.requestTimedOut(seconds: timeout)
            )
        }

        pendingRequests[id] = PendingRequest(
            method: method,
            startedAt: Date(),
            continuation: continuation,
            timeoutTask: timeoutTask
        )

        do {
            let payload = QQMusicHelperRequest(id: id, method: method, params: params)
            var data = try encoder.encode(payload)
            data.append(0x0A)
            try stdinHandle.write(contentsOf: data)
            markActivity()
        } catch {
            timeoutTask.cancel()
            pendingRequests.removeValue(forKey: id)
            recordFailure(reason: "request write failed: \(error.localizedDescription)")
            continuation.resume(
                throwing: QQMusicHelperError.requestWriteFailed(error.localizedDescription)
            )
        }
    }

    private func ensureRunning() async throws {
        if let process, process.isRunning, stdinHandle != nil {
            markActivity()
            return
        }

        stopProcess(failingPendingWith: QQMusicHelperError.processTerminated(-1))

        guard let candidate = findLaunchCandidate() else {
            recordFailure(reason: "helper unavailable")
            throw QQMusicHelperError.helperUnavailable(
                lastLaunchDiagnostics.isEmpty
                    ? "binary missing"
                    : lastLaunchDiagnostics
            )
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = candidate.executableURL
        process.arguments = []
        process.currentDirectoryURL = candidate.currentDirectoryURL
        process.environment = candidate.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            Task {
                await self?.handleStdout(text)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            Task {
                await self?.appendStderr(text)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.handleTermination(terminatedProcess)
            }
        }

        do {
            try process.run()
        } catch {
            let reason = "launch failed: \(error.localizedDescription)"
            recordFailure(reason: reason)
            Log.warning("[QQMusicHelperProcess] \(reason) path=\(candidate.executableURL.path)", category: .import)
            throw QQMusicHelperError.helperUnavailable(reason)
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        stdoutBuffer = ""
        recentStderr = ""
        markActivity()
        Log.info("[QQMusicHelperProcess] started path=\(candidate.executableURL.path)", category: .import)
    }

    private func handleStdout(_ text: String) {
        stdoutBuffer.append(text)
        while let newlineRange = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<newlineRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer.removeSubrange(...newlineRange.lowerBound)
            guard !line.isEmpty else { continue }
            handleResponseLine(line)
        }
    }

    private func handleResponseLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let response: QQMusicHelperResponse
        do {
            response = try decoder.decode(QQMusicHelperResponse.self, from: data)
        } catch {
            recordFailure(reason: "JSON IPC invalid response")
            Log.warning("[QQMusicHelperProcess] JSON IPC invalid response reason=\(error)", category: .import)
            return
        }

        guard let id = response.id,
              let pending = pendingRequests.removeValue(forKey: id)
        else {
            Log.warning("[QQMusicHelperProcess] JSON IPC unknown response id=\(response.id ?? "nil")", category: .import)
            return
        }

        pending.timeoutTask.cancel()
        markActivity()
        pending.continuation.resume(returning: response)
    }

    private func handleTermination(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        let status = terminatedProcess.terminationStatus
        let stderr = recentStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = stderr.isEmpty ? "process terminated code=\(status)" : "process terminated code=\(status) stderr=\(stderr)"
        Log.warning("[QQMusicHelperProcess] \(reason)", category: .import)
        stopProcess(failingPendingWith: QQMusicHelperError.processTerminated(status))
        recordFailure(reason: reason)
    }

    private func failPendingRequest(id: String, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
        recordFailure(reason: String(describing: error))
    }

    private func failAllPendingRequests(with error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func stopProcess(failingPendingWith error: Error) {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        failAllPendingRequests(with: error)

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinHandle?.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        stdinHandle = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer = ""
    }

    private func markActivity() {
        lastActivity = Date()
        scheduleIdleShutdown()
    }

    private func scheduleIdleShutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64((self?.idleTimeout ?? 60) * 1_000_000_000))
            } catch {
                return
            }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard pendingRequests.isEmpty else {
            scheduleIdleShutdown()
            return
        }
        guard Date().timeIntervalSince(lastActivity) >= idleTimeout else {
            scheduleIdleShutdown()
            return
        }
        Log.info("[QQMusicHelperProcess] idle timeout; stopping helper", category: .import)
        stopProcess(failingPendingWith: QQMusicHelperError.cancelled)
    }

    private func appendStderr(_ text: String) {
        recentStderr.append(text)
        if recentStderr.count > recentLogLimit {
            recentStderr = String(recentStderr.suffix(recentLogLimit))
        }
    }

    private func recordFailure(reason: String) {
        let now = Date()
        recentFailureDates = recentFailureDates.filter {
            now.timeIntervalSince($0) <= failureWindow
        }
        recentFailureDates.append(now)
        circuitLastReason = reason
        if recentFailureDates.count >= failureThreshold {
            circuitOpenUntil = now.addingTimeInterval(circuitOpenDuration)
            Log.warning("[QQMusicHelperProcess] circuit open until=\(circuitOpenUntil!) reason=\(reason)", category: .import)
            stopProcess(failingPendingWith: QQMusicHelperError.requestFailed("circuit opened"))
        }
    }

    private func recordSuccess() {
        recentFailureDates.removeAll()
        circuitOpenUntil = nil
        circuitLastReason = ""
    }

    private func checkCircuitBreaker() throws {
        guard let until = circuitOpenUntil else { return }
        if Date() < until {
            Log.warning("[QQMusicHelperProcess] circuit open until=\(until) reason=\(circuitLastReason)", category: .import)
            throw QQMusicHelperError.circuitOpen(until: until)
        }
        circuitOpenUntil = nil
        recentFailureDates.removeAll()
        circuitLastReason = ""
    }

    private func findLaunchCandidate() -> LaunchCandidate? {
        let binaryURL = bundledBinaryURL()
        Log.info("[QQMusicHelperProcess] binary path=\(binaryURL.path)", category: .import)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: binaryURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            lastLaunchDiagnostics = "binary missing: \(binaryURL.path)"
            Log.warning("[QQMusicHelperProcess] \(lastLaunchDiagnostics)", category: .import)
            return nil
        }

        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            lastLaunchDiagnostics = "binary not executable: \(binaryURL.path)"
            Log.warning("[QQMusicHelperProcess] \(lastLaunchDiagnostics)", category: .import)
            return nil
        }

        lastLaunchDiagnostics = ""
        return LaunchCandidate(
            executableURL: binaryURL,
            currentDirectoryURL: binaryURL.deletingLastPathComponent(),
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func bundledBinaryURL() -> URL {
        let resources = Bundle.main.resourceURL
            ?? URL(fileURLWithPath: Bundle.main.resourcePath ?? "", isDirectory: true)
        return resources
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("qqmusic-helper", isDirectory: true)
            .appendingPathComponent("qqmusic-helper", isDirectory: false)
    }

    private func querySummary<Params: Encodable>(_ params: Params) -> String {
        guard let data = try? encoder.encode(params),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "{}"
        }
        let pairs = object
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let text = pairs.joined(separator: ",")
        return text.count > 240 ? String(text.prefix(240)) : text
    }

    private func trimmedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.qqMusicHelperInternet.date(from: value) {
                return date
            }
            if let date = ISO8601DateFormatter.qqMusicHelperInternetWithoutFractionalSeconds.date(from: value) {
                return date
            }
            if let date = ISO8601DateFormatter.qqMusicHelperDateOnly.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported QQMusic helper date: \(value)"
            )
        }
        return decoder
    }
}

private extension ISO8601DateFormatter {
    static let qqMusicHelperInternet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let qqMusicHelperInternetWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let qqMusicHelperDateOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
