import AVFoundation
import SwiftData
import XCTest
@testable import kmgccc_player

private final class SpyDigestHasher: kmgccc_player.ContentDigestHashing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let digest: String

    init(digest: String) { self.digest = digest }

    var callCount: Int { lock.withLock { count } }

    func hexContentDigest(of url: URL) async throws -> String {
        lock.withLock { count += 1 }
        return digest
    }
}

@MainActor
final class TrackIdentityResolverTests: XCTestCase {
    // MARK: - Unified fingerprint predicate

    func testUnifiedExactFingerprintPredicateAgreesAcrossRegistryMarkerStoreAndResolver() {
        let stable = kmgccc_player.ReferencedFileIdentity(
            volumeUUID: "VOL-1",
            resourceIdentifierArchive: Data("inode-1".utf8)
        )
        let sameSizeSameTime: Double = 1_000
        let stableA = kmgccc_player.ReferencedFileFingerprint(
            identity: stable, fileSize: 100, modifiedAt: sameSizeSameTime
        )
        let stableATouched = kmgccc_player.ReferencedFileFingerprint(
            identity: stable, fileSize: 100, modifiedAt: 2_000
        )
        let unstableA = kmgccc_player.ReferencedFileFingerprint(
            identity: nil, fileSize: 100, modifiedAt: sameSizeSameTime
        )
        let unstableB = kmgccc_player.ReferencedFileFingerprint(
            identity: nil, fileSize: 100, modifiedAt: sameSizeSameTime
        )
        let unstableOtherSize = kmgccc_player.ReferencedFileFingerprint(
            identity: nil, fileSize: 200, modifiedAt: sameSizeSameTime
        )

        let cases: [(kmgccc_player.ReferencedFileFingerprint, kmgccc_player.ReferencedFileFingerprint, Bool)] = [
            (stableA, stableA, true),
            (stableA, stableATouched, false),
            (stableA, unstableA, false),
            (unstableA, unstableB, true),
            (unstableA, unstableOtherSize, false),
        ]

        for (lhs, rhs, expected) in cases {
            XCTAssertEqual(
                kmgccc_player.NCMConversionRegistry.sameFingerprint(lhs, rhs),
                expected,
                "registry predicate diverged for \(lhs) vs \(rhs)"
            )
            XCTAssertEqual(
                kmgccc_player.NCMGeneratedOutputMarkerStore.sameExactFingerprint(lhs, rhs),
                expected,
                "marker-store predicate diverged for \(lhs) vs \(rhs)"
            )
            XCTAssertEqual(
                kmgccc_player.TrackIdentityResolver.sameExactFingerprint(lhs, rhs),
                expected,
                "resolver predicate diverged for \(lhs) vs \(rhs)"
            )
        }
    }

    func testPhysicalIdentityKeySemanticsPreservedThroughResolver() {
        let identity = kmgccc_player.ReferencedFileIdentity(
            volumeUUID: "VOL-1",
            resourceIdentifierArchive: Data("inode-1".utf8)
        )
        let stableTouched = kmgccc_player.ReferencedFileFingerprint(
            identity: identity, fileSize: 100, modifiedAt: 1_000
        )
        let stableRestated = kmgccc_player.ReferencedFileFingerprint(
            identity: identity, fileSize: 100, modifiedAt: 9_000
        )
        let fallbackSameState = kmgccc_player.ReferencedFileFingerprint(
            identity: nil, fileSize: 100, modifiedAt: 1_000
        )

        XCTAssertTrue(kmgccc_player.TrackIdentityResolver.samePhysicalIdentity(stableTouched, stableRestated))
        XCTAssertFalse(kmgccc_player.TrackIdentityResolver.samePhysicalIdentity(stableTouched, fallbackSameState))
    }

    // MARK: - Similarity classification

    func testSimilarityClassificationSuggestsButNeverMatches() {
        let candidates = [
            kmgccc_player.SimilarityCandidate(trackID: UUID(), duration: 180.2),
            kmgccc_player.SimilarityCandidate(trackID: UUID(), duration: 181.4),
        ]

        let classification = kmgccc_player.TrackIdentityResolver.classifyMetadataSimilarity(
            dedupKey: "song•artist",
            incomingDuration: 180.0,
            candidates: candidates
        )
        guard case let .possibleDuplicate(ids) = classification else {
            return XCTFail("expected possibleDuplicate suggestion")
        }
        XCTAssertEqual(ids, [candidates[0].trackID])

        XCTAssertEqual(
            kmgccc_player.TrackIdentityResolver.classifyMetadataSimilarity(
                dedupKey: "song•artist",
                incomingDuration: 0,
                candidates: candidates
            ),
            .none,
            "unknown durations must never match"
        )
        XCTAssertEqual(
            kmgccc_player.TrackIdentityResolver.classifyMetadataSimilarity(
                dedupKey: "song•artist",
                incomingDuration: 190,
                candidates: candidates
            ),
            .none
        )
    }

    // MARK: - Digest tier laziness

    func testDigestTierRunsOnlyAfterCheaperTiersMissAndMemoizesPerSession() async {
        let hasher = SpyDigestHasher(digest: String(repeating: "ab", count: 32))
        let resolver = kmgccc_player.TrackIdentityResolver(hasher: hasher)

        let stableIdentity = kmgccc_player.ReferencedFileIdentity(
            volumeUUID: "VOL-1", resourceIdentifierArchive: Data("inode-1".utf8)
        )
        let locationID = UUID()
        let incomingURL = URL(fileURLWithPath: "/tmp/incoming-copy.wav")

        // Stable identity tier: same volume+resource identity on both sides,
        // differing mtime must not matter.
        let stableCandidate = kmgccc_player.ReferencedTrackCandidate(
            trackID: UUID(),
            locations: [
                kmgccc_player.ReferencedLocationSnapshot(
                    id: UUID(),
                    fingerprint: kmgccc_player.ReferencedFileFingerprint(
                        identity: stableIdentity, fileSize: 100, modifiedAt: 5_000
                    ),
                    ncmSourceIdentity: nil,
                    contentDigest: nil,
                    lastKnownPath: "/tmp/does-not-exist.wav"
                )
            ]
        )
        let stableResolution = await resolver.resolveReferencedMatch(
            incomingFingerprint: kmgccc_player.ReferencedFileFingerprint(
                identity: stableIdentity, fileSize: 100, modifiedAt: 6_000
            ),
            incomingURL: incomingURL,
            candidates: [stableCandidate]
        )
        XCTAssertEqual(
            stableResolution.resolution,
            .matched(trackID: stableCandidate.trackID, tier: .stableIdentity)
        )
        XCTAssertEqual(hasher.callCount, 0, "stable identity tier must not hash")

        // Saved fingerprint tier: both sides unstable, size+mtime equality.
        let fallbackCandidate = kmgccc_player.ReferencedTrackCandidate(
            trackID: UUID(),
            locations: [
                kmgccc_player.ReferencedLocationSnapshot(
                    id: UUID(),
                    fingerprint: kmgccc_player.ReferencedFileFingerprint(
                        identity: nil, fileSize: 100, modifiedAt: 5_000
                    ),
                    ncmSourceIdentity: nil,
                    contentDigest: nil,
                    lastKnownPath: "/tmp/does-not-exist.wav"
                )
            ]
        )
        let fallbackResolution = await resolver.resolveReferencedMatch(
            incomingFingerprint: kmgccc_player.ReferencedFileFingerprint(
                identity: nil, fileSize: 100, modifiedAt: 5_000
            ),
            incomingURL: incomingURL,
            candidates: [fallbackCandidate]
        )
        XCTAssertEqual(
            fallbackResolution.resolution,
            .matched(trackID: fallbackCandidate.trackID, tier: .savedFingerprint)
        )
        XCTAssertEqual(hasher.callCount, 0, "saved fingerprint tier must not hash")

        // Digest tier: fingerprints miss, only size matches, hashing kicks in.
        let digestCandidate = kmgccc_player.ReferencedTrackCandidate(
            trackID: UUID(),
            locations: [
                kmgccc_player.ReferencedLocationSnapshot(
                    id: locationID,
                    fingerprint: kmgccc_player.ReferencedFileFingerprint(
                        identity: nil, fileSize: 100, modifiedAt: 5_000
                    ),
                    ncmSourceIdentity: nil,
                    contentDigest: nil,
                    lastKnownPath: "/tmp/does-not-exist.wav"
                )
            ]
        )
        let digestIncoming = kmgccc_player.ReferencedFileFingerprint(
            identity: nil, fileSize: 100, modifiedAt: 7_777
        )
        let digestResolution = await resolver.resolveReferencedMatch(
            incomingFingerprint: digestIncoming,
            incomingURL: incomingURL,
            candidates: [digestCandidate]
        )
        XCTAssertEqual(
            digestResolution.resolution,
            .matched(trackID: digestCandidate.trackID, tier: .contentDigest)
        )
        XCTAssertEqual(hasher.callCount, 2, "digest tier hashes incoming + candidate exactly once each")
        XCTAssertEqual(digestResolution.computedDigests[locationID], hasher.digest)

        await resolver.resolveReferencedMatch(
            incomingFingerprint: digestIncoming,
            incomingURL: incomingURL,
            candidates: [digestCandidate]
        )
        XCTAssertEqual(
            hasher.callCount, 2,
            "repeated comparisons within a session must reuse the memo"
        )
    }

    func testStoredDigestFastPathAvoidsRehashingCandidate() async {
        let digest = String(repeating: "cd", count: 32)
        let hasher = SpyDigestHasher(digest: digest)
        let resolver = kmgccc_player.TrackIdentityResolver(hasher: hasher)

        let candidate = kmgccc_player.ReferencedTrackCandidate(
            trackID: UUID(),
            locations: [
                kmgccc_player.ReferencedLocationSnapshot(
                    id: UUID(),
                    fingerprint: kmgccc_player.ReferencedFileFingerprint(
                        identity: nil, fileSize: 100, modifiedAt: 5_000
                    ),
                    ncmSourceIdentity: nil,
                    contentDigest: digest,
                    lastKnownPath: "/tmp/stored-digest-location.wav"
                )
            ]
        )

        let result = await resolver.resolveReferencedMatch(
            incomingFingerprint: kmgccc_player.ReferencedFileFingerprint(
                identity: nil, fileSize: 100, modifiedAt: 7_777
            ),
            incomingURL: URL(fileURLWithPath: "/tmp/incoming.wav"),
            candidates: [candidate]
        )
        XCTAssertEqual(result.resolution, .matched(trackID: candidate.trackID, tier: .contentDigest))
        XCTAssertEqual(hasher.callCount, 1, "stored candidate digest must be reused without re-hashing")
        XCTAssertTrue(result.computedDigests.isEmpty)
    }

    func testAmbiguousDigestHitsNeverGuess() async throws {
        let digest = String(repeating: "ef", count: 32)
        let hasher = SpyDigestHasher(digest: digest)
        let resolver = kmgccc_player.TrackIdentityResolver(hasher: hasher)

        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstCopy = dir.appendingPathComponent("a.wav")
        let secondCopy = dir.appendingPathComponent("b.wav")
        try Data(repeating: 0x42, count: 128).write(to: firstCopy)
        try FileManager.default.copyItem(at: firstCopy, to: secondCopy)

        let trackA = UUID()
        let trackB = UUID()
        let size = Int64(try Data(contentsOf: firstCopy).count)
        let candidates = [trackA, trackB].map { trackID in
            kmgccc_player.ReferencedTrackCandidate(
                trackID: trackID,
                locations: [
                    kmgccc_player.ReferencedLocationSnapshot(
                        id: UUID(),
                        fingerprint: kmgccc_player.ReferencedFileFingerprint(
                            identity: nil, fileSize: size, modifiedAt: 1_000
                        ),
                        ncmSourceIdentity: nil,
                        contentDigest: nil,
                        lastKnownPath: trackID == trackA ? firstCopy.path : secondCopy.path
                    )
                ]
            )
        }

        let result = await resolver.resolveReferencedMatch(
            incomingFingerprint: kmgccc_player.ReferencedFileFingerprint(
                identity: nil, fileSize: size, modifiedAt: 2_000
            ),
            incomingURL: firstCopy,
            candidates: candidates
        )
        XCTAssertEqual(result.resolution, .unmatched, "ambiguous digest hits must never guess")
        XCTAssertEqual(Set(result.ambiguousTrackIDs), Set([trackA, trackB]))
    }

    // MARK: - Cross-volume copy integration

    func testCrossVolumeCopyReusesExistingTrackViaDigestTierWithoutDuplicate() async throws {
        let fixture = try makeImportFixture(mode: .referenced)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceRoot = fixture.sourceRootA
        try writeWAV(to: sourceRoot.appendingPathComponent("Song.wav"))
        let imported = await fixture.importService.importAutomatically([sourceRoot])
        XCTAssertEqual(imported.count, 1)

        let otherRoot = fixture.sourceRootB
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let copyURL = otherRoot.appendingPathComponent("Copy.wav")
        try FileManager.default.copyItem(
            at: sourceRoot.appendingPathComponent("Song.wav"),
            to: copyURL
        )

        let secondRun = await fixture.importService.importAutomatically([otherRoot])
        XCTAssertEqual(secondRun.count, 1, "byte-identical copy must reuse the existing track")
        XCTAssertEqual(secondRun.first?.id, imported.first?.id)

        let allTracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(allTracks.count, 1, "cross-volume copy must not create a duplicate track")
        let locator = try XCTUnwrap(allTracks[0].mediaLocator.referencedFile)
        XCTAssertEqual(locator.locations.count, 2)
        let digests = locator.locations.compactMap(\.contentDigest)
        XCTAssertEqual(digests.count, 2, "computed digests must persist on both locations")
        XCTAssertEqual(Set(digests).count, 1)

        await fixture.close()
    }

    // MARK: - Managed rename re-import

    func testManagedRenameReimportDedupesViaProvenance() async throws {
        let fixture = try makeImportFixture(mode: .managed)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let originalURL = fixture.sourceRootA.appendingPathComponent("Song.wav")
        try writeWAV(to: originalURL)
        let firstRun = await fixture.importService.importAutomatically([fixture.sourceRootA])
        XCTAssertEqual(firstRun.count, 1)
        let provenance = try XCTUnwrap(firstRun[0].importProvenance)
        XCTAssertNotNil(provenance.originalFingerprint)
        XCTAssertNil(provenance.contentDigest, "digest must stay lazy at import commit time")

        let renamedURL = fixture.sourceRootA.appendingPathComponent("Renamed.wav")
        try FileManager.default.moveItem(at: originalURL, to: renamedURL)

        let secondRun = await fixture.importService.importAutomatically([fixture.sourceRootA])
        XCTAssertEqual(secondRun.count, 1, "renamed re-import must dedupe via provenance")
        XCTAssertEqual(secondRun.first?.id, firstRun[0].id)

        let allTracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(allTracks.count, 1, "renamed re-import must not create a duplicate track")

        await fixture.close()
    }

    // MARK: - Automatic-mode invariant

    func testAutomaticModeImportsSimilarityCandidateAsNewTrack() async throws {
        let fixture = try makeImportFixture(mode: .referenced)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Different frame counts keep the bytes (and thus digests) distinct
        // while staying inside the 0.5s duration tolerance, isolating the
        // metadata-similarity path from the digest tier.
        try writeWAV(to: fixture.sourceRootA.appendingPathComponent("SameName.wav"), frameCount: 4_410)
        try writeWAV(to: fixture.sourceRootB.appendingPathComponent("SameName.wav"), frameCount: 8_820)

        let firstRun = await fixture.importService.importAutomatically([fixture.sourceRootA])
        XCTAssertEqual(firstRun.count, 1)

        let secondRun = await fixture.importService.importAutomatically([fixture.sourceRootB])
        XCTAssertEqual(secondRun.count, 1, "similarity-only match is still imported as a new track")
        XCTAssertNotEqual(secondRun.first?.id, firstRun.first?.id)

        let allTracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(allTracks.count, 2, "similarity must never merge tracks")
        XCTAssertEqual(
            Set(allTracks.map { kmgccc_player.LibraryNormalization.normalizedDedupKey(title: $0.title, artist: $0.artist) }).count,
            1,
            "the two tracks share metadata and are only possible duplicates"
        )

        await fixture.close()
    }

    // MARK: - Sidecar round trip

    func testImportProvenanceRoundTripsThroughSidecarSchemaNine() throws {
        let sidecar = kmgccc_player.TrackSidecar(
            id: UUID(),
            title: "t",
            artist: "a",
            album: "al",
            duration: 12,
            addedAt: Date(timeIntervalSince1970: 100),
            importedAt: Date(timeIntervalSince1970: 100),
            lyricsTimeOffsetMs: nil,
            originalFilePath: nil,
            audioFileName: nil,
            artworkFileName: nil,
            lyricsFileName: nil,
            lyricsType: nil,
            ttmlLyricsFileName: nil,
            ncmSourcePath: nil,
            importProvenance: kmgccc_player.ImportProvenance(
                originalFingerprint: kmgccc_player.ReferencedFileFingerprint(
                    identity: nil, fileSize: 99, modifiedAt: 123.5
                ),
                contentDigest: "deadbeef"
            )
        )
        XCTAssertEqual(sidecar.schemaVersion, 9)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            kmgccc_player.TrackSidecar.self,
            from: encoder.encode(sidecar)
        )
        XCTAssertEqual(decoded.importProvenance?.contentDigest, "deadbeef")
        XCTAssertEqual(decoded.importProvenance?.originalFingerprint?.fileSize, 99)

        let legacyPayload = """
        {"schemaVersion":9,"id":"\(UUID().uuidString)","title":"t","artist":"a","album":"al",
        "duration":1,"addedAt":"2026-01-01T00:00:00Z",
        "mediaLocator":{"kind":"managed","managed":{"libraryRelativePath":"Tracks/x/audio.m4a"}}}
        """
        let legacy = try decoder.decode(kmgccc_player.TrackSidecar.self, from: Data(legacyPayload.utf8))
        XCTAssertNil(legacy.importProvenance, "older schema-9 payloads decode unchanged")
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeWAV(to url: URL, frameCount: AVAudioFrameCount = 4_410) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try audioFile.write(from: buffer)
    }

    @MainActor
    private func makeImportFixture(mode: MusicLibraryMode) throws -> ImportFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let sourceRootA = root.appendingPathComponent("SourceA", isDirectory: true)
        let sourceRootB = root.appendingPathComponent("SourceB", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRootB, withIntermediateDirectories: true)

        let paths = kmgccc_player.LibraryPaths(rootURL: libraryRoot)
        try paths.createRequiredDirectories()
        let libraryService = LocalLibraryService(
            paths: paths,
            preferenceStatsService: PreferenceStatsService()
        )
        let repository = SwiftDataLibraryRepository(libraryService: libraryService)
        let cache = LibraryCacheServices(paths: paths)
        let enrichment = ImportEnrichmentService(
            repository: repository,
            qqMusicCoverService: cache.qqMusicCoverService,
            artistArtworkProviderCoordinator: cache.artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: cache.lyricsSearchCoordinator,
            amllDBService: cache.amllDBService
        )
        let backend: any kmgccc_player.LibraryStorageBackend
        if mode == .managed {
            backend = ManagedLocalBackend(paths: paths)
        } else {
            backend = ReferencedLocalBackend(
                paths: paths,
                sourceStore: ReferencedSourceStore(paths: paths),
                sourceScope: ReferencedSourceScope(),
                bookmarkResolver: FixtureBookmarkResolver()
            )
        }
        let service = FileImportService(
            repository: repository,
            libraryService: libraryService,
            importEnrichmentService: enrichment,
            storageBackend: backend,
            operationCoordinator: LibraryOperationCoordinator(),
            qqMusicCoverService: cache.qqMusicCoverService,
            artistArtworkProviderCoordinator: cache.artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: cache.lyricsSearchCoordinator,
            amllDBService: cache.amllDBService
        )
        return ImportFixture(
            root: root,
            sourceRootA: sourceRootA,
            sourceRootB: sourceRootB,
            repository: repository,
            importService: service,
            enrichment: enrichment,
            backend: backend,
            cache: cache
        )
    }
}

@MainActor
private struct ImportFixture {
    let root: URL
    let sourceRootA: URL
    let sourceRootB: URL
    let repository: SwiftDataLibraryRepository
    let importService: FileImportService
    let enrichment: ImportEnrichmentService
    let backend: any kmgccc_player.LibraryStorageBackend
    let cache: LibraryCacheServices

    func close() async {
        await enrichment.cancelEnrichment(for: [])
        await backend.close()
        await cache.close()
    }
}

private final class FixtureBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
    func refreshBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func startAccessing(_: URL) -> Bool { true }
    func stopAccessing(_: URL) {}
}
