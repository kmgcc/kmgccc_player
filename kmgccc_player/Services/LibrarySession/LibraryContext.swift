//
//  LibraryContext.swift
//  kmgccc_player
//
//  Immutable identity captured by every library-scoped operation.
//

import Foundation

nonisolated struct LibraryContext: Sendable, Equatable {
    let id: UUID
    let mode: MusicLibraryMode
    let rootURL: URL
    let rootBookmarkData: Data
    let generation: UInt64
    let paths: LibraryPaths

    init(
        id: UUID,
        mode: MusicLibraryMode,
        rootURL: URL,
        rootBookmarkData: Data,
        generation: UInt64
    ) {
        let paths = LibraryPaths(rootURL: rootURL)
        self.id = id
        self.mode = mode
        self.rootURL = paths.rootURL
        self.rootBookmarkData = rootBookmarkData
        self.generation = generation
        self.paths = paths
    }

    init(
        manifest: MusicLibraryManifest,
        rootURL: URL,
        rootBookmarkData: Data,
        generation: UInt64
    ) {
        self.init(
            id: manifest.libraryID,
            mode: manifest.mode,
            rootURL: rootURL,
            rootBookmarkData: rootBookmarkData,
            generation: generation
        )
    }

    func isCurrent(generation candidate: UInt64) -> Bool {
        generation == candidate
    }
}
