//
//  MusicLibraryManifest.swift
//  kmgccc_player
//
//  Authoritative identity and immutable storage mode for a music library.
//

import Foundation

nonisolated enum MusicLibraryMode: String, Codable, Sendable, CaseIterable {
    case managed
    case referenced
}

nonisolated enum MusicLibraryManifestError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case invalidMode(String)
    case invalidLibraryID
    case emptyDisplayName

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported music library schema: \(version)"
        case .invalidMode(let mode):
            return "Unsupported music library mode: \(mode)"
        case .invalidLibraryID:
            return "The music library identifier is invalid."
        case .emptyDisplayName:
            return "The music library display name is empty."
        }
    }
}

nonisolated struct MusicLibraryManifest: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let fileName = "library.json"

    let schemaVersion: Int
    let libraryID: UUID
    var displayName: String
    let mode: MusicLibraryMode
    let createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = MusicLibraryManifest.currentSchemaVersion,
        libraryID: UUID = UUID(),
        displayName: String,
        mode: MusicLibraryMode,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.libraryID = libraryID
        self.displayName = displayName
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case libraryID
        case displayName
        case mode
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        libraryID = try container.decode(UUID.self, forKey: .libraryID)
        displayName = try container.decode(String.self, forKey: .displayName)

        let rawMode = try container.decode(String.self, forKey: .mode)
        guard let decodedMode = MusicLibraryMode(rawValue: rawMode) else {
            throw MusicLibraryManifestError.invalidMode(rawMode)
        }
        mode = decodedMode
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func validated() throws -> MusicLibraryManifest {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MusicLibraryManifestError.unsupportedSchema(schemaVersion)
        }
        guard libraryID != UUID.zero else {
            throw MusicLibraryManifestError.invalidLibraryID
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MusicLibraryManifestError.emptyDisplayName
        }
        return self
    }

    static func read(from url: URL) throws -> MusicLibraryManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MusicLibraryManifest.self, from: data).validated()
    }

    func write(to url: URL, fileManager: FileManager = .default) throws {
        _ = try validated()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

nonisolated extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
