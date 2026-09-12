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
