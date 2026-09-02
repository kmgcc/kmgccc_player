import Foundation

nonisolated enum ReferencedTrackDeletePolicy: String, Codable, Sendable, CaseIterable {
    case onlyLibrary
    case recycleSource
}

nonisolated struct LibraryScopedSettings: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    var schemaVersion = LibraryScopedSettings.schemaVersion
    var referencedTrackDeletePolicy: ReferencedTrackDeletePolicy = .onlyLibrary
}

nonisolated enum LibraryScopedSettingsError: Error, Equatable {
    case unsupportedSchema(Int)
    case invalidPayload
}

nonisolated enum LibraryScopedSettingsFile {
    static func save(_ value: LibraryScopedSettings, to fileURL: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
}

/// Recreates missing library scaffolding (required directories and the
/// default scoped-settings file) without touching user data. Libraries
/// migrated in place from the pre-manifest layout can miss these; validation
/// requires them.
nonisolated enum LibraryScaffoldingRepair {
    static func repairIfNeeded(at rootURL: URL, fileManager: FileManager = .default) throws {
        let paths = LibraryPaths(rootURL: rootURL)
        try paths.createRequiredDirectories(fileManager: fileManager)
        if !fileManager.fileExists(atPath: paths.librarySettingsURL.path) {
            try LibraryScopedSettingsFile.save(
                LibraryScopedSettings(),
                to: paths.librarySettingsURL,
                fileManager: fileManager
            )
        }
    }
}

actor LibraryScopedSettingsStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(paths: LibraryPaths, fileManager: FileManager = .default) {
        fileURL = paths.librarySettingsURL
        self.fileManager = fileManager
    }

    func load() throws -> LibraryScopedSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return LibraryScopedSettings() }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw LibraryScopedSettingsError.invalidPayload }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object.isEmpty {
            let defaults = LibraryScopedSettings()
            try LibraryScopedSettingsFile.save(defaults, to: fileURL, fileManager: fileManager)
            return defaults
        }

        do {
            let value = try JSONDecoder().decode(LibraryScopedSettings.self, from: data)
            guard value.schemaVersion == LibraryScopedSettings.schemaVersion else {
                throw LibraryScopedSettingsError.unsupportedSchema(value.schemaVersion)
            }
            return value
        } catch let error as LibraryScopedSettingsError {
            throw error
        } catch {
            throw LibraryScopedSettingsError.invalidPayload
        }
    }

    func setReferencedTrackDeletePolicy(_ policy: ReferencedTrackDeletePolicy) throws {
        var value = try load()
        value.referencedTrackDeletePolicy = policy
        try LibraryScopedSettingsFile.save(value, to: fileURL, fileManager: fileManager)
    }
}
