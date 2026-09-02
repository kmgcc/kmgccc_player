//
//  PlaybackHistoryStorePaths.swift
//  myPlayer2
//
//  Persistent location for the playback history event store.
//

import Foundation
import SQLite3

enum PlaybackHistoryStorePaths {
    nonisolated static let directoryName = "PlaybackHistory"
    nonisolated static let storeFileName = "PlaybackHistory.sqlite"
    private static let legacyMigrationOwnerKey = "playbackHistory.legacyStoreMigration.owner.v3"

    /// Playback history is user-owned library data, not a regenerable cache.
    static func directoryURL(in paths: LibraryPaths) -> URL {
        paths.playbackHistoryRootURL
    }

    static func storeURL(in paths: LibraryPaths) -> URL {
        paths.playbackHistoryStoreURL
    }

    static func prepareStoreURL(
        in paths: LibraryPaths,
        fileManager: FileManager = .default
    ) -> URL {
        let directory = directoryURL(in: paths)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return storeURL(in: paths)
    }

    static func migrateLegacyStoreIfNeeded(
        to context: LibraryContext,
        legacyStoreURL: URL,
        upgradedLegacyRootURL: URL,
        stagingRootURL: URL,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) throws {
        let existingOwner = defaults.string(forKey: legacyMigrationOwnerKey)
            .flatMap(UUID.init(uuidString:))
        guard LegacyLibraryMigrationOwnership(ownerLibraryID: existingOwner).canClaim(
            libraryID: context.id,
            destinationRoot: context.rootURL,
            upgradedLegacyRoot: upgradedLegacyRootURL
        ) else {
            return
        }

        let destination = storeURL(in: context.paths)
        if fileManager.fileExists(atPath: destination.path) {
            defaults.set(context.id.uuidString, forKey: legacyMigrationOwnerKey)
            return
        }
        guard fileManager.fileExists(atPath: legacyStoreURL.path) else {
            defaults.set(context.id.uuidString, forKey: legacyMigrationOwnerKey)
            return
        }

        let stagingDirectory = stagingRootURL.appendingPathComponent(
            "LegacyPlaybackHistory",
            isDirectory: true
        )
        try? fileManager.removeItem(at: stagingDirectory)
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let suffixes = ["", "-wal", "-shm"]
        var stagedFiles: [(source: URL, staged: URL, destination: URL)] = []
        for suffix in suffixes {
            let source = URL(fileURLWithPath: legacyStoreURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let staged = stagingDirectory.appendingPathComponent(storeFileName + suffix)
            let destinationFile = URL(fileURLWithPath: destination.path + suffix)
            guard !fileManager.fileExists(atPath: destinationFile.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try fileManager.copyItem(at: source, to: staged)
            let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let stagedSize = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard sourceSize == stagedSize else {
                throw CocoaError(.fileReadCorruptFile)
            }
            stagedFiles.append((source, staged, destinationFile))
        }
        guard stagedFiles.contains(where: { $0.source == legacyStoreURL }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try validateSQLite(at: stagingDirectory.appendingPathComponent(storeFileName))

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var createdDestinationFiles: [URL] = []
        do {
            for file in stagedFiles {
                try fileManager.copyItem(at: file.staged, to: file.destination)
                createdDestinationFiles.append(file.destination)
            }
        } catch {
            for url in createdDestinationFiles {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }

        defaults.set(context.id.uuidString, forKey: legacyMigrationOwnerKey)
    }

    private static func validateSQLite(at url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close_v2(database) }
            throw LibraryUpgradeValidationError.sqliteIntegrityFailed(url.lastPathComponent)
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LibraryUpgradeValidationError.sqliteIntegrityFailed(url.lastPathComponent)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0),
              String(cString: raw).lowercased() == "ok" else {
            throw LibraryUpgradeValidationError.sqliteIntegrityFailed(url.lastPathComponent)
        }
    }
}
