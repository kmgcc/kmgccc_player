import Foundation

nonisolated struct ReferencedSourceLocatorMutation: Codable, Sendable, Equatable {
    let trackID: UUID
    let locator: ReferencedFileLocator
    let availability: TrackAvailability
}

nonisolated enum LibraryReconcileOperation: String, Codable, Sendable {
    case reconcile
    case sourceReconnect
    case sourceRemoval
}

nonisolated enum LibraryReconcileIntentState: String, Codable, Sendable {
    case prepared
    case sidecarsCommitted
    case runtimeApplied
}

nonisolated enum LibraryReconcileIntentStoreError: Error, Equatable {
    case corruptIntent(String)
    case unsupportedSchema(Int)
    case activeIntentExists(sourceID: UUID, intentID: UUID)
    case invalidState(expected: LibraryReconcileIntentState, actual: LibraryReconcileIntentState)
    case invalidTransition(from: LibraryReconcileIntentState, to: LibraryReconcileIntentState)
}

nonisolated struct LibraryReconcileIntent: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    let id: UUID
    let libraryID: UUID
    let libraryGeneration: UInt64
    let sourceID: UUID
    let scanGeneration: UInt64
    let diff: ReferencedSourceDiff
    var affectedTrackIDs: [UUID]
    var mutations: [ReferencedSourceLocatorMutation]
    var committedTrackIDs: [UUID]
    var proposedManifest: ReferencedSourceScanManifest?
    var proposedSourceDescriptor: ReferencedSourceDescriptor?
    var operation: LibraryReconcileOperation
    var state: LibraryReconcileIntentState
    let createdAt: Date
    var updatedAt: Date
}

actor LibraryReconcileIntentStore {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(paths: LibraryPaths, fileManager: FileManager = .default) {
        directoryURL = paths.sourceScanCacheRootURL.appendingPathComponent("Reconcile", isDirectory: true)
        self.fileManager = fileManager
    }

    func prepare(
        _ diff: ReferencedSourceDiff,
        mutations: [ReferencedSourceLocatorMutation] = [],
        proposedManifest: ReferencedSourceScanManifest? = nil,
        proposedSourceDescriptor: ReferencedSourceDescriptor? = nil,
        operation: LibraryReconcileOperation = .reconcile
    ) throws -> LibraryReconcileIntent {
        if let active = try pending(libraryID: diff.libraryID, sourceID: diff.sourceID).first {
            throw LibraryReconcileIntentStoreError.activeIntentExists(
                sourceID: diff.sourceID,
                intentID: active.id
            )
        }
        let now = Date()
        let intent = LibraryReconcileIntent(
            id: UUID(),
            libraryID: diff.libraryID,
            libraryGeneration: diff.libraryGeneration,
            sourceID: diff.sourceID,
            scanGeneration: diff.scanGeneration,
            diff: diff,
            affectedTrackIDs: Array(Set(diff.affectedTrackIDs + mutations.map(\.trackID)))
                .sorted { $0.uuidString < $1.uuidString },
            mutations: mutations,
            committedTrackIDs: [],
            proposedManifest: proposedManifest,
            proposedSourceDescriptor: proposedSourceDescriptor,
            operation: operation,
            state: .prepared,
            createdAt: now,
            updatedAt: now
        )
        try persist(intent)
        return intent
    }

    func updateMutations(
        _ intent: LibraryReconcileIntent,
        mutations: [ReferencedSourceLocatorMutation]
    ) throws -> LibraryReconcileIntent {
        try requirePrepared(intent)
        var updated = intent
        updated.mutations = mutations
        updated.affectedTrackIDs = Array(Set(updated.diff.affectedTrackIDs + mutations.map(\.trackID)))
            .sorted { $0.uuidString < $1.uuidString }
        updated.updatedAt = Date()
        try persist(updated)
        return updated
    }

    func recordAuthorityCommits(
        _ intent: LibraryReconcileIntent,
        trackIDs: [UUID]
    ) throws -> LibraryReconcileIntent {
        try requirePrepared(intent)
        var updated = intent
        updated.committedTrackIDs = Array(Set(updated.committedTrackIDs + trackIDs))
            .sorted { $0.uuidString < $1.uuidString }
        updated.updatedAt = Date()
        try persist(updated)
        return updated
    }

    func updateManifest(
        _ intent: LibraryReconcileIntent,
        manifest: ReferencedSourceScanManifest?
    ) throws -> LibraryReconcileIntent {
        try requirePrepared(intent)
        var updated = intent
        updated.proposedManifest = manifest
        updated.updatedAt = Date()
        try persist(updated)
        return updated
    }

    func advance(_ intent: LibraryReconcileIntent, to state: LibraryReconcileIntentState) throws -> LibraryReconcileIntent {
        guard intent.state != state else { return intent }
        let isAllowed = (intent.state == .prepared && state == .sidecarsCommitted)
            || (intent.state == .sidecarsCommitted && state == .runtimeApplied)
        guard isAllowed else {
            throw LibraryReconcileIntentStoreError.invalidTransition(from: intent.state, to: state)
        }
        var updated = intent
        updated.state = state
        updated.updatedAt = Date()
        try persist(updated)
        return updated
    }

    func pending(
        libraryID: UUID,
        sourceID: UUID? = nil
    ) throws -> [LibraryReconcileIntent] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var intents: [LibraryReconcileIntent] = []
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        for url in urls {
            let intent: LibraryReconcileIntent
            do {
                intent = try decoder.decode(LibraryReconcileIntent.self, from: Data(contentsOf: url))
            } catch {
                // A truncated/half-written intent (crash mid-write, foreign
                // process contention) must not wedge replay forever:
                // quarantine it aside and keep replaying the rest.
                let quarantineURL = url.appendingPathExtension("corrupt")
                try? fileManager.removeItem(at: quarantineURL)
                do {
                    try fileManager.moveItem(at: url, to: quarantineURL)
                    Log.warning(
                        "[ReconcileIntent] quarantined corrupt intent \(url.lastPathComponent)",
                        category: .library
                    )
                } catch {
                    throw LibraryReconcileIntentStoreError.corruptIntent(url.path)
                }
                continue
            }
            guard intent.schemaVersion == LibraryReconcileIntent.currentSchemaVersion else {
                throw LibraryReconcileIntentStoreError.unsupportedSchema(intent.schemaVersion)
            }
            guard intent.libraryID == libraryID,
                  sourceID == nil || intent.sourceID == sourceID else { continue }
            intents.append(intent)
        }
        return intents.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ intent: LibraryReconcileIntent) throws {
        let url = intentURL(intent.id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func requirePrepared(_ intent: LibraryReconcileIntent) throws {
        guard intent.state == .prepared else {
            throw LibraryReconcileIntentStoreError.invalidState(
                expected: .prepared,
                actual: intent.state
            )
        }
    }

    private func persist(_ intent: LibraryReconcileIntent) throws {
        guard intent.schemaVersion == LibraryReconcileIntent.currentSchemaVersion else {
            throw LibraryReconcileIntentStoreError.unsupportedSchema(intent.schemaVersion)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(intent).write(to: intentURL(intent.id), options: .atomic)
    }

    private func intentURL(_ id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }
}
