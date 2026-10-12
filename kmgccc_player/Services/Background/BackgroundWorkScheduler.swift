import AppKit
import Darwin
import Foundation
import IOKit.ps
import Observation

/// Order in which deferrable work is admitted. Real-time work (audio supply,
/// what the listener is looking at) never goes through the scheduler.
nonisolated enum BackgroundWorkPriority: Int, Comparable, Codable, Sendable {
    /// Started by the listener, such as analyzing the current song.
    case userRequested = 0
    /// Needed soon, such as the next songs in the queue.
    case upcoming = 1
    /// Library-wide preparation that only uses spare capacity.
    case idleBatch = 2

    nonisolated static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct BackgroundWorkResources: OptionSet, Sendable {
    let rawValue: Int
    nonisolated static let cpu = BackgroundWorkResources(rawValue: 1 << 0)
    nonisolated static let diskRead = BackgroundWorkResources(rawValue: 1 << 1)
    nonisolated static let network = BackgroundWorkResources(rawValue: 1 << 2)
}

/// Why idle batch work is not running right now.
nonisolated enum BackgroundWaitReason: String, Equatable, Sendable {
    case onBattery
    case lowPowerMode
    case thermal
    case memoryPressure
    case systemBusy
    case confirmingIdle
    case libraryBusy
    case userActive
    case playbackSupply

    nonisolated var message: String {
        switch self {
        case .onBattery: "等待接通电源"
        case .lowPowerMode: "低电量模式下暂停"
        case .thermal: "设备温度较高，稍后继续"
        case .memoryPressure: "内存紧张，稍后继续"
        case .systemBusy: "系统负载较高，稍后继续"
        case .confirmingIdle: "等待空闲"
        case .libraryBusy: "资料库正在更新"
        case .userActive: "正在使用，稍后继续"
        case .playbackSupply: "播放优先，稍后继续"
        }
    }
}

/// Cooperative pause and cancel point handed to scheduled work. Work calls
/// `checkpoint()` at chunk boundaries; a pause is not a failure.
nonisolated final class BackgroundWorkContext: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false

    nonisolated var isPaused: Bool { lock.withLock { paused } }
    nonisolated var isCancelled: Bool { lock.withLock { cancelled } }

    nonisolated func setPaused(_ value: Bool) { lock.withLock { paused = value } }
    nonisolated func cancel() { lock.withLock { cancelled = true } }

    nonisolated func checkpoint() async throws {
        while true {
            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }
            guard isPaused else { return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// App-wide admission, priority and resource budget for deferrable work.
/// Domain services still execute and store their own results; the scheduler
/// only decides when work may run. One heavy CPU task runs at a time; a more
/// urgent task pauses a less urgent one at its next checkpoint.
///
/// The "body clock" conditions apply to idle batch work only: it runs on AC
/// power, outside Low Power Mode, below serious thermal state, without memory
/// pressure, while the library is not writing, the listener is not actively
/// using the App, audio supply is healthy, and the rest of the system (this
/// App excluded) has used under 30 % of total CPU for about 30 s. It pauses
/// above 40 %. Samples are only taken while idle work is waiting.
@Observable
@MainActor
final class BackgroundWorkScheduler {
    nonisolated enum EntryState: Sendable { case pending, running, paused }

    private struct Entry {
        let key: String
        let group: String
        var priority: BackgroundWorkPriority
        let resources: BackgroundWorkResources
        let work: @Sendable (BackgroundWorkContext) async -> Void
        let context = BackgroundWorkContext()
        var state: EntryState = .pending
        var task: Task<Void, Never>?
        let order: UInt64
    }

    private(set) var idleWaitReason: BackgroundWaitReason?
    private(set) var runningKey: String?
    private(set) var isOnACPower = true
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var otherCPULoadPercent: Double?

    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var nextOrder: UInt64 = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var memorySource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var interactionMonitor: Any?
    @ObservationIgnored private var samplingTimer: Timer?
    @ObservationIgnored private var cpuSamples: [(time: TimeInterval, otherPercent: Double)] = []
    @ObservationIgnored private var lastCPUReading: (busy: UInt64, total: UInt64, ownSeconds: Double)?
    @ObservationIgnored private var cpuGateOpen = false
    @ObservationIgnored private var lowLoadSince: TimeInterval?
    @ObservationIgnored private var memoryPressureUntil: TimeInterval = 0
    @ObservationIgnored private var supplyShortfallUntil: TimeInterval = 0
    @ObservationIgnored private var lastInteractionUptime: TimeInterval = 0
    @ObservationIgnored private let hostPort = mach_host_self()
    @ObservationIgnored private var started = false

    /// True while the active library performs writes such as an import.
    @ObservationIgnored var libraryBusyProvider: (@MainActor () -> Bool)?

    nonisolated static let idleStartThresholdPercent = 30.0
    nonisolated static let idlePauseThresholdPercent = 40.0
    nonisolated static let idleConfirmationSeconds: TimeInterval = 30
    nonisolated static let samplingInterval: TimeInterval = 7
    nonisolated static let interactionQuietSeconds: TimeInterval = 5

    init() {}

    /// Starts the event sources. Called once by the App dependency owner.
    func start() {
        guard !started else { return }
        started = true
        refreshPowerSource()
        installPowerSourceNotification()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.reschedule()
            }
        })
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reschedule() }
        })
        let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memory.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memoryPressureUntil = ProcessInfo.processInfo.systemUptime + 60
                self.reschedule()
            }
        }
        memory.resume()
        memorySource = memory
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            self?.noteUserInteraction()
            return event
        }
    }

    // MARK: - Submission

    /// Adds work under a stable key. A key that is already known keeps its
    /// progress; a more urgent request only raises its priority.
    func submit(
        key: String,
        group: String,
        priority: BackgroundWorkPriority,
        resources: BackgroundWorkResources = [.cpu, .diskRead],
        work: @escaping @Sendable (BackgroundWorkContext) async -> Void
    ) {
        if var existing = entries[key] {
            if priority < existing.priority {
                existing.priority = priority
                entries[key] = existing
                reschedule()
            }
            return
        }
        nextOrder += 1
        entries[key] = Entry(
            key: key, group: group, priority: priority, resources: resources,
            work: work, order: nextOrder
        )
        reschedule()
    }

    func contains(key: String) -> Bool { entries[key] != nil }

    func priority(of key: String) -> BackgroundWorkPriority? { entries[key]?.priority }

    func state(of key: String) -> EntryState? { entries[key]?.state }

    func pendingCount(group: String, priority: BackgroundWorkPriority? = nil) -> Int {
        entries.values.filter { $0.group == group && (priority == nil || $0.priority == priority) }.count
    }

    func cancel(key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.context.cancel()
        entry.task?.cancel()
        if runningKey == key { runningKey = nil }
        reschedule()
    }

    /// Withdraws every entry of a group, for example when a library closes.
    func cancel(group: String) {
        for key in entries.values.filter({ $0.group == group }).map(\.key) {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            entry.context.cancel()
            entry.task?.cancel()
            if runningKey == key { runningKey = nil }
        }
        reschedule()
    }

    // MARK: - Signals

    /// Audio supply ran short; idle work yields for a while.
    func noteAudioSupplyShortfall() {
        supplyShortfallUntil = ProcessInfo.processInfo.systemUptime + 30
        reschedule()
    }

    /// Library write activity or another external condition changed.
    func reevaluate() { reschedule() }

    private func noteUserInteraction() {
        lastInteractionUptime = ProcessInfo.processInfo.systemUptime
        if let runningKey, entries[runningKey]?.priority == .idleBatch {
            reschedule()
        }
    }

    // MARK: - Scheduling

    private func reschedule() {
        updateIdleConditions()
        let idleAllowed = idleWaitReason == nil
        func allowed(_ entry: Entry) -> Bool { entry.priority != .idleBatch || idleAllowed }

        let candidate = entries.values
            .filter(allowed)
            .min { ($0.priority, $0.order) < ($1.priority, $1.order) }

        if let runningKey, var running = entries[runningKey] {
            let shouldYield = !allowed(running)
                || (candidate.map { $0.key != runningKey && $0.priority < running.priority } ?? false)
            guard shouldYield else { return }
            running.context.setPaused(true)
            running.state = .paused
            entries[runningKey] = running
            self.runningKey = nil
        }
        guard let candidate, var entry = entries[candidate.key] else {
            updateSamplingTimer()
            return
        }
        switch entry.state {
        case .paused:
            entry.context.setPaused(false)
            entry.state = .running
        case .pending:
            entry.state = .running
            let key = entry.key
            let work = entry.work
            let context = entry.context
            entry.task = Task.detached(priority: .utility) { [weak self] in
                await work(context)
                await self?.finish(key: key)
            }
        case .running:
            break
        }
        entries[entry.key] = entry
        runningKey = entry.key
        updateSamplingTimer()
    }

    private func finish(key: String) {
        entries.removeValue(forKey: key)
        if runningKey == key { runningKey = nil }
        reschedule()
    }

    private func updateIdleConditions() {
        let now = ProcessInfo.processInfo.systemUptime
        let reason: BackgroundWaitReason?
        if !isOnACPower {
            reason = .onBattery
        } else if isLowPowerModeEnabled {
            reason = .lowPowerMode
        } else if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            reason = .thermal
        } else if now < memoryPressureUntil {
            reason = .memoryPressure
        } else if libraryBusyProvider?() == true {
            reason = .libraryBusy
        } else if now < supplyShortfallUntil {
            reason = .playbackSupply
        } else if now - lastInteractionUptime < Self.interactionQuietSeconds {
            reason = .userActive
        } else if !cpuGateOpen {
            reason = cpuSamples.isEmpty || lowLoadSince != nil ? .confirmingIdle : .systemBusy
        } else {
            reason = nil
        }
        if idleWaitReason != reason { idleWaitReason = reason }
    }

    // MARK: - CPU load excluding this process

    private var hasIdleWork: Bool { entries.values.contains { $0.priority == .idleBatch } }

    private func updateSamplingTimer() {
        let needsSampling = hasIdleWork && isOnACPower && !isLowPowerModeEnabled
        if needsSampling, samplingTimer == nil {
            lastCPUReading = Self.cpuReading(host: hostPort)
            let timer = Timer(timeInterval: Self.samplingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sampleCPU() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            samplingTimer = timer
        } else if !needsSampling, let timer = samplingTimer {
            timer.invalidate()
            samplingTimer = nil
            cpuSamples.removeAll()
            lowLoadSince = nil
            cpuGateOpen = false
            otherCPULoadPercent = nil
        }
    }

    private func sampleCPU() {
        guard let current = Self.cpuReading(host: hostPort) else { return }
        defer { lastCPUReading = current }
        guard let previous = lastCPUReading, current.total > previous.total else { return }
        let totalTicks = Double(current.total - previous.total)
        let busyFraction = Double(current.busy &- previous.busy) / totalTicks
        let ticksPerSecond = Double(max(1, sysconf(_SC_CLK_TCK)))
        let ownFraction = max(0, current.ownSeconds - previous.ownSeconds) * ticksPerSecond / totalTicks
        let other = max(0, min(100, (busyFraction - ownFraction) * 100))
        let now = ProcessInfo.processInfo.systemUptime
        cpuSamples.append((now, other))
        cpuSamples.removeAll { now - $0.time > Self.idleConfirmationSeconds }
        let average = cpuSamples.map(\.otherPercent).reduce(0, +) / Double(cpuSamples.count)
        otherCPULoadPercent = average

        if cpuGateOpen {
            if average > Self.idlePauseThresholdPercent {
                cpuGateOpen = false
                lowLoadSince = nil
            }
        } else if average < Self.idleStartThresholdPercent {
            if let since = lowLoadSince {
                if now - since >= Self.idleConfirmationSeconds { cpuGateOpen = true }
            } else {
                lowLoadSince = now
            }
        } else if average > Self.idleStartThresholdPercent {
            lowLoadSince = nil
        }
        reschedule()
    }

    private nonisolated static func cpuReading(host: mach_port_t) -> (busy: UInt64, total: UInt64, ownSeconds: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let own = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return (user + system + nice, user + system + nice + idle, own)
    }

    // MARK: - Power source

    private func installPowerSourceNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let scheduler = Unmanaged<BackgroundWorkScheduler>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                scheduler.refreshPowerSource()
                scheduler.reschedule()
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func refreshPowerSource() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            // A desktop Mac without a power source report runs on AC power.
            isOnACPower = true
            return
        }
        isOnACPower = (type as String) == kIOPMACPowerKey
    }
}
