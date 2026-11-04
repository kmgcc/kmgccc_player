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

@MainActor
final class SettingsSearchIndexTests: XCTestCase {
    func testChinesePinyinInitialsAndSubsequenceFindTheSameSetting() {
        let entry = SettingsSearchEntry(
            "歌词字体", category: .nowPlaying, tab: 1, tabTitle: "歌词",
            anchor: "lyrics.fonts", keywords: "字体大小 中文 英文"
        )
        for query in ["歌词字体", "歌字", "geciziti", "gczt", "字体 大小", "歌词字休"] {
            XCTAssertEqual(SettingsSearchIndex.results(for: query, entries: [entry]).map(\.id), [entry.id], query)
        }
        XCTAssertTrue(SettingsSearchIndex.results(for: "字体歌词", entries: [entry]).isEmpty)
    }

    func testOneTypoOrAdjacentLetterSwapCanMatch() {
        let entries = [SettingsSearchEntry("音量均衡", category: .audio),
                       SettingsSearchEntry("inter", category: .general)]
        XCTAssertEqual(SettingsSearchIndex.results(for: "音量军衡", entries: entries).first?.title, "音量均衡")
        XCTAssertEqual(SettingsSearchIndex.results(for: "itner", entries: entries).first?.title, "inter")
        XCTAssertTrue(SettingsSearchIndex.results(for: "音乐军衡", entries: entries).isEmpty)
    }

    func testExactTitlesRankAheadOfPrefixesSubstringsAndFuzzyMatches() {
        let entries = [
            SettingsSearchEntry("Ink Type Era", category: .general),
            SettingsSearchEntry("Winter Text", category: .general),
            SettingsSearchEntry("Inter UI", category: .general),
            SettingsSearchEntry("Inter", category: .general),
        ]
        XCTAssertEqual(
            SettingsSearchIndex.results(for: "ｉｎｔｅｒ", entries: entries).map(\.title),
            ["Inter", "Inter UI", "Winter Text", "Ink Type Era"]
        )
    }

    func testAllWordsMustMatchAndCanUsePathAndAliases() {
        let entry = SettingsSearchEntry(
            "目标响度", category: .audio, tab: 0, tabTitle: "常规",
            anchor: "audio.loudness", keywords: "LUFS 音量均衡"
        )
        XCTAssertEqual(SettingsSearchIndex.results(for: "音频 LUFS", entries: [entry]).map(\.id), [entry.id])
        XCTAssertTrue(SettingsSearchIndex.results(for: "音频 missing", entries: [entry]).isEmpty)
        XCTAssertTrue(SettingsSearchIndex.results(for: " ", entries: [entry]).isEmpty)
    }

    func testCatalogueKeepsDistinctWindowAndFullscreenDestinations() {
        let results = SettingsSearchIndex.results(for: "歌词字体", entries: SettingsSearchIndex.entries)
            .filter { $0.title == "歌词字体" }
        XCTAssertEqual(results.map(\.category), [.nowPlaying, .fullscreen])
        XCTAssertTrue(results.allSatisfy { $0.tab == 1 && $0.anchor == "lyrics.fonts" })
        XCTAssertEqual(Set(SettingsSearchIndex.entries.map(\.id)).count, SettingsSearchIndex.entries.count)
    }

    func testVisibleSkinParametersFollowCurrentValuesAndSurface() throws {
        let suiteName = "SettingsSearchIndexTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SkinParameterStore(defaults: defaults)
        let enabled = SkinParameterDefinition(
            id: "enabled", title: "Enabled", defaultValue: .boolean(false), control: .toggle,
            isUserVisible: true
        )
        let detail = SkinParameterDefinition(
            id: "detail", title: "Detail", defaultValue: .boolean(false), control: .toggle,
            surfaces: [.window], isUserVisible: true, visibleWhen: "params.enabled"
        )
        let definitions = [enabled, detail]
        func visible(_ surface: SkinSurface) -> [String] {
            SkinParameterSettingsView.visibleDefinitions(
                skinID: "test.search", surface: surface, definitions: definitions, store: store
            ).map(\.id)
        }

        XCTAssertEqual(visible(.window), ["enabled"])
        store.set(skinID: "test.search", surface: .window, definition: enabled, value: .boolean(true))
        XCTAssertEqual(visible(.window), ["enabled", "detail"])
        XCTAssertEqual(visible(.fullscreen), ["enabled"])
    }
}
