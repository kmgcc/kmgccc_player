import Darwin
import Foundation
import Testing
@testable import PlayerAutomationIPC
@testable import PlayerAutomationProtocol

@Test
func wireRoundTripPreservesRequestAndUnknownJSONFields() throws {
    let requestID = UUID()
    let request = AutomationRequest(
        method: AutomationMethod.systemInfo,
        params: .object([
            "futureField": .string("ignored by the App until supported"),
            "limit": .number(10)
        ]),
        context: AutomationRequestContext(
            libraryID: UUID(),
            deadline: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        requestID: requestID
    )
    let data = try AutomationWireCoding.encoder().encode(request)
    let decoded = try AutomationWireCoding.decoder().decode(AutomationRequest.self, from: data)
    #expect(decoded == request)
}

@Test
func frameDecoderHandlesPartialAndMultipleFrames() throws {
    let codec = try AutomationIPCFrameCodec(maximumFrameBytes: 128)
    let first = try codec.encode(Data("first".utf8))
    let second = try codec.encode(Data("second".utf8))
    var buffer = Data()
    var decoded: [Data] = []
    for byte in first + second {
        buffer.append(byte)
        while let payload = try codec.decodeNext(from: &buffer) {
            decoded.append(payload)
        }
    }
    #expect(decoded == [Data("first".utf8), Data("second".utf8)])
    #expect(buffer.isEmpty)
}

@Test
func frameCodecRejectsOversizeAndNonFiniteNumbers() throws {
    let codec = try AutomationIPCFrameCodec(maximumFrameBytes: 3)
    #expect(throws: AutomationIPCError.frameTooLarge(4)) {
        _ = try codec.encode(Data(repeating: 0x01, count: 4))
    }

    #expect(throws: AutomationCodingError.nonFiniteNumber) {
        _ = try AutomationWireCoding.encoder().encode(AutomationJSONValue.number(.infinity))
    }
}

@Test
func responseFactoriesKeepRequestID() {
    let request = AutomationRequest(method: AutomationMethod.systemPing)
    let success = AutomationResponse.success(for: request, result: .null)
    let failure = AutomationResponse.failure(
        for: request,
        error: AutomationError(code: .methodNotFound, message: "missing")
    )
    #expect(success.requestID == request.requestID)
    #expect(failure.requestID == request.requestID)
}

@Test
func automationToolCatalogIsStableAndMarksMutationsExplicitly() throws {
    let names = AutomationToolCatalog.all.map(\.name)
    #expect(names == names.sorted())
    #expect(Set(names).count == names.count)
    #expect(names.contains(AutomationMethod.libraryTracks))
    #expect(names.contains(AutomationMethod.playlistAddTracks))
    #expect(names.contains(AutomationMethod.sourceList))
    #expect(names.contains(AutomationMethod.sourceRefresh))
    #expect(names.contains(AutomationMethod.filesInspect))
    #expect(names.contains(AutomationMethod.filesRename))
    #expect(names.contains(AutomationMethod.filesMove))
    #expect(names.contains(AutomationMethod.filesDelete))
    #expect(names.contains(AutomationMethod.libraryCreate))
    #expect(names.contains(AutomationMethod.libraryOpen))
    #expect(names.contains(AutomationMethod.librarySwitch))
    #expect(names.contains(AutomationMethod.libraryRename))
    #expect(names.contains(AutomationMethod.libraryRelocate))
    #expect(names.contains(AutomationMethod.libraryRemove))
    #expect(names.contains(AutomationMethod.artworkSearch))
    #expect(names.contains(AutomationMethod.artworkGet))
    #expect(names.contains(AutomationMethod.artworkApply))

    let readOnly = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.libraryTracks)
    )
    #expect(readOnly.readOnly)
    #expect(!readOnly.requiresConfirmation)

    let mutation = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.playlistAddTracks)
    )
    #expect(!mutation.readOnly)
    #expect(!mutation.requiresConfirmation)
    guard case .object(let schema) = mutation.inputSchema else {
        Issue.record("mutation input schema must be an object")
        return
    }
    guard case .array(let required) = schema["required"] else {
        Issue.record("mutation schema must declare required IDs")
        return
    }
    #expect(required.contains(.string("playlistID")))
    #expect(required.contains(.string("trackIDs")))

    let sourceRefresh = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.sourceRefresh)
    )
    #expect(!sourceRefresh.requiresConfirmation)
    #expect(sourceRefresh.supportsJobs)
    #expect(!sourceRefresh.supportsTasks)

    let filesInspect = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.filesInspect)
    )
    #expect(filesInspect.readOnly)
    #expect(!filesInspect.requiresConfirmation)

    let filesRename = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.filesRename)
    )
    #expect(!filesRename.readOnly)
    #expect(filesRename.risk == .medium)
    #expect(filesRename.supportsDryRun)
    #expect(filesRename.supportsJobs)

    let filesMove = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.filesMove)
    )
    #expect(!filesMove.readOnly)
    #expect(filesMove.risk == .medium)
    #expect(filesMove.supportsDryRun)
    #expect(filesMove.supportsJobs)

    let filesDelete = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.filesDelete)
    )
    #expect(!filesDelete.readOnly)
    #expect(filesDelete.risk == .high)
    #expect(filesDelete.requiresConfirmation)
    #expect(filesDelete.supportsDryRun)
    #expect(filesDelete.supportsJobs)

    let libraryCreate = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.libraryCreate)
    )
    #expect(!libraryCreate.readOnly)
    #expect(libraryCreate.requiresConfirmation)
    #expect(libraryCreate.scopes == [.libraryManage])
    #expect(libraryCreate.supportsDryRun)
    guard case .object(let createSchema) = libraryCreate.inputSchema,
          case .array(let createRequired) = createSchema["required"] else {
        Issue.record("library.create must declare its required inputs")
        return
    }
    #expect(createRequired.contains(.string("mode")))
    #expect(createRequired.contains(.string("displayName")))

    for method in [
        AutomationMethod.libraryOpen,
        AutomationMethod.librarySwitch,
        AutomationMethod.libraryRename,
        AutomationMethod.libraryRelocate,
        AutomationMethod.libraryRemove
    ] {
        let descriptor = try #require(AutomationToolCatalog.descriptor(for: method))
        #expect(!descriptor.readOnly)
        #expect(descriptor.supportsDryRun)
        #expect(!descriptor.scopes.isEmpty)
    }
    let libraryRemove = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.libraryRemove)
    )
    #expect(libraryRemove.requiresConfirmation)
    #expect(libraryRemove.scopes == [.libraryDelete])

    let artworkGet = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.artworkGet)
    )
    #expect(artworkGet.readOnly)
    #expect(artworkGet.scopes == [.artworkRead, .libraryRead].sorted { $0.rawValue < $1.rawValue })

    let artworkSearch = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.artworkSearch)
    )
    #expect(artworkSearch.readOnly)
    #expect(!artworkSearch.requiresConfirmation)
    #expect(artworkSearch.scopes == [.artworkRead, .libraryRead].sorted { $0.rawValue < $1.rawValue })
    guard case .object(let artworkSearchSchema) = artworkSearch.inputSchema,
          case .array(let artworkSearchRequired) = artworkSearchSchema["required"] else {
        Issue.record("artwork.search must declare a required Track ID")
        return
    }
    #expect(artworkSearchRequired.contains(.string("trackID")))
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.artworkSearch,
            params: .object([
                "trackID": .string(UUID().uuidString),
                "limit": .number(5),
                "unexpected": .boolean(true)
            ])
        ) == ["unexpected"]
    )

    let artworkCandidate = AutomationArtworkCandidate(
        source: "qqmusic",
        sourceItemID: "album-mid",
        imageBase64: "aW1hZ2U=",
        imageMIMEType: "image/jpeg",
        byteCount: 5,
        originalByteCount: 120_000,
        width: 640,
        height: 640,
        resolution: 640,
        confidence: 0.91,
        matchedTitle: "Example",
        matchedArtist: "Artist",
        matchedAlbum: "Album",
        imageURL: "https://example.invalid/cover.jpg"
    )
    let artworkResult = AutomationArtworkSearchResult(
        trackID: UUID(),
        queryTitle: "Example",
        queryArtist: "Artist",
        queryAlbum: "Album",
        candidates: [artworkCandidate],
        message: "ok"
    )
    let artworkData = try AutomationWireCoding.encoder().encode(artworkResult)
    let decodedArtwork = try AutomationWireCoding.decoder().decode(
        AutomationArtworkSearchResult.self,
        from: artworkData
    )
    #expect(decodedArtwork == artworkResult)
    #expect(decodedArtwork.candidates.first?.originalByteCount == 120_000)

    let artworkApply = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.artworkApply)
    )
    #expect(!artworkApply.readOnly)
    #expect(artworkApply.requiresConfirmation)
    #expect(artworkApply.supportsDryRun)
    #expect(artworkApply.risk == .medium)
    guard case .object(let artworkSchema) = artworkApply.inputSchema,
          case .array(let artworkRequired) = artworkSchema["required"] else {
        Issue.record("artwork.apply must declare required Track IDs")
        return
    }
    #expect(artworkRequired.contains(.string("trackIDs")))
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.artworkApply,
            params: .object([
                "trackIDs": .array([]),
                "imageBase64": .string("..."),
                "unexpected": .boolean(true)
            ])
        ) == ["unexpected"]
    )

    for method in [
        AutomationMethod.sourceSetExcludedPath,
        AutomationMethod.sourceSetMonitorPolicy,
        AutomationMethod.settingsGet,
        AutomationMethod.settingsPatch,
        AutomationMethod.storageInspect,
        AutomationMethod.storageValidate,
        AutomationMethod.storageRepair
    ] {
        let descriptor = try #require(AutomationToolCatalog.descriptor(for: method))
        guard case .object(let schema) = descriptor.inputSchema,
              case .string("object") = schema["type"] else {
            Issue.record("\(method) must expose an object input schema")
            continue
        }
        #expect(!descriptor.scopes.isEmpty || method == AutomationMethod.settingsGet)
    }
}

@Test
func artworkAutomationResultRoundTripsAndMetadataFieldsDecodeDefaults() throws {
    let trackID = UUID()
    let artwork = AutomationArtworkMutationResult(
        applied: true,
        dryRun: false,
        confirmed: true,
        input: "imageBase64",
        updatedTrackIDs: [trackID],
        message: "updated"
    )
    let data = try AutomationWireCoding.encoder().encode(artwork)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationArtworkMutationResult.self,
        from: data
    )
    #expect(decoded == artwork)

    let summary = try AutomationWireCoding.decoder().decode(
        AutomationTrackSummary.self,
        from: Data(
            """
            {"id":"\(trackID.uuidString)","title":"T","artist":"A","album":"B",
             "duration":1,"availability":"available","addedAt":"2026-01-01T00:00:00Z"}
            """.replacingOccurrences(of: "\n", with: "").utf8
        )
    )
    #expect(summary.artistCredits.isEmpty)
    #expect(summary.userDescription.isEmpty)
    #expect(summary.lyricsTimeOffsetMs == 0)
    #expect(summary.artworkFileName == nil)
}

@Test
func libraryLifecycleContractRoundTripsAndRejectsUnknownTopLevelParameters() throws {
    let libraryID = UUID()
    let result = AutomationLibraryLifecycleResult(
        operation: AutomationMethod.librarySwitch,
        applied: true,
        dryRun: false,
        confirmed: true,
        libraryID: libraryID,
        library: AutomationLibrarySummary(
            id: libraryID,
            displayName: "Agent Test",
            mode: .referenced,
            isActive: true
        ),
        activeLibraryID: libraryID,
        path: "/tmp/Agent Test/kmgccc_player Library",
        unavailableSourceIDs: [UUID()],
        message: "switched"
    )
    let data = try AutomationWireCoding.encoder().encode(result)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationLibraryLifecycleResult.self,
        from: data
    )
    #expect(decoded == result)
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.libraryCreate,
            params: .object([
                "mode": .string("referenced"),
                "displayName": .string("Agent Test"),
                "unexpected": .boolean(true)
            ])
        ) == ["unexpected"]
    )
}

@Test
func strictToolParametersRejectUnknownTopLevelKeysWithoutClosingExtensionObjects() throws {
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.filesDelete,
            params: .object([
                "trackIDs": .array([]),
                "dryRun": .boolean(true),
                "dryrun": .boolean(true)
            ])
        ) == ["dryrun"]
    )
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.systemInfo,
            params: .object(["futureField": .string("not accepted")])
        ) == ["futureField"]
    )
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.metadataPatch,
            params: .object([
                "trackIDs": .array([]),
                "patch": .object(["futureMetadataField": .string("extension")]),
                "dryRun": .boolean(true)
            ])
        ).isEmpty
    )
}

@Test
func newSnapshotAndSourceFieldsRemainBackwardCompatibleWhenDecodingOldResponses() throws {
    let tracks = try AutomationWireCoding.decoder().decode(
        AutomationLibraryTracksResult.self,
        from: Data("{\"tracks\":[],\"total\":0,\"offset\":0,\"limit\":100}".utf8)
    )
    #expect(tracks.revision == "v1-unknown")

    let source = try AutomationWireCoding.decoder().decode(
        AutomationSourceCreateResult.self,
        from: Data("{\"applied\":false}".utf8)
    )
    #expect(source.playlistBindingApplied == false)
    #expect(source.completed)
}

@Test
func lyricsAutomationContractExposesSelectionAndRetrySemantics() throws {
    for method in [
        AutomationMethod.lyricsSearch,
        AutomationMethod.lyricsCandidates,
        AutomationMethod.lyricsCompare,
        AutomationMethod.lyricsApply,
        AutomationMethod.lyricsRefresh,
        AutomationMethod.jobsRetry
    ] {
        let descriptor = try #require(AutomationToolCatalog.descriptor(for: method))
        guard case .object(let schema) = descriptor.inputSchema,
              case .string("object") = schema["type"] else {
            Issue.record("\(method) must expose an object input schema")
            continue
        }
    }

    let lyricsApply = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.lyricsApply)
    )
    guard case .object(let lyricsApplySchema) = lyricsApply.inputSchema,
          case .array(let lyricsApplyRequired) = lyricsApplySchema["required"] else {
        Issue.record("lyrics.apply must declare a required Track ID")
        return
    }
    #expect(lyricsApplyRequired == [.string("trackID")])
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.lyricsApply,
            params: .object([
                "trackID": .string(UUID().uuidString),
                "ttmlText": .string("<tt></tt>"),
                "unexpected": .boolean(true)
            ])
        ) == ["unexpected"]
    )

    let candidate = AutomationLyricsCandidate(
        source: "AMLLDB",
        songID: "raw/example.ttml",
        score: 0.98,
        normalizedScore: 98,
        title: "Example",
        artist: "Artist",
        album: "Album",
        durationMs: 210_000,
        mode: "verbatim",
        extra: ["matchLevel": "exact"]
    )
    let comparison = AutomationLyricsComparisonResult(
        trackID: UUID(),
        currentStatus: "lineSynced",
        currentQuality: 1,
        candidate: candidate,
        candidateQuality: 2,
        shouldReplace: true,
        message: "replace"
    )
    let data = try AutomationWireCoding.encoder().encode(comparison)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationLyricsComparisonResult.self,
        from: data
    )
    #expect(decoded == comparison)
    #expect(decoded.candidate.id == "AMLLDB-raw/example.ttml")

    let customApply = AutomationLyricsApplyResult(
        trackID: UUID(),
        applied: true,
        dryRun: false,
        force: false,
        input: "ttmlText",
        candidate: nil,
        ttmlByteCount: 42,
        currentQuality: 1,
        candidateQuality: 2,
        message: "custom TTML applied"
    )
    let customData = try AutomationWireCoding.encoder().encode(customApply)
    let decodedCustom = try AutomationWireCoding.decoder().decode(
        AutomationLyricsApplyResult.self,
        from: customData
    )
    #expect(decodedCustom == customApply)
    #expect(decodedCustom.input == "ttmlText")
    #expect(decodedCustom.candidate == nil)
}

@Test
func storageAutomationContractExposesSafeFallbackOperations() throws {
    for method in [
        AutomationMethod.storageOrphans,
        AutomationMethod.storageBackup,
        AutomationMethod.storageDiff,
        AutomationMethod.storageReload
    ] {
        let descriptor = try #require(AutomationToolCatalog.descriptor(for: method))
        #expect(!descriptor.scopes.isEmpty)
        guard case .object(let schema) = descriptor.inputSchema,
              case .string("object") = schema["type"] else {
            Issue.record("\(method) must expose an object input schema")
            continue
        }
    }

    let issue = AutomationPlaylistReferenceIssue(
        playlistID: UUID(),
        playlistName: "Broken references",
        missingTrackIDs: [UUID()]
    )
    let result = AutomationStorageOrphansResult(
        libraryID: UUID(),
        playlistReferenceIssues: [issue],
        message: "inspect"
    )
    let data = try AutomationWireCoding.encoder().encode(result)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationStorageOrphansResult.self,
        from: data
    )
    #expect(decoded == result)
    #expect(decoded.orphanReferenceCount == 1)
}

@Test
func diagnosticsResultRemainsBackwardCompatibleWithoutExtendedEvidence() throws {
    let data = Data("""
    {"healthy":true,"libraryID":null,"trackCount":0,"playlistCount":0,"missingTrackCount":0,"unavailableTrackCount":0,"sourceCount":0,"sourceIssues":[],"runningJobCount":0,"checks":{}}
    """.utf8)
    let result = try AutomationWireCoding.decoder().decode(
        AutomationDiagnosticsResult.self,
        from: data
    )
    #expect(result.healthy)
    #expect(result.failedJobCount == 0)
    #expect(result.playlistReferenceIssues.isEmpty)
    #expect(result.storageValidation == "notRun")
}

@Test
func automationJobRetryResultKeepsOriginalAndNewJobIDs() throws {
    let originalID = UUID()
    let retryID = UUID()
    let job = AutomationJobSummary(
        id: retryID,
        kind: "enrichment",
        libraryID: UUID(),
        state: .queued,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        retryable: false
    )
    let result = AutomationJobRetryResult(
        originalJobID: originalID,
        accepted: true,
        job: job,
        message: "accepted"
    )
    let data = try AutomationWireCoding.encoder().encode(result)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationJobRetryResult.self,
        from: data
    )
    #expect(decoded == result)
    #expect(decoded.originalJobID == originalID)
    #expect(decoded.job?.id == retryID)
}

@Test
func sourceSummaryRemainsBackwardCompatibleWithoutExclusionField() throws {
    let id = UUID()
    let data = Data("""
    {"id":"\(id.uuidString)","mode":"directory","displayName":"Music","path":"/tmp/Music","status":"available","lastScan":null,"playlistIDs":[]}
    """.utf8)
    let summary = try AutomationWireCoding.decoder().decode(
        AutomationSourceSummary.self,
        from: data
    )
    #expect(summary.id == id)
    #expect(summary.excludedRelativePaths.isEmpty)
}

@Test
func playlistMutationResultRoundTripsOpaqueRevision() throws {
    let playlist = AutomationPlaylistSummary(
        id: UUID(),
        name: "Agent target",
        description: "Test",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        trackCount: 2,
        totalDuration: 321.5,
        revision: "v1-abc"
    )
    let result = AutomationPlaylistMutationResult(
        operation: AutomationMethod.playlistAddTracks,
        applied: false,
        dryRun: true,
        playlist: playlist,
        requestedTrackIDs: [UUID()],
        changedTrackIDs: [UUID()],
        skippedTrackIDs: [],
        message: "preview"
    )
    let data = try AutomationWireCoding.encoder().encode(result)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationPlaylistMutationResult.self,
        from: data
    )
    #expect(decoded == result)
    #expect(decoded.playlist?.revision == "v1-abc")
}

@Test
func unixSocketListenerRoundTripsARequest() async throws {
    let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("player-automation-\(UUID().uuidString)", isDirectory: false)
    let configuration = try AutomationIPCConfiguration(
        maximumFrameBytes: 4_096,
        maximumConcurrentConnections: 2,
        ioTimeout: 2
    )
    let listener = try AutomationIPCListener(
        socketPath: socketURL.path,
        configuration: configuration
    )
    try await listener.start { request in
        AutomationResponse.success(
            for: request,
            result: .object(["echo": .string(request.method)])
        )
    }
    defer {
        Task {
            await listener.stop()
        }
    }

    let client = try AutomationIPCClient(
        socketPath: socketURL.path,
        configuration: configuration
    )
    let request = AutomationRequest(method: AutomationMethod.systemPing)
    let response = try client.send(request)
    #expect(response.requestID == request.requestID)
    #expect(response.error == nil)
    #expect(response.result == .object(["echo": .string(AutomationMethod.systemPing)]))
}

@Test
func unixSocketHandshakeRejectsWrongSecretAndAcceptsCorrectSecret() async throws {
    let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pa-secret-\(UUID().uuidString.prefix(12))", isDirectory: false)
    let secret = Data("test-install-secret".utf8)
    let configuration = try AutomationIPCConfiguration(
        maximumFrameBytes: 4_096,
        maximumConcurrentConnections: 2,
        ioTimeout: 2,
        sharedSecret: secret
    )
    let listener = try AutomationIPCListener(
        socketPath: socketURL.path,
        configuration: configuration
    )
    try await listener.start { request in
        AutomationResponse.success(
            for: request,
            result: .object(["echo": .string(request.method)])
        )
    }
    defer {
        Task { await listener.stop() }
    }

    let wrongConfiguration = try AutomationIPCConfiguration(
        maximumFrameBytes: 4_096,
        maximumConcurrentConnections: 2,
        ioTimeout: 2,
        sharedSecret: Data("wrong-secret".utf8)
    )
    let wrongResponse = try AutomationIPCClient(
        socketPath: socketURL.path,
        configuration: wrongConfiguration
    ).send(AutomationRequest(method: AutomationMethod.systemPing))
    #expect(wrongResponse.error?.code == .authorizationRequired)

    let response = try AutomationIPCClient(
        socketPath: socketURL.path,
        configuration: configuration
    ).send(AutomationRequest(method: AutomationMethod.systemPing))
    #expect(response.error == nil)
    #expect(response.result == .object(["echo": .string(AutomationMethod.systemPing)]))
}

@Test
func secretStoreCreatesPrivateStableCredential() throws {
    let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pa-store-\(UUID().uuidString.prefix(12))", isDirectory: false)
    defer {
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }

    let first = try AutomationIPCSecretStore.loadOrCreate(forSocketPath: socketURL.path)
    let second = try AutomationIPCSecretStore.load(forSocketPath: socketURL.path)
    #expect(first.count == AutomationIPCSecretStore.defaultByteCount)
    #expect(second == first)

    var info = stat()
    #expect(lstat(try AutomationIPCSecretStore.url(forSocketPath: socketURL.path).path, &info) == 0)
    #expect((info.st_mode & mode_t(0o077)) == 0)
}
