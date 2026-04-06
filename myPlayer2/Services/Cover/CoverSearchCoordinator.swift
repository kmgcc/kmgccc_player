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
    /// All candidates found from search, sorted by resolution descending.
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

    init(
        coverDownloadService: CoverDownloadService,
        netEaseCoverService: NetEaseCoverService
    ) {
        self.coverDownloadService = coverDownloadService
        self.netEaseCoverService = netEaseCoverService
    }

    /// Searches both sources concurrently, merges and sorts candidates.
    /// The highest-resolution candidate becomes selectedForPreview.
    func search(artist: String, album: String) async {
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

            // Concurrent search from both sources
            var sacadCandidate: CoverCandidate? = nil
            var neteaseCandidates: [CoverCandidate] = []

            await withTaskGroup(of: Void.self) { group in
                // Sacad search (single result)
                group.addTask {
                    do {
                        let data = try await self.coverDownloadService.downloadCover(
                            artist: artist,
                            album: album,
                            size: 1200
                        )
                        if !Task.isCancelled {
                            let candidate = await MainActor.run {
                                CoverCandidate(
                                    imageData: data,
                                    source: .sacad,
                                    sourceItemId: normalizedQuery
                                )
                            }
                            sacadCandidate = candidate
                        }
                    } catch {
                        // Sacad failed - continue with NetEase only
                        print("[CoverSearchCoordinator] Sacad failed: \(error)")
                    }
                }

                // NetEase multi-candidate search
                group.addTask {
                    do {
                        let results = try await self.netEaseCoverService.searchCoverCandidates(
                            artist: artist,
                            album: album,
                            limit: 5
                        )
                        if !Task.isCancelled {
                            neteaseCandidates = results
                        }
                    } catch {
                        // NetEase failed - continue with sacad only
                        print("[CoverSearchCoordinator] NetEase failed: \(error)")
                    }
                }
            }

            // If cancelled, don't update candidates - just exit
            guard !Task.isCancelled else { return }

            // Merge candidates
            var merged: [CoverCandidate] = []

            // Add sacad result first (it's from authoritative sources)
            if let sacad = sacadCandidate {
                merged.append(sacad)
            }

            // Add NetEase results, deduplicating by ID
            for candidate in neteaseCandidates {
                // Skip if already present (same ID means same source item)
                if !merged.contains(candidate) {
                    merged.append(candidate)
                }
            }

            // Sort by resolution descending
            merged.sort { $0.resolution > $1.resolution }

            candidates = merged
            // Default selection: highest resolution
            selectedForPreview = merged.first
            if merged.isEmpty {
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
}