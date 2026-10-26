import XCTest
@testable import kmgccc_player

final class AutomaticCoverLookupTests: XCTestCase {
    private func candidate(_ id: String, source: CoverSource = .appleMusic, confidence: Double = 0.9,
                           width: Int = 1200, height: Int = 1200) -> CoverCandidate {
        CoverCandidate(imageData: Data(id.utf8), source: source, sourceItemId: id,
                       width: width, height: height, confidence: confidence)
    }

    func testMatchThenSquareResolutionThenApplePriority() {
        let exactSmall = candidate("exact", source: .qqmusic, confidence: 0.99, width: 600, height: 600)
        let lessMatchedLarge = candidate("large", confidence: 0.80, width: 3000, height: 3000)
        XCTAssertEqual(CoverCandidateSorter.sorted([lessMatchedLarge, exactSmall]).first, exactSmall)
        let apple = candidate("apple")
        let other = candidate("other", source: .netease)
        XCTAssertEqual(CoverCandidateSorter.sorted([other, apple]).first, apple)
        let larger = candidate("larger", source: .qqmusic, width: 1600, height: 1600)
        XCTAssertEqual(CoverCandidateSorter.sorted([apple, larger]).first, larger)
        XCTAssertEqual(CoverSource.netease.defaultConfidence, CoverSource.qqmusic.defaultConfidence)
        XCTAssertEqual(CoverSource.sacad.priority, CoverSource.netease.priority)
    }

    func testNetEaseRetainsOriginalURLAndOtherQueryParameters() {
        XCTAssertEqual(NetEaseCoverService.makeLargeCoverURLString(from: "https://example.test/cover.jpg"), "https://example.test/cover.jpg")
        XCTAssertEqual(NetEaseCoverService.makeLargeCoverURLString(from: "https://example.test/cover.jpg?param=1200y1200&v=2"), "https://example.test/cover.jpg?v=2")
    }

    func testSmallCoverWaitsForOtherProvidersAndBannerDoesNotEndSearch() async throws {
        let low = candidate("low", confidence: 0.99, width: 600, height: 600)
        let banner = candidate("banner", confidence: 0.99, width: 2000, height: 400)
        let high = candidate("high", source: .qqmusic, confidence: 0.92)
        let selected = try await AutomaticCoverLookup.select(providers: [
            .init(source: .appleMusic, timeout: 2, search: { [low, banner] in [low, banner] }),
            .init(source: .qqmusic, timeout: 2, search: { [high] in [high] })
        ], fallbackDelay: .milliseconds(10))
        XCTAssertEqual(selected, high)
    }

    func testHighResolutionResultCancelsDelayedFallback() async throws {
        let high = candidate("high")
        let calls = CoverLookupCallCounter()
        let selected = try await AutomaticCoverLookup.select(providers: [
            .init(source: .appleMusic, timeout: 2, search: { [high] in [high] }),
            .init(source: .qqmusic, timeout: 2, search: { await calls.increment(); return [] })
        ], fallbackDelay: .seconds(30))
        XCTAssertEqual(selected, high)
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testLowResolutionFallbackStillUsesMatchBeforePixels() async throws {
        let matched = candidate("matched", source: .qqmusic, confidence: 0.99, width: 600, height: 600)
        let larger = candidate("larger", confidence: 0.8, width: 1000, height: 1000)
        let selected = try await AutomaticCoverLookup.select(providers: [
            .init(source: .appleMusic, timeout: 2, search: { [larger] in [larger] }),
            .init(source: .qqmusic, timeout: 2, search: { [matched] in [matched] })
        ], fallbackDelay: .zero)
        XCTAssertEqual(selected, matched)
    }

    func testFailureIsNotRecordedAsAnEmptySuccessfulSearch() async {
        do {
            _ = try await AutomaticCoverLookup.select(providers: [
                .init(source: .appleMusic, timeout: 2, search: { throw URLError(.notConnectedToInternet) })
            ])
            XCTFail("A transient failure must remain retryable")
        } catch { XCTAssertFalse(error is CancellationError) }
    }
}

private actor CoverLookupCallCounter {
    var count = 0
    func increment() { count += 1 }
}
