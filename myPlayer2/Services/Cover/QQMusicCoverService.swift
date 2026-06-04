//
//  QQMusicCoverService.swift
//  myPlayer2
//
//  Adapts QQMusic helper responses into shared cover candidates.
//

import CryptoKit
import Foundation

nonisolated enum QQMusicCoverError: Error {
    case badURL
    case noResults
    case imageDownloadFailed
}

actor QQMusicCoverService {
    static let shared = QQMusicCoverService()

    private struct MetadataCacheEntry: Codable, Sendable {
        let fetchedAt: Date
        let candidates: [QQMusicArtworkCandidate]
    }

    private struct CoverQuery: Sendable {
        let title: String?
        let artist: String
        let album: String
        let duration: Double?
        let limit: Int
    }

    private let helper: QQMusicHelperProcess
    private let session: URLSession
    private let metadataTTL: TimeInterval = 7 * 24 * 60 * 60
    private var inFlightMetadata: [String: Task<[QQMusicArtworkCandidate], Error>] = [:]

    init(
        helper: QQMusicHelperProcess = .shared,
        session: URLSession = QQMusicCoverService.makeDefaultSession()
    ) {
        self.helper = helper
        self.session = session
    }

    func searchCoverCandidates(
        title: String? = nil,
        artist: String,
        album: String,
        duration: Double? = nil,
        limit: Int = CoverLookupConfiguration.qqMusicCandidateLimit
    ) async throws -> [CoverCandidate] {
        let query = CoverQuery(
            title: trimmed(title),
            artist: trimmed(artist) ?? "",
            album: trimmed(album) ?? "",
            duration: duration,
            limit: limit
        )
        guard query.title?.isEmpty == false || query.album.isEmpty == false else {
            throw QQMusicCoverError.noResults
        }

        let startedAt = Date()
        let rawCandidates = try await fetchRawCandidates(for: query)

        var scored: [(candidate: QQMusicArtworkCandidate, confidence: Double)] = []
        for candidate in rawCandidates {
            let helperConf = candidate.confidence ?? 0
            Log.info(
                "[QQMusicCover] raw[\(candidate.source)] title=\(candidate.title ?? "-") artist=\(candidate.artist ?? candidate.artistName ?? "-") album=\(candidate.album ?? "-") imageURL=\(candidate.imageURL ?? "-") helperConf=\(String(format: "%.2f", helperConf))",
                category: .import
            )
            var rejectReason: String?
            let scoreValue = Self.scoreAndDiagnose(candidate, for: query, rejectReason: &rejectReason)
            if let confidence = scoreValue, confidence >= 0.50 {
                Log.info("[QQMusicCover] accepted: score=\(String(format: "%.2f", confidence))", category: .import)
                scored.append((candidate, confidence))
            } else {
                let why = rejectReason ?? scoreValue.map { "score=\(String(format: "%.2f", $0)) < 0.50" } ?? "nil score"
                Log.info("[QQMusicCover] filtered: \(why)", category: .import)
            }
        }
        scored.sort { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return (lhs.candidate.albumMid ?? lhs.candidate.songMid ?? "") <
                    (rhs.candidate.albumMid ?? rhs.candidate.songMid ?? "")
            }
            return lhs.confidence > rhs.confidence
        }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let topConfidence = scored.map(\.confidence).max() ?? 0
        Log.info(
            "[QQMusicCover] raw=\(rawCandidates.count) scored=\(scored.count) topConfidence=\(String(format: "%.2f", topConfidence)) durationMs=\(durationMs)",
            category: .import
        )

        var results: [CoverCandidate] = []
        var seenImageURLs = Set<String>()

        for item in scored {
            guard results.count < limit else { break }
            guard let rawImageURL = trimmed(item.candidate.imageURL) else {
                Log.info("[QQMusicCover] skipped: empty imageURL title=\(item.candidate.title ?? "-")", category: .import)
                continue
            }
            guard let imageURL = sanitizeImageURL(rawImageURL) else {
                Log.info("[QQMusicCover] skipped: invalid imageURL=\(rawImageURL) title=\(item.candidate.title ?? "-")", category: .import)
                continue
            }
            guard seenImageURLs.insert(imageURL).inserted else {
                Log.info("[QQMusicCover] skipped: duplicate imageURL=\(imageURL) title=\(item.candidate.title ?? "-")", category: .import)
                continue
            }

            do {
                let imageData = try await imageData(for: imageURL)
                let sourceItemId = item.candidate.albumMid
                    ?? item.candidate.songMid
                    ?? Self.cacheKey("image:\(imageURL)")
                results.append(
                    CoverCandidate(
                        imageData: imageData,
                        source: .qqmusic,
                        sourceItemId: sourceItemId,
                        confidence: item.confidence,
                        matchedTitle: item.candidate.title,
                        matchedArtist: item.candidate.artist ?? item.candidate.artistName,
                        matchedAlbum: item.candidate.album,
                        imageURL: imageURL
                    )
                )
            } catch {
                let nsErr = error as NSError
                Log.warning("[QQMusicCover] download failed: url=\(imageURL) code=\(nsErr.code) domain=\(nsErr.domain) \(error)", category: .import)
            }
        }

        guard !results.isEmpty else {
            Log.info("[QQMusicCover] no usable candidates after image download/filtering", category: .import)
            throw QQMusicCoverError.noResults
        }
        Log.info("[QQMusicCover] candidates=\(results.count)", category: .import)
        return CoverCandidateSorter.sorted(results)
    }

    func searchArtistArtworkCandidates(
        artist: String,
        limit: Int = CoverLookupConfiguration.qqMusicCandidateLimit
    ) async throws -> [CoverCandidate] {
        let artist = trimmed(artist) ?? ""
        guard !artist.isEmpty else {
            throw QQMusicCoverError.noResults
        }

        let startedAt = Date()
        let rawCandidates = try await cachedMetadata(
            key: metadataKey(method: "artist", title: nil, artist: artist, album: "", duration: nil),
            taskFactory: {
                Task {
                    try await self.helper.searchArtistArtwork(name: artist, limit: limit)
                }
            }
        )

        let scored = rawCandidates
            .compactMap { candidate -> (candidate: QQMusicArtworkCandidate, confidence: Double)? in
                guard let confidence = Self.scoreArtist(candidate, artist: artist), confidence >= 0.50 else {
                    return nil
                }
                return (candidate, confidence)
            }
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return (lhs.candidate.singerMid ?? lhs.candidate.artistName ?? "") <
                        (rhs.candidate.singerMid ?? rhs.candidate.artistName ?? "")
                }
                return lhs.confidence > rhs.confidence
            }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let topConfidence = scored.map(\.confidence).max() ?? 0
        Log.info(
            "[QQMusicCover] artist raw=\(rawCandidates.count) scored=\(scored.count) topConfidence=\(String(format: "%.2f", topConfidence)) durationMs=\(durationMs)",
            category: .import
        )

        var results: [CoverCandidate] = []
        var seenImageURLs = Set<String>()

        for item in scored {
            guard results.count < limit else { break }
            guard let rawImageURL = trimmed(item.candidate.imageURL),
                  let imageURL = sanitizeImageURL(rawImageURL),
                  seenImageURLs.insert(imageURL).inserted
            else { continue }

            do {
                let imageData = try await imageData(for: imageURL)
                let sourceItemId = item.candidate.singerMid
                    ?? item.candidate.artistName
                    ?? Self.cacheKey("artist-image:\(imageURL)")
                results.append(
                    CoverCandidate(
                        imageData: imageData,
                        source: .qqmusic,
                        sourceItemId: sourceItemId,
                        confidence: item.confidence,
                        matchedTitle: nil,
                        matchedArtist: item.candidate.artistName ?? item.candidate.artist,
                        matchedAlbum: nil,
                        imageURL: imageURL
                    )
                )
            } catch {
                Log.warning("[QQMusicCover] artist image download failed: \(error)", category: .import)
            }
        }

        guard !results.isEmpty else {
            Log.info("[QQMusicCover] artist no usable candidates after image download/filtering", category: .import)
            throw QQMusicCoverError.noResults
        }
        Log.info("[QQMusicCover] artist candidates=\(results.count)", category: .import)
        return CoverCandidateSorter.sorted(results)
    }

    private func fetchRawCandidates(for query: CoverQuery) async throws -> [QQMusicArtworkCandidate] {
        var results: [QQMusicArtworkCandidate] = []
        var firstError: Error?
        let helper = self.helper

        if let title = query.title, !title.isEmpty {
            do {
                results.append(
                    contentsOf: try await cachedMetadata(
                        key: metadataKey(method: "track", title: title, artist: query.artist, album: query.album, duration: query.duration),
                        taskFactory: {
                            Task {
                                try await helper.searchTrackArtwork(
                                    title: title,
                                    artist: query.artist,
                                    album: query.album,
                                    duration: query.duration.map { Int($0.rounded()) },
                                    limit: query.limit
                                )
                            }
                        }
                    )
                )
            } catch {
                firstError = error
                Log.warning("[QQMusicCover] track search failed: \(error)", category: .import)
                Self.recordArtworkDownloadFailure(error: error, operation: "search", httpStatus: nil)
            }
        }

        if !query.album.isEmpty {
            do {
                results.append(
                    contentsOf: try await cachedMetadata(
                        key: metadataKey(method: "album", title: nil, artist: query.artist, album: query.album, duration: nil),
                        taskFactory: {
                            Task {
                                try await helper.searchAlbumArtwork(
                                    album: query.album,
                                    artist: query.artist,
                                    limit: query.limit
                                )
                            }
                        }
                    )
                )
            } catch {
                firstError = firstError ?? error
                Log.warning("[QQMusicCover] album search failed: \(error)", category: .import)
                Self.recordArtworkDownloadFailure(error: error, operation: "search", httpStatus: nil)
            }
        }

        results = deduplicated(results)
        if results.isEmpty, let firstError {
            throw firstError
        }
        return results
    }

    private func cachedMetadata(
        key: String,
        taskFactory: () -> Task<[QQMusicArtworkCandidate], Error>
    ) async throws -> [QQMusicArtworkCandidate] {
        if let cached = readMetadataCache(for: key) {
            return cached
        }

        if let task = inFlightMetadata[key] {
            return try await task.value
        }

        let task = taskFactory()
        inFlightMetadata[key] = task
        defer {
            inFlightMetadata[key] = nil
        }

        let candidates = try await task.value
        writeMetadataCache(candidates, for: key)
        return candidates
    }

    private func imageData(for imageURLString: String) async throws -> Data {
        guard let sanitizedURLString = sanitizeImageURL(imageURLString) else {
            Self.recordArtworkDownloadFailure(error: QQMusicCoverError.badURL, operation: "download", httpStatus: nil)
            throw QQMusicCoverError.badURL
        }

        let cacheURL = imageCacheDirectory()
            .appendingPathComponent("\(Self.cacheKey(sanitizedURLString)).img")

        if let data = try? Data(contentsOf: cacheURL),
           ArtworkDataNormalizer.isDecodableImage(data) {
            return data
        }

        guard let imageURL = URL(string: sanitizedURLString) else {
            Self.recordArtworkDownloadFailure(error: QQMusicCoverError.badURL, operation: "download", httpStatus: nil)
            throw QQMusicCoverError.badURL
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: imageURL)
        } catch {
            Self.recordArtworkDownloadFailure(error: error, operation: "download", httpStatus: nil)
            throw error
        }
        let httpStatus = (response as? HTTPURLResponse)?.statusCode
        do {
            try Self.validateHTTP(response)
        } catch {
            Self.recordArtworkDownloadFailure(error: error, operation: "download", httpStatus: httpStatus)
            throw error
        }
        guard ArtworkDataNormalizer.isDecodableImage(data) else {
            Self.recordArtworkDownloadFailure(
                error: QQMusicCoverError.imageDownloadFailed,
                operation: "decode",
                httpStatus: httpStatus,
                imageFormat: DiagnosticsSafeContext.imageFormat(from: data),
                imageSizeBucket: DiagnosticsSafeContext.imageSizeBucket(from: data)
            )
            throw QQMusicCoverError.imageDownloadFailed
        }

        do {
            try FileManager.default.createDirectory(
                at: imageCacheDirectory(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Self.recordArtworkCacheFailure(error: error)
        }
        return data
    }

    private nonisolated static func recordArtworkDownloadFailure(
        error: Error,
        operation: String,
        httpStatus: Int?,
        imageFormat: String = "unknown",
        imageSizeBucket: String = "unknown"
    ) {
        let errorCode = DiagnosticsErrorMapper.code(for: error)
        let isDecodeFailure = operation == "decode" || errorCode.contains("image")
        var context: DiagnosticsContext = [
            "artwork_source": .string("provider"),
            "operation": .string(operation),
            "result_count_bucket": .string("0"),
            "retry_count": .int(0),
            "cache_hit": .bool(false),
            "fallback_used": .bool(false),
            "error_code": .string(errorCode)
        ]
        if let httpStatus {
            context["http_status"] = .int(httpStatus)
            context["provider_rate_limited"] = .bool(httpStatus == 429)
        }
        if isDecodeFailure {
            context["decode_error_code"] = .string(errorCode)
            context["image_format"] = .string(imageFormat)
            context["image_size_bucket"] = .string(imageSizeBucket)
        } else {
            context["network_error_code"] = .string(errorCode)
        }
        DiagnosticsService.recordAsync(
            level: .warning,
            subsystem: .artwork,
            category: isDecodeFailure ? .decode : .providerFailure,
            stage: isDecodeFailure ? .artworkDecode : (operation == "search" ? .artworkSearch : .artworkDownload),
            provider: .qqmusic,
            messageCode: "qqmusic_\(errorCode)",
            context: context
        )
    }

    private nonisolated static func recordArtworkCacheFailure(error: Error) {
        DiagnosticsService.recordAsync(
            level: .warning,
            subsystem: .artwork,
            category: .fileIO,
            stage: .artworkCache,
            provider: .qqmusic,
            messageCode: "qqmusic_artwork_cache_failed",
            context: [
                "artwork_source": .string("provider"),
                "operation": .string("cache"),
                "cache_hit": .bool(false),
                "fallback_used": .bool(false),
                "error_code": .string(DiagnosticsErrorMapper.code(for: error))
            ]
        )
    }

    private nonisolated func sanitizeImageURL(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              var components = URLComponents(string: value)
        else { return nil }

        let host = components.host?.lowercased() ?? ""
        if components.scheme?.lowercased() == "http",
           Self.qqMusicHTTPSImageHosts.contains(host) {
            let before = components.string ?? value
            components.scheme = "https"
            let after = components.string ?? before.replacingOccurrences(of: "http://", with: "https://")
            Log.info("[QQMusicCover] sanitized imageURL from=\(before) to=\(after)", category: .import)
            return after
        }

        let result = components.string ?? value
        if result != value {
            Log.info("[QQMusicCover] sanitized imageURL from=\(value) to=\(result)", category: .import)
        }
        return result
    }

    private func readMetadataCache(for key: String) -> [QQMusicArtworkCandidate]? {
        let url = metadataCacheDirectory().appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(MetadataCacheEntry.self, from: data)
        else {
            return nil
        }
        if Date().timeIntervalSince(entry.fetchedAt) > metadataTTL {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return entry.candidates
    }

    private func writeMetadataCache(_ candidates: [QQMusicArtworkCandidate], for key: String) {
        let url = metadataCacheDirectory().appendingPathComponent("\(key).json")
        let entry = MetadataCacheEntry(fetchedAt: Date(), candidates: candidates)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(
            at: metadataCacheDirectory(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private func metadataKey(
        method: String,
        title: String?,
        artist: String,
        album: String,
        duration: Double?
    ) -> String {
        let normalized = [
            method,
            ExternalPlaybackTextNormalizer.normalizedKey(title),
            ExternalPlaybackTextNormalizer.normalizedKey(artist),
            ExternalPlaybackTextNormalizer.normalizedKey(album),
            duration.map { String(Int($0.rounded())) } ?? "",
        ].joined(separator: "|")
        return Self.cacheKey(normalized)
    }

    private func deduplicated(_ candidates: [QQMusicArtworkCandidate]) -> [QQMusicArtworkCandidate] {
        var seen = Set<String>()
        var result: [QQMusicArtworkCandidate] = []
        for candidate in candidates {
            let key = candidate.albumMid ?? candidate.songMid ?? candidate.imageURL ?? UUID().uuidString
            if seen.insert(key).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private func metadataCacheDirectory() -> URL {
        cacheRoot().appendingPathComponent("Metadata", isDirectory: true)
    }

    private func imageCacheDirectory() -> URL {
        cacheRoot().appendingPathComponent("Images", isDirectory: true)
    }

    private func cacheRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("kmgccc_player/QQMusicCoverCache", isDirectory: true)
    }

    private nonisolated static func score(
        _ candidate: QQMusicArtworkCandidate,
        for query: CoverQuery
    ) -> Double? {
        var ignored: String?
        return scoreAndDiagnose(candidate, for: query, rejectReason: &ignored)
    }

    private nonisolated static func scoreAndDiagnose(
        _ candidate: QQMusicArtworkCandidate,
        for query: CoverQuery,
        rejectReason: inout String?
    ) -> Double? {
        let helperConfidence = min(max(candidate.confidence ?? 0.70, 0), 1)

        if let queryTitle = query.title, !queryTitle.isEmpty {
            let sourceTitle = ExternalPlaybackTextNormalizer.normalize(queryTitle)
            let candidateTitle = ExternalPlaybackTextNormalizer.normalize(candidate.title)
            let titleScore = ExternalPlaybackTextNormalizer.stringSimilarity(sourceTitle, candidateTitle)
            guard titleScore >= 0.50
                    || candidateTitle.compact.contains(sourceTitle.compact)
                    || sourceTitle.compact.contains(candidateTitle.compact)
            else {
                rejectReason = "title mismatch: score=\(String(format: "%.2f", titleScore)) query=\"\(queryTitle)\" candidate=\"\(candidate.title ?? "-")\""
                return nil
            }

            let sourceArtist = ExternalPlaybackTextNormalizer.normalizeArtist(query.artist)
            let candidateArtist = ExternalPlaybackTextNormalizer.normalizeArtist(
                candidate.artist ?? candidate.artistName
            )
            let artistScore = ExternalPlaybackTextNormalizer.artistSimilarity(sourceArtist, candidateArtist)
            guard artistScore >= 0.22 else {
                rejectReason = "artist mismatch: score=\(String(format: "%.2f", artistScore)) query=\"\(query.artist)\" candidate=\"\(candidate.artist ?? candidate.artistName ?? "-")\""
                return nil
            }

            let candidateDuration = Double(candidate.duration ?? 0)
            // Album-source candidates have nil/empty title; the title guard above passed only
            // via sourceTitle.compact.contains("") == true, so titleScore is 0.
            // hasObviousConflict would always reject them on the titleScore < 0.45 branch.
            // Skip the title component of the conflict check for those candidates.
            if !candidateTitle.compact.isEmpty {
                if ExternalPlaybackTextNormalizer.hasObviousConflict(
                    titleScore: titleScore,
                    artistScore: artistScore,
                    sourceDuration: query.duration ?? 0,
                    candidateDuration: candidateDuration
                ) {
                    rejectReason = "obvious conflict: titleScore=\(String(format: "%.2f", titleScore)) artistScore=\(String(format: "%.2f", artistScore)) sourceDuration=\(query.duration ?? 0) candidateDuration=\(candidateDuration)"
                    return nil
                }
            } else if (query.duration ?? 0) > 0, candidateDuration > 0,
                      abs((query.duration ?? 0) - candidateDuration) > 45
            {
                rejectReason = "duration conflict (album-source): source=\(query.duration ?? 0) candidate=\(candidateDuration)"
                return nil
            }

            let sourceAlbum = ExternalPlaybackTextNormalizer.normalize(query.album)
            let candidateAlbum = ExternalPlaybackTextNormalizer.normalize(candidate.album)
            let albumScore = sourceAlbum.compact.isEmpty || candidateAlbum.compact.isEmpty
                ? 0.5
                : ExternalPlaybackTextNormalizer.stringSimilarity(sourceAlbum, candidateAlbum)
            let durationScore = ExternalPlaybackTextNormalizer.durationScore(
                source: query.duration ?? 0,
                candidate: candidateDuration
            )

            var score = titleScore * 0.46
                + artistScore * 0.28
                + durationScore * 0.18
                + albumScore * 0.06
                + helperConfidence * 0.02
            score -= variantMismatchPenalty(
                sourceTitle: queryTitle,
                candidateTitle: candidate.title,
                sourceAlbum: query.album,
                candidateAlbum: candidate.album
            )
            return min(max(score, 0), 1)
        }

        // Album-only path (no query title)
        let sourceAlbum = ExternalPlaybackTextNormalizer.normalize(query.album)
        let candidateAlbum = ExternalPlaybackTextNormalizer.normalize(candidate.album)
        let albumScore = ExternalPlaybackTextNormalizer.stringSimilarity(sourceAlbum, candidateAlbum)
        let highConf = helperConfidence >= 0.80
        guard albumScore >= 0.45
                || candidateAlbum.compact.contains(sourceAlbum.compact)
                || sourceAlbum.compact.contains(candidateAlbum.compact)
                || highConf
        else {
            rejectReason = "album mismatch: albumScore=\(String(format: "%.2f", albumScore)) helperConf=\(String(format: "%.2f", helperConfidence)) query=\"\(query.album)\" candidate=\"\(candidate.album ?? "-")\""
            return nil
        }

        let sourceArtist = ExternalPlaybackTextNormalizer.normalizeArtist(query.artist)
        let candidateArtist = ExternalPlaybackTextNormalizer.normalizeArtist(
            candidate.artist ?? candidate.artistName
        )
        let artistScore = sourceArtist.text.compact.isEmpty
            ? 0.5
            : ExternalPlaybackTextNormalizer.artistSimilarity(sourceArtist, candidateArtist)
        guard artistScore >= 0.18 else {
            rejectReason = "artist mismatch (album-only): artistScore=\(String(format: "%.2f", artistScore)) query=\"\(query.artist)\" candidate=\"\(candidate.artist ?? candidate.artistName ?? "-")\""
            return nil
        }

        // When the helper has high confidence, boost its weight to reduce the penalty from
        // complex album names (movie soundtracks, EP/Single titles, long subtitles, etc.).
        // Weights always sum to 1.0: albumWeight + 0.34 + confWeight = 1.0.
        let confWeight: Double = highConf ? 0.18 : 0.06
        let albumWeight: Double = highConf ? 0.48 : 0.60
        var score = albumScore * albumWeight + artistScore * 0.34 + helperConfidence * confWeight
        score -= variantMismatchPenalty(
            sourceTitle: nil,
            candidateTitle: candidate.title,
            sourceAlbum: query.album,
            candidateAlbum: candidate.album
        )
        return min(max(score, 0), 1)
    }

    private nonisolated static func scoreArtist(
        _ candidate: QQMusicArtworkCandidate,
        artist: String
    ) -> Double? {
        let helperConfidence = min(max(candidate.confidence ?? 0.70, 0), 1)
        let sourceArtist = ExternalPlaybackTextNormalizer.normalizeArtist(artist)
        let candidateArtist = ExternalPlaybackTextNormalizer.normalizeArtist(
            candidate.artistName ?? candidate.artist
        )
        let artistScore = ExternalPlaybackTextNormalizer.artistSimilarity(sourceArtist, candidateArtist)
        guard artistScore >= 0.45
                || candidateArtist.text.compact.contains(sourceArtist.text.compact)
                || sourceArtist.text.compact.contains(candidateArtist.text.compact)
        else { return nil }

        var score = artistScore * 0.90 + helperConfidence * 0.10
        if containsVariantMarker(candidate.artistName ?? candidate.artist) {
            score -= 0.10
        }
        return min(max(score, 0), 1)
    }

    private nonisolated static func variantMismatchPenalty(
        sourceTitle: String?,
        candidateTitle: String?,
        sourceAlbum: String,
        candidateAlbum: String?
    ) -> Double {
        let sourceHasVariant = containsVariantMarker(sourceTitle)
            || containsVariantMarker(sourceAlbum)
        let candidateHasVariant = containsVariantMarker(candidateTitle)
            || containsVariantMarker(candidateAlbum)
        return sourceHasVariant == candidateHasVariant ? 0 : 0.14
    }

    private nonisolated static func containsVariantMarker(_ value: String?) -> Bool {
        guard let value else { return false }
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let markers = [
            "live", "remix", "dj", "cover", "version", "edit", "instrumental", "karaoke",
            "伴奏", "纯音乐", "现场", "翻唱", "重混", "混音", "改编"
        ]
        return markers.contains { folded.contains($0) }
    }

    private nonisolated static func cacheKey(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw QQMusicCoverError.imageDownloadFailed
        }
    }

    private nonisolated static let qqMusicHTTPSImageHosts: Set<String> = [
        "y.gtimg.cn",
        "qpic.y.qq.com",
        "y.qq.com",
        "thirdqq.qlogo.cn",
        "thirdwx.qlogo.cn",
    ]

    private nonisolated static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = CoverLookupConfiguration.qqMusicCandidatesTimeout
        return URLSession(configuration: configuration)
    }

    private nonisolated func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum CoverCandidateSorter {
    static func sorted(_ candidates: [CoverCandidate]) -> [CoverCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsScore = lhs.rankingScore
            let rhsScore = rhs.rankingScore
            if abs(lhsScore - rhsScore) > 0.01 {
                return lhsScore > rhsScore
            }
            if lhs.resolution != rhs.resolution {
                return lhs.resolution > rhs.resolution
            }
            return lhs.id < rhs.id
        }
    }

    static func bestAutomaticCandidate(from candidates: [CoverCandidate]) -> CoverCandidate? {
        sorted(candidates).first {
            $0.confidence >= CoverLookupConfiguration.automaticCoverConfidenceThreshold
        }
    }
}

actor ArtistArtworkProviderCoordinator {
    static let shared = ArtistArtworkProviderCoordinator()

    private let qqMusicCoverService: QQMusicCoverService

    init(qqMusicCoverService: QQMusicCoverService = .shared) {
        self.qqMusicCoverService = qqMusicCoverService
    }

    func searchCandidates(
        artist: String,
        limit: Int = CoverLookupConfiguration.qqMusicCandidateLimit
    ) async throws -> [CoverCandidate] {
        do {
            return try await withCoverLookupTimeout(
                CoverLookupConfiguration.qqMusicCandidatesTimeout
            ) {
                try await self.qqMusicCoverService.searchArtistArtworkCandidates(
                    artist: artist,
                    limit: limit
                )
            }
        } catch {
            Log.warning("[QQMusicCover] artist candidates failed: \(error)", category: .import)
            throw error
        }
    }
}
