import CryptoKit
import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationMetadataHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }
    private var queries: AutomationLibraryQueries { AutomationLibraryQueries(appSession: appSession) }

    init(appSession: AppSessionHost?) {
        self.appSession = appSession
    }

    func handle(
        _ request: AutomationRequest,
        grantedScopes: @MainActor () -> Set<AutomationScope>
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.metadataGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let entityType = try parameters.string("entityType")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let query = try parameters.string("query")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                guard (1...500).contains(limit), offset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }
                let artistID = try parameters.uuid("artistID")
                let albumKey = try parameters.string("albumKey")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let playlistID = try parameters.uuid("playlistID")
                let requestedEntityCount = [artistID != nil, albumKey != nil, playlistID != nil]
                    .filter { $0 }
                    .count
                var trackIDs = try parameters.uuidArray("trackIDs")
                if let trackID = try parameters.uuid("trackID") {
                    trackIDs.append(trackID)
                }
                if let entityType {
                    guard ["artist", "album", "playlist"].contains(entityType),
                          trackIDs.isEmpty,
                          requestedEntityCount == 0 else {
                        throw AutomationParameterError.invalidValue("entityType")
                    }
                    return AutomationResponseSupport.encodeResult(
                        makeMetadataCollectionResult(
                            entityType: entityType,
                            query: query,
                            offset: offset,
                            limit: limit,
                            session: session
                        ),
                        for: request
                    )
                }
                guard (query == nil || query?.isEmpty == true) && limit == 100 && offset == 0 else {
                    throw AutomationParameterError.invalidValue("query/limit/offset")
                }
                if !trackIDs.isEmpty && requestedEntityCount > 0 {
                    throw AutomationParameterError.invalidValue("trackID/artistID/albumKey/playlistID")
                }
                if trackIDs.isEmpty && requestedEntityCount > 0 {
                    let target = try resolveMetadataTarget(
                        artistID: artistID,
                        albumKey: albumKey,
                        playlistID: playlistID,
                        session: session
                    )
                    return AutomationResponseSupport.encodeResult(
                        makeMetadataGetResult(for: target, session: session),
                        for: request
                    )
                }
                trackIDs = Array(Set(trackIDs)).sorted { $0.uuidString < $1.uuidString }
                guard !trackIDs.isEmpty else {
                    throw AutomationParameterError.missing("trackID or trackIDs")
                }
                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missingIDs = trackIDs.filter { tracksByID[$0] == nil }
                guard missingIDs.isEmpty else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let tracks = trackIDs.compactMap { tracksByID[$0] }
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryTracksResult(
                        tracks: tracks.map {
                            queries.makeTrackSummary(
                                $0,
                                playlists: session.libraryViewModel.playlists,
                                includeFilePath: grantedScopes().contains(.filesRead)
                            )
                        },
                        total: tracks.count,
                        offset: 0,
                        limit: tracks.count,
                        revision: queries.libraryTracksRevision(
                            tracks: session.libraryViewModel.allTracks,
                            playlists: session.libraryViewModel.playlists
                        )
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataEmbeddedGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                var trackIDs = try parameters.uuidArray("trackIDs", maximumCount: 100)
                if let trackID = try parameters.uuid("trackID") {
                    guard trackIDs.isEmpty else {
                        throw AutomationParameterError.invalidValue("trackID/trackIDs")
                    }
                    trackIDs = [trackID]
                }
                guard !trackIDs.isEmpty, Set(trackIDs).count == trackIDs.count else {
                    throw AutomationParameterError.missing("trackID or trackIDs")
                }
                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                guard trackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                var results: [AutomationEmbeddedTagTrack] = []
                for trackID in trackIDs {
                    guard let track = tracksByID[trackID] else { continue }
                    do {
                        let fileURL = try AutomationFileAccess.embeddedAudioFileURL(for: track, session: session)
                        let snapshot = await readEmbeddedTags(from: fileURL)
                        results.append(AutomationEmbeddedTagTrack(
                            id: track.id,
                            fileName: fileURL.lastPathComponent,
                            format: fileURL.pathExtension.lowercased(),
                            supportedForWrite: snapshot.supportedForWrite,
                            trackRevision: session.libraryViewModel.automationTrackRevision(for: track),
                            values: snapshot.values,
                            status: snapshot.status,
                            message: snapshot.message
                        ))
                    } catch {
                        results.append(AutomationEmbeddedTagTrack(
                            id: track.id,
                            fileName: "",
                            format: "",
                            supportedForWrite: false,
                            trackRevision: session.libraryViewModel.automationTrackRevision(for: track),
                            status: "unavailable",
                            message: "The active audio file is unavailable or not authorized."
                        ))
                    }
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationEmbeddedTagsResult(
                        dryRun: false,
                        applied: false,
                        libraryRevision: queries.libraryTracksRevision(
                            tracks: session.libraryViewModel.allTracks,
                            playlists: session.libraryViewModel.playlists
                        ),
                        tracks: results,
                        message: "Tags were read from the active audio files; App metadata was not changed."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataEmbeddedPatch:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                var trackIDs = try parameters.uuidArray("trackIDs", maximumCount: 100)
                if let trackID = try parameters.uuid("trackID") {
                    guard trackIDs.isEmpty else {
                        throw AutomationParameterError.invalidValue("trackID/trackIDs")
                    }
                    trackIDs = [trackID]
                }
                guard !trackIDs.isEmpty, Set(trackIDs).count == trackIDs.count else {
                    throw AutomationParameterError.missing("trackID or trackIDs")
                }
                guard let rawFields = try parameters.object("fields"), !rawFields.isEmpty,
                      rawFields.count <= 16 else {
                    throw AutomationParameterError.missing("fields")
                }
                var fields: [String: String?] = [:]
                for (name, value) in rawFields {
                    guard MP3EmbeddedTagService.supportedFields.contains(name) else {
                        throw AutomationParameterError.invalidValue("fields.\(name)")
                    }
                    switch value {
                    case .string(let text) where text.count <= 16_384:
                        fields.updateValue(text, forKey: name)
                    case .null:
                        fields.updateValue(nil, forKey: name)
                    default:
                        throw AutomationParameterError.invalidValue("fields.\(name)")
                    }
                }
                let expectedRevisions = try queries.makeTrackRevisions(
                    from: parameters.object("expectedRevisions")
                )
                guard trackIDs.allSatisfy({ expectedRevisions[$0] != nil }) else {
                    throw AutomationParameterError.missing("expectedRevisions for every Track")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                guard trackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                var previews: [AutomationEmbeddedTagTrack] = []
                var writeRequests: [MP3EmbeddedTagService.WriteRequest] = []
                for trackID in trackIDs {
                    guard let track = tracksByID[trackID] else { continue }
                    let trackRevision = session.libraryViewModel.automationTrackRevision(for: track)
                    guard expectedRevisions[trackID] == trackRevision else {
                        previews.append(AutomationEmbeddedTagTrack(
                            id: trackID,
                            fileName: "",
                            format: "",
                            supportedForWrite: false,
                            trackRevision: trackRevision,
                            status: "conflict",
                            message: "Track metadata changed after the write was reviewed."
                        ))
                        continue
                    }
                    do {
                        let fileURL = try AutomationFileAccess.embeddedAudioFileURL(for: track, session: session)
                        guard fileURL.pathExtension.lowercased() == "mp3" else {
                            previews.append(AutomationEmbeddedTagTrack(
                                id: trackID,
                                fileName: fileURL.lastPathComponent,
                                format: fileURL.pathExtension.lowercased(),
                                supportedForWrite: false,
                                trackRevision: trackRevision,
                                status: "unsupported",
                                message: "Only MP3 files with safely editable ID3v2 tags can be written."
                            ))
                            continue
                        }
                        let currentTags = try MP3EmbeddedTagService.read(from: fileURL)
                        let currentValues = embeddedTagValues(currentTags)
                        previews.append(AutomationEmbeddedTagTrack(
                            id: trackID,
                            fileName: fileURL.lastPathComponent,
                            format: "mp3",
                            supportedForWrite: true,
                            trackRevision: trackRevision,
                            values: currentValues,
                            status: "ready"
                        ))
                        writeRequests.append(MP3EmbeddedTagService.WriteRequest(
                            trackID: trackID,
                            fileURL: fileURL,
                            fileName: fileURL.lastPathComponent,
                            expectedTrackRevision: trackRevision,
                            fields: fields
                        ))
                    } catch {
                        previews.append(AutomationEmbeddedTagTrack(
                            id: trackID,
                            fileName: "",
                            format: "mp3",
                            supportedForWrite: false,
                            trackRevision: trackRevision,
                            status: "unsupported",
                            message: MP3EmbeddedTagService.publicMessage(for: error)
                        ))
                    }
                }
                let libraryRevision = queries.libraryTracksRevision(
                    tracks: session.libraryViewModel.allTracks,
                    playlists: session.libraryViewModel.playlists
                )
                guard !writeRequests.isEmpty else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationEmbeddedTagsResult(
                            dryRun: dryRun,
                            applied: false,
                            libraryRevision: libraryRevision,
                            tracks: previews,
                            message: "No eligible MP3 files were found; no files were changed."
                        ),
                        for: request
                    )
                }
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationEmbeddedTagsResult(
                            dryRun: true,
                            applied: false,
                            libraryRevision: libraryRevision,
                            tracks: previews,
                            message: "Preview only. The listed ID3 fields are ready for an atomic MP3 update."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "写入原音频标签需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "trackCount": .number(Double(writeRequests.count)),
                            "fields": .array(fields.keys.sorted().map(AutomationJSONValue.string)),
                            "requiresForegroundConfirmation": .boolean(true)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "写入 \(writeRequests.count) 个 MP3 文件标签？",
                    message: "将按预览写入 ID3 标签并替换原音频文件；每首歌曲分别校验，失败的文件保持原样。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let descriptor = session.startAutomationEmbeddedTagWrite(requests: writeRequests) else {
                    throw AutomationParameterError.invalidValue("library session is closing")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationEmbeddedTagsResult(
                        dryRun: false,
                        applied: false,
                        libraryRevision: libraryRevision,
                        tracks: previews,
                        job: AutomationJobProjection.makeJobSummary(descriptor),
                        message: "The embedded-tag Job was started. Query jobs.get for per-file completion and failures."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.metadataExport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    maximumCount: 100
                )
                let allTracks = session.libraryViewModel.allTracks
                let revision = queries.libraryTracksRevision(
                    tracks: allTracks,
                    playlists: session.libraryViewModel.playlists
                )
                let pageTracks: [Track]
                let offset: Int
                let limit: Int
                let total: Int
                if !requestedTrackIDs.isEmpty {
                    guard Set(requestedTrackIDs).count == requestedTrackIDs.count,
                          parameters.values["offset"] == nil,
                          parameters.values["limit"] == nil else {
                        throw AutomationParameterError.invalidValue("trackIDs/limit/offset")
                    }
                    let tracksByID = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.id, $0) })
                    guard requestedTrackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                        throw AutomationParameterError.missingResource("trackIDs")
                    }
                    pageTracks = requestedTrackIDs.compactMap { tracksByID[$0] }
                    offset = 0
                    limit = pageTracks.count
                    total = pageTracks.count
                } else {
                    limit = try parameters.integer("limit", default: 100)
                    offset = try parameters.integer("offset", default: 0)
                    guard (1...100).contains(limit), offset >= 0 else {
                        throw AutomationParameterError.outOfRange("limit/offset")
                    }
                    let ordered = allTracks.sorted {
                        if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    total = ordered.count
                    pageTracks = Array(ordered.dropFirst(min(offset, ordered.count)).prefix(limit))
                }
                let nextOffset = offset + pageTracks.count < total
                    ? offset + pageTracks.count
                    : nil
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataDocument(
                        sourceLibraryID: session.context.id,
                        revision: revision,
                        offset: offset,
                        limit: limit,
                        total: total,
                        nextOffset: nextOffset,
                        tracks: pageTracks.map { track in
                            queries.makeMetadataDocumentTrack(
                                track,
                                revision: session.libraryViewModel.automationTrackRevision(for: track)
                            )
                        }
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataImport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                guard let rawDocument = parameters.values["document"] else {
                    throw AutomationParameterError.missing("document")
                }
                let documentData = try AutomationWireCoding.encoder().encode(rawDocument)
                let document = try AutomationWireCoding.decoder().decode(
                    AutomationMetadataDocument.self,
                    from: documentData
                )
                guard document.schemaVersion == 1,
                      (1...100).contains(document.tracks.count),
                      Set(document.tracks.map(\.id)).count == document.tracks.count else {
                    throw AutomationParameterError.invalidValue("document")
                }
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let overwriteExistingFields = try parameters.boolean("overwriteExistingFields", default: false)
                let currentTracks = session.libraryViewModel.allTracks
                let currentRevision = queries.libraryTracksRevision(
                    tracks: currentTracks,
                    playlists: session.libraryViewModel.playlists
                )
                if let expectedRevision, expectedRevision != currentRevision {
                    return AutomationResponseSupport.revisionConflict(for: request, expected: expectedRevision, actual: currentRevision)
                }

                let sourceIDs = Set(document.tracks.map(\.id))
                let rawIDMap = try parameters.object("trackIDMap") ?? [:]
                guard rawIDMap.count <= 500 else {
                    throw AutomationParameterError.outOfRange("trackIDMap")
                }
                var trackIDMap: [UUID: UUID] = [:]
                for (sourceIDValue, targetIDValue) in rawIDMap {
                    guard let sourceID = UUID(uuidString: sourceIDValue),
                          sourceIDs.contains(sourceID),
                          case .string(let targetValue) = targetIDValue,
                          let targetID = UUID(uuidString: targetValue) else {
                        throw AutomationParameterError.invalidValue("trackIDMap")
                    }
                    trackIDMap[sourceID] = targetID
                }
                if document.sourceLibraryID != session.context.id,
                   Set(trackIDMap.keys) != sourceIDs {
                    throw AutomationParameterError.invalidValue("trackIDMap.crossLibraryRequired")
                }
                let targetIDs = document.tracks.compactMap { record in
                    trackIDMap[record.id] ?? (document.sourceLibraryID == session.context.id ? record.id : nil)
                }
                guard Set(targetIDs).count == targetIDs.count else {
                    throw AutomationParameterError.invalidValue("trackIDMap.duplicateTargets")
                }
                let currentByID = Dictionary(uniqueKeysWithValues: currentTracks.map { ($0.id, $0) })
                var planned: [PlannedMetadataImport] = []
                for record in document.tracks {
                    _ = try makeMetadataPatch(record.fields)
                    let targetID = trackIDMap[record.id]
                        ?? (document.sourceLibraryID == session.context.id ? record.id : nil)
                    guard let targetID, let track = currentByID[targetID] else {
                        planned.append(PlannedMetadataImport(
                            record: record,
                            targetTrackID: targetID,
                            patch: nil,
                            expectedRevision: nil,
                            fields: [],
                            status: "missing",
                            message: "No active-library Track matches this document entry."
                        ))
                        continue
                    }
                    let trackRevision = session.libraryViewModel.automationTrackRevision(for: track)
                    if document.sourceLibraryID == session.context.id,
                       record.revision != trackRevision {
                        planned.append(PlannedMetadataImport(
                            record: record,
                            targetTrackID: targetID,
                            patch: nil,
                            expectedRevision: trackRevision,
                            fields: [],
                            status: "conflict",
                            message: "The Track metadata changed after this document was exported."
                        ))
                        continue
                    }
                    let values = metadataImportFields(
                        record.fields,
                        currentTrack: track,
                        overwriteExistingFields: overwriteExistingFields
                    )
                    let patch = try makeMetadataPatch(values)
                    let changes = metadataPatchChanges(track, patch: patch)
                    planned.append(PlannedMetadataImport(
                        record: record,
                        targetTrackID: targetID,
                        patch: patch,
                        expectedRevision: trackRevision,
                        fields: changes ? Array(patch.fields) : [],
                        status: changes ? "ready" : "unchanged",
                        message: changes ? "Metadata fields are ready to apply." : "No eligible metadata fields would change."
                    ))
                }
                var items = planned.map {
                    AutomationMetadataImportItem(
                        sourceTrackID: $0.record.id,
                        targetTrackID: $0.targetTrackID,
                        status: $0.status,
                        fields: $0.fields,
                        message: $0.message
                    )
                }
                if dryRun || planned.contains(where: { $0.status == "missing" }) {
                    return AutomationResponseSupport.encodeResult(
                        AutomationMetadataImportResult(
                            libraryID: session.context.id,
                            sourceLibraryID: document.sourceLibraryID,
                            dryRun: dryRun,
                            applied: false,
                            items: items,
                            revision: currentRevision,
                            message: dryRun
                                ? "Preview only; no metadata was written."
                                : "No metadata was written because one or more target Tracks are missing."
                        ),
                        for: request
                    )
                }
                let readyCount = planned.filter { $0.status == "ready" }.count
                guard readyCount > 0 else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationMetadataImportResult(
                            libraryID: session.context.id,
                            sourceLibraryID: document.sourceLibraryID,
                            dryRun: false,
                            applied: false,
                            items: items,
                            revision: currentRevision,
                            message: "No eligible metadata fields required an update."
                        ),
                        for: request
                    )
                }
                guard try parameters.boolean("confirm", default: false) else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "Import this Track metadata document?",
                        details: .object([
                            "trackCount": .number(Double(readyCount)),
                            "sourceLibraryID": .string(document.sourceLibraryID.uuidString),
                            "expectedRevision": .string(currentRevision),
                            "requiresForegroundConfirmation": .boolean(true)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "导入曲目元数据？",
                    message: "要为 \(readyCount) 首歌曲写入元数据吗？默认只补充空字段。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }

                var itemBySourceID = Dictionary(uniqueKeysWithValues: items.map { ($0.sourceTrackID, $0) })
                for item in planned where item.status == "ready" {
                    guard let targetID = item.targetTrackID,
                          let patch = item.patch,
                          let expectedTrackRevision = item.expectedRevision else {
                        continue
                    }
                    do {
                        let outcome = try await session.libraryViewModel.applyMetadataPatchForAutomation(
                            trackIDs: [targetID],
                            patch: patch,
                            expectedRevisions: [targetID: expectedTrackRevision]
                        )
                        let status: String
                        let message: String
                        if outcome.updatedTrackIDs.contains(targetID) {
                            status = "updated"
                            message = "Metadata was written through the App-owned persistence path."
                        } else if outcome.conflictedTrackIDs.contains(targetID) {
                            status = "conflict"
                            message = "The Track changed after preview; no metadata was written."
                        } else {
                            status = "unchanged"
                            message = "The Track already had these metadata values."
                        }
                        itemBySourceID[item.record.id] = AutomationMetadataImportItem(
                            sourceTrackID: item.record.id,
                            targetTrackID: targetID,
                            status: status,
                            fields: item.fields,
                            message: message
                        )
                    } catch {
                        itemBySourceID[item.record.id] = AutomationMetadataImportItem(
                            sourceTrackID: item.record.id,
                            targetTrackID: targetID,
                            status: "failed",
                            fields: item.fields,
                            message: "The App could not persist this Track's metadata."
                        )
                    }
                }
                items = planned.compactMap { itemBySourceID[$0.record.id] }
                let applied = items.contains { $0.status == "updated" }
                let hasFailure = items.contains { ["failed", "conflict", "missing"].contains($0.status) }
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataImportResult(
                        libraryID: session.context.id,
                        sourceLibraryID: document.sourceLibraryID,
                        dryRun: false,
                        applied: applied,
                        items: items,
                        revision: queries.libraryTracksRevision(
                            tracks: session.libraryViewModel.allTracks,
                            playlists: session.libraryViewModel.playlists
                        ),
                        message: hasFailure
                            ? "Metadata import finished with conflicts or item failures; inspect each item status."
                            : "Track metadata import completed through the App-owned persistence path."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataSearch:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                var providerWarnings: [String: String] = [:]
                var candidates: [AutomationMetadataCandidate] = []
                do {
                    let qqCandidates = try await session.libraryViewModel.searchTrackMetadataCandidatesForAutomation(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        duration: track.duration
                    )
                    candidates.append(contentsOf: qqCandidates.map { candidate in
                        let artist = candidate.artist ?? candidate.artistName
                        return AutomationMetadataCandidate(
                            candidateID: candidate.songMid,
                            provider: candidate.source,
                            title: candidate.title,
                            artist: artist,
                            album: candidate.album,
                            durationSeconds: candidate.duration,
                            confidence: candidate.confidence,
                            matchQuality: AutomationMetadataQualityEvaluator.score(
                                queryTitle: track.title,
                                queryArtist: track.artist,
                                queryAlbum: track.album,
                                queryDurationSeconds: track.duration,
                                candidateTitle: candidate.title,
                                candidateArtist: artist,
                                candidateAlbum: candidate.album,
                                candidateDurationSeconds: candidate.duration.map(Double.init)
                            ),
                            imageURL: candidate.imageURL
                        )
                    })
                } catch {
                    providerWarnings["QQMusic"] = error.localizedDescription
                }
                do {
                    let musicBrainzCandidates = try await MusicBrainzAutomationProvider.shared.search(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        durationSeconds: track.duration
                    )
                    candidates.append(contentsOf: musicBrainzCandidates.map { candidate in
                        AutomationMetadataCandidate(
                            candidateID: "musicbrainz:\(candidate.recordingID)",
                            provider: "MusicBrainz",
                            title: candidate.title,
                            artist: candidate.artist,
                            album: candidate.album,
                            durationSeconds: candidate.durationSeconds,
                            confidence: nil,
                            matchQuality: AutomationMetadataQualityEvaluator.score(
                                queryTitle: track.title,
                                queryArtist: track.artist,
                                queryAlbum: track.album,
                                queryDurationSeconds: track.duration,
                                candidateTitle: candidate.title,
                                candidateArtist: candidate.artist,
                                candidateAlbum: candidate.album,
                                candidateDurationSeconds: candidate.durationSeconds.map(Double.init)
                            ),
                            imageURL: nil
                        )
                    })
                } catch {
                    providerWarnings["MusicBrainz"] = error.localizedDescription
                }
                candidates.sort {
                    let leftQuality = $0.matchQuality ?? -1
                    let rightQuality = $1.matchQuality ?? -1
                    if leftQuality != rightQuality { return leftQuality > rightQuality }
                    if $0.provider != $1.provider { return $0.provider < $1.provider }
                    return ($0.candidateID ?? "") < ($1.candidateID ?? "")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataSearchResult(
                        trackID: track.id,
                        queryTitle: track.title,
                        queryArtist: track.artist,
                        queryAlbum: track.album,
                        candidates: candidates,
                        revision: session.libraryViewModel.automationTrackRevision(for: track),
                        message: candidates.isEmpty
                            ? (providerWarnings.isEmpty
                                ? "Metadata providers returned no candidates."
                                : "No provider returned candidates; inspect providerWarnings for failures.")
                            : (providerWarnings.isEmpty
                                ? "Candidates were ranked with provider-neutral field matching; no metadata was changed."
                                : "Candidates are available from some providers; inspect providerWarnings for incomplete results."),
                        providerWarnings: providerWarnings.isEmpty ? nil : providerWarnings
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataApplyCandidate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                let candidateID = try parameters.string("candidateID", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidateID.isEmpty,
                      let initialTrack = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID/candidateID")
                }
                let initialRevision = session.libraryViewModel.automationTrackRevision(for: initialTrack)
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let overwriteExistingFields = try parameters.boolean("overwriteExistingFields", default: false)
                if let expectedRevision, expectedRevision != initialRevision {
                    let mutation = AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: dryRun,
                        conflictedTrackIDs: [trackID],
                        message: "The Track changed after the candidate was selected. Search again before applying."
                    )
                    return AutomationResponseSupport.encodeResult(
                        AutomationMetadataCandidateApplyResult(
                            trackID: trackID,
                            candidateID: candidateID,
                            dryRun: dryRun,
                            overwriteExistingFields: overwriteExistingFields,
                            previewPatch: [:],
                            mutation: mutation
                        ),
                        for: request
                    )
                }

                var titleValue: String?
                var artistValue: String?
                var albumValue: String?
                var descriptionValue: String?
                var genreTags: [String] = []
                var languageValue: String?
                var labelValue: String?
                var releaseDateValue: Date?
                var qqMusicSongMID: String?
                var metadataSource: String
                var metadataFetchedAt = Date()
                var metadataConfidence: Double?
                var musicBrainzReleaseID: String?

                if candidateID.hasPrefix("musicbrainz:") {
                    let recordingID = String(candidateID.dropFirst("musicbrainz:".count))
                    let candidates: [MusicBrainzAutomationCandidate]
                    do {
                        candidates = try await MusicBrainzAutomationProvider.shared.search(
                            title: initialTrack.title,
                            artist: initialTrack.artist,
                            album: initialTrack.album,
                            durationSeconds: initialTrack.duration
                        )
                    } catch {
                        return metadataProviderUnavailable(error, provider: "MusicBrainz", for: request)
                    }
                    guard candidates.contains(where: { $0.recordingID == recordingID }) else {
                        throw AutomationParameterError.missingResource("candidateID")
                    }
                    let detail: MusicBrainzAutomationCandidate?
                    do {
                        detail = try await MusicBrainzAutomationProvider.shared.recording(id: recordingID)
                    } catch {
                        return metadataProviderUnavailable(error, provider: "MusicBrainz", for: request)
                    }
                    guard let detail else {
                        throw AutomationParameterError.missingResource("metadata candidate detail")
                    }
                    titleValue = detail.title
                    artistValue = detail.artist
                    albumValue = detail.album
                    genreTags = detail.genreTags
                    releaseDateValue = Self.musicBrainzReleaseDate(detail.releaseDate)
                    musicBrainzReleaseID = detail.releaseID
                    metadataSource = MetadataDetailSource.musicbrainz.rawValue
                } else {
                    let candidates: [QQMusicArtworkCandidate]
                    do {
                        candidates = try await session.libraryViewModel.searchTrackMetadataCandidatesForAutomation(
                            title: initialTrack.title,
                            artist: initialTrack.artist,
                            album: initialTrack.album,
                            duration: initialTrack.duration
                        )
                    } catch {
                        return metadataProviderUnavailable(error, provider: "QQMusic", for: request)
                    }
                    guard candidates.contains(where: { $0.songMid == candidateID }) else {
                        throw AutomationParameterError.missingResource("candidateID")
                    }
                    let detail: TrackMetadataDetail
                    do {
                        detail = try await session.libraryViewModel.fetchTrackMetadataDetailForAutomation(
                            candidateID,
                            title: initialTrack.title,
                            artist: initialTrack.artist,
                            album: initialTrack.album,
                            duration: initialTrack.duration
                        )
                    } catch {
                        return metadataProviderUnavailable(error, provider: "QQMusic", for: request)
                    }
                    titleValue = detail.title
                    artistValue = detail.artist
                    albumValue = detail.album
                    descriptionValue = detail.description
                    genreTags = detail.genreTags
                    languageValue = detail.language
                    labelValue = detail.labelOrCompany
                    releaseDateValue = detail.releaseDate
                    qqMusicSongMID = detail.qqMusicSongMid
                    metadataSource = detail.source.rawValue
                    metadataFetchedAt = detail.fetchedAt ?? Date()
                    metadataConfidence = detail.confidence
                }
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }

                var patchValues: [String: AutomationJSONValue] = [:]
                func addString(_ key: String, value: String?, current: String) {
                    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                          overwriteExistingFields || current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return
                    }
                    patchValues[key] = .string(value)
                }
                addString("title", value: titleValue, current: track.title)
                addString("artist", value: artistValue, current: track.artist)
                addString("album", value: albumValue, current: track.album)
                addString("description", value: descriptionValue, current: track.userDescription)
                if !genreTags.isEmpty && (overwriteExistingFields || track.genreTags.isEmpty) {
                    patchValues["genreTags"] = .array(genreTags.map(AutomationJSONValue.string))
                }
                addString("language", value: languageValue, current: track.language)
                addString("labelOrCompany", value: labelValue, current: track.labelOrCompany)
                if let releaseDate = releaseDateValue,
                   overwriteExistingFields || track.releaseDate == nil {
                    patchValues["releaseDate"] = .string(ISO8601DateFormatter().string(from: releaseDate))
                }
                if let qqMusicSongMID {
                    patchValues["qqMusicSongMid"] = .string(qqMusicSongMID)
                }
                addString("musicBrainzReleaseID", value: musicBrainzReleaseID, current: track.musicBrainzReleaseID ?? "")
                patchValues["metadataSource"] = .string(metadataSource)
                patchValues["metadataFetchedAt"] = .string(
                    ISO8601DateFormatter().string(from: metadataFetchedAt)
                )
                if let metadataConfidence, metadataConfidence.isFinite {
                    patchValues["metadataConfidence"] = .number(metadataConfidence)
                }

                let currentRevision = session.libraryViewModel.automationTrackRevision(for: track)
                let conflicted = currentRevision != initialRevision
                    || (expectedRevision != nil && expectedRevision != currentRevision)
                let patch = try makeMetadataPatch(patchValues)
                let changed = !conflicted && metadataPatchChanges(track, patch: patch)
                let outcome: LibraryAutomationMetadataMutationOutcome
                if dryRun || conflicted || !changed {
                    outcome = LibraryAutomationMetadataMutationOutcome(
                        updatedTrackIDs: [],
                        skippedTrackIDs: !conflicted && !changed ? [trackID] : [],
                        conflictedTrackIDs: conflicted ? [trackID] : []
                    )
                } else {
                    outcome = try await session.libraryViewModel.applyMetadataPatchForAutomation(
                        trackIDs: [trackID],
                        patch: patch,
                        expectedRevisions: [trackID: initialRevision]
                    )
                }
                let mutation = AutomationMetadataMutationResult(
                    applied: !dryRun && !outcome.updatedTrackIDs.isEmpty,
                    dryRun: dryRun,
                    updatedTrackIDs: outcome.updatedTrackIDs,
                    skippedTrackIDs: outcome.skippedTrackIDs,
                    conflictedTrackIDs: outcome.conflictedTrackIDs,
                    message: dryRun
                        ? "Preview only. Existing values are preserved unless overwriteExistingFields is true."
                        : "The selected metadata candidate was applied through the App-owned metadata persistence path."
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataCandidateApplyResult(
                        trackID: trackID,
                        candidateID: candidateID,
                        dryRun: dryRun,
                        overwriteExistingFields: overwriteExistingFields,
                        previewPatch: patchValues,
                        mutation: mutation
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataPatch:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs")
                let hasSingularTrack = try parameters.uuid("trackID") != nil
                let hasEntityTarget = try hasMetadataEntityTarget(parameters)
                if trackIDs.isEmpty || hasEntityTarget || hasSingularTrack {
                    if !trackIDs.isEmpty || (hasSingularTrack && hasEntityTarget) {
                        throw AutomationParameterError.invalidValue("metadata target")
                    }
                    return try await applyMetadataToSingleTarget(
                        parameters: parameters,
                        request: request,
                        session: session
                    )
                }
                guard let patchValues = try parameters.object("patch"), !patchValues.isEmpty else {
                    throw AutomationParameterError.missing("patch")
                }
                let patch = try makeMetadataPatch(patchValues)
                let expectedRevisions = try queries.makeTrackRevisions(
                    from: parameters.object("expectedRevisions")
                )
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missingIDs = trackIDs.filter { tracksByID[$0] == nil }
                guard missingIDs.isEmpty else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let candidates = trackIDs.compactMap { tracksByID[$0] }
                let changedIDs = candidates.compactMap { track -> UUID? in
                    guard metadataPatchChanges(track, patch: patch) else { return nil }
                    guard let expected = expectedRevisions[track.id] else {
                        return track.id
                    }
                    return expected == session.libraryViewModel.automationTrackRevision(for: track)
                        ? track.id
                        : nil
                }
                let conflictIDs: [UUID] = candidates.compactMap { (track: Track) -> UUID? in
                    guard let expected = expectedRevisions[track.id],
                          expected != session.libraryViewModel.automationTrackRevision(for: track) else {
                        return nil
                    }
                    return track.id
                }
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationMetadataMutationResult(
                            applied: false,
                            dryRun: true,
                            updatedTrackIDs: changedIDs,
                            skippedTrackIDs: candidates.map(\.id).filter { !changedIDs.contains($0) && !conflictIDs.contains($0) },
                            conflictedTrackIDs: conflictIDs,
                            message: "Preview only. This updates App-owned metadata and never writes embedded file tags."
                        ),
                        for: request
                    )
                }
                if trackIDs.count >= 10 {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "批量修改歌曲信息需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(AutomationMethod.metadataPatch),
                                "trackCount": .number(Double(trackIDs.count)),
                                "threshold": .number(10),
                                "requiresForegroundConfirmation": .boolean(true)
                            ])
                        )
                    }
                    if !AutomationBatchExecutionContext.aggregateConfirmationApproved {
                        guard await AutomationInteraction.confirmDestructiveOperation(
                            title: "修改 \(trackIDs.count) 首歌曲的信息？",
                            message: "要将这些歌曲的信息更新到播放器资料库吗？原音频文件和内嵌标签不会修改。"
                        ) else {
                            return AutomationResponseSupport.interactionCancelled(for: request)
                        }
                    }
                }
                let outcome = try await session.libraryViewModel.applyMetadataPatchForAutomation(
                    trackIDs: trackIDs,
                    patch: patch,
                    expectedRevisions: expectedRevisions
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: !outcome.updatedTrackIDs.isEmpty,
                        dryRun: false,
                        updatedTrackIDs: outcome.updatedTrackIDs,
                        skippedTrackIDs: outcome.skippedTrackIDs,
                        conflictedTrackIDs: outcome.conflictedTrackIDs,
                        message: outcome.conflictedTrackIDs.isEmpty
                            ? "App metadata updated; original file tags were not changed."
                            : "Some Tracks changed after the query and were left untouched."
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

    private enum MetadataTarget {
        case track(Track)
        case artist(ArtistEntry)
        case album(AlbumEntry)
        case playlist(Playlist)
    }

    private struct PlannedMetadataImport {
        let record: AutomationMetadataDocumentTrack
        let targetTrackID: UUID?
        let patch: LibraryAutomationMetadataPatch?
        let expectedRevision: String?
        let fields: [String]
        var status: String
        var message: String
    }

    private static func musicBrainzReleaseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              components[0].count == 4,
              let year = Int(components[0]), year > 0 else {
            return nil
        }
        var dateComponents = DateComponents(year: year, month: 1, day: 1)
        if components.count >= 2 {
            guard components[1].count == 2,
                  let month = Int(components[1]), (1...12).contains(month) else {
                return nil
            }
            dateComponents.month = month
        }
        if components.count == 3 {
            guard components[2].count == 2,
                  let day = Int(components[2]), (1...31).contains(day) else {
                return nil
            }
            dateComponents.day = day
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: dateComponents) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == dateComponents.year,
              resolved.month == dateComponents.month,
              resolved.day == dateComponents.day else {
            return nil
        }
        return date
    }

    private func metadataImportFields(
        _ values: [String: AutomationJSONValue],
        currentTrack: Track,
        overwriteExistingFields: Bool
    ) -> [String: AutomationJSONValue] {
        guard !overwriteExistingFields else { return values }
        var result: [String: AutomationJSONValue] = [:]
        for (key, value) in values {
            guard value != .null else { continue }
            let existingValueIsEmpty: Bool
            switch key {
            case "title": existingValueIsEmpty = currentTrack.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "artist": existingValueIsEmpty = currentTrack.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "album": existingValueIsEmpty = currentTrack.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "albumArtist": existingValueIsEmpty = currentTrack.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            case "description": existingValueIsEmpty = currentTrack.userDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "genreTags": existingValueIsEmpty = currentTrack.genreTags.isEmpty
            case "language": existingValueIsEmpty = currentTrack.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "labelOrCompany": existingValueIsEmpty = currentTrack.labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "releaseDate": existingValueIsEmpty = currentTrack.releaseDate == nil
            case "qqMusicSongMid": existingValueIsEmpty = currentTrack.qqMusicSongMid?.isEmpty ?? true
            case "metadataSource": existingValueIsEmpty = currentTrack.metadataSource?.isEmpty ?? true
            case "metadataFetchedAt": existingValueIsEmpty = currentTrack.metadataFetchedAt == nil
            case "metadataConfidence": existingValueIsEmpty = currentTrack.metadataConfidence == nil
            case "musicBrainzReleaseID": existingValueIsEmpty = currentTrack.musicBrainzReleaseID?.isEmpty ?? true
            case "lyricsTimeOffsetMs": existingValueIsEmpty = currentTrack.lyricsTimeOffsetMs == 0
            case "artistCredits": existingValueIsEmpty = currentTrack.artistCredits.isEmpty
            default: existingValueIsEmpty = false
            }
            if existingValueIsEmpty { result[key] = value }
        }
        return result
    }

    private func makeMetadataPatch(
        _ values: [String: AutomationJSONValue]
    ) throws -> LibraryAutomationMetadataPatch {
        let allowed: Set<String> = [
            "title", "artist", "album", "albumArtist", "description",
            "genreTags", "language", "labelOrCompany", "releaseDate",
            "qqMusicSongMid", "metadataSource", "metadataFetchedAt",
            "metadataConfidence", "musicBrainzReleaseID", "lyricsTimeOffsetMs",
            "artistCredits"
        ]
        guard Set(values.keys).isSubset(of: allowed) else {
            throw AutomationParameterError.invalidValue("patch")
        }
        func stringValue(_ key: String) throws -> String? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null: return nil
            case .string(let string): return string
            default:
                throw AutomationParameterError.invalidType(key, expected: "string or null")
            }
        }
        func stringArrayValue(_ key: String) throws -> [String]? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null:
                return nil
            case .array(let array):
                let strings = try array.map { value -> String in
                    guard case .string(let string) = value else {
                        throw AutomationParameterError.invalidType(key, expected: "array of strings")
                    }
                    return string
                }
                return strings
            default:
                throw AutomationParameterError.invalidType(key, expected: "array of strings or null")
            }
        }
        func dateValue(_ key: String) throws -> Date? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null:
                return nil
            case .string(let string):
                guard let date = ISO8601DateFormatter().date(from: string) else {
                    throw AutomationParameterError.invalidValue(key)
                }
                return date
            default:
                throw AutomationParameterError.invalidType(key, expected: "ISO-8601 string or null")
            }
        }
        func numberValue(
            _ key: String,
            range: ClosedRange<Double>? = nil
        ) throws -> Double? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null:
                return nil
            case .number(let number):
                guard number.isFinite, range?.contains(number) ?? true else {
                    throw AutomationParameterError.outOfRange(key)
                }
                return number
            default:
                throw AutomationParameterError.invalidType(key, expected: "number or null")
            }
        }
        func artistCreditsValue(_ key: String) throws -> [TrackCredit]? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null:
                return nil
            case .array(let array):
                guard array.count <= 500 else {
                    throw AutomationParameterError.outOfRange(key)
                }
                return try array.map { value in
                    guard case .object(let object) = value else {
                        throw AutomationParameterError.invalidType(key, expected: "array of credit objects")
                    }
                    guard case .string(let displayName)? = object["displayName"],
                          !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AutomationParameterError.invalidValue("\(key).displayName")
                    }
                    let id: UUID
                    if let rawID = object["id"] {
                        guard case .string(let stringID) = rawID,
                              let parsedID = UUID(uuidString: stringID) else {
                            throw AutomationParameterError.invalidValue("\(key).id")
                        }
                        id = parsedID
                    } else {
                        id = UUID()
                    }
                    let canonicalName: String?
                    if let value = object["canonicalName"] {
                        switch value {
                        case .null:
                            canonicalName = nil
                        case .string(let string):
                            canonicalName = string
                        default:
                            throw AutomationParameterError.invalidType(
                                "\(key).canonicalName",
                                expected: "string or null"
                            )
                        }
                    } else {
                        canonicalName = nil
                    }
                    let role: TrackCreditRole
                    if let value = object["role"] {
                        guard case .string(let rawRole) = value,
                              let parsedRole = TrackCreditRole(rawValue: rawRole) else {
                            throw AutomationParameterError.invalidValue("\(key).role")
                        }
                        role = parsedRole
                    } else {
                        role = .primary
                    }
                    return TrackCredit(
                        id: id,
                        displayName: displayName,
                        role: role,
                        canonicalName: canonicalName
                    )
                }
            default:
                throw AutomationParameterError.invalidType(key, expected: "array of credit objects or null")
            }
        }
        return LibraryAutomationMetadataPatch(
            fields: Set(values.keys),
            title: try stringValue("title"),
            artist: try stringValue("artist"),
            album: try stringValue("album"),
            albumArtist: try stringValue("albumArtist"),
            userDescription: try stringValue("description"),
            genreTags: try stringArrayValue("genreTags"),
            language: try stringValue("language"),
            labelOrCompany: try stringValue("labelOrCompany"),
            releaseDate: try dateValue("releaseDate"),
            qqMusicSongMid: try stringValue("qqMusicSongMid"),
            metadataSource: try stringValue("metadataSource"),
            metadataFetchedAt: try dateValue("metadataFetchedAt"),
            metadataConfidence: try numberValue("metadataConfidence", range: 0...1),
            musicBrainzReleaseID: try stringValue("musicBrainzReleaseID"),
            lyricsTimeOffsetMs: try numberValue("lyricsTimeOffsetMs", range: -120_000...120_000),
            artistCredits: try artistCreditsValue("artistCredits")
        )
    }

    private func patchStringValue(
        _ values: [String: AutomationJSONValue],
        key: String
    ) throws -> String? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null: return nil
        case .string(let string): return string
        default: throw AutomationParameterError.invalidType(key, expected: "string or null")
        }
    }

    private func patchStringArrayValue(
        _ values: [String: AutomationJSONValue],
        key: String
    ) throws -> [String]? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null:
            return nil
        case .array(let values):
            return try values.map { value in
                guard case .string(let string) = value else {
                    throw AutomationParameterError.invalidType(key, expected: "array of strings or null")
                }
                return string
            }
        default:
            throw AutomationParameterError.invalidType(key, expected: "array of strings or null")
        }
    }

    private func patchDateValue(
        _ values: [String: AutomationJSONValue],
        key: String
    ) throws -> Date? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null:
            return nil
        case .string(let string):
            guard let date = ISO8601DateFormatter().date(from: string) else {
                throw AutomationParameterError.invalidValue(key)
            }
            return date
        default:
            throw AutomationParameterError.invalidType(key, expected: "ISO-8601 string or null")
        }
    }

    private func patchIntValue(
        _ values: [String: AutomationJSONValue],
        key: String,
        range: ClosedRange<Int>? = nil
    ) throws -> Int? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null:
            return nil
        case .number(let number):
            guard number.isFinite, number.rounded() == number else {
                throw AutomationParameterError.invalidValue(key)
            }
            let integer = Int(number)
            guard range?.contains(integer) ?? true else {
                throw AutomationParameterError.outOfRange(key)
            }
            return integer
        default:
            throw AutomationParameterError.invalidType(key, expected: "integer or null")
        }
    }

    private func patchConfidenceValue(
        _ values: [String: AutomationJSONValue],
        key: String
    ) throws -> Double? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null:
            return nil
        case .number(let number):
            guard number.isFinite, (0...1).contains(number) else {
                throw AutomationParameterError.outOfRange(key)
            }
            return number
        default:
            throw AutomationParameterError.invalidType(key, expected: "number or null")
        }
    }

    private func makeArtistMetadataPatch(
        _ values: [String: AutomationJSONValue]
    ) throws -> LibraryAutomationArtistMetadataPatch {
        let allowed: Set<String> = [
            "displayName", "description", "genreTags", "region", "foreignName",
            "qqMusicSingerMid", "metadataSource", "metadataFetchedAt", "metadataConfidence"
        ]
        guard Set(values.keys).isSubset(of: allowed), !values.isEmpty else {
            throw AutomationParameterError.invalidValue("patch")
        }
        return LibraryAutomationArtistMetadataPatch(
            fields: Set(values.keys),
            displayName: try patchStringValue(values, key: "displayName"),
            description: try patchStringValue(values, key: "description"),
            genreTags: try patchStringArrayValue(values, key: "genreTags"),
            region: try patchStringValue(values, key: "region"),
            foreignName: try patchStringValue(values, key: "foreignName"),
            qqMusicSingerMid: try patchStringValue(values, key: "qqMusicSingerMid"),
            metadataSource: try patchStringValue(values, key: "metadataSource"),
            metadataFetchedAt: try patchDateValue(values, key: "metadataFetchedAt"),
            metadataConfidence: try patchConfidenceValue(values, key: "metadataConfidence")
        )
    }

    private func makeAlbumMetadataPatch(
        _ values: [String: AutomationJSONValue]
    ) throws -> LibraryAutomationAlbumMetadataPatch {
        let allowed: Set<String> = [
            "displayTitle", "description", "year", "releaseYear", "releaseDate", "albumType",
            "genreTags", "language", "labelOrCompany", "qqMusicAlbumMid", "metadataSource",
            "metadataFetchedAt", "metadataConfidence"
        ]
        guard Set(values.keys).isSubset(of: allowed), !values.isEmpty else {
            throw AutomationParameterError.invalidValue("patch")
        }
        return LibraryAutomationAlbumMetadataPatch(
            fields: Set(values.keys),
            displayTitle: try patchStringValue(values, key: "displayTitle"),
            description: try patchStringValue(values, key: "description"),
            year: try patchIntValue(values, key: "year", range: 0...9999),
            releaseYear: try patchIntValue(values, key: "releaseYear", range: 0...9999),
            releaseDate: try patchDateValue(values, key: "releaseDate"),
            albumType: try patchStringValue(values, key: "albumType"),
            genreTags: try patchStringArrayValue(values, key: "genreTags"),
            language: try patchStringValue(values, key: "language"),
            labelOrCompany: try patchStringValue(values, key: "labelOrCompany"),
            qqMusicAlbumMid: try patchStringValue(values, key: "qqMusicAlbumMid"),
            metadataSource: try patchStringValue(values, key: "metadataSource"),
            metadataFetchedAt: try patchDateValue(values, key: "metadataFetchedAt"),
            metadataConfidence: try patchConfidenceValue(values, key: "metadataConfidence")
        )
    }

    private func artistMetadataPatchChanges(
        _ entry: ArtistEntry,
        patch: LibraryAutomationArtistMetadataPatch
    ) -> Bool {
        if patch.fields.contains("displayName"),
           let value = patch.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           entry.displayName != value {
            return true
        }
        if patch.fields.contains("description"), entry.description != (patch.description ?? "") { return true }
        if patch.fields.contains("genreTags"), entry.genreTags != (patch.genreTags ?? []) { return true }
        if patch.fields.contains("region"), entry.region != (patch.region ?? "") { return true }
        if patch.fields.contains("foreignName"), entry.foreignName != (patch.foreignName ?? "") { return true }
        if patch.fields.contains("qqMusicSingerMid"), entry.qqMusicSingerMid != patch.qqMusicSingerMid { return true }
        if patch.fields.contains("metadataSource"), entry.metadataSource != patch.metadataSource { return true }
        if patch.fields.contains("metadataFetchedAt"), entry.metadataFetchedAt != patch.metadataFetchedAt { return true }
        if patch.fields.contains("metadataConfidence"), entry.metadataConfidence != patch.metadataConfidence { return true }
        return false
    }

    private func albumMetadataPatchChanges(
        _ entry: AlbumEntry,
        patch: LibraryAutomationAlbumMetadataPatch
    ) -> Bool {
        if patch.fields.contains("displayTitle"),
           let value = patch.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           entry.displayTitle != value {
            return true
        }
        if patch.fields.contains("description"), entry.description != (patch.description ?? "") { return true }
        if patch.fields.contains("year"), entry.year != patch.year { return true }
        if patch.fields.contains("releaseYear"), entry.releaseYear != patch.releaseYear { return true }
        if patch.fields.contains("releaseDate"), entry.releaseDate != patch.releaseDate { return true }
        if patch.fields.contains("albumType"), entry.albumType != (patch.albumType ?? "") { return true }
        if patch.fields.contains("genreTags"), entry.genreTags != (patch.genreTags ?? []) { return true }
        if patch.fields.contains("language"), entry.language != (patch.language ?? "") { return true }
        if patch.fields.contains("labelOrCompany"), entry.labelOrCompany != (patch.labelOrCompany ?? "") { return true }
        if patch.fields.contains("qqMusicAlbumMid"), entry.qqMusicAlbumMid != patch.qqMusicAlbumMid { return true }
        if patch.fields.contains("metadataSource"), entry.metadataSource != patch.metadataSource { return true }
        if patch.fields.contains("metadataFetchedAt"), entry.metadataFetchedAt != patch.metadataFetchedAt { return true }
        if patch.fields.contains("metadataConfidence"), entry.metadataConfidence != patch.metadataConfidence { return true }
        return false
    }

    private func makePlaylistMetadataPatchValues(
        _ values: [String: AutomationJSONValue]
    ) throws -> (fields: Set<String>, name: String?, description: String?) {
        let allowed: Set<String> = ["name", "description"]
        guard !values.isEmpty, Set(values.keys).isSubset(of: allowed) else {
            throw AutomationParameterError.invalidValue("patch")
        }
        let name: String?
        if values["name"] != nil {
            switch values["name"] {
            case .null:
                name = nil
            case .string(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 255 else {
                    throw AutomationParameterError.outOfRange("patch.name")
                }
                name = trimmed
            default:
                throw AutomationParameterError.invalidType("patch.name", expected: "string or null")
            }
        } else {
            name = nil
        }

        let description: String?
        if values["description"] != nil {
            switch values["description"] {
            case .null:
                description = ""
            case .string(let value):
                description = value
            default:
                throw AutomationParameterError.invalidType("patch.description", expected: "string or null")
            }
        } else {
            description = nil
        }
        return (Set(values.keys), name, description)
    }

    private func applyMetadataToSingleTarget(
        parameters: AutomationParameters,
        request: AutomationRequest,
        session: LibrarySession
    ) async throws -> AutomationResponse {
        guard let patchValues = try parameters.object("patch"), !patchValues.isEmpty else {
            throw AutomationParameterError.missing("patch")
        }
        let expectedRevision = try parameters.string("expectedRevision")
        guard try parameters.object("expectedRevisions") == nil else {
            throw AutomationParameterError.invalidValue("expectedRevisions")
        }
        let dryRun = try parameters.boolean("dryRun", default: false)
        let target: MetadataTarget
        if let trackID = try parameters.uuid("trackID") {
            guard try !hasMetadataEntityTarget(parameters) else {
                throw AutomationParameterError.invalidValue("metadata target")
            }
            guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                throw AutomationParameterError.missingResource("trackID")
            }
            target = .track(track)
        } else {
            target = try resolveMetadataTarget(
                artistID: try parameters.uuid("artistID"),
                albumKey: try parameters.string("albumKey")?.trimmingCharacters(in: .whitespacesAndNewlines),
                playlistID: try parameters.uuid("playlistID"),
                session: session
            )
        }

        switch target {
        case .track(let track):
            let patch = try makeMetadataPatch(patchValues)
            let conflict = expectedRevision != nil && expectedRevision != session.libraryViewModel.automationTrackRevision(for: track)
            let changed = !conflict && metadataPatchChanges(track, patch: patch)
            if dryRun {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: true,
                        updatedTrackIDs: changed ? [track.id] : [],
                        skippedTrackIDs: !changed && !conflict ? [track.id] : [],
                        conflictedTrackIDs: conflict ? [track.id] : [],
                        message: "Preview only. This updates App-owned metadata and never writes embedded file tags."
                    ),
                    for: request
                )
            }
            let outcome = try await session.libraryViewModel.applyMetadataPatchForAutomation(
                trackIDs: [track.id],
                patch: patch,
                expectedRevisions: expectedRevision.map { [track.id: $0] } ?? [:]
            )
            return AutomationResponseSupport.encodeResult(
                AutomationMetadataMutationResult(
                    applied: !outcome.updatedTrackIDs.isEmpty,
                    dryRun: false,
                    updatedTrackIDs: outcome.updatedTrackIDs,
                    skippedTrackIDs: outcome.skippedTrackIDs,
                    conflictedTrackIDs: outcome.conflictedTrackIDs,
                    message: "App metadata updated; original file tags were not changed."
                ),
                for: request
            )
        case .artist(let entry):
            let patch = try makeArtistMetadataPatch(patchValues)
            let conflict = expectedRevision != nil && expectedRevision != session.libraryViewModel.automationArtistRevision(for: entry)
            let changed = !conflict && artistMetadataPatchChanges(entry, patch: patch)
            if dryRun {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: true,
                        updatedArtistIDs: changed ? [entry.id] : [],
                        skippedArtistIDs: !changed && !conflict ? [entry.id] : [],
                        conflictedArtistIDs: conflict ? [entry.id] : [],
                        message: "Preview only. Artist metadata is App-owned and sidecar-backed."
                    ),
                    for: request
                )
            }
            let outcome = try await session.libraryViewModel.applyArtistMetadataPatchForAutomation(
                artistID: entry.id,
                patch: patch,
                expectedRevision: expectedRevision
            )
            return AutomationResponseSupport.encodeResult(
                AutomationMetadataMutationResult(
                    applied: !outcome.updatedArtistIDs.isEmpty,
                    dryRun: false,
                    updatedArtistIDs: outcome.updatedArtistIDs,
                    skippedArtistIDs: outcome.skippedArtistIDs,
                    conflictedArtistIDs: outcome.conflictedArtistIDs,
                    message: "Artist metadata updated in the App-owned sidecar."
                ),
                for: request
            )
        case .album(let entry):
            let patch = try makeAlbumMetadataPatch(patchValues)
            let conflict = expectedRevision != nil && expectedRevision != session.libraryViewModel.automationAlbumRevision(for: entry)
            let changed = !conflict && albumMetadataPatchChanges(entry, patch: patch)
            if dryRun {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: true,
                        updatedAlbumIDs: changed ? [entry.id] : [],
                        skippedAlbumIDs: !changed && !conflict ? [entry.id] : [],
                        conflictedAlbumIDs: conflict ? [entry.id] : [],
                        message: "Preview only. Album metadata is App-owned and sidecar-backed."
                    ),
                    for: request
                )
            }
            let outcome = try await session.libraryViewModel.applyAlbumMetadataPatchForAutomation(
                albumID: entry.id,
                patch: patch,
                expectedRevision: expectedRevision
            )
            return AutomationResponseSupport.encodeResult(
                AutomationMetadataMutationResult(
                    applied: !outcome.updatedAlbumIDs.isEmpty,
                    dryRun: false,
                    updatedAlbumIDs: outcome.updatedAlbumIDs,
                    skippedAlbumIDs: outcome.skippedAlbumIDs,
                    conflictedAlbumIDs: outcome.conflictedAlbumIDs,
                    message: "Album metadata updated in the App-owned sidecar."
                ),
                for: request
            )
        case .playlist(let playlist):
            let patch = try makePlaylistMetadataPatchValues(patchValues)
            let desiredName = patch.fields.contains("name") ? (patch.name ?? playlist.name) : playlist.name
            let desiredDescription = patch.fields.contains("description") ? (patch.description ?? playlist.userDescription) : playlist.userDescription
            let conflict = expectedRevision != nil && expectedRevision != session.libraryViewModel.automationPlaylistRevision(for: playlist)
            let changed = !conflict && (desiredName != playlist.name || desiredDescription != playlist.userDescription)
            if dryRun {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: true,
                        updatedPlaylistIDs: changed ? [playlist.id] : [],
                        skippedPlaylistIDs: !changed && !conflict ? [playlist.id] : [],
                        conflictedPlaylistIDs: conflict ? [playlist.id] : [],
                        message: "Preview only. Playlist name and description are App-owned metadata."
                    ),
                    for: request
                )
            }
            guard !conflict else {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: false,
                        conflictedPlaylistIDs: [playlist.id],
                        message: "The Playlist changed after it was queried; nothing was written."
                    ),
                    for: request
                )
            }
            guard changed else {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: false,
                        skippedPlaylistIDs: [playlist.id],
                        message: "Playlist metadata already matches the requested values."
                    ),
                    for: request
                )
            }
            let updated = try await session.libraryViewModel.renamePlaylistForAutomation(
                playlist,
                name: desiredName,
                description: desiredDescription,
                expectedRevision: expectedRevision
            )
            return AutomationResponseSupport.encodeResult(
                AutomationMetadataMutationResult(
                    applied: true,
                    dryRun: false,
                    updatedPlaylistIDs: [updated.id],
                    message: "Playlist metadata updated."
                ),
                for: request
            )
        }
    }

    private func hasMetadataEntityTarget(_ parameters: AutomationParameters) throws -> Bool {
        let artistID = try parameters.uuid("artistID")
        let albumKey = try parameters.string("albumKey")
        let playlistID = try parameters.uuid("playlistID")
        return artistID != nil || albumKey != nil || playlistID != nil
    }

    private func resolveMetadataTarget(
        artistID: UUID?,
        albumKey: String?,
        playlistID: UUID?,
        session: LibrarySession
    ) throws -> MetadataTarget {
        let normalizedAlbumKey = albumKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = [artistID != nil, normalizedAlbumKey != nil, playlistID != nil]
            .filter { $0 }
            .count
        guard count == 1 else {
            throw AutomationParameterError.missing("exactly one of artistID, albumKey or playlistID")
        }
        if let artistID {
            guard let entry = session.libraryViewModel.artistEntries.first(where: { $0.id == artistID }) else {
                throw AutomationParameterError.missingResource("artistID")
            }
            return .artist(entry)
        }
        if let normalizedAlbumKey {
            guard !normalizedAlbumKey.isEmpty else {
                throw AutomationParameterError.invalidValue("albumKey")
            }
            guard let entry = session.libraryViewModel.albumEntries.first(where: {
                $0.canonicalKey == normalizedAlbumKey
            }) else {
                throw AutomationParameterError.missingResource("albumKey")
            }
            return .album(entry)
        }
        guard let playlistID,
              let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
            throw AutomationParameterError.missingResource("playlistID")
        }
        return .playlist(playlist)
    }

    private func makeMetadataGetResult(
        for target: MetadataTarget,
        session: LibrarySession
    ) -> AutomationMetadataGetResult {
        switch target {
        case .track(let track):
            return AutomationMetadataGetResult(
                tracks: [queries.makeTrackSummary(track, playlists: session.libraryViewModel.playlists)],
                total: 1,
                revision: session.libraryViewModel.automationTrackRevision(for: track)
            )
        case .artist(let entry):
            return AutomationMetadataGetResult(
                artists: [makeArtistMetadata(entry, session: session)],
                total: 1,
                revision: session.libraryViewModel.automationArtistRevision(for: entry)
            )
        case .album(let entry):
            return AutomationMetadataGetResult(
                albums: [makeAlbumMetadata(entry, session: session)],
                total: 1,
                revision: session.libraryViewModel.automationAlbumRevision(for: entry)
            )
        case .playlist(let playlist):
            return AutomationMetadataGetResult(
                playlists: [queries.makePlaylistSummary(playlist)],
                total: 1,
                revision: queries.makePlaylistSummary(playlist).revision
            )
        }
    }

    private func makeMetadataCollectionResult(
        entityType: String,
        query: String?,
        offset: Int,
        limit: Int,
        session: LibrarySession
    ) -> AutomationMetadataGetResult {
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = normalizedQuery?.isEmpty == false

        switch entityType {
        case "artist":
            let allEntries = session.libraryViewModel.artistEntries.sorted {
                let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
            let filtered = hasQuery
                ? allEntries.filter { entry in
                    [entry.displayName, entry.canonicalName, entry.description, entry.foreignName]
                        .contains { $0.localizedCaseInsensitiveContains(normalizedQuery!) }
                }
                : allEntries
            let pageStart = min(offset, filtered.count)
            let pageEnd = min(pageStart + limit, filtered.count)
            let page = Array(filtered[pageStart..<pageEnd]).map {
                makeArtistMetadata($0, session: session)
            }
            return AutomationMetadataGetResult(
                artists: page,
                total: filtered.count,
                offset: offset,
                limit: limit,
                nextOffset: pageEnd < filtered.count ? pageEnd : nil,
                revision: metadataCollectionRevision(
                    entityType: entityType,
                    entries: allEntries.map {
                        ($0.id, session.libraryViewModel.automationArtistRevision(for: $0))
                    }
                )
            )

        case "album":
            let allEntries = session.libraryViewModel.albumEntries.sorted {
                let titleOrder = $0.displayTitle.localizedStandardCompare($1.displayTitle)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                if $0.primaryArtistDisplayName != $1.primaryArtistDisplayName {
                    return $0.primaryArtistDisplayName.localizedStandardCompare($1.primaryArtistDisplayName)
                        == .orderedAscending
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            let filtered = hasQuery
                ? allEntries.filter { entry in
                    [
                        entry.displayTitle,
                        entry.canonicalKey,
                        entry.primaryArtistDisplayName,
                        entry.primaryArtistCanonicalName,
                        entry.description
                    ].contains { $0.localizedCaseInsensitiveContains(normalizedQuery!) }
                }
                : allEntries
            let pageStart = min(offset, filtered.count)
            let pageEnd = min(pageStart + limit, filtered.count)
            let page = Array(filtered[pageStart..<pageEnd]).map {
                makeAlbumMetadata($0, session: session)
            }
            return AutomationMetadataGetResult(
                albums: page,
                total: filtered.count,
                offset: offset,
                limit: limit,
                nextOffset: pageEnd < filtered.count ? pageEnd : nil,
                revision: metadataCollectionRevision(
                    entityType: entityType,
                    entries: allEntries.map {
                        ($0.id, session.libraryViewModel.automationAlbumRevision(for: $0))
                    }
                )
            )

        case "playlist":
            let allEntries = session.libraryViewModel.playlists.sorted {
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
            let filtered = hasQuery
                ? allEntries.filter {
                    $0.name.localizedCaseInsensitiveContains(normalizedQuery!)
                        || $0.userDescription.localizedCaseInsensitiveContains(normalizedQuery!)
                }
                : allEntries
            let pageStart = min(offset, filtered.count)
            let pageEnd = min(pageStart + limit, filtered.count)
            let page = Array(filtered[pageStart..<pageEnd]).map(queries.makePlaylistSummary)
            return AutomationMetadataGetResult(
                playlists: page,
                total: filtered.count,
                offset: offset,
                limit: limit,
                nextOffset: pageEnd < filtered.count ? pageEnd : nil,
                revision: metadataCollectionRevision(
                    entityType: entityType,
                    entries: allEntries.map {
                        ($0.id, session.libraryViewModel.automationPlaylistRevision(for: $0))
                    }
                )
            )

        default:
            // The request handler validates this before calling the helper.
            return AutomationMetadataGetResult(total: 0, revision: "v1-invalid")
        }
    }

    private func metadataCollectionRevision(
        entityType: String,
        entries: [(id: UUID, revision: String)]
    ) -> String {
        var fingerprint = entityType
        for entry in entries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            fingerprint.append("\n")
            fingerprint.append(entry.id.uuidString)
            fingerprint.append("\n")
            fingerprint.append(entry.revision)
        }
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "v1-\(digest)"
    }

    private func makeArtistMetadata(
        _ entry: ArtistEntry,
        session: LibrarySession
    ) -> AutomationArtistMetadata {
        AutomationArtistMetadata(
            id: entry.id,
            canonicalName: entry.canonicalName,
            displayName: entry.displayName,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            description: entry.description,
            genreTags: entry.genreTags,
            region: entry.region,
            foreignName: entry.foreignName,
            qqMusicSingerMid: entry.qqMusicSingerMid,
            metadataSource: entry.metadataSource,
            metadataFetchedAt: entry.metadataFetchedAt,
            metadataConfidence: entry.metadataConfidence,
            artworkAvailable: entry.hasArtwork,
            artworkFileName: entry.artworkFileName,
            trackCount: entry.trackCount,
            albumCount: entry.albumCount,
            totalDuration: entry.totalDuration,
            isOrphaned: entry.isOrphaned,
            revision: session.libraryViewModel.automationArtistRevision(for: entry)
        )
    }

    private func makeAlbumMetadata(
        _ entry: AlbumEntry,
        session: LibrarySession
    ) -> AutomationAlbumMetadata {
        AutomationAlbumMetadata(
            id: entry.id,
            canonicalKey: entry.canonicalKey,
            displayTitle: entry.displayTitle,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            primaryArtistCanonicalName: entry.primaryArtistCanonicalName,
            primaryArtistDisplayName: entry.primaryArtistDisplayName,
            description: entry.description,
            year: entry.year,
            releaseYear: entry.releaseYear,
            releaseDate: entry.releaseDate,
            albumType: entry.albumType,
            genreTags: entry.genreTags,
            language: entry.language,
            labelOrCompany: entry.labelOrCompany,
            qqMusicAlbumMid: entry.qqMusicAlbumMid,
            metadataSource: entry.metadataSource,
            metadataFetchedAt: entry.metadataFetchedAt,
            metadataConfidence: entry.metadataConfidence,
            artworkAvailable: entry.hasArtwork,
            artworkFileName: entry.artworkFileName,
            trackCount: entry.trackCount,
            totalDuration: entry.totalDuration,
            isOrphaned: entry.isOrphaned,
            revision: session.libraryViewModel.automationAlbumRevision(for: entry)
        )
    }

    private func metadataPatchChanges(
        _ track: Track,
        patch: LibraryAutomationMetadataPatch
    ) -> Bool {
        if patch.fields.contains("title"), track.title != (patch.title ?? "") { return true }
        if patch.fields.contains("artist"), track.artist != (patch.artist ?? "") { return true }
        if patch.fields.contains("album"), track.album != (patch.album ?? "") { return true }
        if patch.fields.contains("albumArtist"), track.albumArtist != patch.albumArtist { return true }
        if patch.fields.contains("description"), track.userDescription != (patch.userDescription ?? "") { return true }
        if patch.fields.contains("genreTags"), track.genreTags != (patch.genreTags ?? []) { return true }
        if patch.fields.contains("language"), track.language != (patch.language ?? "") { return true }
        if patch.fields.contains("labelOrCompany"), track.labelOrCompany != (patch.labelOrCompany ?? "") { return true }
        if patch.fields.contains("releaseDate"), track.releaseDate != patch.releaseDate { return true }
        if patch.fields.contains("qqMusicSongMid"), track.qqMusicSongMid != patch.qqMusicSongMid { return true }
        if patch.fields.contains("metadataSource"), track.metadataSource != patch.metadataSource { return true }
        if patch.fields.contains("metadataFetchedAt"), track.metadataFetchedAt != patch.metadataFetchedAt { return true }
        if patch.fields.contains("metadataConfidence"), track.metadataConfidence != patch.metadataConfidence { return true }
        if patch.fields.contains("musicBrainzReleaseID"), track.musicBrainzReleaseID != patch.musicBrainzReleaseID { return true }
        if patch.fields.contains("lyricsTimeOffsetMs"), track.lyricsTimeOffsetMs != (patch.lyricsTimeOffsetMs ?? 0) { return true }
        if patch.fields.contains("artistCredits") {
            if let artistCredits = patch.artistCredits {
                if track.artistCredits != artistCredits { return true }
            } else if track.artistCreditsData != nil {
                return true
            }
        }
        return false
    }

    private func readEmbeddedTags(from url: URL) async -> (
        values: [String: String], supportedForWrite: Bool, status: String, message: String?
    ) {
        if url.pathExtension.lowercased() == "mp3" {
            do {
                let values = embeddedTagValues(try MP3EmbeddedTagService.read(from: url))
                return (
                    values,
                    true,
                    values.isEmpty ? "empty" : "read",
                    values.isEmpty ? "No supported ID3 values were found." : nil
                )
            } catch {
                return ([:], false, "unsupported", MP3EmbeddedTagService.publicMessage(for: error))
            }
        }
        let extracted = await ImportMetadataExtractor.extractMetadata(from: url)
        var values: [String: String] = [:]
        if let value = extracted.tagFields.title { values["title"] = value }
        if let value = extracted.tagFields.artist { values["artist"] = value }
        if let value = extracted.tagFields.album { values["album"] = value }
        if let value = extracted.tagFields.albumArtist { values["albumArtist"] = value }
        if let value = extracted.tagFields.releaseYear { values["year"] = String(value) }
        return (
            values,
            false,
            values.isEmpty ? "empty" : "read",
            "Tags can be read through AVFoundation, but embedded-tag writes are currently supported only for MP3."
        )
    }

    private func embeddedTagValues(_ tags: MP3EmbeddedTagService.TagValues) -> [String: String] {
        var values: [String: String] = [:]
        for field in MP3EmbeddedTagService.supportedFields.subtracting(["comment", "lyrics"]) {
            if let value = tags[field] {
                values[field] = String(value.prefix(16_384))
            }
        }
        return values
    }

    private func metadataProviderUnavailable(
        _ error: Error,
        provider: String,
        for request: AutomationRequest
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .serverUnavailable,
                message: "The \(provider) metadata provider could not complete the request.",
                retryable: true,
                details: .object(["reason": .string(error.localizedDescription)])
            )
        )
    }
}
