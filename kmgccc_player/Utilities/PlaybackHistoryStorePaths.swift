//
//  PlaybackHistoryStorePaths.swift
//  myPlayer2
//
//  Persistent location for the playback history event store.
//

import Foundation

enum PlaybackHistoryStorePaths {
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
}
