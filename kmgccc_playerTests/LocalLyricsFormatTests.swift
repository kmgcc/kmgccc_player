import Foundation
@testable import kmgccc_player
import XCTest

/// Local lyric import: format detection, the parsers ported from AMLL
/// packages/lyric, TTML output and the import-time lookup order.
@MainActor
final class LocalLyricsFormatTests: XCTestCase {
    // MARK: - Detection

    func testDetectsEachFormatFromContent() {
        let samples: [(String, LyricsSourceFormat)] = [
            (#"<tt xmlns="http://www.w3.org/ns/ttml"><body></body></tt>"#, .ttml),
            ("[00:01.00]Hello\n[00:02.00]World", .lrc),
            ("[00:01.00]Hel[00:01.30]lo[00:02.00]", .lrc),
            ("[00:01.000]<00:01.000>Hello <00:01.500>World<00:02.000>", .lrcA2),
            ("[1000,1000](1000,500,0)Hello(1500,500,0)World", .yrc),
            ("[1000,1000]Hello(1000,500)World(1500,500)", .qrc),
            (#"<QrcInfos><LyricInfo><Lyric_1 LyricType="1" LyricContent="[0,500]Hi(0,500)"/></LyricInfo></QrcInfos>"#, .qrc),
            ("[4]Hello(1000,500)World(1500,500)", .lys),
            ("[type:LyricifyLines]\n[1000,2000]Hello", .lyl),
            ("[Lyricify Quick Export]\n[version:1.0]\n[lyrics: format@Lyricify Syllable]\n[4]A(0,100)", .lqe),
        ]
        for (text, expected) in samples {
            XCTAssertEqual(LyricsSourceFormat.detect(in: text), expected, text)
        }
    }

    func testUntimedTextIsReportedAsMissingTimeline() async {
        await assertConversionFails("Just some words\nAnother line", with: .missingTimeline)
        await assertConversionFails("<00:01.00>Hello", with: .unrecognizedFormat)
        await assertConversionFails("   \n", with: .emptyText)
    }

    // MARK: - Parsers

    func testYRCParsesWordsAndBackgroundParentheses() {
        let lyrics = YRCLyricsParser.parse(
            #"{"t":0,"c":[{"tx":"作词: "}]}"# + "\n"
                + "[1000,1000](1000,500,0)Hello(1500,500,0)World\r\n"
                + "[3000,1000](3000,500,0)(Ooh (3500,500,0)yeah)"
        )

        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines[0].startMs, 1000)
        XCTAssertEqual(lyrics.lines[0].endMs, 2000)
        XCTAssertEqual(lyrics.lines[0].words.map(\.text), ["Hello", "World"])
        XCTAssertEqual(lyrics.lines[0].words[1].startMs, 1500)
        XCTAssertEqual(lyrics.lines[0].words[1].endMs, 2000)
        XCTAssertTrue(lyrics.lines[1].isBackground)
        XCTAssertEqual(lyrics.lines[1].text, "Ooh yeah")
    }

    func testQRCParsesPlainAndXMLContainer() {
        let plain = QRCLyricsParser.parse("[190871,1984]For (190871,361)the (191232,172)first(191404,376)")
        XCTAssertEqual(plain.lines.first?.words.map(\.text), ["For ", "the ", "first"])
        XCTAssertEqual(plain.lines.first?.words.last?.endMs, 191_780)

        let wrapped = QRCLyricsParser.parse(
            #"<?xml version="1.0"?><QrcInfos><LyricInfo LyricCount="1">"#
                + #"<Lyric_1 LyricType="1" LyricContent="[ti:Song]&#10;[0,500]Rock &amp; roll(0,500)"/>"#
                + "</LyricInfo></QrcInfos>"
        )
        XCTAssertEqual(wrapped.lines.map(\.text), ["Rock & roll"])
    }

    func testLYSPropertiesMarkBackgroundAndDuet() {
        let lyrics = LYSLyricsParser.parse(
            "no prop\n[4]Hello(1000,500) World(1500,500)\n[8](Echo(1200,300))\n[5]Reply(3000,500)\n[0]Bad(a,b)"
        )

        XCTAssertEqual(lyrics.lines.count, 3)
        XCTAssertEqual(lyrics.lines[0].words.map(\.text), ["Hello", " World"])
        XCTAssertFalse(lyrics.lines[0].isDuet)
        XCTAssertTrue(lyrics.lines[1].isBackground)
        XCTAssertTrue(lyrics.lines[1].isDuet)
        XCTAssertEqual(lyrics.lines[1].text, "Echo")
        XCTAssertTrue(lyrics.lines[2].isDuet)
        XCTAssertFalse(lyrics.lines[2].isBackground)
    }

    func testLQEAttachesTranslationAndPronunciation() {
        let lyrics = LQELyricsParser.parse(
            """
            [Lyricify Quick Export]
            [version:1.0]

            [lyrics: format@Lyricify Syllable]
            [4]A(365,350)ni(715,307)
            [4]Ro(2000,300)

            [translation: format@LRC]
            [00:00.365]不生亦不灭

            [pronunciation: format@LRC, language@romaji]
            [00:02.000]ro
            """
        )

        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines[0].translation, "不生亦不灭")
        XCTAssertNil(lyrics.lines[0].romanization)
        XCTAssertEqual(lyrics.lines[1].romanization, "ro")
    }

    func testLRCA2ParsesWordTagsAndSpacing() {
        let lyrics = LRCA2LyricsParser.parse("[ar: Artist]\n[00:01.000]<00:01.000>Hello <00:01.500>World<00:02.000>")

        XCTAssertEqual(lyrics.lines.count, 1)
        XCTAssertEqual(lyrics.lines[0].endMs, 2000)
        XCTAssertEqual(lyrics.lines[0].words.map(\.text), ["Hello", " ", "World"])
        XCTAssertEqual(lyrics.lines[0].words[2].startMs, 1500)
        XCTAssertEqual(lyrics.lines[0].words[2].endMs, 2000)
    }

    func testNormalizationEndsLineTimedLinesAtTheNextLine() {
        let lyrics = LRCA2LyricsParser.parse("[00:01.00]Line one\n[00:03.00]Line two").normalized()

        XCTAssertEqual(lyrics.lines[0].endMs, 3000)
        XCTAssertEqual(lyrics.lines[0].words[0].endMs, 3000)
        XCTAssertEqual(lyrics.lines[1].endMs, 3000 + ParsedLyrics.fallbackLastLineDurationMs)
    }

    // MARK: - Same-timestamp translations

    func testSplitsPairedTimestampsIntoTranslation() {
        let split = LRCTranslationSplitter.split(
            "[offset:200]\n[00:01.00]Hello\n[00:01.00]你好\n[00:04.00]World\n[00:04.00]世界\n[00:08.00]Outro"
        )

        XCTAssertEqual(split.original, "[offset:200]\n[00:01.00]Hello\n[00:04.00]World\n[00:08.00]Outro")
        XCTAssertEqual(split.translation, "[offset:200]\n[00:01.00]你好\n[00:04.00]世界")
    }

    func testOccasionalSharedTimestampIsNotATranslation() {
        let lrc = "[00:01.00]A\n[00:01.00]B\n[00:02.00]C\n[00:03.00]D\n[00:04.00]E"
        XCTAssertNil(LRCTranslationSplitter.split(lrc).translation)
    }

    // MARK: - TTML output

    func testFullscreenLyricsResolutionTracksExactPayloadChanges() {
        let coordinator = FullscreenLyricsCoordinator()
        let trackID = UUID()
        let first = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="00:01.000" end="00:02.000">First</p></div></body></tt>"#
        let replacement = first.replacingOccurrences(of: "First", with: "Second")

        XCTAssertEqual(coordinator.normalizedLyricsText(trackID: trackID, rawText: "\n\(first)\n"), first)
        XCTAssertEqual(coordinator.normalizedLyricsText(trackID: trackID, rawText: "\n\(first)\n"), first)
        XCTAssertEqual(coordinator.normalizedLyricsText(trackID: trackID, rawText: replacement), replacement)
        XCTAssertNil(coordinator.normalizedLyricsText(trackID: trackID, rawText: "<tt></tt>"))
        XCTAssertNil(coordinator.normalizedLyricsText(trackID: trackID, rawText: "<tt></tt>"))
        XCTAssertEqual(coordinator.normalizedLyricsText(trackID: trackID, rawText: first), first)
        XCTAssertEqual(coordinator.normalizedLyricsText(trackID: UUID(), rawText: replacement), replacement)
        XCTAssertNil(coordinator.normalizedLyricsText(trackID: nil, rawText: nil))
        coordinator.resetForDisappear()
        XCTAssertEqual(coordinator.normalizedLyricsText(trackID: trackID, rawText: first), first)
    }

    func testLRCWithSameTimestampTranslationProducesTranslationSpans() async throws {
        let ttml = try await LyricsTTMLConverter.ttml(
            from: "[00:01.00]Hello world\n[00:01.00]你好世界\n[00:04.00]Second line\n[00:04.00]第二行\n[00:08.00]Third line"
        )

        XCTAssertTrue(LyricsFormatSupport.validateTTML(ttml).isValid)
        XCTAssertEqual(occurrences(of: "<p ", in: ttml), 3)
        XCTAssertTrue(ttml.contains(#"<span ttm:role="x-translation" xml:lang="zh-CN">你好世界</span>"#))
        XCTAssertTrue(ttml.contains(#"<span ttm:role="x-translation" xml:lang="zh-CN">第二行</span>"#))
    }

    func testLRCOffsetTagShiftsLyricsEarlier() async throws {
        let ttml = try await LyricsTTMLConverter.ttml(from: "[offset:500]\n[00:02.00]Hello\n[00:05.00]World")
        XCTAssertTrue(ttml.contains(#"<p ttm:agent="v1" itunes:key="L1" begin="00:01.500""#), ttml)
    }

    func testWordTimedFormatWritesBackgroundAndDuet() async throws {
        let yrc = try await LyricsTTMLConverter.ttml(
            from: "[1000,1000](1000,500,0)Hello (1500,500,0)world\n[1200,800](1200,400,0)(Ooh (1600,400,0)yeah)"
        )
        XCTAssertTrue(LyricsFormatSupport.validateTTML(yrc).isValid)
        XCTAssertEqual(occurrences(of: "<p ", in: yrc), 1)
        XCTAssertTrue(yrc.contains(#"<p begin="00:01.000" end="00:02.000" ttm:agent="v1" itunes:key="L1">"#), yrc)
        XCTAssertTrue(yrc.contains(#"<span ttm:role="x-bg"><span begin="00:01.200" end="00:01.600">Ooh </span>"#), yrc)

        let lys = try await LyricsTTMLConverter.ttml(from: "[4]Hi(0,500)\n[5]Yo(1000,500)")
        XCTAssertTrue(lys.contains(#"ttm:agent="v2" itunes:key="L2""#), lys)
    }

    func testTTMLIsPassedThroughAndValidated() async throws {
        let source = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="00:01.000" end="00:02.000">Hi</p></div></body></tt>"#
        let ttml = try await LyricsTTMLConverter.ttml(from: "\n\(source)\n")
        XCTAssertEqual(ttml, source)

        await assertConversionFails(#"<tt xmlns="http://www.w3.org/ns/ttml"></tt>"#, with: .invalidTTML("TTML 缺少 <body> 节点"))
    }

    // MARK: - Files

    func testDecodesLegacyEncodingsAndByteOrderMarks() throws {
        let gb18030 = Data("[00:01.00]".utf8) + Data([0xC4, 0xE3, 0xBA, 0xC3]) + Data("\r\n".utf8)
        XCTAssertEqual(LyricsTextDecoder.decode(gb18030), "[00:01.00]你好\n")

        let utf16 = try Data([0xFF, 0xFE]) + XCTUnwrap("[00:01.00]Hi".data(using: .utf16LittleEndian))
        XCTAssertEqual(LyricsTextDecoder.decode(utf16), "[00:01.00]Hi")

        let utf8WithBOM = Data([0xEF, 0xBB, 0xBF]) + Data("[00:01.00]歌".utf8)
        XCTAssertEqual(LyricsTextDecoder.decode(utf8WithBOM), "[00:01.00]歌")
    }

    func testSameNameLyricFileWinsOverEmbeddedLyrics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-lyrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("Song.flac")
        let embedded = "[1000,1000](1000,1000,0)Embedded"

        let fromTags = await LocalLyricsImporter.ttmlForImportedAudio(at: audioURL, embeddedLyrics: embedded)
        XCTAssertTrue(fromTags?.contains("Embedded") == true)

        try Data("[00:01.00]From LRC\n[00:03.00]Next".utf8).write(to: directory.appendingPathComponent("Song.lrc"))
        let fromLRC = await LocalLyricsImporter.ttmlForImportedAudio(at: audioURL, embeddedLyrics: embedded)
        XCTAssertTrue(fromLRC?.contains("From LRC") == true)

        try Data("[1000,1000](1000,1000,0)From YRC".utf8).write(to: directory.appendingPathComponent("Song.yrc"))
        let fromYRC = await LocalLyricsImporter.ttmlForImportedAudio(at: audioURL, embeddedLyrics: embedded)
        XCTAssertTrue(fromYRC?.contains("From YRC") == true)
    }

    // MARK: - Helpers

    private func assertConversionFails(
        _ text: String,
        with expected: LyricsConversionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let ttml = try await LyricsTTMLConverter.ttml(from: text)
            XCTFail("Expected \(expected), got \(ttml)", file: file, line: line)
        } catch let error as LyricsConversionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
