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

nonisolated struct ReferencedSourceIgnoredFile: Codable, Sendable, Equatable {
    var relativePath: String
    var fingerprint: ReferencedFileFingerprint
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
    var ignored: [ReferencedSourceIgnoredFile] = []
    var failures: [ReferencedSourceScanFailure] = []

    var affectedTrackIDs: [UUID] {
        Array(Set(moved.map(\.trackID) + replacements.map(\.trackID) + missing.map(\.trackID)))
            .sorted { $0.uuidString < $1.uuidString }
    }

    var isEmpty: Bool {
        added.isEmpty && moved.isEmpty && replacements.isEmpty && missing.isEmpty
            && ignored.isEmpty && failures.isEmpty
    }
}

nonisolated extension ReferencedSourceDiff {
    private enum CodingKeys: String, CodingKey {
        case libraryID
        case libraryGeneration
        case sourceID
        case scanGeneration
        case sourceStatus
        case added
        case moved
        case replacements
        case missing
        case ignored
        case failures
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        libraryID = try values.decode(UUID.self, forKey: .libraryID)
        libraryGeneration = try values.decode(UInt64.self, forKey: .libraryGeneration)
        sourceID = try values.decode(UUID.self, forKey: .sourceID)
        scanGeneration = try values.decode(UInt64.self, forKey: .scanGeneration)
        sourceStatus = try values.decode(ReferencedSourceStatus.self, forKey: .sourceStatus)
        added = try values.decodeIfPresent([ReferencedSourceAddedFile].self, forKey: .added) ?? []
        moved = try values.decodeIfPresent([ReferencedSourceMovedFile].self, forKey: .moved) ?? []
        replacements = try values.decodeIfPresent([ReferencedSourceReplacement].self, forKey: .replacements) ?? []
        missing = try values.decodeIfPresent([ReferencedSourceMissingFile].self, forKey: .missing) ?? []
        ignored = try values.decodeIfPresent([ReferencedSourceIgnoredFile].self, forKey: .ignored) ?? []
        failures = try values.decodeIfPresent([ReferencedSourceScanFailure].self, forKey: .failures) ?? []
    }
}
