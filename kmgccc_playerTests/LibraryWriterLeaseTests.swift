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

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-lease-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
