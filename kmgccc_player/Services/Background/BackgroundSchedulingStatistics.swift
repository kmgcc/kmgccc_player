import Foundation

nonisolated enum SystemThermalLevel: Int, Comparable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    nonisolated static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    nonisolated init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

nonisolated enum SystemMemoryPressureLevel: Int, Comparable, Sendable {
    case normal = 0
    case warning = 1
    case critical = 2

    nonisolated static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension BackgroundWaitReason {
    /// Stable key used by the anonymous scheduling statistics.
    nonisolated var statisticsKey: String {
        switch self {
        case .disabled: "disabled"
        case .launching: "launching"
        case .onBattery: "on_battery"
        case .lowPowerMode: "low_power_mode"
        case .thermal: "thermal"
        case .memoryPressure: "memory_pressure"
        case .systemBusy: "system_busy"
        case .confirmingIdle: "confirming_idle"
        case .libraryBusy: "library_busy"
        case .importing: "importing"
        case .userActive: "user_active"
        case .playbackSupply: "playback_supply"
        case .resting: "resting"
        case .offline: "offline"
        case .expensiveNetwork: "expensive_network"
        }
    }
}

/// Session totals of how the Mac and the scheduler behaved, kept as time in
/// each state. It holds only durations and no content; the anonymous
/// statistics and the daily log line are built from it.
nonisolated struct BackgroundSchedulingStatistics: Sendable {
    nonisolated struct State: Equatable, Sendable {
        var onACPower = true
        var thermal: SystemThermalLevel = .nominal
        var memory: SystemMemoryPressureLevel = .normal
        /// Idle batch work exists, whether running, paused or waiting.
        var idlePending = false
        var idleRunning = false
        var waitReason: BackgroundWaitReason?

        nonisolated init() {}
    }

    private(set) var startedAt: TimeInterval
    private var lastTime: TimeInterval
    private var state = State()

    private(set) var sessionSeconds: Double = 0
    private(set) var onACSeconds: Double = 0
    private(set) var thermalSeconds: [SystemThermalLevel: Double] = [:]
    private(set) var memorySeconds: [SystemMemoryPressureLevel: Double] = [:]
    private(set) var idlePendingSeconds: Double = 0
    private(set) var idleRunningSeconds: Double = 0
    private(set) var waitSeconds: [BackgroundWaitReason: Double] = [:]
    /// Waiting time while on AC power; the blockers that matter for tuning.
    private(set) var waitSecondsOnAC: [BackgroundWaitReason: Double] = [:]

    nonisolated init(now: TimeInterval) {
        startedAt = now
        lastTime = now
    }

    /// Attributes the time since the last call to the previous state, then
    /// switches to `newState`.
    nonisolated mutating func advance(to now: TimeInterval, state newState: State) {
        let delta = max(0, now - lastTime)
        if delta > 0 {
            sessionSeconds += delta
            if state.onACPower { onACSeconds += delta }
            if state.thermal != .nominal { thermalSeconds[state.thermal, default: 0] += delta }
            if state.memory != .normal { memorySeconds[state.memory, default: 0] += delta }
            if state.idlePending {
                idlePendingSeconds += delta
                if state.idleRunning {
                    idleRunningSeconds += delta
                } else if let reason = state.waitReason {
                    waitSeconds[reason, default: 0] += delta
                    if state.onACPower { waitSecondsOnAC[reason, default: 0] += delta }
                }
            }
        }
        lastTime = now
        state = newState
    }

    /// Share of idle-pending time lost to each reason, largest first.
    nonisolated func waitShares(onACOnly: Bool = false) -> [(reason: BackgroundWaitReason, share: Double)] {
        let source = onACOnly ? waitSecondsOnAC : waitSeconds
        let total = source.values.reduce(0, +)
        guard total > 0 else { return [] }
        return source
            .map { (reason: $0.key, share: $0.value / total) }
            .sorted { $0.share > $1.share }
    }

    /// One line for the daily log.
    nonisolated func logLine() -> String {
        func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
        let session = max(sessionSeconds, 1)
        let waits = waitShares(onACOnly: true).prefix(4)
            .map { "\($0.reason.statisticsKey)=\(percent($0.share))%" }
            .joined(separator: " ")
        return "[Background] day summary session=\(Int(sessionSeconds))s "
            + "ac=\(percent(onACSeconds / session))% "
            + "idlePending=\(percent(idlePendingSeconds / session))% "
            + "idleRunning=\(percent(idleRunningSeconds / session))% "
            + "waitOnAC[\(waits)]"
    }
}

/// The anonymous per-session summary: bands and ratios only.
nonisolated struct BackgroundSchedulingSummary: Equatable, Sendable {
    var cpuBaselineBand: String?
    var acPowerRatio: Double
    var thermalRatios: [String: Double]
    var memoryRatios: [String: Double]
    var idlePendingRatio: Double
    var idleRunRatio: Double
    var waitRatios: [String: Double]
    var pacing: String
    var preparationEnabled: Bool

    /// Bands for the learned baseline of the other processes' CPU load.
    nonisolated static func baselineBand(_ percent: Double) -> String {
        switch percent {
        case ..<10: "lt10"
        case ..<20: "10_20"
        case ..<30: "20_30"
        case ..<40: "30_40"
        default: "ge40"
        }
    }

    nonisolated init(
        statistics: BackgroundSchedulingStatistics,
        learnedBaseline: Double?,
        pacing: BackgroundPacingMode,
        preparationEnabled: Bool
    ) {
        let session = max(statistics.sessionSeconds, 1)
        func ratio(_ seconds: Double, of total: Double) -> Double {
            guard total > 0 else { return 0 }
            return (min(1, max(0, seconds / total)) * 100).rounded() / 100
        }
        cpuBaselineBand = learnedBaseline.map(Self.baselineBand)
        acPowerRatio = ratio(statistics.onACSeconds, of: session)
        thermalRatios = [
            "fair": ratio(statistics.thermalSeconds[.fair] ?? 0, of: session),
            "serious": ratio(statistics.thermalSeconds[.serious] ?? 0, of: session),
            "critical": ratio(statistics.thermalSeconds[.critical] ?? 0, of: session),
        ]
        memoryRatios = [
            "warning": ratio(statistics.memorySeconds[.warning] ?? 0, of: session),
            "critical": ratio(statistics.memorySeconds[.critical] ?? 0, of: session),
        ]
        idlePendingRatio = ratio(statistics.idlePendingSeconds, of: session)
        idleRunRatio = ratio(statistics.idleRunningSeconds, of: session)
        var waits: [String: Double] = [:]
        for (reason, seconds) in statistics.waitSeconds {
            waits[reason.statisticsKey] = ratio(seconds, of: statistics.idlePendingSeconds)
        }
        waitRatios = waits
        self.pacing = pacing.rawValue
        self.preparationEnabled = preparationEnabled
    }
}
