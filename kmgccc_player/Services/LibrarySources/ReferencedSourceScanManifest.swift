import Foundation

nonisolated struct ReferencedSourceScanEntry: Codable, Sendable, Equatable {
    var relativePath: String
    var identity: ReferencedFileIdentity?
    var fingerprint: ReferencedFileFingerprint
    var trackID: UUID?
    var availability: TrackAvailability
    var lastSeenGeneration: UInt64
}

nonisolated struct ReferencedSourceScanResult: Sendable, Equatable {
    var diff: ReferencedSourceDiff
    var proposedManifest: ReferencedSourceScanManifest?
}

nonisolated struct ReferencedSourceScanManifest: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var libraryID: UUID
    var sourceID: UUID
    var generation: UInt64
    var lastSuccessfulScan: Date
    var entries: [ReferencedSourceScanEntry]

    func entryByPath() -> [String: ReferencedSourceScanEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })
    }
}

actor ReferencedSourceScanManifestStore {
    private let paths: LibraryPaths
    private let fileManager: FileManager

    init(paths: LibraryPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load(sourceID: UUID, libraryID: UUID) throws -> ReferencedSourceScanManifest? {
        let url = paths.sourceScanManifestURL(for: sourceID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value: ReferencedSourceScanManifest
        do {
            value = try decoder.decode(
                ReferencedSourceScanManifest.self,
                from: Data(contentsOf: url)
            )
        } catch {
            try quarantine(url, sourceID: sourceID, reason: "corrupt")
            return nil
        }
        guard value.schemaVersion == ReferencedSourceScanManifest.currentSchemaVersion else {
            try quarantine(url, sourceID: sourceID, reason: "schema")
            return nil
        }
        guard value.libraryID == libraryID else {
            try quarantine(url, sourceID: sourceID, reason: "library")
            return nil
        }
        guard value.sourceID == sourceID else {
            try quarantine(url, sourceID: sourceID, reason: "source")
            return nil
        }
        return value
    }

    func save(_ manifest: ReferencedSourceScanManifest) throws {
        try fileManager.createDirectory(at: paths.sourceScanCacheRootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: paths.sourceScanManifestURL(for: manifest.sourceID),
            options: .atomic
        )
    }

    func bind(
        _ manifest: ReferencedSourceScanManifest,
        trackIDsByRelativePath: [String: UUID]
    ) throws {
        var bound = manifest
        for index in bound.entries.indices {
            if let trackID = trackIDsByRelativePath[bound.entries[index].relativePath] {
                bound.entries[index].trackID = trackID
            }
        }
        try save(bound)
    }

    func quarantinedURLs() throws -> [URL] {
        let directory = quarantineDirectoryURL
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func remove(sourceID: UUID) throws {
        let url = paths.sourceScanManifestURL(for: sourceID)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private var quarantineDirectoryURL: URL {
        paths.sourceScanCacheRootURL.appendingPathComponent("Invalid", isDirectory: true)
    }

    private func quarantine(_ url: URL, sourceID: UUID, reason: String) throws {
        try fileManager.createDirectory(at: quarantineDirectoryURL, withIntermediateDirectories: true)
        let destination = quarantineDirectoryURL.appendingPathComponent(
            "\(sourceID.uuidString).\(reason).\(UUID().uuidString).json"
        )
        try fileManager.moveItem(at: url, to: destination)
    }
}
