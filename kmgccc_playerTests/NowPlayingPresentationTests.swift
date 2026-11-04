import XCTest
@testable import kmgccc_player

@MainActor
final class NowPlayingPresentationTests: XCTestCase {
    func testLyricsClockStateParticipatesInPresentationEquality() {
        var preparing = NowPlayingPresentation.emptyLocal
        preparing.isPlaying = true
        preparing.lyricsIsPlaying = false
        var ready = preparing
        ready.lyricsIsPlaying = true

        XCTAssertFalse(preparing.effectiveLyricsIsPlaying)
        XCTAssertTrue(ready.effectiveLyricsIsPlaying)
        XCTAssertFalse(preparing.isEffectivelyEqualIgnoringCurrentTime(to: ready))
    }

    func testLocalArtworkFileTakesPrecedenceOverEnrichmentArtwork() {
        var presentation = NowPlayingPresentation.emptyLocal
        presentation.localArtworkFileURL = URL(fileURLWithPath: "/tmp/local-cover.jpg")

        XCTAssertFalse(presentation.canUseEnrichmentArtwork)

        presentation.localArtworkFileURL = nil
        XCTAssertTrue(presentation.canUseEnrichmentArtwork)

        presentation.artworkData = Data([1])
        XCTAssertFalse(presentation.canUseEnrichmentArtwork)

        presentation.source = .appleMusic
        presentation.artworkData = nil
        XCTAssertTrue(presentation.canUseEnrichmentArtwork)
    }

    func testPlaybackLyricsCacheKeyTracksEveryInputValue() {
        let trackID = UUID()
        let original = PlaybackLyricsCacheKey(
            trackID: trackID,
            lyricsText: "line lyrics",
            ttmlLyricText: "<tt>word lyrics</tt>",
            lyricsFileName: "lyrics.lrc",
            ttmlLyricsFileName: "lyrics.ttml"
        )

        XCTAssertEqual(
            original,
            PlaybackLyricsCacheKey(
                trackID: trackID,
                lyricsText: "line lyrics",
                ttmlLyricText: "<tt>word lyrics</tt>",
                lyricsFileName: "lyrics.lrc",
                ttmlLyricsFileName: "lyrics.ttml"
            )
        )
        XCTAssertNotEqual(original, PlaybackLyricsCacheKey(
            trackID: UUID(),
            lyricsText: "line lyrics",
            ttmlLyricText: "<tt>word lyrics</tt>",
            lyricsFileName: "lyrics.lrc",
            ttmlLyricsFileName: "lyrics.ttml"
        ))
        XCTAssertNotEqual(original, PlaybackLyricsCacheKey(
            trackID: trackID,
            lyricsText: "changed line lyrics",
            ttmlLyricText: "<tt>word lyrics</tt>",
            lyricsFileName: "lyrics.lrc",
            ttmlLyricsFileName: "lyrics.ttml"
        ))
        XCTAssertNotEqual(original, PlaybackLyricsCacheKey(
            trackID: trackID,
            lyricsText: "line lyrics",
            ttmlLyricText: "<tt>changed word lyrics</tt>",
            lyricsFileName: "lyrics.lrc",
            ttmlLyricsFileName: "lyrics.ttml"
        ))
        XCTAssertNotEqual(original, PlaybackLyricsCacheKey(
            trackID: trackID,
            lyricsText: "line lyrics",
            ttmlLyricText: "<tt>word lyrics</tt>",
            lyricsFileName: "new-lyrics.lrc",
            ttmlLyricsFileName: "lyrics.ttml"
        ))
        XCTAssertNotEqual(original, PlaybackLyricsCacheKey(
            trackID: trackID,
            lyricsText: "line lyrics",
            ttmlLyricText: "<tt>word lyrics</tt>",
            lyricsFileName: "lyrics.lrc",
            ttmlLyricsFileName: "new-lyrics.ttml"
        ))
    }

    func testTrackArtworkSourceKeyParticipatesInStableEquality() {
        var original = NowPlayingPresentation.emptyLocal
        original.artworkIdentity = "same-artwork"
        original.localArtworkSourceKey = "source-a"

        var updated = original
        updated.localArtworkSourceKey = "source-b"

        XCTAssertFalse(original.isEffectivelyEqualIgnoringCurrentTime(to: updated))
    }

    func testLocalArtworkFileURLParticipatesInStableEquality() {
        var original = NowPlayingPresentation.emptyLocal
        original.artworkIdentity = "same-artwork"
        original.localArtworkFileURL = URL(fileURLWithPath: "/tmp/cover-a.jpg")

        var updated = original
        updated.localArtworkFileURL = URL(fileURLWithPath: "/tmp/cover-b.jpg")

        XCTAssertFalse(original.isEffectivelyEqualIgnoringCurrentTime(to: updated))
    }

    func testArtworkDataChecksumFlowsIntoDisplayContextAndStableEquality() {
        var original = NowPlayingPresentation.emptyLocal
        original.artworkDataChecksum = 42

        XCTAssertEqual(original.displayContext.artworkDataChecksum, 42)

        var updated = original
        updated.artworkDataChecksum = 43
        XCTAssertFalse(original.isEffectivelyEqualIgnoringCurrentTime(to: updated))
    }

    func testSystemNowPlayingArtworkPayloadCacheReusesAndInvalidatesByEncoding() {
        var cache = SystemNowPlayingArtworkPayloadCache()
        let firstData = Data([1, 4, 9, 16])
        let firstEncoded = firstData.base64EncodedString()

        let first = cache.resolve(encoded: firstEncoded)
        XCTAssertEqual(first?.data, firstData)
        XCTAssertEqual(first?.checksum, ArtworkAssetStore.checksum(for: firstData))
        XCTAssertEqual(cache.resolve(encoded: firstEncoded), first)

        let secondData = Data([2, 4, 8, 16])
        let second = cache.resolve(encoded: secondData.base64EncodedString())
        XCTAssertEqual(second?.data, secondData)
        XCTAssertEqual(second?.checksum, ArtworkAssetStore.checksum(for: secondData))
        XCTAssertNotEqual(second?.checksum, first?.checksum)

        XCTAssertNil(cache.resolve(encoded: nil))
        XCTAssertNil(cache.resolve(encoded: ""))
    }

    func testSystemNowPlayingArtworkPayloadCacheInvalidBase64CanRecover() {
        var cache = SystemNowPlayingArtworkPayloadCache()

        let invalid = cache.resolve(encoded: "!!!")
        XCTAssertNotNil(invalid)
        XCTAssertNil(invalid?.data)
        XCTAssertNil(invalid?.checksum)
        XCTAssertEqual(cache.resolve(encoded: "!!!"), invalid)

        let validData = Data([3, 1, 4])
        let recovered = cache.resolve(encoded: validData.base64EncodedString())
        XCTAssertEqual(recovered?.data, validData)
        XCTAssertEqual(recovered?.checksum, ArtworkAssetStore.checksum(for: validData))
    }

    func testArtworkRenderingFallbackChecksumMatchesItsData() {
        let trackID = UUID()
        let data = ArtworkRenderingFallback.data(for: trackID)

        XCTAssertNotNil(data)
        XCTAssertEqual(
            ArtworkRenderingFallback.checksum(for: trackID),
            ArtworkAssetStore.checksum(for: data)
        )
    }

    func testMissingSidecarRetriesAreSpacedBetweenProgressTicks() {
        var retry = PlaybackSidecarRetryState()
        let key = PlaybackSidecarHydrationKey(
            trackID: UUID(), libraryRoot: "/tmp/library", ttmlURL: URL(fileURLWithPath: "/tmp/lyrics.ttml"), fallbackURL: nil
        )
        XCTAssertTrue(retry.begin(key, uptime: 100))
        for time in stride(from: 100.25, to: 105.0, by: 0.25) {
            XCTAssertFalse(retry.begin(key, uptime: time))
        }
        XCTAssertTrue(retry.begin(key, uptime: 105))
    }

    func testSidecarInputChangesCanRetryImmediately() {
        var retry = PlaybackSidecarRetryState()
        let trackID = UUID()
        let original = PlaybackSidecarHydrationKey(
            trackID: trackID, libraryRoot: "/tmp/first", ttmlURL: URL(fileURLWithPath: "/tmp/first/lyrics.ttml"), fallbackURL: nil
        )
        let replaced = PlaybackSidecarHydrationKey(
            trackID: trackID, libraryRoot: "/tmp/first", ttmlURL: URL(fileURLWithPath: "/tmp/first/replacement.ttml"), fallbackURL: nil
        )
        let otherLibrary = PlaybackSidecarHydrationKey(
            trackID: trackID, libraryRoot: "/tmp/second", ttmlURL: original.ttmlURL, fallbackURL: nil
        )
        XCTAssertTrue(retry.begin(original, uptime: 100))
        XCTAssertTrue(retry.begin(replaced, uptime: 100.25))
        XCTAssertTrue(retry.begin(otherLibrary, uptime: 100.5))
    }
}

@MainActor
final class SmartPlaybackQueueLookupTests: XCTestCase {
    func testShuffleCanBeEnabledAfterQueueBecomesEmpty() {
        let controller = makeController()
        controller.startPlayback(tracks: [Track(title: "Song")], startingAt: 0, shuffle: false)
        controller.updateQueue(tracks: [])
        controller.setShuffle(true)
        XCTAssertNil(controller.currentTrack)
        XCTAssertTrue(controller.getCurrentQueue().isEmpty)
        controller.stop()
    }

    func testShuffleLookupUsesRefreshedQueueObjects() {
        let controller = makeController()
        let original = Track(title: "Original")
        let other = Track(title: "Other")
        controller.startPlayback(tracks: [original, other], startingAt: 0, shuffle: true)
        let replacement = Track(id: original.id, title: "Updated")
        controller.updateQueue(tracks: [replacement, other])
        XCTAssertTrue(controller.currentTrack === replacement)
        XCTAssertTrue(controller.getCurrentQueue().first === replacement)
        controller.stop()
    }

    func testShuffleLookupRetainsFirstDuplicateObject() {
        let controller = makeController()
        let first = Track(title: "First")
        let duplicate = Track(id: first.id, title: "Duplicate")
        controller.startPlayback(tracks: [first, duplicate], startingAt: 0, shuffle: true)
        XCTAssertTrue(controller.currentTrack === first)
        XCTAssertTrue(controller.getCurrentQueue().allSatisfy { $0 === first })
        controller.stop()
    }

    private func makeController() -> SmartPlaybackController {
        let preferences = PreferenceStatsService()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = LocalLibraryService(paths: LibraryPaths(rootURL: root), preferenceStatsService: preferences)
        return SmartPlaybackController(
            playbackHistoryStore: .inMemory(), preferenceStatsService: preferences, libraryService: library
        )
    }
}
