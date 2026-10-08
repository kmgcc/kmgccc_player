import AVFoundation
import Foundation
import SwiftData
import XCTest
import PlayerAutomationIPC
import PlayerAutomationProtocol
@testable import kmgccc_player

@MainActor
final class AutomationJobIntegrationTests: XCTestCase {
    func testJobsWaitReportsTimeoutAndTerminalStateAndWaitCancellationLeavesJobRunning() async throws {
        try await withFixture { fixture in
            let gate = AutomationJobIntegrationGate()
            defer { gate.open() }

            let descriptor = try XCTUnwrap(
                fixture.session.startAutomationJob(totalCount: 1) { _ in
                    await gate.wait()
                }
            )
            let jobStarted = await awaitState(
                fixture.session,
                jobID: descriptor.id,
                state: .running
            )
            XCTAssertTrue(jobStarted)

            let timeoutResult = try await fixture.waitForJob(
                descriptor.id,
                timeoutMs: 50
            )
            XCTAssertFalse(timeoutResult.completed)
            XCTAssertTrue(timeoutResult.timedOut)
            XCTAssertEqual(timeoutResult.job.state, .running)

            let cancellation = AutomationIPCCancellationToken()
            let request = fixture.jobsWaitRequest(descriptor.id, timeoutMs: 20_000)
            let client = fixture.client
            let cancelledWait = Task.detached { () -> Bool in
                do {
                    _ = try client.sendClassified(
                        request,
                        timeout: 30,
                        cancellation: cancellation
                    )
                    return false
                } catch let error as AutomationIPCRequestError {
                    if case .outcomeUnknown = error {
                        return true
                    }
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            try await Task.sleep(for: .milliseconds(200))
            cancellation.cancel()
            let waitWasCancelled = await cancelledWait.value
            XCTAssertTrue(waitWasCancelled)
            XCTAssertEqual(
                fixture.session.libraryJobDescriptorsSnapshot()
                    .first(where: { $0.id == descriptor.id })?.state,
                .running,
                "Cancelling the IPC wait must not cancel its Job."
            )

            gate.open()
            let reachedTerminalState = await awaitState(
                fixture.session,
                jobID: descriptor.id,
                state: .completed
            )
            XCTAssertTrue(reachedTerminalState)

            let terminalResult = try await fixture.waitForJob(
                descriptor.id,
                timeoutMs: 0
            )
            XCTAssertTrue(terminalResult.completed)
            XCTAssertFalse(terminalResult.timedOut)
            XCTAssertEqual(terminalResult.job.state, .completed)

            let unknownResponse = try await fixture.send(fixture.jobsWaitRequest(
                UUID(),
                timeoutMs: 0
            ))
            XCTAssertEqual(unknownResponse.error?.code, .invalidRequest)
        }
    }

    func testOperationsBatchAppliesDistinctPatchesAndPreservesPreflightDryRunAndConflicts() async throws {
        try await withFixture { fixture in
            let tracks = await fixture.session.repository.fetchTracks(in: nil)
            XCTAssertEqual(tracks.count, 2)
            let first = try XCTUnwrap(tracks.first)
            let second = try XCTUnwrap(tracks.dropFirst().first)
            let originalFirstTitle = first.title
            let originalFirstArtist = first.artist
            let originalSecondTitle = second.title
            let originalSecondArtist = second.artist
            let firstRevision = fixture.session.libraryViewModel.automationTrackRevision(for: first)
            let secondRevision = fixture.session.libraryViewModel.automationTrackRevision(for: second)

            let jobsBeforePreflight = Set(
                fixture.session.libraryJobDescriptorsSnapshot().map(\.id)
            )
            let invalidBatch = AutomationRequest(
                method: AutomationMethod.operationsBatch,
                params: .object([
                    "operations": .array([
                        Self.patchOperation(
                            trackID: first.id,
                            patch: ["title": .string("must not apply")],
                            revision: firstRevision
                        ),
                        .object([
                            "method": .string("library.remove"),
                            "params": .object([:])
                        ])
                    ])
                ]),
                context: fixture.requestContext
            )
            let invalidResponse = try await fixture.send(invalidBatch)
            XCTAssertEqual(invalidResponse.error?.code, .invalidRequest)
            XCTAssertEqual(
                Set(fixture.session.libraryJobDescriptorsSnapshot().map(\.id)),
                jobsBeforePreflight,
                "An invalid child method must be rejected before a Job is created."
            )
            let afterPreflight = await fixture.session.repository.fetchTracks(in: nil)
            XCTAssertEqual(afterPreflight.first(where: { $0.id == first.id })?.title, originalFirstTitle)

            let dryRunSubmission = try await fixture.submitBatch(
                operations: [
                    Self.patchOperation(
                        trackID: first.id,
                        patch: ["title": .string("dry-run title")],
                        revision: firstRevision
                    )
                ],
                dryRun: true
            )
            let dryRun = try await fixture.waitForJob(dryRunSubmission.job.id, timeoutMs: 5_000)
            XCTAssertEqual(dryRun.job.state, .completed)
            let dryRunFields = try XCTUnwrap(Self.objectFields(dryRun.job.result))
            XCTAssertEqual(dryRunFields["dryRun"], .boolean(true))
            let dryRunItem = try XCTUnwrap(Self.firstBatchItemResponseResult(dryRun.job.result))
            XCTAssertEqual(dryRunItem["dryRun"], .boolean(true))
            XCTAssertEqual(dryRunItem["applied"], .boolean(false))

            let afterDryRun = await fixture.session.repository.fetchTracks(in: nil)
            XCTAssertEqual(afterDryRun.first(where: { $0.id == first.id })?.title, originalFirstTitle)
            XCTAssertEqual(afterDryRun.first(where: { $0.id == second.id })?.artist, originalSecondArtist)

            let successfulSubmission = try await fixture.submitBatch(operations: [
                Self.patchOperation(
                    trackID: first.id,
                    patch: ["title": .string("Batch title A")],
                    revision: firstRevision
                ),
                Self.patchOperation(
                    trackID: second.id,
                    patch: ["artist": .string("Batch artist B")],
                    revision: secondRevision
                )
            ])
            let successfulBatch = try await fixture.waitForJob(
                successfulSubmission.job.id,
                timeoutMs: 5_000
            )
            XCTAssertEqual(successfulBatch.job.state, .completed)
            let successfulFields = try XCTUnwrap(Self.objectFields(successfulBatch.job.result))
            XCTAssertEqual(Self.integer(successfulFields["requestedCount"]), 2)
            XCTAssertEqual(Self.integer(successfulFields["completedCount"]), 2)
            XCTAssertEqual(Self.integer(successfulFields["failedCount"]), 0)

            let afterSuccessfulBatch = await fixture.session.repository.fetchTracks(in: nil)
            XCTAssertEqual(afterSuccessfulBatch.first(where: { $0.id == first.id })?.title, "Batch title A")
            XCTAssertEqual(afterSuccessfulBatch.first(where: { $0.id == first.id })?.artist, originalFirstArtist)
            XCTAssertEqual(afterSuccessfulBatch.first(where: { $0.id == second.id })?.title, originalSecondTitle)
            XCTAssertEqual(afterSuccessfulBatch.first(where: { $0.id == second.id })?.artist, "Batch artist B")

            let updatedSecond = try XCTUnwrap(afterSuccessfulBatch.first(where: { $0.id == second.id }))
            let currentSecondRevision = fixture.session.libraryViewModel.automationTrackRevision(for: updatedSecond)
            let conflictSubmission = try await fixture.submitBatch(operations: [
                Self.patchOperation(
                    trackID: first.id,
                    patch: ["title": .string("stale overwrite")],
                    revision: "v1-deliberately-stale"
                ),
                Self.patchOperation(
                    trackID: second.id,
                    patch: ["album": .string("Batch album B")],
                    revision: currentSecondRevision
                )
            ])
            let conflictedBatch = try await fixture.waitForJob(
                conflictSubmission.job.id,
                timeoutMs: 5_000
            )
            XCTAssertEqual(conflictedBatch.job.state, .partialFailure)
            let conflictFields = try XCTUnwrap(Self.objectFields(conflictedBatch.job.result))
            XCTAssertEqual(Self.integer(conflictFields["conflictCount"]), 1)
            XCTAssertEqual(
                Self.strings(conflictFields["conflictedTrackIDs"]),
                [first.id.uuidString]
            )

            let afterConflict = await fixture.session.repository.fetchTracks(in: nil)
            XCTAssertEqual(afterConflict.first(where: { $0.id == first.id })?.title, "Batch title A")
            XCTAssertEqual(afterConflict.first(where: { $0.id == second.id })?.album, "Batch album B")
        }
    }

    func testDomainDispatchAndGlobalValidationRetainIPCContract() async throws {
        try await withFixture { fixture in
            let methods = [
                AutomationMethod.systemPing, AutomationMethod.systemInfo,
                AutomationMethod.libraryList, AutomationMethod.libraryStats,
                AutomationMethod.playlistList, AutomationMethod.playbackState,
                AutomationMethod.queueGet, AutomationMethod.queueUpcoming,
                AutomationMethod.historyList, AutomationMethod.historyStats,
                AutomationMethod.jobsList, AutomationMethod.settingsGet,
                AutomationMethod.settingsSchema, AutomationMethod.audioGet,
                AutomationMethod.storageInspect, AutomationMethod.automationCapabilities,
                AutomationMethod.automationScopes
            ]
            for method in methods {
                let request = AutomationRequest(method: method, context: fixture.requestContext)
                let response = try await fixture.send(request)
                XCTAssertNil(response.error, method)
                XCTAssertNotNil(response.result, method)
                XCTAssertEqual(response.requestID, request.requestID, method)
            }
            let track = try XCTUnwrap(fixture.session.libraryViewModel.allTracks.first)
            for method in [AutomationMethod.metadataGet, AutomationMethod.artworkGet, AutomationMethod.lyricsGet] {
                let response = try await fixture.send(AutomationRequest(
                    method: method,
                    params: .object(["trackID": .string(track.id.uuidString)]),
                    context: fixture.requestContext
                ))
                XCTAssertNil(response.error, method)
                XCTAssertNotNil(response.result, method)
            }
            let fileParams: AutomationJSONValue = .object(["trackIDs": .array([.string(track.id.uuidString)])])
            let denied = try await fixture.send(AutomationRequest(
                method: AutomationMethod.filesDelete, params: fileParams, context: fixture.requestContext
            ))
            XCTAssertEqual(denied.error?.code, .authorizationRequired)
            let unknownParameters = try await fixture.send(AutomationRequest(
                method: AutomationMethod.filesDelete,
                params: .object(["unknown": .boolean(true)]), context: fixture.requestContext
            ))
            XCTAssertEqual(unknownParameters.error?.code, .invalidRequest,
                           "Unknown parameters must still precede scope denial.")
            let preview = try await fixture.send(AutomationRequest(
                method: AutomationMethod.filesDelete,
                params: .object(["trackIDs": .array([.string(track.id.uuidString)]), "dryRun": .boolean(true)]),
                context: fixture.requestContext
            ))
            XCTAssertEqual(preview.error?.code, .invalidRequest,
                           "The managed Library restriction follows the dry-run delete-scope exemption.")
            let wrongLibrary = try await fixture.send(AutomationRequest(
                method: AutomationMethod.queueGet,
                context: AutomationRequestContext(libraryID: UUID(), caller: "test")
            ))
            XCTAssertEqual(wrongLibrary.error?.code, .libraryNotActive)
            let unknownMethod = try await fixture.send(AutomationRequest(
                method: "unknown.operation", context: fixture.requestContext
            ))
            XCTAssertEqual(unknownMethod.error?.code, .methodNotFound)
        }
    }

    func testIdempotencyAndPlaylistSelectionRetainIPCBehavior() async throws {
        try await withFixture { fixture in
            let context = AutomationRequestContext(
                libraryID: fixture.session.context.id, idempotencyKey: UUID().uuidString, caller: "test"
            )
            let params: AutomationJSONValue = .object(["name": .string("Idempotent Playlist")])
            let first = try await fixture.send(AutomationRequest(
                method: AutomationMethod.playlistCreate, params: params, context: context
            ))
            XCTAssertNil(first.error)
            let replayRequest = AutomationRequest(method: AutomationMethod.playlistCreate, params: params, context: context)
            let replay = try await fixture.send(replayRequest)
            XCTAssertEqual(replay.requestID, replayRequest.requestID)
            XCTAssertEqual(replay.result, first.result)
            XCTAssertEqual(replay.serverTime, first.serverTime)
            XCTAssertEqual(fixture.session.libraryViewModel.playlists.filter { $0.name == "Idempotent Playlist" }.count, 1)
            let conflict = try await fixture.send(AutomationRequest(
                method: AutomationMethod.playlistCreate,
                params: .object(["name": .string("Different Playlist")]), context: context
            ))
            XCTAssertEqual(conflict.error?.code, .invalidRequest)
            let playlist = try XCTUnwrap(fixture.session.libraryViewModel.playlists.first { $0.name == "Idempotent Playlist" })
            let trackIDs = fixture.session.libraryViewModel.allTracks.map(\.id)
            let selectionResponse = try await fixture.send(AutomationRequest(
                method: AutomationMethod.librarySelectionCreate,
                params: .object(["trackIDs": .array(trackIDs.map { .string($0.uuidString) })]),
                context: fixture.requestContext
            ))
            XCTAssertNil(selectionResponse.error)
            let selections = try await fixture.send(AutomationRequest(
                method: AutomationMethod.librarySelectionList, context: fixture.requestContext
            ))
            let data = try AutomationWireCoding.encoder().encode(try XCTUnwrap(selections.result))
            let result = try AutomationWireCoding.decoder().decode(AutomationSelectionListResult.self, from: data)
            let selection = try XCTUnwrap(result.selections.first)
            let preview = try await fixture.send(AutomationRequest(
                method: AutomationMethod.playlistAddSelection,
                params: .object([
                    "playlistID": .string(playlist.id.uuidString),
                    "selectionID": .string(selection.id.uuidString),
                    "expectedSelectionRevision": .string(selection.revision),
                    "dryRun": .boolean(true)
                ]), context: fixture.requestContext
            ))
            XCTAssertNil(preview.error)
            XCTAssertTrue(playlist.tracks.isEmpty)
            let mutation = try await fixture.send(AutomationRequest(
                method: AutomationMethod.playlistAddSelection,
                params: .object([
                    "playlistID": .string(playlist.id.uuidString),
                    "selectionID": .string(selection.id.uuidString),
                    "expectedSelectionRevision": .string(selection.revision)
                ]), context: fixture.requestContext
            ))
            XCTAssertNil(mutation.error)
            XCTAssertEqual(playlist.tracks.map(\.id), trackIDs)
        }
    }

    func testFileWorkerCopyPreservesCollisionNamesAndMissingFileErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source/Audio.wav")
        let destination = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: source)
        try bytes.write(to: destination.appendingPathComponent("Audio.wav"))
        let worker = AutomationFileWorker()
        let trackID = UUID()
        async let first = worker.copy(source: source, trackID: trackID, to: destination)
        async let second = worker.copy(source: source, trackID: trackID, to: destination)
        let outputs = try await [first, second]
        XCTAssertEqual(outputs.map(\.lastPathComponent).sorted(), ["Audio (2).wav", "Audio (3).wav"])
        for output in outputs { XCTAssertEqual(try Data(contentsOf: output), bytes) }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        do {
            _ = try await worker.copy(source: root.appendingPathComponent("missing.wav"), trackID: trackID, to: destination)
            XCTFail("A missing source must fail.")
        } catch AutomationFileOperationError.fileUnavailable(let failedID) {
            XCTAssertEqual(failedID, trackID)
        }
    }

    func testFileWorkerMoveRestoresEarlierFilesAfterPartialFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.wav")
        let destination = root.appendingPathComponent("moved/audio.wav")
        let bytes = Data([4, 3, 2, 1])
        try bytes.write(to: source)
        do {
            try await AutomationFileWorker().move([
                .init(from: source, destination: destination),
                .init(from: root.appendingPathComponent("missing.wav"), destination: root.appendingPathComponent("other.wav"))
            ])
            XCTFail("The second move must fail.")
        } catch AutomationFileOperationError.operationFailed {
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testLibraryQuiesceWaitsForFileIOCompletionAfterCancellation() async throws {
        try await withFixture { fixture in
            let queue = DispatchQueue(label: "automation.file-test-gate")
            queue.suspend()
            var queueNeedsResume = true
            defer { if queueNeedsResume { queue.resume() } }
            let worker = AutomationFileWorker(queue: queue)
            let destination = fixture.rootURL.appendingPathComponent("export")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let source = fixture.rootURL.appendingPathComponent("Audio/First.wav")
            let task = Task { @MainActor in
                try await fixture.session.runLibraryOperation(as: .other) {
                    try await worker.copy(source: source, trackID: UUID(), to: destination)
                }
            }
            var descriptor: LibraryOperationTaskDescriptor?
            for _ in 0..<200 {
                descriptor = fixture.session.libraryJobDescriptorsSnapshot().first { $0.kind == .other && $0.state == .running }
                if descriptor != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            _ = try XCTUnwrap(descriptor)
            var didQuiesce = false
            let quiesce = Task { @MainActor in
                await fixture.session.quiesce()
                didQuiesce = true
            }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(didQuiesce, "Library access must remain alive while a queued copy owns it.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("First.wav").path))
            queue.resume()
            queueNeedsResume = false
            let output = try await task.value
            await quiesce.value
            XCTAssertTrue(didQuiesce)
            XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: source))
        }
    }

    private func withFixture(
        _ work: @MainActor (AutomationJobIPCFixture) async throws -> Void
    ) async throws {
        let fixture = try await AutomationJobIPCFixture.make()
        do {
            try await work(fixture)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    private func awaitState(
        _ session: LibrarySession,
        jobID: UUID,
        state: LibraryTaskState
    ) async -> Bool {
        for _ in 0..<200 {
            if session.libraryJobDescriptorsSnapshot().first(where: { $0.id == jobID })?.state == state {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return session.libraryJobDescriptorsSnapshot().first(where: { $0.id == jobID })?.state == state
    }

    private static func patchOperation(
        trackID: UUID,
        patch: [String: AutomationJSONValue],
        revision: String
    ) -> AutomationJSONValue {
        .object([
            "method": .string(AutomationMethod.metadataPatch),
            "params": .object([
                "trackIDs": .array([.string(trackID.uuidString)]),
                "patch": .object(patch),
                "expectedRevisions": .object([trackID.uuidString: .string(revision)])
            ])
        ])
    }

    private static func objectFields(_ value: AutomationJSONValue?) -> [String: AutomationJSONValue]? {
        guard case .object(let fields)? = value else { return nil }
        return fields
    }

    private static func firstBatchItemResponseResult(
        _ value: AutomationJSONValue?
    ) -> [String: AutomationJSONValue]? {
        guard let fields = objectFields(value),
              case .array(let items)? = fields["items"],
              let first = items.first,
              let item = objectFields(first),
              let response = objectFields(item["response"])
        else { return nil }
        return objectFields(response["result"])
    }

    private static func integer(_ value: AutomationJSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return Int(number)
    }

    private static func strings(_ value: AutomationJSONValue?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        return items.map { item in
            guard case .string(let string) = item else { return "" }
            return string
        }
    }
}

@MainActor
private final class AutomationJobIPCFixture {
    let rootURL: URL
    let session: LibrarySession
    let server: AutomationIPCServer
    let client: AutomationIPCClient
    let requestContext: AutomationRequestContext
    private var didClose = false

    private init(
        rootURL: URL,
        session: LibrarySession,
        server: AutomationIPCServer,
        client: AutomationIPCClient
    ) {
        self.rootURL = rootURL
        self.session = session
        self.server = server
        self.client = client
        requestContext = AutomationRequestContext(libraryID: session.context.id, caller: "test")
    }

    static func make() async throws -> AutomationJobIPCFixture {
        let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("kmgjob-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("Audio", isDirectory: true)
        let libraryParentURL = rootURL.appendingPathComponent("Libraries", isDirectory: true)
        let supportURL = rootURL.appendingPathComponent("AppSupport", isDirectory: true)
        let socketDirectoryURL = rootURL.appendingPathComponent("IPC", isDirectory: true)
        let fileManager = FileManager.default
        var host: AppSessionHost?
        var session: LibrarySession?
        var server: AutomationIPCServer?
        do {
            try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: libraryParentURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: socketDirectoryURL, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectoryURL.path)
            try writeWAV(to: sourceURL.appendingPathComponent("First.wav"))
            try writeWAV(to: sourceURL.appendingPathComponent("Second.wav"))

            let schema = Schema([TrackIndexEntry.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let registryURL = rootURL.appendingPathComponent("Registry.json")
            let createdHost = AppSessionHost(
                modelContainer: container,
                initialLibraryContext: nil,
                registryStore: try kmgccc_player.MusicLibraryRegistryStore(fileURL: registryURL),
                sessionFactory: LibrarySessionFactory()
            )
            host = createdHost
            _ = try await createdHost.createMusicLibrary(
                mode: .managed,
                parentURL: libraryParentURL,
                displayName: "Automation Job Tests",
                initialImportSelection: nil
            )
            guard let activeSession = createdHost.activeLibraryBinding.activeSession else {
                throw AutomationJobIntegrationError.activeLibraryUnavailable
            }
            session = activeSession

            let importContext = LibraryImportContext(
                libraryID: activeSession.context.id,
                sessionGeneration: activeSession.context.generation,
                destination: .libraryOnly,
                origin: .automation,
                enrichmentPolicy: .migration
            )
            let importResult = await activeSession.fileImportService.importSelectedURLs(
                [sourceURL],
                context: importContext
            )
            guard importResult.importedTrackCount == 2, importResult.failures.isEmpty else {
                throw AutomationJobIntegrationError.fixtureTracksCouldNotBeImported
            }
            await activeSession.libraryViewModel.syncVisibleStateFromRepositoryAfterImport()

            let socketURL = socketDirectoryURL.appendingPathComponent("automation.sock")
            let bundleIdentifier = "com.kmgccc.player.tests.\(UUID().uuidString.lowercased())"
            let createdServer = try AutomationIPCServer(
                appSession: createdHost,
                bundleIdentifier: bundleIdentifier,
                socketURL: socketURL,
                appSupportDirectoryURL: supportURL,
                ioTimeout: 30
            )
            server = createdServer
            try await createdServer.start()
            let secret = try AutomationIPCSecretStore.load(forSocketPath: socketURL.path)
            let clientConfiguration = try AutomationIPCConfiguration(
                ioTimeout: 30,
                sharedSecret: secret
            )
            let client = try AutomationIPCClient(
                socketPath: socketURL.path,
                configuration: clientConfiguration,
                clientIDHint: "automation-job-integration-tests",
                displayName: "Automation Job integration tests"
            )
            return AutomationJobIPCFixture(
                rootURL: rootURL,
                session: activeSession,
                server: createdServer,
                client: client
            )
        } catch {
            await server?.stop()
            if let activeSession = session ?? host?.activeLibraryBinding.activeSession {
                await activeSession.quiesce()
                await activeSession.close()
            }
            try? fileManager.removeItem(at: rootURL)
            throw error
        }
    }

    func send(
        _ request: AutomationRequest,
        cancellation: AutomationIPCCancellationToken? = nil
    ) async throws -> AutomationResponse {
        let client = self.client
        return try await Task.detached(priority: .userInitiated) {
            try client.send(request, timeout: 30, cancellation: cancellation)
        }.value
    }

    func jobsWaitRequest(_ jobID: UUID, timeoutMs: Int) -> AutomationRequest {
        AutomationRequest(
            method: AutomationMethod.jobsWait,
            params: .object([
                "jobID": .string(jobID.uuidString),
                "timeoutMs": .number(Double(timeoutMs))
            ]),
            context: requestContext
        )
    }

    func waitForJob(_ jobID: UUID, timeoutMs: Int) async throws -> AutomationJobWaitResult {
        let response = try await send(jobsWaitRequest(jobID, timeoutMs: timeoutMs))
        guard response.error == nil, let result = response.result else {
            throw AutomationJobIntegrationError.responseDidNotContainResult
        }
        let data = try AutomationWireCoding.encoder().encode(result)
        return try AutomationWireCoding.decoder().decode(AutomationJobWaitResult.self, from: data)
    }

    func submitBatch(
        operations: [AutomationJSONValue],
        dryRun: Bool = false
    ) async throws -> AutomationJobSubmissionResult {
        var params: [String: AutomationJSONValue] = ["operations": .array(operations)]
        if dryRun { params["dryRun"] = .boolean(true) }
        let response = try await send(AutomationRequest(
            method: AutomationMethod.operationsBatch,
            params: .object(params),
            context: requestContext
        ))
        guard response.error == nil, let result = response.result else {
            throw AutomationJobIntegrationError.responseDidNotContainResult
        }
        let data = try AutomationWireCoding.encoder().encode(result)
        return try AutomationWireCoding.decoder().decode(AutomationJobSubmissionResult.self, from: data)
    }

    func close() async {
        guard !didClose else { return }
        didClose = true
        await server.stop()
        await session.quiesce()
        await session.close()
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func writeWAV(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410) else {
            throw AutomationJobIntegrationError.audioFixtureCouldNotBeCreated
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        buffer.frameLength = 4_410
        try file.write(from: buffer)
    }
}

private final class AutomationJobIntegrationGate: @unchecked Sendable {
    private let pair = AsyncStream<Void>.makeStream()

    func wait() async {
        for await _ in pair.stream {
            break
        }
    }

    func open() {
        pair.continuation.yield(())
        pair.continuation.finish()
    }
}

private enum AutomationJobIntegrationError: Error {
    case activeLibraryUnavailable
    case fixtureTracksCouldNotBeImported
    case responseDidNotContainResult
    case audioFixtureCouldNotBeCreated
}
