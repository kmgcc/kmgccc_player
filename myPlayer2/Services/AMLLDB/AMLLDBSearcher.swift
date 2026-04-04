//
//  AMLLDBSearcher.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB Search Engine
//  Implements multi-dimensional scoring search for AMLLDB
//

import Foundation
import os.log

/// AMLLDB search engine with multi-dimensional scoring
struct AMLLDBSearcher {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.kmgccc.player", category: "AMLLDB")

    // MARK: - Configuration

    /// Maximum candidates to return
    static let maxResults = 50

    /// Maximum candidates for prefiltering
    static let maxPrefilterCandidates = 500

    /// Minimum score threshold for results
    static let minScoreThreshold = 0.15

    // MARK: - Search

    /// Search AMLLDB entries with multi-dimensional scoring
    /// - Parameters:
    ///   - entries: All index entries to search
    ///   - params: Search parameters
    /// - Returns: Scored and ranked candidates
    static func search(
        entries: [AMLLDBRawIndexEntry],
        params: AMLLDBSearchParams
    ) -> [AMLLDBSearchCandidate] {
        let normalizedQuery = prepareQuery(params)

        Self.logger.debug("[AMLLDB] Search query:")
        Self.logger.debug("[AMLLDB]   title: '\(params.title)'")
        Self.logger.debug("[AMLLDB]   normalized: '\(normalizedQuery.normalizedTitle)'")
        Self.logger.debug("[AMLLDB]   aliases: \(normalizedQuery.aliases)")
        Self.logger.debug("[AMLLDB]   artists: \(params.artists)")
        Self.logger.debug("[AMLLDB]   album: \(params.album ?? "nil")")
        Self.logger.debug("[AMLLDB]   duration: \(params.durationMs ?? 0) ms")

        // Step 1: Prefilter by title
        let candidates = prefilterByTitle(
            entries: entries,
            query: normalizedQuery
        )

        Self.logger.debug("[AMLLDB] Prefilter candidate count: \(candidates.count)")

        guard !candidates.isEmpty else {
            return []
        }

        // Step 2: Score candidates
        let scored = scoreCandidates(
            candidates: candidates,
            query: normalizedQuery,
            params: params
        )

        Self.logger.debug("[AMLLDB] Scored candidate count: \(scored.count)")

        // Step 3: Deduplicate and sort
        let deduplicated = deduplicateAndSort(scored)

        Self.logger.debug("[AMLLDB] Deduplicated result count: \(deduplicated.count)")

        // Step 4: Log top results
        logTopResults(Array(deduplicated.prefix(5)))

        // Step 5: Filter and limit
        return Array(deduplicated
            .filter { $0.matchScore.totalScore >= minScoreThreshold }
            .prefix(maxResults))
    }

    // MARK: - Query Preparation

    /// Prepare normalized query from search parameters
    private static func prepareQuery(_ params: AMLLDBSearchParams) -> NormalizedQuery {
        // Normalize title
        let normalizedTitle = AMLLDBTitleNormalizer.normalize(params.title)
        let compactTitle = AMLLDBTitleNormalizer.compactNormalize(params.title)
        let strippedTitle = AMLLDBTitleNormalizer.stripVersionSuffix(params.title)

        // Extract aliases from title
        let (primaryTitle, extractedAliases) = AMLLDBTitleNormalizer.extractAliases(params.title)

        // Normalize aliases
        let aliases = (extractedAliases + [strippedTitle])
            .map { AMLLDBTitleNormalizer.normalize($0) }
            .filter { !$0.isEmpty && $0 != normalizedTitle }

        // Normalize artists
        let normalizedArtists = AMLLDBArtistNormalizer.normalizeArtistArray(params.artists)

        // Normalize album
        let normalizedAlbum = params.album.map { AMLLDBTitleNormalizer.normalize($0) }

        return NormalizedQuery(
            originalTitle: params.title,
            normalizedTitle: normalizedTitle,
            compactTitle: compactTitle,
            strippedTitle: strippedTitle,
            primaryTitle: AMLLDBTitleNormalizer.normalize(primaryTitle),
            aliases: Array(Set(aliases)),
            artists: normalizedArtists,
            album: normalizedAlbum,
            durationMs: params.durationMs
        )
    }

    private struct NormalizedQuery {
        let originalTitle: String
        let normalizedTitle: String
        let compactTitle: String
        let strippedTitle: String
        let primaryTitle: String
        let aliases: [String]
        let artists: [String]
        let album: String?
        let durationMs: Int?
    }

    // MARK: - Prefiltering

    /// Prefilter entries by title contains
    private static func prefilterByTitle(
        entries: [AMLLDBRawIndexEntry],
        query: NormalizedQuery
    ) -> [AMLLDBRawIndexEntry] {
        var candidates: [AMLLDBRawIndexEntry] = []
        candidates.reserveCapacity(min(entries.count, maxPrefilterCandidates))

        // Primary title search
        let primarySearch = query.normalizedTitle

        for entry in entries {
            // Check if any title contains the query
            for title in entry.titles {
                let normalizedEntryTitle = AMLLDBTitleNormalizer.normalize(title)

                // Loose contains check
                if normalizedEntryTitle.contains(primarySearch) ||
                    primarySearch.contains(normalizedEntryTitle) {
                    candidates.append(entry)
                    break
                }

                // Check compact version
                let compactEntry = AMLLDBTitleNormalizer.compactNormalize(title)
                if compactEntry.contains(query.compactTitle) ||
                    query.compactTitle.contains(compactEntry) {
                    candidates.append(entry)
                    break
                }
            }

            // Stop if we have enough candidates
            if candidates.count >= maxPrefilterCandidates {
                break
            }
        }

        // If we don't have enough, try aliases
        if candidates.count < 20 && !query.aliases.isEmpty {
            for alias in query.aliases {
                for entry in entries where !candidates.contains(entry) {
                    for title in entry.titles {
                        let normalized = AMLLDBTitleNormalizer.normalize(title)
                        if normalized.contains(alias) || alias.contains(normalized) {
                            candidates.append(entry)
                            break
                        }
                    }

                    if candidates.count >= maxPrefilterCandidates {
                        break
                    }
                }
            }
        }

        return candidates
    }

    // MARK: - Scoring

    /// Score all candidates
    private static func scoreCandidates(
        candidates: [AMLLDBRawIndexEntry],
        query: NormalizedQuery,
        params: AMLLDBSearchParams
    ) -> [AMLLDBSearchCandidate] {
        candidates.map { entry in
            let score = calculateScore(entry: entry, query: query, params: params)
            return AMLLDBSearchCandidate(
                id: entry.rawLyricFile,
                entry: entry,
                matchScore: score
            )
        }
    }

    /// Calculate multi-dimensional score for an entry
    private static func calculateScore(
        entry: AMLLDBRawIndexEntry,
        query: NormalizedQuery,
        params: AMLLDBSearchParams
    ) -> AMLLDBMatchScore {
        // Title score (try all titles and aliases)
        let titleScore = calculateTitleScore(
            entryTitles: entry.titles,
            query: query
        )

        // Artist score
        let artistScore = calculateArtistScore(
            entryArtists: entry.artists,
            queryArtists: query.artists
        )

        // Duration score
        let durationScore = calculateDurationScore(
            entryDuration: entry.durationMs,
            queryDuration: query.durationMs
        )

        // Album score
        let albumScore = calculateAlbumScore(
            entryAlbums: entry.albums,
            queryAlbum: query.album
        )

        return AMLLDBMatchScore(
            titleScore: titleScore,
            artistScore: artistScore,
            durationScore: durationScore,
            albumScore: albumScore
        )
    }

    /// Calculate title match score
    private static func calculateTitleScore(
        entryTitles: [String],
        query: NormalizedQuery
    ) -> Double {
        var bestScore: Double = 0

        for entryTitle in entryTitles {
            // Compare with original query
            let score1 = AMLLDBTitleNormalizer.compareTitles(entryTitle, query.originalTitle)
            bestScore = max(bestScore, score1)

            // Compare with primary title
            if !query.primaryTitle.isEmpty {
                let score2 = AMLLDBTitleNormalizer.compareTitles(entryTitle, query.primaryTitle)
                bestScore = max(bestScore, score2)
            }

            // Compare with stripped title
            if !query.strippedTitle.isEmpty {
                let score3 = AMLLDBTitleNormalizer.compareTitles(entryTitle, query.strippedTitle)
                bestScore = max(bestScore, score3)
            }
        }

        // Also compare with aliases
        for alias in query.aliases {
            for entryTitle in entryTitles {
                let score = AMLLDBTitleNormalizer.compareTitles(entryTitle, alias)
                // Aliases score slightly lower
                bestScore = max(bestScore, score * 0.95)
            }
        }

        return bestScore
    }

    /// Calculate artist match score
    private static func calculateArtistScore(
        entryArtists: [String],
        queryArtists: [String]
    ) -> Double {
        guard !queryArtists.isEmpty else { return 0 }

        // Use set-based comparison
        return AMLLDBArtistNormalizer.compareArtistSets(entryArtists, queryArtists)
    }

    /// Calculate duration match score
    private static func calculateDurationScore(
        entryDuration: Int?,
        queryDuration: Int?
    ) -> Double {
        guard let queryMs = queryDuration, let entryMs = entryDuration else {
            return 0
        }

        return AMLLDBDurationComparator.compareDuration(
            queryMs: queryMs,
            candidateMs: entryMs
        )
    }

    /// Calculate album match score
    private static func calculateAlbumScore(
        entryAlbums: [String],
        queryAlbum: String?
    ) -> Double {
        guard let queryAlbum = queryAlbum, !queryAlbum.isEmpty else {
            return 0
        }

        // Try each album variant
        var bestScore: Double = 0
        for entryAlbum in entryAlbums {
            let score = AMLLDBAlbumComparator.compareAlbums(queryAlbum, entryAlbum)
            bestScore = max(bestScore, score)
        }

        return bestScore
    }

    // MARK: - Deduplication

    /// Deduplicate by platform IDs and sort by score
    private static func deduplicateAndSort(_ candidates: [AMLLDBSearchCandidate]) -> [AMLLDBSearchCandidate] {
        // Group by platform IDs
        var seenIds: Set<String> = []
        var uniqueCandidates: [AMLLDBSearchCandidate] = []

        // Sort by score first
        let sorted = candidates.sorted { $0.matchScore.totalScore > $1.matchScore.totalScore }

        for candidate in sorted {
            let entry = candidate.entry

            // Use platform IDs for deduplication
            let dedupeKeys = [
                entry.ncmMusicId,
                entry.qqMusicId,
                entry.appleMusicId,
                entry.spotifyId,
                entry.rawLyricFile // Fallback
            ].compactMap { $0 }

            // Check if we've seen any of these IDs
            var isDuplicate = false
            for key in dedupeKeys {
                if seenIds.contains(key) {
                    isDuplicate = true
                    break
                }
            }

            if !isDuplicate {
                // Mark all IDs as seen
                for key in dedupeKeys {
                    seenIds.insert(key)
                }
                uniqueCandidates.append(candidate)
            }
        }

        return uniqueCandidates
    }

    // MARK: - Logging

    /// Log top results for debugging
    private static func logTopResults(_ results: [AMLLDBSearchCandidate]) {
        Self.logger.debug("[AMLLDB] Top results:")
        for (index, result) in results.prefix(5).enumerated() {
            Self.logger.debug(
                "[AMLLDB]   #\(index + 1): '\(result.entry.musicName)' by \(result.entry.artistsDisplay) - score: \(String(format: "%.2f", result.matchScore.totalScore)) (\(result.matchScore.level.rawValue))"
            )
        }
    }
}