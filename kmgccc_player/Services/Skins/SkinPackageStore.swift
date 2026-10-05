import Foundation

enum SkinPackageImportDisposition: Equatable { case copy, replace }

enum SkinPackageError: LocalizedError {
    case unsupportedVersion
    case missingPreset(String)
    case bundledSkin
    case multipleLyrics
    case archive(String)
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "皮肤格式版本不支持"
        case .missingPreset(let id): "缺少皮肤组件：\(id)"
        case .bundledSkin: "内置皮肤保留在 App 中"
        case .multipleLyrics: "每个场景支持一个原生歌词组件"
        case .archive(let message): message
        case .invalidManifest(let message): "皮肤定义无效：\(message)"
        }
    }
}

/// Package persistence and archive work live outside settings views and renderers.
@MainActor
final class SkinPackageStore {
    private unowned let catalog: SkinCatalog
    private let root: URL

    init(catalog: SkinCatalog, root: URL? = nil) {
        self.catalog = catalog
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kmgccc_player/Skins", isDirectory: true)
    }

    func loadInstalled() {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in directories {
            do {
                let manifest = try readManifest(in: directory)
                if let existing = catalog.registeredSkin(for: manifest.descriptor.id) as? PackagedSkin,
                   case .bundled = existing.origin { continue }
                catalog.install(try skin(manifest, origin: .installed(directory)))
            } catch {
                Log.warning("Skin package load failed: \(error.localizedDescription)", category: .ui)
            }
        }
    }

    func inspect(_ archive: URL) async throws -> SkinPackageManifest {
        let directory = try await unpack(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try readManifest(in: directory)
        _ = try skin(manifest, origin: .installed(directory))
        return manifest
    }

    func importPackage(_ archive: URL, disposition: SkinPackageImportDisposition = .copy) async throws -> String {
        let directory = try await unpack(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        var manifest = try readManifest(in: directory)
        let existing = catalog.registeredSkin(for: manifest.descriptor.id) as? PackagedSkin
        let bundledCollision: Bool
        if let existing, case .bundled = existing.origin { bundledCollision = true }
        else { bundledCollision = false }
        if existing != nil && (bundledCollision || disposition == .copy) {
            let original = manifest.descriptor
            manifest.descriptor = original.withIdentity(
                id: "user.\(UUID().uuidString.lowercased())",
                name: "\(original.name) 副本"
            )
            manifest.descriptor.legacy = nil
        }
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        _ = try skin(manifest, origin: .installed(destination))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Prepare the complete new installation before retiring an installed version.
        do {
            try FileManager.default.copyItem(at: directory, to: destination)
            try write(manifest, in: destination)
            if let existing, case .installed(let previous) = existing.origin, disposition == .replace {
                try FileManager.default.removeItem(at: previous)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        catalog.install(try skin(manifest, origin: .installed(destination)))
        return manifest.descriptor.id
    }

    /// Validate the full definition before publishing a replacement. Failed reloads
    /// leave the catalog and current runtime generation untouched.
    func reloadPackage(_ skinID: String) throws {
        guard let current = catalog.registeredSkin(for: skinID) as? PackagedSkin,
              case .installed(let directory) = current.origin else { throw SkinPackageError.bundledSkin }
        let manifest = try readManifest(in: directory)
        guard manifest.descriptor.id == skinID else {
            throw SkinPackageError.invalidManifest("重载时不能更改皮肤 ID")
        }
        catalog.install(try skin(manifest, origin: current.origin))
    }

    func removePackage(_ skinID: String) throws {
        guard let current = catalog.registeredSkin(for: skinID) as? PackagedSkin,
              case .installed(let directory) = current.origin else { throw SkinPackageError.bundledSkin }
        try FileManager.default.removeItem(at: directory)
        catalog.removeInstalled(skinID)
    }

    func exportPackage(_ skin: any NowPlayingSkin, to archive: URL) async throws {
        guard let packaged = skin as? PackagedSkin else { throw SkinPackageError.unsupportedVersion }
        guard packaged.isExportable else { throw SkinPackageError.bundledSkin }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        switch packaged.origin {
        case .bundled: throw SkinPackageError.bundledSkin
        case .installed(let source):
            try FileManager.default.copyItem(at: source, to: directory)
        }
        try write(packaged.manifest, in: directory)
        try await archiveOperation(["-c", "-k", directory.path, archive.path])
    }

    private func skin(_ manifest: SkinPackageManifest, origin: SkinPackageOrigin) throws -> PackagedSkin {
        guard manifest.formatVersion == 1, manifest.hostAPIVersion == 1 else { throw SkinPackageError.unsupportedVersion }
        try manifest.validateDefinition()
        if let scene = manifest.scene {
            if let missing = scene.componentTypes.first(where: { !catalog.components.contains($0) }) {
                throw SkinPackageError.missingPreset(missing)
            }
            guard scene.simultaneousLyricsCount <= 1 else { throw SkinPackageError.multipleLyrics }
        }
        let renderer = catalog.nativePreset(for: manifest.nativePreset)
        if let preset = manifest.nativePreset, renderer == nil { throw SkinPackageError.missingPreset(preset) }
        return PackagedSkin(manifest: manifest, origin: origin, renderer: renderer)
    }

    private func unpack(_ archive: URL) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try await archiveOperation(["-x", "-k", archive.path, directory.path])
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func readManifest(in directory: URL) throws -> SkinPackageManifest {
        try JSONDecoder().decode(SkinPackageManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    private func write(_ manifest: SkinPackageManifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func archiveOperation(_ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = arguments
            process.standardError = errors
            try process.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SkinPackageError.archive(String(data: output, encoding: .utf8) ?? "皮肤包处理失败")
            }
        }.value
    }
}
