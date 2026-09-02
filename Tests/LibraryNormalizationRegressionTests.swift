//
//  LibraryNormalizationRegressionTests.swift
//  myPlayer2
//
//  Standalone regression checks for artist collaboration grouping and the
//  §10.3 album-identity key composition.
//  Run with:
//    Tests/run_library_normalization_regression.sh
//

import Foundation

// Minimal stand-ins keep this regression check independent from the full
// SwiftData/AppKit application target. They mirror only the members
// LibraryNormalization actually reads.
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
    var artistCredits: [TrackCredit] = []
    var musicBrainzReleaseID: String?
    var embeddedReleaseYear: Int?
    var embeddedCompilation: Bool?
}

// Logging shim so LibraryNormalization.swift compiles outside the app target.
enum LogCategory {
    case library
}

enum Log {
    static func error(_ message: @autoclosure () -> String, category: LogCategory) {}
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

        expectAlbumKeyContract()
        print("LibraryNormalizationRegressionTests passed")
    }

    // §10.3 evidence ordering for composeAlbumKey. Default parameters must
    // keep every legacy caller byte-compatible; explicit evidence must win in
    // the documented priority (mbid > year > folder).
    private static func expectAlbumKeyContract() {
        let base = LibraryNormalization.composeAlbumKey(album: "Greatest Hits")
        expect(
            base == LibraryNormalization.normalizedAlbumKey(album: "Greatest Hits"),
            "Expected default parameters to keep the plain normalized album key"
        )

        let mbidKey = LibraryNormalization.composeAlbumKey(
            album: "Greatest Hits",
            musicBrainzReleaseID: "4d1c8a54-9f61-4e0b-9d5f-3f7c2b1a0e99"
        )
        expect(
            mbidKey.hasSuffix("•mbid:4d1c8a54-9f61-4e0b-9d5f-3f7c2b1a0e99"),
            "Expected the MusicBrainz release id to dominate the composed key"
        )
        expect(
            LibraryNormalization.composeAlbumKey(
                album: "Greatest Hits",
                musicBrainzReleaseID: "4d1c8a54-9f61-4e0b-9d5f-3f7c2b1a0e99",
                releaseYear: 1998,
                folderHint: "/Volumes/A"
            ) == mbidKey,
            "Expected the MusicBrainz release id to suppress year and folder hints"
        )

        let yearKey = LibraryNormalization.composeAlbumKey(album: "Greatest Hits", releaseYear: 1998)
        expect(yearKey.hasSuffix("•year:1998"), "Expected a year disambiguation suffix when no album artist exists")
        expect(
            LibraryNormalization.composeAlbumKey(album: "Greatest Hits", releaseYear: 1998, folderHint: "/Volumes/A")
                == yearKey,
            "Expected the folder hint to be suppressed once a year is present"
        )

        let folderKey = LibraryNormalization.composeAlbumKey(
            album: "Greatest Hits",
            folderHint: "/Volumes/Music/VA Mix"
        )
        expect(folderKey.contains("•folder:"), "Expected a folder suffix marker for the last-resort hint")
        expect(
            folderKey != LibraryNormalization.composeAlbumKey(
                album: "Greatest Hits",
                folderHint: "/Volumes/Music/Other"
            ),
            "Expected different folders to produce different last-resort keys"
        )

        let albumArtistKey = LibraryNormalization.composeAlbumKey(
            album: "Greatest Hits",
            disambiguation: .albumArtist("nirvana")
        )
        expect(
            albumArtistKey.hasSuffix("•albumartist:nirvana"),
            "Expected the trusted album-artist disambiguation to stay unchanged"
        )
        expect(
            !LibraryNormalization.composeAlbumKey(
                album: "Greatest Hits",
                disambiguation: .albumArtist("nirvana"),
                releaseYear: 1998
            ).contains("•year:"),
            "Expected the year hint to be skipped when an album artist already disambiguates"
        )
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
