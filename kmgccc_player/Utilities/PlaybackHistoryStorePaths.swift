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
    private static let legacyMigrationKey = "playbackHistory.libraryStoreMigration.v1"

    /// Playback history is user-owned library data, not a regenerable cache.
    /// Keeping it beside the library makes a custom library self-contained and
    /// lets switching libraries switch the history timeline with it.
    static var directoryURL: URL {
        LocalLibraryPaths.libraryRootURL
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static var storeURL: URL {
        LocalLibraryPaths.libraryRootURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(storeFileName)
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

    static func prepareStoreURL(at libraryRootURL: URL = LocalLibraryPaths.libraryRootURL) -> URL {
        let directory = libraryRootURL.appendingPathComponent(directoryName, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(storeFileName)
        migrateLegacyStoreIfNeeded(to: destination, fileManager: fileManager)
        return destination
    }

    private static func migrateLegacyStoreIfNeeded(to destination: URL, fileManager: FileManager) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyMigrationKey) else { return }

        if fileManager.fileExists(atPath: destination.path) {
            defaults.set(true, forKey: legacyMigrationKey)
            return
        }

        let legacy = legacyStoreURL
        guard fileManager.fileExists(atPath: legacy.path) else {
            defaults.set(true, forKey: legacyMigrationKey)
            return
        }

        // SQLite may have live WAL/SHM companions. Copy them as a group so a
        // first launch after the feature upgrade does not lose committed events.
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
        defaults.set(true, forKey: legacyMigrationKey)
    }
}
