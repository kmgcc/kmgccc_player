//
//  StubFileImportService.swift
//  myPlayer2
//
//  kmgccc_player - Stub File Import Service
//  Does nothing - for UI previews only.
//

import Foundation

/// Stub implementation for previews.
@MainActor
final class StubFileImportService: FileImportServiceProtocol {
    func pickImportURLs(triggeredAt: Date) async -> [URL]? {
        Log.debug("StubFileImportService.pickImportURLs at \(triggeredAt) (no-op)", category: .import)
        return nil
    }

    @discardableResult
    func importSelectedURLs(_ urls: [URL], to playlist: Playlist?) async -> Int {
        let destination = playlist.map { "\"\($0.name)\"" } ?? "library only"
        Log.debug(
            "StubFileImportService.importSelectedURLs(\(urls.count)) to \(destination) (no-op)",
            category: .import
        )
        return 0
    }
}
