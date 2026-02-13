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

    /// Present file picker and import selected files/folders into a playlist.
    /// - Parameter playlist: The target playlist.
    /// - Returns: Number of tracks successfully imported.
    @discardableResult
    func pickAndImport(to playlist: Playlist) async -> Int
}
