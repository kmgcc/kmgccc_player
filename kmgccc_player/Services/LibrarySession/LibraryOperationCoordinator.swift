import Foundation

nonisolated enum LibraryOperationError: Error, Equatable {
    case sessionQuiescing
}

/// Observable lifecycle states for a coordinated library task (plan §14).
/// The per-domain presentation/persistence enums (BatchImportStage,
/// NCMConversionState, SidebarTaskProgress.State) stay independent layers
/// and map onto this coordinator-level model.
nonisolated enum LibraryTaskState: Equatable, Sendable {
    case queued
    case running
    case checkpointed
    case completed
    case partialFailure
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .queued, .running, .checkpointed:
            return false
        case .completed, .partialFailure, .failed, .cancelled:
            return true
        }
    }
}

/// Coarse operation taxonomy from plan §14. Existing call sites default to
/// `.other`; services opt into a specific kind where it is cheap to do so.
nonisolated enum LibraryTaskKind: Equatable, Sendable {
    case importFiles
    case sourceScan
    case ncmConversion
    case enrichment
    case indexUpdate
    case other
}

/// Value snapshot of one coordinated task. `state` only advances through the
/// owning coordinator; the fileprivate mutators below keep external copies
/// effectively frozen while the descriptor stays a plain Sendable value.
nonisolated struct LibraryOperationTaskDescriptor: Equatable, Sendable, Identifiable {
    let id: UUID
    let kind: LibraryTaskKind
    let libraryID: UUID?
    let sessionGeneration: UInt64?
    private(set) var state: LibraryTaskState
    let createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var lastCheckpointLabel: String?
    var lastCheckpointAt: Date?
    var partialFailureSummaries: [String]

    init(
        id: UUID,
        kind: LibraryTaskKind,
        libraryID: UUID?,
        sessionGeneration: UInt64?,
        state: LibraryTaskState,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastCheckpointLabel: String? = nil,
        lastCheckpointAt: Date? = nil,
        partialFailureSummaries: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.libraryID = libraryID
        self.sessionGeneration = sessionGeneration
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastCheckpointLabel = lastCheckpointLabel
        self.lastCheckpointAt = lastCheckpointAt
        self.partialFailureSummaries = partialFailureSummaries
    }

    fileprivate mutating func markRunning(at date: Date) {
        state = .running
        if startedAt == nil { startedAt = date }
    }

    /// A checkpoint is a refinement of live progress, not a pause: the label
    /// and timestamp are kept for observation while the task keeps running
    /// towards its terminal classification.
    fileprivate mutating func markCheckpointed(label: String, at date: Date) {
        state = .checkpointed
        lastCheckpointLabel = label
        lastCheckpointAt = date
    }

    fileprivate mutating func appendPartialFailure(_ summary: String) {
        partialFailureSummaries.append(summary)
    }

    fileprivate mutating func finish(_ terminalState: LibraryTaskState, at date: Date) {
        state = terminalState
        finishedAt = date
    }
}

private struct LibraryOperationContextValue: Sendable {
    let coordinatorID: UUID
    let operationID: UUID
}

private enum LibraryOperationContext {
    @TaskLocal static var current: LibraryOperationContextValue?
}

/// Owns library-scoped asynchronous work that must quiesce before the active
/// session is released.  A task captured by this coordinator is never allowed
/// to outlive the session transition that owns it.
@MainActor
final class LibraryOperationCoordinator {
    private struct Operation {
        let cancel: () -> Void
        let wait: () async -> Void
    }

    private var operations: [UUID: Operation] = [:]
    private var acceptingOperations = true
    private var tail: Task<Void, Never>?
    private let coordinatorID = UUID()

    private let libraryID: UUID?
    private let sessionGeneration: UInt64?

    /// Live task snapshots ordered by creation time. A terminal descriptor is
    /// published through `onTasksDidChange` first and removed from this list
    /// immediately afterwards, so observers follow state changes without any
    /// polling loop.
    private(set) var taskDescriptors: [LibraryOperationTaskDescriptor] = []

    /// Invoked on the MainActor after every task-state mutation. Observers
    /// copy `taskDescriptors` inside the callback to refresh their snapshot.
    @MainActor var onTasksDidChange: (@MainActor () -> Void)?

    init(libraryID: UUID? = nil, sessionGeneration: UInt64? = nil) {
        self.libraryID = libraryID
        self.sessionGeneration = sessionGeneration
    }

    // MARK: - Enqueueing

    /// Runs an operation under this session's lifetime owner.  The generic
    /// result is deliberately awaited by the caller; the coordinator stores a
    /// type-erased cancellation/wait pair only for quiesce.
    func run<Value: Sendable>(
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try await run(work, kind: .other)
    }

    /// Same as `run(_:)` with an explicit §14 task kind for observation.
    /// The kind leads so callers can use trailing-closure syntax.
    func run<Value: Sendable>(
        as kind: LibraryTaskKind,
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try await run(work, kind: kind)
    }

    private func run<Value: Sendable>(
        _ work: @escaping @MainActor () async throws -> Value,
        kind: LibraryTaskKind
    ) async throws -> Value {
        guard acceptingOperations else {
            throw LibraryOperationError.sessionQuiescing
        }

        // Session helpers may expose a public operation API and still call
        // another session helper internally. Treat that as part of the
        // current transaction instead of enqueueing behind our own tail.
        // Without this re-entrancy boundary, an outer operation waits for an
        // inner task whose predecessor is the outer operation itself.
        // Re-entrant inline executions deliberately create no descriptor;
        // checkpoints recorded inside them land on the enclosing operation.
        if LibraryOperationContext.current?.coordinatorID == coordinatorID {
            return try await work()
        }

        let operationID = UUID()
        let ownerID = coordinatorID
        let predecessor = tail
        registerTask(kind: kind, operationID: operationID)
        let task = Task { @MainActor [weak self] () throws -> Value in
            do {
                let value = try await LibraryOperationContext.$current.withValue(
                    .init(coordinatorID: ownerID, operationID: operationID)
                ) {
                    await predecessor?.value
                    try Task.checkCancellation()
                    self?.markRunning(operationID: operationID)
                    return try await work()
                }
                self?.finishNormally(operationID: operationID)
                return value
            } catch {
                self?.finishThrowing(operationID: operationID, error: error)
                throw error
            }
        }
        let completion = Task { @MainActor in
            _ = try? await task.value
        }
        tail = completion
        operations[operationID] = Operation(
            cancel: { task.cancel() },
            wait: {
                _ = try? await task.value
                await completion.value
            }
        )

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Starts non-blocking work while retaining ownership until it finishes.
    /// Returns false when the session is already quiescing.
    @discardableResult
    func start(
        _ work: @escaping @MainActor () async -> Void
    ) -> Bool {
        start(work, kind: .other)
    }

    /// Same as `start(_:)` with an explicit §14 task kind for observation.
    @discardableResult
    func start(
        _ work: @escaping @MainActor () async -> Void,
        kind: LibraryTaskKind
    ) -> Bool {
        guard acceptingOperations else { return false }
        let operationID = UUID()
        let ownerID = coordinatorID
        let predecessor = tail
        registerTask(kind: kind, operationID: operationID)
        let task = Task { @MainActor [weak self] in
            await LibraryOperationContext.$current.withValue(
                .init(coordinatorID: ownerID, operationID: operationID)
            ) {
                await predecessor?.value
                guard !Task.isCancelled else {
                    self?.finish(operationID: operationID, state: .cancelled)
                    return
                }
                self?.markRunning(operationID: operationID)
                await work()
                self?.finishNormally(operationID: operationID)
            }
        }
        let completion = Task { @MainActor in
            await task.value
        }
        tail = completion
        operations[operationID] = Operation(
            cancel: { task.cancel() },
            wait: {
                await task.value
                await completion.value
            }
        )
        return true
    }

    // MARK: - Progress hooks (usable from inside an operation closure)

    /// Records a progress checkpoint against the enclosing operation. A
    /// checkpoint means the task is alive and progressing; the terminal
    /// classification still decides completed vs partialFailure later.
    /// Calls from outside any coordinated operation are silent no-ops.
    func recordCheckpoint(_ label: String) {
        guard let operationID = LibraryOperationContext.current?.operationID else { return }
        mutateDescriptor(id: operationID) { descriptor in
            descriptor.markCheckpointed(label: label, at: Date())
        }
    }

    /// Records one item-scoped failure against the enclosing operation. The
    /// state stays running/checkpointed until the task returns; a non-empty
    /// summary list then classifies the result as partialFailure.
    func recordPartialFailure(_ summary: String) {
        guard let operationID = LibraryOperationContext.current?.operationID else { return }
        mutateDescriptor(id: operationID) { descriptor in
            descriptor.appendPartialFailure(summary)
        }
    }

    // MARK: - Quiesce

    func quiesceAndWait() async {
        acceptingOperations = false
        while !operations.isEmpty {
            let pending = operations
            pending.values.forEach { $0.cancel() }
            for operation in pending.values {
                await operation.wait()
            }
        }
    }

    // MARK: - Descriptor bookkeeping

    private func registerTask(kind: LibraryTaskKind, operationID: UUID) {
        taskDescriptors.append(LibraryOperationTaskDescriptor(
            id: operationID,
            kind: kind,
            libraryID: libraryID,
            sessionGeneration: sessionGeneration,
            state: .queued,
            createdAt: Date()
        ))
        notifyTasksDidChange()
    }

    private func markRunning(operationID: UUID) {
        mutateDescriptor(id: operationID) { descriptor in
            descriptor.markRunning(at: Date())
        }
    }

    private func finishNormally(operationID: UUID) {
        let state: LibraryTaskState
        if Task.isCancelled {
            state = .cancelled
        } else {
            state = descriptor(id: operationID)?.partialFailureSummaries.isEmpty == false
                ? .partialFailure
                : .completed
        }
        finish(operationID: operationID, state: state)
    }

    private func finishThrowing(operationID: UUID, error: Error) {
        let state: LibraryTaskState
        if error is CancellationError || Task.isCancelled {
            state = .cancelled
        } else {
            state = .failed
        }
        finish(operationID: operationID, state: state)
    }

    /// Publishes the terminal snapshot first, then drops the entry from the
    /// live list so observers can capture the final state without polling.
    private func finish(operationID: UUID, state: LibraryTaskState) {
        mutateDescriptor(id: operationID) { descriptor in
            descriptor.finish(state, at: Date())
        }
        retire(operationID: operationID)
    }

    private func descriptor(id: UUID) -> LibraryOperationTaskDescriptor? {
        taskDescriptors.first { $0.id == id }
    }

    private func mutateDescriptor(
        id: UUID,
        _ transform: (inout LibraryOperationTaskDescriptor) -> Void
    ) {
        guard let index = taskDescriptors.firstIndex(where: { $0.id == id }) else { return }
        transform(&taskDescriptors[index])
        notifyTasksDidChange()
    }

    /// Silent cleanup: removal follows the terminal notification emitted by
    /// `finish`, so this intentionally does not notify again.
    private func retire(operationID: UUID) {
        operations.removeValue(forKey: operationID)
        taskDescriptors.removeAll { $0.id == operationID }
        if operations.isEmpty {
            tail = nil
        }
    }

    private func notifyTasksDidChange() {
        onTasksDidChange?()
    }
}
