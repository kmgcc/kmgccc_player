//
//  LyricsSearchHelper.swift
//  myPlayer2
//
//  kmgccc_player - Shared Lyrics Search Helper
//  Provides unified lyric search logic for both import-time and manual search flows.
//  Ensures both flows use the same ranking, normalization, and merging behavior.
//

import Foundation
import os.log

/// Shared helper for lyrics search operations.
/// Used by both import enrichment and manual LDDC search UI.
/// Note: This runs on MainActor since AMLLDBService requires it.
@MainActor
struct LyricsSearchHelper {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.kmgccc.player", category: "LyricsSearchHelper")

    // MARK: - Search Configuration

    /// Default sources for LDDC search (nonisolated because it's just a configuration constant)
    nonisolated static let defaultLDDCSources: Set<LDDCSource> = [.QM, .KG, .NE]
    nonisolated static let automaticMatchMinimumScore = 75.0

    struct AutomaticFetchCandidateSummary: Sendable, Equatable {
        let title: String
        let source: String
        let normalizedScore: Double
    }

    struct AutomaticFetchResult: Sendable, Equatable {
        enum Status: String, Sendable, Equatable {
            case matched
            case noCandidates
            case thresholdRejected
            case allCandidatesFailed
        }

        let status: Status
        let ttml: String?
        let topCandidate: AutomaticFetchCandidateSummary?
        let fetchedCandidate: AutomaticFetchCandidateSummary?
        let threshold: Double?
    }

    /// Search result containing merged and ranked candidates
    struct SearchResult: Sendable {
        let candidates: [LDDCCandidate]
        let amlldbCount: Int
        let lddcCount: Int
        let topCandidate: LDDCCandidate?
        let queryTitle: String
        let queryArtist: String?
        let queryAlbum: String?
    }

    // MARK: - Full Search

    /// Perform a full lyrics search using both AMLLDB and LDDC sources.
    /// Returns merged and ranked results using the same logic as the manual search UI.
    /// - Parameters:
    ///   - title: Song title to search
    ///   - artist: Artist name (optional)
    ///   - album: Album name (optional)
    ///   - duration: Duration in seconds (optional, improves AMLLDB matching)
    ///   - lddcSources: LDDC sources to search (default: QM, KG, NE)
    ///   - mode: LDDC search mode (default: verbatim for word-by-word)
    ///   - translation: Include translation (default: true)
    ///   - amlldbLimit: Maximum AMLLDB results (default: 20)
    ///   - lddcLimitPerSource: Maximum results per LDDC source (default: 5)
    /// - Returns: SearchResult with merged, ranked candidates
    static func performFullSearch(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        lddcSources: Set<LDDCSource> = defaultLDDCSources,
        mode: LDDCMode = .verbatim,
        translation: Bool = true,
        amlldbLimit: Int = 20,
        lddcLimitPerSource: Int = 5
    ) async -> SearchResult {
        Self.logger.debug("[LyricsSearchHelper] Starting full search - title: '\(title)', artist: '\(artist ?? "nil")', album: '\(album ?? "nil")'")

        // Run AMLLDB and LDDC searches in parallel
        async let amlldbTask: [LDDCCandidate] = performAMLLDBSearch(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            limit: amlldbLimit
        )

        async let lddcTask: [LDDCCandidate] = performLDDCSearch(
            title: title,
            artist: artist,
            sources: lddcSources,
            mode: mode,
            translation: translation,
            limitPerSource: lddcLimitPerSource
        )

        let amlldbResults = await amlldbTask
        let lddcResults = await lddcTask

        Self.logger.debug("[LyricsSearchHelper] Raw results: AMLLDB=\(amlldbResults.count), LDDC=\(lddcResults.count)")

        // Log top 3 candidates for debugging
        #if DEBUG
        for candidate in amlldbResults.prefix(3) {
            let normScore = candidate.normalizedScore()
            Self.logger.debug("[LyricsSearchHelper] AMLLDB top candidate: '\(candidate.title)' rawScore=\(candidate.score) normalized=\(normScore)")
        }
        for candidate in lddcResults.prefix(3) {
            let normScore = candidate.normalizedScore()
            Self.logger.debug("[LyricsSearchHelper] LDDC top candidate: '\(candidate.title)' source=\(candidate.source) rawScore=\(candidate.score) normalized=\(normScore)")
        }
        #endif

        // Merge with proper ranking (same logic as LDDCSearchSection)
        let mergedResults = mergeAndSortResults(amlldb: amlldbResults, lddc: lddcResults)

        Self.logger.info("[LyricsSearchHelper] Merged result count: \(mergedResults.count) (AMLLDB: \(amlldbResults.count), LDDC: \(lddcResults.count))")

        // Log final top 3
        #if DEBUG
        for (index, candidate) in mergedResults.prefix(3).enumerated() {
            let normScore = candidate.normalizedScore()
            Self.logger.debug("[LyricsSearchHelper] Final ranked #\(index + 1): '\(candidate.title)' source=\(candidate.source) normalized=\(normScore)")
        }
        #endif

        let topCandidate = mergedResults.first

        if let top = topCandidate {
            Self.logger.info("[LyricsSearchHelper] Top candidate selected: '\(top.title)' source=\(top.source) normalizedScore=\(top.normalizedScore())")
        } else {
            Self.logger.warning("[LyricsSearchHelper] No candidates found for query")
            recordLyricsDiagnostic(
                level: .warning,
                category: .noResults,
                stage: .lyricsSearch,
                provider: .unknown,
                messageCode: "lyrics_search_no_results",
                operation: "search",
                lyricsSource: "unknown",
                lyricsFormat: "unknown",
                resultCount: 0
            )
        }

        return SearchResult(
            candidates: mergedResults,
            amlldbCount: amlldbResults.count,
            lddcCount: lddcResults.count,
            topCandidate: topCandidate,
            queryTitle: title,
            queryArtist: artist,
            queryAlbum: album
        )
    }

    // MARK: - AMLLDB Search

    /// Perform AMLLDB lyrics search
    private static func performAMLLDBSearch(
        title: String,
        artist: String?,
        album: String?,
        duration: Double?,
        limit: Int
    ) async -> [LDDCCandidate] {
        let amlldbService = AMLLDBService.shared

        // Ensure index is ready (non-blocking if already ready)
        let ready = await amlldbService.ensureIndexReady()

        guard ready else {
            Self.logger.warning("[LyricsSearchHelper] AMLLDB index not ready, skipping AMLLDB search")
            recordLyricsDiagnostic(
                level: .warning,
                category: .providerFailure,
                stage: .lyricsSearch,
                provider: .amll,
                messageCode: "amlldb_index_not_ready",
                operation: "search",
                lyricsSource: "amll",
                lyricsFormat: "ttml",
                resultCount: 0
            )
            return []
        }

        Self.logger.debug("[LyricsSearchHelper] AMLLDB search - title: '\(title)', artist: '\(artist ?? "nil")', album: '\(album ?? "nil")'")

        let results = amlldbService.search(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            limit: limit
        )

        Self.logger.debug("[LyricsSearchHelper] AMLLDB returned \(results.count) results")

        return results.map { $0.toLDDCCandidate() }
    }

    // MARK: - LDDC Search

    /// Perform LDDC lyrics search
    private static func performLDDCSearch(
        title: String,
        artist: String?,
        sources: Set<LDDCSource>,
        mode: LDDCMode,
        translation: Bool,
        limitPerSource: Int
    ) async -> [LDDCCandidate] {
        guard !sources.isEmpty else {
            Self.logger.debug("[LyricsSearchHelper] No LDDC sources selected, skipping LDDC search")
            return []
        }

        Self.logger.debug("[LyricsSearchHelper] LDDC search - title: '\(title)', artist: '\(artist ?? "nil")', sources: \(sources.map { $0.rawValue })")

        let client = LDDCClient()

        do {
            let response = try await client.search(
                title: title,
                artist: artist,
                sources: Array(sources),
                mode: mode,
                translation: translation,
                limitPerSource: limitPerSource
            )

            Self.logger.debug("[LyricsSearchHelper] LDDC returned \(response.results.count) results")

            if let errors = response.errors, !errors.isEmpty {
                Self.logger.warning("[LyricsSearchHelper] LDDC partial errors: \(errors.joined(separator: ", "))")
                recordLyricsDiagnostic(
                    level: .warning,
                    category: .providerFailure,
                    stage: .lyricsSearch,
                    provider: .unknown,
                    messageCode: "lddc_partial_provider_errors",
                    operation: "search",
                    lyricsSource: "unknown",
                    lyricsFormat: mode == .verbatim ? "lrc" : "plain",
                    resultCount: response.results.count,
                    errorCode: "lddc_partial_provider_errors"
                )
            }

            return response.results
        } catch {
            Self.logger.error("[LyricsSearchHelper] LDDC search failed: \(error.localizedDescription)")
            recordLyricsDiagnostic(
                level: .error,
                category: .providerFailure,
                stage: .lyricsSearch,
                provider: .unknown,
                messageCode: DiagnosticsErrorMapper.code(for: error),
                operation: "search",
                lyricsSource: "unknown",
                lyricsFormat: mode == .verbatim ? "lrc" : "plain",
                resultCount: 0,
                errorCode: DiagnosticsErrorMapper.code(for: error)
            )
            return []
        }
    }

    // MARK: - Result Merging & Sorting

    /// Merge AMLLDB and LDDC results with proper ranking.
    /// High-confidence AMLLDB results (>=80%) are promoted to the top.
    /// All other results are sorted together by normalized score.
    /// This is the EXACT same logic used in LDDCSearchSection.
    static func mergeAndSortResults(amlldb: [LDDCCandidate], lddc: [LDDCCandidate]) -> [LDDCCandidate] {
        // Separate AMLLDB results by confidence level
        let highConfidenceAMLLDB = amlldb.filter { $0.normalizedScore() >= 80.0 }
            .sorted { $0.normalizedScore() > $1.normalizedScore() }

        let lowerConfidenceAMLLDB = amlldb.filter { $0.normalizedScore() < 80.0 }

        // Combine lower-confidence AMLLDB with all LDDC results
        let remainingResults = (lowerConfidenceAMLLDB + lddc)
            .sorted { $0.normalizedScore() > $1.normalizedScore() }

        // Final order: high-confidence AMLLDB first, then remaining sorted by score
        return highConfidenceAMLLDB + remainingResults
    }

    // MARK: - Lyrics Fetch

    /// Fetch lyrics content for a candidate
    /// - Parameters:
    ///   - candidate: The candidate to fetch lyrics for
    ///   - mode: LDDC mode (for conversion)
    ///   - translation: Whether to include translation
    ///   - stripMetadata: Whether to strip metadata from converted TTML
    /// - Returns: TTML lyrics content, or nil if failed
    static func fetchLyricsContent(
        candidate: LDDCCandidate,
        mode: LDDCMode = .verbatim,
        translation: Bool = true,
        stripMetadata: Bool = false
    ) async -> String? {
        Self.logger.info("[LyricsSearchHelper] Fetching lyrics for candidate: '\(candidate.title)' source=\(candidate.source)")

        do {
            // AMLLDB candidates are already TTML
            if candidate.source == "AMLLDB" {
                let rawLyricFile = candidate.songId
                let ttml: String
                do {
                    ttml = try await AMLLDBService.shared.downloadLyricsByRawFile(rawLyricFile)
                } catch {
                    recordLyricsDiagnostic(
                        level: .error,
                        category: .providerFailure,
                        stage: .lyricsDownload,
                        provider: .amll,
                        messageCode: DiagnosticsErrorMapper.code(for: error),
                        operation: "download",
                        lyricsSource: "amll",
                        lyricsFormat: "ttml",
                        resultCount: 0,
                        errorCode: DiagnosticsErrorMapper.code(for: error)
                    )
                    throw error
                }
                Self.logger.info("[LyricsSearchHelper] AMLLDB TTML fetched: \(rawLyricFile), \(ttml.count) bytes")
                return ttml
            }

            // LDDC candidates need conversion
            let client = LDDCClient()

            if translation {
                let (origLyrics, transLyrics): (String, String?)
                do {
                    (origLyrics, transLyrics) = try await client.fetchByIdSeparate(
                        candidate: candidate,
                        mode: mode
                    )
                } catch {
                    recordLyricsDiagnostic(
                        level: .error,
                        category: .providerFailure,
                        stage: .lyricsDownload,
                        provider: diagnosticsProvider(for: candidate.source),
                        messageCode: DiagnosticsErrorMapper.code(for: error),
                        operation: "download",
                        lyricsSource: diagnosticsLyricsSource(for: candidate.source),
                        lyricsFormat: mode == .verbatim ? "lrc" : "plain",
                        resultCount: 0,
                        errorCode: DiagnosticsErrorMapper.code(for: error)
                    )
                    throw error
                }

                let ttml: String
                if let trans = transLyrics, !trans.isEmpty {
                    do {
                        ttml = try await TTMLConverter.shared.convertToTTMLWithTranslation(
                            origLyrics: origLyrics,
                            transLyrics: trans,
                            stripMetadata: stripMetadata
                        )
                    } catch {
                        recordLyricsConversionFailure(
                            error: error,
                            candidate: candidate,
                            mode: mode,
                            lineCount: lineCount(origLyrics) + lineCount(trans),
                            hasTranslation: true
                        )
                        throw error
                    }
                    Self.logger.info("[LyricsSearchHelper] LDDC converted with translation: \(ttml.count) bytes")
                } else {
                    do {
                        ttml = try await TTMLConverter.shared.convertToTTML(
                            rawLyrics: origLyrics,
                            stripMetadata: stripMetadata
                        )
                    } catch {
                        recordLyricsConversionFailure(
                            error: error,
                            candidate: candidate,
                            mode: mode,
                            lineCount: lineCount(origLyrics),
                            hasTranslation: false
                        )
                        throw error
                    }
                    Self.logger.info("[LyricsSearchHelper] LDDC converted (no translation): \(ttml.count) bytes")
                }
                return ttml
            } else {
                let lyrics: String
                do {
                    lyrics = try await client.fetchById(
                        candidate: candidate,
                        mode: mode,
                        translation: false
                    )
                } catch {
                    recordLyricsDiagnostic(
                        level: .error,
                        category: .providerFailure,
                        stage: .lyricsDownload,
                        provider: diagnosticsProvider(for: candidate.source),
                        messageCode: DiagnosticsErrorMapper.code(for: error),
                        operation: "download",
                        lyricsSource: diagnosticsLyricsSource(for: candidate.source),
                        lyricsFormat: mode == .verbatim ? "lrc" : "plain",
                        resultCount: 0,
                        errorCode: DiagnosticsErrorMapper.code(for: error)
                    )
                    throw error
                }
                let ttml: String
                do {
                    ttml = try await TTMLConverter.shared.convertToTTML(
                        rawLyrics: lyrics,
                        stripMetadata: stripMetadata
                    )
                } catch {
                    recordLyricsConversionFailure(
                        error: error,
                        candidate: candidate,
                        mode: mode,
                        lineCount: lineCount(lyrics),
                        hasTranslation: false
                    )
                    throw error
                }
                Self.logger.info("[LyricsSearchHelper] LDDC converted: \(ttml.count) bytes")
                return ttml
            }
        } catch {
            Self.logger.error("[LyricsSearchHelper] Lyrics fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Convenience: Search and Fetch Best

    /// Perform full search and fetch lyrics for the best candidate.
    /// Falls back to subsequent candidates if the top candidate returns empty or fails.
    /// This is the one-shot method for import-time lyrics lookup.
    /// - Parameters:
    ///   - title: Song title to search
    ///   - artist: Artist name (optional)
    ///   - album: Album name (optional)
    ///   - duration: Duration in seconds (optional)
    /// - Returns: TTML lyrics content for the first valid candidate, or nil if all fail
    static func searchAndFetchBestLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: Double?
    ) async -> String? {
        let result = await searchAndFetchLyrics(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            minimumTopCandidateScore: nil
        )
        return result.ttml
    }

    /// Perform search and fetch for AM automatic online matching only.
    /// A minimum top-candidate score is enforced to avoid bad auto-applies.
    static func searchAndFetchAutomaticallyMatchedLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: Double?
    ) async -> AutomaticFetchResult {
        await searchAndFetchLyrics(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            minimumTopCandidateScore: automaticMatchMinimumScore
        )
    }

    private static func searchAndFetchLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: Double?,
        minimumTopCandidateScore: Double?
    ) async -> AutomaticFetchResult {
        Self.logger.info("[LyricsSearchHelper] searchAndFetchBestLyrics called for: '\(title)' by '\(artist ?? "unknown")'")

        let searchResult = await performFullSearch(
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )

        let candidates = searchResult.candidates
        guard !candidates.isEmpty else {
            Self.logger.warning("[LyricsSearchHelper] No candidates found at all")
            recordLyricsDiagnostic(
                level: .warning,
                category: .noResults,
                stage: .lyricsSearch,
                provider: .unknown,
                messageCode: "lyrics_auto_no_candidates",
                operation: "search",
                lyricsSource: "unknown",
                lyricsFormat: "unknown",
                resultCount: 0
            )
            return AutomaticFetchResult(
                status: .noCandidates,
                ttml: nil,
                topCandidate: nil,
                fetchedCandidate: nil,
                threshold: minimumTopCandidateScore
            )
        }

        let topCandidate = candidateSummary(for: candidates.first)
        if let minimumTopCandidateScore,
           let topCandidate,
           topCandidate.normalizedScore <= minimumTopCandidateScore {
            Self.logger.warning(
                "[LyricsSearchHelper] Top candidate rejected by threshold: score=\(topCandidate.normalizedScore) threshold=\(minimumTopCandidateScore) title='\(topCandidate.title)' source=\(topCandidate.source)"
            )
            return AutomaticFetchResult(
                status: .thresholdRejected,
                ttml: nil,
                topCandidate: topCandidate,
                fetchedCandidate: nil,
                threshold: minimumTopCandidateScore
            )
        }

        for (index, candidate) in candidates.enumerated() {
            Self.logger.info("[LyricsSearchHelper] Trying candidate #\(index + 1)/\(candidates.count): '\(candidate.title)' source=\(candidate.source)")
            let ttml = await fetchLyricsContent(candidate: candidate)
            if let ttml, !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Self.logger.info("[LyricsSearchHelper] Candidate #\(index + 1) succeeded: '\(candidate.title)' source=\(candidate.source) length=\(ttml.count)")
                return AutomaticFetchResult(
                    status: .matched,
                    ttml: ttml,
                    topCandidate: topCandidate,
                    fetchedCandidate: candidateSummary(for: candidate),
                    threshold: minimumTopCandidateScore
                )
            }
            let reason = ttml == nil ? "fetch failed" : "content empty"
            Self.logger.warning("[LyricsSearchHelper] Candidate #\(index + 1) rejected: \(reason) — '\(candidate.title)' source=\(candidate.source)")
        }

        Self.logger.warning("[LyricsSearchHelper] All \(candidates.count) candidates failed for '\(title)'")
        recordLyricsDiagnostic(
            level: .error,
            category: .providerFailure,
            stage: .lyricsDownload,
            provider: .unknown,
            messageCode: "lyrics_auto_all_candidates_failed",
            operation: "download",
            lyricsSource: "unknown",
            lyricsFormat: "unknown",
            resultCount: candidates.count
        )
        return AutomaticFetchResult(
            status: .allCandidatesFailed,
            ttml: nil,
            topCandidate: topCandidate,
            fetchedCandidate: nil,
            threshold: minimumTopCandidateScore
        )
    }

    private static func candidateSummary(for candidate: LDDCCandidate?) -> AutomaticFetchCandidateSummary? {
        guard let candidate else { return nil }
        return AutomaticFetchCandidateSummary(
            title: candidate.title,
            source: candidate.source,
            normalizedScore: candidate.normalizedScore()
        )
    }

    private static func recordLyricsConversionFailure(
        error: Error,
        candidate: LDDCCandidate,
        mode: LDDCMode,
        lineCount: Int,
        hasTranslation: Bool
    ) {
        recordLyricsDiagnostic(
            level: .error,
            category: .parse,
            stage: .lyricsConvert,
            provider: diagnosticsProvider(for: candidate.source),
            messageCode: DiagnosticsErrorMapper.code(for: error),
            operation: "convert",
            lyricsSource: diagnosticsLyricsSource(for: candidate.source),
            lyricsFormat: mode == .verbatim ? "lrc" : "plain",
            resultCount: 0,
            lineCount: lineCount,
            hasTranslation: hasTranslation,
            errorCode: DiagnosticsErrorMapper.code(for: error),
            conversionPath: "lrc_to_ttml"
        )
    }

    private static func recordLyricsDiagnostic(
        level: DiagnosticsLevel,
        category: DiagnosticsCategory,
        stage: DiagnosticsStage,
        provider: DiagnosticsProvider,
        messageCode: String,
        operation: String,
        lyricsSource: String,
        lyricsFormat: String,
        resultCount: Int,
        lineCount: Int? = nil,
        hasTranslation: Bool? = nil,
        errorCode: String? = nil,
        conversionPath: String? = nil
    ) {
        var context: DiagnosticsContext = [
            "lyrics_source": .string(lyricsSource),
            "lyrics_format": .string(lyricsFormat),
            "operation": .string(operation),
            "result_count_bucket": .string(DiagnosticsBuckets.resultCount(resultCount)),
            "retry_count": .int(0),
            "has_romanization": .string("unknown")
        ]
        if let lineCount {
            context["line_count_bucket"] = .string(DiagnosticsBuckets.lineCount(lineCount))
        }
        context["has_translation"] = hasTranslation.map { .bool($0) } ?? .string("unknown")
        if let errorCode {
            if case .parse = category {
                context["parse_error_code"] = .string(errorCode)
            } else {
                context["network_error_code"] = .string(errorCode)
            }
            context["error_code"] = .string(errorCode)
        }
        if let conversionPath {
            context["conversion_path"] = .string(conversionPath)
        }
        DiagnosticsService.shared.record(
            level: level,
            subsystem: .lyrics,
            category: category,
            stage: stage,
            provider: provider,
            messageCode: messageCode,
            context: context
        )
    }

    private static func diagnosticsProvider(for source: String) -> DiagnosticsProvider {
        switch source.uppercased() {
        case "AMLLDB": return .amll
        case "QM": return .qqmusic
        case "KG": return .kugou
        case "NE": return .netease
        default: return .unknown
        }
    }

    private static func diagnosticsLyricsSource(for source: String) -> String {
        switch source.uppercased() {
        case "AMLLDB": return "amll"
        case "QM": return "qqmusic"
        case "KG": return "kugou"
        case "NE": return "netease"
        default: return "unknown"
        }
    }

    private static func lineCount(_ lyrics: String) -> Int {
        lyrics.split(whereSeparator: \.isNewline).count
    }
}
