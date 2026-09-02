//
//  LibraryLocationStore.swift
//  myPlayer2
//
//  kmgccc_player - Configurable library root location.
//

import Foundation

/// One-time access to the pre-registry music-library location.
/// Production sessions use `MusicLibraryRegistryStore` and `LibraryContext`.
nonisolated enum LibraryLocationStore {
    private static let defaultsKey = "kmgccc_player.libraryRootPath"
    private static let defaultLibraryRootName = "kmgccc_player Library"

    /// The factory default library root URL (`~/Music/kmgccc_player Library`).
    static var defaultLibraryRootURL: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        return (base ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent(defaultLibraryRootName, isDirectory: true)
    }

    static func legacyLibraryRootURL(defaults: UserDefaults = .standard) -> URL {
        if let savedPath = defaults.string(forKey: defaultsKey) {
            return URL(fileURLWithPath: savedPath)
        }
        return defaultLibraryRootURL
    }

    static func hasLegacyLibraryRoot(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) != nil
    }

    static func removeLegacyLibraryRoot(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
