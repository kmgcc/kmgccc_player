import Foundation
import Observation

/// Gain-reduction readings of one metering node for one analysis chunk:
/// low, mid, high and full-band reduction in decibels.
nonisolated struct DSPNodeMeterReading: Sendable, Equatable {
    let nodeID: UUID
    let values: [Float]
}

/// Latest meter readings as they become audible. The renderer publishes a
/// chunk's readings when that chunk reaches the output clock, so a card
/// shows what is heard rather than what is queued.
nonisolated final class DSPMeterBus: @unchecked Sendable {
    static let shared = DSPMeterBus()

    private let lock = NSLock()
    private var readings: [UUID: (values: [Float], time: TimeInterval)] = [:]
    private var wakers: [UUID: @MainActor @Sendable () -> Void] = [:]
    private var observers: [UUID: [UUID: @MainActor @Sendable ([Float]) -> Void]] = [:]

    func publish(_ batch: [DSPNodeMeterReading]) {
        guard !batch.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var due: [@MainActor @Sendable () -> Void] = []
        var dueObservers: [(@MainActor @Sendable ([Float]) -> Void, [Float])] = []
        lock.lock()
        for reading in batch {
            readings[reading.nodeID] = (reading.values, now)
            if let waker = wakers.removeValue(forKey: reading.nodeID) { due.append(waker) }
            if let nodeObservers = observers[reading.nodeID], !nodeObservers.isEmpty {
                for observer in nodeObservers.values {
                    dueObservers.append((observer, reading.values))
                }
            }
        }
        lock.unlock()
        guard !due.isEmpty || !dueObservers.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for waker in due { waker() }
                for (observer, values) in dueObservers { observer(values) }
            }
        }
    }

    /// Registers a continuous observer for a node's readings on the main actor.
    @discardableResult
    func addObserver(for nodeID: UUID, id: UUID = UUID(), _ action: @escaping @MainActor @Sendable ([Float]) -> Void) -> UUID {
        lock.lock()
        observers[nodeID, default: [:]][id] = action
        lock.unlock()
        return id
    }

    /// Removes an observer registered via `addObserver`.
    func removeObserver(for nodeID: UUID, id: UUID) {
        lock.lock()
        observers[nodeID]?.removeValue(forKey: id)
        if observers[nodeID]?.isEmpty == true { observers.removeValue(forKey: nodeID) }
        lock.unlock()
    }

    /// Runs `action` once on the main actor when the node's next reading
    /// arrives, so an idle meter view can sleep instead of polling.
    func wakeOnNextReading(for nodeID: UUID, _ action: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        wakers[nodeID] = action
        lock.unlock()
    }

    func cancelWake(for nodeID: UUID) {
        lock.lock()
        wakers.removeValue(forKey: nodeID)
        lock.unlock()
    }

    /// The node's newest values, or nil when none arrived within `maximumAge`.
    func latest(for nodeID: UUID, maximumAge: TimeInterval = 0.25) -> [Float]? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard let entry = readings[nodeID], now - entry.time <= maximumAge else { return nil }
        return entry.values
    }

    func clear() {
        lock.lock()
        readings.removeAll()
        wakers.removeAll()
        lock.unlock()
    }
}

/// Tracks whether the safety limiter has recently triggered compression.
/// When gain reduction occurs, the warning is held active for two seconds.
/// Any subsequent gain reduction within that window refreshes the timer.
@Observable
@MainActor
final class DSPLimiterWarningPresentation {
    /// Whether safety limiter compression has occurred within the last two seconds.
    private(set) var isWarningActive: Bool = false

    /// The latest gain reduction reading in decibels.
    private(set) var lastReductionDB: Float = 0

    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var observerID: UUID?

    static let holdDuration: TimeInterval = 2.0
    static let reductionThresholdDB: Float = 0.05

    init() {
        startObserving()
    }

    deinit {
        if let observerID {
            DSPMeterBus.shared.removeObserver(for: DSPLimiterConfiguration.nodeID, id: observerID)
        }
    }

    private func startObserving() {
        let id = UUID()
        self.observerID = id
        DSPMeterBus.shared.addObserver(for: DSPLimiterConfiguration.nodeID, id: id) { [weak self] values in
            guard let self, let reduction = values.first, reduction >= Self.reductionThresholdDB else { return }
            self.recordTrigger(reductionDB: reduction)
        }
    }

    func recordTrigger(reductionDB: Float) {
        lastReductionDB = reductionDB
        isWarningActive = true
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdDuration))
            guard !Task.isCancelled, let self else { return }
            self.isWarningActive = false
            self.lastReductionDB = 0
        }
    }

    func reset() {
        holdTask?.cancel()
        holdTask = nil
        isWarningActive = false
        lastReductionDB = 0
    }
}
