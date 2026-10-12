import AppKit
import Foundation
import Observation
import OSLog

/// App-wide admission, priority and resource budget for deferrable work.
/// Domain services execute their work and keep their results; the scheduler
/// only decides when a unit may run and how much of the machine it may use.
///
/// - Units declare resource channels (compute, disk, network). Each channel has
///   its own budget per priority, and a more urgent unit pauses a less urgent
///   one in the same channel at its next checkpoint.
/// - Backlogs are pulled from registered sources; discrete work is submitted
///   under a key. Neither is persisted: sources derive what is left from their
///   own state.
/// - Idle batch work follows the "body clock": it runs on AC power, outside
///   Low Power Mode and serious heat, while the App and the system are quiet,
///   and rests between units so the machine stays cool.
/// - Every unit has an owner. Revoking a library owner ends its work, so a
///   closed library session never leaves units behind in the next one.
@Observable
@MainActor
final class BackgroundWorkScheduler {
    // MARK: - Internal types

    private enum RunState: Equatable {
        case running
        case paused
        case stopping(deadline: TimeInterval)
    }

    private enum StopReason {
        /// Yielded its slot and gave up its paused place, or lost the network
        /// it could not pause without; runs again later.
        case overflow
        case revoked
        case cancelled
    }

    private enum Origin: Hashable {
        case source(String)
        case task(String)
    }

    private enum RestPool: Hashable {
        case heavy
        case network
    }

    private struct RunningUnit {
        let runID: UInt64
        let order: UInt64
        let origin: Origin
        let unitID: String
        let owner: BackgroundWorkOwner
        let domain: BackgroundWorkDomain
        let priority: BackgroundWorkPriority
        let resources: BackgroundWorkResources
        let networkHost: String?
        /// Never paused or displaced; only losing the network ends it.
        let runsToCompletion: Bool
        let context: BackgroundWorkContext
        var task: Task<Void, Never>?
        var state: RunState = .running
        var stopReason: StopReason?
        var activeSeconds: TimeInterval = 0
        var activeSince: TimeInterval?
        var signpost: OSSignpostIntervalState?
    }

    private struct TaskEntry {
        let key: String
        let owner: BackgroundWorkOwner
        let domain: BackgroundWorkDomain
        var priority: BackgroundWorkPriority
        let resources: BackgroundWorkResources
        let networkHost: String?
        let runsToCompletion: Bool
        var work: @Sendable (BackgroundWorkContext) async -> BackgroundWorkOutcome
        let order: UInt64
        let handle: BackgroundTaskHandle
        var isRunning = false
    }

    private final class SourceBox {
        weak var source: (any BackgroundWorkSource)?
        let id: String
        init(source: any BackgroundWorkSource) {
            self.source = source
            self.id = source.sourceID
        }
    }

    private struct Gate {
        var idleReason: BackgroundWaitReason?
        var thermal: SystemThermalLevel
        var memory: SystemMemoryPressureLevel
        var supplyConstrained: Bool
        /// The listener's choices as read at the start of this evaluation.
        var configuration: BackgroundWorkConfiguration

        var userLimitedToOne: Bool { thermal >= .serious || memory == .critical }
    }

    // MARK: - Published state

    /// Why idle batch work is not running; nil when it may run. Includes the
    /// rest between units.
    private(set) var idleWaitReason: BackgroundWaitReason?
    /// Changes whenever a unit starts, pauses, resumes or ends, for surfaces
    /// that summarize activity.
    private(set) var activityRevision = 0

    let conditions: SystemConditionMonitor
    let deviceProfile: BackgroundDeviceProfile

    /// Supplies the listener's choices; read on every evaluation.
    @ObservationIgnored var configurationProvider: @MainActor () -> BackgroundWorkConfiguration = {
        BackgroundWorkConfiguration()
    }

    // MARK: - Private state

    @ObservationIgnored private let holdRegistry = BackgroundHoldRegistry()
    @ObservationIgnored private var liveHolds: [BackgroundHoldKind: BackgroundWorkHold] = [:]
    @ObservationIgnored private var sources: [String: SourceBox] = [:]
    @ObservationIgnored private var sourceOrder: [String] = []
    @ObservationIgnored private var rotation = 0
    @ObservationIgnored private var tasks: [String: TaskEntry] = [:]
    @ObservationIgnored private var running: [UInt64: RunningUnit] = [:]
    @ObservationIgnored private var nextRunID: UInt64 = 0
    @ObservationIgnored private var nextOrder: UInt64 = 0
    @ObservationIgnored private var failures: [String: TimeInterval] = [:]
    @ObservationIgnored private var completions: [BackgroundWorkDomain: Date] = [:]
    @ObservationIgnored private var restUntil: [RestPool: TimeInterval] = [:]
    @ObservationIgnored private var restDebt: [RestPool: Double] = [:]
    @ObservationIgnored private var supplyShortfallUntil: TimeInterval = 0
    @ObservationIgnored private var visualPausedUntil: TimeInterval = 0
    @ObservationIgnored private var lastInteractionUptime: TimeInterval = -.infinity
    @ObservationIgnored private var userWasActive = false
    @ObservationIgnored private var interactionMonitor: Any?
    @ObservationIgnored private var conditionToken: UUID?
    @ObservationIgnored private var cpuGate = IdleCPUGate()
    @ObservationIgnored private var baselineStore: CPUBaselineStore
    @ObservationIgnored private var lastBaselineSave: TimeInterval = 0
    @ObservationIgnored private var activeLibraryOwner: BackgroundWorkOwner?
    @ObservationIgnored private var revokedOwners: Set<BackgroundWorkOwner> = []
    @ObservationIgnored private var libraryGeneration: UInt64 = 0
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var wakeAt: TimeInterval?
    @ObservationIgnored private var statistics: BackgroundSchedulingStatistics
    @ObservationIgnored private var lastDailyLog: TimeInterval
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?
    @ObservationIgnored private var isPassing = false
    @ObservationIgnored private var passRequested = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private let signposter = OSSignposter(subsystem: "kmg.myplayer2", category: "background")
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: @MainActor () -> TimeInterval

    nonisolated static let interactionQuietSeconds: TimeInterval = 5
    nonisolated static let supplyShortfallSeconds: TimeInterval = 30
    nonisolated static let memoryEventQuietSeconds: TimeInterval = 60
    nonisolated static let stopGraceSeconds: TimeInterval = 3
    nonisolated static let failureCooldownSeconds: TimeInterval = 600
    nonisolated static let completionCooldownSeconds: TimeInterval = 2
    /// Rest shorter than this is accumulated instead of scheduled, so tiny
    /// units do not cause a wake-up each.
    nonisolated static let minimumRestSeconds: TimeInterval = 0.25
    nonisolated static let statisticsInterval: Duration = .seconds(300)
    nonisolated static let dailyLogInterval: TimeInterval = 86_400
    nonisolated static let baselineSaveInterval: TimeInterval = 300
    nonisolated private static let baselineDefaultsKey = "background.cpu-baseline.v1"

    init(
        conditions: SystemConditionMonitor,
        deviceProfile: BackgroundDeviceProfile = .current(),
        userDefaults: UserDefaults = .standard,
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.conditions = conditions
        self.deviceProfile = deviceProfile
        self.defaults = userDefaults
        self.clock = clock
        let now = clock()
        statistics = BackgroundSchedulingStatistics(now: now)
        lastDailyLog = now
        if let data = userDefaults.data(forKey: Self.baselineDefaultsKey),
           let stored = try? JSONDecoder().decode(CPUBaselineStore.self, from: data) {
            baselineStore = stored
        } else {
            baselineStore = CPUBaselineStore()
        }
        holdRegistry.setChangeHandler { [weak self] in
            Task { @MainActor [weak self] in self?.reschedule() }
        }
    }

    /// Starts listening to the system and the listener. Called once by the
    /// App dependency owner, after the monitor has started.
    func start() {
        guard !started else { return }
        started = true
        conditionToken = conditions.addObserver { [weak self] event in
            self?.handle(event)
        }
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            self?.noteUserInteraction()
            return event
        }
        statisticsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.statisticsInterval)
                guard !Task.isCancelled else { return }
                self?.statisticsTick()
            }
        }
        reschedule()
    }

    // MARK: - Registration

    /// Adds a backlog the scheduler pulls from. Sources are held weakly; the
    /// domain service that owns one keeps it alive.
    func register(_ source: any BackgroundWorkSource) {
        guard !revokedOwners.contains(source.owner) else { return }
        if sources[source.sourceID] == nil { sourceOrder.append(source.sourceID) }
        sources[source.sourceID] = SourceBox(source: source)
        reschedule()
    }

    func unregister(sourceID: String) {
        sources[sourceID] = nil
        sourceOrder.removeAll { $0 == sourceID }
        for run in running.values where run.origin == .source(sourceID) {
            stop(runID: run.runID, reason: .revoked)
        }
        reschedule()
    }

    /// A source has new or reordered work.
    func noteWorkAvailable() { reschedule() }

    /// Submits a discrete task under a key. A key that is not started yet can
    /// take new content and a more urgent priority; one that is running keeps
    /// running. Returns a handle to wait on or cancel.
    ///
    /// `runsToCompletion` is for work that cannot stop and resume partway, such
    /// as a download handed to another framework: once started, it is not
    /// paused or displaced. It is cancelled and queued again when the network
    /// goes away, or turns metered for work below user-requested priority.
    @discardableResult
    func submit(
        key: String,
        owner: BackgroundWorkOwner = .app,
        domain: BackgroundWorkDomain,
        priority: BackgroundWorkPriority,
        resources: BackgroundWorkResources = [.compute, .disk],
        networkHost: String? = nil,
        runsToCompletion: Bool = false,
        work: @escaping @Sendable (BackgroundWorkContext) async -> BackgroundWorkOutcome
    ) -> BackgroundTaskHandle {
        if var existing = tasks[key] {
            if !existing.isRunning {
                existing.work = work
                if priority < existing.priority { existing.priority = priority }
                tasks[key] = existing
                reschedule()
            }
            return existing.handle
        }
        let handle = BackgroundTaskHandle(key: key, scheduler: self)
        guard !revokedOwners.contains(owner) else {
            handle.fulfill(.cancelled)
            return handle
        }
        nextOrder += 1
        tasks[key] = TaskEntry(
            key: key, owner: owner, domain: domain, priority: priority, resources: resources,
            networkHost: networkHost, runsToCompletion: runsToCompletion,
            work: work, order: nextOrder, handle: handle
        )
        reschedule()
        return handle
    }

    /// Runs best-effort work that returns nothing, such as a cache warm-up,
    /// under a fresh key. The operation cooperates through `checkpoint()`; if it
    /// returns after a cancel the task ends as cancelled.
    @discardableResult
    func submitWork(
        owner: BackgroundWorkOwner = .app,
        domain: BackgroundWorkDomain,
        priority: BackgroundWorkPriority,
        resources: BackgroundWorkResources = [.compute, .disk],
        networkHost: String? = nil,
        operation: @escaping @Sendable (BackgroundWorkContext) async -> Void
    ) -> BackgroundTaskHandle {
        nextOrder += 1
        return submit(
            key: "\(domain.rawValue)#\(nextOrder)",
            owner: owner, domain: domain, priority: priority,
            resources: resources, networkHost: networkHost
        ) { context in
            await operation(context)
            return context.isCancelled || Task.isCancelled ? .cancelled : .completed
        }
    }

    /// Raises a waiting task's priority, for example when the listener asks
    /// for what was queued as idle work.
    func promote(taskKey: String, to priority: BackgroundWorkPriority) {
        guard var entry = tasks[taskKey], priority < entry.priority else { return }
        entry.priority = priority
        tasks[taskKey] = entry
        reschedule()
    }

    func cancel(taskKey: String) {
        guard let entry = tasks[taskKey] else { return }
        if entry.isRunning {
            for run in running.values where run.origin == .task(taskKey) {
                stop(runID: run.runID, reason: .cancelled)
            }
        } else {
            tasks[taskKey] = nil
            entry.handle.fulfill(.cancelled)
        }
        reschedule()
    }

    /// Stops running units of a source whose work the listener withdrew. The
    /// source drops them from its own backlog first.
    func cancelRunningUnits(sourceID: String, unitIDs: Set<String>) {
        for run in running.values where run.origin == .source(sourceID) && unitIDs.contains(run.unitID) {
            stop(runID: run.runID, reason: .cancelled)
        }
        reschedule()
    }

    func hasTask(key: String) -> Bool { tasks[key] != nil }

    // MARK: - Leases

    /// Claims channel slots for work that runs in its own pipeline. The claim
    /// waits like a submitted task and is counted while held, so idle work
    /// steps aside. Returns nil when the claim was cancelled or its owner was
    /// revoked before it was granted; the caller then carries on without it.
    func acquireLease(
        owner: BackgroundWorkOwner = .app,
        domain: BackgroundWorkDomain,
        priority: BackgroundWorkPriority,
        resources: BackgroundWorkResources,
        networkHost: String? = nil
    ) async -> BackgroundLease? {
        let lease = BackgroundLease()
        nextOrder += 1
        let handle = submit(
            key: "lease:\(domain.rawValue)#\(nextOrder)",
            owner: owner, domain: domain, priority: priority,
            resources: resources, networkHost: networkHost,
            runsToCompletion: true
        ) { _ in
            lease.markGranted()
            await withTaskCancellationHandler {
                await lease.holdUntilReleased()
            } onCancel: {
                lease.markEnded()
            }
            return .completed
        }
        // A claim that ends without being granted returns its waiter.
        Task { @MainActor in
            _ = await handle.value()
            lease.markEnded()
        }
        return await withTaskCancellationHandler {
            await lease.waitForGrant() ? lease : nil
        } onCancel: {
            Task { @MainActor in handle.cancel() }
        }
    }

    /// A lender bound to this scheduler and owner, for services that are not
    /// on the main actor.
    func lender(owner: BackgroundWorkOwner = .app) -> BackgroundWorkLender {
        BackgroundWorkLender { [weak self] domain, priority, resources, host in
            await self?.acquireLease(
                owner: owner, domain: domain, priority: priority,
                resources: resources, networkHost: host
            )
        }
    }

    func priority(ofTask key: String) -> BackgroundWorkPriority? { tasks[key]?.priority }

    // MARK: - Owners

    /// A fresh owner for a library session. A later session of the same
    /// library gets a different generation.
    func makeLibraryOwner(libraryID: UUID) -> BackgroundWorkOwner {
        libraryGeneration += 1
        return .library(id: libraryID, generation: libraryGeneration)
    }

    /// Marks the owner of the library now in front. Work of every other
    /// library owner is revoked, even when its session forgot to say so.
    func activateLibrary(_ owner: BackgroundWorkOwner) {
        activeLibraryOwner = owner
        var stale: Set<BackgroundWorkOwner> = []
        for entry in tasks.values where entry.owner.isLibrary && entry.owner != owner { stale.insert(entry.owner) }
        for run in running.values where run.owner.isLibrary && run.owner != owner { stale.insert(run.owner) }
        for box in sources.values {
            if let source = box.source, source.owner.isLibrary, source.owner != owner { stale.insert(source.owner) }
        }
        for old in stale { revoke(owner: old) }
    }

    /// Ends all work of an owner: waiting tasks are dropped, running units
    /// stop at their next checkpoint (the channel is released after a short
    /// grace period either way), and its sources are removed.
    func revoke(owner: BackgroundWorkOwner) {
        if owner.isLibrary { revokedOwners.insert(owner) }
        for entry in tasks.values where entry.owner == owner {
            if entry.isRunning {
                for run in running.values where run.origin == .task(entry.key) {
                    stop(runID: run.runID, reason: .revoked)
                }
            } else {
                tasks[entry.key] = nil
                entry.handle.fulfill(.cancelled)
            }
        }
        for (id, box) in sources where box.source == nil || box.source?.owner == owner {
            sources[id] = nil
            sourceOrder.removeAll { $0 == id }
        }
        for run in running.values where run.owner == owner {
            stop(runID: run.runID, reason: .revoked)
        }
        if activeLibraryOwner == owner { activeLibraryOwner = nil }
        reschedule()
    }

    // MARK: - Holds and signals

    /// Declares that the App is busy with something background work should
    /// step aside for. The hold ends when released or dropped.
    func acquireHold(_ kind: BackgroundHoldKind) -> BackgroundWorkHold {
        BackgroundWorkHold(kind: kind, registry: holdRegistry)
    }

    /// Holds a kind on or off by a flag, for owners that track a state rather
    /// than a scope (for example "the library is writing").
    func setHold(_ kind: BackgroundHoldKind, active: Bool) {
        if active {
            guard liveHolds[kind] == nil else { return }
            liveHolds[kind] = acquireHold(kind)
        } else if let hold = liveHolds.removeValue(forKey: kind) {
            hold.release()
        }
    }

    /// Audio supply ran short; idle work yields for a while and upcoming
    /// network work drops to one at a time.
    func noteAudioSupplyShortfall() {
        supplyShortfallUntil = clock() + Self.supplyShortfallSeconds
        reschedule()
    }

    /// A setting or another external condition changed.
    func reevaluate() { reschedule() }

    private func noteUserInteraction() {
        lastInteractionUptime = clock()
        guard !userWasActive else { return }
        userWasActive = true
        reschedule()
    }

    private func handle(_ event: SystemConditionEvent) {
        switch event {
        case .memoryPressure(let level):
            if level != .normal { visualPausedUntil = clock() + Self.memoryEventQuietSeconds }
            reschedule()
        case .cpuSample:
            ingestCPUSample()
        case .powerSource, .lowPowerMode, .thermal, .network, .launchSettled:
            reschedule()
        }
    }

    // MARK: - Queries for surfaces

    /// Why work at `priority` using `resources` for `domain` is not running now.
    func waitReason(
        for domain: BackgroundWorkDomain,
        resources: BackgroundWorkResources,
        priority: BackgroundWorkPriority = .idleBatch
    ) -> BackgroundWaitReason? {
        let gate = makeGate(now: clock())
        return blockReason(
            priority: priority, domain: domain, resources: resources, gate: gate, now: clock()
        )
    }

    func runningUnitCount(domain: BackgroundWorkDomain) -> Int {
        running.values.filter { $0.domain == domain && $0.state == .running }.count
    }

    /// What the scheduler holds for a domain right now, for the Background
    /// Tasks page: units running, units paused for something more urgent, and
    /// submitted tasks still waiting to start.
    func activity(of domain: BackgroundWorkDomain) -> BackgroundDomainActivity {
        var activity = BackgroundDomainActivity()
        for run in running.values where run.domain == domain {
            switch run.state {
            case .running: activity.running += 1
            case .paused: activity.paused += 1
            case .stopping: break
            }
        }
        for entry in tasks.values where entry.domain == domain && !entry.isRunning {
            activity.waiting += 1
        }
        return activity
    }

    /// When a task of the domain last completed, kept across launches for
    /// domains that run as single tasks.
    func lastCompletion(of domain: BackgroundWorkDomain) -> Date? {
        if let date = completions[domain] { return date }
        let stored = defaults.double(forKey: Self.completionDefaultsKey(domain))
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    private func recordCompletion(of domain: BackgroundWorkDomain, persistent: Bool) {
        let now = Date()
        completions[domain] = now
        if persistent {
            defaults.set(now.timeIntervalSince1970, forKey: Self.completionDefaultsKey(domain))
        }
    }

    nonisolated private static func completionDefaultsKey(_ domain: BackgroundWorkDomain) -> String {
        "background.last-completed.\(domain.rawValue)"
    }

    func isActive(domain: BackgroundWorkDomain, priority: BackgroundWorkPriority? = nil) -> Bool {
        running.values.contains { run in
            run.domain == domain && run.state == .running && (priority == nil || run.priority == priority)
        }
    }

    var currentStatistics: BackgroundSchedulingStatistics { statistics }

    func statisticsSummary() -> BackgroundSchedulingSummary {
        updateStatistics(now: clock(), gate: makeGate(now: clock()))
        let configuration = configurationProvider()
        return BackgroundSchedulingSummary(
            statistics: statistics,
            learnedBaseline: baselineStore.learnedBaseline(today: CPUBaselineStore.dayIndex(for: Date())),
            pacing: configuration.pacing,
            preparationEnabled: configuration.preparationEnabled
        )
    }

    // MARK: - Scheduling pass

    private func reschedule() {
        guard started else { return }
        guard !isPassing else {
            passRequested = true
            return
        }
        isPassing = true
        defer { isPassing = false }
        var passes = 0
        repeat {
            passRequested = false
            runPass()
            passes += 1
        } while passRequested && passes < 4
    }

    private func runPass() {
        let now = clock()
        pruneFailures(now: now)
        let gate = makeGate(now: now)
        var occupants: [(priority: BackgroundWorkPriority, resources: BackgroundWorkResources, host: String?)] = []
        var pausedChannels = Set<BackgroundWorkChannel>()

        for priority in BackgroundWorkPriority.allCases {
            // Units that are already in flight, oldest first.
            let live = running.values.filter { $0.priority == priority }.sorted { $0.order < $1.order }
            for unit in live {
                switch unit.state {
                case .stopping(let deadline):
                    if now < deadline { occupants.append((priority, unit.resources, unit.networkHost)) }
                case .running, .paused:
                    if unit.runsToCompletion {
                        if networkLost(for: unit) {
                            stop(runID: unit.runID, reason: .overflow)
                        } else {
                            occupants.append((priority, unit.resources, unit.networkHost))
                            if unit.state == .paused { resume(runID: unit.runID, now: now) }
                        }
                        continue
                    }
                    let blocked = blockReason(
                        priority: priority, domain: unit.domain, resources: unit.resources, gate: gate, now: now
                    )
                    if blocked == nil,
                       fits(unit.resources, priority: priority, host: unit.networkHost, occupants: occupants, gate: gate) {
                        occupants.append((priority, unit.resources, unit.networkHost))
                        if unit.state == .paused { resume(runID: unit.runID, now: now) }
                    } else {
                        stepAside(runID: unit.runID, now: now, pausedChannels: &pausedChannels)
                    }
                }
            }
            startNewUnits(priority: priority, gate: gate, now: now, occupants: &occupants)
        }

        let idleWork = hasIdleWork()
        publishGate(gate, now: now)
        updateCPUSampling(idleWork: idleWork)
        updateStatistics(now: now, gate: gate, idleWork: idleWork)
        scheduleWake(now: now)
    }

    /// Hands out new units at `priority` while their channels have room.
    private func startNewUnits(
        priority: BackgroundWorkPriority,
        gate: Gate,
        now: TimeInterval,
        occupants: inout [(priority: BackgroundWorkPriority, resources: BackgroundWorkResources, host: String?)]
    ) {
        var progressed = true
        var iterations = 0
        while progressed && iterations < 16 {
            progressed = false
            iterations += 1

            let candidates = tasks.values
                .filter { !$0.isRunning && $0.priority == priority }
                .sorted { $0.order < $1.order }
            for entry in candidates {
                guard blockReason(priority: priority, domain: entry.domain, resources: entry.resources, gate: gate, now: now) == nil,
                      fits(entry.resources, priority: priority, host: entry.networkHost, occupants: occupants, gate: gate)
                else { continue }
                var started = entry
                started.isRunning = true
                tasks[entry.key] = started
                let unit = BackgroundWorkUnit(id: entry.key, priority: priority, networkHost: entry.networkHost, run: entry.work)
                launch(unit, origin: .task(entry.key), owner: entry.owner, domain: entry.domain,
                       resources: entry.resources, runsToCompletion: entry.runsToCompletion, now: now)
                occupants.append((priority, entry.resources, entry.networkHost))
                progressed = true
                break
            }
            if progressed { continue }

            guard !sourceOrder.isEmpty else { continue }
            for offset in 0..<sourceOrder.count {
                let index = (rotation + offset) % sourceOrder.count
                let id = sourceOrder[index]
                guard let source = sources[id]?.source else { continue }
                guard !revokedOwners.contains(source.owner),
                      blockReason(priority: priority, domain: source.domain, resources: source.resources, gate: gate, now: now) == nil,
                      fits(source.resources, priority: priority, host: nil, occupants: occupants, gate: gate)
                else { continue }
                let excluded = excludedUnitIDs(sourceID: id, priority: priority, now: now)
                guard let unit = source.nextUnit(priority: priority, excluding: excluded) else { continue }
                if let host = unit.networkHost,
                   !fits(source.resources, priority: priority, host: host, occupants: occupants, gate: gate) {
                    continue
                }
                launch(unit, origin: .source(id), owner: source.owner, domain: source.domain,
                       resources: source.resources, now: now)
                occupants.append((priority, source.resources, unit.networkHost))
                rotation = (index + 1) % max(1, sourceOrder.count)
                progressed = true
                break
            }
        }
    }

    // MARK: - Admission rules

    private func capacity(_ channel: BackgroundWorkChannel, priority: BackgroundWorkPriority, gate: Gate) -> Int {
        let value: Int
        switch (channel, priority) {
        case (_, .idleBatch): value = 1
        case (.network, .upcoming): value = gate.supplyConstrained ? 1 : 2
        case (_, .upcoming): value = 1
        case (.network, .userRequested): value = 4
        case (_, .userRequested): value = 2
        }
        if priority == .userRequested && gate.userLimitedToOne { return 1 }
        return value
    }

    /// Whether a unit fits next to the units already counted. Only units at
    /// least as urgent count against it, which is what lets a more urgent unit
    /// displace a less urgent one in the same channel.
    private func fits(
        _ resources: BackgroundWorkResources,
        priority: BackgroundWorkPriority,
        host: String?,
        occupants: [(priority: BackgroundWorkPriority, resources: BackgroundWorkResources, host: String?)],
        gate: Gate
    ) -> Bool {
        for channel in BackgroundWorkChannel.allCases where resources.uses(channel) {
            let used = occupants.filter { $0.priority <= priority && $0.resources.uses(channel) }.count
            if used >= capacity(channel, priority: priority, gate: gate) { return false }
        }
        // One idle unit at a time does heavy work, whichever channel it uses.
        if priority == .idleBatch, resources.usesHeavyChannels,
           occupants.contains(where: { $0.priority == .idleBatch && $0.resources.usesHeavyChannels }) {
            return false
        }
        if let host, resources.uses(.network) {
            let sameHost = occupants.filter { $0.host == host && $0.resources.uses(.network) }.count
            if sameHost >= 2 { return false }
        }
        return true
    }

    /// Why a unit may not run right now, or nil when it may.
    private func blockReason(
        priority: BackgroundWorkPriority,
        domain: BackgroundWorkDomain,
        resources: BackgroundWorkResources,
        gate: Gate,
        now: TimeInterval
    ) -> BackgroundWaitReason? {
        let configuration = gate.configuration
        switch priority {
        case .userRequested:
            return nil
        case .upcoming:
            if gate.thermal >= .critical { return .thermal }
            if gate.memory == .critical { return .memoryPressure }
            if !domain.survivesPreparationSwitch {
                if !configuration.preparationEnabled || !configuration.allows(domain) { return .disabled }
            }
            if domain.isVisualPreparation {
                if gate.thermal >= .serious { return .thermal }
                if now < visualPausedUntil { return .memoryPressure }
            }
            if resources.uses(.network) {
                if !conditions.network.isAvailable { return .offline }
                if conditions.network.isMetered { return .expensiveNetwork }
            }
            return nil
        case .idleBatch:
            if let reason = gate.idleReason { return reason }
            if !configuration.allows(domain) { return .disabled }
            if resources.uses(.network) {
                if !conditions.network.isAvailable { return .offline }
                if conditions.network.isMetered { return .expensiveNetwork }
                if (restUntil[.network] ?? 0) > now { return .resting }
            }
            if resources.usesHeavyChannels, (restUntil[.heavy] ?? 0) > now { return .resting }
            return nil
        }
    }

    /// Whether a network unit that cannot be paused has lost the connection it
    /// needs: offline, or a metered link for work that is not user-requested.
    private func networkLost(for unit: RunningUnit) -> Bool {
        guard unit.resources.uses(.network) else { return false }
        if !conditions.network.isAvailable { return true }
        return unit.priority != .userRequested && conditions.network.isMetered
    }

    private func makeGate(now: TimeInterval) -> Gate {
        let configuration = configurationProvider()
        let thermal = conditions.thermalLevel
        let memory = conditions.memoryPressure
        let recentMemoryEvent = conditions.lastMemoryPressureEventUptime.map {
            now - $0 < Self.memoryEventQuietSeconds
        } ?? false
        let userActive = now - lastInteractionUptime < Self.interactionQuietSeconds
        userWasActive = userActive

        let reason: BackgroundWaitReason?
        if !configuration.preparationEnabled {
            reason = .disabled
        } else if !conditions.isLaunchSettled {
            reason = .launching
        } else if !conditions.isOnACPower {
            reason = .onBattery
        } else if conditions.isLowPowerModeEnabled {
            reason = .lowPowerMode
        } else if thermal >= .serious {
            reason = .thermal
        } else if memory == .critical || recentMemoryEvent {
            reason = .memoryPressure
        } else if holdRegistry.isHeld(.libraryWrite) {
            reason = .libraryBusy
        } else if holdRegistry.isHeld(.importing) {
            reason = .importing
        } else if holdRegistry.isHeld(.fullscreen) {
            reason = .userActive
        } else if now < supplyShortfallUntil {
            reason = .playbackSupply
        } else if userActive {
            reason = .userActive
        } else {
            reason = cpuGate.waitReason
        }
        return Gate(
            idleReason: reason,
            thermal: thermal,
            memory: memory,
            supplyConstrained: now < supplyShortfallUntil,
            configuration: configuration
        )
    }

    private func publishGate(_ gate: Gate, now: TimeInterval) {
        var visible = gate.idleReason
        if visible == nil, (restUntil[.heavy] ?? 0) > now { visible = .resting }
        if idleWaitReason != visible { idleWaitReason = visible }
    }

    // MARK: - Unit lifecycle

    private func excludedUnitIDs(sourceID: String, priority: BackgroundWorkPriority, now: TimeInterval) -> Set<String> {
        var excluded = Set<String>()
        for run in running.values where run.origin == .source(sourceID) { excluded.insert(run.unitID) }
        if priority != .userRequested {
            let prefix = "\(sourceID)|"
            for (key, until) in failures where until > now && key.hasPrefix(prefix) {
                excluded.insert(String(key.dropFirst(prefix.count)))
            }
        }
        return excluded
    }

    private func pruneFailures(now: TimeInterval) {
        failures = failures.filter { $0.value > now }
    }

    private func launch(
        _ unit: BackgroundWorkUnit,
        origin: Origin,
        owner: BackgroundWorkOwner,
        domain: BackgroundWorkDomain,
        resources: BackgroundWorkResources,
        runsToCompletion: Bool = false,
        now: TimeInterval
    ) {
        nextRunID += 1
        nextOrder += 1
        let runID = nextRunID
        let context = BackgroundWorkContext(taskPriority: unit.priority.taskPriority)
        let signpostID = signposter.makeSignpostID()
        var record = RunningUnit(
            runID: runID, order: nextOrder, origin: origin, unitID: unit.id, owner: owner,
            domain: domain, priority: unit.priority, resources: resources,
            networkHost: unit.networkHost, runsToCompletion: runsToCompletion, context: context
        )
        record.activeSince = now
        record.signpost = signposter.beginInterval("unit", id: signpostID, "\(domain.rawValue, privacy: .public)")
        let run = unit.run
        record.task = Task.detached(priority: unit.priority.taskPriority) { [weak self] in
            let outcome = await run(context)
            await self?.unitDidFinish(runID: runID, outcome: outcome)
        }
        running[runID] = record
        activityRevision &+= 1
    }

    private func pause(runID: UInt64, now: TimeInterval) {
        guard var unit = running[runID], unit.state == .running else { return }
        if let since = unit.activeSince { unit.activeSeconds += now - since }
        unit.activeSince = nil
        unit.state = .paused
        unit.context.setPaused(true)
        running[runID] = unit
        signposter.emitEvent("pause", "\(unit.domain.rawValue, privacy: .public)")
        activityRevision &+= 1
    }

    private func resume(runID: UInt64, now: TimeInterval) {
        guard var unit = running[runID], unit.state == .paused else { return }
        unit.activeSince = now
        unit.state = .running
        unit.context.setPaused(false)
        running[runID] = unit
        signposter.emitEvent("resume", "\(unit.domain.rawValue, privacy: .public)")
        activityRevision &+= 1
    }

    /// Makes a unit step aside. Each channel keeps at most one paused unit
    /// with its state in memory; further units give up and run again from the
    /// backlog.
    private func stepAside(runID: UInt64, now: TimeInterval, pausedChannels: inout Set<BackgroundWorkChannel>) {
        guard let unit = running[runID] else { return }
        let channels = BackgroundWorkChannel.allCases.filter { unit.resources.uses($0) }
        let slotTaken = channels.contains { pausedChannels.contains($0) }
        if slotTaken {
            stop(runID: runID, reason: .overflow)
        } else {
            pausedChannels.formUnion(channels)
            if unit.state == .running { pause(runID: runID, now: now) }
        }
    }

    private func stop(runID: UInt64, reason: StopReason) {
        guard var unit = running[runID] else { return }
        if case .stopping = unit.state { return }
        let now = clock()
        if let since = unit.activeSince { unit.activeSeconds += now - since }
        unit.activeSince = nil
        unit.state = .stopping(deadline: now + Self.stopGraceSeconds)
        unit.stopReason = reason
        unit.context.cancel()
        unit.task?.cancel()
        running[runID] = unit
        signposter.emitEvent("stop", "\(unit.domain.rawValue, privacy: .public)")
        activityRevision &+= 1
    }

    private func unitDidFinish(runID: UInt64, outcome: BackgroundWorkOutcome) {
        guard var unit = running.removeValue(forKey: runID) else { return }
        let now = clock()
        if let since = unit.activeSince { unit.activeSeconds += now - since }
        if let state = unit.signpost { signposter.endInterval("unit", state) }

        switch unit.origin {
        case .source(let id):
            if unit.priority != .userRequested {
                // A unit that failed is not offered again for a while; one that
                // completed is not offered again at once, which guards against
                // a domain that forgets to record its result.
                switch outcome {
                case .failed:
                    failures["\(id)|\(unit.unitID)"] = now + Self.failureCooldownSeconds
                case .completed:
                    let key = "\(id)|\(unit.unitID)"
                    failures[key] = max(failures[key] ?? 0, now + Self.completionCooldownSeconds)
                case .cancelled:
                    break
                }
            }
            sources[id]?.source?.unitDidEnd(unitID: unit.unitID, outcome: outcome)
        case .task(let key):
            if var entry = tasks[key] {
                if outcome == .cancelled, unit.stopReason == .overflow {
                    entry.isRunning = false
                    tasks[key] = entry
                } else {
                    tasks[key] = nil
                    entry.handle.fulfill(outcome)
                }
            }
            if outcome == .completed, !key.hasPrefix("lease:") {
                recordCompletion(of: unit.domain, persistent: unit.domain.persistsLastCompletion)
            }
        }
        if case .source = unit.origin, outcome == .completed {
            recordCompletion(of: unit.domain, persistent: false)
        }

        if unit.priority == .idleBatch, outcome != .cancelled {
            accrueRest(after: unit, now: now)
        }
        activityRevision &+= 1
        reschedule()
    }

    /// Duty cycle: an idle unit is followed by rest in proportion to the time
    /// it ran, set by machine class, pacing choice and heat.
    private func accrueRest(after unit: RunningUnit, now: TimeInterval) {
        let pool: RestPool
        if unit.resources.usesHeavyChannels {
            pool = .heavy
        } else if unit.resources.uses(.network) {
            pool = .network
        } else {
            return
        }
        let factor = deviceProfile.restFactor(
            mode: configurationProvider().pacing,
            thermalFairOrWorse: conditions.thermalLevel >= .fair
        )
        guard factor > 0 else { return }
        let debt = (restDebt[pool] ?? 0) + unit.activeSeconds * factor
        if debt >= Self.minimumRestSeconds {
            restUntil[pool] = max(restUntil[pool] ?? 0, now) + debt
            restDebt[pool] = 0
        } else {
            restDebt[pool] = debt
        }
    }

    // MARK: - CPU gate

    private func ingestCPUSample() {
        guard let average = conditions.otherCPULoadPercent else { return }
        let now = clock()
        let today = CPUBaselineStore.dayIndex(for: Date())
        // Only a filled window counts as a baseline sample.
        if conditions.cpuWindowSampleCount >= 3 {
            baselineStore.record(percent: average, day: today)
            if now - lastBaselineSave >= Self.baselineSaveInterval { saveBaseline(now: now) }
        }
        cpuGate.ingest(average: average, baseline: baselineStore.baseline(today: today), now: now)
        reschedule()
    }

    private func saveBaseline(now: TimeInterval) {
        lastBaselineSave = now
        if let data = try? JSONEncoder().encode(baselineStore) {
            defaults.set(data, forKey: Self.baselineDefaultsKey)
        }
    }

    /// Samples only while idle work waits and the machine could run it.
    private func updateCPUSampling(idleWork: Bool) {
        let configuration = configurationProvider()
        let needed = configuration.preparationEnabled
            && conditions.isOnACPower
            && !conditions.isLowPowerModeEnabled
            && idleWork
        conditions.setCPUSampling(needed, requester: "background-scheduler")
        if !needed, cpuGate.hasSample || cpuGate.isOpen {
            cpuGate.reset()
            saveBaseline(now: clock())
        }
    }

    private func hasIdleWork() -> Bool {
        if tasks.values.contains(where: { $0.priority == .idleBatch }) { return true }
        if running.values.contains(where: { $0.priority == .idleBatch }) { return true }
        let now = clock()
        for id in sourceOrder {
            guard let source = sources[id]?.source else { continue }
            let excluded = excludedUnitIDs(sourceID: id, priority: .idleBatch, now: now)
            if source.hasWork(priority: .idleBatch, excluding: excluded) { return true }
        }
        return false
    }

    // MARK: - Statistics

    private func updateStatistics(now: TimeInterval, gate: Gate, idleWork: Bool? = nil) {
        var state = BackgroundSchedulingStatistics.State()
        state.onACPower = conditions.isOnACPower
        state.thermal = conditions.thermalLevel
        state.memory = conditions.memoryPressure
        let idleRunning = running.values.contains { $0.priority == .idleBatch && $0.state == .running }
        state.idleRunning = idleRunning
        state.idlePending = idleRunning || (idleWork ?? hasIdleWork())
        var reason = gate.idleReason
        if reason == nil, (restUntil[.heavy] ?? 0) > now { reason = .resting }
        state.waitReason = reason
        statistics.advance(to: now, state: state)

        if now - lastDailyLog >= Self.dailyLogInterval {
            lastDailyLog = now
            Log.info(statistics.logLine(), category: .background)
        }
    }

    private func statisticsTick() {
        conditions.refreshMemoryPressure()
        let now = clock()
        updateStatistics(now: now, gate: makeGate(now: now))
    }

    // MARK: - Wake-ups

    private func scheduleWake(now: TimeInterval) {
        var deadlines: [TimeInterval] = []
        for until in restUntil.values where until > now { deadlines.append(until) }
        if supplyShortfallUntil > now { deadlines.append(supplyShortfallUntil) }
        if visualPausedUntil > now { deadlines.append(visualPausedUntil) }
        if let last = conditions.lastMemoryPressureEventUptime {
            let end = last + Self.memoryEventQuietSeconds
            if end > now { deadlines.append(end) }
        }
        if userWasActive { deadlines.append(lastInteractionUptime + Self.interactionQuietSeconds) }
        for run in running.values {
            if case .stopping(let deadline) = run.state, deadline > now { deadlines.append(deadline) }
        }
        for until in failures.values where until > now { deadlines.append(until) }

        guard let next = deadlines.min() else {
            wakeTask?.cancel()
            wakeTask = nil
            wakeAt = nil
            return
        }
        if let wakeAt, wakeAt <= next, wakeAt > now { return }
        wakeTask?.cancel()
        wakeAt = next
        let delay = max(0.05, next - now)
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.wakeAt = nil
            self?.reschedule()
        }
    }
}
