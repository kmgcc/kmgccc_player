//
//  LegacyLibraryBootstrap.swift
//  kmgccc_player
//
//  Synchronous pre-container registration of the single legacy library.
//

import Foundation

nonisolated struct LegacyLibraryBootstrapResult: Sendable, Equatable {
    let context: LibraryContext?
    let didCreateManifest: Bool
    let didRegisterLibrary: Bool

    static let noLibrary = LegacyLibraryBootstrapResult(
        context: nil,
        didCreateManifest: false,
        didRegisterLibrary: false
    )
}

nonisolated struct LegacyLibraryBootstrap: Sendable {
    typealias BookmarkDataProvider = @Sendable (URL) throws -> Data

    let registryURL: URL
    let bookmarkDataProvider: BookmarkDataProvider

    init(
        registryURL: URL = MusicLibraryRegistryFile.defaultURL(),
        bookmarkDataProvider: @escaping BookmarkDataProvider = { url in
            try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    ) {
        self.registryURL = registryURL
        self.bookmarkDataProvider = bookmarkDataProvider
    }

    func run(
        legacyRootURL: URL = LibraryLocationStore.activeLibraryRootURL,
        displayName: String? = nil,
        generation: UInt64 = 1,
        now: Date = Date()
    ) throws -> LegacyLibraryBootstrapResult {
        let paths = LibraryPaths(rootURL: legacyRootURL)
        let fileManager = FileManager.default
        let manifestExists = fileManager.fileExists(atPath: paths.manifestURL.path)

        guard manifestExists || Self.containsLegacyLibrary(at: paths.rootURL, fileManager: fileManager) else {
            return .noLibrary
        }

        var journal = try LibraryUpgradeJournal.read(from: paths.upgradeJournalURL)
        if let journal, journal.rootPath != paths.rootURL.path {
            throw LibraryUpgradeJournalError.rootMismatch
        }

        let manifest: MusicLibraryManifest
        let didCreateManifest: Bool
        if manifestExists {
            manifest = try MusicLibraryManifest.read(from: paths.manifestURL)
            if let journal, journal.libraryID != manifest.libraryID {
                throw LibraryUpgradeJournalError.manifestIdentityMismatch
            }
            didCreateManifest = false
        } else {
            let libraryID = journal?.libraryID ?? UUID()
            if journal == nil {
                journal = LibraryUpgradeJournal(
                    libraryID: libraryID,
                    rootURL: paths.rootURL,
                    stage: .discovered,
                    startedAt: now,
                    updatedAt: now
                )
                try journal?.write(to: paths.upgradeJournalURL)
            }

            let parentName = paths.rootURL.deletingLastPathComponent().lastPathComponent
            let resolvedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            manifest = MusicLibraryManifest(
                libraryID: libraryID,
                displayName: resolvedDisplayName?.isEmpty == false
                    ? resolvedDisplayName!
                    : (parentName.isEmpty ? paths.rootURL.lastPathComponent : parentName),
                mode: .managed,
                createdAt: now,
                updatedAt: now
            )
            try manifest.write(to: paths.manifestURL)
            journal = journal?.advancing(to: .manifestWritten, now: now)
            try journal?.write(to: paths.upgradeJournalURL)
            didCreateManifest = true
        }

        let bookmarkData = try bookmarkDataProvider(paths.rootURL)
        let descriptor = try MusicLibraryBookmark.make(
            manifest: manifest,
            rootURL: paths.rootURL,
            bookmarkData: bookmarkData
        )

        var registry = try MusicLibraryRegistryFile.load(from: registryURL)
        let wasRegistered = registry.library(id: descriptor.id) != nil
        if let conflicting = registry.libraries.first(where: {
            URL(fileURLWithPath: $0.lastKnownPath).standardizedFileURL == paths.rootURL
                && $0.id != descriptor.id
        }) {
            _ = conflicting
            throw MusicLibraryRegistryError.libraryPathBelongsToAnotherID
        }
        if let index = registry.libraries.firstIndex(where: { $0.id == descriptor.id }) {
            registry.libraries[index] = descriptor
        } else {
            registry.libraries.append(descriptor)
        }

        if registry.activeLibraryID == nil || didCreateManifest {
            registry.activeLibraryID = descriptor.id
        }
        switch manifest.mode {
        case .managed:
            if registry.recentManagedLibraryID == nil || didCreateManifest {
                registry.recentManagedLibraryID = descriptor.id
            }
        case .referenced:
            if registry.recentReferencedLibraryID == nil {
                registry.recentReferencedLibraryID = descriptor.id
            }
        }
        try MusicLibraryRegistryFile.save(registry, to: registryURL)

        if journal == nil {
            journal = LibraryUpgradeJournal(
                libraryID: manifest.libraryID,
                rootURL: paths.rootURL,
                stage: .registryWritten,
                startedAt: now,
                updatedAt: now
            )
        } else {
            journal = journal?.advancing(to: .registryWritten, now: now)
        }
        try journal?.write(to: paths.upgradeJournalURL)
        journal = journal?.advancing(to: .committed, now: now)
        try journal?.write(to: paths.upgradeJournalURL)

        return LegacyLibraryBootstrapResult(
            context: LibraryContext(
                manifest: manifest,
                rootURL: paths.rootURL,
                rootBookmarkData: bookmarkData,
                generation: generation
            ),
            didCreateManifest: didCreateManifest,
            didRegisterLibrary: !wasRegistered
        )
    }

    static func containsLegacyLibrary(
        at rootURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        return ["Tracks", "Playlists", "Artists", "Albums"].contains { name in
            var childIsDirectory: ObjCBool = false
            return fileManager.fileExists(
                atPath: rootURL.appendingPathComponent(name, isDirectory: true).path,
                isDirectory: &childIsDirectory
            ) && childIsDirectory.boolValue
        }
    }
}
