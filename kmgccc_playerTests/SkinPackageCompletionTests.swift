import Foundation
import SwiftUI
import XCTest
@testable import kmgccc_player

final class SkinPackageCompletionTests: XCTestCase {
    @MainActor
    func testCodeRegisteredIdentityIsPreservedWhenAnArchiveUsesTheSameID() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let originalID = "test.code-owner.\(UUID().uuidString.lowercased())"
        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        let codeSkin = CodeRegisteredSkin(descriptor: descriptor(id: originalID, name: "Code Skin"))
        XCTAssertTrue(catalog.register(codeSkin))

        let archive = try makeArchive(
            manifest: manifestData(id: originalID, name: "Imported Skin"),
            assets: ["asset.txt": Data("package resource".utf8)],
            in: sandbox
        )
        let store = SkinPackageStore(catalog: catalog, root: sandbox.appendingPathComponent("installed"))
        let importedID = try await store.importPackage(archive, disposition: .replace)

        XCTAssertNotEqual(importedID, originalID)
        XCTAssertEqual(catalog.registeredSkin(for: originalID)?.name, "Code Skin")
        let imported = try XCTUnwrap(catalog.registeredSkin(for: importedID) as? PackagedSkin)
        XCTAssertEqual(imported.name, "Imported Skin 副本")
        guard case .installed(let installedDirectory) = imported.origin else {
            return XCTFail("The imported copy should be installed")
        }
        XCTAssertEqual(
            try String(contentsOf: installedDirectory.appendingPathComponent("asset.txt"), encoding: .utf8),
            "package resource"
        )
    }

    @MainActor
    func testRestartDiscoveryDoesNotReplaceACodeRegisteredSkin() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let skinID = "test.code-discovery.\(UUID().uuidString.lowercased())"
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        let storedPackage = root.appendingPathComponent("stale-package", isDirectory: true)
        try FileManager.default.createDirectory(at: storedPackage, withIntermediateDirectories: true)
        try manifestData(id: skinID, name: "Stored Package")
            .write(to: storedPackage.appendingPathComponent("manifest.json"))

        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        XCTAssertTrue(catalog.register(CodeRegisteredSkin(descriptor: descriptor(id: skinID, name: "Code Skin"))))

        SkinPackageStore(catalog: catalog, root: root).loadInstalled()

        XCTAssertEqual(catalog.skins.count, 1)
        XCTAssertEqual(catalog.registeredSkin(for: skinID)?.name, "Code Skin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedPackage.appendingPathComponent("manifest.json").path))
    }

    @MainActor
    func testExportedResourcesSurviveSourceRemovalAndRestartDiscovery() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        let store = SkinPackageStore(catalog: catalog, root: root)
        let sourceArchive = try makeArchive(
            manifest: manifestData(id: "test.export.resources", name: "Resources"),
            assets: [
                "assets/cover.bin": Data([0, 1, 2, 255]),
                "assets/nested/credit.txt": Data("author credit".utf8),
            ],
            in: sandbox
        )
        let originalID = try await store.importPackage(sourceArchive)
        try FileManager.default.removeItem(at: sourceArchive)

        let original = try XCTUnwrap(catalog.registeredSkin(for: originalID) as? PackagedSkin)
        guard case .installed(let originalDirectory) = original.origin else {
            return XCTFail("The package should have an App-managed installation")
        }
        XCTAssertEqual(
            try Data(contentsOf: originalDirectory.appendingPathComponent("assets/cover.bin")),
            Data([0, 1, 2, 255])
        )

        let exportedArchive = sandbox.appendingPathComponent("exported.zip")
        try await store.exportPackage(original, to: exportedArchive)
        let exportedCopyID = try await store.importPackage(exportedArchive, disposition: .copy)
        let exportedCopy = try XCTUnwrap(catalog.registeredSkin(for: exportedCopyID) as? PackagedSkin)
        guard case .installed(let exportedCopyDirectory) = exportedCopy.origin else {
            return XCTFail("The exported package should remain installable")
        }
        XCTAssertEqual(
            try String(contentsOf: exportedCopyDirectory.appendingPathComponent("assets/nested/credit.txt"), encoding: .utf8),
            "author credit"
        )

        let restartedCatalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: restartedCatalog.components)
        SkinPackageStore(catalog: restartedCatalog, root: root).loadInstalled()
        XCTAssertEqual(restartedCatalog.registeredSkin(for: originalID)?.name, "Resources")
        XCTAssertEqual(restartedCatalog.registeredSkin(for: exportedCopyID)?.name, "Resources 副本")
    }

    @MainActor
    func testFormatAndHostAPIVersionsGateReplacementWhileAuthorVersionCanAdvance() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        let store = SkinPackageStore(catalog: catalog, root: sandbox.appendingPathComponent("installed"))
        let originalArchive = try makeArchive(
            manifest: manifestData(id: "test.version.contract", name: "Original", version: "1.0.0"),
            assets: ["asset.txt": Data("old resource".utf8)],
            in: sandbox
        )
        let id = try await store.importPackage(originalArchive)

        let compatibleUpgrade = try makeArchive(
            manifest: manifestData(id: id, name: "Compatible", version: "3.2.0"),
            assets: ["asset.txt": Data("current resource".utf8)],
            in: sandbox
        )
        _ = try await store.importPackage(compatibleUpgrade, disposition: .replace)
        let current = try XCTUnwrap(catalog.registeredSkin(for: id) as? PackagedSkin)
        XCTAssertEqual(current.manifest.formatVersion, 1)
        XCTAssertEqual(current.manifest.hostAPIVersion, 1)
        XCTAssertEqual(current.manifest.version, "3.2.0")
        guard case .installed(let currentDirectory) = current.origin else {
            return XCTFail("The compatible version should replace the prior installation")
        }
        let currentRevision = catalog.revision(for: id)
        let currentManifest = try Data(contentsOf: currentDirectory.appendingPathComponent("manifest.json"))
        try Data("{broken".utf8).write(to: currentDirectory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.reloadPackage(id))
        XCTAssertEqual(catalog.revision(for: id), currentRevision)
        XCTAssertEqual(catalog.registeredSkin(for: id)?.name, "Compatible")
        XCTAssertEqual(
            try String(contentsOf: currentDirectory.appendingPathComponent("asset.txt"), encoding: .utf8),
            "current resource"
        )
        try currentManifest.write(to: currentDirectory.appendingPathComponent("manifest.json"))

        for unsupportedVersion in ["format", "hostAPI"] {
            var manifest = makeManifest(id: id, name: "Rejected \(unsupportedVersion)", version: "4.0.0")
            if unsupportedVersion == "format" { manifest.formatVersion = 2 }
            else { manifest.hostAPIVersion = 2 }
            let archive = try makeArchive(manifest: JSONEncoder().encode(manifest), in: sandbox)

            do {
                _ = try await store.importPackage(archive, disposition: .replace)
                XCTFail("Unsupported \(unsupportedVersion) versions must not replace an installed package")
            } catch let error as SkinPackageError {
                guard case .unsupportedVersion = error else {
                    return XCTFail("Expected unsupported version error, got \(error)")
                }
            }

            XCTAssertEqual(catalog.revision(for: id), currentRevision)
            XCTAssertEqual(catalog.registeredSkin(for: id)?.name, "Compatible")
            XCTAssertEqual(
                try String(contentsOf: currentDirectory.appendingPathComponent("asset.txt"), encoding: .utf8),
                "current resource"
            )
        }
    }

    @MainActor
    func testUpdatedParameterDefinitionsPreserveClampAndResetValuesPerSurface() throws {
        let suiteName = "SkinPackageCompletionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SkinParameterStore(defaults: defaults)
        let previousDefinitions = [
            SkinParameterDefinition(id: "enabled", title: "Enabled", defaultValue: .boolean(false), control: .toggle),
            SkinParameterDefinition(id: "amount", title: "Amount", defaultValue: .number(0.5), control: .range(min: 0, max: 1, step: 0.1)),
            SkinParameterDefinition(id: "style", title: "Style", defaultValue: .text("old"), control: .choice([.init(id: "old", title: "Old")])),
            SkinParameterDefinition(id: "mode", title: "Mode", defaultValue: .boolean(true), control: .toggle),
        ]
        store.set(skinID: "test.parameter.upgrade", surface: .window, definition: previousDefinitions[0], value: .boolean(true))
        store.set(skinID: "test.parameter.upgrade", surface: .window, definition: previousDefinitions[1], value: .number(0.9))
        store.set(skinID: "test.parameter.upgrade", surface: .fullscreen, definition: previousDefinitions[1], value: .number(0.35))
        store.set(skinID: "test.parameter.upgrade", surface: .window, definition: previousDefinitions[2], value: .text("old"))
        store.set(skinID: "test.parameter.upgrade", surface: .window, definition: previousDefinitions[3], value: .boolean(false))

        let upgradedDefinitions = [
            SkinParameterDefinition(id: "enabled", title: "Enabled", defaultValue: .boolean(false), control: .toggle),
            SkinParameterDefinition(id: "amount", title: "Amount", defaultValue: .number(0.3), control: .range(min: 0.2, max: 0.6, step: 0.1)),
            SkinParameterDefinition(id: "style", title: "Style", defaultValue: .text("new"), control: .choice([.init(id: "new", title: "New")])),
            SkinParameterDefinition(id: "mode", title: "Mode", defaultValue: .text("native"), control: .choice([.init(id: "native", title: "Native")])),
        ]

        let windowValues = store.values(
            skinID: "test.parameter.upgrade",
            surface: .window,
            definitions: upgradedDefinitions
        )
        XCTAssertEqual(windowValues["enabled"], .boolean(true))
        XCTAssertEqual(windowValues["amount"], .number(0.6))
        XCTAssertEqual(windowValues["style"], .text("new"))
        XCTAssertEqual(windowValues["mode"], .text("native"))

        let fullscreenValues = store.values(
            skinID: "test.parameter.upgrade",
            surface: .fullscreen,
            definitions: upgradedDefinitions
        )
        XCTAssertEqual(fullscreenValues["amount"], .number(0.35))
    }

    @MainActor
    func testRemovingSelectedInstalledSkinRestoresBothBuiltInSelections() throws {
        let catalog = SkinRegistry.catalog
        let settings = AppSettings.shared
        let skinID = "test.selected-removal.\(UUID().uuidString.lowercased())"
        let originalWindowID = settings.selectedNowPlayingSkinID
        let originalFullscreen = settings.fullscreen.configuration
        let defaults = UserDefaults.standard
        let fallbackDescriptor = SkinRegistry.registeredDescriptor(for: SkinRegistry.defaultFullscreenSkinID)
        let originalWindowDescriptor = SkinRegistry.registeredDescriptor(for: originalWindowID)
        let descriptorForVisualizerKey: (String) -> String = { id in
            SkinRegistry.registeredDescriptor(for: id)?.legacy?.visualizerKey(scope: .fullscreen)
                ?? "skin.\(id).fullscreen.visualizerMode"
        }
        let keys = [
            "nowPlayingSkin",
            "fullscreenPresentationConfiguration_v2",
            "fullscreenSkin",
            "miniPlayerSpectrumEnabled",
            "userExplicitlyDisabledMiniPlayerSpectrum_v1",
            "audioVisualization.fullscreen.\(skinID).selection.v1",
            descriptorForVisualizerKey(skinID),
            "audioVisualization.fullscreen.\(originalFullscreen.skinID).selection.v1",
            descriptorForVisualizerKey(originalFullscreen.skinID),
            "audioVisualization.fullscreen.\(SkinRegistry.defaultFullscreenSkinID).selection.v1",
            descriptorForVisualizerKey(SkinRegistry.defaultFullscreenSkinID),
        ] + (fallbackDescriptor?.legacy?.entryBooleanKey.map { [$0] } ?? [])
            + (originalWindowDescriptor?.legacy?.entryBooleanKey.map { [$0] } ?? [])
        let snapshots = keys.map { ($0, defaults.object(forKey: $0)) }

        defer {
            settings.selectedNowPlayingSkinID = originalWindowID
            settings.fullscreen.setSkinID(originalFullscreen.skinID)
            settings.fullscreen.setVisualizerMode(originalFullscreen.visualizerMode)
            for (key, value) in snapshots {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            if catalog.registeredSkin(for: skinID) != nil { catalog.removeInstalled(skinID) }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinPackageCompletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = SkinPackageManifest(
            descriptor: descriptor(id: skinID, name: "Selected Package"),
            scene: .init(root: .component("root", "native.trackInfo"))
        )
        catalog.install(PackagedSkin(manifest: manifest, origin: .installed(directory), renderer: nil))
        settings.selectedNowPlayingSkinID = skinID
        settings.fullscreen.setSkinID(skinID)

        try SkinManager(catalog: catalog).removePackage(skinID, settings: settings)

        XCTAssertEqual(settings.selectedNowPlayingSkinID, SkinRegistry.defaultSkinID)
        XCTAssertEqual(settings.fullscreen.skinID, SkinRegistry.defaultFullscreenSkinID)
        XCTAssertNotNil(catalog.registeredSkin(for: SkinRegistry.defaultSkinID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testStandaloneOfficialCapsulesPairInEveryAdaptiveBranch() throws {
        let actions = SkinSceneNode.component("actions", "native.actionsCapsule")
        let volume = SkinSceneNode.component("volume", "native.volumeCapsule")
        let leftOnly = SkinSceneNode(id: "root", content: .row(children: [actions], spacing: 0))
        let rightOnly = SkinSceneNode(id: "root", content: .row(children: [volume], spacing: 0))
        XCTAssertThrowsError(try manifest(scene: .init(root: leftOnly)).validateDefinition())
        XCTAssertThrowsError(try manifest(scene: .init(root: rightOnly)).validateDefinition())

        let paired = SkinSceneNode(id: "paired", content: .row(children: [actions, volume], spacing: 0))
        let empty = SkinSceneNode(id: "empty", content: .row(children: [], spacing: 0))
        let validAdaptive = SkinSceneNode(
            id: "root",
            content: .adaptive(minimumWidth: 700, wide: paired, compact: empty)
        )
        XCTAssertNoThrow(try manifest(scene: .init(root: validAdaptive)).validateDefinition())

        let invalidAdaptive = SkinSceneNode(
            id: "root",
            content: .adaptive(minimumWidth: 700, wide: paired, compact: leftOnly)
        )
        XCTAssertThrowsError(try manifest(scene: .init(root: invalidAdaptive)).validateDefinition())

        let customControl = SkinSceneNode.component("custom", "author.customControl")
        XCTAssertNoThrow(try manifest(scene: .init(root: customControl)).validateDefinition())
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    @MainActor
    private func descriptor(id: String, name: String) -> SkinDescriptor {
        SkinDescriptor(id: id, name: name, detail: "", systemImage: "paintpalette")
    }

    @MainActor
    private func makeManifest(
        id: String,
        name: String,
        version: String = "1.0.0"
    ) -> SkinPackageManifest {
        SkinPackageManifest(
            version: version,
            descriptor: descriptor(id: id, name: name),
            scene: .init(root: .component("root", "native.trackInfo"))
        )
    }

    @MainActor
    private func manifest(scene: SkinSceneDocument) -> SkinPackageManifest {
        SkinPackageManifest(
            descriptor: descriptor(id: "test.capsules", name: "Capsules"),
            scene: scene
        )
    }

    @MainActor
    private func manifestData(id: String, name: String, version: String = "1.0.0") throws -> Data {
        try JSONEncoder().encode(makeManifest(id: id, name: name, version: version))
    }

    private func makeArchive(
        manifest: Data,
        assets: [String: Data] = [:],
        in sandbox: URL
    ) throws -> URL {
        let source = sandbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try manifest.write(to: source.appendingPathComponent("manifest.json"))
        for (relativePath, data) in assets {
            let asset = source.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: asset.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: asset)
        }

        let archive = sandbox.appendingPathComponent(UUID().uuidString + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", source.path, archive.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SkinPackageCompletionTests", code: Int(process.terminationStatus))
        }
        return archive
    }
}

private struct CodeRegisteredSkin: NowPlayingSkin {
    let descriptor: SkinDescriptor
}
