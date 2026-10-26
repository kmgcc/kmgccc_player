import XCTest
@testable import kmgccc_player

@MainActor
final class SystemFontFamilySearchTests: XCTestCase {
    func testSearchFindsLocalizedNamesAndPostScriptAliasesWithoutChangingSavedIdentity() {
        let family = SystemFontFamily(
            name: "Cafe Sans",
            displayName: "咖啡黑体",
            aliases: ["CaféSans-Regular", "Atelier Sans"]
        )

        for query in ["CAFE SANS", "ｃａｆé—ｓａｎｓ", "咖啡 黑体", "cafesansregular", "atelier"] {
            let result = SystemFontFamilySearch.matches(in: [family], query: query, selectedFamily: "")
            XCTAssertEqual(result.map(\.name), ["Cafe Sans"], query)
            XCTAssertEqual(result.first?.displayName, "咖啡黑体", query)
        }
    }

    func testEveryQueryWordMustMatchAndWordsCanUseDifferentAliases() {
        let family = SystemFontFamily(
            name: "Harbor Sans",
            displayName: "港湾黑体",
            aliases: ["HarborSans-Book", "Foundry North"]
        )

        XCTAssertEqual(
            SystemFontFamilySearch.matches(in: [family], query: "港湾 north", selectedFamily: ""),
            [family]
        )
        XCTAssertTrue(
            SystemFontFamilySearch.matches(in: [family], query: "港湾 south", selectedFamily: "").isEmpty
        )
    }

    func testExactPrefixSubstringAndSubsequenceHaveUsefulOrdering() {
        let families = [
            SystemFontFamily(name: "Ink Type Era"),
            SystemFontFamily(name: "Winter Text"),
            SystemFontFamily(name: "Inter UI"),
            SystemFontFamily(name: "Alternate Family", aliases: ["Inter"]),
        ]

        XCTAssertEqual(
            SystemFontFamilySearch.matches(in: families, query: "inter", selectedFamily: "").map(\.name),
            ["Alternate Family", "Inter UI", "Winter Text", "Ink Type Era"]
        )
    }

    func testAbbreviationsMatchInOrderWithoutAcceptingReorderedLetters() {
        let families = [SystemFontFamily(name: "PingFang SC")]

        XCTAssertEqual(
            SystemFontFamilySearch.matches(in: families, query: "pfsc", selectedFamily: "").map(\.name),
            ["PingFang SC"]
        )
        XCTAssertTrue(
            SystemFontFamilySearch.matches(in: families, query: "scpf", selectedFamily: "").isEmpty
        )
    }

    func testOpeningOrSearchingCurrentValueShowsSelectionFirstAndLimitsCandidates() {
        let families = (0..<20).map { SystemFontFamily(name: "Family \($0)") }

        for query in ["", "ＦＡＭＩＬＹ—１９"] {
            let result = SystemFontFamilySearch.matches(
                in: families,
                query: query,
                selectedFamily: "Family 19"
            )
            XCTAssertEqual(result.count, 12, query)
            XCTAssertEqual(result.first?.name, "Family 19", query)
            XCTAssertEqual(Set(result.map(\.name)).count, result.count, query)
        }
    }

    func testMissingSavedFamilyRemainsAvailableButDoesNotPolluteOtherSearches() {
        let families = [SystemFontFamily(name: "Inter")]
        let initial = SystemFontFamilySearch.matches(
            in: families,
            query: "",
            selectedFamily: "Retired Family"
        )
        XCTAssertEqual(initial.map(\.name), ["Retired Family", "Inter"])
        XCTAssertEqual(initial.first?.displayName, "Retired Family")
        XCTAssertEqual(
            SystemFontFamilySearch.matches(
                in: families,
                query: "retired",
                selectedFamily: "Retired Family"
            ).map(\.name),
            ["Retired Family"]
        )
        XCTAssertTrue(
            SystemFontFamilySearch.matches(
                in: families,
                query: "unavailablezzzz",
                selectedFamily: "Retired Family"
            ).isEmpty
        )
    }

    func testExplicitCandidateLimitAppliesToSearchAndOpening() {
        let families = (0..<5).map { SystemFontFamily(name: "Sans \($0)") }

        for query in ["", "sans"] {
            XCTAssertEqual(
                SystemFontFamilySearch.matches(in: families, query: query, selectedFamily: "", limit: 2).count,
                2
            )
            XCTAssertTrue(
                SystemFontFamilySearch.matches(in: families, query: query, selectedFamily: "", limit: 0).isEmpty
            )
        }
    }
}
