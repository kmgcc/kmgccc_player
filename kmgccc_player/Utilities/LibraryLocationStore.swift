//
//  LibraryLocationStore.swift
//  myPlayer2
//
//  kmgccc_player - Legacy factory-default library root location.
//

import Foundation

/// Production sessions use `MusicLibraryRegistryStore` and `LibraryContext`;
/// this locates the legacy factory-default root and the default storage parent.
nonisolated enum LibraryLocationStore {
    private static let defaultLibraryRootName = "kmgccc_player Library"

    /// The legacy factory default root URL (`~/Music/kmgccc_player Library`).
    static var defaultLibraryRootURL: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        return (base ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent(defaultLibraryRootName, isDirectory: true)
    }
}
