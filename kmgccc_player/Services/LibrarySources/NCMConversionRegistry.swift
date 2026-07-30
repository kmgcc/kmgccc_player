//
//  NCMConversionRegistry.swift
//  kmgccc_player
//

import Foundation

// NCMConversionAssociation is persisted with TrackSidecar in LibrarySidecars.swift.

nonisolated enum NCMConversionState: String, Codable, Sendable {
    case pending
    case outputReady
    case committed
    case removed
    case failed
}

nonisolated struct NCMConversionRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let sourceIdentity: ReferencedFileIdentity?
    let sourceFingerprint: ReferencedFileFingerprint
    let sourceBookmarkData: Data
    let parentDirectoryBookmarkData: Data?
    let sourcePath: String
    let sourceMemberships: [ReferencedSourceMembership]
    let sourcePrimaryID: UUID?
    let expectedOutputPath: String
    var outputIdentity: ReferencedFileIdentity?
    var outputFingerprint: ReferencedFileFingerprint?
    var outputLocator: ReferencedFileLocator?
    var outputFormat: NCMFormat?
    var outputMetadata: NCMMetadata?
    var outputCoverData: Data?
    var trackID: UUID?
    var state: NCMConversionState
    var errorSummary: String?
    let createdAt: Date
    var updatedAt: Date
}

nonisolated struct NCMConversionJournal: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = Self.currentSchemaVersion
    var records: [NCMConversionRecord] = []
}

nonisolated enum NCMConversionRegistryError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case sourceAlreadyReserved(UUID)
    case outputAlreadyReserved(UUID)
    case recordNotFound(UUID)
    case invalidTransition

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Unsupported NCM conversion journal schema: \(version)"
        case .sourceAlreadyReserved: return "This NCM file already has an active conversion."
        case .outputAlreadyReserved: return "The NCM output is already reserved."
        case .recordNotFound: return "The NCM conversion reservation was not found."
        case .invalidTransition: return "The NCM conversion reservation is in an invalid state."
        }
    }
}

actor NCMConversionRegistry {
    private let url: URL
    private let fileManager = FileManager.default
    private var journal: NCMConversionJournal?

    init(paths: LibraryPaths) {
        self.url = paths.ncmConversionsURL
    }

    func load() throws -> NCMConversionJournal {
        if let journal { return journal }
        guard fileManager.fileExists(atPath: url.path) else {
            let empty = NCMConversionJournal()
            journal = empty
            return empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            NCMConversionJournal.self,
            from: Data(contentsOf: url)
        )
        guard decoded.schemaVersion == NCMConversionJournal.currentSchemaVersion else {
            throw NCMConversionRegistryError.unsupportedSchema(decoded.schemaVersion)
        }
        journal = decoded
        return decoded
    }

    func reserve(_ record: NCMConversionRecord) throws {
        var current = try load()
        if let existing = current.records.first(where: {
            Self.sameSource($0, record)
                && ($0.state == .pending || $0.state == .outputReady || $0.state == .committed)
        }) {
            throw NCMConversionRegistryError.sourceAlreadyReserved(existing.id)
        }
        if let existing = current.records.first(where: {
            $0.expectedOutputPath == record.expectedOutputPath
                && ($0.state == .pending || $0.state == .outputReady || $0.state == .committed)
        }) {
            throw NCMConversionRegistryError.outputAlreadyReserved(existing.id)
        }
        current.records.append(record)
        try persist(current)
    }

    func updateExpectedOutput(operationID: UUID, path: String) throws {
        var current = try load()
        guard let index = current.records.firstIndex(where: { $0.id == operationID }) else {
            throw NCMConversionRegistryError.recordNotFound(operationID)
        }
        guard current.records[index].state == .pending else {
            throw NCMConversionRegistryError.invalidTransition
        }
        if let existing = current.records.first(where: {
            $0.id != operationID && $0.expectedOutputPath == path && $0.state != .failed
        }) {
            throw NCMConversionRegistryError.outputAlreadyReserved(existing.id)
        }
        current.records[index] = NCMConversionRecord(
            id: current.records[index].id,
            sourceIdentity: current.records[index].sourceIdentity,
            sourceFingerprint: current.records[index].sourceFingerprint,
            sourceBookmarkData: current.records[index].sourceBookmarkData,
            parentDirectoryBookmarkData: current.records[index].parentDirectoryBookmarkData,
            sourcePath: current.records[index].sourcePath,
            sourceMemberships: current.records[index].sourceMemberships,
            sourcePrimaryID: current.records[index].sourcePrimaryID,
            expectedOutputPath: path,
            outputIdentity: current.records[index].outputIdentity,
            outputFingerprint: current.records[index].outputFingerprint,
            outputLocator: current.records[index].outputLocator,
            outputFormat: current.records[index].outputFormat,
            outputMetadata: current.records[index].outputMetadata,
            outputCoverData: current.records[index].outputCoverData,
            trackID: current.records[index].trackID,
            state: current.records[index].state,
            errorSummary: current.records[index].errorSummary,
            createdAt: current.records[index].createdAt,
            updatedAt: Date()
        )
        try persist(current)
    }

    func prepareOutputPayload(
        operationID: UUID,
        format: NCMFormat,
        metadata: NCMMetadata,
        coverData: Data?
    ) throws {
        try update(operationID) { record in
            guard record.state == .pending else { throw NCMConversionRegistryError.invalidTransition }
            record.outputFormat = format
            record.outputMetadata = metadata
            record.outputCoverData = coverData
            record.updatedAt = Date()
        }
    }

    func markOutputReady(
        operationID: UUID,
        outputFingerprint: ReferencedFileFingerprint,
        locator: ReferencedFileLocator,
        format: NCMFormat,
        metadata: NCMMetadata,
        coverData: Data?
    ) throws {
        try update(operationID) { record in
            guard record.state == .pending else { throw NCMConversionRegistryError.invalidTransition }
            record.outputFingerprint = outputFingerprint
            record.outputIdentity = outputFingerprint.identity
            record.outputLocator = locator
            record.outputFormat = format
            record.outputMetadata = metadata
            record.outputCoverData = coverData
            record.state = .outputReady
            record.updatedAt = Date()
        }
    }

    func associateTrack(operationID: UUID, trackID: UUID) throws {
        try update(operationID) { record in
            guard record.state == .outputReady else { throw NCMConversionRegistryError.invalidTransition }
            if let existing = record.trackID, existing != trackID {
                throw NCMConversionRegistryError.invalidTransition
            }
            record.trackID = trackID
            record.updatedAt = Date()
        }
    }

    func markCommitted(operationID: UUID, trackID: UUID) throws {
        try update(operationID) { record in
            guard record.state == .outputReady || record.state == .committed else {
                throw NCMConversionRegistryError.invalidTransition
            }
            record.trackID = trackID
            record.state = .committed
            record.errorSummary = nil
            record.updatedAt = Date()
        }
    }

    func markFailed(operationID: UUID, summary: String) throws {
        try update(operationID) { record in
            guard record.state != .committed && record.state != .removed else {
                throw NCMConversionRegistryError.invalidTransition
            }
            record.state = .failed
            record.errorSummary = String(summary.prefix(512))
            record.updatedAt = Date()
        }
    }

    func record(operationID: UUID) throws -> NCMConversionRecord? {
        try load().records.first { $0.id == operationID }
    }

    func committedRecord(matching fingerprint: ReferencedFileFingerprint) throws -> NCMConversionRecord? {
        try load().records.first {
            $0.state == .committed && Self.sameFingerprint($0.sourceFingerprint, fingerprint)
        }
    }

    func removedRecord(matching fingerprint: ReferencedFileFingerprint) throws -> NCMConversionRecord? {
        try load().records.first {
            $0.state == .removed && Self.sameFingerprint($0.sourceFingerprint, fingerprint)
        }
    }

    @discardableResult
    func markRemoved(operationID: UUID) throws -> NCMConversionRecord {
        var removed: NCMConversionRecord?
        try update(operationID) { record in
            guard record.state == .committed || record.state == .outputReady || record.state == .removed else {
                throw NCMConversionRegistryError.invalidTransition
            }
            record.state = .removed
            record.errorSummary = nil
            record.updatedAt = Date()
            removed = record
        }
        guard let removed else { throw NCMConversionRegistryError.recordNotFound(operationID) }
        return removed
    }

    func allowManualRetry(
        matching fingerprint: ReferencedFileFingerprint
    ) throws -> [ReferencedFileFingerprint] {
        var current = try load()
        guard let index = current.records.firstIndex(where: {
            $0.state == .removed && Self.sameFingerprint($0.sourceFingerprint, fingerprint)
        }) else { return [] }
        var clearedFingerprints = [current.records[index].sourceFingerprint]
        if let outputFingerprint = current.records[index].outputFingerprint {
            clearedFingerprints.append(outputFingerprint)
        }
        let outputExists = fileManager.fileExists(atPath: current.records[index].expectedOutputPath)
        if outputExists,
           current.records[index].outputFingerprint != nil,
           current.records[index].outputFormat != nil,
           current.records[index].outputMetadata != nil {
            current.records[index].state = .outputReady
            current.records[index].trackID = nil
            current.records[index].errorSummary = nil
        } else {
            current.records[index].state = .failed
            current.records[index].trackID = nil
            current.records[index].errorSummary = "Manual retry requested"
        }
        current.records[index].updatedAt = Date()
        try persist(current)
        return clearedFingerprints
    }

    func restoreAfterFailedRemoval(operationID: UUID) throws {
        try update(operationID) { record in
            guard record.state == .removed else { return }
            record.state = record.trackID == nil ? .outputReady : .committed
            record.updatedAt = Date()
        }
    }

    func activeRecord(matching fingerprint: ReferencedFileFingerprint) throws -> NCMConversionRecord? {
        try load().records.first {
            ($0.state == .pending || $0.state == .outputReady)
                && Self.sameFingerprint($0.sourceFingerprint, fingerprint)
        }
    }

    func isReserved(url candidate: URL, identity: ReferencedFileIdentity?) throws -> Bool {
        let path = candidate.standardizedFileURL.path
        return try load().records.contains { record in
            switch record.state {
            case .pending, .outputReady:
                if let identity, identity == record.sourceIdentity || identity == record.outputIdentity {
                    return true
                }
                return record.sourcePath == path || record.expectedOutputPath == path
            case .committed:
                if let identity, identity == record.sourceIdentity { return true }
                return record.sourcePath == path
            case .removed:
                if let identity, identity == record.sourceIdentity || identity == record.outputIdentity {
                    return true
                }
                return record.sourcePath == path || record.expectedOutputPath == path
            case .failed:
                return false
            }
        }
    }

    private func update(
        _ operationID: UUID,
        mutation: (inout NCMConversionRecord) throws -> Void
    ) throws {
        var current = try load()
        guard let index = current.records.firstIndex(where: { $0.id == operationID }) else {
            throw NCMConversionRegistryError.recordNotFound(operationID)
        }
        try mutation(&current.records[index])
        try persist(current)
    }

    private func persist(_ value: NCMConversionJournal) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        journal = value
    }

    private static func sameSource(_ lhs: NCMConversionRecord, _ rhs: NCMConversionRecord) -> Bool {
        sameFingerprint(lhs.sourceFingerprint, rhs.sourceFingerprint)
    }

    nonisolated static func sameFingerprint(
        _ lhs: ReferencedFileFingerprint,
        _ rhs: ReferencedFileFingerprint
    ) -> Bool {
        let leftStable = lhs.identity.flatMap(Self.stableIdentity)
        let rightStable = rhs.identity.flatMap(Self.stableIdentity)
        switch (leftStable, rightStable) {
        case let (.some(left), .some(right)):
            return left == right
        case (.some, .none), (.none, .some):
            return false
        case (.none, .none):
            return lhs.fileSize == rhs.fileSize && lhs.modifiedAt == rhs.modifiedAt
        }
    }

    private nonisolated static func stableIdentity(
        _ identity: ReferencedFileIdentity
    ) -> ReferencedFileIdentity? {
        guard identity.volumeUUID?.isEmpty == false,
              identity.resourceIdentifierArchive?.isEmpty == false else { return nil }
        return identity
    }
}
