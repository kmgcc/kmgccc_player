import XCTest

final class SkinRoutePolicyTests: XCTestCase {
    func testKnownRouteIsPreserved() {
        XCTAssertEqual(
            SkinRoutePolicy.resolvedID(
                requestedID: "skin.two",
                availableIDs: ["skin.one", "skin.two"],
                defaultID: "skin.one",
                fallbackID: "fallback"
            ),
            "skin.two"
        )
    }

    func testUnknownRouteUsesConfiguredDefault() {
        XCTAssertEqual(
            SkinRoutePolicy.resolvedID(
                requestedID: "missing",
                availableIDs: ["skin.one", "skin.two"],
                defaultID: "skin.two",
                fallbackID: "fallback"
            ),
            "skin.two"
        )
    }

    func testMissingDefaultUsesFirstAvailableRoute() {
        XCTAssertEqual(
            SkinRoutePolicy.resolvedID(
                requestedID: "missing",
                availableIDs: ["skin.one", "skin.two"],
                defaultID: "also.missing",
                fallbackID: "fallback"
            ),
            "skin.one"
        )
    }

    func testEmptyRegistryUsesHardFallback() {
        XCTAssertEqual(
            SkinRoutePolicy.resolvedID(
                requestedID: "missing",
                availableIDs: [],
                defaultID: "also.missing",
                fallbackID: "fallback"
            ),
            "fallback"
        )
    }

    func testFullscreenPrioritySortRank() {
        XCTAssertEqual(
            SkinRoutePolicy.sortRank(
                for: "fullscreen.coverGradientBlur",
                prioritizedID: "fullscreen.coverGradientBlur",
                orderedIDs: ["classic", "fullscreen.coverGradientBlur"]
            ),
            -1
        )
        XCTAssertEqual(
            SkinRoutePolicy.sortRank(
                for: "classic",
                prioritizedID: "fullscreen.coverGradientBlur",
                orderedIDs: ["classic", "fullscreen.coverGradientBlur"]
            ),
            0
        )
    }
}
