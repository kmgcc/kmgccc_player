import Foundation

nonisolated struct AudioProgramRecoverySnapshot: Codable, Equatable, Sendable {
    struct WholeTrack: Codable, Equatable, Sendable {
        let id: UUID
        let sidecar: Data
        let replacementMediaPath: String?
    }
    struct PlaylistState: Codable, Equatable, Sendable {
        let id: UUID
        let trackIDs: [UUID]
        let itemAddedAt: [UUID: Date]
    }
    let id: UUID
    let createdAt: Date
    let oldTracks: [WholeTrack]
    let newTrackIDs: [UUID]
    let playlists: [PlaylistState]

    static func loadAll(paths: LibraryPaths) throws -> [Self] {
        let root = paths.recoveryRootURL.appendingPathComponent("AudioExpansions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { folder in
            let file = folder.appendingPathComponent("snapshot.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try decoder.decode(Self.self, from: Data(contentsOf: file))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func restoreTrackFiles(paths: LibraryPaths) throws {
        let source = paths.recoveryRootURL.appendingPathComponent("AudioExpansions/\(id.uuidString)", isDirectory: true)
        for track in oldTracks {
            let target = paths.trackFolderURL(for: track.id)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let saved = source.appendingPathComponent(track.id.uuidString, isDirectory: true)
            for file in try FileManager.default.contentsOfDirectory(at: saved, includingPropertiesForKeys: nil)
                where file.lastPathComponent != "meta.json" {
                let destination = target.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: file, to: destination) }
            }
            guard var object = try JSONSerialization.jsonObject(with: track.sidecar) as? [String: Any] else {
                throw AudioDecodingError.failed("整轨恢复记录损坏")
            }
            if let path = track.replacementMediaPath {
                guard let media = paths.libraryURL(from: path), FileManager.default.isReadableFile(atPath: media.path) else {
                    throw AudioDecodingError.failed("整轨原始音频暂时无法访问")
                }
                let locator = try JSONEncoder().encode(TrackMediaLocator.managed(libraryRelativePath: path))
                object["mediaLocator"] = try JSONSerialization.jsonObject(with: locator)
                object["schemaVersion"] = TrackSidecar.currentSchemaVersion
            }
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                .write(to: paths.trackMetaURL(for: track.id), options: .atomic)
        }
    }

    func write(to paths: LibraryPaths) throws {
        let folder = paths.recoveryRootURL.appendingPathComponent("AudioExpansions/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for track in oldTracks {
            let source = paths.trackFolderURL(for: track.id)
            let target = folder.appendingPathComponent(track.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                let ext = file.pathExtension.lowercased()
                if ["json", "jpg", "jpeg", "png", "lrc", "ttml", "srt", "ass"].contains(ext) {
                    try FileManager.default.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
                }
            }
        }
        try encoder.encode(self).write(to: folder.appendingPathComponent("snapshot.json"), options: .atomic)
    }
}
