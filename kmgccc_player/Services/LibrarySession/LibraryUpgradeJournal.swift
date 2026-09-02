//
//  LibraryUpgradeJournal.swift
//  kmgccc_player
//
//  Durable checkpoints for idempotent legacy-library registration.
//

import Foundation

nonisolated struct LibraryUpgradeJournal: Codable, Sendable, Equatable {
    static let schemaVersion = 2

    enum Stage: String, Codable, Sendable, Comparable {
        case discovered
        case manifestWritten
        case registryWritten
        case cachesMigrated
        case validated
        case committed

        static func < (lhs: Stage, rhs: Stage) -> Bool {
            order(lhs) < order(rhs)
        }

        private static func order(_ stage: Stage) -> Int {
            switch stage {
            case .discovered: return 0
            case .manifestWritten: return 1
            case .registryWritten: return 2
            case .cachesMigrated: return 3
            case .validated: return 4
            case .committed: return 5
            }
        }
    }

    let schemaVersion: Int
    let libraryID: UUID
    let rootPath: String
    var stage: Stage
    let startedAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case libraryID
        case rootPath
        case stage
        case startedAt
        case updatedAt
    }

    init(
        libraryID: UUID,
        rootURL: URL,
        stage: Stage = .discovered,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.libraryID = libraryID
        self.rootPath = rootURL.standardizedFileURL.path
        self.stage = stage
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchema = try values.decode(Int.self, forKey: .schemaVersion)
        guard storedSchema == 1 || storedSchema == Self.schemaVersion else {
            throw LibraryUpgradeJournalError.unsupportedSchema(storedSchema)
        }
        schemaVersion = Self.schemaVersion
        libraryID = try values.decode(UUID.self, forKey: .libraryID)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        let storedStage = try values.decode(Stage.self, forKey: .stage)
        stage = storedSchema == 1 && storedStage == .committed
            ? .registryWritten
            : storedStage
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    static func read(from url: URL) throws -> LibraryUpgradeJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(Self.self, from: Data(contentsOf: url))
        return journal
    }

    func advancing(to newStage: Stage, now: Date = Date()) -> LibraryUpgradeJournal {
        var copy = self
        if newStage > copy.stage {
            copy.stage = newStage
        }
        copy.updatedAt = now
        return copy
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

nonisolated enum LibraryUpgradeJournalError: Error, Equatable {
    case unsupportedSchema(Int)
    case rootMismatch
    case manifestIdentityMismatch
}
