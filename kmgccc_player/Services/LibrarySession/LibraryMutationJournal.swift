import Foundation

nonisolated enum LibraryMutationKind: String, Codable, Sendable, CaseIterable {
    case userLibraryMutation
    case importCommit
    case enrichmentCommit
    case sourceReconcileCommit
    case settingsUpdate
    case maintenance
    case automation

    var defaultStepIDs: [String] {
        switch self {
        case .importCommit:
            return ["tracks", "sources", "membership", "index", "finalize"]
        case .sourceReconcileCommit:
            return ["authority", "sidecars", "membership", "manifest", "finalize"]
        case .userLibraryMutation:
            return ["authority", "sidecars", "index", "finalize"]
        case .enrichmentCommit:
            return ["metadata", "index", "finalize"]
        case .settingsUpdate:
            return ["settings", "finalize"]
        case .maintenance:
            return ["maintenance", "finalize"]
        case .automation:
            return ["automation", "finalize"]
        }
    }
}

nonisolated enum LibraryMutationJournalState: String, Codable, Sendable {
    case prepared
    case committing
    case failed
    case completed
    case recovered
}

nonisolated enum LibraryMutationStepState: String, Codable, Sendable {
    case pending
    case completed
    case failed
    case recovered
}

nonisolated struct LibraryMutationStep: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var state: LibraryMutationStepState
    var updatedAt: Date
    var resultSummary: String?

    init(id: String, state: LibraryMutationStepState = .pending, updatedAt: Date = Date()) {
        self.id = id
        self.state = state
        self.updatedAt = updatedAt
        resultSummary = nil
    }
}

nonisolated struct LibraryMutationIntent: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let id: UUID
    let libraryID: UUID
    let sessionGeneration: UInt64
    let kind: LibraryMutationKind
    let targetIDs: [String]
    var steps: [LibraryMutationStep]
    let createdAt: Date
    var updatedAt: Date
    var state: LibraryMutationJournalState
    var failureSummary: String?
    var recoverySummary: String?

    init(
        id: UUID = UUID(),
        libraryID: UUID,
        sessionGeneration: UInt64,
        kind: LibraryMutationKind,
        targetIDs: [String] = [],
        stepIDs: [String] = [],
        createdAt: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.libraryID = libraryID
        self.sessionGeneration = sessionGeneration
        self.kind = kind
        self.targetIDs = Array(Set(targetIDs)).sorted()
        let normalizedStepIDs = Array(Set(stepIDs)).sorted()
        steps = normalizedStepIDs.map { LibraryMutationStep(id: $0, updatedAt: createdAt) }
        self.createdAt = createdAt
        updatedAt = createdAt
        state = .prepared
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case libraryID
        case sessionGeneration
        case kind
        case targetIDs
        case steps
        case createdAt
        case updatedAt
        case state
        case failureSummary
        case recoverySummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        libraryID = try container.decode(UUID.self, forKey: .libraryID)
        sessionGeneration = try container.decode(UInt64.self, forKey: .sessionGeneration)
        kind = try container.decode(LibraryMutationKind.self, forKey: .kind)
        targetIDs = Array(Set(try container.decode([String].self, forKey: .targetIDs))).sorted()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        let decodedSteps = try container.decodeIfPresent([LibraryMutationStep].self, forKey: .steps)
        if let decodedSteps, !decodedSteps.isEmpty {
            steps = decodedSteps
        } else {
            let defaultStepIDs = kind.defaultStepIDs
            var defaultSteps: [LibraryMutationStep] = []
            defaultSteps.reserveCapacity(defaultStepIDs.count)
            for stepID in defaultStepIDs {
                defaultSteps.append(LibraryMutationStep(id: stepID, updatedAt: createdAt))
            }
            steps = defaultSteps
        }
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        state = try container.decode(LibraryMutationJournalState.self, forKey: .state)
        failureSummary = try container.decodeIfPresent(String.self, forKey: .failureSummary)
        recoverySummary = try container.decodeIfPresent(String.self, forKey: .recoverySummary)
    }
}

nonisolated enum LibraryMutationJournalError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case libraryIdentityMismatch(expected: UUID, actual: UUID)
    case missingIntent(UUID)
    case invalidTransition(from: LibraryMutationJournalState, to: LibraryMutationJournalState)
    case invalidStep(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema):
            return "不支持的资料库事务日志版本：\(schema)"
        case .libraryIdentityMismatch(let expected, let actual):
            return "事务日志不属于当前资料库（预期 \(expected)，实际 \(actual)）。"
        case .missingIntent(let id):
            return "资料库事务日志不存在：\(id)"
        case .invalidTransition(let from, let to):
            return "非法的资料库事务状态转换：\(from.rawValue) → \(to.rawValue)"
        case .invalidStep(let id):
            return "资料库事务步骤不存在或尚未进入提交阶段：\(id)"
        }
    }
}

/// Durable, library-scoped intent log for short mutations.
///
/// The journal does not pretend that SQLite plus sidecar files form one ACID
/// database. It makes an interrupted cross-store commit explicit so startup
/// can fail closed on corrupt evidence, then reload each authoritative store
/// and archive the adjudicated intent before accepting another writer.
actor LibraryMutationJournal {
    nonisolated let paths: LibraryPaths
    nonisolated let libraryID: UUID

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let completedRecordLimit: Int

    init(
        paths: LibraryPaths,
        libraryID: UUID,
        fileManager: FileManager = .default,
        completedRecordLimit: Int = 256
    ) {
        self.paths = paths
        self.libraryID = libraryID
        self.fileManager = fileManager
        self.completedRecordLimit = max(16, completedRecordLimit)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func prepare(
        kind: LibraryMutationKind,
        sessionGeneration: UInt64,
        targetIDs: [String] = [],
        stepIDs: [String] = []
    ) throws -> LibraryMutationIntent {
        try prepareDirectories()
        let intent = LibraryMutationIntent(
            libraryID: libraryID,
            sessionGeneration: sessionGeneration,
            kind: kind,
            targetIDs: targetIDs,
            stepIDs: stepIDs.isEmpty ? kind.defaultStepIDs : stepIDs
        )
        try persist(intent, to: pendingURL(for: intent.id))
        return intent
    }

    func markCommitting(_ intent: LibraryMutationIntent) throws -> LibraryMutationIntent {
        try transition(intent, to: .committing)
    }

    func markStepCompleted(
        _ intent: LibraryMutationIntent,
        stepID: String,
        summary: String? = nil
    ) throws -> LibraryMutationIntent {
        try updateStep(intent, stepID: stepID, state: .completed, summary: summary)
    }

    func markStepFailed(
        _ intent: LibraryMutationIntent,
        stepID: String,
        error: any Error
    ) throws -> LibraryMutationIntent {
        try updateStep(
            intent,
            stepID: stepID,
            state: .failed,
            summary: String(String(describing: error).prefix(1_024))
        )
    }

    func markFailed(
        _ intent: LibraryMutationIntent,
        error: any Error
    ) throws -> LibraryMutationIntent {
        var updated = try loadPending(id: intent.id)
        guard updated.state == .prepared || updated.state == .committing else {
            throw LibraryMutationJournalError.invalidTransition(from: updated.state, to: .failed)
        }
        updated.state = .failed
        updated.failureSummary = String(String(describing: error).prefix(1_024))
        updated.updatedAt = Date()
        try persist(updated, to: pendingURL(for: updated.id))
        return updated
    }

    func complete(_ intent: LibraryMutationIntent) throws -> LibraryMutationIntent {
        var updated = try loadPending(id: intent.id)
        guard updated.state == .committing else {
            throw LibraryMutationJournalError.invalidTransition(from: updated.state, to: .completed)
        }
        updated.state = .completed
        updated.updatedAt = Date()

        // Persist completion in Pending first, then the archive, then remove
        // Pending. Every crash point leaves at least one complete record.
        try persist(updated, to: pendingURL(for: updated.id))
        try persist(updated, to: completedURL(for: updated.id))
        try fileManager.removeItem(at: pendingURL(for: updated.id))
        try pruneCompletedRecordsIfNeeded()
        return updated
    }

    /// Adjudicates every leftover intent before the session loads runtime
    /// state. Callers must reload authoritative sidecars/databases afterwards.
    /// Corrupt or foreign records throw and prevent a writable open.
    func recoverInterruptedMutations() throws -> [LibraryMutationIntent] {
        try prepareDirectories()
        var recovered: [LibraryMutationIntent] = []
        for url in try pendingRecordURLs() {
            var intent = try decodeIntent(at: url)
            try validate(intent)
            if intent.state == .completed {
                try persist(intent, to: completedURL(for: intent.id))
                try fileManager.removeItem(at: url)
                continue
            }

            intent.state = .recovered
            intent.updatedAt = Date()
            let pendingSteps = intent.steps
                .filter { $0.state != .completed }
                .map(\.id)
            intent.recoverySummary = pendingSteps.isEmpty
                ? "authoritative stores reloaded at next session open; no step completion was claimed"
                : "authoritative stores reloaded at next session open; unresolved steps: \(pendingSteps.joined(separator: ","))"
            try persist(intent, to: completedURL(for: intent.id))
            try fileManager.removeItem(at: url)
            recovered.append(intent)
        }
        try pruneCompletedRecordsIfNeeded()
        return recovered.sorted { $0.createdAt < $1.createdAt }
    }

    func pendingIntents() throws -> [LibraryMutationIntent] {
        try pendingRecordURLs().map(decodeIntent(at:)).sorted { $0.createdAt < $1.createdAt }
    }

    func completedIntents() throws -> [LibraryMutationIntent] {
        guard fileManager.fileExists(atPath: paths.completedTransactionsRootURL.path) else { return [] }
        return try recordURLs(in: paths.completedTransactionsRootURL)
            .map(decodeIntent(at:))
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func transition(
        _ intent: LibraryMutationIntent,
        to newState: LibraryMutationJournalState
    ) throws -> LibraryMutationIntent {
        var updated = try loadPending(id: intent.id)
        guard updated.state == .prepared, newState == .committing else {
            throw LibraryMutationJournalError.invalidTransition(from: updated.state, to: newState)
        }
        updated.state = newState
        updated.updatedAt = Date()
        try persist(updated, to: pendingURL(for: updated.id))
        return updated
    }

    private func updateStep(
        _ intent: LibraryMutationIntent,
        stepID: String,
        state: LibraryMutationStepState,
        summary: String?
    ) throws -> LibraryMutationIntent {
        var updated = try loadPending(id: intent.id)
        guard updated.state == .committing,
              let index = updated.steps.firstIndex(where: { $0.id == stepID }) else {
            throw LibraryMutationJournalError.invalidStep(stepID)
        }
        updated.steps[index].state = state
        updated.steps[index].updatedAt = Date()
        updated.steps[index].resultSummary = summary
        updated.updatedAt = Date()
        try persist(updated, to: pendingURL(for: updated.id))
        return updated
    }

    private func loadPending(id: UUID) throws -> LibraryMutationIntent {
        let url = pendingURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw LibraryMutationJournalError.missingIntent(id)
        }
        let intent = try decodeIntent(at: url)
        try validate(intent)
        return intent
    }

    private func validate(_ intent: LibraryMutationIntent) throws {
        guard intent.schemaVersion == 1 || intent.schemaVersion == LibraryMutationIntent.currentSchemaVersion else {
            throw LibraryMutationJournalError.unsupportedSchema(intent.schemaVersion)
        }
        guard intent.libraryID == libraryID else {
            throw LibraryMutationJournalError.libraryIdentityMismatch(
                expected: libraryID,
                actual: intent.libraryID
            )
        }
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: paths.pendingTransactionsRootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: paths.completedTransactionsRootURL,
            withIntermediateDirectories: true
        )
    }

    private func pendingRecordURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: paths.pendingTransactionsRootURL.path) else { return [] }
        return try recordURLs(in: paths.pendingTransactionsRootURL)
    }

    private func recordURLs(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    private func pendingURL(for id: UUID) -> URL {
        paths.pendingTransactionsRootURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func completedURL(for id: UUID) -> URL {
        paths.completedTransactionsRootURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func decodeIntent(at url: URL) throws -> LibraryMutationIntent {
        let intent = try decoder.decode(LibraryMutationIntent.self, from: Data(contentsOf: url))
        try validate(intent)
        return intent
    }

    private func persist(_ intent: LibraryMutationIntent, to url: URL) throws {
        try encoder.encode(intent).write(to: url, options: .atomic)
    }

    private func pruneCompletedRecordsIfNeeded() throws {
        let records = try recordURLs(in: paths.completedTransactionsRootURL)
        guard records.count > completedRecordLimit else { return }
        let ordered = try records.sorted { lhs, rhs in
            let left = try lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let right = try rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            return left < right
        }
        for url in ordered.prefix(records.count - completedRecordLimit) {
            try fileManager.removeItem(at: url)
        }
    }
}
