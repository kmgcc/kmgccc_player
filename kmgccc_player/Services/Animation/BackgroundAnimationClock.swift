//
//  BackgroundAnimationClock.swift
//  myPlayer2
//
//  kmgccc_player - Master clock for background animations
//  Consolidates background animation timers and adapts cadence to demand.
//

import Combine
import Foundation

/// Master clock for background animations.
/// Views keep the same typed publishers, but leases declare which channels are
/// active so the backing timer only wakes at the cadence currently required.
@MainActor
final class BackgroundAnimationClock: ObservableObject {
    
    static let shared = BackgroundAnimationClock()
    
    struct Channels: OptionSet, Sendable {
        let rawValue: Int

        static let background = Channels(rawValue: 1 << 0)
        static let shape = Channels(rawValue: 1 << 1)
        static let dot = Channels(rawValue: 1 << 2)
        static let dotHighRate = Channels(rawValue: 1 << 3)
        static let transition = Channels(rawValue: 1 << 4)
        static let speedRamp = Channels(rawValue: 1 << 5)

        static let all: Channels = [
            .background,
            .shape,
            .dot,
            .dotHighRate,
            .transition,
            .speedRamp,
        ]
    }

    private enum Cadence {
        static let background: TimeInterval = 1.0 / 0.67
        static let shape: TimeInterval = 1.0 / 15.0
        static let dot: TimeInterval = 1.0 / 15.0
        static let dotHighRate: TimeInterval = 1.0 / 30.0
        static let transition: TimeInterval = 1.0 / 6.0
        static let speedRamp: TimeInterval = 1.0 / 60.0
    }

    private enum DriverCadence: Equatable {
        case background
        case transition6
        case art15
        case art30
        case speed60

        var interval: TimeInterval {
            switch self {
            case .background:
                return Cadence.background
            case .transition6:
                return Cadence.transition
            case .art15:
                return Cadence.shape
            case .art30:
                return Cadence.dotHighRate
            case .speed60:
                return Cadence.speedRamp
            }
        }

        var shapeTickInterval: UInt64? {
            switch self {
            case .art15:
                return 1
            case .art30:
                return 2
            case .speed60:
                return 4
            default:
                return nil
            }
        }

        var dotTickInterval: UInt64? {
            shapeTickInterval
        }

        var dotHighRateTickInterval: UInt64? {
            switch self {
            case .art30:
                return 1
            case .speed60:
                return 2
            default:
                return nil
            }
        }

        var transitionTickInterval: UInt64? {
            switch self {
            case .transition6:
                return 1
            case .art30:
                return 5
            case .speed60:
                return 10
            default:
                return nil
            }
        }

        var speedRampTickInterval: UInt64? {
            self == .speed60 ? 1 : nil
        }
    }
    
    // MARK: - State
    
    private var timer: Timer?
    private var tickCount: UInt64 = 0
    private var isRunning = false
    private var isPaused = false
    private var leases: [UUID: Channels] = [:]
    private var legacyLeaseID: UUID?
    private var activeChannels: Channels = []
    private var currentDriverCadence: DriverCadence?
    private var driverTickCount: UInt64 = 0

    private var lastBackgroundFire: TimeInterval = 0
    
    /// Publishers for each phase
    let backgroundPublisher = PassthroughSubject<Void, Never>()
    let shapePublisher = PassthroughSubject<Void, Never>()
    let dotPublisher = PassthroughSubject<Void, Never>()
    let dotHighRatePublisher = PassthroughSubject<Void, Never>()
    let transitionPublisher = PassthroughSubject<Void, Never>()
    let speedRampPublisher = PassthroughSubject<Void, Never>()
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Control
    
    /// Start the master clock with full demand. Prefer `acquire(channels:)`
    /// when the caller can describe the channels it actually uses.
    func start() {
        if let legacyLeaseID {
            updateLease(legacyLeaseID, channels: .all)
        } else {
            legacyLeaseID = acquire(channels: .all)
        }

        if LogConfig.perfDebugEnabled {
            Log.info("[BackgroundAnimationClock] Started operationStack=\(FirstUseHitchDiagnostics.currentOperationStack())", category: .perf)
        }
    }

    /// Acquire a shared clock lease.
    /// The timer runs while at least one client is active.
    @discardableResult
    func acquire(channels: Channels = .all) -> UUID {
        let id = UUID()
        leases[id] = channels
        refreshDemand()
        return id
    }

    func updateLease(_ id: UUID, channels: Channels) {
        guard leases[id] != channels else { return }
        leases[id] = channels
        refreshDemand()
    }

    /// Release a shared clock lease.
    func release(_ id: UUID) {
        leases.removeValue(forKey: id)
        if legacyLeaseID == id {
            legacyLeaseID = nil
        }
        refreshDemand()
    }

    /// Legacy release for old call sites that only balance start/acquire with
    /// release. New call sites should release by token.
    func release() {
        if let id = legacyLeaseID {
            release(id)
        }
    }
    
    /// Stop the master clock.
    func stop() {
        invalidateTimer()
        isRunning = false
        isPaused = false
        tickCount = 0
        leases.removeAll(keepingCapacity: true)
        legacyLeaseID = nil
        activeChannels = []
        currentDriverCadence = nil
        driverTickCount = 0
        resetFireTimes()
        if LogConfig.perfDebugEnabled {
            Log.info("[BackgroundAnimationClock] Stopped operationStack=\(FirstUseHitchDiagnostics.currentOperationStack())", category: .perf)
        }
    }
    
    /// Pause when app is backgrounded.
    func pause() {
        guard isRunning, !isPaused else { return }
        invalidateTimer()
        isPaused = true
        if LogConfig.perfDebugEnabled {
            Log.info("[BackgroundAnimationClock] Paused", category: .perf)
        }
    }
    
    /// Resume after pause.
    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        scheduleTimerIfNeeded()
        if LogConfig.perfDebugEnabled {
            Log.info("[BackgroundAnimationClock] Resumed", category: .perf)
        }
    }
    
    // MARK: - Private

    private func refreshDemand() {
        activeChannels = leases.values.reduce(into: Channels(rawValue: 0)) { result, channels in
            result.formUnion(channels)
        }

        if activeChannels.isEmpty {
            invalidateTimer()
            isRunning = false
            isPaused = false
            tickCount = 0
            currentDriverCadence = nil
            driverTickCount = 0
            resetFireTimes()
            return
        }

        if !isRunning {
            isRunning = true
            isPaused = false
            tickCount = 0
            resetFireTimes(to: Date.timeIntervalSinceReferenceDate)
        }

        scheduleTimerIfNeeded()
    }

    private func scheduleTimerIfNeeded() {
        guard isRunning, !isPaused else { return }
        let cadence = requiredDriverCadence(for: activeChannels)
        guard currentDriverCadence != cadence || timer == nil else { return }
        scheduleTimer(cadence: cadence)
    }

    private func scheduleTimer(cadence: DriverCadence) {
        invalidateTimer()

        driverTickCount = 0
        let interval = cadence.interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        currentDriverCadence = cadence

        if LogConfig.perfDebugEnabled {
            let hz = 1.0 / interval
            Log.info("[BackgroundAnimationClock] Cadence \(String(format: "%.1f", hz))Hz channels=\(activeChannels.rawValue)", category: .perf)
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func requiredDriverCadence(for channels: Channels) -> DriverCadence {
        if channels.contains(.speedRamp) {
            return .speed60
        }
        if channels.contains(.dotHighRate) {
            return .art30
        }
        if channels.contains(.transition), !channels.intersection([.shape, .dot]).isEmpty {
            // 30Hz is the lowest common driver for the steady art rates used here:
            // 15fps floating/dot motion fires every 2 ticks, while the 6fps mask
            // transition keeps its deliberate style cadence at every 5 ticks.
            return .art30
        }

        if !channels.intersection([.shape, .dot]).isEmpty {
            return .art15
        }
        if channels.contains(.transition) {
            return .transition6
        }
        return .background
    }

    private func resetFireTimes(to time: TimeInterval = 0) {
        lastBackgroundFire = time
    }

    private func tick() {
        guard let currentDriverCadence else { return }
        let now = Date.timeIntervalSinceReferenceDate
        tickCount += 1
        driverTickCount += 1

        if activeChannels.contains(.background),
           shouldFire(now: now, lastFire: &lastBackgroundFire, interval: Cadence.background) {
            backgroundPublisher.send()
        }

        if activeChannels.contains(.shape),
           shouldFire(every: currentDriverCadence.shapeTickInterval) {
            shapePublisher.send()
        }

        if activeChannels.contains(.dot),
           shouldFire(every: currentDriverCadence.dotTickInterval) {
            dotPublisher.send()
        }

        if activeChannels.contains(.dotHighRate),
           shouldFire(every: currentDriverCadence.dotHighRateTickInterval) {
            dotHighRatePublisher.send()
        }

        if activeChannels.contains(.transition),
           shouldFire(every: currentDriverCadence.transitionTickInterval) {
            transitionPublisher.send()
        }

        if activeChannels.contains(.speedRamp),
           shouldFire(every: currentDriverCadence.speedRampTickInterval) {
            speedRampPublisher.send()
        }
    }

    private func shouldFire(every tickInterval: UInt64?) -> Bool {
        guard let tickInterval, tickInterval > 0 else { return false }
        return driverTickCount % tickInterval == 0
    }

    private func shouldFire(
        now: TimeInterval,
        lastFire: inout TimeInterval,
        interval: TimeInterval
    ) -> Bool {
        if lastFire <= 0 {
            lastFire = now
            return false
        }

        let elapsed = now - lastFire
        guard elapsed >= interval else { return false }

        if elapsed > interval * 8 {
            lastFire = now
        } else {
            repeat {
                lastFire += interval
            } while now - lastFire >= interval
        }
        return true
    }
}
