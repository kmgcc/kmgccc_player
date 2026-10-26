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
        lyricsSearchCoordinator: LyricsSearchCoordinator,
        amllDBService: AMLLDBService
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
        qqMusicCoverService: QQMusicCoverService
    ) async -> ImportCoverLookupOutcome {
        guard !Task.isCancelled else { return .failed("已取消") }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasValidTitle = normalizedTitle?.isEmpty == false
        let hasValidAlbum = !normalizedAlbum.isEmpty && !LibraryNormalization.isUnknownAlbum(normalizedAlbum)

        guard hasValidTitle || hasValidAlbum else {
            return .noResults
        }

        do {
            let selected = try await withCoverLookupTimeout(
                CoverLookupConfiguration.importPerTrackTimeout
            ) {
                try Task.checkCancellation()
                return try await AutomaticCoverLookup.search(
                    title: normalizedTitle,
                    artist: normalizedArtist,
                    album: normalizedAlbum,
                    duration: duration,
                    qqMusic: qqMusicCoverService
                )
            }
            try Task.checkCancellation()

            guard let selected else {
                return .noResults
            }

            guard let data = ArtworkDataNormalizer.originalData(from: selected.imageData) else { return .noResults }
            return .completed(data)
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
        artistArtworkProviderCoordinator: ArtistArtworkProviderCoordinator
    ) async -> ImportArtistArtworkOutcome {
        guard !Task.isCancelled else { return .failed("已取消") }
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanArtist.isEmpty, !LibraryNormalization.isUnknownArtist(cleanArtist) else {
            return .noResults
        }
        do {
            let candidates = try await withCoverLookupTimeout(metadataTimeout) {
                try Task.checkCancellation()
                return try await artistArtworkProviderCoordinator.searchCandidates(artist: cleanArtist)
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
                "Import artist artwork timed out for \(cleanArtist): \(error)",
                category: .import
            )
            return .failed("歌手封面查找超时")
        } catch is CancellationError {
            return .failed("已取消")
        } catch {
            Log.warning(
                "Import artist artwork failed for \(cleanArtist): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Album Artwork

    static func fetchAlbumArtwork(
        album: String,
        artist: String,
        qqMusicCoverService: QQMusicCoverService
    ) async -> ImportAlbumArtworkOutcome {
        guard !Task.isCancelled else { return .failed("已取消") }
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlbum.isEmpty, !LibraryNormalization.isUnknownAlbum(cleanAlbum) else {
            return .noResults
        }
        let outcome = await ImportEnrichmentWorker.fetchCover(
            title: nil,
            artist: artist,
            album: album,
            duration: nil,
            qqMusicCoverService: qqMusicCoverService
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
