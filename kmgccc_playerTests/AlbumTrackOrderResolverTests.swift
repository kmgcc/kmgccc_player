//
//  AlbumTrackOrderResolverTests.swift
//  kmgccc_playerTests
//
//  Catalog order matching used after an album import.
//

import Foundation
@testable import kmgccc_player
import XCTest

@MainActor
final class AlbumTrackOrderResolverTests: XCTestCase {
    private func track(
        _ title: String,
        duration: Double = 200,
        songMid: String? = nil,
        alternativeTitles: [String] = []
    ) -> AlbumTrackOrderResolver.LocalTrack {
        AlbumTrackOrderResolver.LocalTrack(
            id: UUID(),
            title: title,
            duration: duration,
            songMid: songMid,
            alternativeTitles: alternativeTitles
        )
    }

    private func song(
        _ title: String,
        duration: Double? = 200,
        songMid: String? = nil,
        alternativeTitles: [String] = []
    ) -> AlbumTrackOrderResolver.CatalogSong {
        AlbumTrackOrderResolver.CatalogSong(
            title: title,
            duration: duration,
            songMid: songMid,
            alternativeTitles: alternativeTitles
        )
    }

    func testOrdersLocalTracksByCatalogOrder() {
        let first = track("爱在西元前", duration: 234)
        let second = track("简单爱", duration: 270)
        let third = track("安静", duration: 334)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [third, first, second],
            catalog: [
                song("爱在西元前", duration: 234),
                song("简单爱", duration: 270),
                song("安静", duration: 334)
            ]
        )

        XCTAssertEqual(ordered, [first.id, second.id, third.id])
    }

    func testUnmatchedLocalTrackKeepsItsRelativePlaceAtTheEnd() {
        let matched = track("简单爱", duration: 270)
        let bonus = track("隐藏曲目", duration: 90)
        let alsoMatched = track("安静", duration: 334)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [bonus, alsoMatched, matched],
            catalog: [
                song("简单爱", duration: 270),
                song("安静", duration: 334)
            ]
        )

        XCTAssertEqual(ordered, [matched.id, alsoMatched.id, bonus.id])
    }

    func testLowMatchRatioDoesNotReplaceAlbumOrder() {
        let one = track("First", duration: 100)
        let two = track("Second", duration: 200)
        let three = track("Third", duration: 300)
        let four = track("Fourth", duration: 400)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [one, two, three, four],
            catalog: [song("Unrelated", duration: 100), song("Also unrelated", duration: 200)]
        )

        XCTAssertNil(ordered)
    }

    func testDurationSeparatesCatalogEntriesWithTheSameTitle() {
        let short = track("Interlude", duration: 45)
        let long = track("Interlude", duration: 210)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [long, short],
            catalog: [
                song("Interlude", duration: 45),
                song("Interlude", duration: 210)
            ]
        )

        XCTAssertEqual(ordered, [short.id, long.id])
    }

    func testSingleTrackAlbumIsLeftAlone() {
        let only = track("Only", duration: 180)
        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [only],
            catalog: [song("Only", duration: 180)]
        )
        XCTAssertNil(ordered)
    }

    func testPartialAlbumOrdersOnlyPresentTracks() {
        let present = [
            track("Track 01", duration: 101),
            track("Track 02", duration: 102),
            track("Track 04", duration: 104),
            track("Track 05", duration: 105),
            track("Track 07", duration: 107),
            track("Track 10", duration: 110)
        ]
        let catalog = (1...10).map { song("Track \(String(format: "%02d", $0))", duration: Double(100 + $0)) }

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [present[4], present[1], present[5], present[0], present[3], present[2]],
            catalog: catalog
        )

        XCTAssertEqual(ordered, present.map(\.id))
    }

    func testExistingManualOrderKeepsRelativeOrderWhenInserting() {
        let a = track("A", duration: 100)
        let b = track("B", duration: 200)
        let c = track("C", duration: 300)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [a, b, c],
            catalog: [song("A", duration: 100), song("B", duration: 200), song("C", duration: 300)],
            existingOrder: [c.id, a.id]
        )

        XCTAssertEqual(ordered, [b.id, c.id, a.id])
    }

    func testExistingCatalogOrderInsertsNewTrackInPlace() {
        let a = track("A", duration: 100)
        let b = track("B", duration: 200)
        let c = track("C", duration: 300)
        let bonus = track("Bonus", duration: 90)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [a, b, c, bonus],
            catalog: [song("A", duration: 100), song("B", duration: 200), song("C", duration: 300)],
            existingOrder: [a.id, c.id, bonus.id]
        )

        XCTAssertEqual(ordered, [a.id, b.id, c.id, bonus.id])
    }

    func testManualBonusInterleavingIsPreservedWhenInserting() {
        let a = track("A", duration: 100)
        let b = track("B", duration: 200)
        let c = track("C", duration: 300)
        let bonus = track("Bonus", duration: 90)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [a, b, c, bonus],
            catalog: [song("A", duration: 100), song("B", duration: 200), song("C", duration: 300)],
            existingOrder: [a.id, bonus.id, c.id]
        )

        XCTAssertEqual(ordered, [a.id, bonus.id, b.id, c.id])
    }

    func testStaleOrderIDsAreDroppedWhenInserting() {
        let a = track("A", duration: 100)
        let b = track("B", duration: 200)
        let c = track("C", duration: 300)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [a, b, c],
            catalog: [song("A", duration: 100), song("B", duration: 200), song("C", duration: 300)],
            existingOrder: [c.id, UUID(), a.id]
        )

        XCTAssertEqual(ordered, [b.id, c.id, a.id])
    }

    func testEmptyExistingOrderFallsBackToCatalogOrder() {
        let a = track("A", duration: 100)
        let b = track("B", duration: 200)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [b, a],
            catalog: [song("A", duration: 100), song("B", duration: 200)],
            existingOrder: []
        )

        XCTAssertEqual(ordered, [a.id, b.id])
    }

    func testExistingOrderWithoutNewTracksIsReturnedUnchanged() {
        let a = track("A", duration: 100)
        let b = track("B", duration: 200)
        let c = track("C", duration: 300)

        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [a, b, c],
            catalog: [song("A", duration: 100), song("B", duration: 200), song("C", duration: 300)],
            existingOrder: [c.id, a.id, b.id]
        )

        XCTAssertEqual(ordered, [c.id, a.id, b.id])
    }

    func testSecondPartialImportFillsGapsInCatalogOrder() {
        let a = track("A", duration: 100)
        let b = track("B", duration: 200)
        let c = track("C", duration: 300)
        let d = track("D", duration: 400)
        let e = track("E", duration: 500)
        let f = track("F", duration: 600)
        let catalog = (1...6).map { song(["A", "B", "C", "D", "E", "F"][$0 - 1], duration: Double($0 * 100)) }

        // First import brought A, C, F and already stored them in catalog order.
        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [f, d, a, b, e, c],
            catalog: catalog,
            existingOrder: [a.id, c.id, f.id]
        )

        XCTAssertEqual(ordered, [a.id, b.id, c.id, d.id, e.id, f.id])
    }

    func testCatalogOrderRespectsExplicitAlbumSortPreference() {
        XCTAssertTrue(AlbumTrackOrderingService.allowsCatalogOrder(sortKey: nil))
        XCTAssertTrue(AlbumTrackOrderingService.allowsCatalogOrder(sortKey: ""))
        XCTAssertTrue(AlbumTrackOrderingService.allowsCatalogOrder(sortKey: "custom"))
        XCTAssertTrue(AlbumTrackOrderingService.allowsCatalogOrder(sortKey: "legacySortKey"))
        XCTAssertFalse(AlbumTrackOrderingService.allowsCatalogOrder(sortKey: "title"))
        XCTAssertFalse(AlbumTrackOrderingService.allowsCatalogOrder(sortKey: "addedAt"))
    }

    func testSongMidMatchesWhenDisplayTitleWasEdited() {
        let edited = track("我在资料库改过的名字", duration: 234, songMid: "002usg9o4GTAKf")
        let other = track("简单爱", duration: 270, songMid: "003other")
        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [other, edited],
            catalog: [
                song("爱在西元前", duration: 234, songMid: "002usg9o4GTAKf"),
                song("简单爱", duration: 270, songMid: "003other")
            ]
        )
        XCTAssertEqual(ordered, [edited.id, other.id])
    }

    func testEditedTitleFallsBackToOriginalEmbeddedTitle() {
        let edited = track(
            "改过的标题",
            duration: 234,
            alternativeTitles: ["爱在西元前"]
        )
        let other = track("简单爱", duration: 270)
        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [other, edited],
            catalog: [
                song("爱在西元前", duration: 234),
                song("简单爱", duration: 270)
            ]
        )
        XCTAssertEqual(ordered, [edited.id, other.id])
    }

    func testLeadingTrackNumberPrefixesAreIgnored() {
        let first = track("01 - 爱在西元前", duration: 234)
        let second = track("1-03. 简单爱", duration: 270)
        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [second, first],
            catalog: [
                song("爱在西元前", duration: 234),
                song("简单爱", duration: 270)
            ]
        )
        XCTAssertEqual(ordered, [first.id, second.id])
    }

    func testBareNumberTitleIsNotTreatedAsATrackPrefix() {
        XCTAssertEqual(
            AlbumTrackOrderResolver.strippingLeadingCatalogNumber("7 Rings"),
            "7 Rings"
        )
        XCTAssertEqual(
            AlbumTrackOrderResolver.strippingLeadingCatalogNumber("1979"),
            "1979"
        )
        XCTAssertEqual(
            AlbumTrackOrderResolver.strippingLeadingCatalogNumber("01 - Song"),
            "Song"
        )
    }

    func testTraditionalAndSimplifiedTitlesUsePhoneticFallback() {
        let traditionalFirst = track("範特西", duration: 234)
        let traditionalSecond = track("愛人", duration: 270)
        let ordered = AlbumTrackOrderResolver.orderedTrackIDs(
            localTracks: [traditionalSecond, traditionalFirst],
            catalog: [
                song("范特西", duration: 234),
                song("爱人", duration: 270)
            ]
        )
        XCTAssertEqual(ordered, [traditionalFirst.id, traditionalSecond.id])
    }

    func testCatalogPositionsKeepGapsForPartialAlbums() {
        let one = track("Track 1", duration: 101)
        let two = track("Track 2", duration: 102)
        let four = track("Track 4", duration: 104)
        let five = track("Track 5", duration: 105)
        let seven = track("Track 7", duration: 107)
        let ten = track("Track 10", duration: 110)
        let catalog = (1...10).map {
            song("Track \($0)", duration: Double(100 + $0))
        }

        let resolution = AlbumTrackOrderResolver.resolve(
            localTracks: [ten, four, one, seven, two, five],
            catalog: catalog
        )

        XCTAssertEqual(
            resolution?.orderedTrackIDs,
            [one.id, two.id, four.id, five.id, seven.id, ten.id]
        )
        XCTAssertEqual(resolution?.catalogPositionByTrackID[one.id], 1)
        XCTAssertEqual(resolution?.catalogPositionByTrackID[two.id], 2)
        XCTAssertEqual(resolution?.catalogPositionByTrackID[four.id], 4)
        XCTAssertEqual(resolution?.catalogPositionByTrackID[five.id], 5)
        XCTAssertEqual(resolution?.catalogPositionByTrackID[seven.id], 7)
        XCTAssertEqual(resolution?.catalogPositionByTrackID[ten.id], 10)
    }

    private struct AlbumSongsPayload: Decodable {
        let songs: [QQMusicAlbumSong]
    }

    func testDecodesHelperAlbumSongsPayload() throws {
        let payload = """
        {"songs":[{"songMid":"002usg9o4GTAKf","title":"爱在西元前","artist":"周杰伦","album":"范特西","duration":234,"discNumber":0,"trackNumber":1}]}
        """
        let decoded = try JSONDecoder().decode(
            AlbumSongsPayload.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(decoded.songs.count, 1)
        XCTAssertEqual(decoded.songs.first?.title, "爱在西元前")
        XCTAssertEqual(decoded.songs.first?.duration, 234)
        XCTAssertEqual(decoded.songs.first?.trackNumber, 1)
    }
}
