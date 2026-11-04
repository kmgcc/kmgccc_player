//
//  CoverSearchCoordinator.swift
//  myPlayer2
//
//  kmgccc_player - Cover Search Coordinator
//  Shared logic for merging, sorting, and selecting cover candidates
//

import AppKit
import Observation
import Foundation

/// Coordinates cover search from multiple sources, merges results, and manages selection.
@Observable
@MainActor
final class CoverSearchCoordinator {
    /// All candidates found from search, with matches to the original query first.
    var candidates: [CoverCandidate] = []

    /// The candidate currently selected for preview (not yet persisted).
    var selectedForPreview: CoverCandidate?

    /// Whether a search is currently in progress.
    var isLoading: Bool = false

    /// Error message if search failed completely.
    var error: String?

    /// Whether candidates are available and strip should be shown.
    var hasCandidates: Bool {
        !candidates.isEmpty
    }

    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    private let coverDownloadService: CoverDownloadService
    private let netEaseCoverService: NetEaseCoverService
    private let qqMusicCoverService: QQMusicCoverService

    init(
        coverDownloadService: CoverDownloadService,
        netEaseCoverService: NetEaseCoverService,
        qqMusicCoverService: QQMusicCoverService
    ) {
        self.coverDownloadService = coverDownloadService
        self.netEaseCoverService = netEaseCoverService
        self.qqMusicCoverService = qqMusicCoverService
    }

    /// Searches all providers concurrently and publishes candidates as soon as any source returns.
    func search(
        artist: String,
        album: String,
        title: String? = nil,
        duration: Double? = nil
    ) async {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        isLoading = true
        error = nil
        candidates = []
        selectedForPreview = nil

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidTitle = cleanTitle?.isEmpty == false
        let hasValidArtist = !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LibraryNormalization.isUnknownArtist(artist)
        let hasValidAlbum = !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LibraryNormalization.isUnknownAlbum(album)

        guard hasValidTitle || hasValidAlbum else {
            isLoading = false
            return
        }

        let normalizedQuery = normalizeQuery(artist: artist, album: album)
        let searchArtist = ManualMusicSearch.cleanArtist(artist)
        let searchAlbum = ManualMusicSearch.cleanAlbum(album)
        let variants = ManualMusicSearch.queries(title: cleanTitle ?? "", artist: searchArtist, album: searchAlbum)

        let task = Task {
            defer {
                if searchGeneration == generation {
                    isLoading = false
                    searchTask = nil
                }
            }

            var backgroundCandidates: [CoverCandidate] = []
            await withTaskGroup(of: [CoverCandidate].self) { group in
                for provider in ["appleCache", "appleWeb"] {
                    group.addTask {
                        Log.info("[CoverSearch] event=attempt provider=\(provider)", category: .playback)
                        do {
                            return try await withCoverLookupTimeout(CoverLookupConfiguration.appleMusicTimeout) {
                                try await AutomaticCoverLookup.appleCandidates(provider: provider, title: cleanTitle,
                                    artist: artist, album: album, duration: duration)
                            }
                        } catch {
                            Log.info("[CoverSearch] event=failed provider=\(provider) errorType=\(String(describing: type(of: error)))", category: .playback)
                            return []
                        }
                    }
                }

                for variant in variants.dropFirst() where !variant.title.isEmpty {
                    group.addTask {
                        do {
                            return try await withCoverLookupTimeout(CoverLookupConfiguration.appleMusicTimeout) {
                                try await AutomaticCoverLookup.appleCandidates(
                                    provider: "appleWeb", title: variant.title, artist: variant.artist,
                                    album: variant.album, duration: duration
                                )
                            }
                        } catch {
                            Log.info("[CoverSearch] event=failed provider=appleWeb errorType=\(String(describing: type(of: error)))", category: .playback)
                            return []
                        }
                    }
                }

                if hasValidAlbum {
                    group.addTask {
                        do {
                            let preferredCandidate = try await withCoverLookupTimeout(
                                CoverLookupConfiguration.netEasePreferredTimeout
                            ) {
                                try await self.netEaseCoverService.searchTopCoverCandidate(
                                    artist: artist,
                                    album: album
                                )
                            }
                            return [preferredCandidate]
                        } catch {
                            Log.info("[CoverSearch] event=failed provider=NetEase errorType=\(String(describing: type(of: error)))", category: .playback)
                            return []
                        }
                    }
                }

                let netEaseName = hasValidAlbum ? searchAlbum : (cleanTitle ?? "")
                if !netEaseName.isEmpty {
                    let artists = searchArtist.isEmpty ? [""] : [searchArtist, ""]
                    for variantArtist in artists {
                        group.addTask {
                            do {
                                return try await withCoverLookupTimeout(
                                    CoverLookupConfiguration.netEaseCandidatesTimeout
                                ) {
                                    try await self.netEaseCoverService.searchCoverCandidates(
                                        artist: variantArtist,
                                        album: netEaseName,
                                        limit: 8
                                    )
                                }
                            } catch {
                                Log.info("[CoverSearch] event=failed provider=NetEase errorType=\(String(describing: type(of: error)))", category: .playback)
                                return []
                            }
                        }
                    }
                }

                if hasValidArtist && hasValidAlbum {
                    group.addTask {
                        do {
                            let data = try await withCoverLookupTimeout(
                                CoverLookupConfiguration.sacadTimeout
                            ) {
                                try await self.coverDownloadService.downloadCover(
                                    artist: artist,
                                    album: album,
                                    size: 1200
                                )
                            }
                            let candidate = CoverCandidate(
                                imageData: data,
                                source: .sacad,
                                sourceItemId: normalizedQuery
                            )
                            return [candidate]
                        } catch {
                            Log.info("[CoverSearch] event=failed provider=Sacad errorType=\(String(describing: type(of: error)))", category: .playback)
                            return []
                        }
                    }
                }

                group.addTask {
                    // The shared helper handles requests serially. Waiting for
                    // each variant avoids timing out requests in its queue.
                    for variant in variants {
                        guard !Task.isCancelled else { break }
                        do {
                            let found = try await withCoverLookupTimeout(
                                CoverLookupConfiguration.qqMusicCandidatesTimeout
                            ) {
                                try await self.qqMusicCoverService.searchCoverCandidates(
                                    title: variant.title.isEmpty ? nil : variant.title,
                                    artist: variant.artist,
                                    album: variant.album,
                                    duration: duration,
                                    limit: 8,
                                    manualSuggestions: true
                                )
                            }
                            await self.publishPartialCandidates(
                                found, generation: generation, title: cleanTitle,
                                artist: searchArtist, album: searchAlbum
                            )
                        } catch QQMusicCoverError.noResults {
                            continue
                        } catch {
                            Log.info("[CoverSearch] event=failed provider=QQMusic errorType=\(String(describing: type(of: error)))", category: .playback)
                            break
                        }
                    }
                    return []
                }

                for await partialCandidates in group {
                    guard searchGeneration == generation, !Task.isCancelled else { return }
                    backgroundCandidates.append(contentsOf: partialCandidates)
                    self.publishMergedCandidates(
                        backgroundCandidates,
                        title: cleanTitle,
                        artist: searchArtist,
                        album: searchAlbum
                    )
                    if self.candidates.isEmpty == false {
                        self.error = nil
                    }
                }
            }

            guard searchGeneration == generation, !Task.isCancelled else { return }
            if candidates.isEmpty {
                error = String(localized: "cover.no_results", defaultValue: "未找到封面")
            }
        }
        searchTask = task
        _ = await task.value
    }

    /// Cancels any ongoing search.
    func cancelSearch() {
        searchTask?.cancel()
        searchGeneration &+= 1
        searchTask = nil
        isLoading = false
    }

    /// Clears all candidates and selection.
    func clear() {
        candidates = []
        selectedForPreview = nil
        error = nil
    }

    /// Selects a candidate for preview (does NOT persist).
    func selectForPreview(_ candidate: CoverCandidate) {
        selectedForPreview = candidate
    }

    /// Returns the image data for the currently selected preview candidate.
    func getPreviewImageData() -> Data? {
        selectedForPreview?.imageData
    }

    /// Normalizes artist+album into a stable query string for ID generation.
    private func normalizeQuery(artist: String, album: String) -> String {
        let combined = "\(artist)-\(album)"
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Simple normalization: remove special chars, collapse spaces
        return combined
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private func publishMergedCandidates(
        _ incomingCandidates: [CoverCandidate],
        title: String?, artist: String, album: String
    ) {
        func rank(_ candidate: CoverCandidate) -> ManualMusicSearch.Rank {
            ManualMusicSearch.rank(
                title: title, artist: artist, album: album,
                candidateTitle: candidate.matchedTitle, candidateArtist: candidate.matchedArtist,
                candidateAlbum: candidate.matchedAlbum
            )
        }
        func isBetter(_ lhs: CoverCandidate, than rhs: CoverCandidate) -> Bool {
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left.isBetter(than: right) }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.squarePixelSize != rhs.squarePixelSize { return lhs.squarePixelSize > rhs.squarePixelSize }
            return lhs.id < rhs.id
        }

        var unique: [String: CoverCandidate] = [:]
        for candidate in candidates + incomingCandidates {
            if let existing = unique[candidate.id], !isBetter(candidate, than: existing) {
                continue
            }
            unique[candidate.id] = candidate
        }
        let merged = unique.values.sorted { isBetter($0, than: $1) }
        candidates = merged

        if let currentSelection = selectedForPreview,
           merged.contains(currentSelection) {
            return
        }
        // Batch editing saves the preview immediately, so broadened suggestions
        // must be selected explicitly unless the original metadata also matches.
        selectedForPreview = merged.first {
            ManualMusicSearch.canAutomaticallyPreview($0, title: title, artist: artist, album: album)
        }
    }

    private func publishPartialCandidates(
        _ incomingCandidates: [CoverCandidate], generation: Int, title: String?, artist: String, album: String
    ) {
        guard searchGeneration == generation, !Task.isCancelled else { return }
        publishMergedCandidates(incomingCandidates, title: title, artist: artist, album: album)
        if !candidates.isEmpty { error = nil }
    }

}
