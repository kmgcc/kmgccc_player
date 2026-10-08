import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

@MainActor
final class AutomationLyricsHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }
    private var queries: AutomationLibraryQueries { AutomationLibraryQueries(appSession: appSession) }

    init(appSession: AppSessionHost?) {
        self.appSession = appSession
    }

    func handle(
        _ request: AutomationRequest
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.lyricsGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLyricsDetail(
                        trackID: trackID,
                        status: queries.trackLyricsStatus(track),
                        ttml: track.ttmlLyricText,
                        plainText: track.lyricsText
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsSearch, AutomationMethod.lyricsCandidates:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                let requestedMode = try parameters.string("mode") ?? LDDCMode.verbatim.rawValue
                guard let mode = LDDCMode(rawValue: requestedMode) else {
                    throw AutomationParameterError.invalidValue("mode")
                }
                let translation = try parameters.boolean("translation", default: true)
                let requestedRefresh = try parameters.boolean("refresh", default: false)
                let shouldRefresh = request.method == AutomationMethod.lyricsSearch
                    || requestedRefresh
                let cache = lyricsCandidateCache[trackID]
                let usedCache = !shouldRefresh
                    && cache?.mode == mode
                    && cache?.translation == translation
                let result: LyricsSearchHelper.SearchResult
                if usedCache, let cache {
                    result = cache.result
                } else {
                    result = await LyricsSearchHelper.performFullSearch(
                        title: track.title,
                        artist: track.artist.isEmpty ? nil : track.artist,
                        album: track.album.isEmpty ? nil : track.album,
                        duration: track.duration > 0 ? track.duration : nil,
                        mode: mode,
                        translation: translation,
                        searchCoordinator: session.cacheServices.lyricsSearchCoordinator
                    )
                    lyricsCandidateCache[trackID] = CachedLyricsCandidates(
                        mode: mode,
                        translation: translation,
                        result: result
                    )
                    trimLyricsCandidateCacheIfNeeded()
                }
                return AutomationResponseSupport.encodeResult(
                    makeLyricsSearchResult(
                        trackID: trackID,
                        track: track,
                        mode: mode,
                        result: result,
                        fromCache: usedCache
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsCompare:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                guard let candidateValues = try parameters.object("candidate") else {
                    throw AutomationParameterError.missing("candidate")
                }
                let candidate = try makeAutomationLyricsCandidate(from: candidateValues)
                let currentQuality = queries.currentLyricsQuality(track)
                let candidateQuality = lyricsQuality(for: candidate)
                return AutomationResponseSupport.encodeResult(
                    AutomationLyricsComparisonResult(
                        trackID: trackID,
                        currentStatus: queries.trackLyricsStatus(track),
                        currentQuality: currentQuality,
                        candidate: candidate,
                        candidateQuality: candidateQuality,
                        shouldReplace: candidateQuality > currentQuality,
                        message: candidateQuality > currentQuality
                            ? "The candidate is a higher synchronization quality than the current lyrics."
                            : "The current lyrics are equal or higher quality; no replacement is recommended."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsApply:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                let candidateValues = try parameters.object("candidate")
                let customTTML = try parameters.string("ttmlText")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let hasCandidate = candidateValues != nil
                let hasCustomTTML = customTTML?.isEmpty == false
                guard hasCandidate != hasCustomTTML else {
                    throw AutomationParameterError.invalidValue("candidate/ttmlText")
                }
                let force = try parameters.boolean("force", default: false)
                let translation = try parameters.boolean("translation", default: true)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let cleanMetadata = try parameters.boolean("cleanMetadata", default: true)
                let expectedRevision = try parameters.string("expectedRevision")
                let currentQuality = queries.currentLyricsQuality(track)
                let candidate: AutomationLyricsCandidate?
                let estimatedQuality: Int
                let effectiveCustomTTML: String?
                if let candidateValues {
                    let parsedCandidate = try makeAutomationLyricsCandidate(from: candidateValues)
                    candidate = parsedCandidate
                    estimatedQuality = lyricsQuality(for: parsedCandidate)
                    effectiveCustomTTML = nil
                } else {
                    guard let rawCustom = customTTML,
                          LyricsFormatSupport.validateTTML(rawCustom).isValid else {
                        throw AutomationParameterError.invalidValue("ttmlText")
                    }
                    candidate = nil
                    let sanitized = cleanMetadata
                        ? LyricsFormatSupport.sanitizeTTML(rawCustom, trackTitle: track.title, artist: track.artist).sanitized
                        : rawCustom
                    effectiveCustomTTML = sanitized
                    estimatedQuality = LyricsFormatSupport.isWordSyncedTTML(sanitized) ? 2 : 1
                }
                if let expectedRevision,
                   expectedRevision != session.libraryViewModel.automationTrackRevision(for: track) {
                    return AutomationResponseSupport.trackRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: session.libraryViewModel.automationTrackRevision(for: track)
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsApplyResult(
                            trackID: trackID,
                            applied: false,
                            dryRun: true,
                            force: force,
                            input: candidate == nil ? "ttmlText" : "candidate",
                            candidate: candidate,
                            ttmlByteCount: effectiveCustomTTML?.utf8.count,
                            currentQuality: currentQuality,
                            candidateQuality: estimatedQuality,
                            message: candidate == nil
                                ? "Preview only. The supplied TTML text will replace the current lyrics directly."
                                : force
                                ? "Preview only. The selected candidate will replace the current lyrics."
                                : "Preview only. The candidate will replace the current lyrics only when its fetched quality is higher."
                        ),
                        for: request
                    )
                }
                if let effectiveCustomTTML {
                    let outcome = await session.applyCustomTTMLForAutomation(
                        trackID: trackID,
                        ttml: effectiveCustomTTML,
                        expectedRevision: expectedRevision
                    )
                    if outcome.conflicted {
                        return AutomationResponseSupport.trackRevisionConflict(
                            for: request,
                            expected: expectedRevision ?? "unknown",
                            actual: session.libraryViewModel.allTracks
                                .first(where: { $0.id == trackID })
                                .map { session.libraryViewModel.automationTrackRevision(for: $0) }
                                ?? "unknown"
                        )
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsApplyResult(
                            trackID: trackID,
                            applied: outcome.applied,
                            dryRun: false,
                            force: force,
                            input: "ttmlText",
                            candidate: nil,
                            ttmlByteCount: effectiveCustomTTML.utf8.count,
                            currentQuality: outcome.currentQuality,
                            candidateQuality: outcome.candidateQuality,
                            message: outcome.message
                        ),
                        for: request
                    )
                }
                guard let candidate else {
                    throw AutomationParameterError.invalidValue("candidate/ttmlText")
                }
                let lddcCandidate = try makeLDDCCandidate(from: candidate)
                guard let ttml = await LyricsSearchHelper.fetchTTMLForAutomation(
                    candidate: lddcCandidate,
                    mode: try lddcMode(for: candidate),
                    translation: translation,
                    amllDBService: session.cacheServices.amllDBService
                ) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .internalError,
                            message: "The selected lyrics candidate could not be fetched or converted.",
                            retryable: true,
                            details: .object([
                                "trackID": .string(trackID.uuidString),
                                "candidateID": .string(candidate.id)
                            ])
                        )
                    )
                }
                let effectiveCandidateTTML = cleanMetadata
                    ? LyricsFormatSupport.sanitizeTTML(ttml, trackTitle: track.title, artist: track.artist).sanitized
                    : ttml
                let fetchedQuality = LyricsFormatSupport.isWordSyncedTTML(effectiveCandidateTTML) ? 2 : 1
                let outcome = await session.applyAutomationLyrics(
                    trackID: trackID,
                    ttml: effectiveCandidateTTML,
                    candidateQuality: fetchedQuality,
                    force: force,
                    expectedRevision: expectedRevision
                )
                if outcome.conflicted {
                    return AutomationResponseSupport.trackRevisionConflict(
                        for: request,
                        expected: expectedRevision ?? "unknown",
                        actual: session.libraryViewModel.allTracks
                            .first(where: { $0.id == trackID })
                            .map { session.libraryViewModel.automationTrackRevision(for: $0) }
                            ?? "unknown"
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLyricsApplyResult(
                        trackID: trackID,
                        applied: outcome.applied,
                        dryRun: false,
                        force: force,
                        input: "candidate",
                        candidate: candidate,
                        currentQuality: outcome.currentQuality,
                        candidateQuality: outcome.candidateQuality,
                        message: outcome.message
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsClean:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                guard let ttml = queries.resolveTTMLText(for: track),
                      !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "Track does not have TTML lyrics to clean.",
                            details: .object(["trackID": .string(trackID.uuidString)])
                        )
                    )
                }
                let (sanitized, removedCount) = LyricsFormatSupport.sanitizeTTML(
                    ttml,
                    trackTitle: track.title,
                    artist: track.artist
                )
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsCleanResult(
                            trackID: trackID,
                            cleaned: removedCount > 0,
                            dryRun: true,
                            removedLines: removedCount,
                            message: removedCount > 0
                                ? "Preview only. \(removedCount) preamble/trailing metadata line(s) will be stripped."
                                : "Lyrics are already clean. No metadata noise lines found.",
                            preview: removedCount > 0 ? sanitized : nil
                        ),
                        for: request
                    )
                }
                if removedCount > 0 {
                    let outcome = await session.applyCustomTTMLForAutomation(
                        trackID: trackID,
                        ttml: sanitized,
                        expectedRevision: nil
                    )
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsCleanResult(
                            trackID: trackID,
                            cleaned: outcome.applied,
                            dryRun: false,
                            removedLines: removedCount,
                            message: outcome.applied
                                ? "Successfully stripped \(removedCount) metadata line(s) and synchronized lyrics start."
                                : outcome.message,
                            preview: nil
                        ),
                        for: request
                    )
                } else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsCleanResult(
                            trackID: trackID,
                            cleaned: false,
                            dryRun: false,
                            removedLines: 0,
                            message: "Lyrics are already clean. No metadata noise lines found.",
                            preview: nil
                        ),
                        for: request
                    )
                }
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsRefresh:
            guard let session = sessionAccess.activeSession(for: request), let appSession else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                let force = try parameters.boolean("force", default: false)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let existingIDs = Set(session.libraryViewModel.allTracks.map(\.id))
                guard trackIDs.allSatisfy(existingIDs.contains) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsRefreshResult(
                            applied: false,
                            dryRun: true,
                            selectedTrackIDs: trackIDs,
                            message: "Preview only. The selected Tracks will be processed by the existing provider pipeline."
                        ),
                        for: request
                    )
                }
                guard let descriptor = appSession.startLyricsRefreshJob(
                    trackIDs: trackIDs,
                    force: force,
                    libraryID: session.context.id
                ) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .serverUnavailable,
                            message: "The lyrics Job could not be started.",
                            retryable: true
                        )
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLyricsRefreshResult(
                        applied: true,
                        dryRun: false,
                        selectedTrackIDs: trackIDs,
                        job: AutomationJobProjection.makeJobSummary(descriptor),
                        message: "Lyrics refresh Job accepted; query jobs.get for progress and failures."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private struct CachedLyricsCandidates {
        let mode: LDDCMode
        let translation: Bool
        let result: LyricsSearchHelper.SearchResult
    }

    private var lyricsCandidateCache: [UUID: CachedLyricsCandidates] = [:]


    private let lyricsCandidateCacheLimit = 256


    private func makeLyricsSearchResult(
        trackID: UUID,
        track: Track,
        mode: LDDCMode,
        result: LyricsSearchHelper.SearchResult,
        fromCache: Bool
    ) -> AutomationLyricsSearchResult {
        AutomationLyricsSearchResult(
            trackID: trackID,
            queryTitle: result.queryTitle,
            queryArtist: result.queryArtist,
            queryAlbum: result.queryAlbum,
            mode: mode.rawValue,
            candidates: result.candidates.map {
                makeAutomationLyricsCandidate($0, mode: mode)
            },
            amlldbCount: result.amlldbCount,
            lddcCount: result.lddcCount,
            message: fromCache
                ? "Returned the last cached provider search for this Track."
                : (result.candidates.isEmpty
                    ? "No lyrics candidates were returned by the configured providers."
                    : "Lyrics candidates were searched and ranked by the existing App provider pipeline.")
        )
    }

    private func makeAutomationLyricsCandidate(
        _ candidate: LDDCCandidate,
        mode: LDDCMode
    ) -> AutomationLyricsCandidate {
        AutomationLyricsCandidate(
            source: candidate.source,
            songID: candidate.songId,
            score: candidate.score,
            normalizedScore: candidate.normalizedScore(),
            title: candidate.title,
            artist: candidate.artist,
            album: candidate.album,
            durationMs: candidate.durationMs,
            mode: mode.rawValue,
            extra: candidate.extra
        )
    }

    private func makeAutomationLyricsCandidate(
        from values: [String: AutomationJSONValue]
    ) throws -> AutomationLyricsCandidate {
        guard case .string(let source) = values["source"], !source.isEmpty,
              case .string(let songID) = values["songID"], !songID.isEmpty,
              case .string(let title) = values["title"], !title.isEmpty,
              case .string(let mode) = values["mode"],
              LDDCMode(rawValue: mode) != nil else {
            throw AutomationParameterError.invalidValue("candidate")
        }
        let score = try jsonDouble(values["score"], key: "candidate.score", default: 0)
        let normalizedScore = try jsonDouble(
            values["normalizedScore"],
            key: "candidate.normalizedScore",
            default: source == "AMLLDB" ? score * 100 : score
        )
        let durationMs = try jsonInt(values["durationMs"], key: "candidate.durationMs")
        var extra: [String: String]?
        if case .object(let rawExtra) = values["extra"] {
            extra = rawExtra.reduce(into: [:]) { result, entry in
                if case .string(let value) = entry.value {
                    result[entry.key] = value
                }
            }
        }
        return AutomationLyricsCandidate(
            source: source,
            songID: songID,
            score: score,
            normalizedScore: normalizedScore,
            title: title,
            artist: optionalJSONString(values["artist"]),
            album: optionalJSONString(values["album"]),
            durationMs: durationMs,
            mode: mode,
            extra: extra
        )
    }

    private func makeLDDCCandidate(
        from candidate: AutomationLyricsCandidate
    ) throws -> LDDCCandidate {
        guard LDDCSource(rawValue: candidate.source) != nil else {
            throw AutomationParameterError.invalidValue("candidate.source")
        }
        return LDDCCandidate(
            source: candidate.source,
            songId: candidate.songID,
            score: candidate.score,
            title: candidate.title,
            artist: candidate.artist,
            album: candidate.album,
            durationMs: candidate.durationMs,
            extra: candidate.extra
        )
    }

    private func lddcMode(
        for candidate: AutomationLyricsCandidate
    ) throws -> LDDCMode {
        guard let mode = LDDCMode(rawValue: candidate.mode) else {
            throw AutomationParameterError.invalidValue("candidate.mode")
        }
        return mode
    }

    private func lyricsQuality(for candidate: AutomationLyricsCandidate) -> Int {
        candidate.mode == LDDCMode.verbatim.rawValue ? 2 : 1
    }

    private func trimLyricsCandidateCacheIfNeeded() {
        guard lyricsCandidateCache.count > lyricsCandidateCacheLimit else { return }
        let removeCount = lyricsCandidateCache.count - lyricsCandidateCacheLimit
        for trackID in lyricsCandidateCache.keys.prefix(removeCount) {
            lyricsCandidateCache.removeValue(forKey: trackID)
        }
    }

    private func optionalJSONString(_ value: AutomationJSONValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    private func jsonDouble(
        _ value: AutomationJSONValue?,
        key: String,
        default defaultValue: Double
    ) throws -> Double {
        guard let value else { return defaultValue }
        guard case .number(let number) = value, number.isFinite else {
            throw AutomationParameterError.invalidType(key, expected: "number")
        }
        return number
    }

    private func jsonInt(
        _ value: AutomationJSONValue?,
        key: String
    ) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw AutomationParameterError.invalidType(key, expected: "integer")
        }
        return Int(number)
    }
}
