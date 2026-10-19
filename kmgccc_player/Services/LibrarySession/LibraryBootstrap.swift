//
//  LibraryBootstrap.swift
//  kmgccc_player
//
//  Synchronous pre-container restore of the active registered library.
//

import Foundation

nonisolated struct LibraryBootstrapResult: Sendable, Equatable {
    let context: LibraryContext?

    static let noLibrary = LibraryBootstrapResult(context: nil)
}

nonisolated enum LibraryBootstrapError: Error, Equatable {
    case manifestIdentityMismatch
}

/// Restores the active library from the registry before the main window
/// exists. With no registry or no active library it returns `.noLibrary`;
/// `AppSessionHost` then adopts or creates the factory-default library.
nonisolated struct LibraryBootstrap: Sendable {
    typealias BookmarkDataProvider = @Sendable (URL) throws -> Data
    typealias BookmarkURLResolver = @Sendable (Data) throws -> (url: URL, isStale: Bool)

    let registryURL: URL
    let bookmarkDataProvider: BookmarkDataProvider
    let bookmarkURLResolver: BookmarkURLResolver

    init(
        registryURL: URL = MusicLibraryRegistryFile.defaultURL(),
        bookmarkDataProvider: @escaping BookmarkDataProvider = { url in
            try SystemBookmarkResolver().refreshBookmark(for: url)
        },
        bookmarkURLResolver: @escaping BookmarkURLResolver = { data in
            try SystemBookmarkResolver().resolve(data)
        }
    ) {
        self.registryURL = registryURL
        self.bookmarkDataProvider = bookmarkDataProvider
        self.bookmarkURLResolver = bookmarkURLResolver
    }

    func run(generation: UInt64 = 1) throws -> LibraryBootstrapResult {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return .noLibrary
        }
        var registry = try MusicLibraryRegistryFile.load(from: registryURL)
        guard let activeID = registry.activeLibraryID,
              let descriptorIndex = registry.libraries.firstIndex(where: { $0.id == activeID }) else {
            return .noLibrary
        }

        let restored = try restoreRegisteredLibrary(
            registry.libraries[descriptorIndex],
            generation: generation
        )
        if let refreshedDescriptor = restored.refreshedDescriptor {
            registry.libraries[descriptorIndex] = refreshedDescriptor
            try MusicLibraryRegistryFile.save(registry, to: registryURL)
        }
        return LibraryBootstrapResult(context: restored.context)
    }

    private func restoreRegisteredLibrary(
        _ descriptor: MusicLibraryBookmark,
        generation: UInt64
    ) throws -> (context: LibraryContext, refreshedDescriptor: MusicLibraryBookmark?) {
        let resolution = try bookmarkURLResolver(descriptor.rootBookmarkData)
        let bookmarkedURL = resolution.url
        let bookmarkRootExists = FileManager.default.fileExists(atPath: bookmarkedURL.path)
        let rootURL = bookmarkRootExists
            ? bookmarkedURL
            : URL(fileURLWithPath: descriptor.lastKnownPath, isDirectory: true)
        let manifest = try MusicLibraryManifest.read(
            from: LibraryPaths(rootURL: rootURL).manifestURL
        )
        guard manifest.libraryID == descriptor.id,
              manifest.mode == descriptor.modeProjection else {
            throw LibraryBootstrapError.manifestIdentityMismatch
        }

        let refreshedDescriptor: MusicLibraryBookmark?
        let contextBookmarkData: Data
        if resolution.isStale || !bookmarkRootExists {
            let refreshedData = try bookmarkDataProvider(rootURL)
            contextBookmarkData = refreshedData
            refreshedDescriptor = MusicLibraryBookmark(
                id: descriptor.id,
                displayName: manifest.displayName,
                rootBookmarkData: refreshedData,
                lastKnownPath: rootURL.standardizedFileURL.path,
                modeProjection: manifest.mode
            )
        } else {
            contextBookmarkData = descriptor.rootBookmarkData
            refreshedDescriptor = nil
        }

        return (
            LibraryContext(
                manifest: manifest,
                rootURL: rootURL,
                rootBookmarkData: contextBookmarkData,
                generation: generation
            ),
            refreshedDescriptor
        )
    }
}
