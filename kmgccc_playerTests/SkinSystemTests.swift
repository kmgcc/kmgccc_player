import Foundation
import SwiftUI
import XCTest
@testable import kmgccc_player

final class SkinSystemTests: XCTestCase {
    @MainActor
    func testZIPInstallCopyReplaceReloadRestartAndRemoval() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("installed")
        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        let store = SkinPackageStore(catalog: catalog, root: root)
        let manifest = try manifestJSON(id: "test.reading", name: "Reading")
        let archive = try zip(manifest: manifest, in: sandbox)
        let installedID = try await store.importPackage(archive)
        XCTAssertEqual(installedID, "test.reading")
        let installed = try XCTUnwrap(catalog.registeredSkin(for: installedID) as? PackagedSkin)
        guard case .installed(let directory) = installed.origin else { return XCTFail("Missing installation") }
        try FileManager.default.removeItem(at: archive)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("asset.txt"), encoding: .utf8), "resource")
        let copyArchive = try zip(manifest: manifest, in: sandbox)
        let copyID = try await store.importPackage(copyArchive, disposition: .copy)
        XCTAssertNotEqual(copyID, installedID)
        XCTAssertNotNil(catalog.registeredSkin(for: installedID))

        let upgraded = try zip(manifest: manifestJSON(id: installedID, name: "Updated"), in: sandbox)
        let replacedID = try await store.importPackage(upgraded, disposition: .replace)
        XCTAssertEqual(replacedID, installedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let replaced = try XCTUnwrap(catalog.registeredSkin(for: installedID) as? PackagedSkin)
        guard case .installed(let currentDirectory) = replaced.origin else { return XCTFail("Missing replacement") }
        let revision = catalog.revision(for: installedID)
        try Data("{broken".utf8).write(to: currentDirectory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.reloadPackage(installedID))
        XCTAssertEqual(catalog.revision(for: installedID), revision)
        XCTAssertEqual(catalog.registeredSkin(for: installedID)?.name, "Updated")
        try manifestJSON(id: installedID, name: "Reloaded").write(to: currentDirectory.appendingPathComponent("manifest.json"))
        try store.reloadPackage(installedID)
        XCTAssertGreaterThan(catalog.revision(for: installedID), revision)
        XCTAssertEqual(catalog.registeredSkin(for: installedID)?.name, "Reloaded")

        let exported = sandbox.appendingPathComponent("export.zip")
        try await store.exportPackage(try XCTUnwrap(catalog.registeredSkin(for: installedID)), to: exported)
        let exportedManifest = try await store.inspect(exported)
        XCTAssertEqual(exportedManifest.descriptor.name, "Reloaded")
        let restarted = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: restarted.components)
        SkinPackageStore(catalog: restarted, root: root).loadInstalled()
        XCTAssertEqual(restarted.registeredSkin(for: installedID)?.name, "Reloaded")
        XCTAssertNotNil(restarted.registeredSkin(for: copyID))
        try store.removePackage(installedID)
        XCTAssertNil(catalog.registeredSkin(for: installedID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentDirectory.path))
    }

    @MainActor
    func testInvalidReplacementPreservesInstalledDefinitionAndResources() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        let store = SkinPackageStore(catalog: catalog, root: sandbox.appendingPathComponent("installed"))
        let archive = try zip(manifest: manifestJSON(id: "test.replacement", name: "Original"), in: sandbox)
        let id = try await store.importPackage(archive)
        let original = try XCTUnwrap(catalog.registeredSkin(for: id) as? PackagedSkin)
        let revision = catalog.revision(for: id)
        let invalid = try zip(manifest: Data("{\"descriptor\":{\"id\":\"test.replacement\",\"name\":\"Invalid\"}}".utf8), in: sandbox)
        do {
            _ = try await store.importPackage(invalid, disposition: .replace)
            XCTFail("Blank scenes must not replace a usable installation")
        } catch {}
        XCTAssertEqual(catalog.revision(for: id), revision)
        XCTAssertEqual(catalog.registeredSkin(for: id)?.name, "Original")
        if case .installed(let directory) = original.origin {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("asset.txt").path))
        }
    }

    @MainActor
    func testBundledCollisionAlwaysCopiesAndBundledRemovalIsRejected() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        catalog.registerBundled(ClassicLEDSkin())
        let store = SkinPackageStore(catalog: catalog, root: sandbox.appendingPathComponent("installed"))
        let archive = try zip(manifest: manifestJSON(id: ClassicLEDSkin.id, name: "Copy"), in: sandbox)
        let id = try await store.importPackage(archive, disposition: .replace)
        XCTAssertNotEqual(id, ClassicLEDSkin.id)
        XCTAssertThrowsError(try store.removePackage(ClassicLEDSkin.id))
        XCTAssertNotNil(catalog.registeredSkin(for: ClassicLEDSkin.id))
    }

    @MainActor
    func testAuthorParameterUpgradeAndMalformedRange() throws {
        let range = SkinParameterDefinition(id: "amount", title: "Amount", defaultValue: .number(0.5), control: .range(min: 0, max: 1, step: 0.1))
        XCTAssertEqual(range.resolvedValue(.number(10)), .number(1))
        XCTAssertEqual(range.resolvedValue(.text("old type")), .number(0.5))
        let choice = SkinParameterDefinition(id: "style", title: "Style", defaultValue: .text("new"), control: .choice([.init(id: "new", title: "New")]))
        XCTAssertEqual(choice.resolvedValue(.text("removed")), .text("new"))
        let invalid = SkinParameterDefinition(id: "invalid", title: "Invalid", defaultValue: .number(0), control: .range(min: 2, max: 1, step: 0))
        XCTAssertThrowsError(try invalid.validateDefinition())
    }

    @MainActor
    func testPartialDescriptorOverridesAndAdaptiveLyricsCount() throws {
        let data = Data("""
        {"descriptor":{"id":"test.adaptive","name":"Adaptive","audio":{"fullscreen":"off"},"presentation":{"lyricsBackdrop":"mesh"}},
         "scene":{"root":{"id":"root","type":"adaptive","minimumWidth":720,
          "wide":{"id":"lyrics","type":"component","component":"native.lyrics"},
          "compact":{"id":"lyrics","type":"component","component":"native.lyrics"}}}}
        """.utf8)
        let manifest = try JSONDecoder().decode(SkinPackageManifest.self, from: data)
        try manifest.validateDefinition()
        XCTAssertEqual(manifest.scene?.simultaneousLyricsCount, 1)
        XCTAssertEqual(manifest.descriptor.presentation.lyricsBackdrop, .mesh)
        XCTAssertTrue(manifest.descriptor.audio.supportsMiniPlayerVisualization)
        let roundTrip = try JSONDecoder().decode(SkinPackageManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(roundTrip.hostAPIVersion, 1)
    }

    @MainActor
    func testUnsupportedVisualizationKeepsAuthorsSelectedSkin() {
        let id = "test.skin." + UUID().uuidString
        var descriptor = SkinDescriptor(id: id, name: "Custom", detail: "", systemImage: "paintpalette")
        descriptor.audio.supportsMiniPlayerVisualization = false
        descriptor.audio.supportsEmbeddedVisualizer = false
        let catalog = SkinRegistry.catalog
        catalog.install(PackagedSkin(
            manifest: .init(descriptor: descriptor, scene: .init(root: .component("title", "native.trackInfo"))),
            origin: .installed(FileManager.default.temporaryDirectory.appendingPathComponent(id)), renderer: nil
        ))
        defer { catalog.removeInstalled(id) }
        let configuration = FullscreenPresentationConfiguration(skinID: id, visualizerMode: .miniPlayerSpectrum)
        XCTAssertEqual(configuration.skinID, id)
        XCTAssertEqual(configuration.visualizerMode, .off)
    }

    @MainActor
    func testSameIDRevisionInvalidatesHostWork() async {
        let session = SkinSession()
        session.activate("test", revision: 1)
        let generation = session.generation
        session.activate("test", revision: 1)
        XCTAssertEqual(session.generation, generation)
        session.activate("test", revision: 2)
        XCTAssertGreaterThan(session.generation, generation)
        let refreshed = session.generation
        session.deactivate()
        XCTAssertGreaterThan(session.generation, refreshed)
    }

    @MainActor
    func testSceneResourcesReleaseExactlyOnceOnReloadAndExit() {
        let session = SkinSession()
        session.activate("test", revision: 1)
        var releases = 0
        session.registerCleanup { releases += 1 }
        session.activate("test", revision: 2)
        XCTAssertEqual(releases, 1)
        let removed = session.registerCleanup { releases += 100 }
        session.removeCleanup(removed)
        session.registerCleanup { releases += 1 }
        session.deactivate()
        session.deactivate()
        XCTAssertEqual(releases, 2)
    }

    @MainActor
    func testRetiringLyricsSceneCannotClearSuccessorConfiguration() {
        let manager = NativeLyricsSurfaceManager.shared
        let role = LyricsSurfaceRole.batchPreview
        let old = UUID(), current = UUID()
        let baseline = manager.configurationForConsumers(role: role)
        defer {
            manager.clearSceneConfigurationOverride(for: role, owner: current)
            manager.applyConfiguration(baseline, for: role)
        }
        manager.setSceneConfigurationOverride("{\"fontSize\":44}", for: role, owner: old)
        manager.setSceneConfigurationOverride("{\"fontSize\":70}", for: role, owner: current)
        manager.clearSceneConfigurationOverride(for: role, owner: old)
        XCTAssertEqual(manager.configurationForConsumers(role: role).fontSize, 70)
        manager.clearSceneConfigurationOverride(for: role, owner: current)
        XCTAssertEqual(manager.configurationForConsumers(role: role).fontSize, baseline.fontSize)
    }

    @MainActor
    private func manifestJSON(id: String, name: String) throws -> Data {
        let manifest = SkinPackageManifest(
            descriptor: .init(id: id, name: name, detail: "", systemImage: "text.alignleft"),
            scene: .init(root: .component("title", "native.trackInfo"))
        )
        return try JSONEncoder().encode(manifest)
    }

    private func zip(manifest: Data, in sandbox: URL) throws -> URL {
        let source = sandbox.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try manifest.write(to: source.appendingPathComponent("manifest.json"))
        try Data("resource".utf8).write(to: source.appendingPathComponent("asset.txt"))
        let archive = sandbox.appendingPathComponent(UUID().uuidString + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", source.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }
}
