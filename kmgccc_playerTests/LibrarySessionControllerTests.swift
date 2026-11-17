import AppKit
import SwiftData
import XCTest
@testable import kmgccc_player

@MainActor
final class LibrarySessionControllerTests: XCTestCase {
    func testSuccessfulSwitchFollowsLifecycleOrder() async throws {
        let events = EventLog()
        let old = FakeSession(context: context(id: UUID()), events: events, label: "old")
        let targetContext = context(id: UUID())
        let target = FakeSession(context: targetContext, events: events, label: "target")
        let factory = FakeSessionFactory(sessions: [targetContext.id: [target]])
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(old)
        controller.willReleaseActiveSession = { events.append("binding.release") }
        controller.didActivateSession = { _ in events.append("binding.publish") }

        try await controller.switchToLibrary(targetContext)

        XCTAssertEqual(
            events.values,
            ["old.flush", "old.quiesce", "binding.release", "old.close", "target.load", "binding.publish"]
        )
        XCTAssertEqual(controller.state, .active(targetContext.id))
        XCTAssertTrue(controller.activeSession === target)
    }

    func testTargetPreparationFailureLeavesOldSessionActive() async {
        let old = FakeSession(context: context(id: UUID()), label: "old")
        let targetContext = context(id: UUID())
        let factory = FakeSessionFactory(sessions: [:])
        factory.makeErrors[targetContext.id] = TestFailure.expected
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(old)

        await XCTAssertThrowsErrorAsync {
            try await controller.switchToLibrary(targetContext)
        }

        XCTAssertEqual(controller.state, .active(old.context.id))
        XCTAssertTrue(controller.activeSession === old)
        XCTAssertEqual(old.events.values, [])
    }

    func testOldFlushFailureDoesNotQuiesceOrReleaseOldSession() async {
        let old = FakeSession(context: context(id: UUID()), label: "old")
        old.flushError = TestFailure.expected
        let targetContext = context(id: UUID())
        let target = FakeSession(context: targetContext, label: "target")
        let factory = FakeSessionFactory(sessions: [targetContext.id: [target]])
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(old)

        await XCTAssertThrowsErrorAsync {
            try await controller.switchToLibrary(targetContext)
        }

        XCTAssertEqual(old.events.values, ["old.flush"])
        XCTAssertEqual(target.events.values, ["target.close"])
        XCTAssertEqual(controller.state, .active(old.context.id))
        XCTAssertTrue(controller.activeSession === old)
    }

    func testTargetLoadFailureRebuildsPreviousSession() async {
        let oldContext = context(id: UUID())
        let old = FakeSession(context: oldContext, label: "old")
        let targetContext = context(id: UUID())
        let target = FakeSession(context: targetContext, label: "target")
        target.loadError = TestFailure.expected
        let restored = FakeSession(context: oldContext, label: "restored")
        let factory = FakeSessionFactory(
            sessions: [
                targetContext.id: [target],
                oldContext.id: [restored],
            ]
        )
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(old)

        await XCTAssertThrowsErrorAsync(expected: LibrarySessionControllerError.targetLoadFailed) {
            try await controller.switchToLibrary(targetContext)
        }

        XCTAssertEqual(old.events.values, ["old.flush", "old.quiesce", "old.close"])
        XCTAssertEqual(target.events.values, ["target.load", "target.close"])
        XCTAssertEqual(restored.events.values, ["restored.load"])
        XCTAssertEqual(controller.state, .active(oldContext.id))
        XCTAssertTrue(controller.activeSession === restored)
    }

    func testNewerSwitchSupersedesPreparationBeforeOldSessionIsTouched() async throws {
        let old = FakeSession(context: context(id: UUID()), label: "old")
        let firstContext = context(id: UUID())
        let secondContext = context(id: UUID())
        let first = FakeSession(context: firstContext, label: "first")
        let second = FakeSession(context: secondContext, label: "second")
        let factory = FakeSessionFactory(
            sessions: [firstContext.id: [first], secondContext.id: [second]]
        )
        factory.suspendedContextIDs.insert(firstContext.id)
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(old)

        let firstTask = Task { try await controller.switchToLibrary(firstContext) }
        await factory.waitUntilSuspended(firstContext.id)
        try await controller.switchToLibrary(secondContext)
        factory.resume(firstContext.id)

        await XCTAssertThrowsErrorAsync(expected: LibrarySessionControllerError.superseded) {
            try await firstTask.value
        }

        XCTAssertEqual(controller.state, .active(secondContext.id))
        XCTAssertTrue(controller.activeSession === second)
        XCTAssertEqual(first.events.values, ["first.close"])
    }

    func testSwitchToCurrentLibraryIsNoOp() async throws {
        let current = FakeSession(context: context(id: UUID()), label: "current")
        let factory = FakeSessionFactory(sessions: [:])
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(current)

        try await controller.switchToLibrary(current.context)

        XCTAssertTrue(controller.activeSession === current)
        XCTAssertEqual(controller.state, .active(current.context.id))
        XCTAssertTrue(factory.madeContextIDs.isEmpty)
        XCTAssertTrue(current.events.values.isEmpty)
    }

    func testCloseWaitsForDestructiveSwitchAndClosesPublishedTarget() async throws {
        let old = FakeSession(context: context(id: UUID()), label: "old")
        old.suspendQuiesce = true
        let targetContext = context(id: UUID())
        let target = FakeSession(context: targetContext, label: "target")
        let factory = FakeSessionFactory(sessions: [targetContext.id: [target]])
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(old)

        let switchTask = Task { try await controller.switchToLibrary(targetContext) }
        await old.waitUntilQuiesceSuspended()
        let closeTask = Task { try await controller.closeActiveSession() }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(target.events.values, [])
        old.resumeQuiesce()
        try await switchTask.value
        try await closeTask.value

        XCTAssertNil(controller.activeSession)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(target.events.values, ["target.load", "target.flush", "target.quiesce", "target.close"])
    }

    func testNewSwitchWaitsUntilDestructiveLoadFinishes() async throws {
        let old = FakeSession(context: context(id: UUID()), label: "old")
        let firstContext = context(id: UUID())
        let secondContext = context(id: UUID())
        let first = FakeSession(context: firstContext, label: "first")
        first.suspendLoad = true
        let second = FakeSession(context: secondContext, label: "second")
        let factory = FakeSessionFactory(
            sessions: [firstContext.id: [first], secondContext.id: [second]]
        )
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(old)

        let firstTask = Task { try await controller.switchToLibrary(firstContext) }
        await first.waitUntilLoadSuspended()
        let secondTask = Task { try await controller.switchToLibrary(secondContext) }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(factory.madeContextIDs, [firstContext.id])
        first.resumeLoad()
        try await firstTask.value
        try await secondTask.value

        XCTAssertEqual(controller.state, .active(secondContext.id))
        XCTAssertTrue(controller.activeSession === second)
        XCTAssertEqual(factory.madeContextIDs, [firstContext.id, secondContext.id])
    }

    func testSelectingCurrentLibrarySupersedesPendingPreparation() async throws {
        let current = FakeSession(context: context(id: UUID()), label: "current")
        let pendingContext = context(id: UUID())
        let pending = FakeSession(context: pendingContext, label: "pending")
        let factory = FakeSessionFactory(sessions: [pendingContext.id: [pending]])
        factory.suspendedContextIDs.insert(pendingContext.id)
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(current)

        let task = Task { try await controller.switchToLibrary(pendingContext) }
        await factory.waitUntilSuspended(pendingContext.id)
        try await controller.switchToLibrary(current.context)
        factory.resume(pendingContext.id)
        await XCTAssertThrowsErrorAsync(expected: .superseded) { try await task.value }

        XCTAssertTrue(controller.activeSession === current)
        XCTAssertTrue(current.events.values.isEmpty)
        XCTAssertEqual(pending.events.values, ["pending.close"])
    }

    func testFirstLoadSerializesLaterSwitchWithoutInitialSession() async throws {
        let firstContext = context(id: UUID())
        let secondContext = context(id: UUID())
        let first = FakeSession(context: firstContext, label: "first")
        first.suspendLoad = true
        let second = FakeSession(context: secondContext, label: "second")
        let factory = FakeSessionFactory(sessions: [firstContext.id: [first], secondContext.id: [second]])
        let controller = LibrarySessionController(factory: factory)

        let firstTask = Task { try await controller.switchToLibrary(firstContext) }
        await first.waitUntilLoadSuspended()
        let secondTask = Task { try await controller.switchToLibrary(secondContext) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(factory.madeContextIDs, [firstContext.id])
        first.resumeLoad()
        try await firstTask.value
        try await secondTask.value

        XCTAssertTrue(controller.activeSession === second)
        XCTAssertEqual(first.events.values, ["first.load", "first.flush", "first.quiesce", "first.close"])
    }

    func testFirstPublicationFinishesBeforeCloseReleasesBindings() async throws {
        let targetContext = context(id: UUID())
        let target = FakeSession(context: targetContext, label: "target")
        let publication = FakeSession(context: targetContext, label: "publication")
        publication.suspendQuiesce = true
        let controller = LibrarySessionController(factory: FakeSessionFactory(sessions: [targetContext.id: [target]]))
        controller.didActivateSession = { _ in await publication.quiesce() }

        let openTask = Task { try await controller.switchToLibrary(targetContext) }
        await publication.waitUntilQuiesceSuspended()
        let closeTask = Task { try await controller.closeActiveSession() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(target.events.values, ["target.load"])
        publication.resumeQuiesce()
        try await openTask.value
        try await closeTask.value

        XCTAssertNil(controller.activeSession)
        XCTAssertEqual(controller.state, .idle)
    }

    func testSupersededPreparationFailureCannotOverwriteNewLoadingState() async throws {
        let old = FakeSession(context: context(id: UUID()), label: "old")
        let failedContext = context(id: UUID())
        let latestContext = context(id: UUID())
        let latest = FakeSession(context: latestContext, label: "latest")
        latest.suspendLoad = true
        let factory = FakeSessionFactory(sessions: [latestContext.id: [latest]])
        factory.suspendedContextIDs.insert(failedContext.id)
        factory.makeErrors[failedContext.id] = TestFailure.expected
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(old)

        let failedTask = Task { try await controller.switchToLibrary(failedContext) }
        await factory.waitUntilSuspended(failedContext.id)
        let latestTask = Task { try await controller.switchToLibrary(latestContext) }
        await latest.waitUntilLoadSuspended()
        factory.resume(failedContext.id)
        await XCTAssertThrowsErrorAsync(expected: .superseded) { try await failedTask.value }
        XCTAssertEqual(controller.state, .loading(latestContext.id))
        latest.resumeLoad()
        try await latestTask.value
        XCTAssertTrue(controller.activeSession === latest)
    }

    func testCancelledPreparationClosesCandidateAndKeepsCurrentSession() async throws {
        let current = FakeSession(context: context(id: UUID()), label: "current")
        let targetContext = context(id: UUID())
        let target = FakeSession(context: targetContext, label: "target")
        let factory = FakeSessionFactory(sessions: [targetContext.id: [target]])
        factory.suspendedContextIDs.insert(targetContext.id)
        let controller = LibrarySessionController(factory: factory)
        controller.installInitialSession(current)

        let task = Task { try await controller.switchToLibrary(targetContext) }
        await factory.waitUntilSuspended(targetContext.id)
        task.cancel()
        factory.resume(targetContext.id)
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }

        XCTAssertTrue(controller.activeSession === current)
        XCTAssertEqual(controller.state, .active(current.context.id))
        XCTAssertTrue(current.events.values.isEmpty)
        XCTAssertEqual(target.events.values, ["target.close"])
    }

    func testFailedRecoveryClosesRestoredSessionResources() async {
        let old = FakeSession(context: context(id: UUID()), label: "old")
        let targetContext = context(id: UUID())
        let target = FakeSession(context: targetContext, label: "target")
        target.loadError = TestFailure.expected
        let restored = FakeSession(context: old.context, label: "restored")
        restored.loadError = TestFailure.expected
        let controller = LibrarySessionController(factory: FakeSessionFactory(sessions: [
            targetContext.id: [target], old.context.id: [restored]
        ]))
        controller.installInitialSession(old)

        await XCTAssertThrowsErrorAsync(expected: .targetAndRecoveryFailed) {
            try await controller.switchToLibrary(targetContext)
        }
        XCTAssertNil(controller.activeSession)
        XCTAssertEqual(controller.state, .unavailable(old.context.id))
        XCTAssertEqual(restored.events.values, ["restored.load", "restored.close"])
    }

    func testCancellationDuringLoadDoesNotCancelRecovery() async throws {
        let old = FakeSession(context: context(id: UUID()), label: "old")
        let targetContext = context(id: UUID())
        let target = FakeSession(context: targetContext, label: "target")
        target.suspendLoad = true
        target.requiresUncancelledLoad = true
        let restored = FakeSession(context: old.context, label: "restored")
        restored.requiresUncancelledLoad = true
        let controller = LibrarySessionController(factory: FakeSessionFactory(sessions: [
            targetContext.id: [target], old.context.id: [restored]
        ]))
        controller.installInitialSession(old)

        let task = Task { try await controller.switchToLibrary(targetContext) }
        await target.waitUntilLoadSuspended()
        task.cancel()
        target.resumeLoad()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(controller.activeSession === restored)
        XCTAssertEqual(controller.state, .active(old.context.id))
    }

    func testCurrentLibraryModeMismatchKeepsExistingSession() async {
        let current = FakeSession(context: context(id: UUID()), label: "current")
        let controller = LibrarySessionController(factory: FakeSessionFactory(sessions: [:]))
        controller.installInitialSession(current)
        let wrongMode = LibraryContext(
            id: current.context.id, mode: .referenced, rootURL: current.context.rootURL,
            rootBookmarkData: current.context.rootBookmarkData, generation: 2
        )
        do {
            try await controller.switchToLibrary(wrongMode)
            XCTFail("Expected mode mismatch")
        } catch {
            XCTAssertEqual(error as? LibrarySessionFactoryError, .manifestModeMismatch)
        }
        XCTAssertTrue(controller.activeSession === current)
        XCTAssertEqual(controller.state, .active(current.context.id))
        XCTAssertTrue(current.events.values.isEmpty)
    }

    func testPlaybackMemoryIsIsolatedPerLibrary() throws {
        let suiteName = "PlaybackMemoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackMemoryStore(defaults: defaults)
        let now = Date()
        let libraryA = UUID()
        let libraryB = UUID()
        let memoryA = PlaybackMemory(
            savedAt: now,
            trackID: UUID(),
            currentTime: 12,
            duration: 120,
            queueTrackIDs: [UUID()],
            playbackOrderMode: "sequential"
        )
        let memoryB = PlaybackMemory(
            savedAt: now,
            trackID: UUID(),
            currentTime: 34,
            duration: 200,
            queueTrackIDs: nil,
            playbackOrderMode: "shuffle"
        )

        store.save(memoryA, libraryID: libraryA)
        store.save(memoryB, libraryID: libraryB)
        XCTAssertEqual(store.loadValid(libraryID: libraryA, now: now), memoryA)
        XCTAssertEqual(store.loadValid(libraryID: libraryB, now: now), memoryB)

        store.clear(libraryID: libraryB)
        XCTAssertEqual(store.loadValid(libraryID: libraryA, now: now), memoryA)
        XCTAssertNil(store.loadValid(libraryID: libraryB, now: now))
    }

    func testPlaybackMemoryLegacyPayloadIsClaimedOnlyOnce() throws {
        let suiteName = "PlaybackMemoryLegacyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackMemoryStore(defaults: defaults)
        let now = Date()
        let memory = PlaybackMemory(
            savedAt: now,
            trackID: UUID(),
            currentTime: 8,
            duration: 80,
            queueTrackIDs: nil,
            playbackOrderMode: nil
        )
        defaults.set(try JSONEncoder().encode(memory), forKey: PlaybackMemoryStore.legacyKey)
        let libraryA = UUID()
        let libraryB = UUID()

        XCTAssertEqual(store.loadValid(libraryID: libraryA, now: now), memory)
        XCTAssertNil(store.loadValid(libraryID: libraryB, now: now))
        XCTAssertEqual(
            defaults.string(forKey: PlaybackMemoryStore.legacyOwnerKey),
            libraryA.uuidString
        )
        XCTAssertNil(defaults.data(forKey: PlaybackMemoryStore.legacyKey))
    }

    func testFullscreenReleaseDefersCloseUntilTransitionEnds() {
        var state = FullscreenDeferredReleaseState()
        XCTAssertEqual(
            state.nextAction(isTransitioning: true, hasWindow: true),
            .waitForTransition
        )
        XCTAssertEqual(
            state.nextAction(isTransitioning: false, hasWindow: true),
            .requestWindowClose
        )
        XCTAssertEqual(
            state.nextAction(isTransitioning: true, hasWindow: true),
            .waitForTransition
        )
        XCTAssertEqual(
            state.nextAction(isTransitioning: false, hasWindow: false),
            .complete
        )
    }

    func testAppKitHostRebuildIsConsumedOnceAfterPublish() {
        var state = LibraryHostRebuildState()
        XCTAssertNil(state.consumeRebuildAfterPublish())
        let generation = state.recordRelease()
        XCTAssertEqual(state.consumeRebuildAfterPublish(), generation)
        XCTAssertNil(state.consumeRebuildAfterPublish())

        let nextGeneration = state.recordRelease()
        XCTAssertGreaterThan(nextGeneration, generation)
        XCTAssertEqual(state.consumeRebuildAfterPublish(), nextGeneration)
        XCTAssertNil(state.consumeRebuildAfterPublish())
    }

    func testLibraryHandoffRebuildsContentInsideTheSameMainWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try MusicLibraryRegistryStore(fileURL: root.appendingPathComponent("Registry.json"))
        let schema = Schema([TrackIndexEntry.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let appSession = AppSessionHost(modelContainer: container, initialLibraryContext: nil, registryStore: registry)
        // Setup is intentionally not run: show creates a hidden host and
        // never opens the user's library or presents the main App window.
        let controller = AppKitMainSplitWindowController.show(appSession: appSession)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let oldContent = window.contentViewController

        AppKitMainSplitWindowController.releaseActiveLibraryReferences()

        XCTAssertTrue(AppKitMainSplitWindowController.isRebuildingAfterLibrarySwitch)
        XCTAssertTrue(AppKitMainSplitWindowController.show(appSession: appSession) === controller)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.contentViewController === oldContent)
        AppKitMainSplitWindowController.rebuildAfterLibrarySwitchIfNeeded(appSession: appSession)
        XCTAssertFalse(AppKitMainSplitWindowController.isRebuildingAfterLibrarySwitch)
        XCTAssertTrue(controller.window === window)
        XCTAssertNotNil(window.contentViewController)
        XCTAssertFalse(window.contentViewController === oldContent)
    }

    private func context(id: UUID) -> LibraryContext {
        LibraryContext(
            id: id,
            mode: .managed,
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(id.uuidString, isDirectory: true),
            rootBookmarkData: Data(),
            generation: 1
        )
    }
}

@MainActor
private final class FakeSession: LibrarySessionLifecycle {
    let context: LibraryContext
    let events: EventLog
    let label: String
    var loadError: Error?
    var flushError: Error?
    var suspendLoad = false
    var suspendQuiesce = false
    var requiresUncancelledLoad = false
    private var didReachSuspendedLoad = false
    private var didReachSuspendedQuiesce = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var quiesceContinuation: CheckedContinuation<Void, Never>?

    init(context: LibraryContext, events: EventLog = EventLog(), label: String) {
        self.context = context
        self.events = events
        self.label = label
    }

    func load() async throws {
        events.append("\(label).load")
        if suspendLoad {
            didReachSuspendedLoad = true
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        if requiresUncancelledLoad { try Task.checkCancellation() }
        if let loadError { throw loadError }
    }

    func waitUntilLoadSuspended() async {
        while !didReachSuspendedLoad {
            await Task.yield()
        }
    }

    func resumeLoad() {
        suspendLoad = false
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func waitUntilQuiesceSuspended() async {
        while !didReachSuspendedQuiesce {
            await Task.yield()
        }
    }

    func resumeQuiesce() {
        suspendQuiesce = false
        quiesceContinuation?.resume()
        quiesceContinuation = nil
    }

    func flush() async throws {
        events.append("\(label).flush")
        if let flushError { throw flushError }
    }

    func quiesce() async {
        events.append("\(label).quiesce")
        if suspendQuiesce {
            didReachSuspendedQuiesce = true
            await withCheckedContinuation { continuation in
                quiesceContinuation = continuation
            }
        }
    }

    func close() async {
        events.append("\(label).close")
    }
}

@MainActor
private final class FakeSessionFactory: LibrarySessionBuilding {
    var sessions: [UUID: [FakeSession]]
    var makeErrors: [UUID: Error] = [:]
    var suspendedContextIDs: Set<UUID> = []
    private var suspendedContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var reachedSuspension: Set<UUID> = []
    private(set) var madeContextIDs: [UUID] = []

    init(sessions: [UUID: [FakeSession]]) {
        self.sessions = sessions
    }

    func makeSession(for context: LibraryContext) async throws -> any LibrarySessionLifecycle {
        madeContextIDs.append(context.id)
        if suspendedContextIDs.contains(context.id) {
            reachedSuspension.insert(context.id)
            await withCheckedContinuation { continuation in
                suspendedContinuations[context.id] = continuation
            }
        }
        if let error = makeErrors[context.id] { throw error }
        guard var queued = sessions[context.id], !queued.isEmpty else {
            throw TestFailure.noSession
        }
        let session = queued.removeFirst()
        sessions[context.id] = queued
        return session
    }

    func waitUntilSuspended(_ id: UUID) async {
        while !reachedSuspension.contains(id) {
            await Task.yield()
        }
    }

    func resume(_ id: UUID) {
        suspendedContextIDs.remove(id)
        suspendedContinuations.removeValue(forKey: id)?.resume()
    }
}

@MainActor
private final class EventLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private enum TestFailure: Error {
    case expected
    case noSession
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    expected: LibrarySessionControllerError? = nil,
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected operation to throw", file: file, line: line)
    } catch {
        if let expected {
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        }
    }
}
