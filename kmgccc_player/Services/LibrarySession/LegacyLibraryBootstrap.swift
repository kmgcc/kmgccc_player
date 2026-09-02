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
    let requiresPostRegistrationMigration: Bool

    static let noLibrary = LegacyLibraryBootstrapResult(
        context: nil,
        didCreateManifest: false,
        didRegisterLibrary: false,
        requiresPostRegistrationMigration: false
    )
}

nonisolated struct LegacyLibraryBootstrap: Sendable {
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

    func run(
        legacyRootURL: URL = LibraryLocationStore.legacyLibraryRootURL(),
        displayName: String? = nil,
        generation: UInt64 = 1,
        now: Date = Date()
    ) throws -> LegacyLibraryBootstrapResult {
        // Once a registry exists it is the startup authority. Legacy discovery is
        // retained only as a recovery fallback for an independently valid old root.
        if FileManager.default.fileExists(atPath: registryURL.path) {
            var registry = try MusicLibraryRegistryFile.load(from: registryURL)
            if let activeID = registry.activeLibraryID,
               let descriptorIndex = registry.libraries.firstIndex(where: { $0.id == activeID }) {
                do {
                    let restored = try restoreRegisteredLibrary(
                        registry.libraries[descriptorIndex],
                        generation: generation
                    )
                    if let refreshedDescriptor = restored.refreshedDescriptor {
                        registry.libraries[descriptorIndex] = refreshedDescriptor
                        try MusicLibraryRegistryFile.save(registry, to: registryURL)
                    }
                    return restored.result
                } catch {
                    let fallbackPaths = LibraryPaths(rootURL: legacyRootURL)
                    guard Self.containsLegacyLibrary(at: fallbackPaths.rootURL),
                          FileManager.default.fileExists(atPath: fallbackPaths.manifestURL.path) else {
                        throw error
                    }
                    // The verified legacy root remains a recoverable fallback.
                }
            }
            // No active library is registered (for example after settings were
            // cleared): fall through to legacy discovery so the factory-default
            // root (`~/Music/kmgccc_player Library`) is adopted when it still
            // holds a valid library on disk.
        }

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

        return LegacyLibraryBootstrapResult(
            context: LibraryContext(
                manifest: manifest,
                rootURL: paths.rootURL,
                rootBookmarkData: bookmarkData,
                generation: generation
            ),
            didCreateManifest: didCreateManifest,
            didRegisterLibrary: !wasRegistered,
            requiresPostRegistrationMigration: journal.map { $0.stage != .committed } ?? false
        )
    }

    private func restoreRegisteredLibrary(
        _ descriptor: MusicLibraryBookmark,
        generation: UInt64
    ) throws -> (result: LegacyLibraryBootstrapResult, refreshedDescriptor: MusicLibraryBookmark?) {
        let resolution = try bookmarkURLResolver(descriptor.rootBookmarkData)
        let bookmarkedURL = resolution.url
        let isStale = resolution.isStale
        let bookmarkRootExists = FileManager.default.fileExists(atPath: bookmarkedURL.path)
        let rootURL = bookmarkRootExists
            ? bookmarkedURL
            : URL(fileURLWithPath: descriptor.lastKnownPath, isDirectory: true)
        let manifest = try MusicLibraryManifest.read(
            from: LibraryPaths(rootURL: rootURL).manifestURL
        )
        guard manifest.libraryID == descriptor.id,
              manifest.mode == descriptor.modeProjection else {
            throw LibraryUpgradeJournalError.manifestIdentityMismatch
        }

        let refreshedDescriptor: MusicLibraryBookmark?
        let contextBookmarkData: Data
        if isStale || !bookmarkRootExists {
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

        let paths = LibraryPaths(rootURL: rootURL)
        let requiresPostRegistrationMigration: Bool
        do {
            let journal = try LibraryUpgradeJournal.read(from: paths.upgradeJournalURL)
            if let journal,
               (journal.libraryID != manifest.libraryID
                || journal.rootPath != paths.rootURL.standardizedFileURL.path) {
                requiresPostRegistrationMigration = true
            } else {
                requiresPostRegistrationMigration = journal.map { $0.stage != .committed } ?? false
            }
        } catch {
            requiresPostRegistrationMigration = true
        }
        return (
            LegacyLibraryBootstrapResult(
                context: LibraryContext(
                    manifest: manifest,
                    rootURL: rootURL,
                    rootBookmarkData: contextBookmarkData,
                    generation: generation
                ),
                didCreateManifest: false,
                didRegisterLibrary: false,
                requiresPostRegistrationMigration: requiresPostRegistrationMigration
            ),
            refreshedDescriptor
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
