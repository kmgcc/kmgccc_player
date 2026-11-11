import Darwin
import XCTest
@testable import kmgccc_player

@MainActor
final class LibraryWriterLeaseTests: XCTestCase {
    func testSecondWriterIsRejectedUntilLeaseReleases() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = kmgccc_player.LibraryPaths(rootURL: root)

        let first = try LibraryWriterLease.acquire(paths: paths, processID: 101)
        XCTAssertThrowsError(try LibraryWriterLease.acquire(paths: paths, processID: 202)) { error in
            guard case LibraryWriterLeaseError.libraryInUse(paths.writerLockURL) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        first.release()
        let replacement = try LibraryWriterLease.acquire(paths: paths, processID: 303)
        replacement.release()
    }

    func testLockFileIsPrivateAndTransactionsAreRequiredDirectories() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = kmgccc_player.LibraryPaths(rootURL: root)

        let lease = try LibraryWriterLease.acquire(paths: paths)
        defer { lease.release() }
        try paths.createRequiredDirectories()

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.writerLockURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingTransactionsRootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.completedTransactionsRootURL.path))
    }

    func testSymlinkAliasCannotOpenSameLibraryTwiceInOneProcess() throws {
        let container = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let realRoot = container.appendingPathComponent("real", isDirectory: true)
        let aliasRoot = container.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: realRoot)

        let lease = try LibraryWriterLease.acquire(
            paths: kmgccc_player.LibraryPaths(rootURL: realRoot)
        )
        defer { lease.release() }

        XCTAssertThrowsError(
            try LibraryWriterLease.acquire(
                paths: kmgccc_player.LibraryPaths(rootURL: aliasRoot)
            )
        ) { error in
            guard case LibraryWriterLeaseError.libraryInUse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testWriterLeaseFailureNeverCreatesAnAlternateDefaultLibrary() {
        let lockURL = URL(fileURLWithPath: "/tmp/library-writer.lock")
        let errors: [LibraryWriterLeaseError] = [
            .libraryInUse(lockURL),
            .writerLeaseUnsupported(lockURL),
            .cannotPrepareLockDirectory("denied"),
            .cannotOpenLockFile(lockURL.path, EACCES),
            .cannotWriteDiagnostic("full")
        ]

        for error in errors {
            XCTAssertFalse(
                LibraryStartupFailurePolicy.permitsFactoryDefaultFallback(after: error),
                "writer failure unexpectedly permitted fallback: \(error)"
            )
        }
        XCTAssertTrue(
            LibraryStartupFailurePolicy.permitsFactoryDefaultFallback(
                after: CocoaError(.fileReadCorruptFile)
            )
        )
    }

    func testMissingLibraryRootIsNotRecreatedForWriterLock() throws {
        let root = temporaryRoot().appendingPathComponent("missing", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertThrowsError(try LibraryWriterLease.acquire(paths: LibraryPaths(rootURL: root)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testWriterLockSymlinkDoesNotModifyItsTarget() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.settingsRootURL, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("user-file")
        let original = Data("preserve".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.writerLockURL, withDestinationURL: target)
        XCTAssertThrowsError(try LibraryWriterLease.acquire(paths: paths))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testSeparateOpenDescriptionHoldingTheKernelLockBlocksTheLease() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.settingsRootURL, withIntermediateDirectories: true)

        // BSD locks belong to the open file description, so this raw open
        // models a second App process holding the writer lock. The lease must
        // observe the kernel lock rather than only the in-process registry.
        let descriptor = Darwin.open(
            paths.writerLockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = Darwin.close(descriptor) }
        XCTAssertEqual(kmgccc_flock(descriptor, LOCK_EX | LOCK_NB), 0)

        XCTAssertThrowsError(try LibraryWriterLease.acquire(paths: paths)) { error in
            guard case LibraryWriterLeaseError.libraryInUse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(kmgccc_flock(descriptor, LOCK_UN), 0)
        let lease = try LibraryWriterLease.acquire(paths: paths)
        lease.release()
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-lease-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
