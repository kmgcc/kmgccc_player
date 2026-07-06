//
//  FileImportServiceProtocol.swift
//  myPlayer2
//
//  kmgccc_player - File Import Service Protocol
//
//  Design Decision: Import is ALWAYS per-playlist.
//  There is no global import action.
//

import Foundation

/// Optional metadata overrides applied after file metadata is read and before
/// duplicate detection/import. Used by context-aware imports from artist/album pages.
nonisolated struct ImportMetadataOverride: Equatable, Sendable {
    var artist: String?
    var album: String?

    var isEmpty: Bool {
        artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
}

/// Protocol for importing audio files into a specific playlist.
@MainActor
protocol FileImportServiceProtocol: AnyObject {

    /// Present the system-native file picker and return selected files/folders.
    func pickImportURLs(triggeredAt: Date) async -> [URL]?

    /// Import previously selected files/folders into a playlist.
    @discardableResult
    func importSelectedURLs(
        _ urls: [URL],
        to playlist: Playlist,
        metadataOverride: ImportMetadataOverride?
    ) async -> Int

    /// Cancel background enrichment work and release strong references for deleted tracks.
    func cancelEnrichment(for trackIDs: Set<UUID>) async
}

extension FileImportServiceProtocol {
    @discardableResult
    func importSelectedURLs(_ urls: [URL], to playlist: Playlist) async -> Int {
        await importSelectedURLs(urls, to: playlist, metadataOverride: nil)
    }
}
