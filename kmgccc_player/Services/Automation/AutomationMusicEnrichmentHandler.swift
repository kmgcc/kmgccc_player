import CryptoKit
import Foundation
import PlayerAutomationProtocol

/// Automation uses the same library service as the editor and idle worker.
/// Candidate IDs never carry caller supplied media URLs into the downloader.
@MainActor
final class AutomationMusicEnrichmentHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }
    private var candidates: [String: Candidate] = [:]

    private struct Target {
        var query: MusicEnrichmentQuery
        var trackID: UUID?
    }
    private struct Candidate {
        var libraryID: UUID
        var target: Target
        var result: MusicEnrichmentResult
        var revision: String
        var expires: Date
    }

    init(appSession: AppSessionHost?) { self.appSession = appSession }

    func handle(_ request: AutomationRequest, grantedScopes: Set<AutomationScope>) async -> AutomationResponse {
        guard let session = sessionAccess.activeSession(for: request) else {
            return sessionAccess.noActiveLibraryResponse(for: request)
        }
        do {
            let parameters = try AutomationParameters(request)
            let service = session.cacheServices.musicEnrichmentService
            switch request.method {
            case AutomationMethod.enrichmentList:
                let offset = try parameters.integer("offset", default: 0)
                let limit = try parameters.integer("limit", default: 20)
                guard offset >= 0, (1...100).contains(limit) else { throw AutomationParameterError.outOfRange("offset/limit") }
                let page = try await service.listRecords(offset: offset, limit: limit)
                try requireActive(session, request: request)
                let entries: [AutomationJSONValue] = page.records.map { record in
                    .object([
                        "key": .string(record.query.key), "title": .string(record.query.title),
                        "artist": .string(record.query.artist), "album": .string(record.query.album),
                        "updatedAt": .string(ISO8601DateFormatter().string(from: record.updatedAt)),
                        "providers": .array(record.results.map { .string($0.source) }),
                        "motionKinds": .array(record.assets.map { .string($0.kind) }),
                        "isUserSelected": .boolean(record.manualMotionSelection != nil)
                    ])
                }
                return .success(for: request, result: .object([
                    "records": .array(entries), "offset": .number(Double(offset)),
                    "nextOffset": page.nextOffset.map { .number(Double($0)) } ?? .null
                ]))
            case AutomationMethod.completionStatus, AutomationMethod.completionControl:
                return try completion(request, parameters: parameters, session: session)

            case AutomationMethod.motionArtworkApply:
                candidates = candidates.filter { $0.value.expires > Date() }
                let id = try parameters.string("candidateID", required: true)!
                guard let candidate = candidates[id], candidate.libraryID == session.context.id else {
                    throw AutomationParameterError.missingResource("candidateID")
                }
                let target = try await resolve(candidate.target, session: session)
                let revision = try await revision(for: target, service: service)
                let expected = try parameters.string("expectedRevision") ?? candidate.revision
                guard revision == expected, revision == candidate.revision else {
                    return AutomationResponseSupport.trackRevisionConflict(for: request, expected: expected, actual: revision)
                }
                if try parameters.boolean("dryRun", default: false) {
                    return .success(for: request, result: .object([
                        "dryRun": .boolean(true), "key": .string(target.query.key),
                        "revision": .string(revision), "candidate": try json(candidate.result)
                    ]))
                }
                let snapshot = try await service.selectMotion(candidate.result, for: target.query)
                try requireActive(session, request: request)
                return .success(for: request, result: .object(try await payload(snapshot: snapshot, target: target, session: session)))

            case AutomationMethod.enrichmentGet, AutomationMethod.motionArtworkGet:
                let includeLyrics = try parameters.boolean("includeLyrics", default: false)
                let includePaths = try parameters.boolean("includeFilePaths", default: false)
                let includeRaw = try parameters.boolean("includeRaw", default: false)
                if includeLyrics, !grantedScopes.contains(.lyricsRead) { return denied(.lyricsRead, request: request) }
                if includeRaw, !grantedScopes.contains(.lyricsRead) { return denied(.lyricsRead, request: request) }
                if includePaths, !grantedScopes.contains(.filesRead) { return denied(.filesRead, request: request) }
                let target = try await resolve(parameters, session: session)
                let snapshot = try await service.loadSnapshot(for: target.query)
                try requireActive(session, request: request)
                var result = try await payload(snapshot: snapshot, target: target, session: session, includePaths: includePaths)
                if request.method == AutomationMethod.enrichmentGet, var record = snapshot?.record {
                    if let provider = try parameters.string("provider") {
                        record.results = record.results.filter { $0.source == provider }
                    }
                    for index in record.results.indices {
                        if !includeLyrics {
                            record.results[index].lyricsTTML = nil
                            record.results[index].lyricsLocalizations = nil
                        }
                        if !includeRaw { record.results[index].resources = nil }
                    }
                    if var selection = record.manualMotionSelection {
                        if !includeLyrics { selection.lyricsTTML = nil; selection.lyricsLocalizations = nil }
                        if !includeRaw { selection.resources = nil }
                        record.manualMotionSelection = selection
                    }
                    if !includePaths {
                        record.assets = []
                        record.query.storedMotionArtwork = nil
                    }
                    result["record"] = try json(record)
                    result["attributes"] = try json(snapshot?.attributes ?? [:])
                    result["attributeSources"] = try json(snapshot?.record.attributeSources ?? [:])
                }
                let presentation = session.playbackCoordinator.presentation
                if presentation.musicEnrichment?.record.query.key == target.query.key || presentation.externalStableKey == target.query.key {
                    result["adoptedSources"] = try json(presentation.metadataSources)
                    result["currentDisplay"] = .object([
                        "title": .string(presentation.title), "artist": .string(presentation.artist),
                        "album": .string(presentation.album ?? "")
                    ])
                }
                return .success(for: request, result: .object(result))

            case AutomationMethod.enrichmentPatch:
                let target = try await resolve(parameters, session: session)
                let revision = try await revision(for: target, service: service)
                if let expected = try parameters.string("expectedRevision"), expected != revision {
                    return AutomationResponseSupport.trackRevisionConflict(for: request, expected: expected, actual: revision)
                }
                let fields = try parameters.object("fields") ?? [:]
                var clearFields: [String] = []
                if let value = parameters.values["clearFields"] {
                    guard case .array(let values) = value else { throw AutomationParameterError.invalidValue("clearFields") }
                    for value in values {
                        guard case .string(let key) = value, !key.isEmpty else { throw AutomationParameterError.invalidValue("clearFields") }
                        clearFields.append(key)
                    }
                }
                guard !fields.isEmpty || !clearFields.isEmpty,
                      fields.count + clearFields.count <= 200,
                      fields.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw AutomationParameterError.invalidValue("fields/clearFields")
                }
                if try parameters.boolean("dryRun", default: false) {
                    return .success(for: request, result: .object([
                        "dryRun": .boolean(true), "key": .string(target.query.key), "revision": .string(revision),
                        "fields": .object(fields), "clearFields": .array(clearFields.map(AutomationJSONValue.string))
                    ]))
                }
                let overrides = try JSONDecoder().decode([String: MusicMetadataValue].self, from: JSONEncoder().encode(fields))
                let snapshot = try await service.patchAttributes(fields: overrides, clearFields: clearFields, for: target.query)
                try requireActive(session, request: request)
                var result = try await payload(snapshot: snapshot, target: target, session: session)
                result["attributes"] = try json(snapshot.attributes)
                return .success(for: request, result: .object(result))

            case AutomationMethod.enrichmentRefresh:
                let target = try await resolve(parameters, session: session)
                if try parameters.boolean("dryRun", default: false) {
                    return .success(for: request, result: .object(["dryRun": .boolean(true), "query": try json(target.query)]))
                }
                let snapshot = try await service.completeIndependently(
                    query: target.query,
                    force: try parameters.boolean("force", default: false),
                    includeMotion: try parameters.boolean("includeMotion", default: true)
                )
                try requireActive(session, request: request)
                return .success(for: request, result: .object(try await payload(snapshot: snapshot, target: target, session: session)))

            case AutomationMethod.motionArtworkImport:
                let target = try await resolve(parameters, session: session)
                let revision = try await revision(for: target, service: service)
                if let expected = try parameters.string("expectedRevision"), expected != revision {
                    return AutomationResponseSupport.trackRevisionConflict(for: request, expected: expected, actual: revision)
                }
                let path = try parameters.string("filePath", required: true)!
                guard path.hasPrefix("/") else { throw AutomationParameterError.invalidValue("filePath") }
                let url = URL(fileURLWithPath: path)
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if try parameters.boolean("dryRun", default: false) {
                    let video = try await service.validateMotionVideo(from: url)
                    try requireActive(session, request: request)
                    return .success(for: request, result: .object([
                        "dryRun": .boolean(true), "key": .string(target.query.key), "revision": .string(revision),
                        "duration": .number(video.duration), "width": .number(Double(video.width)),
                        "height": .number(Double(video.height))
                    ]))
                }
                let snapshot = try await service.importMotionVideo(from: url, for: target.query)
                try requireActive(session, request: request)
                return .success(for: request, result: .object(try await payload(snapshot: snapshot, target: target, session: session)))

            case AutomationMethod.motionArtworkSearch:
                let target = try await resolve(parameters, session: session)
                var query = target.query
                if let value = try parameters.string("title") { query.title = value }
                if let value = try parameters.string("artist") { query.artist = value }
                if let value = try parameters.string("album") { query.album = value }
                let limit = try parameters.integer("limit", default: 6)
                guard (1...6).contains(limit), !query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AutomationParameterError.invalidValue("title/limit")
                }
                // Text edits are a deliberate manual search, not an exact-ID lookup.
                if query.title != target.query.title || query.artist != target.query.artist || query.album != target.query.album {
                    query.appleSongID = nil; query.appleAlbumID = nil; query.isrc = nil
                }
                let revision = try await revision(for: target, service: service)
                let found = try await service.searchMotionCandidates(query: query)
                try requireActive(session, request: request)
                candidates = candidates.filter { $0.value.expires > Date() }
                if candidates.count > 64 { candidates.removeAll() }
                var values: [AutomationJSONValue] = []
                for original in found.prefix(limit) {
                    let result = motionCandidate(original)
                    let id = UUID().uuidString
                    candidates[id] = Candidate(libraryID: session.context.id, target: target, result: result, revision: revision, expires: Date().addingTimeInterval(600))
                    values.append(.object(["candidateID": .string(id), "candidate": try json(result)]))
                }
                return .success(for: request, result: .object([
                    "key": .string(target.query.key), "revision": .string(revision), "candidates": .array(values)
                ]))

            case AutomationMethod.motionArtworkClear:
                let target = try await resolve(parameters, session: session)
                let revision = try await revision(for: target, service: service)
                if let expected = try parameters.string("expectedRevision"), expected != revision {
                    return AutomationResponseSupport.trackRevisionConflict(for: request, expected: expected, actual: revision)
                }
                if try parameters.boolean("dryRun", default: false) {
                    return .success(for: request, result: .object(["dryRun": .boolean(true), "key": .string(target.query.key), "revision": .string(revision)]))
                }
                let snapshot = try await service.clearMotion(for: target.query, resumeAutomatic: try parameters.boolean("resumeAutomatic", default: false))
                try requireActive(session, request: request)
                return .success(for: request, result: .object(try await payload(snapshot: snapshot, target: target, session: session)))

            default: return AutomationResponseSupport.unsupportedMethod(for: request)
            }
        } catch let error as MotionVideoImportError {
            return .failure(for: request, error: AutomationError(code: .invalidRequest, message: error.localizedDescription))
        } catch let error as AutomationParameterError {
            return AutomationResponseSupport.invalidParameters(for: request, error: error)
        } catch {
            return .failure(for: request, error: AutomationError(
                code: error is CancellationError ? .conflict : .internalError,
                message: error is CancellationError ? "The Library or target changed; retry against the active Library." : "Music enrichment could not complete. See the App's MusicEnrichment log for provider results.",
                retryable: true
            ))
        }
    }

    private func resolve(_ parameters: AutomationParameters, session: LibrarySession) async throws -> Target {
        let trackID = try parameters.uuid("trackID")
        let key = try parameters.string("externalKey")
        guard trackID == nil || key == nil else { throw AutomationParameterError.invalidValue("trackID/externalKey") }
        if let trackID { return try localTarget(trackID, session: session) }
        if let key {
            guard !key.isEmpty, !key.hasPrefix("track:") else { throw AutomationParameterError.invalidValue("externalKey") }
            if let saved = try await session.cacheServices.musicEnrichmentService.loadSnapshot(for: key) {
                return Target(query: saved.record.query, trackID: nil)
            }
            guard session.playbackCoordinator.presentation.externalStableKey == key else {
                throw AutomationParameterError.missingResource("externalKey")
            }
        }
        let presentation = session.playbackCoordinator.presentation
        if let track = presentation.localTrack, presentation.source == .local { return try localTarget(track.id, session: session) }
        guard presentation.hasTrack, let key = presentation.externalStableKey else {
            throw AutomationParameterError.missing("trackID or externalKey or current playback")
        }
        return Target(query: presentation.musicEnrichment?.record.query ?? MusicEnrichmentQuery(
            key: key, title: presentation.externalRawTitle ?? presentation.title,
            artist: presentation.externalRawArtist ?? presentation.artist,
            album: presentation.externalRawAlbum ?? presentation.album ?? "", duration: presentation.duration,
            seedAttributes: presentation.externalMusicAttributes
        ), trackID: nil)
    }

    private func localTarget(_ id: UUID, session: LibrarySession) throws -> Target {
        guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == id }) else {
            throw AutomationParameterError.missingResource("trackID")
        }
        return Target(query: MusicEnrichmentQuery(
            key: "track:\(id.uuidString)", title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, storedMotionArtwork: track.motionArtwork,
            albumArtist: track.albumArtist
        ), trackID: id)
    }

    private func resolve(_ target: Target, session: LibrarySession) async throws -> Target {
        if let id = target.trackID { return try localTarget(id, session: session) }
        if let record = try await session.cacheServices.musicEnrichmentService.loadSnapshot(for: target.query.key)?.record {
            return Target(query: record.query, trackID: nil)
        }
        return target
    }

    private func revision(for target: Target, service: MusicEnrichmentService) async throws -> String {
        let record = try await service.loadSnapshot(for: target.query)?.record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(target.query)
        let stamp = record.map { String($0.updatedAt.timeIntervalSince1970) } ?? "none"
        return SHA256.hash(data: data + Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func payload(snapshot: MusicEnrichmentSnapshot?, target: Target, session: LibrarySession, includePaths: Bool = false) async throws -> [String: AutomationJSONValue] {
        var assets: [AutomationJSONValue] = []
        for asset in snapshot?.record.assets ?? target.query.storedMotionArtwork?.assets ?? [] {
            let isLibraryRelative = asset.relativePath.hasPrefix("Tracks/") || asset.relativePath.hasPrefix("Enrichment/")
            let base = isLibraryRelative ? session.context.paths.rootURL : session.context.paths.musicEnrichmentRootURL
            let url = base.appendingPathComponent(asset.relativePath)
            var item: [String: AutomationJSONValue] = [
                "kind": .string(asset.kind), "sourceURL": .string(asset.sourceURL),
                "available": .boolean(FileManager.default.fileExists(atPath: url.path)),
                "startTime": .number(asset.startTime), "duration": .number(asset.duration)
            ]
            if let width = asset.width { item["width"] = .number(Double(width)) }
            if let height = asset.height { item["height"] = .number(Double(height)) }
            if includePaths { item["filePath"] = .string(url.path) }
            assets.append(.object(item))
        }
        let manual = snapshot?.record.manualMotionSelection != nil || target.query.storedMotionArtwork?.isUserSelected == true
        let albumIdentity = snapshot?.record.albumMotionIdentity ?? target.query.storedMotionArtwork?.albumIdentity
        return [
            "key": .string(target.query.key), "found": .boolean(snapshot != nil),
            "revision": .string(try await revision(for: target, service: session.cacheServices.musicEnrichmentService)),
            "assets": .array(assets),
            "isUserSelected": .boolean(manual),
            "scope": .string(manual ? "trackOverride" : (albumIdentity == nil ? "none" : "album")),
            "albumIdentity": albumIdentity.map(AutomationJSONValue.string) ?? .null,
            "providers": .array((snapshot?.record.results ?? []).map { .string($0.source) })
        ]
    }

    private func json<T: Encodable>(_ value: T) throws -> AutomationJSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(AutomationJSONValue.self, from: encoder.encode(value))
    }

    private func motionCandidate(_ original: MusicEnrichmentResult) -> MusicEnrichmentResult {
        var result = original
        result.resources = nil
        result.lyricsTTML = nil
        result.lyricsLocalizations = nil
        let allowed: Set<String> = ["name", "artistName", "albumName", "releaseDate", "artwork", "url"]
        result.attributes = result.attributes?.filter { allowed.contains($0.key) }
        return result
    }

    private func requireActive(_ session: LibrarySession, request: AutomationRequest) throws {
        guard sessionAccess.activeSession(for: request) === session, !Task.isCancelled else { throw CancellationError() }
    }

    private func denied(_ scope: AutomationScope, request: AutomationRequest) -> AutomationResponse {
        .failure(for: request, error: AutomationError(code: .permissionDenied, message: "This projection requires \(scope.rawValue)."))
    }

    private func completion(_ request: AutomationRequest, parameters: AutomationParameters, session: LibrarySession) throws -> AutomationResponse {
        guard let source = session.cacheServices.metadataCompletionSource else {
            throw AutomationParameterError.missingResource("metadataCompletion")
        }
        if request.method == AutomationMethod.completionControl {
            let action = try parameters.string("action", required: true)!
            let ids = try parameters.uuidArray("trackIDs", allowEmpty: true)
            guard ["enqueue", "pause", "resume", "retry"].contains(action), action == "enqueue" || ids.isEmpty else {
                throw AutomationParameterError.invalidValue("action/trackIDs")
            }
            guard ids.allSatisfy({ id in session.libraryViewModel.allTracks.contains { $0.id == id } }) else {
                throw AutomationParameterError.missingResource("trackIDs")
            }
            if try parameters.boolean("dryRun", default: false) {
                return .success(for: request, result: .object(["dryRun": .boolean(true), "action": .string(action), "status": try json(source.status)]))
            }
            switch action {
            case "pause": source.setPaused(true)
            case "resume": source.setPaused(false)
            case "retry": source.retryFailures()
            default: source.enqueue(trackIDs: ids.isEmpty ? nil : ids, force: try parameters.boolean("force", default: false))
            }
        }
        return .success(for: request, result: try json(source.status))
    }
}
