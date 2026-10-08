import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

@MainActor
struct AutomationPlaylistHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }
    private var queries: AutomationLibraryQueries { AutomationLibraryQueries(appSession: appSession) }
    private let selectionStore: AutomationSelectionStore

    init(appSession: AppSessionHost?, selectionStore: AutomationSelectionStore) {
        self.appSession = appSession
        self.selectionStore = selectionStore
    }

    func handle(
        _ request: AutomationRequest,
        grantedScopes: @MainActor () -> Set<AutomationScope>,
        executeChild: @MainActor (AutomationRequest) async -> AutomationResponse
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.playlistList:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                AutomationPlaylistListResult(
                    playlists: session.libraryViewModel.playlists.map(queries.makePlaylistSummary)
                ),
                for: request
            )

        case AutomationMethod.playlistCreate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let name = try parameters.string("name", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 255 else {
                    throw AutomationParameterError.outOfRange("name")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistCreate,
                            applied: false,
                            dryRun: true,
                            playlist: nil,
                            message: "Preview only. Set dryRun=false and confirm=true to create the playlist."
                        ),
                        for: request
                    )
                }
                do {
                    let playlist = try await session.libraryViewModel.createPlaylistForAutomation(name: name)
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistCreate,
                            applied: true,
                            dryRun: false,
                            playlist: queries.makePlaylistSummary(playlist),
                            message: "Playlist created."
                        ),
                        for: request
                    )
                } catch {
                    return AutomationResponseSupport.mutationFailure(for: request, error: error)
                }
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistAddTracks:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    required: true,
                    maximumCount: 10_000
                )
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let trackByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missingTrackIDs = requestedTrackIDs.filter { trackByID[$0] == nil }
                guard missingTrackIDs.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "One or more requested tracks are not in the active library.",
                            details: .object([
                                "missingTrackIDs": .array(missingTrackIDs.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                let existingIDs = Set(playlist.tracks.map(\.id))
                let changedTrackIDs = requestedTrackIDs.filter { !existingIDs.contains($0) }
                let skippedTrackIDs = requestedTrackIDs.filter { existingIDs.contains($0) }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistAddTracks,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Preview only. Set dryRun=false and confirm=true to apply."
                        ),
                        for: request
                    )
                }
                guard !changedTrackIDs.isEmpty else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistAddTracks,
                            applied: false,
                            dryRun: false,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: [],
                            skippedTrackIDs: skippedTrackIDs,
                            message: "No playlist membership changes were needed."
                        ),
                        for: request
                    )
                }
                do {
                    try await session.libraryViewModel.addTracksToPlaylistForAutomation(
                        changedTrackIDs.compactMap { trackByID[$0] },
                        playlist: playlist,
                        expectedRevision: expectedRevision
                    )
                    let updatedPlaylist = session.libraryViewModel.playlists.first {
                        $0.id == playlistID
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistAddTracks,
                            applied: true,
                            dryRun: false,
                            playlist: updatedPlaylist.map(queries.makePlaylistSummary),
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Playlist membership updated; library Tracks were reused."
                        ),
                        for: request
                    )
                } catch {
                    return AutomationResponseSupport.mutationFailure(for: request, error: error)
                }
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistAddSelection:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let selectionID = try parameters.uuid("selectionID", required: true)!
                let expectedRevision = try parameters.string("expectedRevision")
                let expectedSelectionRevision = try parameters.string("expectedSelectionRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let snapshots = try selectionStore.load(libraryID: session.context.id)
                guard let snapshot = snapshots.first(where: { $0.summary.id == selectionID }) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The requested selection snapshot does not exist or has expired.",
                            details: .object(["selectionID": .string(selectionID.uuidString)])
                        )
                    )
                }
                let resolved = try queries.resolveSelection(snapshot, viewModel: session.libraryViewModel)
                if let expectedSelectionRevision,
                   expectedSelectionRevision != resolved.summary.revision {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "The saved selection changed after it was read.",
                            details: .object([
                                "expectedRevision": .string(expectedSelectionRevision),
                                "actualRevision": .string(resolved.summary.revision)
                            ])
                        )
                    )
                }
                let availableIDs = Set(session.libraryViewModel.allTracks.map(\.id))
                let missingIDs = resolved.trackIDs.filter { !availableIDs.contains($0) }
                guard missingIDs.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "Some Tracks in the saved selection no longer exist in the active Library.",
                            details: .object([
                                "selectionID": .string(selectionID.uuidString),
                                "missingTrackIDs": .array(missingIDs.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                var values: [String: AutomationJSONValue] = [
                    "playlistID": .string(playlistID.uuidString),
                    "trackIDs": .array(resolved.trackIDs.map { .string($0.uuidString) }),
                    "dryRun": .boolean(dryRun)
                ]
                if let expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                let nestedRequest = AutomationRequest(
                    method: AutomationMethod.playlistAddTracks,
                    params: .object(values),
                    context: request.context,
                    requestID: request.requestID,
                    protocolVersion: request.protocolVersion
                )
                let nestedResponse = await executeChild(nestedRequest)
                if let error = nestedResponse.error {
                    return .failure(for: request, error: error)
                }
                guard let nestedResult = nestedResponse.result else {
                    throw AutomationParameterError.invalidValue("playlistMutationResult")
                }
                let resultData = try AutomationWireCoding.encoder().encode(nestedResult)
                let mutation = try AutomationWireCoding.decoder().decode(
                    AutomationPlaylistMutationResult.self,
                    from: resultData
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistSelectionMutationResult(
                        selectionID: selectionID,
                        selectionRevision: resolved.summary.revision,
                        mutation: mutation
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        case AutomationMethod.playlistRemoveTracks:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    required: true,
                    maximumCount: 10_000
                )
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let trackByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missingTrackIDs = requestedTrackIDs.filter { trackByID[$0] == nil }
                guard missingTrackIDs.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "One or more requested tracks are not in the active library.",
                            details: .object([
                                "missingTrackIDs": .array(missingTrackIDs.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                let existingIDs = Set(playlist.tracks.map(\.id))
                let changedTrackIDs = requestedTrackIDs.filter { existingIDs.contains($0) }
                let skippedTrackIDs = requestedTrackIDs.filter { !existingIDs.contains($0) }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistRemoveTracks,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Preview only. Set dryRun=false and confirm=true to apply."
                        ),
                        for: request
                    )
                }
                guard !changedTrackIDs.isEmpty else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistRemoveTracks,
                            applied: false,
                            dryRun: false,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: [],
                            skippedTrackIDs: skippedTrackIDs,
                            message: "No playlist membership changes were needed."
                        ),
                        for: request
                    )
                }
                do {
                    try await session.libraryViewModel.removeTracksFromPlaylistForAutomation(
                        changedTrackIDs.compactMap { trackByID[$0] },
                        playlist: playlist,
                        expectedRevision: expectedRevision
                    )
                    let updatedPlaylist = session.libraryViewModel.playlists.first {
                        $0.id == playlistID
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistRemoveTracks,
                            applied: true,
                            dryRun: false,
                            playlist: updatedPlaylist.map(queries.makePlaylistSummary),
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Playlist membership updated; library Tracks and files were retained."
                        ),
                        for: request
                    )
                } catch {
                    return AutomationResponseSupport.mutationFailure(for: request, error: error)
                }
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistDetailResult(
                        playlist: queries.makePlaylistSummary(playlist),
                        trackIDs: playlist.tracks.map(\.id)
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistDiff:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistIDs = try parameters.uuidArray("playlistIDs", required: true)
                guard (2...100).contains(playlistIDs.count), Set(playlistIDs).count == playlistIDs.count else {
                    throw AutomationParameterError.invalidValue("playlistIDs")
                }
                let operation = try parameters.string("operation", required: true)!
                guard ["union", "intersection", "difference"].contains(operation) else {
                    throw AutomationParameterError.invalidValue("operation")
                }
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                guard (1...500).contains(limit), offset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }
                let playlistsByID = Dictionary(uniqueKeysWithValues: session.libraryViewModel.playlists.map { ($0.id, $0) })
                guard playlistIDs.allSatisfy({ playlistsByID[$0] != nil }) else {
                    throw AutomationParameterError.missingResource("playlistIDs")
                }
                let orderedMemberships = playlistIDs.map { id in playlistsByID[id]!.tracks.map(\.id) }
                let membershipSets = orderedMemberships.map(Set.init)
                let resultIDs: [UUID]
                switch operation {
                case "union":
                    var seen = Set<UUID>()
                    resultIDs = orderedMemberships.flatMap { $0 }.filter { seen.insert($0).inserted }
                case "intersection":
                    resultIDs = orderedMemberships[0].filter { id in membershipSets.dropFirst().allSatisfy { $0.contains(id) } }
                default:
                    let excluded = membershipSets.dropFirst().reduce(into: Set<UUID>()) { $0.formUnion($1) }
                    resultIDs = orderedMemberships[0].filter { !excluded.contains($0) }
                }
                let summaries = playlistIDs.compactMap { id in playlistsByID[id].map(queries.makePlaylistSummary) }
                let revision = "v1-" + summaries.map(\.revision).joined(separator: ":")
                let start = min(offset, resultIDs.count)
                let page = Array(resultIDs[start..<min(start + limit, resultIDs.count)])
                return AutomationResponseSupport.encodeResult(AutomationPlaylistDiffResult(
                    operation: operation, inputPlaylistIDs: playlistIDs,
                    trackIDs: page, total: resultIDs.count, revision: revision
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistExport:
            guard let session = sessionAccess.activeSession(for: request) else { return sessionAccess.noActiveLibraryResponse(for: request) }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let includePaths = try parameters.boolean("includePaths", default: false)
                guard !includePaths || grantedScopes().contains(.filesRead) else {
                    return .failure(for: request, error: AutomationError(code: .authorizationRequired, message: "Absolute file paths require the files.read scope."))
                }
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                var rows = ["#EXTM3U"]
                var pathCount = 0
                for track in playlist.tracks {
                    let duration = track.duration.isFinite ? max(0, Int(track.duration)) : 0
                    let label = [track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " - ")
                    rows.append("#EXTINF:\(duration),\(label)")
                    if includePaths, let fileURL = AutomationFileAccess.automationTrackFileURL(track, in: session) {
                        rows.append(fileURL.absoluteString)
                        pathCount += 1
                    } else {
                        rows.append("player-track://\(track.id.uuidString)")
                    }
                }
                return AutomationResponseSupport.encodeResult(AutomationPlaylistExportResult(
                    playlist: queries.makePlaylistSummary(playlist),
                    m3uText: rows.joined(separator: "\n") + "\n",
                    exportedTrackCount: playlist.tracks.count,
                    filePathEntryCount: pathCount
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistImport:
            guard let session = sessionAccess.activeSession(for: request) else { return sessionAccess.noActiveLibraryResponse(for: request) }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let m3uText = try parameters.string("m3uText", required: true)!
                guard m3uText.utf8.count <= 5_000_000 else { throw AutomationParameterError.outOfRange("m3uText") }
                let operation = try parameters.string("operation") ?? "append"
                guard operation == "append" || operation == "replace" else { throw AutomationParameterError.invalidValue("operation") }
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(for: request, expected: expectedRevision, actual: summary.revision)
                }
                let tracks = session.libraryViewModel.allTracks
                let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
                var trackIDByPath: [String: UUID] = [:]
                var managedIDByRelativePath: [String: UUID] = [:]
                for track in tracks {
                    if let fileURL = AutomationFileAccess.automationTrackFileURL(track, in: session) {
                        let path = fileURL.standardizedFileURL.path
                        if trackIDByPath[path] == nil { trackIDByPath[path] = track.id }
                    }
                    if let relativePath = track.mediaLocator.managedLibraryRelativePath {
                        managedIDByRelativePath[relativePath] = track.id
                    }
                }
                let entries = m3uText.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                guard entries.count <= 10_000 else { throw AutomationParameterError.outOfRange("m3uText") }
                var matchedTrackIDs: [UUID] = []
                var unmatchedEntries: [String] = []
                for entry in entries {
                    if let url = URL(string: entry), url.scheme == "player-track",
                       let id = UUID(uuidString: url.host ?? url.path), tracksByID[id] != nil {
                        matchedTrackIDs.append(id)
                        continue
                    }
                    let entryURL = URL(string: entry).flatMap { $0.isFileURL ? $0 : nil }
                    let path = entryURL?.path ?? (entry.removingPercentEncoding ?? entry)
                    if let id = trackIDByPath[URL(fileURLWithPath: path).standardizedFileURL.path]
                        ?? managedIDByRelativePath[path] {
                        matchedTrackIDs.append(id)
                    } else {
                        unmatchedEntries.append(entry)
                    }
                }
                var seen = Set<UUID>()
                let uniqueMatched = matchedTrackIDs.filter { seen.insert($0).inserted }
                let targetIDs: [UUID]
                if operation == "append" {
                    var allSeen = Set<UUID>()
                    targetIDs = (playlist.tracks.map(\.id) + uniqueMatched).filter { allSeen.insert($0).inserted }
                } else {
                    targetIDs = uniqueMatched
                }
                guard dryRun || targetIDs != playlist.tracks.map(\.id) else {
                    return AutomationResponseSupport.encodeResult(AutomationPlaylistImportResult(
                        playlist: summary, operation: operation, applied: false, dryRun: false,
                        matchedTrackIDs: matchedTrackIDs, unmatchedEntries: unmatchedEntries
                    ), for: request)
                }
                if !dryRun {
                    try await session.libraryViewModel.replacePlaylistTracksForAutomation(
                        targetIDs.compactMap { tracksByID[$0] }, playlist: playlist,
                        expectedRevision: expectedRevision
                    )
                }
                let updatedPlaylist = session.libraryViewModel.playlists.first { $0.id == playlistID } ?? playlist
                return AutomationResponseSupport.encodeResult(AutomationPlaylistImportResult(
                    playlist: queries.makePlaylistSummary(dryRun ? playlist : updatedPlaylist),
                    operation: operation,
                    applied: !dryRun,
                    dryRun: dryRun,
                    matchedTrackIDs: matchedTrackIDs,
                    unmatchedEntries: unmatchedEntries
                ), for: request)
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.playlistRename:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let name = try parameters.string("name", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 255 else {
                    throw AutomationParameterError.outOfRange("name")
                }
                let description = try parameters.string("description")
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistRename,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            message: "Preview only. Set dryRun=false to rename the playlist."
                        ),
                        for: request
                    )
                }
                let updated = try await session.libraryViewModel.renamePlaylistForAutomation(
                    playlist,
                    name: name,
                    description: description,
                    expectedRevision: expectedRevision
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistMutationResult(
                        operation: AutomationMethod.playlistRename,
                        applied: true,
                        dryRun: false,
                        playlist: queries.makePlaylistSummary(updated),
                        message: "Playlist renamed."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.playlistDelete:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("id", required: true)!
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("id")
                }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistDelete,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            message: "Preview only. This removes the playlist membership but retains Tracks and files."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "删除播放列表需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "playlistID": .string(playlistID.uuidString),
                            "trackCount": .number(Double(summary.trackCount))
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "删除播放列表？",
                    message: "要删除“\(summary.name)”及其 \(summary.trackCount) 条歌曲关系吗？歌曲和音频文件会保留。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                try await session.libraryViewModel.deletePlaylistForAutomation(
                    playlist,
                    expectedRevision: expectedRevision
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistMutationResult(
                        operation: AutomationMethod.playlistDelete,
                        applied: true,
                        dryRun: false,
                        playlist: nil,
                        message: "Playlist deleted; library Tracks and files were retained."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.playlistReplaceTracks, AutomationMethod.playlistReorder:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    required: true,
                    allowEmpty: true
                )
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let currentIDs = playlist.tracks.map(\.id)
                if request.method == AutomationMethod.playlistReorder,
                   Set(requestedTrackIDs) != Set(currentIDs) {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let trackByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missing = requestedTrackIDs.filter { trackByID[$0] == nil }
                guard missing.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "One or more requested Tracks are not in the active library.",
                            details: .object([
                                "missingTrackIDs": .array(missing.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                let operation = request.method
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: operation,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: requestedTrackIDs,
                            message: "Preview only. Set dryRun=false to apply the ordered membership."
                        ),
                        for: request
                    )
                }
                try await session.libraryViewModel.replacePlaylistTracksForAutomation(
                    requestedTrackIDs.compactMap { trackByID[$0] },
                    playlist: playlist,
                    expectedRevision: expectedRevision
                )
                let updated = session.libraryViewModel.playlists.first { $0.id == playlistID }
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistMutationResult(
                        operation: operation,
                        applied: true,
                        dryRun: false,
                        playlist: updated.map(queries.makePlaylistSummary),
                        requestedTrackIDs: requestedTrackIDs,
                        changedTrackIDs: requestedTrackIDs,
                        message: "Playlist membership order updated; no files were imported or deleted."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }


}
