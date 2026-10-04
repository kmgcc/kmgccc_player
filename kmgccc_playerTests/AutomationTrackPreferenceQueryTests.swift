import Foundation
import PlayerAutomationProtocol
@testable import kmgccc_player
import XCTest

final class AutomationTrackPreferenceQueryTests: XCTestCase {
    func testPlaybackPreferencePredicatesUsePersistedStatsFields() {
        let stats = kmgccc_player.TrackPreferenceStats(
            playCount: 12,
            completePlayCount: 8,
            skipCount: 3,
            quickSkipCount: 1,
            totalPlayedSeconds: 2_880,
            lastPlayedAt: Date(timeIntervalSince1970: 1_750_000_000),
            manualLikeState: .liked,
            preferenceScoreCache: 0.82
        )

        XCTAssertTrue(AutomationTrackPreferenceQuery.matches(
            "likeState", value: .string("liked"), stats: stats
        ))
        XCTAssertTrue(AutomationTrackPreferenceQuery.matches(
            "playCountMin", value: .number(10), stats: stats
        ))
        XCTAssertTrue(AutomationTrackPreferenceQuery.matches(
            "completePlayCountMin", value: .number(8), stats: stats
        ))
        XCTAssertFalse(AutomationTrackPreferenceQuery.matches(
            "skipCountMin", value: .number(4), stats: stats
        ))
        XCTAssertTrue(AutomationTrackPreferenceQuery.matches(
            "preferenceScoreMin", value: .number(0.8), stats: stats
        ))
        XCTAssertTrue(AutomationTrackPreferenceQuery.matches(
            "totalPlayedSecondsMin", value: .number(2_800), stats: stats
        ))
        XCTAssertTrue(AutomationTrackPreferenceQuery.matches(
            "lastPlayedAfter", value: .string("2025-06-01T00:00:00Z"), stats: stats
        ))
        XCTAssertFalse(AutomationTrackPreferenceQuery.matches(
            "lastPlayedBefore", value: .string("2025-05-01T00:00:00Z"), stats: stats
        ))
    }

    func testHistoryScopeRequirementFindsNestedPredicatesAndSorts() {
        let filter: AutomationJSONValue = .object([
            "all": .array([
                .object(["titleContains": .string("live")]),
                .object(["not": .object(["likeState": .string("disliked")])])
            ])
        ])
        XCTAssertTrue(AutomationTrackPreferenceQuery.requiresHistoryRead(in: filter))
        XCTAssertFalse(AutomationTrackPreferenceQuery.requiresHistoryRead(in: .object([
            "all": .array([.object(["titleContains": .string("live")])])
        ])))
        XCTAssertTrue(AutomationTrackPreferenceQuery.requiresHistoryRead(sort: [
            .object(["field": .string("lastPlayedAt"), "direction": .string("desc")])
        ]))
        XCTAssertFalse(AutomationTrackPreferenceQuery.requiresHistoryRead(sort: [
            .object(["field": .string("title"), "direction": .string("asc")])
        ]))
    }

    func testPreferenceSortAndSummaryRoundTrip() throws {
        let older = kmgccc_player.TrackPreferenceStats(
            playCount: 2,
            lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_000),
            manualLikeState: .none,
            preferenceScoreCache: 0.2
        )
        let newer = kmgccc_player.TrackPreferenceStats(
            playCount: 7,
            lastPlayedAt: Date(timeIntervalSince1970: 1_750_000_000),
            manualLikeState: .liked,
            preferenceScoreCache: 0.7
        )

        XCTAssertEqual(
            AutomationTrackPreferenceQuery.compare(older, newer, field: "lastPlayedAt"),
            .orderedAscending
        )
        XCTAssertEqual(
            AutomationTrackPreferenceQuery.compare(older, newer, field: "playCount"),
            .orderedAscending
        )

        let summary = AutomationTrackPreferenceQuery.summary(newer)
        let encoded = try AutomationWireCoding.encoder().encode(summary)
        let decoded = try AutomationWireCoding.decoder().decode(
            AutomationTrackPreferenceSummary.self,
            from: encoded
        )
        XCTAssertEqual(decoded.playCount, 7)
        XCTAssertEqual(decoded.likeState, "liked")
        XCTAssertEqual(decoded.preferenceScore, 0.7)
    }
}
