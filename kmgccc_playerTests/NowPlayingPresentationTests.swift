import XCTest
@testable import kmgccc_player

@MainActor
final class NowPlayingPresentationTests: XCTestCase {
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
}
