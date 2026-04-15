//
//  FileImportServiceProtocol.swift
//  myPlayer2
//
//  kmgccc_player - File Import Service Protocol
//
//  Supports importing directly into the library, with an optional playlist target.
//

import Foundation

/// Protocol for importing audio files into the library, optionally adding them to a playlist.
@MainActor
protocol FileImportServiceProtocol: AnyObject {

    /// Present the system-native file picker and return selected files/folders.
    func pickImportURLs(triggeredAt: Date) async -> [URL]?

    /// Import previously selected files/folders into the library and optionally a playlist.
    @discardableResult
    func importSelectedURLs(_ urls: [URL], to playlist: Playlist?) async -> Int
}
