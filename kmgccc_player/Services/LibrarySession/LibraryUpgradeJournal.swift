//
//  LibraryUpgradeJournal.swift
//  kmgccc_player
//
//  Durable checkpoints for idempotent legacy-library registration.
//

import Foundation

nonisolated struct LibraryUpgradeJournal: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    enum Stage: String, Codable, Sendable, Comparable {
        case discovered
        case manifestWritten
        case registryWritten
        case committed

        static func < (lhs: Stage, rhs: Stage) -> Bool {
            order(lhs) < order(rhs)
        }

        private static func order(_ stage: Stage) -> Int {
            switch stage {
            case .discovered: return 0
            case .manifestWritten: return 1
            case .registryWritten: return 2
            case .committed: return 3
            }
        }
    }

    let schemaVersion: Int
    let libraryID: UUID
    let rootPath: String
    var stage: Stage
    let startedAt: Date
    var updatedAt: Date

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

    static func read(from url: URL) throws -> LibraryUpgradeJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(Self.self, from: Data(contentsOf: url))
        guard journal.schemaVersion == Self.schemaVersion else {
            throw LibraryUpgradeJournalError.unsupportedSchema(journal.schemaVersion)
        }
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
