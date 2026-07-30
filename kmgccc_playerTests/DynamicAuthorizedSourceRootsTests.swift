import Foundation
@testable import kmgccc_player
import XCTest

private final class LeaseStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@MainActor
final class DynamicAuthorizedSourceRootsTests: XCTestCase {
    func testPlaybackRequestSeesSourceAddedAfterServiceInitAndCloseClearsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceID = UUID()
        let songURL = root.appendingPathComponent("song.mp3")
        try Data("audio".utf8).write(to: songURL)
        let stopCounter = LeaseStopCounter()
        let lease = SecurityScopedResourceLease { stopCounter.increment() }
        let scope = ReferencedSourceScope()
        let paths = LibraryPaths(rootURL: root)
        let preferenceStatsService = PreferenceStatsService()
        let libraryService = LocalLibraryService(
            paths: paths,
            preferenceStatsService: preferenceStatsService
        )
        let smartController = SmartPlaybackController(
            playbackHistoryStore: .inMemory(),
            preferenceStatsService: preferenceStatsService,
            libraryService: libraryService
        )
        let service = AVAudioPlaybackService(
            smartController: smartController,
            libraryPaths: paths,
            authorizedSourceRootsProvider: scope.rootsProvider
        )
        let track = Track(
            title: "Track",
            fileBookmarkData: Data("bookmark".utf8),
            mediaLocator: .referenced(ReferencedFileLocator(
                fileBookmarkData: Data("bookmark".utf8),
                sourceMemberships: [.init(sourceID: sourceID, relativePath: "song.mp3")],
                primarySourceID: sourceID,
                lastKnownPath: root.appendingPathComponent("song.mp3").path
            )),
            libraryRootSnapshot: root.path
        )

        XCTAssertTrue(service.makePrepRequest(for: track).authorizedSourceRoots.isEmpty)
        scope.add(sourceID: sourceID, url: root, lease: lease)
        let request = service.makePrepRequest(for: track)
        XCTAssertEqual(request.authorizedSourceRoots[sourceID]?.url, root)
        let resolution = try LocalAudioResourceResolver(
            paths: request.libraryPaths,
            authorizedSourceRoots: request.authorizedSourceRoots
        ).resolve(request.locator)
        XCTAssertEqual(resolution.url, songURL)
        resolution.lease.release()

        scope.close()
        XCTAssertTrue(service.makePrepRequest(for: track).authorizedSourceRoots.isEmpty)
        XCTAssertEqual(stopCounter.count, 1)
        scope.close()
        XCTAssertEqual(stopCounter.count, 1)
    }
}
