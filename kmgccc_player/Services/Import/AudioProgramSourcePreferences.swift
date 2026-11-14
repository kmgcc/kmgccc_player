import Foundation

nonisolated enum AudioProgramSourcePreferences {
    private struct Preferences: Codable {
        var areas: [UUID: Int] = [:]
        var cues: [UUID: String] = [:]
    }
    private static func url(_ paths: LibraryPaths) -> URL {
        paths.sourcesRootURL.appendingPathComponent("audio-program-options.json")
    }
    private static func load(paths: LibraryPaths) throws -> Preferences {
        let file = url(paths)
        guard FileManager.default.fileExists(atPath: file.path) else { return Preferences() }
        let data = try Data(contentsOf: file)
        if let legacy = try? JSONDecoder().decode([UUID: Int].self, from: data) { return Preferences(areas: legacy) }
        return try JSONDecoder().decode(Preferences.self, from: data)
    }
    static func areas(paths: LibraryPaths) throws -> [UUID: Int] { try load(paths: paths).areas }
    static func cues(paths: LibraryPaths) throws -> [UUID: String] { try load(paths: paths).cues }
    static func save(area: Int, groupID: UUID, paths: LibraryPaths) throws {
        var values = try load(paths: paths)
        values.areas[groupID] = area
        try write(values, paths: paths)
    }
    static func save(cue: URL, groupID: UUID, paths: LibraryPaths) throws {
        var values = try load(paths: paths)
        values.cues[groupID] = cue.lastPathComponent
        try write(values, paths: paths)
    }
    private static func write(_ values: Preferences, paths: LibraryPaths) throws {
        try FileManager.default.createDirectory(at: paths.sourcesRootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: url(paths), options: .atomic)
    }
}
