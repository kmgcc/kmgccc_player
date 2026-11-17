import XCTest
@testable import kmgccc_player

final class CustomTrackOrderMergeTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()
    private let third = UUID()
    private let fourth = UUID()

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func testAscendingAppendsNewTracksInAddTimeOrder() {
        let merged = CustomTrackOrderMerge.merging(
            customOrder: [second, first],
            availableIDs: [second, first, fourth, third],
            addedAt: [
                first: date(100),
                second: date(200),
                third: date(300),
                fourth: date(400)
            ],
            placesNewTracksOnTop: false
        )

        XCTAssertEqual(merged, [second, first, third, fourth])
    }

    func testDescendingPlacesTheLatestAdditionsFirst() {
        let merged = CustomTrackOrderMerge.merging(
            customOrder: [second, first],
            availableIDs: [second, first, third, fourth],
            addedAt: [
                first: date(100),
                second: date(200),
                third: date(300),
                fourth: date(400)
            ],
            placesNewTracksOnTop: true
        )

        XCTAssertEqual(merged, [fourth, third, second, first])
    }

    func testSingleAdditionGoesToTheTopWhenDescending() {
        let merged = CustomTrackOrderMerge.merging(
            customOrder: [second, first],
            availableIDs: [second, third, first],
            addedAt: [third: date(300)],
            placesNewTracksOnTop: true
        )

        XCTAssertEqual(merged, [third, second, first])
    }

    func testTracksThatAreNoLongerAvailableLeaveTheOrder() {
        let merged = CustomTrackOrderMerge.merging(
            customOrder: [third, second, first],
            availableIDs: [first, second],
            addedAt: [:],
            placesNewTracksOnTop: true
        )

        XCTAssertEqual(merged, [second, first])
    }

    func testOrderIsUnchangedWhenEveryTrackIsKnown() {
        let merged = CustomTrackOrderMerge.merging(
            customOrder: [third, first, second],
            availableIDs: [first, second, third],
            addedAt: [:],
            placesNewTracksOnTop: true
        )

        XCTAssertEqual(merged, [third, first, second])
    }
}
