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

    @discardableResult
    func pickAndImport(to playlist: Playlist) async -> Int {
        print("📁 StubFileImportService: pickAndImport to \"\(playlist.name)\" (no-op)")
        return 0
    }
}
