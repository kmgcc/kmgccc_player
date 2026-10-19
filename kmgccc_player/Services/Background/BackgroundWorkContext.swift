import Foundation

/// Cooperative pause and cancel point handed to a scheduled unit. The unit
/// calls `checkpoint()` at chunk boundaries. While the scheduler holds the
/// unit paused, the call suspends until it is resumed or cancelled; there is
/// no polling. A pause is not a failure.
nonisolated final class BackgroundWorkContext: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Quality of service the unit was started at. Nested detached tasks use
    /// it so the whole unit keeps one priority.
    nonisolated let taskPriority: TaskPriority

    nonisolated init(taskPriority: TaskPriority = .background) {
        self.taskPriority = taskPriority
    }

    nonisolated var isPaused: Bool { lock.withLock { paused } }
    nonisolated var isCancelled: Bool { lock.withLock { cancelled } }

    nonisolated func setPaused(_ value: Bool) {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            paused = value
            guard !value else { return [] }
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in resumed { continuation.resume() }
    }

    nonisolated func cancel() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            cancelled = true
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in resumed { continuation.resume() }
    }

    /// Returns when the unit may continue; throws `CancellationError` once
    /// the unit was cancelled.
    nonisolated func checkpoint() async throws {
        while true {
            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }
            guard isPaused else { return }
            await waitForResume()
        }
    }

    /// Set under `lock` when the waiting task is cancelled, so a cancellation
    /// that lands before the continuation is registered is not lost.
    private nonisolated final class WaitFlag: @unchecked Sendable {
        var taskCancelled = false
        nonisolated init() {}
    }

    private nonisolated func waitForResume() async {
        let flag = WaitFlag()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if !paused || cancelled || flag.taskCancelled { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
                flag.taskCancelled = true
                defer { waiters.removeAll() }
                return waiters
            }
            for continuation in resumed { continuation.resume() }
        }
    }
}
