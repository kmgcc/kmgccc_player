//
//  PlaybackHistoryStorePaths.swift
//  myPlayer2
//
//  Persistent location for the playback history event store.
//

import Foundation

enum PlaybackHistoryStorePaths {
    static let directoryName = "PlaybackHistory"
    static let storeFileName = "PlaybackHistory.sqlite"
    private static let legacyMigrationOwnerKey = "playbackHistory.legacyStoreMigration.owner.v3"

    /// Playback history is user-owned library data, not a regenerable cache.
    static func directoryURL(in paths: LibraryPaths) -> URL {
        paths.playbackHistoryRootURL
    }

    static func storeURL(in paths: LibraryPaths) -> URL {
        paths.playbackHistoryStoreURL
    }

    // Compatibility only; remove after history/session migration.
    static var directoryURL: URL {
        directoryURL(in: LibraryPaths(rootURL: LibraryLocationStore.activeLibraryRootURL))
    }

    // Compatibility only; remove after history/session migration.
    static var storeURL: URL {
        storeURL(in: LibraryPaths(rootURL: LibraryLocationStore.activeLibraryRootURL))
    }

    /// The pre-library-location store used by the first playback-history build.
    /// It is only a migration source; new records never go back here.
    static var legacyStoreURL: URL {
        let appSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "kmgccc.player"
        let directory = appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("PlaybackHistory", isDirectory: true)
        return directory.appendingPathComponent("PlaybackHistory.sqlite")
    }

    static func prepareStoreURL(
        in paths: LibraryPaths,
        libraryID: UUID,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> URL {
        let directory = directoryURL(in: paths)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = storeURL(in: paths)
        migrateLegacyStoreIfNeeded(
            to: destination,
            libraryID: libraryID,
            fileManager: fileManager,
            defaults: defaults
        )
        return destination
    }

    // Compatibility only; remove after history/session migration.
    static func prepareStoreURL(at libraryRootURL: URL = LibraryLocationStore.activeLibraryRootURL) -> URL {
        let paths = LibraryPaths(rootURL: libraryRootURL)
        return prepareStoreURL(in: paths, libraryID: stableLegacyLibraryID(for: paths.rootURL))
    }

    private static func migrateLegacyStoreIfNeeded(
        to destination: URL,
        libraryID: UUID,
        fileManager: FileManager,
        defaults: UserDefaults
    ) {
        let existingOwner = defaults.string(forKey: legacyMigrationOwnerKey).flatMap(UUID.init(uuidString:))
        let ownership = LegacyLibraryMigrationOwnership(ownerLibraryID: existingOwner)
        let destinationRoot = destination
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard ownership.canClaim(
            libraryID: libraryID,
            destinationRoot: destinationRoot,
            upgradedLegacyRoot: LibraryLocationStore.activeLibraryRootURL
        ) else { return }

        if fileManager.fileExists(atPath: destination.path) {
            defaults.set(libraryID.uuidString, forKey: legacyMigrationOwnerKey)
            return
        }

        let legacy = legacyStoreURL
        guard fileManager.fileExists(atPath: legacy.path) else {
            defaults.set(libraryID.uuidString, forKey: legacyMigrationOwnerKey)
            return
        }

        var didFail = false
        for suffix in ["", "-wal", "-shm"] {
            let sourceURL = URL(fileURLWithPath: legacy.path + suffix)
            let destinationURL = URL(fileURLWithPath: destination.path + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                didFail = true
                let component = suffix.isEmpty ? "sqlite" : suffix
                Log.warning(
                    "[PlaybackHistory] legacy store migration failed for \(component): \(error)",
                    category: .library
                )
            }
        }

        guard !didFail else {
            for suffix in ["", "-wal", "-shm"] {
                try? fileManager.removeItem(at: URL(fileURLWithPath: destination.path + suffix))
            }
            return
        }
        defaults.set(libraryID.uuidString, forKey: legacyMigrationOwnerKey)
    }

    private static func stableLegacyLibraryID(for rootURL: URL) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in rootURL.standardizedFileURL.path.utf8.enumerated() {
            let slot = index % bytes.count
            bytes[slot] = bytes[slot] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
