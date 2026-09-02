import Foundation
import XCTest
@testable import kmgccc_player

/// 测试 target 与主 target 存在同名类型歧义，本文件所有 app 类型一律显式限定。
private final class StaticSourceBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) { (url, false) }
    func refreshBookmark(for url: URL) throws -> Data { Data(url.standardizedFileURL.path.utf8) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

@MainActor
final class ReferencedLibraryDomainMigrationTests: XCTestCase {
    // MARK: - Journal actor behavior

    func testPrepareIsIdempotentAndCommitMarksJournalCommitted() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let migration = kmgccc_player.ReferencedLibraryDomainMigration(
            paths: fixture.paths,
            libraryID: fixture.context.id
        )

        let first = try await migration.prepare()
        XCTAssertEqual(first.stage, .backedUp)
        XCTAssertEqual(first.libraryID, fixture.context.id)
        let second = try await migration.prepare()
        XCTAssertEqual(second.backupID, first.backupID)

        try await migration.commit()
        let committed = try await migration.journal()
        XCTAssertEqual(committed?.stage, .committed)
        XCTAssertNotNil(committed?.completedAt)
        let third = try await migration.prepare()
        XCTAssertEqual(third.stage, .committed)
        let hasCommitted = await migration.hasCommittedJournal()
        XCTAssertTrue(hasCommitted)
    }

    func testHasCommittedJournalIsFalseWithoutReadableCommittedJournal() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let migration = kmgccc_player.ReferencedLibraryDomainMigration(
            paths: fixture.paths,
            libraryID: fixture.context.id
        )

        let withoutJournal = await migration.hasCommittedJournal()
        XCTAssertFalse(withoutJournal)

        try Data("corrupt".utf8).write(to: fixture.paths.domainMigrationJournalURL)
        let withCorruptJournal = await migration.hasCommittedJournal()
        XCTAssertFalse(withCorruptJournal)
    }

    // MARK: - Backup failure blocks the open (fail closed)

    func testBackupFailureBlocksReferencedSessionOpen() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await saveDescriptor(
            at: fixture.paths,
            bindings: []
        )
        // 占用备份根目录，使 prepare() 的备份拷贝必然失败且无已提交 journal。
        try Data("blocked".utf8).write(to: fixture.paths.domainMigrationBackupRootURL)

        do {
            let session = try await makeSession(fixture)
            await session.close()
            XCTFail("Expected the backup failure to block the session")
        } catch {
            guard case let kmgccc_player.LibrarySessionFactoryError.referencedDomainBackupUnavailable(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("备份"))
        }
        let journal = try await domainJournal(fixture)
        XCTAssertNil(journal)
    }

    func testCommittedJournalOpensWithoutFreshBackup() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await saveDescriptor(at: fixture.paths, bindings: [])
        let migration = kmgccc_player.ReferencedLibraryDomainMigration(
            paths: fixture.paths,
            libraryID: fixture.context.id
        )
        _ = try await migration.prepare()
        try await migration.commit()
        // 已提交后即使备份基础设施不可用，也不应阻止打开。
        try FileManager.default.removeItem(at: fixture.paths.domainMigrationBackupRootURL)
        try Data("blocked".utf8).write(to: fixture.paths.domainMigrationBackupRootURL)

        let session = try await makeSession(fixture)
        await session.close()

        let journal = try await domainJournal(fixture)
        XCTAssertEqual(journal?.stage, .committed)
    }

    // MARK: - Post-validation gates commit()

    func testDanglingBindingKeepsJournalPendingButSessionOpens() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await saveDescriptor(
            at: fixture.paths,
            bindings: [kmgccc_player.ReferencedPlaylistSourceBinding(playlistID: UUID())]
        )

        let session = try await makeSession(fixture)
        await session.close()

        let journal = try await domainJournal(fixture)
        XCTAssertEqual(journal?.stage, .backedUp)
    }

    func testHealthyReferencedOpenCommitsJournal() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await saveDescriptor(at: fixture.paths, bindings: [])

        let session = try await makeSession(fixture)
        await session.close()

        let journal = try await domainJournal(fixture)
        XCTAssertEqual(journal?.stage, .committed)
    }

    // MARK: - Comparator

    func testEvaluateListsEveryFailedCheck() {
        let trackA = UUID()
        let trackB = UUID()
        let keptPlaylist = UUID()
        let droppedPlaylist = UUID()
        let keptDescriptor = UUID()
        let droppedDescriptor = UUID()
        let pre = kmgccc_player.ReferencedDomainMigrationValidator.Snapshot(
            trackCount: 2,
            playlistTrackIDs: [keptPlaylist: [trackA, trackB], droppedPlaylist: [trackB]],
            descriptorBindings: [keptDescriptor: [keptPlaylist], droppedDescriptor: [droppedPlaylist]],
            decodableLocatorTrackIDs: [trackA, trackB]
        )

        let failures = kmgccc_player.ReferencedDomainMigrationValidator.evaluate(
            pre: pre,
            postTrackCount: 1,
            postPlaylistOrders: [(id: keptPlaylist, trackIDs: [trackB, trackA])],
            postDescriptors: [(id: keptDescriptor, bindingPlaylistIDs: [UUID()])],
            postDecodableLocatorTrackIDs: [trackA]
        )

        XCTAssertEqual(failures.count, 6)
        XCTAssertTrue(failures.contains { $0.hasPrefix("trackCount(pre=2, post=1)") })
        XCTAssertTrue(failures.contains { $0.hasPrefix("playlistOrder(\(keptPlaylist.uuidString))") })
        XCTAssertTrue(failures.contains { $0.hasPrefix("playlistOrder(\(droppedPlaylist.uuidString))") })
        XCTAssertTrue(failures.contains { $0.hasPrefix("sourceDescriptorMissing(\(droppedDescriptor.uuidString))") })
        XCTAssertTrue(failures.contains { $0.hasPrefix("sourceBindings(\(keptDescriptor.uuidString))") })
        XCTAssertTrue(failures.contains { $0.hasPrefix("locatorIntegrity(count=1") })
    }

    func testEvaluatePassesMatchingState() {
        let trackA = UUID()
        let playlist = UUID()
        let descriptor = UUID()
        let pre = kmgccc_player.ReferencedDomainMigrationValidator.Snapshot(
            trackCount: 1,
            playlistTrackIDs: [playlist: [trackA]],
            descriptorBindings: [descriptor: [playlist]],
            decodableLocatorTrackIDs: [trackA]
        )

        let failures = kmgccc_player.ReferencedDomainMigrationValidator.evaluate(
            pre: pre,
            postTrackCount: 1,
            postPlaylistOrders: [(id: playlist, trackIDs: [trackA])],
            postDescriptors: [(id: descriptor, bindingPlaylistIDs: [playlist])],
            postDecodableLocatorTrackIDs: [trackA]
        )

        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: - Fixture

    private func makeFixture() throws -> (
        root: URL,
        paths: kmgccc_player.LibraryPaths,
        context: kmgccc_player.LibraryContext,
        cleanup: () -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("domain-migration-tests-\(UUID().uuidString)", isDirectory: true)
        let paths = kmgccc_player.LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
        let manifest = kmgccc_player.MusicLibraryManifest(displayName: "Referenced", mode: .referenced)
        try manifest.write(to: paths.manifestURL)
        let context = kmgccc_player.LibraryContext(
            manifest: manifest,
            rootURL: root,
            rootBookmarkData: Data("root".utf8),
            generation: 1
        )
        return (root, paths, context, { try? FileManager.default.removeItem(at: root) })
    }

    private func saveDescriptor(
        at paths: kmgccc_player.LibraryPaths,
        bindings: [kmgccc_player.ReferencedPlaylistSourceBinding]
    ) async throws {
        let store = kmgccc_player.ReferencedSourceStore(paths: paths)
        try await store.save(kmgccc_player.ReferencedSourceDescriptor(
            rootBookmarkData: Data("good".utf8),
            lastKnownPath: paths.rootURL.path,
            displayName: "Good",
            playlistBindings: bindings
        ))
    }

    private func makeSession(
        _ fixture: (
            root: URL,
            paths: kmgccc_player.LibraryPaths,
            context: kmgccc_player.LibraryContext,
            cleanup: () -> Void
        )
    ) async throws -> any kmgccc_player.LibrarySessionLifecycle {
        try await kmgccc_player.LibrarySessionFactory(
            sourceBookmarkResolver: StaticSourceBookmarkResolver(url: fixture.root)
        ).makeSession(for: fixture.context)
    }

    private func domainJournal(
        _ fixture: (
            root: URL,
            paths: kmgccc_player.LibraryPaths,
            context: kmgccc_player.LibraryContext,
            cleanup: () -> Void
        )
    ) async throws -> kmgccc_player.ReferencedLibraryDomainMigrationJournal? {
        try await kmgccc_player.ReferencedLibraryDomainMigration(
            paths: fixture.paths,
            libraryID: fixture.context.id
        ).journal()
    }
}
