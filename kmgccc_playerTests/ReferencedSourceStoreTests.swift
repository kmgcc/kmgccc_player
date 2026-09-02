import Foundation
@testable import kmgccc_player
import XCTest

final class ReferencedSourceStoreTests: XCTestCase {
    func testRoundTripAndReload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = ReferencedSourceStore(paths: fixture.paths)
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: Data("bookmark".utf8),
            lastKnownPath: "/Music",
            displayName: "Music",
            lastScan: Date(timeIntervalSince1970: 123),
            status: .stale
        )

        try await store.save(source)
        XCTAssertEqual(try await store.load(id: source.id), source)
        XCTAssertEqual(try await store.loadAll(), [source])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.sourceDescriptorURL(for: source.id).path))
    }

    func testUnknownSchemaAndModeFailExplicitly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = ReferencedSourceStore(paths: fixture.paths)
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: Data("bookmark".utf8),
            lastKnownPath: "/Music",
            displayName: "Music"
        )
        try await store.save(source)
        let url = fixture.paths.sourceDescriptorURL(for: source.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        await XCTAssertThrowsErrorAsync(try await store.load(id: source.id)) {
            XCTAssertEqual($0 as? ReferencedSourceStoreError, .unsupportedSchema(99))
        }

        object["schemaVersion"] = 1
        object["mode"] = "remote"
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        await XCTAssertThrowsErrorAsync(try await store.load(id: source.id)) {
            XCTAssertEqual($0 as? ReferencedSourceStoreError, .unsupportedMode("remote"))
        }
    }

    func testMissingDescriptorInValidUUIDDirectoryFailsAsIncompleteAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let id = UUID()
        try FileManager.default.createDirectory(
            at: fixture.paths.sourceRootURL(for: id),
            withIntermediateDirectories: true
        )
        let store = ReferencedSourceStore(paths: fixture.paths)
        await XCTAssertThrowsErrorAsync(try await store.loadAll()) {
            XCTAssertEqual($0 as? ReferencedSourceStoreError, .incompleteSource(id))
        }
    }

    func testMissingModeAndSchemaAreDeterministic() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: Data("bookmark".utf8), lastKnownPath: "/Music", displayName: "Music"
        )
        let store = ReferencedSourceStore(paths: fixture.paths)
        try await store.save(source)
        let url = fixture.paths.sourceDescriptorURL(for: source.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "mode")
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        await XCTAssertThrowsErrorAsync(try await store.load(id: source.id)) {
            XCTAssertEqual($0 as? ReferencedSourceStoreError, .missingMode)
        }
        object["mode"] = "directory"
        object.removeValue(forKey: "schemaVersion")
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        await XCTAssertThrowsErrorAsync(try await store.load(id: source.id)) {
            XCTAssertEqual($0 as? ReferencedSourceStoreError, .missingSchema)
        }
    }

    func testCorruptSidecarIsNotOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let id = UUID()
        let url = fixture.paths.sourceDescriptorURL(for: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)
        let store = ReferencedSourceStore(paths: fixture.paths)

        await XCTAssertThrowsErrorAsync(try await store.load(id: id))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testExcludedRelativePathsRoundTripAndCanBeCleared() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = ReferencedSourceStore(paths: fixture.paths)
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: Data("bookmark".utf8),
            lastKnownPath: "/Music",
            displayName: "Music",
            excludedRelativePaths: ["Live", "Live/Archive"]
        )

        try await store.save(source)
        let loaded = try await store.load(id: source.id)
        XCTAssertEqual(loaded.excludedRelativePaths, ["Live", "Live/Archive"])

        _ = try await store.setExcludedRelativePath(
            sourceID: source.id,
            relativePath: "Live",
            excluded: false
        )
        let cleared = try await store.load(id: source.id)
        XCTAssertTrue(cleared.excludedRelativePaths.isEmpty)
    }

    func testSchemaTwoSourceLoadsAndIsUpgradedWithoutLosingBindings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = ReferencedSourceStore(paths: fixture.paths)
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: Data("bookmark".utf8),
            lastKnownPath: "/Music",
            displayName: "Music",
            playlistBindings: [.init(playlistID: UUID())]
        )
        try await store.save(source)

        let url = fixture.paths.sourceDescriptorURL(for: source.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["schemaVersion"] = 2
        object.removeValue(forKey: "excludedRelativePaths")
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

        let loaded = try await store.load(id: source.id)
        XCTAssertEqual(loaded.playlistBindings.count, 1)
        XCTAssertEqual(loaded.excludedRelativePaths, [])
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(upgraded["schemaVersion"] as? Int, ReferencedSourceDescriptor.currentSchemaVersion)
    }

    func testInvalidExcludedRelativePathIsRejectedWithoutMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = ReferencedSourceStore(paths: fixture.paths)
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: Data("bookmark".utf8),
            lastKnownPath: "/Music",
            displayName: "Music"
        )
        try await store.save(source)

        await XCTAssertThrowsErrorAsync(
            try await store.setExcludedRelativePath(
                sourceID: source.id,
                relativePath: "../Music",
                excluded: true
            )
        ) {
            XCTAssertEqual($0 as? ReferencedSourceStoreError, .invalidExcludedPath)
        }
        let loaded = try await store.load(id: source.id)
        XCTAssertTrue(loaded.excludedRelativePaths.isEmpty)
    }
}

private struct Fixture {
    let root: URL
    let paths: LibraryPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
