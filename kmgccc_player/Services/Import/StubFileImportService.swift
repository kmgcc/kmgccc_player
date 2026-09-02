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
    func importSelectedURLs(
        _ urls: [URL],
        context: LibraryImportContext
    ) async -> LibraryImportResult {
        print(
            "📁 StubFileImportService: importSelectedURLs(\(urls.count)) destination=\(String(describing: context.destination)) (no-op)"
        )
        return LibraryImportResult(
            importedTrackCount: 0,
            reusedTrackCount: 0,
            playlistMembershipAdditions: 0,
            sourceBindingCount: 0,
            failures: [],
            wasRejectedAsStale: false
        )
    }

    @discardableResult
    func importSelectedURLs(
        _ urls: [URL],
        to playlist: Playlist,
        metadataOverride: ImportMetadataOverride?
    ) async -> Int {
        print(
            "📁 StubFileImportService: importSelectedURLs(\(urls.count)) to \"\(playlist.name)\" override=\(String(describing: metadataOverride)) (no-op)"
        )
        return 0
    }

    func cancelEnrichment(for trackIDs: Set<UUID>) async {
        print("📁 StubFileImportService: cancelEnrichment(\(trackIDs.count)) (no-op)")
    }
}
