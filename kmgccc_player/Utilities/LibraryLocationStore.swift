//
//  LibraryLocationStore.swift
//  myPlayer2
//
//  kmgccc_player - Factory-default library root location.
//

import Foundation

/// Production sessions use `MusicLibraryRegistryStore` and `LibraryContext`;
/// this only names the factory-default root.
nonisolated enum LibraryLocationStore {
    private static let defaultLibraryRootName = "kmgccc_player Library"

    /// The factory default library root URL (`~/Music/kmgccc_player Library`).
    static var defaultLibraryRootURL: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        return (base ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent(defaultLibraryRootName, isDirectory: true)
    }
}
