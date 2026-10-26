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
                if let existing = catalog.registeredSkin(for: manifest.descriptor.id) {
                    if let packaged = existing as? PackagedSkin {
                        if case .bundled = packaged.origin { continue }
                    } else {
                        Log.warning(
                            "Installed skin ID conflicts with a code-registered skin; keeping the registered skin: \(manifest.descriptor.id)",
                            category: .ui
                        )
                        continue
                    }
                }
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
        let registeredSkin = catalog.registeredSkin(for: manifest.descriptor.id)
        let existingPackage = registeredSkin as? PackagedSkin
        let previousPackage: PackagedSkin? = {
            guard disposition == .replace,
                  let existingPackage,
                  case .installed = existingPackage.origin else { return nil }
            return existingPackage
        }()
        // Code-registered skins cannot be replaced by an imported archive. Treat
        // those collisions like bundled skins and give the package a new identity.
        if registeredSkin != nil && previousPackage == nil {
            let original = manifest.descriptor
            manifest.descriptor = original.withIdentity(
                id: "user.\(UUID().uuidString.lowercased())",
                name: "\(original.name) 副本"
            )
            manifest.descriptor.legacy = nil
        }
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        _ = try skin(manifest, origin: .installed(directory))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Prepare the complete new installation before retiring an installed version.
        let prepared: PackagedSkin
        do {
            try FileManager.default.copyItem(at: directory, to: destination)
            try write(manifest, in: destination)
            prepared = try skin(manifest, origin: .installed(destination))
            if let previousPackage, case .installed(let previous) = previousPackage.origin {
                try FileManager.default.removeItem(at: previous)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        catalog.install(prepared)
        return manifest.descriptor.id
    }

    /// Validate the full definition before publishing a replacement. Failed reloads
    /// leave the catalog and current runtime generation untouched.
    func reloadPackage(_ skinID: String) throws {
        guard let current = catalog.registeredSkin(for: skinID) as? PackagedSkin else { throw SkinPackageError.bundledSkin }
        let directory: URL
        switch current.origin {
        case .installed(let url), .development(let url): directory = url
        case .bundled: throw SkinPackageError.bundledSkin
        }
        let manifest = try readManifest(in: directory)
        guard manifest.descriptor.id == skinID else {
            throw SkinPackageError.invalidManifest("重载时不能更改皮肤 ID")
        }
        catalog.install(try skin(manifest, origin: current.origin))
    }

    func removePackage(_ skinID: String) throws {
        guard let current = catalog.registeredSkin(for: skinID) as? PackagedSkin else { throw SkinPackageError.bundledSkin }
        switch current.origin {
        case .installed(let directory): try FileManager.default.removeItem(at: directory)
        case .development: catalog.developmentDirectories.detach(skinID)
        case .bundled: throw SkinPackageError.bundledSkin
        }
        catalog.removeInstalled(skinID)
    }

    func exportPackage(_ skin: any NowPlayingSkin, to archive: URL) async throws {
        guard let packaged = skin as? PackagedSkin else { throw SkinPackageError.unsupportedVersion }
        guard packaged.isExportable else { throw SkinPackageError.bundledSkin }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        switch packaged.origin {
        case .bundled: throw SkinPackageError.bundledSkin
        case .installed(let source), .development(let source):
            try FileManager.default.copyItem(at: source, to: directory)
        }
        try write(packaged.manifest, in: directory)
        try await archiveOperation(["-c", "-k", directory.path, archive.path])
    }

    private func skin(_ manifest: SkinPackageManifest, origin: SkinPackageOrigin) throws -> PackagedSkin {
        guard manifest.formatVersion == 2, manifest.hostAPIVersion == 2 else { throw SkinPackageError.unsupportedVersion }
        try manifest.validateDefinition()
        if let scene = manifest.scene {
            if let missing = scene.componentTypes.first(where: { !catalog.components.contains($0) }) {
                throw SkinPackageError.missingPreset(missing)
            }
            guard scene.simultaneousLyricsCount <= 1 else { throw SkinPackageError.multipleLyrics }
        }
        let renderer = catalog.nativePreset(for: manifest.nativePreset)
        if let preset = manifest.nativePreset, renderer == nil { throw SkinPackageError.missingPreset(preset) }
        var programs: [String: SkinSceneProgram] = [:]
        if let document = manifest.sceneV2 {
            programs["default"] = try SkinSceneCompiler.compile(document, parameters: manifest.parameters, requires: manifest.requires, file: manifest.scenePath ?? "manifest.json")
        }
        for (surface, document) in manifest.scenes {
            guard SkinSurface(rawValue: surface) != nil else { throw SkinPackageError.invalidManifest("显示模式无效：\(surface)") }
            programs[surface] = try SkinSceneCompiler.compile(document, parameters: manifest.parameters, requires: manifest.requires)
        }
        guard renderer != nil || manifest.descriptor.surfaces.allSatisfy({ programs[$0.rawValue] != nil || programs["default"] != nil }) else {
            throw SkinPackageError.invalidManifest("缺少显示模式的场景")
        }
        let resourceRoot: URL?
        switch origin { case .installed(let url), .development(let url): resourceRoot = url; case .bundled: resourceRoot = Bundle.main.resourceURL }
        if let resourceRoot {
            try validateResources(in: resourceRoot, fonts: manifest.fonts)
            let assets = programs.values.reduce(into: Set<String>()) { $0.formUnion($1.root.referencedAssets) }
            for path in assets {
                let url = try SkinResourceResolver.resolve(path, root: resourceRoot)
                guard FileManager.default.fileExists(atPath: url.path) else { throw SkinPackageError.invalidManifest("缺少素材：\(path)") }
                if url.pathExtension == "metal", (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1024 * 1024 {
                    throw SkinPackageError.invalidManifest("着色器超过大小限制")
                }
            }
        }
        return PackagedSkin(manifest: manifest, origin: origin, renderer: renderer, programs: programs)
    }

    private func unpack(_ archive: URL) async throws -> URL {
        try SkinArchiveInspection.validate(archive)
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
        var manifest = try JSONDecoder().decode(SkinPackageManifest.self, from: limitedData(directory.appendingPathComponent("manifest.json")))
        if let path = manifest.scenePath {
            let url = try SkinResourceResolver.resolve(path, root: directory)
            manifest.sceneV2 = try JSONDecoder().decode(SkinSceneV2Document.self, from: limitedData(url))
        }
        let componentsDirectory = directory.appendingPathComponent("components", isDirectory: true)
        if FileManager.default.fileExists(atPath: componentsDirectory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: componentsDirectory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                let safeURL = try SkinResourceResolver.resolve("components/" + url.lastPathComponent, root: directory)
                let template = try JSONDecoder().decode(SkinParameterValue.self, from: limitedData(safeURL))
                let name = url.deletingPathExtension().lastPathComponent
                manifest.sceneV2?.components[name] = template
                for surface in Array(manifest.scenes.keys) { manifest.scenes[surface]?.components[name] = template }
            }
        }
        return manifest
    }

    private func limitedData(_ url: URL) throws -> Data {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4 * 1024 * 1024 else {
            throw SkinPackageError.invalidManifest("JSON 文件超过大小限制")
        }
        return try Data(contentsOf: url)
    }

    private func validateResources(in root: URL, fonts: [String]) throws {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else { return }
        var count = 0, total = 0
        for case let url as URL in entries {
            count += 1
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw SkinPackageError.invalidManifest("包内不能包含链接") }
            total += values.fileSize ?? 0
            guard count <= SkinArchiveInspection.maximumFiles, total <= SkinArchiveInspection.maximumExpandedBytes,
                  (values.fileSize ?? 0) <= 128 * 1024 * 1024 else { throw SkinPackageError.invalidManifest("包资源超过大小限制") }
        }
        for path in fonts {
            let url = try SkinResourceResolver.resolve(path, root: root)
            guard ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()), FileManager.default.fileExists(atPath: url.path) else {
                throw SkinPackageError.invalidManifest("字体无效：\(path)")
            }
        }
    }

    func validateDirectory(_ directory: URL) throws -> PackagedSkin {
        try skin(readManifest(in: directory), origin: .development(directory))
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
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
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
