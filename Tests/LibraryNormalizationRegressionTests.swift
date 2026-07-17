//
//  LibraryNormalizationRegressionTests.swift
//  myPlayer2
//
//  Standalone regression checks for artist collaboration grouping.
//  Run with:
//    swiftc -parse-as-library kmgccc_player/Services/Library/LibraryNormalization.swift Tests/LibraryNormalizationRegressionTests.swift -o /tmp/library_normalization_regression && /tmp/library_normalization_regression
//

import Foundation

// Minimal stand-ins keep this regression check independent from the full
// SwiftData/AppKit application target.
struct AlbumSection {
    let key: String
    let name: String
    let artistName: String
    let artistCanonicalName: String
    let memberArtistCanonicalNames: [String]
    let trackCount: Int
}

final class Track {
    let id = UUID()
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist: String?
}

@main
struct LibraryNormalizationRegressionTests {
    static func main() {
        expectComponents("福梦, Marz23", ["福梦", "Marz23"])
        expectComponents("吴青峰, AURORA", ["吴青峰", "AURORA"])

        let fumengKey = LibraryNormalization.normalizeArtist("福梦")
        expect(
            LibraryNormalization.containsArtist(fumengKey, in: "福梦, Marz23"),
            "Expected the first artist to match a comma-separated collaboration"
        )

        let renamed = LibraryNormalization.replacingArtistComponent(
            in: "福梦, Marz23",
            matching: fumengKey,
            with: "Fumeng"
        )
        expect(renamed == "Fumeng, Marz23", "Expected comma-separated artist replacement to preserve the other artist")
        print("LibraryNormalizationRegressionTests passed")
    }

    private static func expectComponents(_ value: String, _ expected: [String]) {
        let actual = LibraryNormalization.artistComponents(value).map { $0.displayName }
        expect(actual == expected, "Expected \(value) to split as \(expected), got \(actual)")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard !condition else { return }
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
