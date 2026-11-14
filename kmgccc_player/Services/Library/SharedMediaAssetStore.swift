import Foundation

/// Shared originals are owned by committed track sidecars. Recovery records
/// and active imports retain their resources until the corresponding operation ends.
nonisolated enum SharedMediaAssetStore {
    private final class AccessState: @unchecked Sendable {
        let lock = NSLock()
        var generation: UInt64 = 0
        var readers: [String: Int] = [:]
    }
    private static let access = AccessState()

    static func retainMedia(_ relativePath: String, paths: LibraryPaths) -> @Sendable () -> Void {
        let key = paths.rootURL.standardizedFileURL.path + "/" + relativePath
        access.lock.withLock {
            access.generation &+= 1
            access.readers[key, default: 0] += 1
        }
        return {
            access.lock.withLock {
                access.generation &+= 1
                let count = (access.readers[key] ?? 1) - 1
                access.readers[key] = count > 0 ? count : nil
            }
        }
    }

    private struct Ownership: Codable {
        let schemaVersion: Int
        let audioFileName: String
    }
    static func markOwnership(folder: URL, audioFileName: String) throws {
        try JSONEncoder().encode(Ownership(schemaVersion: 1, audioFileName: audioFileName))
            .write(to: folder.appendingPathComponent(".media-owner.json"), options: .atomic)
    }

    static func pruneUnreferenced(paths: LibraryPaths) throws {
        let root = paths.rootURL.appendingPathComponent("MediaAssets", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        for group in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard UUID(uuidString: group.lastPathComponent) != nil, group.hasDirectoryPath else { continue }
            for version in try fm.contentsOfDirectory(at: group, includingPropertiesForKeys: [.isDirectoryKey]) {
                let marker = version.appendingPathComponent(".media-owner.json")
                guard let data = try? Data(contentsOf: marker),
                      let owner = try? JSONDecoder().decode(Ownership.self, from: data), owner.schemaVersion == 1,
                      owner.audioFileName == URL(fileURLWithPath: owner.audioFileName).lastPathComponent else { continue }
                try releaseIfUnreferenced("MediaAssets/\(group.lastPathComponent)/\(version.lastPathComponent)/\(owner.audioFileName)", paths: paths)
            }
        }
    }

    static func enableFormat(at paths: LibraryPaths) throws {
        let old = try MusicLibraryManifest.read(from: paths.manifestURL)
        guard old.schemaVersion < 2 else { return }
        let backup = paths.recoveryRootURL.appendingPathComponent("shared-media-library-v1.json")
        try FileManager.default.createDirectory(at: paths.recoveryRootURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: paths.manifestURL, to: backup)
        }
        let upgraded = MusicLibraryManifest(schemaVersion: 2, libraryID: old.libraryID,
            displayName: old.displayName, mode: old.mode, createdAt: old.createdAt, updatedAt: Date())
        try upgraded.write(to: paths.manifestURL)
    }

    static func releaseIfUnreferenced(_ relativePath: String, paths: LibraryPaths) throws {
        guard relativePath.hasPrefix("MediaAssets/"), TrackMediaLocator.isSafeRelativePath(relativePath),
              let media = paths.libraryURL(from: relativePath) else { return }
        let key = paths.rootURL.standardizedFileURL.path + "/" + relativePath
        let generation: UInt64? = access.lock.withLock {
            access.readers[key] == nil ? access.generation : nil
        }
        guard let generation else { return }
        let fm = FileManager.default
        if let imports = try? fm.contentsOfDirectory(at: paths.importStagingRootURL, includingPropertiesForKeys: nil),
           !imports.isEmpty { return }
        // A malformed authority record means reachability cannot be established.
        // Keep the original until the existing repair workflow resolves it.
        let folders = try fm.contentsOfDirectory(at: paths.tracksRootURL, includingPropertiesForKeys: nil)
        let folderPath = (relativePath as NSString).deletingLastPathComponent + "/"
        for folder in folders {
            let meta = folder.appendingPathComponent("meta.json")
            guard fm.fileExists(atPath: meta.path) else { continue }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: meta))
            if references(object, prefix: folderPath) { return }
        }
        if let recovery = fm.enumerator(at: paths.recoveryRootURL, includingPropertiesForKeys: nil) {
            for case let url as URL in recovery where url.pathExtension == "json" {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                if references(object, prefix: folderPath) { return }
            }
        }
        let directory = media.deletingLastPathComponent()
        try access.lock.withLock {
            guard access.generation == generation, access.readers[key] == nil else { return }
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        }
    }

    private static func references(_ object: Any, prefix: String) -> Bool {
        if let string = object as? String { return string.hasPrefix(prefix) }
        if let dictionary = object as? [String: Any] { return dictionary.values.contains { references($0, prefix: prefix) } }
        if let array = object as? [Any] { return array.contains { references($0, prefix: prefix) } }
        return false
    }
}
