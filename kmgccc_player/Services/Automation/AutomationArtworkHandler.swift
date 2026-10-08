import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

@MainActor
final class AutomationArtworkHandler {
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
        case AutomationMethod.artworkSearch:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let limit = try parameters.integer("limit", default: 5)
                guard (1...5).contains(limit) else {
                    throw AutomationParameterError.outOfRange("limit")
                }
                let target = try resolveArtworkTarget(
                    from: parameters,
                    session: session,
                    allowPlaylist: false
                )
                let targetRevision = artworkRevision(for: target, session: session)
                let candidates: [CoverCandidate]
                let queryTitle: String?
                let queryArtist: String?
                let queryAlbum: String?
                let trackID: UUID?
                let artistID: UUID?
                let albumKey: String?
                switch target {
                case .track(let track):
                    candidates = await session.searchArtworkCandidatesForAutomation(
                        trackID: track.id,
                        limit: limit
                    )
                    queryTitle = track.title
                    queryArtist = track.artist.isEmpty ? nil : track.artist
                    queryAlbum = track.album.isEmpty ? nil : track.album
                    trackID = track.id
                    artistID = nil
                    albumKey = nil
                case .artist(let entry):
                    candidates = await session.searchArtistArtworkCandidatesForAutomation(
                        artistID: entry.id,
                        limit: limit
                    )
                    queryTitle = nil
                    queryArtist = entry.displayName
                    queryAlbum = nil
                    trackID = nil
                    artistID = entry.id
                    albumKey = nil
                case .album(let entry):
                    candidates = await session.searchAlbumArtworkCandidatesForAutomation(
                        albumKey: entry.canonicalKey,
                        limit: limit
                    )
                    queryTitle = nil
                    queryArtist = entry.primaryArtistDisplayName.isEmpty
                        ? nil
                        : entry.primaryArtistDisplayName
                    queryAlbum = entry.displayTitle
                    trackID = nil
                    artistID = nil
                    albumKey = entry.canonicalKey
                case .playlist:
                    throw AutomationParameterError.invalidValue("playlistID")
                }
                let rankedCandidates = candidates.map {
                    cacheArtworkCandidate(
                        $0,
                        target: target,
                        revision: targetRevision,
                        session: session,
                        queryTitle: queryTitle,
                        queryArtist: queryArtist,
                        queryAlbum: queryAlbum
                    )
                }.sorted { lhs, rhs in
                    let leftQuality = lhs.matchQuality ?? 0
                    let rightQuality = rhs.matchQuality ?? 0
                    if leftQuality != rightQuality { return leftQuality > rightQuality }
                    if lhs.resolution != rhs.resolution { return lhs.resolution > rhs.resolution }
                    return lhs.id < rhs.id
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationArtworkSearchResult(
                        targetType: target.type,
                        trackID: trackID,
                        artistID: artistID,
                        albumKey: albumKey,
                        queryTitle: queryTitle,
                        queryArtist: queryArtist,
                        queryAlbum: queryAlbum,
                        candidates: rankedCandidates,
                        message: rankedCandidates.isEmpty
                            ? "No artwork candidates were returned by the configured providers."
                            : "Artwork candidates include provider-neutral metadata/image matchQuality alongside each provider's own confidence. Results are ordered by matchQuality, then resolution and stable ID. Each candidate has a Library- and artwork-revision-bound ID for preview and direct apply. Inline imageBase64 remains available for Agent review."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.artworkApplyCandidate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let candidateID = try parameters.string("candidateID", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidateID.isEmpty else {
                    throw AutomationParameterError.invalidValue("candidateID")
                }
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                pruneArtworkCandidateCache(now: Date())
                guard let cached = artworkCandidateCache[candidateID],
                      cached.expiresAt > Date(),
                      cached.libraryID == session.context.id else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The artwork candidate is unknown, expired, or belongs to another Library. Search artwork again to obtain a current candidate ID.",
                            details: .object(["candidateID": .string(candidateID)])
                        )
                    )
                }
                if let expectedRevision, expectedRevision != cached.revision {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "The supplied revision does not match the revision captured when this artwork candidate was searched.",
                            details: .object([
                                "expectedRevision": .string(expectedRevision),
                                "candidateRevision": .string(cached.revision)
                            ])
                        )
                    )
                }

                var resolvedValues: [String: AutomationJSONValue] = [
                    "imageBase64": .string(cached.candidate.imageBase64),
                    "expectedRevision": .string(cached.revision),
                    "dryRun": .boolean(dryRun),
                    "confirm": .boolean(confirm)
                ]
                if let trackID = cached.trackID {
                    resolvedValues["trackID"] = .string(trackID.uuidString)
                } else if let artistID = cached.artistID {
                    resolvedValues["artistID"] = .string(artistID.uuidString)
                } else if let albumKey = cached.albumKey {
                    resolvedValues["albumKey"] = .string(albumKey)
                } else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The artwork candidate no longer has a supported target.",
                            details: .object(["candidateID": .string(candidateID)])
                        )
                    )
                }
                let applyRequest = AutomationRequest(
                    method: AutomationMethod.artworkApply,
                    params: .object(resolvedValues),
                    context: request.context,
                    requestID: request.requestID,
                    protocolVersion: request.protocolVersion
                )
                let applyParameters = try AutomationParameters(applyRequest)
                let resolvedTarget = try resolveArtworkTarget(
                    from: applyParameters,
                    session: session,
                    allowPlaylist: false
                )
                guard resolvedTarget.stableIdentity == cached.targetIdentity else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "The artwork candidate target changed after search.",
                            details: .object(["candidateID": .string(candidateID)])
                        )
                    )
                }
                return try await applyArtworkToSingleTarget(
                    parameters: applyParameters,
                    request: request,
                    session: session
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.artworkGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs")
                let artworks: [AutomationArtworkInfo]
                let revision: String
                if !trackIDs.isEmpty {
                    guard try !hasArtworkTargetParameters(parameters, excludingTrackIDs: true) else {
                        throw AutomationParameterError.invalidValue("trackIDs")
                    }
                    let tracksByID = Dictionary(
                        uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                    )
                    guard trackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                        throw AutomationParameterError.invalidValue("trackIDs")
                    }
                    artworks = trackIDs.compactMap { id in
                        tracksByID[id].map {
                            makeArtworkInfo(.track($0), session: session)
                        }
                    }
                    revision = queries.libraryTracksRevision(
                        tracks: session.libraryViewModel.allTracks,
                        playlists: session.libraryViewModel.playlists
                    )
                } else {
                    let target = try resolveArtworkTarget(
                        from: parameters,
                        session: session,
                        allowPlaylist: true
                    )
                    artworks = [makeArtworkInfo(target, session: session)]
                    revision = artworkRevision(for: target, session: session)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationArtworkGetResult(
                        artworks: artworks,
                        revision: revision
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.artworkApply:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs")
                if trackIDs.isEmpty {
                    return try await applyArtworkToSingleTarget(
                        parameters: parameters,
                        request: request,
                        session: session
                    )
                }
                guard try !hasArtworkTargetParameters(parameters, excludingTrackIDs: true) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let clear = try parameters.boolean("clear", default: false)
                let imagePath = try parameters.string("imagePath")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let imageBase64 = try parameters.string("imageBase64")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let expectedRevisions = try queries.makeTrackRevisions(
                    from: parameters.object("expectedRevisions")
                )
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                guard !(clear && (imagePath != nil || imageBase64 != nil)) else {
                    throw AutomationParameterError.invalidValue("clear")
                }
                guard !(imagePath != nil && imageBase64 != nil) else {
                    throw AutomationParameterError.invalidValue("imagePath/imageBase64")
                }
                if let imageBase64, imageBase64.isEmpty {
                    throw AutomationParameterError.invalidValue("imageBase64")
                }
                if let imagePath, imagePath.isEmpty {
                    throw AutomationParameterError.invalidValue("imagePath")
                }

                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                guard trackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let candidates = trackIDs.compactMap { tracksByID[$0] }
                let conflictIDs = candidates.compactMap { track -> UUID? in
                    guard let expected = expectedRevisions[track.id],
                          expected != session.libraryViewModel.automationTrackRevision(for: track),
                          expected != session.libraryViewModel.automationArtworkRevision(for: track) else {
                        return nil
                    }
                    return track.id
                }
                let changedIDs = candidates.compactMap { track -> UUID? in
                    guard !conflictIDs.contains(track.id) else { return nil }
                    if clear {
                        return track.loadArtworkDataIfNeeded() != nil || track.artworkFileName != nil
                            ? track.id
                            : nil
                    }
                    return track.id
                }
                let skippedIDs = candidates.map(\.id).filter {
                    !changedIDs.contains($0) && !conflictIDs.contains($0)
                }
                let inputKind = clear
                    ? "clear"
                    : imageBase64 != nil
                        ? "imageBase64"
                        : imagePath != nil
                            ? "imagePath"
                            : "picker"

                if !dryRun, trackIDs.count >= 10 {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "批量应用封面需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(AutomationMethod.artworkApply),
                                "trackCount": .number(Double(trackIDs.count)),
                                "threshold": .number(10),
                                "requiresForegroundConfirmation": .boolean(true)
                            ])
                        )
                    }
                }

                guard !dryRun else {
                    if let imageBase64 {
                        let encoded = imageBase64.hasPrefix("data:")
                            ? (imageBase64.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "")
                            : imageBase64
                        guard let data = Data(base64Encoded: encoded),
                              data.count <= 16 * 1024 * 1024,
                              ArtworkDataNormalizer.isDecodableImage(data) else {
                            throw AutomationParameterError.invalidValue("imageBase64")
                        }
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationArtworkMutationResult(
                            applied: false,
                            dryRun: true,
                            input: inputKind,
                            updatedTrackIDs: changedIDs,
                            skippedTrackIDs: skippedIDs,
                            conflictedTrackIDs: conflictIDs,
                            message: "Preview only. App-owned artwork will be replaced or cleared; original audio-file tags will not be changed. Batches of 10 or more require confirm=true and foreground confirmation."
                        ),
                        for: request
                    )
                }

                if trackIDs.count >= 10,
                   !AutomationBatchExecutionContext.aggregateConfirmationApproved {
                    guard await AutomationInteraction.confirmDestructiveOperation(
                        title: "应用到 \(trackIDs.count) 首歌曲？",
                        message: clear
                            ? "要清除这 \(trackIDs.count) 首歌曲的封面吗？原音频文件不会修改。"
                            : "要将所选封面应用到这 \(trackIDs.count) 首歌曲吗？原音频文件不会修改。"
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                }

                let resolvedInput: (kind: String, data: Data?)
                if clear {
                    resolvedInput = ("clear", nil)
                } else if let imageBase64 {
                    let encoded = imageBase64.hasPrefix("data:")
                        ? (imageBase64.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "")
                        : imageBase64
                    guard let data = Data(base64Encoded: encoded),
                          data.count <= 16 * 1024 * 1024,
                          ArtworkDataNormalizer.isDecodableImage(data) else {
                        throw AutomationParameterError.invalidValue("imageBase64")
                    }
                    resolvedInput = ("imageBase64", data)
                } else if let imagePath,
                           let data = try? Data(contentsOf: URL(fileURLWithPath: AutomationInteraction.expandPath(imagePath))),
                           data.count <= 16 * 1024 * 1024,
                           ArtworkDataNormalizer.isDecodableImage(data) {
                    resolvedInput = ("imagePath", ArtworkDataNormalizer.normalizedJPEGData(from: data) ?? data)
                } else {
                    guard let selectedURL = try await AutomationInteraction.requestArtworkURL(
                        requestedPath: imagePath.map(AutomationInteraction.expandPath(_:))
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                    let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                        let accessed = selectedURL.startAccessingSecurityScopedResource()
                        defer {
                            if accessed { selectedURL.stopAccessingSecurityScopedResource() }
                        }
                        return try? Data(contentsOf: selectedURL)
                    }.value
                    guard let data,
                          data.count <= 16 * 1024 * 1024,
                          ArtworkDataNormalizer.isDecodableImage(data) else {
                        throw AutomationParameterError.invalidValue("imagePath")
                    }
                    resolvedInput = (imagePath == nil ? "picker" : "imagePath", data)
                }

                let outcome = try await session.libraryViewModel.applyArtworkForAutomation(
                    trackIDs: trackIDs,
                    artworkData: resolvedInput.data,
                    expectedRevisions: expectedRevisions
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationArtworkMutationResult(
                        applied: !outcome.updatedTrackIDs.isEmpty,
                        dryRun: false,
                        confirmed: trackIDs.count >= 10,
                        input: resolvedInput.kind,
                        updatedTrackIDs: outcome.updatedTrackIDs,
                        skippedTrackIDs: outcome.skippedTrackIDs,
                        conflictedTrackIDs: outcome.conflictedTrackIDs,
                        message: outcome.conflictedTrackIDs.isEmpty
                            ? "App-owned artwork updated; original audio-file tags were not changed."
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

    private struct ResolvedArtworkInput {
        let kind: String
        let data: Data?
    }

    private enum ArtworkTarget {
        case track(Track)
        case artist(ArtistEntry)
        case album(AlbumEntry)
        case playlist(Playlist)

        var type: String {
            switch self {
            case .track: return "track"
            case .artist: return "artist"
            case .album: return "album"
            case .playlist: return "playlist"
            }
        }

        var stableIdentity: String {
            switch self {
            case .track(let track): return "track:\(track.id.uuidString)"
            case .artist(let artist): return "artist:\(artist.id.uuidString)"
            case .album(let album): return "album:\(album.canonicalKey)"
            case .playlist(let playlist): return "playlist:\(playlist.id.uuidString)"
            }
        }
    }

    private struct CachedArtworkCandidate {
        let libraryID: UUID
        let targetIdentity: String
        let trackID: UUID?
        let artistID: UUID?
        let albumKey: String?
        let revision: String
        let candidate: AutomationArtworkCandidate
        let expiresAt: Date
    }

    private var artworkCandidateCache: [String: CachedArtworkCandidate] = [:]


    private var artworkCandidateOrder: [String] = []


    private let artworkCandidateCacheLimit = 64


    private func hasArtworkTargetParameters(
        _ parameters: AutomationParameters,
        excludingTrackIDs: Bool = false
    ) throws -> Bool {
        let trackID = try parameters.uuid("trackID")
        let artistID = try parameters.uuid("artistID")
        let albumKey = try parameters.string("albumKey")
        let playlistID = try parameters.uuid("playlistID")
        if excludingTrackIDs {
            return trackID != nil || artistID != nil || albumKey != nil || playlistID != nil
        }
        return trackID != nil || artistID != nil || albumKey != nil || playlistID != nil
    }

    private func resolveArtworkTarget(
        from parameters: AutomationParameters,
        session: LibrarySession,
        allowPlaylist: Bool
    ) throws -> ArtworkTarget {
        let trackID = try parameters.uuid("trackID")
        let artistID = try parameters.uuid("artistID")
        let rawAlbumKey = try parameters.string("albumKey")
        let albumKey = rawAlbumKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlistID = try parameters.uuid("playlistID")
        let targetCount = [trackID != nil, artistID != nil, albumKey != nil, playlistID != nil]
            .filter { $0 }
            .count
        guard targetCount == 1 else {
            throw AutomationParameterError.missing("exactly one of trackID, artistID, albumKey or playlistID")
        }

        if let trackID {
            guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                throw AutomationParameterError.missingResource("trackID")
            }
            return .track(track)
        }
        if let artistID {
            guard let artist = session.libraryViewModel.artistEntries.first(where: { $0.id == artistID }) else {
                throw AutomationParameterError.missingResource("artistID")
            }
            return .artist(artist)
        }
        if let albumKey {
            guard !albumKey.isEmpty else {
                throw AutomationParameterError.invalidValue("albumKey")
            }
            guard let album = session.libraryViewModel.albumEntries.first(where: { $0.canonicalKey == albumKey }) else {
                throw AutomationParameterError.missingResource("albumKey")
            }
            return .album(album)
        }
        guard allowPlaylist else {
            throw AutomationParameterError.invalidValue("playlistID")
        }
        guard let playlistID,
              let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
            throw AutomationParameterError.missingResource("playlistID")
        }
        return .playlist(playlist)
    }

    private func makeArtworkInfo(
        _ target: ArtworkTarget,
        session: LibrarySession
    ) -> AutomationArtworkInfo {
        switch target {
        case .track(let track):
            let data = track.loadArtworkDataIfNeeded()
            return AutomationArtworkInfo(
                targetType: target.type,
                trackID: track.id,
                available: data != nil || track.artworkFileName != nil,
                fileName: track.artworkFileName,
                byteCount: data?.count,
                sha256: artworkDigest(data),
                revision: session.libraryViewModel.automationArtworkRevision(for: track)
            )
        case .artist(let entry):
            return AutomationArtworkInfo(
                targetType: target.type,
                artistID: entry.id,
                available: entry.hasArtwork,
                fileName: entry.artworkFileName,
                byteCount: entry.artworkData?.count,
                sha256: artworkDigest(entry.artworkData),
                revision: session.libraryViewModel.automationArtworkRevision(for: entry)
            )
        case .album(let entry):
            return AutomationArtworkInfo(
                targetType: target.type,
                albumKey: entry.canonicalKey,
                available: entry.hasArtwork,
                fileName: entry.artworkFileName,
                byteCount: entry.artworkData?.count,
                sha256: artworkDigest(entry.artworkData),
                revision: session.libraryViewModel.automationArtworkRevision(for: entry)
            )
        case .playlist(let playlist):
            let sidecar = session.libraryService.loadPlaylistSidecar(playlistID: playlist.id)
            let fileName: String?
            switch sidecar?.headerArtworkSource ?? .none {
            case .custom:
                fileName = sidecar?.customHeaderArtworkFileName
            case .generated:
                fileName = sidecar?.generatedHeaderArtworkFileName
            case .none:
                fileName = nil
            }
            let data = fileName.flatMap {
                try? Data(contentsOf: session.libraryService.paths.playlistsRootURL.appendingPathComponent($0))
            }
            return AutomationArtworkInfo(
                targetType: target.type,
                playlistID: playlist.id,
                available: data != nil || fileName != nil,
                fileName: fileName,
                byteCount: data?.count,
                sha256: artworkDigest(data),
                revision: session.libraryViewModel.automationArtworkRevision(for: playlist)
            )
        }
    }

    private func artworkDigest(_ data: Data?) -> String? {
        guard let data else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func artworkRevision(
        for target: ArtworkTarget,
        session: LibrarySession
    ) -> String {
        switch target {
        case .track(let track): return session.libraryViewModel.automationArtworkRevision(for: track)
        case .artist(let entry): return session.libraryViewModel.automationArtworkRevision(for: entry)
        case .album(let entry): return session.libraryViewModel.automationArtworkRevision(for: entry)
        case .playlist(let playlist): return session.libraryViewModel.automationArtworkRevision(for: playlist)
        }
    }

    private func resolveArtworkInput(
        clear: Bool,
        imagePath: String?,
        imageBase64: String?
    ) async throws -> ResolvedArtworkInput? {
        if clear {
            return ResolvedArtworkInput(kind: "clear", data: nil)
        }
        if let imageBase64 {
            let encoded = imageBase64.hasPrefix("data:")
                ? (imageBase64.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "")
                : imageBase64
            guard let data = Data(base64Encoded: encoded),
                  data.count <= 16 * 1024 * 1024,
                  ArtworkDataNormalizer.isDecodableImage(data) else {
                throw AutomationParameterError.invalidValue("imageBase64")
            }
            let normalized = ArtworkDataNormalizer.normalizedJPEGData(from: data) ?? data
            return ResolvedArtworkInput(kind: "imageBase64", data: normalized)
        }

        if let imagePath {
            let expanded = AutomationInteraction.expandPath(imagePath)
            let directURL = URL(fileURLWithPath: expanded)
            if let data = try? Data(contentsOf: directURL),
               data.count <= 16 * 1024 * 1024,
               ArtworkDataNormalizer.isDecodableImage(data) {
                return ResolvedArtworkInput(
                    kind: "imagePath",
                    data: ArtworkDataNormalizer.normalizedJPEGData(from: data) ?? data
                )
            }
        }

        guard let selectedURL = try await AutomationInteraction.requestArtworkURL(
            requestedPath: imagePath.map(AutomationInteraction.expandPath(_:))
        ) else {
            return nil
        }
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            let accessed = selectedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { selectedURL.stopAccessingSecurityScopedResource() }
            }
            return try? Data(contentsOf: selectedURL)
        }.value
        guard let data,
              data.count <= 16 * 1024 * 1024,
              ArtworkDataNormalizer.isDecodableImage(data) else {
            throw AutomationParameterError.invalidValue("imagePath")
        }
        return ResolvedArtworkInput(
            kind: imagePath == nil ? "picker" : "imagePath",
            data: ArtworkDataNormalizer.normalizedJPEGData(from: data) ?? data
        )
    }

    private func applyArtworkToSingleTarget(
        parameters: AutomationParameters,
        request: AutomationRequest,
        session: LibrarySession
    ) async throws -> AutomationResponse {
        guard try hasArtworkTargetParameters(parameters) else {
            throw AutomationParameterError.missing("artwork target")
        }
        guard try parameters.object("expectedRevisions") == nil else {
            throw AutomationParameterError.invalidValue("expectedRevisions")
        }
        let target = try resolveArtworkTarget(from: parameters, session: session, allowPlaylist: true)
        let clear = try parameters.boolean("clear", default: false)
        let imagePath = try parameters.string("imagePath")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageBase64 = try parameters.string("imageBase64")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedRevision = try parameters.string("expectedRevision")
        let dryRun = try parameters.boolean("dryRun", default: false)
        let confirm = try parameters.boolean("confirm", default: false)
        guard !(clear && (imagePath != nil || imageBase64 != nil)) else {
            throw AutomationParameterError.invalidValue("clear")
        }
        guard !(imagePath != nil && imageBase64 != nil) else {
            throw AutomationParameterError.invalidValue("imagePath/imageBase64")
        }
        if let imagePath, imagePath.isEmpty { throw AutomationParameterError.invalidValue("imagePath") }
        if let imageBase64, imageBase64.isEmpty { throw AutomationParameterError.invalidValue("imageBase64") }

        let info = makeArtworkInfo(target, session: session)
        let actualRevision = artworkRevision(for: target, session: session)
        let compatibleRevision: String? = {
            switch target {
            case .track(let track): return session.libraryViewModel.automationTrackRevision(for: track)
            case .artist(let entry): return session.libraryViewModel.automationArtistRevision(for: entry)
            case .album(let entry): return session.libraryViewModel.automationAlbumRevision(for: entry)
            case .playlist(let playlist): return session.libraryViewModel.automationPlaylistRevision(for: playlist)
            }
        }()
        let isConflict = expectedRevision.map {
            $0 != actualRevision && $0 != compatibleRevision
        } ?? false
        let targetID: UUID? = {
            switch target {
            case .track(let track): return track.id
            case .artist(let entry): return entry.id
            case .album, .playlist: return nil
            }
        }()
        let targetArtistID: UUID? = {
            if case .artist(let entry) = target { return entry.id }
            return nil
        }()
        let targetTrackIDs: [UUID] = {
            if case .track(let track) = target { return [track.id] }
            return []
        }()
        let targetArtistIDs: [UUID] = {
            if case .artist(let entry) = target { return [entry.id] }
            return []
        }()
        let targetAlbumIDs = ifCaseAlbumID(target)
        let targetPlaylistIDs = ifCasePlaylistID(target).map { [$0] } ?? []
        let changed = !isConflict && (clear ? info.available : true)
        let inputKind = clear ? "clear" : imageBase64 != nil ? "imageBase64" : imagePath != nil ? "imagePath" : "picker"

        func result(
            applied: Bool,
            dryRun: Bool,
            confirmed: Bool,
            input: String,
            outcome: LibraryAutomationEntityArtworkMutationOutcome? = nil,
            trackOutcome: LibraryAutomationArtworkMutationOutcome? = nil,
            conflict: Bool = false,
            previewChanged: Bool? = nil,
            message: String
        ) -> AutomationResponse {
            let conflictedTrackIDs: [UUID]
            let conflictedArtistIDs: [UUID]
            let conflictedAlbumIDs: [UUID]
            let conflictedPlaylistIDs: [UUID]
            if let trackOutcome {
                conflictedTrackIDs = trackOutcome.conflictedTrackIDs
                conflictedArtistIDs = []
                conflictedAlbumIDs = []
                conflictedPlaylistIDs = []
            } else if let outcome {
                conflictedTrackIDs = []
                conflictedArtistIDs = outcome.conflictedArtistIDs
                conflictedAlbumIDs = outcome.conflictedAlbumIDs
                conflictedPlaylistIDs = outcome.conflictedPlaylistIDs
            } else if conflict {
                conflictedTrackIDs = targetID.flatMap { targetArtistID == nil ? [$0] : [] } ?? []
                conflictedArtistIDs = targetArtistID.map { [$0] } ?? []
                conflictedAlbumIDs = ifCaseAlbumID(target)
                conflictedPlaylistIDs = ifCasePlaylistID(target).map { [$0] } ?? []
            } else {
                conflictedTrackIDs = []
                conflictedArtistIDs = []
                conflictedAlbumIDs = []
                conflictedPlaylistIDs = []
            }
            let previewUpdatedTrackIDs = previewChanged == true ? targetTrackIDs : []
            let previewSkippedTrackIDs = previewChanged == false ? targetTrackIDs : []
            let previewUpdatedArtistIDs = previewChanged == true ? targetArtistIDs : []
            let previewSkippedArtistIDs = previewChanged == false ? targetArtistIDs : []
            let previewUpdatedAlbumIDs = previewChanged == true ? targetAlbumIDs : []
            let previewSkippedAlbumIDs = previewChanged == false ? targetAlbumIDs : []
            let previewUpdatedPlaylistIDs = previewChanged == true ? targetPlaylistIDs : []
            let previewSkippedPlaylistIDs = previewChanged == false ? targetPlaylistIDs : []
            return AutomationResponseSupport.encodeResult(
                AutomationArtworkMutationResult(
                    targetType: target.type,
                    trackID: targetID.flatMap { targetArtistID == nil ? $0 : nil },
                    artistID: targetArtistID,
                    albumKey: ifCaseAlbumKey(target),
                    playlistID: ifCasePlaylistID(target),
                    applied: applied,
                    dryRun: dryRun,
                    confirmed: confirmed,
                    input: input,
                    updatedTrackIDs: trackOutcome?.updatedTrackIDs ?? previewUpdatedTrackIDs,
                    skippedTrackIDs: trackOutcome?.skippedTrackIDs ?? previewSkippedTrackIDs,
                    conflictedTrackIDs: conflictedTrackIDs,
                    updatedArtistIDs: outcome?.updatedArtistIDs ?? previewUpdatedArtistIDs,
                    skippedArtistIDs: outcome?.skippedArtistIDs ?? previewSkippedArtistIDs,
                    conflictedArtistIDs: conflictedArtistIDs,
                    updatedAlbumIDs: outcome?.updatedAlbumIDs ?? previewUpdatedAlbumIDs,
                    skippedAlbumIDs: outcome?.skippedAlbumIDs ?? previewSkippedAlbumIDs,
                    conflictedAlbumIDs: conflictedAlbumIDs,
                    updatedPlaylistIDs: outcome?.updatedPlaylistIDs ?? previewUpdatedPlaylistIDs,
                    skippedPlaylistIDs: outcome?.skippedPlaylistIDs ?? previewSkippedPlaylistIDs,
                    conflictedPlaylistIDs: conflictedPlaylistIDs,
                    message: message
                ),
                for: request
            )
        }

        if isConflict {
            return result(
                applied: false,
                dryRun: dryRun,
                confirmed: false,
                input: inputKind,
                conflict: true,
                message: "The target artwork changed after it was queried; nothing was written."
            )
        }

        if dryRun {
            if let imageBase64 {
                _ = try await resolveArtworkInput(clear: false, imagePath: nil, imageBase64: imageBase64)
            }
            return result(
                applied: false,
                dryRun: true,
                confirmed: false,
                input: inputKind,
                previewChanged: changed,
                message: changed
                    ? "Preview only. App-owned artwork will be replaced or cleared; original audio-file tags will not be changed."
                    : "Preview only. The target is already clear and would be skipped."
            )
        }

        let resolvedInput = try await resolveArtworkInput(
            clear: clear,
            imagePath: imagePath,
            imageBase64: imageBase64
        )
        guard let resolvedInput else {
            return AutomationResponseSupport.interactionCancelled(for: request)
        }

        switch target {
        case .track(let track):
            let outcome = try await session.libraryViewModel.applyArtworkForAutomation(
                trackIDs: [track.id],
                artworkData: resolvedInput.data,
                expectedRevisions: expectedRevision.map { [track.id: $0] } ?? [:]
            )
            return result(
                applied: !outcome.updatedTrackIDs.isEmpty,
                dryRun: false,
                confirmed: confirm,
                input: resolvedInput.kind,
                trackOutcome: outcome,
                message: "App-owned artwork updated; original audio-file tags were not changed."
            )
        case .artist(let entry):
            let outcome = try await session.libraryViewModel.applyArtistArtworkForAutomation(
                artistID: entry.id,
                artworkData: resolvedInput.data,
                expectedRevision: expectedRevision
            )
            return result(
                applied: !outcome.updatedArtistIDs.isEmpty,
                dryRun: false,
                confirmed: confirm,
                input: resolvedInput.kind,
                outcome: outcome,
                message: "App-owned Artist artwork updated."
            )
        case .album(let entry):
            let outcome = try await session.libraryViewModel.applyAlbumArtworkForAutomation(
                albumID: entry.id,
                artworkData: resolvedInput.data,
                expectedRevision: expectedRevision
            )
            return result(
                applied: !outcome.updatedAlbumIDs.isEmpty,
                dryRun: false,
                confirmed: confirm,
                input: resolvedInput.kind,
                outcome: outcome,
                message: "App-owned Album artwork updated."
            )
        case .playlist(let playlist):
            let outcome = try await session.libraryViewModel.applyPlaylistArtworkForAutomation(
                playlistID: playlist.id,
                artworkData: resolvedInput.data,
                expectedRevision: expectedRevision
            )
            return result(
                applied: !outcome.updatedPlaylistIDs.isEmpty,
                dryRun: false,
                confirmed: confirm,
                input: resolvedInput.kind,
                outcome: outcome,
                message: "App-owned Playlist artwork updated."
            )
        }
    }

    private func ifCaseAlbumKey(_ target: ArtworkTarget) -> String? {
        if case .album(let entry) = target { return entry.canonicalKey }
        return nil
    }

    private func ifCaseAlbumID(_ target: ArtworkTarget) -> [UUID] {
        if case .album(let entry) = target { return [entry.id] }
        return []
    }

    private func ifCasePlaylistID(_ target: ArtworkTarget) -> UUID? {
        if case .playlist(let playlist) = target { return playlist.id }
        return nil
    }

    private func cacheArtworkCandidate(
        _ candidate: CoverCandidate,
        target: ArtworkTarget,
        revision: String,
        session: LibrarySession,
        queryTitle: String?,
        queryArtist: String?,
        queryAlbum: String?
    ) -> AutomationArtworkCandidate {
        pruneArtworkCandidateCache(now: Date())
        let imageDigest = artworkDigest(candidate.imageData) ?? "unavailable"
        let identity = [
            session.context.id.uuidString,
            target.stableIdentity,
            artworkSourceName(candidate.source),
            candidate.sourceItemId ?? "",
            imageDigest
        ].joined(separator: "\n")
        let candidateDigest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let candidateID = "art-v1-" + candidateDigest
        let wireCandidate = makeArtworkCandidate(
            candidate,
            candidateID: candidateID,
            queryTitle: queryTitle,
            queryArtist: queryArtist,
            queryAlbum: queryAlbum
        )
        let trackID: UUID?
        let artistID: UUID?
        let albumKey: String?
        switch target {
        case .track(let track):
            trackID = track.id
            artistID = nil
            albumKey = nil
        case .artist(let artist):
            trackID = nil
            artistID = artist.id
            albumKey = nil
        case .album(let album):
            trackID = nil
            artistID = nil
            albumKey = album.canonicalKey
        case .playlist:
            return wireCandidate
        }
        artworkCandidateCache[candidateID] = CachedArtworkCandidate(
            libraryID: session.context.id,
            targetIdentity: target.stableIdentity,
            trackID: trackID,
            artistID: artistID,
            albumKey: albumKey,
            revision: revision,
            candidate: wireCandidate,
            expiresAt: Date().addingTimeInterval(15 * 60)
        )
        artworkCandidateOrder.removeAll { $0 == candidateID }
        artworkCandidateOrder.append(candidateID)
        while artworkCandidateOrder.count > artworkCandidateCacheLimit {
            let expired = artworkCandidateOrder.removeFirst()
            artworkCandidateCache.removeValue(forKey: expired)
        }
        return wireCandidate
    }

    private func pruneArtworkCandidateCache(now: Date) {
        artworkCandidateOrder.removeAll { candidateID in
            guard let candidate = artworkCandidateCache[candidateID],
                  candidate.expiresAt > now else {
                artworkCandidateCache.removeValue(forKey: candidateID)
                return true
            }
            return false
        }
    }

    private func makeArtworkCandidate(
        _ candidate: CoverCandidate,
        candidateID: String? = nil,
        queryTitle: String?,
        queryArtist: String?,
        queryAlbum: String?
    ) -> AutomationArtworkCandidate {
        let inlineData = inlineArtworkData(candidate.imageData)
        return AutomationArtworkCandidate(
            candidateID: candidateID,
            source: artworkSourceName(candidate.source),
            sourceItemID: candidate.sourceItemId,
            imageBase64: inlineData.base64EncodedString(),
            imageMIMEType: artworkMIMEType(for: inlineData),
            byteCount: inlineData.count,
            originalByteCount: inlineData == candidate.imageData ? nil : candidate.imageData.count,
            width: candidate.width,
            height: candidate.height,
            resolution: candidate.resolution,
            confidence: candidate.confidence,
            matchQuality: AutomationArtworkQualityEvaluator.score(
                queryTitle: queryTitle,
                queryArtist: queryArtist,
                queryAlbum: queryAlbum,
                candidateTitle: candidate.matchedTitle,
                candidateArtist: candidate.matchedArtist,
                candidateAlbum: candidate.matchedAlbum,
                width: candidate.width,
                height: candidate.height
            ),
            matchedTitle: candidate.matchedTitle,
            matchedArtist: candidate.matchedArtist,
            matchedAlbum: candidate.matchedAlbum,
            imageURL: candidate.imageURL
        )
    }

    /// The App IPC response frame is intentionally capped at 1 MiB. Provider
    /// images can be multi-megabyte PNGs, so keep the Agent-review payload
    /// useful and bounded while preserving the original URL/size metadata.
    private func inlineArtworkData(_ data: Data) -> Data {
        let maximumBytes = 100_000
        guard data.count > maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return data
        }

        var maxPixelSize = 640
        var quality = 0.82
        var bestData: Data?
        for _ in 0..<5 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                break
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                break
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { break }
            let encoded = output as Data
            bestData = encoded
            if encoded.count <= maximumBytes {
                return encoded
            }
            maxPixelSize = max(256, maxPixelSize * 3 / 4)
            quality *= 0.78
        }
        return bestData ?? data
    }

    private func artworkSourceName(_ source: CoverSource) -> String {
        switch source {
        case .sacad: return "sacad"
        case .netease: return "netease"
        case .qqmusic: return "qqmusic"
        }
    }

    private func artworkMIMEType(for data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.subdata(in: 8..<12) == Data("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }
}
