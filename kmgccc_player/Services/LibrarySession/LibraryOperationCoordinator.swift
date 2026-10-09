import Foundation
import PlayerAutomationProtocol

nonisolated enum LibraryOperationError: Error, Equatable {
    case sessionQuiescing
}

/// Observable lifecycle states for a coordinated library task (plan §14).
/// The per-domain presentation/persistence enums (BatchImportStage,
/// NCMConversionState, SidebarTaskProgress.State) stay independent layers
/// and map onto this coordinator-level model.
nonisolated enum LibraryTaskState: String, Codable, Equatable, Sendable {
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
nonisolated enum LibraryTaskKind: String, Codable, Equatable, Sendable {
    case importFiles
    case sourceScan
    case ncmConversion
    case enrichment
    case automation
    case indexUpdate
    case libraryBundleExport
    case embeddedTagWrite
    case other
}

/// Durable retry information for automation-owned Jobs. The payload is kept
/// deliberately narrow: it contains stable IDs and policy flags, never raw
/// security-scoped URLs or user media content.
nonisolated struct LibraryOperationRetrySpec: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case lyricsRefresh
        case sourceRefresh
        case libraryImport
        case loudnessAnalyze
        case dspScriptTest
    }

    let kind: Kind
    let trackIDs: [UUID]
    let sourceID: UUID?
    let force: Bool
    let targetPlaylistID: UUID?
    let enrichmentPolicy: String
    let scriptNodeID: UUID?
    let scriptRevision: String?
    let scriptSampleRate: Double?
    let scriptChannelCount: Int?
    let scriptUsesDraft: Bool?
    let scriptFixtures: AutomationJSONValue?

    init(
        kind: Kind,
        trackIDs: [UUID] = [],
        sourceID: UUID? = nil,
        force: Bool = false,
        targetPlaylistID: UUID? = nil,
        enrichmentPolicy: String = "standard",
        scriptNodeID: UUID? = nil,
        scriptRevision: String? = nil,
        scriptSampleRate: Double? = nil,
        scriptChannelCount: Int? = nil,
        scriptUsesDraft: Bool? = nil,
        scriptFixtures: AutomationJSONValue? = nil
    ) {
        self.kind = kind
        self.trackIDs = trackIDs
        self.sourceID = sourceID
        self.force = force
        self.targetPlaylistID = targetPlaylistID
        self.enrichmentPolicy = enrichmentPolicy
        self.scriptNodeID = scriptNodeID
        self.scriptRevision = scriptRevision
        self.scriptSampleRate = scriptSampleRate
        self.scriptChannelCount = scriptChannelCount
        self.scriptUsesDraft = scriptUsesDraft
        self.scriptFixtures = scriptFixtures
    }

    static func lyricsRefresh(trackIDs: [UUID], force: Bool) -> Self {
        Self(
            kind: .lyricsRefresh,
            trackIDs: trackIDs,
            sourceID: nil,
            force: force,
            targetPlaylistID: nil
        )
    }

    static func sourceRefresh(sourceID: UUID) -> Self {
        Self(
            kind: .sourceRefresh,
            trackIDs: [],
            sourceID: sourceID,
            force: false,
            targetPlaylistID: nil
        )
    }

    static func libraryImport(
        targetPlaylistID: UUID?,
        enrichmentPolicy: String = "standard"
    ) -> Self {
        Self(
            kind: .libraryImport,
            trackIDs: [],
            sourceID: nil,
            force: false,
            targetPlaylistID: targetPlaylistID,
            enrichmentPolicy: enrichmentPolicy
        )
    }

    static func loudnessAnalyze(trackIDs: [UUID]) -> Self {
        Self(
            kind: .loudnessAnalyze,
            trackIDs: trackIDs,
            sourceID: nil,
            force: false,
            targetPlaylistID: nil
        )
    }

    static func dspScriptTest(nodeID: UUID, revision: String, sampleRate: Double,
                              channelCount: Int, usesDraft: Bool, fixtures: AutomationJSONValue? = nil) -> Self {
        Self(kind: .dspScriptTest, scriptNodeID: nodeID, scriptRevision: revision,
             scriptSampleRate: sampleRate, scriptChannelCount: channelCount, scriptUsesDraft: usesDraft,
             scriptFixtures: fixtures)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, trackIDs, sourceID, force, targetPlaylistID, enrichmentPolicy
        case scriptNodeID, scriptRevision, scriptSampleRate, scriptChannelCount, scriptUsesDraft, scriptFixtures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        trackIDs = try container.decodeIfPresent([UUID].self, forKey: .trackIDs) ?? []
        sourceID = try container.decodeIfPresent(UUID.self, forKey: .sourceID)
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
        targetPlaylistID = try container.decodeIfPresent(UUID.self, forKey: .targetPlaylistID)
        enrichmentPolicy = try container.decodeIfPresent(String.self, forKey: .enrichmentPolicy) ?? "standard"
        scriptNodeID = try container.decodeIfPresent(UUID.self, forKey: .scriptNodeID)
        scriptRevision = try container.decodeIfPresent(String.self, forKey: .scriptRevision)
        scriptSampleRate = try container.decodeIfPresent(Double.self, forKey: .scriptSampleRate)
        scriptChannelCount = try container.decodeIfPresent(Int.self, forKey: .scriptChannelCount)
        scriptUsesDraft = try container.decodeIfPresent(Bool.self, forKey: .scriptUsesDraft)
        scriptFixtures = try container.decodeIfPresent(AutomationJSONValue.self, forKey: .scriptFixtures)
    }
}

/// Value snapshot of one coordinated task. `state` only advances through the
/// owning coordinator; the fileprivate mutators below keep external copies
/// effectively frozen while the descriptor stays a plain Sendable value.
nonisolated struct LibraryOperationTaskDescriptor: Codable, Equatable, Sendable, Identifiable {
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
    var completedCount: Int?
    var totalCount: Int?
    var currentPhase: String?
    var partialFailureSummaries: [String]
    var failedItemIDs: [UUID]
    let retrySpec: LibraryOperationRetrySpec?
    var result: AutomationJSONValue? = nil

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
        completedCount: Int? = nil,
        totalCount: Int? = nil,
        currentPhase: String? = nil,
        partialFailureSummaries: [String] = [],
        failedItemIDs: [UUID] = [],
        retrySpec: LibraryOperationRetrySpec? = nil
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
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.currentPhase = currentPhase
        self.partialFailureSummaries = partialFailureSummaries
        self.failedItemIDs = failedItemIDs
        self.retrySpec = retrySpec
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, libraryID, sessionGeneration, state, createdAt, startedAt, finishedAt
        case lastCheckpointLabel, lastCheckpointAt, completedCount, totalCount, currentPhase
        case partialFailureSummaries, failedItemIDs, retrySpec, result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(LibraryTaskKind.self, forKey: .kind)
        libraryID = try container.decodeIfPresent(UUID.self, forKey: .libraryID)
        sessionGeneration = try container.decodeIfPresent(UInt64.self, forKey: .sessionGeneration)
        state = try container.decode(LibraryTaskState.self, forKey: .state)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        lastCheckpointLabel = try container.decodeIfPresent(String.self, forKey: .lastCheckpointLabel)
        lastCheckpointAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckpointAt)
        completedCount = try container.decodeIfPresent(Int.self, forKey: .completedCount)
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount)
        currentPhase = try container.decodeIfPresent(String.self, forKey: .currentPhase)
        partialFailureSummaries = try container.decodeIfPresent(
            [String].self,
            forKey: .partialFailureSummaries
        ) ?? []
        failedItemIDs = try container.decodeIfPresent([UUID].self, forKey: .failedItemIDs) ?? []
        result = try container.decodeIfPresent(AutomationJSONValue.self, forKey: .result)
        retrySpec = try container.decodeIfPresent(
            LibraryOperationRetrySpec.self,
            forKey: .retrySpec
        )
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

    fileprivate mutating func appendPartialFailure(_ summary: String, itemID: UUID? = nil) {
        partialFailureSummaries.append(summary)
        if let itemID, !failedItemIDs.contains(itemID) {
            failedItemIDs.append(itemID)
        }
    }

    fileprivate mutating func updateProgress(
        completedCount: Int,
        totalCount: Int?,
        phase: String?
    ) {
        self.completedCount = max(0, completedCount)
        self.totalCount = totalCount.map { max(0, $0) }
        if let phase, !phase.isEmpty {
            currentPhase = phase
        }
    }

    fileprivate mutating func finish(_ terminalState: LibraryTaskState, at date: Date) {
        state = terminalState
        finishedAt = date
    }

    fileprivate mutating func markInterruptedAfterRestart(at date: Date) {
        state = .failed
        finishedAt = date
        let summary = "The App restarted before this Job reached a terminal state."
        if !partialFailureSummaries.contains(summary) {
            partialFailureSummaries.append(summary)
        }
        currentPhase = currentPhase ?? "recovery"
    }
}

private struct PersistedLibraryJobs: Codable {
    let schemaVersion: Int
    let jobs: [LibraryOperationTaskDescriptor]

    init(jobs: [LibraryOperationTaskDescriptor]) {
        schemaVersion = 1
        self.jobs = jobs
    }
}

/// Small, atomic JSON persistence for the App-owned Job observation surface.
/// The actual library mutations remain owned by their existing stores; this
/// file only makes Job state and retry metadata durable across App launches.
private struct LibraryOperationJobStore {
    let fileURL: URL

    func load() -> [LibraryOperationTaskDescriptor] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PersistedLibraryJobs.self, from: data),
              payload.schemaVersion == 1 else {
            return []
        }
        return payload.jobs
    }

    func save(_ jobs: [LibraryOperationTaskDescriptor]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(PersistedLibraryJobs(jobs: jobs)).write(
                to: fileURL,
                options: .atomic
            )
        } catch {
            Log.debug(
                "[LibraryJobs] failed to persist Job state: \(error)",
                category: .library
            )
        }
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
    private let jobStore: LibraryOperationJobStore?

    /// Live task snapshots ordered by creation time. A terminal descriptor is
    /// published through `onTasksDidChange` first and removed from this list
    /// immediately afterwards, so observers follow state changes without any
    /// polling loop.
    private(set) var taskDescriptors: [LibraryOperationTaskDescriptor] = []

    /// A bounded history makes a completed Job observable after its operation
    /// has retired. When a persistence URL is supplied, the same snapshots
    /// survive App restart as diagnostic state; the underlying library
    /// operation still persists its own domain data separately.
    private(set) var recentTaskDescriptors: [LibraryOperationTaskDescriptor] = []
    private let recentTaskLimit = 100

    /// Invoked on the MainActor after every task-state mutation. Observers
    /// copy `taskDescriptors` inside the callback to refresh their snapshot.
    @MainActor var onTasksDidChange: (@MainActor () -> Void)?

    init(
        libraryID: UUID? = nil,
        sessionGeneration: UInt64? = nil,
        persistenceURL: URL? = nil
    ) {
        self.libraryID = libraryID
        self.sessionGeneration = sessionGeneration
        self.jobStore = persistenceURL.map(LibraryOperationJobStore.init(fileURL:))

        guard let jobStore = self.jobStore else { return }
        var restored = jobStore.load()
        let recoveryDate = Date()
        for index in restored.indices where !restored[index].state.isTerminal {
            restored[index].markInterruptedAfterRestart(at: recoveryDate)
        }
        self.recentTaskDescriptors = Array(restored.prefix(recentTaskLimit))
        jobStore.save(self.recentTaskDescriptors)
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
        kind: LibraryTaskKind,
        retrySpec: LibraryOperationRetrySpec? = nil
    ) -> Bool {
        guard acceptingOperations else { return false }
        let operationID = UUID()
        let ownerID = coordinatorID
        let predecessor = tail
        registerTask(kind: kind, operationID: operationID, retrySpec: retrySpec)
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
                if Task.isCancelled {
                    self?.finish(operationID: operationID, state: .cancelled)
                } else {
                    self?.finishNormally(operationID: operationID)
                }
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
    func recordPartialFailure(_ summary: String, itemID: UUID? = nil) {
        guard let operationID = LibraryOperationContext.current?.operationID else { return }
        mutateDescriptor(id: operationID) { descriptor in
            descriptor.appendPartialFailure(summary, itemID: itemID)
        }
    }

    /// Publishes item-level progress against the enclosing operation. Callers
    /// outside a coordinated operation are ignored, just like checkpoints.
    func recordProgress(completedCount: Int, totalCount: Int?, phase: String? = nil) {
        guard let operationID = LibraryOperationContext.current?.operationID else { return }
        mutateDescriptor(id: operationID) { descriptor in
            descriptor.updateProgress(
                completedCount: completedCount,
                totalCount: totalCount,
                phase: phase
            )
        }
    }

    /// Stores the current structured outcome in the library-scoped Job history.
    func recordResult(_ result: AutomationJSONValue) {
        guard let operationID = LibraryOperationContext.current?.operationID else { return }
        mutateDescriptor(id: operationID) { $0.result = result }
    }

    /// Cancels one live operation without affecting unrelated work.
    @discardableResult
    func cancel(operationID: UUID) -> Bool {
        guard let operation = operations[operationID] else { return false }
        operation.cancel()
        return true
    }

    /// Returns either a live or recently completed descriptor.
    func taskDescriptor(operationID: UUID) -> LibraryOperationTaskDescriptor? {
        taskDescriptors.first { $0.id == operationID }
            ?? recentTaskDescriptors.first { $0.id == operationID }
    }

    // MARK: - Quiesce

    func quiesceAndWait() async {
        stopAcceptingNewOperations()
        await cancelAndWait()
    }

    func stopAcceptingNewOperations() {
        acceptingOperations = false
    }

    func cancelAndWait() async {
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
        registerTask(kind: kind, operationID: operationID, retrySpec: nil)
    }

    private func registerTask(
        kind: LibraryTaskKind,
        operationID: UUID,
        retrySpec: LibraryOperationRetrySpec?
    ) {
        taskDescriptors.append(LibraryOperationTaskDescriptor(
            id: operationID,
            kind: kind,
            libraryID: libraryID,
            sessionGeneration: sessionGeneration,
            state: .queued,
            createdAt: Date(),
            retrySpec: retrySpec
        ))
        persistJobs()
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
        if let finalDescriptor = descriptor(id: operationID) {
            recentTaskDescriptors.insert(finalDescriptor, at: 0)
            if recentTaskDescriptors.count > recentTaskLimit {
                recentTaskDescriptors.removeLast(recentTaskDescriptors.count - recentTaskLimit)
            }
        }
        retire(operationID: operationID)
        // The first notification exposes the terminal live snapshot for UI
        // observers; this second notification exposes the same snapshot in
        // the retained Job history for automation callers.
        notifyTasksDidChange()
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
        persistJobs()
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
        persistJobs()
    }

    private func persistJobs() {
        guard let jobStore else { return }
        let liveAndRecent = (taskDescriptors + recentTaskDescriptors)
            .reduce(into: [UUID: LibraryOperationTaskDescriptor]()) { result, descriptor in
                result[descriptor.id] = descriptor
            }
            .values
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        jobStore.save(Array(liveAndRecent.prefix(recentTaskLimit)))
    }

    private func notifyTasksDidChange() {
        onTasksDidChange?()
    }
}
