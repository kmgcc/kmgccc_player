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
        print("📁 StubFileImportService: pickImportURLs at \(triggeredAt) (no-op)")
        return nil
    }

    @discardableResult
    func importSelectedURLs(_ urls: [URL], to playlist: Playlist) async -> Int {
        print(
            "📁 StubFileImportService: importSelectedURLs(\(urls.count)) to \"\(playlist.name)\" (no-op)"
        )
        return 0
    }

    func cancelEnrichment(for trackIDs: Set<UUID>) async {
        print("📁 StubFileImportService: cancelEnrichment(\(trackIDs.count)) (no-op)")
    }
}
