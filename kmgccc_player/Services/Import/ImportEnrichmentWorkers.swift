//
//  ImportEnrichmentWorkers.swift
//  myPlayer2
//
//  kmgccc_player - Import metadata, artwork, and lyrics workers
//

import AVFoundation
import AppKit
import Combine
import CoreServices
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    @MainActor
    static func fetchLyrics(
        title: String,
        artist: String,
        album: String? = nil,
        duration: Double? = nil,
        lyricsSearchCoordinator: LyricsSearchCoordinator = .shared,
        amllDBService: AMLLDBService = .shared
    ) async -> ImportLyricsLookupOutcome {
        guard !Task.isCancelled else { return .failed("已取消") }
        // Use shared helper that matches manual "Find Lyrics" ranking logic
        // This ensures import flow uses the same AMLLDB + LDDC search with proper merging
        let ttml = await LyricsSearchHelper.searchAndFetchBestLyrics(
            title: title,
            artist: artist.isEmpty ? nil : artist,
            album: album?.isEmpty == true ? nil : album,
            duration: duration,
            searchCoordinator: lyricsSearchCoordinator,
            amllDBService: amllDBService
        )

        if let ttml {
            guard !Task.isCancelled else { return .failed("已取消") }
            return .completed(ttml)
        } else {
            return .noResults
        }
    }

    static func fetchCover(
        title: String? = nil,
        artist: String,
        album: String,
        duration: Double? = nil,
        qqMusicCoverService: QQMusicCoverService = .shared
    ) async -> ImportCoverLookupOutcome {
        guard !Task.isCancelled else { return .failed("已取消") }
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
                try Task.checkCancellation()
                return await fetchImportCoverCandidates(
                    title: normalizedTitle,
                    artist: normalizedArtist,
                    album: normalizedAlbum,
                    duration: duration,
                    qqMusicCoverService: qqMusicCoverService
                )
            }
            try Task.checkCancellation()

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
        } catch is CancellationError {
            return .failed("已取消")
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
        duration: Double?,
        qqMusicCoverService: QQMusicCoverService
    ) async -> [CoverCandidate] {
        guard !Task.isCancelled else { return [] }
        var candidates: [CoverCandidate] = []

        await withTaskGroup(of: [CoverCandidate].self) { group in
            group.addTask {
                do {
                    try Task.checkCancellation()
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
                    try Task.checkCancellation()
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
                    try Task.checkCancellation()
                    return try await withCoverLookupTimeout(
                        CoverLookupConfiguration.qqMusicCandidatesTimeout
                    ) {
                        try await qqMusicCoverService.searchCoverCandidates(
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
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
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
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
            try Task.checkCancellation()
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
            try Task.checkCancellation()
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
        guard !Task.isCancelled else { return .failed("已取消") }
        let coordinator = await MetadataDetailCoordinator.shared
        do {
            let detail = try await withCoverLookupTimeout(metadataTimeout) {
                try Task.checkCancellation()
                return try await coordinator.fetchTrackDetail(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration.map { Int($0.rounded()) }
                )
            }
            try Task.checkCancellation()
            return .completed(detail)
        } catch let error as CoverLookupTimeoutError {
            Log.warning(
                "Import track metadata timed out for \(artist) - \(title): \(error)",
                category: .import
            )
            return .failed("歌曲信息查找超时")
        } catch is CancellationError {
            return .failed("已取消")
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
        guard !Task.isCancelled else { return .failed("已取消") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noResults
        }
        let coordinator = await MetadataDetailCoordinator.shared
        do {
            let detail = try await withCoverLookupTimeout(metadataTimeout) {
                try Task.checkCancellation()
                return try await coordinator.fetchArtistDetail(name: name)
            }
            try Task.checkCancellation()
            return .completed(detail)
        } catch let error as CoverLookupTimeoutError {
            Log.warning(
                "Import artist metadata timed out for \(name): \(error)",
                category: .import
            )
            return .failed("歌手信息查找超时")
        } catch is CancellationError {
            return .failed("已取消")
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
        guard !Task.isCancelled else { return .failed("已取消") }
        guard !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noResults
        }
        let coordinator = await MetadataDetailCoordinator.shared
        do {
            let detail = try await withCoverLookupTimeout(metadataTimeout) {
                try Task.checkCancellation()
                return try await coordinator.fetchAlbumDetail(album: album, artist: artist)
            }
            try Task.checkCancellation()
            return .completed(detail)
        } catch let error as CoverLookupTimeoutError {
            Log.warning(
                "Import album metadata timed out for \(artist) - \(album): \(error)",
                category: .import
            )
            return .failed("专辑信息查找超时")
        } catch is CancellationError {
            return .failed("已取消")
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
        artist: String,
        artistArtworkProviderCoordinator: ArtistArtworkProviderCoordinator = .shared
    ) async -> ImportArtistArtworkOutcome {
        guard !Task.isCancelled else { return .failed("已取消") }
        guard !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noResults
        }
        do {
            let candidates = try await withCoverLookupTimeout(metadataTimeout) {
                try Task.checkCancellation()
                return try await artistArtworkProviderCoordinator.searchCandidates(artist: artist)
            }
            try Task.checkCancellation()
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
        } catch is CancellationError {
            return .failed("已取消")
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
        guard !Task.isCancelled else { return .failed("已取消") }
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

