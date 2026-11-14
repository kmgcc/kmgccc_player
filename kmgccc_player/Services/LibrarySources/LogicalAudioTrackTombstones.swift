import Foundation

/// These tombstones suppress only the selected logical track, while its
/// physical file remains available to the other tracks in the same program.
nonisolated enum LogicalAudioTrackTombstones {
    private static func url(_ paths: LibraryPaths) -> URL {
        paths.sourcesRootURL.appendingPathComponent("logical-track-removals.json")
    }
    static func load(paths: LibraryPaths) throws -> Set<String> {
        let location = url(paths)
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: location))
    }
    static func add(_ selection: AudioMediaSelection, paths: LibraryPaths) throws {
        _ = try add([selection], paths: paths)
    }
    @discardableResult
    static func add(_ selections: [AudioMediaSelection], paths: LibraryPaths) throws -> Set<String> {
        let existing = try load(paths: paths)
        let inserted = Set(selections.map(\.logicalKey)).subtracting(existing)
        try save(existing.union(inserted), paths: paths)
        return inserted
    }
    static func remove(_ keys: Set<String>, paths: LibraryPaths) throws {
        guard !keys.isEmpty else { return }
        try save(try load(paths: paths).subtracting(keys), paths: paths)
    }
    private static func save(_ removed: Set<String>, paths: LibraryPaths) throws {
        try FileManager.default.createDirectory(at: paths.sourcesRootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(removed.sorted()).write(to: url(paths), options: .atomic)
    }
}
