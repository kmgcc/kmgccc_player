import Foundation

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

    func publish(_ batch: [DSPNodeMeterReading]) {
        guard !batch.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var due: [@MainActor @Sendable () -> Void] = []
        lock.lock()
        for reading in batch {
            readings[reading.nodeID] = (reading.values, now)
            if let waker = wakers.removeValue(forKey: reading.nodeID) { due.append(waker) }
        }
        lock.unlock()
        guard !due.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for waker in due { waker() } }
        }
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
        lock.unlock()
    }
}
