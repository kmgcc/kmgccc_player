import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationPlaybackHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }

    init(appSession: AppSessionHost?) {
        self.appSession = appSession
    }

    func handle(
        _ request: AutomationRequest
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.playbackState:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                makePlaybackState(session.playbackCoordinator),
                for: request
            )

        case AutomationMethod.playbackPlay,
             AutomationMethod.playbackPlayPlaylist,
             AutomationMethod.playbackToggle,
             AutomationMethod.playbackPause,
             AutomationMethod.playbackNext,
             AutomationMethod.playbackPrevious,
             AutomationMethod.playbackSeek,
             AutomationMethod.playbackSetVolume,
             AutomationMethod.playbackSetMode:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                switch request.method {
                case AutomationMethod.playbackPlay:
                    let singleTrackID = try parameters.uuid("trackID")
                    let trackIDs = try parameters.uuidArray("trackIDs", allowEmpty: true)
                    let startIndex = try parameters.integer("startIndex", default: 0)
                    if let singleTrackID {
                        guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == singleTrackID }) else {
                            throw AutomationParameterError.missingResource("trackID")
                        }
                        session.playbackCoordinator.play(track: track)
                    } else if !trackIDs.isEmpty {
                        let tracks = try AutomationFileAccess.automationTracks(
                            ids: trackIDs,
                            in: session.libraryViewModel.allTracks
                        )
                        guard (0..<tracks.count).contains(startIndex) else {
                            throw AutomationParameterError.outOfRange("startIndex")
                        }
                        session.playbackCoordinator.playTracks(
                            tracks,
                            startingAt: startIndex
                        )
                    } else {
                        session.playbackCoordinator.resume()
                    }
                case AutomationMethod.playbackPlayPlaylist:
                    let playlistID = try parameters.uuid("playlistID", required: true)!
                    guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                        throw AutomationParameterError.missingResource("playlistID")
                    }
                    let tracks = playlist.tracks
                    let startIndex = try parameters.integer("startIndex", default: 0)
                    guard !tracks.isEmpty, (0..<tracks.count).contains(startIndex) else {
                        throw AutomationParameterError.outOfRange("startIndex")
                    }
                    session.playbackCoordinator.playTracks(tracks, startingAt: startIndex)
                case AutomationMethod.playbackToggle:
                    session.playbackCoordinator.playPause()
                case AutomationMethod.playbackPause:
                    guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                        throw AutomationParameterError.invalidShape
                    }
                    session.playbackCoordinator.pause()
                case AutomationMethod.playbackNext:
                    session.playbackCoordinator.next()
                case AutomationMethod.playbackPrevious:
                    session.playbackCoordinator.previous()
                case AutomationMethod.playbackSeek:
                    guard let seconds = try parameters.double("seconds") else {
                        throw AutomationParameterError.missing("seconds")
                    }
                    guard seconds >= 0 else { throw AutomationParameterError.outOfRange("seconds") }
                    session.playbackCoordinator.seek(to: seconds)
                case AutomationMethod.playbackSetVolume:
                    guard let volume = try parameters.double("volume") else {
                        throw AutomationParameterError.missing("volume")
                    }
                    guard (0...1).contains(volume) else {
                        throw AutomationParameterError.outOfRange("volume")
                    }
                    session.playbackCoordinator.setVolume(volume)
                case AutomationMethod.playbackSetMode:
                    let rawMode = try parameters.string("mode", required: true)!
                    guard let mode = PlaybackOrderMode(rawValue: rawMode) else {
                        throw AutomationParameterError.invalidValue("mode")
                    }
                    session.playbackCoordinator.setPlaybackOrderMode(mode, announceChange: false)
                default:
                    break
                }
                return AutomationResponseSupport.encodeResult(
                    makePlaybackState(session.playbackCoordinator),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.queueGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(makeQueueResult(session), for: request)

        case AutomationMethod.queueUpcoming:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                guard (1...500).contains(limit), offset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }
                let revision = session.playerViewModel.automationQueueRevision
                if let expected = try parameters.string("expectedRevision"), expected != revision {
                    return .failure(for: request, error: AutomationError(
                        code: .conflict,
                        message: "The queue changed since it was queried.",
                        retryable: true,
                        details: .object(["expectedRevision": .string(expected), "actualRevision": .string(revision)])
                    ))
                }
                let ids = session.playerViewModel.currentQueueTracks.map(\.id)
                let start = min(offset, ids.count)
                let page = Array(ids[start..<min(start + limit, ids.count)])
                return AutomationResponseSupport.encodeResult(AutomationQueueUpcomingResult(
                    currentTrackID: session.playbackCoordinator.presentation.localTrack?.id,
                    trackIDs: page, offset: offset, total: ids.count, revision: revision
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.queueReplace,
             AutomationMethod.queueEnqueue,
             AutomationMethod.queueEnqueueNext,
             AutomationMethod.queueRemove,
             AutomationMethod.queueReorder,
             AutomationMethod.queueClear:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let player = session.playerViewModel
                let current = player.currentQueueTracks
                let currentRevision = player.automationQueueRevision
                let expectedRevision = try parameters.string("expectedRevision")
                if let expectedRevision, expectedRevision != currentRevision {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "The queue changed since it was queried.",
                            retryable: true,
                            details: .object([
                                "expectedRevision": .string(expectedRevision),
                                "actualRevision": .string(currentRevision)
                            ])
                        )
                    )
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let nextIDs: [UUID]
                let mutationTracks: [Track]
                switch request.method {
                case AutomationMethod.queueClear:
                    nextIDs = []
                    mutationTracks = []
                case AutomationMethod.queueReplace:
                    nextIDs = try parameters.uuidArray("trackIDs", required: true, allowEmpty: true)
                    mutationTracks = try AutomationFileAccess.automationTracks(ids: nextIDs, in: session.libraryViewModel.allTracks)
                case AutomationMethod.queueEnqueue:
                    let appended = try parameters.uuidArray("trackIDs", required: true)
                    nextIDs = current.map(\.id) + appended
                    mutationTracks = try AutomationFileAccess.automationTracks(ids: appended, in: session.libraryViewModel.allTracks)
                case AutomationMethod.queueEnqueueNext:
                    let appended = try parameters.uuidArray("trackIDs", required: true)
                    mutationTracks = try AutomationFileAccess.automationTracks(ids: appended, in: session.libraryViewModel.allTracks)
                    let currentTrackID = session.playbackCoordinator.presentation.localTrack?.id
                    nextIDs = predictedQueueAfterEnqueueNext(
                        currentIDs: current.map(\.id),
                        currentTrackID: currentTrackID,
                        insertedIDs: mutationTracks.map(\.id)
                    )
                case AutomationMethod.queueRemove:
                    let requestedIDs = try parameters.uuidArray("trackIDs", required: true)
                    var removalCounts = Dictionary(grouping: requestedIDs, by: { $0 }).mapValues(\.count)
                    var remaining: [Track] = []
                    for track in current {
                        if let count = removalCounts[track.id], count > 0 {
                            removalCounts[track.id] = count - 1
                        } else {
                            remaining.append(track)
                        }
                    }
                    guard removalCounts.values.allSatisfy({ $0 == 0 }) else {
                        throw AutomationParameterError.missingResource("trackIDs")
                    }
                    nextIDs = remaining.map(\.id)
                    mutationTracks = []
                case AutomationMethod.queueReorder:
                    let requestedIDs = try parameters.uuidArray("trackIDs", required: true, allowEmpty: true)
                    guard Dictionary(grouping: requestedIDs, by: { $0 }).mapValues(\.count)
                        == Dictionary(grouping: current.map(\.id), by: { $0 }).mapValues(\.count) else {
                        throw AutomationParameterError.invalidValue("trackIDs")
                    }
                    nextIDs = requestedIDs
                    mutationTracks = []
                default:
                    throw AutomationParameterError.invalidValue("method")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        makeQueueResult(
                            session,
                            trackIDs: nextIDs,
                            revision: currentRevision
                        ),
                        for: request
                    )
                }
                switch request.method {
                case AutomationMethod.queueRemove, AutomationMethod.queueReorder:
                    player.updateQueueTracks(nextIDs.compactMap { id in current.first { $0.id == id } })
                case AutomationMethod.queueEnqueueNext:
                    let inserted = session.playbackCoordinator.insertTracksAfterCurrent(mutationTracks)
                    if inserted == 0 {
                        player.updateQueueTracks(current + mutationTracks)
                    }
                case AutomationMethod.queueEnqueue:
                    player.updateQueueTracks(current + mutationTracks)
                default:
                    player.updateQueueTracks(mutationTracks)
                }
                return AutomationResponseSupport.encodeResult(makeQueueResult(session), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private func makePlaybackState(
        _ coordinator: PlaybackCoordinator
    ) -> AutomationPlaybackState {
        let presentation = coordinator.presentation
        let currentTrack = presentation.localTrack
        let playbackMode = presentation.localPlaybackOrderMode?.rawValue
            ?? AppSettings.shared.playbackOrderMode.rawValue
        return AutomationPlaybackState(
            source: coordinator.activeSource.rawValue,
            isPlaying: presentation.isPlaying,
            currentTrackID: currentTrack?.id,
            currentTitle: presentation.title.isEmpty ? nil : presentation.title,
            currentArtist: presentation.artist.isEmpty ? nil : presentation.artist,
            position: max(0, presentation.currentTime),
            duration: max(0, presentation.duration),
            volume: min(max(presentation.volume, 0), 1),
            playbackMode: playbackMode
        )
    }

    private func makeQueueResult(
        _ session: LibrarySession,
        trackIDs: [UUID]? = nil,
        revision: String? = nil
    ) -> AutomationQueueResult {
        AutomationQueueResult(
            trackIDs: trackIDs ?? session.playerViewModel.currentQueueTracks.map(\.id),
            currentTrackID: session.playbackCoordinator.presentation.localTrack?.id,
            revision: revision ?? session.playerViewModel.automationQueueRevision
        )
    }

    /// Mirrors the ordinary (non-shuffle) queue insertion contract for a
    /// dry-run result. The playback owner remains authoritative for the real
    /// mutation; this helper only makes sure a preview never treats the whole
    /// existing queue as newly inserted tracks.
    private func predictedQueueAfterEnqueueNext(
        currentIDs: [UUID],
        currentTrackID: UUID?,
        insertedIDs: [UUID]
    ) -> [UUID] {
        var seen = Set<UUID>()
        let uniqueInserted = insertedIDs.filter { seen.insert($0).inserted }
        guard let currentTrackID,
              currentIDs.contains(currentTrackID) else {
            return currentIDs + uniqueInserted
        }

        let eligibleInserted = uniqueInserted.filter { $0 != currentTrackID }
        let insertionSet = Set(eligibleInserted)
        var queue = currentIDs.filter { !insertionSet.contains($0) }
        guard let updatedCurrentIndex = queue.firstIndex(of: currentTrackID) else {
            return currentIDs + uniqueInserted
        }
        queue.insert(contentsOf: eligibleInserted, at: updatedCurrentIndex + 1)
        return queue
    }
}
