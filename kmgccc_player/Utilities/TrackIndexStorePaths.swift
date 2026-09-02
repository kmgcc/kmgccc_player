//
//  TrackIndexStorePaths.swift
//  myPlayer2
//
//  Persistent store location for SwiftData index cache.
//

import Foundation

nonisolated enum TrackIndexStorePaths {
    static func storeURL(in paths: LibraryPaths) -> URL {
        paths.trackIndexStoreURL
    }

    static func prepareStoreURL(
        in paths: LibraryPaths,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: paths.indexRootURL, withIntermediateDirectories: true)
        return storeURL(in: paths)
    }

    static func relatedStoreFiles(in paths: LibraryPaths) -> [URL] {
        let storeURL = storeURL(in: paths)
        return [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]
    }

}
