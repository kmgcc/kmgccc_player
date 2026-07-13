import Foundation
import XCTest

final class MetadataMatchScorerTests: XCTestCase {
    private func titleAccepted(_ query: String, _ candidate: String) -> Bool {
        ExternalPlaybackTextNormalizer.titleAccepted(query: query, candidate: candidate)
    }

    private func titleScore(_ query: String, _ candidate: String) -> Double {
        ExternalPlaybackTextNormalizer.stringSimilarity(
            ExternalPlaybackTextNormalizer.normalize(query),
            ExternalPlaybackTextNormalizer.normalize(candidate)
        )
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        ExternalPlaybackTextNormalizer.levenshteinDistance(
            ExternalPlaybackTextNormalizer.normalize(lhs).compact,
            ExternalPlaybackTextNormalizer.normalize(rhs).compact
        )
    }

    func testColorsDoesNotMatchCloser() {
        XCTAssertFalse(titleAccepted("Colors", "Closer"))
        XCTAssertLessThan(
            titleScore("Colors", "Closer"),
            ExternalPlaybackTextNormalizer.shortTitleFuzzyFloor
        )
    }

    func testExactTitleMatch() {
        XCTAssertTrue(titleAccepted("Colors", "Colors"))
    }

    func testVersionSuffixVariants() {
        let cases = [
            "Colors - Single",
            "Colors (Stripped)",
            "Colors (Live)",
            "Colors (Acoustic)",
            "Colors (Remastered)",
            "Colors (Deluxe Edition)",
        ]
        for candidate in cases {
            XCTAssertTrue(titleAccepted("Colors", candidate), candidate)
        }
    }

    func testArtistTypoTolerance() {
        XCTAssertTrue(titleAccepted("Colors", "Colors"))
        let source = ExternalPlaybackTextNormalizer.normalizeArtist("Halsy")
        let candidate = ExternalPlaybackTextNormalizer.normalizeArtist("Halsey")
        XCTAssertGreaterThanOrEqual(
            ExternalPlaybackTextNormalizer.artistSimilarity(source, candidate),
            0.80
        )
    }

    func testShortTitleConflicts() {
        let cases = [
            ("Stay", "Star"),
            ("Home", "Hope"),
            ("Hello", "Holla"),
            ("Light", "Night"),
            ("Flame", "Frame"),
            ("Yours", "Hours"),
            ("Sorry", "Story"),
        ]
        for (query, candidate) in cases {
            XCTAssertFalse(
                titleAccepted(query, candidate),
                "edit distance: \(editDistance(query, candidate))"
            )
        }
    }

    func testExactTitleWithMinorArtistDifference() {
        XCTAssertTrue(titleAccepted("Colors", "Colors"))
    }

    func testDifferentTitleWithExactArtist() {
        XCTAssertFalse(titleAccepted("Colors", "Closer"))
        XCTAssertFalse(titleAccepted("Stay", "Star"))
    }

    func testFeaturingTextIsIgnored() {
        XCTAssertTrue(titleAccepted("Colors feat. SZA", "Colors"))
        XCTAssertTrue(titleAccepted("Colors", "Colors ft. SZA"))
        XCTAssertTrue(titleAccepted("Colors featuring SZA", "Colors"))
    }

    func testVersionMarkersDoNotHideDifferentCoreTitles() {
        XCTAssertTrue(titleAccepted("Colors", "Colors (Acoustic Version)"))
        XCTAssertTrue(titleAccepted("Colors", "Colors - Live"))
        XCTAssertFalse(titleAccepted("Colors", "Closer (Remix)"))
    }

    func testOneEditNearVariants() {
        XCTAssertTrue(titleAccepted("Color", "Colour"))
        XCTAssertTrue(titleAccepted("Colors", "Colours"))
    }
}
