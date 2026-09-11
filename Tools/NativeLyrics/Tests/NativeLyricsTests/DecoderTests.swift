import XCTest
@testable import NativeLyrics

final class DecoderTests: XCTestCase {
    func testStandardParentRelativeTiming() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body begin='2s'><div begin='3s'><p begin='4s' dur='5s'><span begin='1s' end='3s'>Hello</span></p></div></body></tt>".utf8)
        let document = try TTMLDecoder(profile: .w3cRelative).decode(data)
        XCTAssertEqual(document.groups[0].main.range,LyricRange(9,14))
        XCTAssertEqual(document.groups[0].main.words[0].range,LyricRange(10,12))
    }

    func testAMLLAbsoluteTimingIsTheDefaultAndDoesNotAddParentOrigins() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div begin='10s' end='20s'><p begin='12s' end='16s'><span begin='12s' end='13s'>One</span><span begin='15.5' end='16'> two</span></p></div></body></tt>".utf8)
        let document = try TTMLDecoder().decode(data)
        let line = try XCTUnwrap(document.groups.first?.main)
        XCTAssertEqual(line.range, LyricRange(12, 16))
        XCTAssertEqual(line.words[0].range, LyricRange(12, 13))
        XCTAssertEqual(line.words[1].range, LyricRange(15.5, 16))
        XCTAssertEqual(document.timingMode, .word)
    }

    func testBareSecondsAndNamespaceShadowAreAcceptedByAMLLProfile() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml' xmlns:ttm='http://www.w3.org/ns/ttml#metadata'><body xmlns='' dur='12.5'><div xmlns='' begin='10' end='12.5'><p begin='10' end='12.5' ttm:role='x-bg'> (echo) </p></div></body></tt>"
        let document = try TTMLDecoder().decode(Data(xml.utf8))
        XCTAssertEqual(document.groups.first?.main.range, LyricRange(10, 12.5))
        XCTAssertEqual(document.groups.first?.main.text, "(echo)")
        XCTAssertTrue(document.diagnostics.contains { $0.contains("namespace") })
    }

    func testLineTimingIgnoresInnerWordClocks() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml' xmlns:itunes='http://music.apple.com/lyric-ttml-internal' itunes:timing='Line'><body><div><p begin='2s' end='5s'><span begin='2s' end='3s'>One</span> <span begin='4s' end='5s'>two</span></p></div></body></tt>"
        let line = try TTMLDecoder().decode(Data(xml.utf8)).groups[0].main
        XCTAssertEqual(line.text, "One two")
        XCTAssertFalse(line.isWordTimed)
        XCTAssertEqual(line.words.count, 1)
        XCTAssertEqual(line.words[0].range, LyricRange(2, 5))
    }

    func testSongPartAndAmllMetadataAreRetained() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml' xmlns:amll='http://www.example.com/ns/amll' xmlns:itunes='http://itunes.apple.com/lyric-ttml-extensions'><head><metadata><amll:meta key='musicName' value='Song'/><amll:meta key='artists' value='Artist'/></metadata></head><body><div begin='1s' end='2s' itunes:song-part='Chorus'><p begin='1s' end='2s' itunes:key='L1'>Line</p></div></body></tt>"
        let document = try TTMLDecoder().decode(Data(xml.utf8))
        XCTAssertEqual(document.title, "Song")
        XCTAssertEqual(document.metadata["artists"], ["Artist"])
        XCTAssertEqual(document.groups[0].main.songPart, "Chorus")
        XCTAssertEqual(document.groups[0].main.blockIndex, 1)
    }

    func testAppleSidecarTranslationAndRomanizationKeepAbsoluteWordClocks() throws {
        let xml = """
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <head>
            <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
              <translations>
                <translation xml:lang="zh-Hans">
                  <text for="L1"><span begin="1.5" end="2.0">你</span><span begin="2.0" end="2.5">好</span></text>
                </translation>
              </translations>
              <transliterations>
                <transliteration xml:lang="ja-Latn">
                  <text for="L1"><span begin="1.5" end="2.5">nihao</span></text>
                </transliteration>
              </transliterations>
            </iTunesMetadata>
          </head>
          <body><div><p begin="1" end="3" itunes:key="L1" ttm:agent="v1">你好</p></div></body>
        </tt>
        """
        let line = try TTMLDecoder().decode(Data(xml.utf8)).groups[0].main

        XCTAssertEqual(line.translations.map(\.language), ["zh-Hans"])
        XCTAssertEqual(line.translations[0].text, "你好")
        XCTAssertEqual(line.translations[0].words.map(\.range), [LyricRange(1.5, 2), LyricRange(2, 2.5)])
        XCTAssertEqual(line.romanizations.map(\.language), ["ja-Latn"])
        XCTAssertEqual(line.romanizations[0].text, "nihao")
        XCTAssertEqual(line.romanizations[0].words[0].range, LyricRange(1.5, 2.5))
    }

    func testSmallInvertedAMLLWordRangeIsCollapsedWithDiagnostic() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='30s' end='31s'><span begin='30.349' end='30.331'>word</span></p></div></body></tt>"
        let document = try TTMLDecoder().decode(Data(xml.utf8))
        XCTAssertEqual(document.groups[0].main.words[0].range, LyricRange(30.349, 30.349))
        XCTAssertTrue(document.diagnostics.contains { $0.contains("inverted AMLL timing") })
    }

    func testCompactMinuteClockIsAccepted() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='04:24.615' end='04:28.000'>Compact</p></div></body></tt>".utf8)
        let line = try TTMLDecoder().decode(data).groups[0].main
        XCTAssertEqual(line.range, LyricRange(264.615, 268))
    }
    func testInlineWhitespaceBetweenTimedSpansIsPreserved() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='1s' end='3s'><span begin='1s' end='2s'>Hello</span> <span begin='2s' end='3s'>world</span></p></div></body></tt>"
        let line = try TTMLDecoder().decode(Data(xml.utf8)).groups[0].main
        XCTAssertEqual(line.text,"Hello world")
        XCTAssertEqual(line.words.map(\.text),["Hello"," ","world"])
    }
    func testAcceptsLegacyNamespaceInAMLLProfile() throws {
        let document = try TTMLDecoder().decode(Data("<tt><body><div><p begin='1s' end='3s'>hello</p></div></body></tt>".utf8))
        XCTAssertEqual(document.groups.first?.main.range, LyricRange(1, 3))
    }
    func testSequentialContainersAndFrameTime() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml' xmlns:ttp='http://www.w3.org/ns/ttml#parameter' ttp:frameRate='25'><body><div begin='2s' timeContainer='seq'><p dur='25f'>One</p><p dur='2s'>Two</p></div></body></tt>"
        let groups = try TTMLDecoder(profile: .w3cRelative).decode(Data(xml.utf8)).groups
        XCTAssertEqual(groups.map(\.main.range),[LyricRange(2,3),LyricRange(3,5)])
    }
    func testDuetAgentTypesAndBackground() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml' xmlns:ttm='http://www.w3.org/ns/ttml#metadata'><head><metadata><ttm:agent xml:id='a' type='person'/><ttm:agent xml:id='b' type='person'/><ttm:agent xml:id='g' type='group'/></metadata></head><body><div><p begin='1s' end='4s' ttm:agent='a'>One<span ttm:role='x-bg'>(echo)</span></p><p begin='4s' end='5s' ttm:agent='b'>Two</p><p begin='5s' end='6s' ttm:agent='g'>All</p><p begin='6s' end='7s' ttm:agent='b'>Two again</p></div></body></tt>"
        let groups = try TTMLDecoder().decode(Data(xml.utf8)).groups
        XCTAssertEqual(groups.map(\.main.isDuet),[false,true,false,true])
        XCTAssertEqual(groups[0].background?.text,"echo")
    }
    func testRubyTranslationAndTextDoNotFlattenTogether() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml' xmlns:ttm='http://www.w3.org/ns/ttml#metadata' xmlns:tts='http://www.w3.org/ns/ttml#styling'><body><div><p begin='1s' end='4s'><span tts:ruby='container' begin='1s' end='4s'><span tts:ruby='base'>星</span><span tts:ruby='text' begin='1s' end='4s'>ほし</span></span><span ttm:role='x-translation' xml:lang='en'>Star</span><span ttm:role='x-roman'>hoshi</span></p></div></body></tt>"
        let line = try TTMLDecoder().decode(Data(xml.utf8)).groups[0].main
        XCTAssertEqual(line.text,"星"); XCTAssertEqual(line.words[0].ruby[0].text,"ほし"); XCTAssertEqual(line.translations[0].text,"Star"); XCTAssertEqual(line.romanizations[0].text,"hoshi")
    }
}
