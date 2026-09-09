import XCTest
@testable import NativeLyrics

final class TimingPolicyTests: XCTestCase {
    func testCurrentPlayerAppliesVisualOffsetLeadInNearGapAndCapsPreviousLine() {
        let first = LyricLine(
            id: "first",
            range: .init(1, 3),
            words: [LyricWord(id: "first-word", text: "First", range: .init(1, 3))],
            isWordTimed: true
        )
        let second = LyricLine(
            id: "second",
            range: .init(3.1, 5),
            words: [LyricWord(id: "second-word", text: "Second", range: .init(3.1, 5))],
            isWordTimed: true
        )
        let document = LyricsDocument(
            groups: [
                LyricGroup(main: first),
                LyricGroup(main: second)
            ],
            title: "timing",
            duration: 5,
            diagnostics: []
        )
        var configuration = LyricsConfiguration()
        configuration.timing.trackOffset = 0.2
        configuration.timing.globalAdvance = 0.1
        configuration.timing.leadIn = 0.6
        configuration.timing.nearSwitchGap = 0.16

        let prepared = TimingPolicy.prepare(document, configuration)
        XCTAssertEqual(prepared[0].range.start, 0.1, accuracy: 0.0001)
        // The near-switch line starts 600 ms early and caps the previous line
        // at the same visual boundary instead of manufacturing a new overlap.
        XCTAssertEqual(prepared[1].range.start, 2.6, accuracy: 0.0001)
        XCTAssertEqual(prepared[0].range.end, 2.6, accuracy: 0.0001)
        XCTAssertEqual(prepared[1].main.words[0].range.start, 2.94, accuracy: 0.0001)
    }

    func testDisabledPolicyStillAppliesExplicitVisualOffset() {
        let line = LyricLine(
            id: "line",
            range: .init(2, 4),
            words: [LyricWord(id: "word", text: "Line", range: .init(2, 4))]
        )
        let document = LyricsDocument(
            groups: [LyricGroup(main: line)],
            title: "timing",
            duration: 4,
            diagnostics: []
        )
        var configuration = LyricsConfiguration()
        configuration.timing.enabled = false
        configuration.timing.trackOffset = 1
        configuration.timing.globalAdvance = 0.5
        let prepared = TimingPolicy.prepare(document, configuration)
        // The explicit track/global correction is presentation state; the
        // `enabled` switch only disables lead-in/near-switch preprocessing.
        XCTAssertEqual(prepared[0].range, .init(2.5, 4.5))
        XCTAssertEqual(prepared[0].main.words[0].range, .init(2.5, 4.5))
    }

    func testCombinedVisualOffsetKeepsTheDocumentedTwentySecondBound() {
        let line = LyricLine(
            id: "line",
            range: .init(30, 32),
            words: [LyricWord(id: "word", text: "Line", range: .init(30, 32))]
        )
        let document = LyricsDocument(
            groups: [LyricGroup(main: line)],
            title: "timing",
            duration: 32,
            diagnostics: []
        )
        var configuration = LyricsConfiguration()
        configuration.timing.trackOffset = 20
        let prepared = TimingPolicy.prepare(document, configuration)
        // The first line also receives the normal one-second lead-in cap;
        // the important part is that the 20-second offset survives (a
        // legacy ±15-second clamp would produce 45 seconds here).
        XCTAssertEqual(prepared[0].range, .init(49, 52))
    }

    func testCanonicalAdjacentSampleKeepsLeadInWithoutManufacturingOverlap() {
        // The documented AMLL regression has an ordinary preceding line, then
        // L5/L6 with touching authored ranges.  L5 receives the fallback
        // one-second lead but is bounded by L4's end; L6 receives the near
        // switch lead and clips L5 at its final visual start.
        func line(_ id: String, _ start: Double, _ end: Double) -> LyricLine {
            LyricLine(
                id: id,
                range: .init(start, end),
                words: [LyricWord(id: id + "-word", text: id, range: .init(start, end))],
                isWordTimed: true
            )
        }
        let document = LyricsDocument(
            groups: [
                LyricGroup(main: line("L4", 30, 33.119)),
                LyricGroup(main: line("L5", 33.469, 33.877)),
                LyricGroup(main: line("L6", 33.877, 35.504))
            ],
            title: "sample",
            duration: 36,
            diagnostics: []
        )
        var configuration = LyricsConfiguration()
        configuration.timing.leadIn = 0.6
        configuration.timing.nearSwitchGap = 0.16

        let prepared = TimingPolicy.prepare(document, configuration)
        XCTAssertEqual(prepared[1].range.start, 33.119, accuracy: 0.0001)
        XCTAssertEqual(prepared[1].range.end, 33.277, accuracy: 0.0001)
        XCTAssertEqual(prepared[2].range.start, 33.277, accuracy: 0.0001)
        XCTAssertEqual(prepared[1].range.end, prepared[2].range.start, accuracy: 0.0001)
    }

    func testBackgroundIsSkippedWhenFindingPreviousMainForNearSwitch() {
        let main = LyricLine(
            id: "main",
            range: .init(0, 3),
            words: [LyricWord(id: "main-word", text: "main", range: .init(0, 3))],
            isWordTimed: true
        )
        var background = LyricLine(
            id: "background",
            range: .init(0.4, 2.8),
            words: [LyricWord(id: "background-word", text: "background", range: .init(0.4, 2.8))],
            isWordTimed: true,
            isBackground: true
        )
        background.isBackground = true
        let next = LyricLine(
            id: "next",
            range: .init(3.1, 5),
            words: [LyricWord(id: "next-word", text: "next", range: .init(3.1, 5))],
            isWordTimed: true
        )
        let document = LyricsDocument(
            groups: [
                LyricGroup(main: main, background: background),
                LyricGroup(main: next)
            ],
            title: "background",
            duration: 5,
            diagnostics: []
        )
        var configuration = LyricsConfiguration()
        configuration.timing.leadIn = 0.6
        configuration.timing.nearSwitchGap = 0.16

        let prepared = TimingPolicy.prepare(document, configuration)
        // The 0.1-second gap is measured from the preceding main end (3.0),
        // not from the attached background's authored end (2.8).
        XCTAssertEqual(prepared[1].range.start, 2.5, accuracy: 0.0001)
        XCTAssertEqual(prepared[0].range.end, 2.5, accuracy: 0.0001)
        XCTAssertEqual(prepared[0].background?.range.end ?? .nan, 2.5, accuracy: 0.0001)
    }

    func testEarlyWordLeadUsesMillisecondFloorInNativeSeconds() {
        let first = LyricLine(
            id: "first",
            range: .init(0, 0.8),
            words: [LyricWord(id: "first-word", text: "first", range: .init(0, 0.8))],
            isWordTimed: true
        )
        let second = LyricLine(
            id: "second",
            range: .init(1, 1.4),
            words: [
                LyricWord(id: "second-a", text: "a", range: .init(1, 1.05)),
                LyricWord(id: "second-b", text: "b", range: .init(1.05, 1.4))
            ],
            isWordTimed: true
        )
        let document = LyricsDocument(
            groups: [LyricGroup(main: first), LyricGroup(main: second)],
            title: "subsecond-front-words",
            duration: 2,
            diagnostics: []
        )
        var configuration = LyricsConfiguration()
        configuration.timing.leadIn = 0.6
        configuration.timing.nearSwitchGap = 0.16

        let prepared = TimingPolicy.prepare(document, configuration)
        let words = prepared[1].main.words

        // The 180 ms lead is distributed across the authored 400 ms front
        // segment.  A one-second floor would incorrectly produce 879 ms here
        // instead of the AMLL-equivalent 892.5 ms boundary.
        XCTAssertEqual(words[0].range.start, 0.82, accuracy: 0.0001)
        XCTAssertEqual(words[0].range.end, 0.8925, accuracy: 0.0001)
        XCTAssertEqual(words[1].range.start, 0.8925, accuracy: 0.0001)
        XCTAssertEqual(words[1].range.end, 1.4, accuracy: 0.0001)
    }
}
