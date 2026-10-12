import XCTest
@testable import kmgccc_player

// MARK: - Pure policy

final class IdleCPUGateTests: XCTestCase {
    func testThresholdsFollowBaselineWithCeilings() {
        XCTAssertEqual(IdleCPUGate.startThreshold(baseline: 15), 25)
        XCTAssertEqual(IdleCPUGate.pauseThreshold(baseline: 15), 40)
        XCTAssertEqual(IdleCPUGate.startThreshold(baseline: 23), 33)
        XCTAssertEqual(IdleCPUGate.pauseThreshold(baseline: 23), 48)
        XCTAssertEqual(IdleCPUGate.startThreshold(baseline: 8), 18)
        XCTAssertEqual(IdleCPUGate.pauseThreshold(baseline: 8), 33)
        // A busy machine never gets a looser gate than the ceilings.
        XCTAssertEqual(IdleCPUGate.startThreshold(baseline: 60), 35)
        XCTAssertEqual(IdleCPUGate.pauseThreshold(baseline: 60), 50)
    }

    func testOpensAfterConfirmationAndPausesAtUpperThreshold() {
        var gate = IdleCPUGate()
        XCTAssertEqual(gate.waitReason, .confirmingIdle)
        gate.ingest(average: 10, baseline: 15, now: 0)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.waitReason, .confirmingIdle)
        gate.ingest(average: 10, baseline: 15, now: 29)
        XCTAssertFalse(gate.isOpen)
        gate.ingest(average: 10, baseline: 15, now: 30)
        XCTAssertTrue(gate.isOpen)
        XCTAssertNil(gate.waitReason)

        // Between the thresholds the state is kept.
        gate.ingest(average: 35, baseline: 15, now: 40)
        XCTAssertTrue(gate.isOpen)
        gate.ingest(average: 40, baseline: 15, now: 47)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.waitReason, .systemBusy)
    }

    func testAPeakDuringConfirmationRestartsTheClock() {
        var gate = IdleCPUGate()
        gate.ingest(average: 10, baseline: 15, now: 0)
        gate.ingest(average: 30, baseline: 15, now: 10)
        gate.ingest(average: 10, baseline: 15, now: 20)
        gate.ingest(average: 10, baseline: 15, now: 49)
        XCTAssertFalse(gate.isOpen)
        gate.ingest(average: 10, baseline: 15, now: 50)
        XCTAssertTrue(gate.isOpen)
    }
}

final class CPUBaselineStoreTests: XCTestCase {
    func testBaselineIsDefaultUntilEnoughSamples() {
        var store = CPUBaselineStore()
        for _ in 0..<(CPUBaselineStore.minimumSamples - 1) { store.record(percent: 5, day: 100) }
        XCTAssertNil(store.learnedBaseline(today: 100))
        XCTAssertEqual(store.baseline(today: 100), CPUBaselineStore.defaultBaselinePercent)
        store.record(percent: 5, day: 100)
        XCTAssertEqual(store.learnedBaseline(today: 100), 5)
    }

    func testBaselineIsTheFirstQuartileSoBusyStretchesDoNotRaiseIt() {
        var store = CPUBaselineStore()
        for _ in 0..<100 { store.record(percent: 10, day: 100) }
        for _ in 0..<100 { store.record(percent: 80, day: 100) }
        XCTAssertEqual(store.learnedBaseline(today: 100), 10)
    }

    func testOldDaysFallOut() {
        var store = CPUBaselineStore()
        for _ in 0..<200 { store.record(percent: 60, day: 100) }
        for _ in 0..<200 { store.record(percent: 12, day: 110) }
        XCTAssertEqual(store.learnedBaseline(today: 110), 12)
        XCTAssertEqual(store.sampleCount(today: 110), 200)
    }

    func testCodableRoundTrip() throws {
        var store = CPUBaselineStore()
        store.record(percent: 22, day: 5)
        let decoded = try JSONDecoder().decode(CPUBaselineStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(decoded, store)
    }
}

final class BackgroundDeviceProfileTests: XCTestCase {
    func testMachineClassesAndRestFactors() {
        let air = BackgroundDeviceProfile(deviceFamily: "MacBook Air", memoryGB: 16)
        XCTAssertEqual(air.machineClass, .fanlessLaptop)
        XCTAssertEqual(air.gentleRestFactor, 2)
        XCTAssertEqual(BackgroundDeviceProfile(deviceFamily: "MacBook Neo", memoryGB: 8).machineClass, .fanlessLaptop)
        let pro = BackgroundDeviceProfile(deviceFamily: "MacBook Pro", memoryGB: 32)
        XCTAssertEqual(pro.machineClass, .fannedLaptop)
        XCTAssertEqual(pro.gentleRestFactor, 1)
        let mini = BackgroundDeviceProfile(deviceFamily: "Mac mini", memoryGB: 16)
        XCTAssertEqual(mini.machineClass, .desktop)
        XCTAssertEqual(mini.gentleRestFactor, 0.5)
        XCTAssertEqual(BackgroundDeviceProfile(deviceFamily: "unknown", memoryGB: nil).machineClass, .unknown)
    }

    func testSmallMemoryRestsAtLeastTwiceAndSkipsComponentPreparation() {
        let smallPro = BackgroundDeviceProfile(deviceFamily: "MacBook Pro", memoryGB: 8)
        XCTAssertTrue(smallPro.isSmallMemory)
        XCTAssertEqual(smallPro.gentleRestFactor, 2)
        XCTAssertFalse(smallPro.allowsComponentPreparation)
        XCTAssertTrue(BackgroundDeviceProfile(deviceFamily: "MacBook Air", memoryGB: 16).allowsComponentPreparation)
        XCTAssertFalse(BackgroundDeviceProfile(deviceFamily: "unknown", memoryGB: 16).allowsComponentPreparation)
    }

    func testFastModeRemovesRestButHeatBringsItBack() {
        let air = BackgroundDeviceProfile(deviceFamily: "MacBook Air", memoryGB: 16)
        XCTAssertEqual(air.restFactor(mode: .fast, thermalFairOrWorse: false), 0)
        XCTAssertEqual(air.restFactor(mode: .gentle, thermalFairOrWorse: false), 2)
        XCTAssertEqual(air.restFactor(mode: .gentle, thermalFairOrWorse: true), 3)
        XCTAssertEqual(air.restFactor(mode: .fast, thermalFairOrWorse: true), 3)
    }
}

final class BackgroundSchedulingStatisticsTests: XCTestCase {
    func testTimeIsAttributedToThePreviousState() {
        var statistics = BackgroundSchedulingStatistics(now: 0)
        var state = BackgroundSchedulingStatistics.State()
        state.idlePending = true
        state.waitReason = .onBattery
        state.onACPower = false
        statistics.advance(to: 0, state: state)
        var running = state
        running.onACPower = true
        running.idleRunning = true
        running.waitReason = nil
        statistics.advance(to: 60, state: running)
        statistics.advance(to: 100, state: running)

        XCTAssertEqual(statistics.sessionSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(statistics.idlePendingSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(statistics.idleRunningSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(statistics.onACSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(statistics.waitSeconds[.onBattery] ?? 0, 60, accuracy: 0.001)
        XCTAssertTrue(statistics.waitSecondsOnAC.isEmpty)
    }

    func testSummaryHoldsOnlyBandsAndRatios() {
        var statistics = BackgroundSchedulingStatistics(now: 0)
        var state = BackgroundSchedulingStatistics.State()
        state.thermal = .fair
        state.idlePending = true
        state.waitReason = .systemBusy
        statistics.advance(to: 0, state: state)
        statistics.advance(to: 100, state: state)

        let summary = BackgroundSchedulingSummary(
            statistics: statistics, learnedBaseline: 23, pacing: .gentle, preparationEnabled: true
        )
        XCTAssertEqual(summary.cpuBaselineBand, "20_30")
        XCTAssertEqual(summary.thermalRatios["fair"], 1)
        XCTAssertEqual(summary.thermalRatios["serious"], 0)
        XCTAssertEqual(summary.idlePendingRatio, 1)
        XCTAssertEqual(summary.idleRunRatio, 0)
        XCTAssertEqual(summary.waitRatios["system_busy"], 1)
        XCTAssertEqual(summary.pacing, "gentle")
        XCTAssertNil(BackgroundSchedulingSummary(
            statistics: statistics, learnedBaseline: nil, pacing: .fast, preparationEnabled: false
        ).cpuBaselineBand)
    }

    func testBaselineBands() {
        XCTAssertEqual(BackgroundSchedulingSummary.baselineBand(4), "lt10")
        XCTAssertEqual(BackgroundSchedulingSummary.baselineBand(10), "10_20")
        XCTAssertEqual(BackgroundSchedulingSummary.baselineBand(29.9), "20_30")
        XCTAssertEqual(BackgroundSchedulingSummary.baselineBand(30), "30_40")
        XCTAssertEqual(BackgroundSchedulingSummary.baselineBand(55), "ge40")
    }
}

final class BackgroundWorkContextTests: XCTestCase {
    func testCheckpointSuspendsWhilePausedAndResumesWithoutPolling() async throws {
        let context = BackgroundWorkContext()
        context.setPaused(true)
        let resumed = expectation(description: "resumed")
        let task = Task.detached {
            try await context.checkpoint()
            resumed.fulfill()
        }
        try await Task.sleep(for: .milliseconds(100))
        context.setPaused(false)
        await fulfillment(of: [resumed], timeout: 2)
        _ = try await task.value
    }

    func testCancelReleasesAPausedCheckpointWithAnError() async {
        let context = BackgroundWorkContext()
        context.setPaused(true)
        let task = Task.detached { () -> Bool in
            do {
                try await context.checkpoint()
                return false
            } catch {
                return error is CancellationError
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        context.cancel()
        let threw = await task.value
        XCTAssertTrue(threw)
    }

    func testTaskCancellationReleasesAPausedCheckpoint() async {
        let context = BackgroundWorkContext()
        context.setPaused(true)
        let task = Task.detached { () -> Bool in
            do {
                try await context.checkpoint()
                return false
            } catch {
                return error is CancellationError
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let threw = await task.value
        XCTAssertTrue(threw)
    }
}

// MARK: - Scheduler

/// A unit finishes when the test opens its latch.
private final class UnitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if open { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiters.removeAll() }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }
}

@MainActor
private final class RecordingSource: BackgroundWorkSource {
    let sourceID: String
    let domain: BackgroundWorkDomain = .loudness
    let owner: BackgroundWorkOwner
    let resources: BackgroundWorkResources
    var progress: BackgroundWorkProgress { .empty }
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private var queue: [(id: String, priority: BackgroundWorkPriority)] = []
    let latches: [String: UnitLatch]

    init(
        id: String,
        owner: BackgroundWorkOwner = .app,
        resources: BackgroundWorkResources = [.compute],
        units: [(String, BackgroundWorkPriority)]
    ) {
        sourceID = id
        self.owner = owner
        self.resources = resources
        queue = units.map { (id: $0.0, priority: $0.1) }
        latches = Dictionary(uniqueKeysWithValues: units.map { ($0.0, UnitLatch()) })
    }

    func hasWork(priority: BackgroundWorkPriority, excluding: Set<String>) -> Bool {
        queue.contains { $0.priority == priority && !excluding.contains($0.id) }
    }

    func nextUnit(priority: BackgroundWorkPriority, excluding: Set<String>) -> BackgroundWorkUnit? {
        guard let item = queue.first(where: { $0.priority == priority && !excluding.contains($0.id) }),
              let latch = latches[item.id] else { return nil }
        let id = item.id
        return BackgroundWorkUnit(id: id, priority: priority) { [weak self] context in
            await MainActor.run { self?.started.append(id) }
            await latch.wait()
            guard (try? await context.checkpoint()) != nil else { return .cancelled }
            await MainActor.run {
                self?.finished.append(id)
                self?.queue.removeAll { $0.id == id }
            }
            return .completed
        }
    }

    func release(_ id: String) { latches[id]?.release() }
}

@MainActor
final class BackgroundWorkSchedulerTests: XCTestCase {
    private func makeScheduler() -> BackgroundWorkScheduler {
        let defaults = UserDefaults(suiteName: "BackgroundWorkSchedulerTests-\(UUID().uuidString)")!
        let scheduler = BackgroundWorkScheduler(
            conditions: SystemConditionMonitor(),
            deviceProfile: BackgroundDeviceProfile(machineClass: .desktop, isSmallMemory: false),
            userDefaults: defaults
        )
        scheduler.start()
        return scheduler
    }

    private func eventually(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out: \(description)")
    }

    func testListenerRequestedUnitsRespectTheChannelBudget() async {
        let scheduler = makeScheduler()
        let source = RecordingSource(id: "s", units: [("a", .userRequested), ("b", .userRequested), ("c", .userRequested)])
        scheduler.register(source)

        // Two user-requested units may use the compute channel at once.
        await eventually("two units start") { source.started.count == 2 }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(source.started.count, 2)

        source.release("a")
        await eventually("third starts after one ends") { source.started.count == 3 }
        source.release("b")
        source.release("c")
        await eventually("all finish") { source.finished.count == 3 }
    }

    func testNetworkWorkIsNotBlockedByComputation() async {
        let scheduler = makeScheduler()
        let compute = RecordingSource(id: "compute", resources: [.compute], units: [("c1", .userRequested), ("c2", .userRequested)])
        scheduler.register(compute)
        await eventually("compute channel is full") { compute.started.count == 2 }

        let network = RecordingSource(id: "net", resources: [.network], units: [("n1", .userRequested)])
        scheduler.register(network)
        await eventually("network unit starts while compute is busy") { network.started == ["n1"] }

        compute.release("c1")
        compute.release("c2")
        network.release("n1")
    }

    func testMoreUrgentUnitPausesALessUrgentOneInTheSameChannel() async {
        let scheduler = makeScheduler()
        let upcoming = RecordingSource(id: "soon", units: [("soon", .upcoming)])
        let urgent = RecordingSource(id: "urgent", units: [("now", .userRequested)])
        scheduler.register(upcoming)
        await eventually("upcoming unit starts") { upcoming.started == ["soon"] }
        XCTAssertTrue(scheduler.isActive(domain: .loudness, priority: .upcoming))

        scheduler.register(urgent)
        await eventually("urgent unit starts") { urgent.started == ["now"] }
        await eventually("upcoming unit steps aside") {
            !scheduler.isActive(domain: .loudness, priority: .upcoming)
        }

        urgent.release("now")
        await eventually("upcoming unit resumes") {
            scheduler.isActive(domain: .loudness, priority: .upcoming)
        }
        upcoming.release("soon")
        await eventually("upcoming unit finishes") { upcoming.finished == ["soon"] }
    }

    func testTaskKeyIsDeduplicatedAndCanBePromotedBeforeItStarts() async {
        let scheduler = makeScheduler()
        let blocker = RecordingSource(id: "blocker", units: [("x", .userRequested), ("y", .userRequested)])
        scheduler.register(blocker)
        await eventually("compute channel is full") { blocker.started.count == 2 }

        let first = scheduler.submit(key: "job", domain: .cacheMaintenance, priority: .idleBatch, resources: [.compute]) { _ in .completed }
        let second = scheduler.submit(key: "job", domain: .cacheMaintenance, priority: .upcoming, resources: [.compute]) { _ in .completed }
        XCTAssertTrue(first === second)
        XCTAssertEqual(scheduler.priority(ofTask: "job"), .upcoming)
        scheduler.promote(taskKey: "job", to: .userRequested)
        XCTAssertEqual(scheduler.priority(ofTask: "job"), .userRequested)

        blocker.release("x")
        blocker.release("y")
        let outcome = await first.value()
        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(scheduler.hasTask(key: "job"))
    }

    func testRevokingALibraryOwnerCancelsItsWaitingTasks() async {
        let scheduler = makeScheduler()
        let owner = scheduler.makeLibraryOwner(libraryID: UUID())
        // Idle work cannot start on a scheduler that has not settled launch.
        let handle = scheduler.submit(
            key: "owned", owner: owner, domain: .artworkColors, priority: .idleBatch, resources: [.compute]
        ) { _ in .completed }
        XCTAssertTrue(scheduler.hasTask(key: "owned"))
        scheduler.revoke(owner: owner)
        let outcome = await handle.value()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(scheduler.hasTask(key: "owned"))

        // A revoked session cannot submit again.
        let late = scheduler.submit(
            key: "late", owner: owner, domain: .artworkColors, priority: .idleBatch
        ) { _ in .completed }
        let lateOutcome = await late.value()
        XCTAssertEqual(lateOutcome, .cancelled)
    }

    func testActivatingALibraryRevokesOtherLibraries() async {
        let scheduler = makeScheduler()
        let old = scheduler.makeLibraryOwner(libraryID: UUID())
        let current = scheduler.makeLibraryOwner(libraryID: UUID())
        let oldHandle = scheduler.submit(key: "old", owner: old, domain: .artworkColors, priority: .idleBatch) { _ in .completed }
        let appHandle = scheduler.submit(key: "app", owner: .app, domain: .cacheMaintenance, priority: .idleBatch) { _ in .completed }
        scheduler.activateLibrary(current)
        let oldOutcome = await oldHandle.value()
        XCTAssertEqual(oldOutcome, .cancelled)
        XCTAssertTrue(scheduler.hasTask(key: "app"))
        appHandle.cancel()
    }

    func testIdleWorkWaitsUntilLaunchHasSettled() async {
        let scheduler = makeScheduler()
        let source = RecordingSource(id: "idle", units: [("i", .idleBatch)])
        scheduler.register(source)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(source.started.isEmpty)
        XCTAssertNotNil(scheduler.idleWaitReason)
        scheduler.unregister(sourceID: "idle")
    }

    // MARK: Leases

    @MainActor
    private final class Flag {
        var value = false
    }

    func testLeasesCountAgainstTheChannelBudgetUntilReleased() async {
        let scheduler = makeScheduler()
        let first = await scheduler.acquireLease(domain: .fileWork, priority: .userRequested, resources: [.compute])
        let second = await scheduler.acquireLease(domain: .fileWork, priority: .userRequested, resources: [.compute])
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)

        // Two user-requested units fill the compute channel; a third claim waits.
        let thirdGranted = Flag()
        let third = Task { @MainActor in
            let lease = await scheduler.acquireLease(domain: .fileWork, priority: .userRequested, resources: [.compute])
            thirdGranted.value = lease != nil
            lease?.release()
        }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(thirdGranted.value)

        first?.release()
        await eventually("the waiting claim is granted once a slot frees") { thirdGranted.value }
        second?.release()
        await third.value
    }

    func testCancellingAWaitingLeaseReturnsNil() async {
        let scheduler = makeScheduler()
        let first = await scheduler.acquireLease(domain: .fileWork, priority: .userRequested, resources: [.compute])
        let second = await scheduler.acquireLease(domain: .fileWork, priority: .userRequested, resources: [.compute])
        let waiting = Task { @MainActor in
            await scheduler.acquireLease(domain: .fileWork, priority: .userRequested, resources: [.compute])
        }
        try? await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        let lease = await waiting.value
        XCTAssertNil(lease)
        first?.release()
        second?.release()
    }

    func testLenderWithoutASchedulerGrantsNothingAndNeverWaits() async {
        let value = await BackgroundWorkLender.none.withLease(
            domain: .fileWork, priority: .userRequested, resources: [.disk]
        ) { 42 }
        XCTAssertEqual(value, 42)
    }

    // MARK: Domains

    func testUpdateDownloadAndSourceSyncSurviveThePreparationSwitch() {
        XCTAssertTrue(BackgroundWorkDomain.loudness.survivesPreparationSwitch)
        XCTAssertTrue(BackgroundWorkDomain.appUpdate.survivesPreparationSwitch)
        XCTAssertTrue(BackgroundWorkDomain.sourceSync.survivesPreparationSwitch)
        XCTAssertFalse(BackgroundWorkDomain.pageThumbnails.survivesPreparationSwitch)
        XCTAssertFalse(BackgroundWorkDomain.lyricsIndex.survivesPreparationSwitch)
    }

    func testTaskCompletionIsRecordedPerDomain() async {
        let scheduler = makeScheduler()
        XCTAssertNil(scheduler.lastCompletion(of: .cacheMaintenance))
        let handle = scheduler.submit(
            key: "tidy", domain: .cacheMaintenance, priority: .userRequested, resources: [.disk]
        ) { _ in .completed }
        let outcome = await handle.value()
        XCTAssertEqual(outcome, .completed)
        XCTAssertNotNil(scheduler.lastCompletion(of: .cacheMaintenance))
        XCTAssertNil(scheduler.lastCompletion(of: .lyricsIndex))
    }
}

@MainActor
final class SidebarTaskVisibilityTests: XCTestCase {
    func testKindsRegisterTheirOwnRules() {
        XCTAssertEqual(LibraryTaskKind.importFiles.sidebarVisibility, .always)
        XCTAssertEqual(LibraryTaskKind.embeddedTagWrite.sidebarVisibility, .always)
        XCTAssertEqual(LibraryTaskKind.libraryBundleExport.sidebarVisibility, .always)
        XCTAssertEqual(LibraryTaskKind.sourceScan.sidebarVisibility, .never)
        XCTAssertEqual(
            LibraryTaskKind.automation.sidebarVisibility,
            .whenAtLeast(SidebarTaskVisibility.largeBatchCount)
        )
    }

    func testBatchRuleNeedsEnoughItems() {
        let rule = SidebarTaskVisibility.whenAtLeast(50)
        XCTAssertFalse(rule.shows(itemCount: nil))
        XCTAssertFalse(rule.shows(itemCount: 49))
        XCTAssertTrue(rule.shows(itemCount: 50))
        XCTAssertTrue(SidebarTaskVisibility.always.shows(itemCount: nil))
        XCTAssertFalse(SidebarTaskVisibility.never.shows(itemCount: 1000))
    }

    func testTaskAppearsOnlyAfterTheDelayAndLeavesWhenItStopsBeingEligible() {
        var tracker = SidebarTaskRevealTracker()
        let id = UUID()

        var result = tracker.update(eligible: [id], now: 100, delay: 3)
        XCTAssertTrue(result.revealed.isEmpty)
        XCTAssertEqual(result.nextCheck, 3)

        result = tracker.update(eligible: [id], now: 101.5, delay: 3)
        XCTAssertTrue(result.revealed.isEmpty)
        XCTAssertEqual(result.nextCheck ?? 0, 1.5, accuracy: 0.001)

        result = tracker.update(eligible: [id], now: 103.1, delay: 3)
        XCTAssertEqual(result.revealed, [id])
        XCTAssertNil(result.nextCheck)

        // A task that ended and came back starts its delay again.
        _ = tracker.update(eligible: [], now: 104, delay: 3)
        result = tracker.update(eligible: [id], now: 105, delay: 3)
        XCTAssertTrue(result.revealed.isEmpty)
    }

    func testThumbnailSizeHintsRoundTrip() {
        let defaults = UserDefaults(suiteName: "SidebarTaskVisibilityTests-\(UUID().uuidString)")!
        XCTAssertNil(PageThumbnailSizeHints.albumRail(defaults: defaults))
        PageThumbnailSizeHints.record(albumRail: 304, artistRail: 256, defaults: defaults)
        XCTAssertEqual(PageThumbnailSizeHints.albumRail(defaults: defaults), 304)
        XCTAssertEqual(PageThumbnailSizeHints.artistRail(defaults: defaults), 256)
    }
}
