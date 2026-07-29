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
            guard schema == ReferencedSourceDescriptor.currentSchemaVersion else {
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
        return try validate(descriptor, expectedID: id)
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
        return descriptor
    }
}
