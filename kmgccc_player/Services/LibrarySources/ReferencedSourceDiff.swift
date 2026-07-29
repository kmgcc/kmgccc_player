import Foundation

nonisolated struct ReferencedSourceAddedFile: Codable, Sendable, Equatable {
    var relativePath: String
    var fingerprint: ReferencedFileFingerprint
}

nonisolated struct ReferencedSourceMovedFile: Codable, Sendable, Equatable {
    var trackID: UUID
    var oldRelativePath: String
    var newRelativePath: String
    var fingerprint: ReferencedFileFingerprint
}

nonisolated struct ReferencedSourceReplacement: Codable, Sendable, Equatable {
    var trackID: UUID
    var relativePath: String
    var oldFingerprint: ReferencedFileFingerprint
    var newFingerprint: ReferencedFileFingerprint
}

nonisolated struct ReferencedSourceMissingFile: Codable, Sendable, Equatable {
    var trackID: UUID
    var relativePath: String
}

nonisolated struct ReferencedSourceScanFailure: Codable, Sendable, Equatable {
    var relativePath: String?
    var summary: String
}

nonisolated struct ReferencedSourceDiff: Codable, Sendable, Equatable {
    var libraryID: UUID
    var libraryGeneration: UInt64
    var sourceID: UUID
    var scanGeneration: UInt64
    var sourceStatus: ReferencedSourceStatus
    var added: [ReferencedSourceAddedFile] = []
    var moved: [ReferencedSourceMovedFile] = []
    var replacements: [ReferencedSourceReplacement] = []
    var missing: [ReferencedSourceMissingFile] = []
    var failures: [ReferencedSourceScanFailure] = []

    var affectedTrackIDs: [UUID] {
        Array(Set(moved.map(\.trackID) + replacements.map(\.trackID) + missing.map(\.trackID)))
            .sorted { $0.uuidString < $1.uuidString }
    }

    var isEmpty: Bool {
        added.isEmpty && moved.isEmpty && replacements.isEmpty && missing.isEmpty && failures.isEmpty
    }
}
