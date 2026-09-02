import Foundation

nonisolated enum IgnoredReferencedItemReason: String, Codable, Sendable {
    case trackRemoval
    case ncmSourceRemoval
    case ncmOutputRemoval
}

nonisolated struct IgnoredReferencedItem: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let fingerprint: ReferencedFileFingerprint
    let lastKnownPath: String
    let reason: IgnoredReferencedItemReason
    let createdAt: Date

    init(
        id: UUID = UUID(),
        fingerprint: ReferencedFileFingerprint,
        lastKnownPath: String,
        reason: IgnoredReferencedItemReason,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.lastKnownPath = lastKnownPath
        self.reason = reason
        self.createdAt = createdAt
    }
}

nonisolated struct IgnoredReferencedItemsFile: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var items: [IgnoredReferencedItem] = []
}

nonisolated enum IgnoredReferencedItemsStoreError: Error, Equatable {
    case unsupportedSchema(Int)
}

actor IgnoredReferencedItemsStore {
    private let url: URL
    private let fileManager: FileManager
    private var cachedFile: IgnoredReferencedItemsFile?

    init(paths: LibraryPaths, fileManager: FileManager = .default) {
        url = paths.ignoredItemsURL
        self.fileManager = fileManager
    }

    func allItems() throws -> [IgnoredReferencedItem] {
        try load().items
    }

    func contains(_ fingerprint: ReferencedFileFingerprint) throws -> Bool {
        let key = ReferencedPhysicalIdentityKey(fingerprint)
        return try load().items.contains {
            ReferencedPhysicalIdentityKey($0.fingerprint) == key
        }
    }

    @discardableResult
    func add(_ proposedItems: [IgnoredReferencedItem]) throws -> [ReferencedFileFingerprint] {
        guard !proposedItems.isEmpty else { return [] }
        var file = try load()
        var keys = Set(file.items.map { ReferencedPhysicalIdentityKey($0.fingerprint) })
        var inserted: [ReferencedFileFingerprint] = []
        for item in proposedItems where keys.insert(ReferencedPhysicalIdentityKey(item.fingerprint)).inserted {
            file.items.append(item)
            inserted.append(item.fingerprint)
        }
        guard !inserted.isEmpty else { return [] }
        file.items.sort { $0.createdAt < $1.createdAt }
        try persist(file)
        return inserted
    }

    func remove(matching fingerprints: [ReferencedFileFingerprint]) throws {
        guard !fingerprints.isEmpty else { return }
        let keys = Set(fingerprints.map(ReferencedPhysicalIdentityKey.init))
        var file = try load()
        let previousCount = file.items.count
        file.items.removeAll { keys.contains(ReferencedPhysicalIdentityKey($0.fingerprint)) }
        guard file.items.count != previousCount else { return }
        try persist(file)
    }

    private func load() throws -> IgnoredReferencedItemsFile {
        if let cachedFile { return cachedFile }
        guard fileManager.fileExists(atPath: url.path) else {
            let empty = IgnoredReferencedItemsFile()
            cachedFile = empty
            return empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            IgnoredReferencedItemsFile.self,
            from: Data(contentsOf: url)
        )
        guard decoded.schemaVersion == IgnoredReferencedItemsFile.currentSchemaVersion else {
            throw IgnoredReferencedItemsStoreError.unsupportedSchema(decoded.schemaVersion)
        }
        cachedFile = decoded
        return decoded
    }

    private func persist(_ file: IgnoredReferencedItemsFile) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: url, options: .atomic)
        cachedFile = file
    }
}
