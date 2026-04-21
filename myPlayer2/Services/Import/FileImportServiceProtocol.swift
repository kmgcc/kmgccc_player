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

/// Protocol for importing audio files into a specific playlist.
@MainActor
protocol FileImportServiceProtocol: AnyObject {

    /// Present the system-native file picker and return selected files/folders.
    func pickImportURLs(triggeredAt: Date) async -> [URL]?

    /// Import previously selected files/folders into a playlist.
    @discardableResult
    func importSelectedURLs(_ urls: [URL], to playlist: Playlist) async -> Int

    /// Cancel background enrichment work and release strong references for deleted tracks.
    func cancelEnrichment(for trackIDs: Set<UUID>) async
}
