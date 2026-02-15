//
//  TrackIndexStorePaths.swift
//  myPlayer2
//
//  Persistent store location for SwiftData index cache.
//

import Foundation

enum TrackIndexStorePaths {
    static var storeURL: URL {
        let appSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "kmgccc.player"
        let dir = appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("IndexCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("TrackIndex.sqlite")
    }

    static var relatedStoreFiles: [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]
    }
}
