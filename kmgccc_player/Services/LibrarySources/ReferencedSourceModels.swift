//
//  ReferencedSourceModels.swift
//  kmgccc_player
//
//  Authoritative descriptors for user-authorized referenced-library roots.
//

import Foundation

nonisolated enum ReferencedSourceMode: String, Codable, Sendable {
    case directory
}

nonisolated enum ReferencedSourceStatus: String, Codable, Sendable {
    case available
    case stale
    case permissionDenied
    case offline
}

nonisolated struct ReferencedSourceDescriptor: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let mode: ReferencedSourceMode
    var rootBookmarkData: Data
    var lastKnownPath: String
    var displayName: String
    let createdAt: Date
    var lastScan: Date?
    var status: ReferencedSourceStatus

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        mode: ReferencedSourceMode = .directory,
        rootBookmarkData: Data,
        lastKnownPath: String,
        displayName: String,
        createdAt: Date = Date(),
        lastScan: Date? = nil,
        status: ReferencedSourceStatus = .available
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.mode = mode
        self.rootBookmarkData = rootBookmarkData
        self.lastKnownPath = lastKnownPath
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastScan = lastScan
        self.status = status
    }
}

nonisolated enum ReferencedSourceStoreError: Error, Equatable, LocalizedError {
    case incompleteSource(UUID)
    case missingSchema
    case unsupportedSchema(Int)
    case missingMode
    case unsupportedMode(String)
    case identifierMismatch(expected: UUID, actual: UUID)
    case emptyBookmark
    case invalidPath
    case invalidDisplayName

    var errorDescription: String? {
        switch self {
        case .incompleteSource(let id): return "Referenced source \(id) is missing source.json."
        case .missingSchema: return "Referenced source schemaVersion is missing."
        case .unsupportedSchema(let version): return "Unsupported referenced source schema: \(version)"
        case .missingMode: return "Referenced source mode is missing."
        case .unsupportedMode(let mode): return "Unsupported referenced source mode: \(mode)"
        case .identifierMismatch(let expected, let actual):
            return "Referenced source identifier mismatch: expected \(expected), found \(actual)"
        case .emptyBookmark: return "Referenced source bookmark is empty."
        case .invalidPath: return "Referenced source path is invalid."
        case .invalidDisplayName: return "Referenced source display name is empty."
        }
    }
}
