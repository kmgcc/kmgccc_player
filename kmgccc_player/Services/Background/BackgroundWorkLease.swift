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

    nonisolated init() {}

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
    /// without being granted (cancelled while waiting, owner revoked).
    nonisolated func waitForGrant() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let immediate: Bool? = lock.withLock {
                if granted { return true }
                if ended { return false }
                grantWaiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    // MARK: Scheduler side

    nonisolated func markGranted() {
        let waiter = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            granted = true
            defer { grantWaiter = nil }
            return grantWaiter
        }
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
        let (grantContinuation, holdContinuation, wasGranted) = lock.withLock {
            () -> (CheckedContinuation<Bool, Never>?, CheckedContinuation<Void, Never>?, Bool) in
            ended = true
            defer {
                grantWaiter = nil
                holdWaiter = nil
            }
            return (grantWaiter, holdWaiter, granted)
        }
        grantContinuation?.resume(returning: wasGranted)
        holdContinuation?.resume()
    }
}

/// How a service that is not on the main actor borrows channel slots from the
/// App scheduler. A service without a scheduler (previews, tests) holds
/// `.none`, which grants nothing and never waits.
nonisolated struct BackgroundWorkLender: Sendable {
    typealias Acquire = @Sendable (
        BackgroundWorkDomain, BackgroundWorkPriority, BackgroundWorkResources, String?
    ) async -> BackgroundLease?

    private let acquire: Acquire

    nonisolated init(acquire: @escaping Acquire) {
        self.acquire = acquire
    }

    nonisolated static let none = BackgroundWorkLender { _, _, _, _ in nil }

    nonisolated func lease(
        domain: BackgroundWorkDomain,
        priority: BackgroundWorkPriority,
        resources: BackgroundWorkResources,
        networkHost: String? = nil
    ) async -> BackgroundLease? {
        await acquire(domain, priority, resources, networkHost)
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
