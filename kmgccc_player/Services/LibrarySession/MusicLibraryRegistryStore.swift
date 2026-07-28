//
//  MusicLibraryRegistryStore.swift
//  kmgccc_player
//
//  The only process-global index of known music libraries.
//

import Foundation

nonisolated struct MusicLibraryBookmark: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var displayName: String
    var rootBookmarkData: Data
    var lastKnownPath: String
    var modeProjection: MusicLibraryMode
}

nonisolated struct MusicLibraryRegistry: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var libraries: [MusicLibraryBookmark]
    var activeLibraryID: UUID?
    var recentManagedLibraryID: UUID?
    var recentReferencedLibraryID: UUID?

    init(
        schemaVersion: Int = MusicLibraryRegistry.schemaVersion,
        libraries: [MusicLibraryBookmark] = [],
        activeLibraryID: UUID? = nil,
        recentManagedLibraryID: UUID? = nil,
        recentReferencedLibraryID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.libraries = libraries
        self.activeLibraryID = activeLibraryID
        self.recentManagedLibraryID = recentManagedLibraryID
        self.recentReferencedLibraryID = recentReferencedLibraryID
    }

    func validated() throws -> MusicLibraryRegistry {
        guard schemaVersion == Self.schemaVersion else {
            throw MusicLibraryRegistryError.unsupportedSchema(schemaVersion)
        }

        let ids = libraries.map(\.id)
        guard Set(ids).count == ids.count else {
            throw MusicLibraryRegistryError.duplicateLibraryID
        }

        let normalizedPaths = libraries.map {
            URL(fileURLWithPath: $0.lastKnownPath).standardizedFileURL.path
        }
        guard Set(normalizedPaths).count == normalizedPaths.count else {
            throw MusicLibraryRegistryError.duplicateLibraryPath
        }

        let knownIDs = Set(ids)
        for pointer in [activeLibraryID, recentManagedLibraryID, recentReferencedLibraryID].compactMap({ $0 }) {
            guard knownIDs.contains(pointer) else {
                throw MusicLibraryRegistryError.danglingLibraryReference(pointer)
            }
        }
        return self
    }

    func library(id: UUID) -> MusicLibraryBookmark? {
        libraries.first { $0.id == id }
    }

    func recentLibraryID(for mode: MusicLibraryMode) -> UUID? {
        switch mode {
        case .managed:
            return recentManagedLibraryID
        case .referenced:
            return recentReferencedLibraryID
        }
    }
}

nonisolated enum MusicLibraryRegistryError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case duplicateLibraryID
    case duplicateLibraryPath
    case danglingLibraryReference(UUID)
    case libraryNotFound(UUID)
    case libraryPathBelongsToAnotherID
    case corruptedRegistry(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported library registry schema: \(version)"
        case .duplicateLibraryID:
            return "The library registry contains a duplicate identifier."
        case .duplicateLibraryPath:
            return "The library registry contains a duplicate path."
        case .danglingLibraryReference(let id):
            return "The library registry contains an invalid reference: \(id.uuidString)"
        case .libraryNotFound(let id):
            return "The library is not registered: \(id.uuidString)"
        case .libraryPathBelongsToAnotherID:
            return "The selected path belongs to another registered library."
        case .corruptedRegistry:
            return "The library registry cannot be decoded."
        }
    }
}

nonisolated enum MusicLibraryRegistryFile {
    static func defaultURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "kmgccc.player"
    ) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("LibraryRegistry.json")
    }

    static func load(from url: URL) throws -> MusicLibraryRegistry {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MusicLibraryRegistry()
        }

        do {
            let decoder = JSONDecoder()
            let registry = try decoder.decode(MusicLibraryRegistry.self, from: Data(contentsOf: url))
            return try registry.validated()
        } catch let error as MusicLibraryRegistryError {
            throw error
        } catch {
            throw MusicLibraryRegistryError.corruptedRegistry(String(describing: error))
        }
    }

    static func save(_ registry: MusicLibraryRegistry, to url: URL) throws {
        _ = try registry.validated()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: url, options: .atomic)
    }
}

actor MusicLibraryRegistryStore {
    nonisolated static var defaultRegistryURL: URL {
        MusicLibraryRegistryFile.defaultURL()
    }

    let fileURL: URL
    private var registry: MusicLibraryRegistry

    init(fileURL: URL = MusicLibraryRegistryStore.defaultRegistryURL) throws {
        self.fileURL = fileURL
        self.registry = try MusicLibraryRegistryFile.load(from: fileURL)
    }

    func snapshot() -> MusicLibraryRegistry {
        registry
    }

    func reload() throws -> MusicLibraryRegistry {
        let loaded = try MusicLibraryRegistryFile.load(from: fileURL)
        registry = loaded
        return loaded
    }

    func register(_ descriptor: MusicLibraryBookmark) throws {
        var updated = registry
        if let existingPath = updated.libraries.first(where: {
            URL(fileURLWithPath: $0.lastKnownPath).standardizedFileURL
                == URL(fileURLWithPath: descriptor.lastKnownPath).standardizedFileURL
        }), existingPath.id != descriptor.id {
            throw MusicLibraryRegistryError.libraryPathBelongsToAnotherID
        }

        if let index = updated.libraries.firstIndex(where: { $0.id == descriptor.id }) {
            updated.libraries[index] = descriptor
        } else {
            updated.libraries.append(descriptor)
        }
        try commit(updated)
    }

    func updateDisplayName(libraryID: UUID, displayName: String) throws {
        var updated = registry
        guard let index = updated.libraries.firstIndex(where: { $0.id == libraryID }) else {
            throw MusicLibraryRegistryError.libraryNotFound(libraryID)
        }
        updated.libraries[index].displayName = displayName
        try commit(updated)
    }

    func updateBookmark(
        libraryID: UUID,
        bookmarkData: Data,
        lastKnownPath: String,
        modeProjection: MusicLibraryMode
    ) throws {
        var updated = registry
        guard let index = updated.libraries.firstIndex(where: { $0.id == libraryID }) else {
            throw MusicLibraryRegistryError.libraryNotFound(libraryID)
        }
        updated.libraries[index].rootBookmarkData = bookmarkData
        updated.libraries[index].lastKnownPath = lastKnownPath
        updated.libraries[index].modeProjection = modeProjection
        try commit(updated)
    }

    func setActiveLibrary(id: UUID, manifestMode: MusicLibraryMode) throws {
        var updated = registry
        guard updated.library(id: id) != nil else {
            throw MusicLibraryRegistryError.libraryNotFound(id)
        }
        updated.activeLibraryID = id
        switch manifestMode {
        case .managed:
            updated.recentManagedLibraryID = id
        case .referenced:
            updated.recentReferencedLibraryID = id
        }
        try commit(updated)
    }

    func remove(libraryID: UUID) throws {
        var updated = registry
        guard updated.libraries.contains(where: { $0.id == libraryID }) else {
            throw MusicLibraryRegistryError.libraryNotFound(libraryID)
        }
        updated.libraries.removeAll { $0.id == libraryID }

        if updated.activeLibraryID == libraryID {
            updated.activeLibraryID = nil
        }
        if updated.recentManagedLibraryID == libraryID {
            updated.recentManagedLibraryID = updated.libraries.last(where: {
                $0.modeProjection == .managed
            })?.id
        }
        if updated.recentReferencedLibraryID == libraryID {
            updated.recentReferencedLibraryID = updated.libraries.last(where: {
                $0.modeProjection == .referenced
            })?.id
        }
        try commit(updated)
    }

    private func commit(_ updated: MusicLibraryRegistry) throws {
        try MusicLibraryRegistryFile.save(updated, to: fileURL)
        registry = updated
    }
}

nonisolated extension MusicLibraryBookmark {
    static func make(
        manifest: MusicLibraryManifest,
        rootURL: URL,
        bookmarkData: Data? = nil
    ) throws -> MusicLibraryBookmark {
        let data = try bookmarkData ?? rootURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return MusicLibraryBookmark(
            id: manifest.libraryID,
            displayName: manifest.displayName,
            rootBookmarkData: data,
            lastKnownPath: rootURL.standardizedFileURL.path,
            modeProjection: manifest.mode
        )
    }
}
