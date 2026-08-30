import Foundation

nonisolated enum LibraryMutationCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case sessionQuiescing

    var errorDescription: String? {
        switch self {
        case .sessionQuiescing:
            return "资料库正在切换或关闭，暂时不能接受新的写操作。"
        }
    }
}

private struct LibraryMutationContextValue: Sendable {
    let coordinatorID: UUID
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

    private let coordinatorID = UUID()
    private let libraryID: UUID
    private let sessionGeneration: UInt64
    private let journal: LibraryMutationJournal
    private var acceptingMutations = true
    private var tail: Task<Void, Never>?
    private var operations: [UUID: Operation] = [:]

    init(
        libraryID: UUID,
        sessionGeneration: UInt64,
        journal: LibraryMutationJournal
    ) {
        self.libraryID = libraryID
        self.sessionGeneration = sessionGeneration
        self.journal = journal
    }

    func run<Value: Sendable>(
        kind: LibraryMutationKind,
        targetIDs: [String] = [],
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        guard acceptingMutations else {
            throw LibraryMutationCoordinatorError.sessionQuiescing
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
                targetIDs: targetIDs
            )
            intent = try await journal.markCommitting(intent)
            do {
                let value = try await LibraryMutationContext.$current.withValue(
                    .init(coordinatorID: ownerID)
                ) {
                    try await work()
                }
                _ = try await journal.complete(intent)
                return value
            } catch {
                do {
                    _ = try await journal.markFailed(intent, error: error)
                } catch {
                    // Preserve the original write error for the caller while
                    // leaving the last durable Pending record for startup.
                    Log.error(
                        "[LibraryMutationCoordinator] failed to update mutation journal: \(error)",
                        category: .library
                    )
                }
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

    func quiesceAndWait() async {
        stopAcceptingNewMutations()
        await waitForDrain()
    }

    func stopAcceptingNewMutations() {
        acceptingMutations = false
    }

    func waitForDrain() async {
        while !operations.isEmpty {
            let pending = operations.values
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
