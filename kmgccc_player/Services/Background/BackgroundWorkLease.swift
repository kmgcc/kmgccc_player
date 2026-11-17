import Foundation

/// A claim on channel slots, held by work that runs in its own pipeline (a
/// bounded import-time enrichment, a folder scan, a tag write). The pipeline
/// keeps its own parallelism and execution; the claim only makes the scheduler
/// count it, so idle work steps aside while the claim is held. Release it
/// when the unit of work ends. A claim that is dropped without release ends
/// when the scheduler drops it.
nonisolated final class BackgroundLease: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    private var ended = false
    private var released = false
    private var grantWaiter: CheckedContinuation<Bool, Never>?
    private var holdWaiter: CheckedContinuation<Void, Never>?
    private var grantTimeoutTask: Task<Void, Never>?
    private var grantWaitCancelled = false
    private var grantWaitTimedOut = false

    nonisolated init() {}

    /// Whether the last grant wait ended because its timeout elapsed, so a
    /// caller can report a timed-out claim apart from a cancelled one.
    nonisolated var waitTimedOut: Bool {
        lock.withLock { grantWaitTimedOut }
    }

    // MARK: Holder side

    /// Ends the claim and frees its slots.
    nonisolated func release() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { holdWaiter = nil }
            return holdWaiter
        }
        waiter?.resume()
    }

    /// Suspends until the slots are granted. False when the claim ended
    /// without being granted (cancelled while waiting, owner revoked), when
    /// `timeout` elapsed, or when the calling task is cancelled. A wait that
    /// gives up abandons the claim, so it is never granted afterwards. The
    /// remaining slots are released by the scheduler cancelling the claim.
    nonisolated func waitForGrant(timeout: Duration? = nil) async -> Bool {
        if Task.isCancelled {
            cancelGrantWait()
            return false
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate: Bool? = lock.withLock {
                    if granted { return true }
                    if ended { return false }
                    if grantWaitCancelled { return false }
                    grantWaiter = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }
                guard let timeout else { return }
                let timer = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.resolveGrantWait(returning: false, timedOut: true)
                }
                let timerStored = lock.withLock { () -> Bool in
                    guard grantWaiter != nil else { return false }
                    grantTimeoutTask = timer
                    return true
                }
                if !timerStored { timer.cancel() }
            }
        } onCancel: {
            self.cancelGrantWait()
        }
    }

    /// Resolves the pending grant waiter under the lock, so a continuation is
    /// resumed exactly once even when a timeout, a grant and a cancellation
    /// race. A timeout is remembered for `waitTimedOut`.
    nonisolated private func resolveGrantWait(returning value: Bool, timedOut: Bool) {
        let (waiter, timer) = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) in
            if timedOut { grantWaitTimedOut = true }
            defer {
                grantWaiter = nil
                grantTimeoutTask = nil
            }
            return (grantWaiter, grantTimeoutTask)
        }
        timer?.cancel()
        waiter?.resume(returning: value)
    }

    /// Gives up the wait immediately when the calling task is cancelled. The
    /// gate stays closed so a later grant cannot resume a stale waiter.
    nonisolated private func cancelGrantWait() {
        let (waiter, timer) = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) in
            grantWaitCancelled = true
            defer {
                grantWaiter = nil
                grantTimeoutTask = nil
            }
            return (grantWaiter, grantTimeoutTask)
        }
        timer?.cancel()
        waiter?.resume(returning: false)
    }

    // MARK: Scheduler side

    nonisolated func markGranted() {
        let (waiter, timer) = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) in
            granted = true
            defer {
                grantWaiter = nil
                grantTimeoutTask = nil
            }
            return (grantWaiter, grantTimeoutTask)
        }
        timer?.cancel()
        waiter?.resume(returning: true)
    }

    /// Suspends the scheduler's placeholder unit until the holder releases.
    nonisolated func holdUntilReleased() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = lock.withLock { () -> Bool in
                if released || ended { return true }
                holdWaiter = continuation
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    /// The scheduler dropped the claim.
    nonisolated func markEnded() {
        let (grantContinuation, holdContinuation, timer, wasGranted) = lock.withLock {
            () -> (CheckedContinuation<Bool, Never>?, CheckedContinuation<Void, Never>?, Task<Void, Never>?, Bool) in
            ended = true
            defer {
                grantWaiter = nil
                holdWaiter = nil
                grantTimeoutTask = nil
            }
            return (grantWaiter, holdWaiter, grantTimeoutTask, granted)
        }
        timer?.cancel()
        grantContinuation?.resume(returning: wasGranted)
        holdContinuation?.resume()
    }
}

/// Why a service that borrowed channel slots does or does not hold a claim.
/// Callers that only need the claim read `lease`; a caller that reports the
/// wait outcome can tell a timed-out wait apart from an unavailable scheduler.
nonisolated enum BackgroundWorkLeaseAcquisition: Sendable {
    case granted(BackgroundLease)
    /// The channels stayed busy past the wait limit. The caller runs without a
    /// counted claim so enrichment cannot hang on the scheduler forever.
    case timedOut
    /// No scheduler to borrow from, the claim was cancelled, or its owner was
    /// revoked before it was granted.
    case unavailable

    nonisolated var lease: BackgroundLease? {
        if case .granted(let lease) = self { return lease }
        return nil
    }
}

/// How a service that is not on the main actor borrows channel slots from the
/// App scheduler. A service without a scheduler (previews, tests) holds
/// `.none`, which grants nothing and never waits.
nonisolated struct BackgroundWorkLender: Sendable {
    typealias Acquire = @Sendable (
        BackgroundWorkDomain, BackgroundWorkPriority, BackgroundWorkResources, String?, Duration?
    ) async -> BackgroundWorkLeaseAcquisition

    private let acquire: Acquire

    nonisolated init(acquire: @escaping Acquire) {
        self.acquire = acquire
    }

    nonisolated static let none = BackgroundWorkLender { _, _, _, _, _ in .unavailable }

    nonisolated func lease(
        domain: BackgroundWorkDomain,
        priority: BackgroundWorkPriority,
        resources: BackgroundWorkResources,
        networkHost: String? = nil
    ) async -> BackgroundLease? {
        await acquire(domain, priority, resources, networkHost, nil).lease
    }

    /// Like `lease`, but reports why no claim was held. `waitTimeout` limits how
    /// long the claim waits for channel slots; on expiry the caller continues
    /// without a counted claim.
    nonisolated func acquireLease(
        domain: BackgroundWorkDomain,
        priority: BackgroundWorkPriority,
        resources: BackgroundWorkResources,
        networkHost: String? = nil,
        waitTimeout: Duration? = nil
    ) async -> BackgroundWorkLeaseAcquisition {
        await acquire(domain, priority, resources, networkHost, waitTimeout)
    }

    /// Runs `operation` while holding the slots, and frees them afterwards.
    nonisolated func withLease<T>(
        domain: BackgroundWorkDomain,
        priority: BackgroundWorkPriority,
        resources: BackgroundWorkResources,
        networkHost: String? = nil,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let held = await lease(
            domain: domain, priority: priority, resources: resources, networkHost: networkHost
        )
        defer { held?.release() }
        return try await operation()
    }
}
