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
    /// All candidates found from search, sorted by confidence and resolution.
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

    private let coverDownloadService: CoverDownloadService
    private let netEaseCoverService: NetEaseCoverService
    private let qqMusicCoverService: QQMusicCoverService

    init(
        coverDownloadService: CoverDownloadService,
        netEaseCoverService: NetEaseCoverService,
        qqMusicCoverService: QQMusicCoverService = .shared
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
        isLoading = true
        error = nil
        candidates = []
        selectedForPreview = nil

        let normalizedQuery = normalizeQuery(artist: artist, album: album)

        searchTask = Task {
            defer {
                isLoading = false
                searchTask = nil
            }

            var backgroundCandidates: [CoverCandidate] = []
            await withTaskGroup(of: [CoverCandidate].self) { group in
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
                        print("[CoverSearchCoordinator] NetEase preferred candidate failed: \(error)")
                        return []
                    }
                }

                group.addTask {
                    do {
                        return try await withCoverLookupTimeout(
                            CoverLookupConfiguration.netEaseCandidatesTimeout
                        ) {
                            try await self.netEaseCoverService.searchCoverCandidates(
                                artist: artist,
                                album: album,
                                limit: CoverLookupConfiguration.netEaseCandidateLimit
                            )
                        }
                    } catch {
                        print("[CoverSearchCoordinator] NetEase candidates failed: \(error)")
                        return []
                    }
                }

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
                        print("[CoverSearchCoordinator] Sacad failed: \(error)")
                        return []
                    }
                }

                group.addTask {
                    do {
                        return try await withCoverLookupTimeout(
                            CoverLookupConfiguration.qqMusicCandidatesTimeout
                        ) {
                            try await self.qqMusicCoverService.searchCoverCandidates(
                                title: title,
                                artist: artist,
                                album: album,
                                duration: duration,
                                limit: CoverLookupConfiguration.qqMusicCandidateLimit
                            )
                        }
                    } catch {
                        print("[CoverSearchCoordinator] QQMusic candidates failed: \(error)")
                        return []
                    }
                }

                for await partialCandidates in group {
                    guard !Task.isCancelled else { return }
                    backgroundCandidates.append(contentsOf: partialCandidates)
                    self.publishMergedCandidates(
                        backgroundCandidates,
                        preferExistingSelection: self.selectedForPreview != nil
                    )
                    if self.candidates.isEmpty == false {
                        self.error = nil
                    }
                }
            }

            guard !Task.isCancelled else { return }
            if candidates.isEmpty {
                error = NSLocalizedString("cover.no_results", comment: "No cover found")
            }
        }
    }

    /// Cancels any ongoing search.
    func cancelSearch() {
        searchTask?.cancel()
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
        preferExistingSelection: Bool
    ) {
        var merged = candidates
        for candidate in incomingCandidates {
            if !merged.contains(candidate) {
                merged.append(candidate)
            }
        }

        merged = CoverCandidateSorter.sorted(merged)
        candidates = merged

        if preferExistingSelection,
           let currentSelection = selectedForPreview,
           merged.contains(currentSelection) {
            return
        }

        selectedForPreview = merged.first
    }
}
