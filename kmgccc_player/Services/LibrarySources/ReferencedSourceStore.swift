//
//  ReferencedSourceStore.swift
//  kmgccc_player
//

import Foundation

actor ReferencedSourceStore {
    nonisolated let paths: LibraryPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(paths: LibraryPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadAll() throws -> [ReferencedSourceDescriptor] {
        guard fileManager.fileExists(atPath: paths.sourcesRootURL.path) else { return [] }
        let children = try fileManager.contentsOfDirectory(
            at: paths.sourcesRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try children.compactMap { child in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let id = UUID(uuidString: child.lastPathComponent) else { return nil }
            let descriptorURL = paths.sourceDescriptorURL(for: id)
            guard fileManager.fileExists(atPath: descriptorURL.path) else {
                throw ReferencedSourceStoreError.incompleteSource(id)
            }
            return try load(id: id)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func contains(id: UUID) -> Bool {
        fileManager.fileExists(atPath: paths.sourceDescriptorURL(for: id).path)
    }

    func load(id: UUID) throws -> ReferencedSourceDescriptor {
        let data = try Data(contentsOf: paths.sourceDescriptorURL(for: id))
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let schema = object["schemaVersion"] as? Int else {
                throw ReferencedSourceStoreError.missingSchema
            }
            guard schema == 1 || schema == 2 || schema == ReferencedSourceDescriptor.currentSchemaVersion else {
                throw ReferencedSourceStoreError.unsupportedSchema(schema)
            }
            guard let mode = object["mode"] as? String else {
                throw ReferencedSourceStoreError.missingMode
            }
            guard ReferencedSourceMode(rawValue: mode) != nil else {
                throw ReferencedSourceStoreError.unsupportedMode(mode)
            }
        }
        let descriptor = try decoder.decode(ReferencedSourceDescriptor.self, from: data)
        let validated = try validate(descriptor, expectedID: id)
        if schemaVersion(in: data) < ReferencedSourceDescriptor.currentSchemaVersion {
            // Upgrade one descriptor at a time. The caller can continue even
            // if another source is unavailable; each write is atomic.
            try save(validated)
        }
        return validated
    }

    func save(_ descriptor: ReferencedSourceDescriptor) throws {
        let validated = try validate(descriptor, expectedID: descriptor.id)
        let directory = paths.sourceRootURL(for: descriptor.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(validated).write(to: paths.sourceDescriptorURL(for: descriptor.id), options: .atomic)
    }

    func updateResolvedBookmark(
        sourceID: UUID,
        bookmarkData: Data,
        lastKnownPath: String,
        status: ReferencedSourceStatus = .available
    ) throws -> ReferencedSourceDescriptor {
        var descriptor = try load(id: sourceID)
        descriptor.rootBookmarkData = bookmarkData
        descriptor.lastKnownPath = lastKnownPath
        descriptor.status = status
        try save(descriptor)
        return descriptor
    }

    func updateStatus(sourceID: UUID, status: ReferencedSourceStatus) throws -> ReferencedSourceDescriptor {
        var descriptor = try load(id: sourceID)
        descriptor.status = status
        try save(descriptor)
        return descriptor
    }

    func ensurePlaylistBinding(
        sourceID: UUID,
        playlistID: UUID,
        relativePath: String? = nil
    ) throws -> ReferencedPlaylistSourceBinding {
        var descriptor = try load(id: sourceID)
        if let existing = descriptor.playlistBindings.first(where: {
            $0.playlistID == playlistID && $0.relativePath == relativePath
        }) {
            return existing
        }
        let binding = ReferencedPlaylistSourceBinding(
            playlistID: playlistID,
            relativePath: relativePath
        )
        descriptor.playlistBindings.append(binding)
        try save(descriptor)
        return binding
    }

    func updatePlaylistBinding(_ binding: ReferencedPlaylistSourceBinding, sourceID: UUID) throws {
        var descriptor = try load(id: sourceID)
        guard let index = descriptor.playlistBindings.firstIndex(where: { $0.id == binding.id }) else {
            return
        }
        descriptor.playlistBindings[index] = binding
        try save(descriptor)
    }

    func updateExcludedRelativePaths(
        sourceID: UUID,
        paths: [String]
    ) throws -> ReferencedSourceDescriptor {
        var descriptor = try load(id: sourceID)
        guard descriptor.mode == .directory else {
            guard paths.isEmpty else { throw ReferencedSourceStoreError.invalidExcludedPath }
            descriptor.excludedRelativePaths = []
            try save(descriptor)
            return descriptor
        }

        let trimmedPaths = paths.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard trimmedPaths.allSatisfy({
            !$0.isEmpty && TrackMediaLocator.isSafeRelativePath($0)
        }) else {
            throw ReferencedSourceStoreError.invalidExcludedPath
        }
        let normalized = ReferencedSourceDescriptor.normalizedExcludedRelativePaths(trimmedPaths)
        descriptor.excludedRelativePaths = normalized
        try save(descriptor)
        return descriptor
    }

    func setExcludedRelativePath(
        sourceID: UUID,
        relativePath: String,
        excluded: Bool
    ) throws -> ReferencedSourceDescriptor {
        let normalizedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty,
              TrackMediaLocator.isSafeRelativePath(normalizedPath) else {
            throw ReferencedSourceStoreError.invalidExcludedPath
        }

        var descriptor = try load(id: sourceID)
        guard descriptor.mode == .directory else {
            throw ReferencedSourceStoreError.invalidExcludedPath
        }

        if excluded {
            descriptor.excludedRelativePaths.append(normalizedPath)
        } else {
            descriptor.excludedRelativePaths.removeAll { existing in
                existing == normalizedPath
                    || existing.hasPrefix(normalizedPath + "/")
            }
        }
        descriptor.excludedRelativePaths = ReferencedSourceDescriptor.normalizedExcludedRelativePaths(
            descriptor.excludedRelativePaths
        )
        try save(descriptor)
        return descriptor
    }

    func removePlaylistBinding(sourceID: UUID, bindingID: UUID) throws {
        var descriptor = try load(id: sourceID)
        descriptor.playlistBindings.removeAll { $0.id == bindingID }
        try save(descriptor)
    }

    func bindings(for sourceID: UUID) throws -> [ReferencedPlaylistSourceBinding] {
        try load(id: sourceID).playlistBindings
    }

    func allBindings() throws -> [(sourceID: UUID, binding: ReferencedPlaylistSourceBinding)] {
        try loadAll().flatMap { descriptor in
            descriptor.playlistBindings.map { (descriptor.id, $0) }
        }
    }

    /// Removes bindings for a deleted playlist but leaves source descriptors
    /// and external files untouched. This is deliberately explicit so a later
    /// scan can never recreate a deleted playlist from stale source metadata.
    func removeBindings(for playlistID: UUID) throws {
        for var descriptor in try loadAll() {
            let before = descriptor.playlistBindings.count
            descriptor.playlistBindings.removeAll { $0.playlistID == playlistID }
            guard descriptor.playlistBindings.count != before else { continue }
            try save(descriptor)
        }
    }

    func reconnectDescriptor(
        sourceID: UUID,
        rootBookmarkData: Data,
        rootURL: URL
    ) throws -> ReferencedSourceDescriptor {
        var descriptor = try load(id: sourceID)
        descriptor.rootBookmarkData = rootBookmarkData
        descriptor.lastKnownPath = rootURL.standardizedFileURL.path
        descriptor.displayName = rootURL.lastPathComponent
        descriptor.lastScan = Date()
        descriptor.status = .available
        return try validate(descriptor, expectedID: sourceID)
    }

    func remove(id: UUID) throws {
        let directory = paths.sourceRootURL(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func validate(
        _ descriptor: ReferencedSourceDescriptor,
        expectedID: UUID
    ) throws -> ReferencedSourceDescriptor {
        guard descriptor.schemaVersion == ReferencedSourceDescriptor.currentSchemaVersion else {
            throw ReferencedSourceStoreError.unsupportedSchema(descriptor.schemaVersion)
        }
        guard descriptor.id == expectedID else {
            throw ReferencedSourceStoreError.identifierMismatch(expected: expectedID, actual: descriptor.id)
        }
        guard !descriptor.rootBookmarkData.isEmpty else { throw ReferencedSourceStoreError.emptyBookmark }
        guard !descriptor.lastKnownPath.isEmpty else { throw ReferencedSourceStoreError.invalidPath }
        guard !descriptor.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReferencedSourceStoreError.invalidDisplayName
        }
        guard descriptor.excludedRelativePaths.allSatisfy({
            !$0.isEmpty && TrackMediaLocator.isSafeRelativePath($0)
        }) else {
            throw ReferencedSourceStoreError.invalidExcludedPath
        }
        return descriptor
    }

    private func schemaVersion(in data: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schemaVersion"] as? Int else {
            return ReferencedSourceDescriptor.currentSchemaVersion
        }
        return schema
    }
}
