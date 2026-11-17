import Foundation

nonisolated enum LibraryMutationCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case sessionQuiescing
    case targetIsolated(String)

    var errorDescription: String? {
        switch self {
        case .sessionQuiescing:
            return "资料库正在切换或关闭，暂时不能接受新的写操作。"
        case .targetIsolated:
            return "这项内容属于尚未完成的资料库操作，请先在资料库检查中核对记录。"
        }
    }
}

private struct LibraryMutationContextValue: Sendable {
    let coordinatorID: UUID
    let outcome: LibraryMutationOutcome
}

@MainActor private final class LibraryMutationOutcome {
    var unresolvedSummary: String?
    var intent: LibraryMutationIntent
    let journal: LibraryMutationJournal

    init(intent: LibraryMutationIntent, journal: LibraryMutationJournal) {
        self.intent = intent
        self.journal = journal
    }
}

private nonisolated struct LibraryMutationIncomplete: Error, CustomStringConvertible {
    let description: String
}

private enum LibraryMutationContext {
    @TaskLocal static var current: LibraryMutationContextValue?
}

/// Serializes only short durable commits shared by UI, CLI, MCP and monitors.
/// Long scans and network work must complete before entering `run`.
@MainActor
final class LibraryMutationCoordinator {
    private struct Operation {
        let wait: () async -> Void
    }
    @MainActor var onSlowQuiescence: (@MainActor (Int) -> Void)?
    @MainActor var onUnresolvedMutation: (@MainActor (LibraryMutationIntent) -> Void)?

    private let coordinatorID = UUID()
    private let libraryID: UUID
    private let sessionGeneration: UInt64
    private let journal: LibraryMutationJournal
    private var acceptingMutations = true
    private var tail: Task<Void, Never>?
    private var operations: [UUID: Operation] = [:]
    /// Targets of intents that could not be adjudicated at load time or whose
    /// commit failed. New mutations touching the same projection stay blocked
    /// until an operation-specific verifier resolves the record.
    private var isolatedTargetIDs: Set<String> = []

    init(
        libraryID: UUID,
        sessionGeneration: UInt64,
        journal: LibraryMutationJournal
    ) {
        precondition(journal.libraryID == libraryID)
        self.libraryID = libraryID
        self.sessionGeneration = sessionGeneration
        self.journal = journal
    }

    func run<Value: Sendable>(
        kind: LibraryMutationKind,
        targetIDs: [String] = [],
        stepIDs: [String] = [],
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        guard acceptingMutations else {
            throw LibraryMutationCoordinatorError.sessionQuiescing
        }
        if let isolated = targetIDs.first(where: isolatedTargetIDs.contains) {
            throw LibraryMutationCoordinatorError.targetIsolated(isolated)
        }

        // Nested service calls are one durable mutation, not a second queue
        // entry behind their own parent.
        if LibraryMutationContext.current?.coordinatorID == coordinatorID {
            return try await work()
        }

        let operationID = UUID()
        let ownerID = coordinatorID
        let predecessor = tail
        let journal = journal
        let generation = sessionGeneration
        let task = Task { @MainActor () throws -> Value in
            await predecessor?.value
            var intent = try await journal.prepare(
                kind: kind,
                sessionGeneration: generation,
                targetIDs: targetIDs,
                stepIDs: stepIDs
            )
            intent = try await journal.markCommitting(intent)
            do {
                let outcome = LibraryMutationOutcome(intent: intent, journal: journal)
                let value = try await LibraryMutationContext.$current.withValue(
                    .init(coordinatorID: ownerID, outcome: outcome)
                ) {
                    try await work()
                }
                intent = outcome.intent
                if let summary = outcome.unresolvedSummary {
                    do {
                        intent = try await journal.markFailed(intent, error: LibraryMutationIncomplete(description: summary))
                    } catch {
                        // Pending still records an incomplete commit. Keep
                        // the already-published partial result visible.
                        Log.error("[LibraryMutationCoordinator] failed to mark partial result: \(error)", category: .library)
                    }
                    self.onUnresolvedMutation?(intent)
                    return value
                }
                // Explicit checkpoints are already durable. Remaining steps
                // are completed only after the entire body returns normally.
                for step in intent.steps where step.state != .completed {
                    intent = try await journal.markStepCompleted(
                        intent,
                        stepID: step.id
                    )
                }
                _ = try await journal.complete(intent)
                return value
            } catch {
                do {
                    intent = try await journal.markFailed(intent, error: error)
                } catch {
                    // Preserve the original write error for the caller while
                    // leaving the last durable Pending record for startup.
                    Log.error(
                        "[LibraryMutationCoordinator] failed to update mutation journal: \(error)",
                        category: .library
                    )
                }
                self.onUnresolvedMutation?(intent)
                throw error
            }
        }
        let completion = Task { @MainActor [weak self] in
            _ = try? await task.value
            self?.finish(operationID)
        }
        tail = completion
        operations[operationID] = Operation(wait: {
            _ = try? await task.value
            await completion.value
        })

        // Deliberately do not cancel `task` if the caller is cancelled. Once
        // its intent reaches the queue, a short disk commit must finish or
        // throw on its own; session quiescence waits for that outcome.
        return try await task.value
    }

    /// Preserve a successful partial result while keeping its transaction
    /// pending for later consistency review.
    func recordUnresolved(_ summary: String) {
        guard let context = LibraryMutationContext.current, context.coordinatorID == coordinatorID else { return }
        if let previous = context.outcome.unresolvedSummary, !previous.isEmpty {
            context.outcome.unresolvedSummary = String((previous + "\n" + summary).prefix(1_024))
        } else {
            context.outcome.unresolvedSummary = String(summary.prefix(1_024))
        }
    }

    /// Persists a concrete completed step while the mutation is still active.
    /// Nested work only records steps declared by its enclosing transaction.
    func recordCompletedStep(_ stepID: String) async throws {
        guard let context = LibraryMutationContext.current, context.coordinatorID == coordinatorID,
              context.outcome.intent.steps.contains(where: { $0.id == stepID }) else { return }
        context.outcome.intent = try await context.outcome.journal.markStepCompleted(
            context.outcome.intent, stepID: stepID
        )
    }

    func quiesceAndWait() async {
        stopAcceptingNewMutations()
        await waitForDrain()
    }

    func stopAcceptingNewMutations() {
        acceptingMutations = false
    }

    /// Replaces the set of blocked target identifiers. Called after a
    /// verification pass so resolved intents release their isolation.
    func replaceIsolatedTargets(_ targetIDs: Set<String>) {
        isolatedTargetIDs = targetIDs
    }

    func isolateTargets(_ targetIDs: [String]) {
        isolatedTargetIDs.formUnion(targetIDs)
    }

    var isolatedTargetCount: Int { isolatedTargetIDs.count }

    func waitForDrain() async {
        let warningTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                guard let self, !self.operations.isEmpty else { return }
                Log.warning(
                    "[LibraryMutation] waiting for \(self.operations.count) queued or active commit(s) before closing library \(self.libraryID)",
                    category: .library
                )
                self.onSlowQuiescence?(self.operations.count)
            }
        }
        defer { warningTask.cancel() }
        while !operations.isEmpty {
            let pending = Array(operations.values)
            for operation in pending {
                await operation.wait()
            }
        }
    }

    var isAcceptingMutations: Bool { acceptingMutations }

    private func finish(_ operationID: UUID) {
        operations.removeValue(forKey: operationID)
        if operations.isEmpty {
            tail = nil
        }
    }
}
