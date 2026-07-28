//
//  SearchIndexStorePaths.swift
//  myPlayer2
//
//  Persistent store location for library search index.
//

import Foundation

nonisolated enum SearchIndexStorePaths {
    static func storeURL(in paths: LibraryPaths) -> URL {
        paths.searchIndexStoreURL
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

    // Compatibility only; remove after search/session migration.
    static var storeURL: URL {
        let paths = LibraryPaths(rootURL: LibraryLocationStore.activeLibraryRootURL)
        try? FileManager.default.createDirectory(at: paths.indexRootURL, withIntermediateDirectories: true)
        return storeURL(in: paths)
    }

    // Compatibility only; remove after search/session migration.
    static var relatedStoreFiles: [URL] {
        relatedStoreFiles(in: LibraryPaths(rootURL: LibraryLocationStore.activeLibraryRootURL))
    }
}
