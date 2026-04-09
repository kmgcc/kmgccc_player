//
//  ArtworkDecodeGate.swift
//  myPlayer2
//
//  kmgccc_player - Artwork Decode Gate with Cancellation Support
//  Limits concurrent image decoding and supports cancellation for waiting tasks.
//

import Foundation

/// Actor that limits concurrent decode operations with cancellation support.
///
/// ## Usage
/// ```swift
/// let (acquired, token) = await decodeGate.acquire()
/// guard acquired else { return nil }  // Cancelled while waiting
/// defer { await decodeGate.release() }
/// // ... perform decode ...
/// ```
actor ArtworkDecodeGate {
    private let maxConcurrent: Int
    private var running = 0

    // Waiter storage: token -> continuation
    // Uses CheckedContinuation<Bool, Never> to signal:
    // - true: acquired slot successfully
    // - false: cancelled while waiting
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Attempts to acquire a decode slot.
    ///
    /// - Returns: A tuple containing:
    ///   - `acquired`: `true` if slot acquired (proceed with decode),
    ///                 `false` if cancelled while waiting (do not proceed)
    ///   - `token`: A stable UUID identifying this wait request. Used internally
    ///              for cancellation tracking. Nil if acquired immediately.
    ///
    /// ## Cancellation Behavior
    /// - If already cancelled before calling, returns `(false, nil)` immediately
    /// - If slot available immediately, returns `(true, nil)` immediately
    /// - If must wait, suspends until either:
    ///   - Slot becomes available: returns `(true, token)`
    ///   - Task cancelled: returns `(false, token)`
    func acquire() async -> (acquired: Bool, token: UUID?) {
        // Check pre-cancelled
        guard !Task.isCancelled else {
            return (false, nil)
        }

        // Fast path: slot available immediately
        if running < maxConcurrent {
            running += 1
            return (true, nil)
        }

        // Slow path: need to wait with cancellation support
        let token = UUID()

        return await withTaskCancellationHandler {
            let acquired = await withCheckedContinuation { continuation in
                waiters[token] = continuation
            }
            return (acquired, token)
        } onCancel: {
            // Cancellation handler: remove self from waiters and resume with false
            Task { @Sendable [weak self] in
                await self?.cancelWaiter(token)
            }
        }
    }

    /// Cancels a waiting acquire by token.
    /// Called by cancellation handler when the waiting Task is cancelled.
    private func cancelWaiter(_ token: UUID) {
        guard let continuation = waiters.removeValue(forKey: token) else {
            // Already resumed (either by release() or previous cancellation)
            return
        }
        // Resume with false = cancelled
        continuation.resume(returning: false)
    }

    /// Releases a decode slot.
    ///
    /// If there are waiting tasks, wakes the next one (FIFO order by UUID).
    /// Otherwise decrements the running count.
    ///
    /// ## Important
    /// Must be called exactly once per successful acquire(), even if the
    /// decoding task is cancelled after acquiring the slot.
    func release() {
        guard !waiters.isEmpty else {
            // No waiters: just decrement running count
            running = max(0, running - 1)
            return
        }

        // Wake next waiter (FIFO using UUID sort for stability)
        // UUID is 128-bit random, sort order is effectively insertion order
        guard let nextToken = waiters.keys.min(),
              let continuation = waiters.removeValue(forKey: nextToken) else {
            running = max(0, running - 1)
            return
        }

        // Resume with true = acquired slot
        continuation.resume(returning: true)
    }

    /// Returns current diagnostics for debugging.
    var diagnostics: (running: Int, waiting: Int) {
        (running, waiters.count)
    }
}
