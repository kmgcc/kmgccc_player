import Foundation
@testable import kmgccc_player
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

    func testManualSearchExpandsMetadataAndPreservesAlternateTitle() {
        let queries = ManualMusicSearch.queries(title: "Song (Live)", artist: "Artist", album: "Album")
        XCTAssertEqual(queries.first, .init(title: "Song (Live)", artist: "Artist", album: "Album"))
        XCTAssertTrue(queries.contains(.init(title: "Song (Live)", artist: "Artist", album: "")))
        XCTAssertTrue(queries.contains(.init(title: "song", artist: "Artist", album: "")))
        XCTAssertTrue(queries.contains(.init(title: "song", artist: "", album: "")))

        let alternate = ManualMusicSearch.queries(title: "故乡（Hometown）", artist: "Artist", album: nil)
        XCTAssertTrue(alternate.contains(.init(title: "Hometown", artist: "Artist", album: "")))
        XCTAssertFalse(queries.contains { $0.title.lowercased() == "live" })

        let album = ManualMusicSearch.queries(title: "", artist: "Artist", album: "Album (Deluxe)")
        XCTAssertTrue(album.contains(.init(title: "", artist: "", album: "album")))
    }

    func testFuzzyCoverSuggestionNeedsExplicitSelection() {
        let fuzzy = CoverCandidate(imageData: Data(), source: .qqmusic, sourceItemId: "fuzzy",
            width: 1200, height: 1200, confidence: 0.95, matchedTitle: "Closer", matchedArtist: "Artist")
        let exact = CoverCandidate(imageData: Data(), source: .qqmusic, sourceItemId: "exact",
            width: 1200, height: 1200, confidence: 0.95, matchedTitle: "Colors", matchedArtist: "Artist")
        XCTAssertFalse(ManualMusicSearch.canAutomaticallyPreview(fuzzy, title: "Colors", artist: "Artist", album: ""))
        XCTAssertTrue(ManualMusicSearch.canAutomaticallyPreview(exact, title: "Colors", artist: "Artist", album: ""))
        XCTAssertFalse(ManualMusicSearch.canAutomaticallyPreview(exact, title: "Colors", artist: "Other", album: ""))
        XCTAssertFalse(ManualMusicSearch.canAutomaticallyPreview(exact, title: "Colors", artist: "", album: ""))
    }

    func testMetadataSuggestionsPreferOriginalTitleAndDeduplicateSongIDs() {
        func candidate(_ id: String, _ title: String) -> QQMusicArtworkCandidate {
            QQMusicArtworkCandidate(source: "qqmusic", title: title, artist: "Artist", album: "Album",
                artistName: nil, singerMid: nil, songMid: id, albumMid: nil, imageURL: nil,
                duration: nil, confidence: 0.9)
        }
        let similar = candidate("2", "Closer")
        let exact = candidate("1", "Colors")
        let sorted = ManualMusicSearch.sortMetadataCandidates(
            [similar, exact, similar], title: "Colors", artist: "Artist", album: "Album"
        )
        XCTAssertEqual(sorted.compactMap(\.songMid), ["1", "2"])
    }

    @MainActor
    func testManualLyricsRescoreAndDeduplicateAgainstOriginalTitle() {
        let similar = LDDCCandidate(source: "QM", songId: "2", score: 100, title: "Closer",
            artist: "Artist", album: nil, durationMs: nil, extra: nil)
        let exact = LDDCCandidate(source: "NE", songId: "1", score: 30, title: "Colors",
            artist: "Artist", album: nil, durationMs: nil, extra: nil)
        let results = LyricsSearchHelper.mergeManualSuggestions(
            amlldb: [], lddc: [similar, exact, similar], title: "Colors", artist: "Artist", album: nil
        )
        XCTAssertEqual(results.map(\.id), [exact.id, similar.id])
        XCTAssertGreaterThan(results[0].normalizedScore(), results[1].normalizedScore())
        XCTAssertLessThan(results[1].normalizedScore(), 100)
    }

    @MainActor
    func testAMLLDBOneCharacterToleranceIsManualOnly() {
        let entry = AMLLDBRawIndexEntry(titles: ["Colours"], artists: ["Artist"], albums: [],
            ncmMusicId: nil, qqMusicId: nil, appleMusicId: nil, spotifyId: nil,
            rawLyricFile: "colours.ttml", durationMs: nil)
        let params = AMLLDBSearchParams(title: "Colors", artists: ["Artist"])
        XCTAssertTrue(AMLLDBSearcher.search(entries: [entry], params: params).isEmpty)
        XCTAssertEqual(AMLLDBSearcher.search(entries: [entry], params: params, allowFuzzy: true).map(\.id), [entry.rawLyricFile])

        let chinese = AMLLDBRawIndexEntry(titles: ["故郷"], artists: [], albums: [],
            ncmMusicId: nil, qqMusicId: nil, appleMusicId: nil, spotifyId: nil,
            rawLyricFile: "home.ttml", durationMs: nil)
        XCTAssertEqual(AMLLDBSearcher.search(entries: [chinese], params: .init(title: "故乡"), allowFuzzy: true).map(\.id), [chinese.rawLyricFile])
    }

    @MainActor
    func testAMLLDBKeepsExactTitlesAheadOfFuzzyMatchesBeforeTheLimit() {
        let alternatives = (0..<510).map { index in
            AMLLDBRawIndexEntry(titles: ["Colors Live \(index)"], artists: ["Artist"], albums: [],
                ncmMusicId: nil, qqMusicId: nil, appleMusicId: nil, spotifyId: nil,
                rawLyricFile: "\(index).ttml", durationMs: nil)
        }
        let exact = AMLLDBRawIndexEntry(titles: ["Colors"], artists: ["Other"], albums: [],
            ncmMusicId: nil, qqMusicId: nil, appleMusicId: nil, spotifyId: nil,
            rawLyricFile: "exact.ttml", durationMs: nil)
        let results = AMLLDBSearcher.search(entries: alternatives + [exact],
            params: .init(title: "Colors", artists: ["Artist"]), allowFuzzy: true)
        XCTAssertEqual(results.first?.id, exact.rawLyricFile)
    }

    @MainActor
    func testMotionSuggestionsMergeVariantsAndPreferOriginalName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = MotionSuggestionClient()
        let service = MusicEnrichmentService(store: MusicEnrichmentStore(rootURL: root), client: client)
        let query = MusicEnrichmentQuery(key: "test", title: "Colors", artist: "Artist", album: "Wrong album", duration: 0)
        let results = try await service.searchMotionCandidates(query: query)
        XCTAssertEqual(results.compactMap(\.albumID), ["1", "2"])
        let attempts = await client.queries
        XCTAssertTrue(attempts.contains { $0.album.isEmpty && $0.artist.isEmpty })
        await service.close()
    }
}

private actor MotionSuggestionClient: MusicEnrichmentFetching {
    private(set) var queries: [MusicEnrichmentQuery] = []

    func fetch(provider: String, query: MusicEnrichmentQuery) async throws -> MusicEnrichmentResult? { nil }
    func materialize(_ descriptor: MotionArtworkDescriptor, destination: URL) async throws -> MusicEnrichmentHelperClient.MaterializedMotion {
        throw URLError(.unsupportedURL)
    }
    func searchMotion(query: MusicEnrichmentQuery) async throws -> [MusicEnrichmentResult] {
        queries.append(query)
        if !query.album.isEmpty { throw URLError(.timedOut) }
        func result(_ id: String, title: String) -> MusicEnrichmentResult {
            MusicEnrichmentResult(source: "appleWeb", albumID: id,
                attributes: ["name": .string(title), "albumName": .string(title), "artistName": .string("Artist")],
                motion: [.init(kind: "square", url: "https://example.com/\(id).m3u8")])
        }
        return [result("2", title: "Closer"), result("1", title: "Colors")]
    }
}

/// Placeholder identities (未知艺人 / 群星 / 未知专辑) must not become provider
/// seeds, and a match made without an artist has to be confirmed by duration.
final class PlaceholderIdentitySeedTests: XCTestCase {
    func testDetectsPlaceholderArtists() {
        for value in [
            "未知艺人", "未知歌手", "未知", "群星", "合辑",
            "Unknown Artist", "unknown", "UNKOWN", "Various Artists", "V.A.", "VA",
            "未知艺人 (Unknown)", "Various Artists [Compilation]", "",
        ] {
            XCTAssertTrue(
                LibraryNormalization.isUnknownArtist(value),
                "\(value) should read as a placeholder artist"
            )
        }
    }

    func testDetectsPlaceholderAlbums() {
        for value in ["未知专辑", "未知专辑、、、", "未知唱片", "未命名专辑", "Unknown Album", ""] {
            XCTAssertTrue(
                LibraryNormalization.isUnknownAlbum(value),
                "\(value) should read as a placeholder album"
            )
        }
    }

    func testKeepsRealNames() {
        for value in ["福梦", "福梦 (FUMON)", "DOUDOU", "司南", "AURORA & Bear McCreary"] {
            XCTAssertFalse(LibraryNormalization.isUnknownArtist(value), value)
        }
        for value in ["苦难里的祝福", "天空"] {
            XCTAssertFalse(LibraryNormalization.isUnknownAlbum(value), value)
        }
    }

    func testPlaceholdersNeverBecomeSeeds() {
        XCTAssertEqual(LibraryNormalization.searchSeedArtist("未知艺人"), "")
        XCTAssertEqual(LibraryNormalization.searchSeedArtist("群星"), "")
        XCTAssertEqual(LibraryNormalization.searchSeedAlbum("未知专辑"), "")
        XCTAssertEqual(LibraryNormalization.searchSeedArtist("  福梦  "), "福梦")
        XCTAssertEqual(LibraryNormalization.searchSeedAlbum("苦难里的祝福"), "苦难里的祝福")
    }

    func testArtistlessMatchNeedsTheDurationToAgree() {
        // 背叛 runs 291s; the 曹格 version runs 321s.
        XCTAssertTrue(
            ExternalPlaybackTextNormalizer.durationSupportsArtistlessMatch(source: 291, candidate: 291)
        )
        XCTAssertFalse(
            ExternalPlaybackTextNormalizer.durationSupportsArtistlessMatch(source: 291, candidate: 321)
        )
        XCTAssertFalse(
            ExternalPlaybackTextNormalizer.durationSupportsArtistlessMatch(source: 291, candidate: 0)
        )
    }
}
