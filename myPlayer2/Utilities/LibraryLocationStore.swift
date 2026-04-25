//
//  LibraryLocationStore.swift
//  myPlayer2
//
//  kmgccc_player - Configurable library root location.
//

import Foundation

/// Lightweight store for the active music library root path.
/// Uses UserDefaults for persistence. Falls back to the legacy default.
nonisolated enum LibraryLocationStore {
    private static let defaultsKey = "kmgccc_player.libraryRootPath"
    private static let defaultLibraryRootName = "kmgccc_player Library"

    /// The factory default library root URL (`~/Music/kmgccc_player Library`).
    static var defaultLibraryRootURL: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        return (base ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent(defaultLibraryRootName, isDirectory: true)
    }

    /// The currently configured library root URL.
    /// If the user has never changed it, returns `~/Music/kmgccc_player Library`.
    static var activeLibraryRootURL: URL {
        if let savedPath = UserDefaults.standard.string(forKey: defaultsKey) {
            return URL(fileURLWithPath: savedPath)
        }
        return defaultLibraryRootURL
    }

    /// Persist a new library root URL and notify observers.
    static func setLibraryRootURL(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
        NotificationCenter.default.post(name: .libraryLocationChanged, object: nil)
    }

    /// Reset to the factory default and notify observers.
    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: .libraryLocationChanged, object: nil)
    }
}

extension Notification.Name {
    nonisolated static let libraryLocationChanged = Notification.Name("kmgccc_player.libraryLocationChanged")
}
