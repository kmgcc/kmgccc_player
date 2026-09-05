import XCTest
@testable import NativeLyrics

final class DecoderTests: XCTestCase {
    func testStandardParentRelativeTiming() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body begin='2s'><div begin='3s'><p begin='4s' dur='5s'><span begin='1s' end='3s'>Hello</span></p></div></body></tt>".utf8)
        let document = try TTMLDecoder().decode(data)
        XCTAssertEqual(document.groups[0].main.range,LyricRange(9,14))
        XCTAssertEqual(document.groups[0].main.words[0].range,LyricRange(10,12))
    }
    func testRejectsLegacyNamespace() {
        XCTAssertThrowsError(try TTMLDecoder().decode(Data("<tt><body><div><p begin='1s' end='3s'>hello</p></div></body></tt>".utf8)))
    }
    func testSequentialContainersAndFrameTime() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml' xmlns:ttp='http://www.w3.org/ns/ttml#parameter' ttp:frameRate='25'><body><div begin='2s' timeContainer='seq'><p dur='25f'>One</p><p dur='2s'>Two</p></div></body></tt>"
        let groups = try TTMLDecoder().decode(Data(xml.utf8)).groups
        XCTAssertEqual(groups.map(\.main.range),[LyricRange(2,3),LyricRange(3,5)])
    }
    func testDuetAgentTypesAndBackground() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml' xmlns:ttm='http://www.w3.org/ns/ttml#metadata'><head><metadata><ttm:agent xml:id='a' type='person'/><ttm:agent xml:id='b' type='person'/><ttm:agent xml:id='g' type='group'/></metadata></head><body><div><p begin='1s' end='4s' ttm:agent='a'>One<span ttm:role='x-bg'>(echo)</span></p><p begin='4s' end='5s' ttm:agent='b'>Two</p><p begin='5s' end='6s' ttm:agent='g'>All</p><p begin='6s' end='7s' ttm:agent='b'>Two again</p></div></body></tt>"
        let groups = try TTMLDecoder().decode(Data(xml.utf8)).groups
        XCTAssertEqual(groups.map(\.main.isDuet),[false,true,false,true])
        XCTAssertEqual(groups[0].background?.text,"echo")
    }
    func testRubyTranslationAndTextDoNotFlattenTogether() throws {
        let xml = "<tt xmlns='http://www.w3.org/ns/ttml' xmlns:ttm='http://www.w3.org/ns/ttml#metadata' xmlns:tts='http://www.w3.org/ns/ttml#styling'><body><div><p begin='1s' end='4s'><span tts:ruby='container' begin='0s' end='3s'><span tts:ruby='base'>星</span><span tts:ruby='text'>ほし</span></span><span ttm:role='x-translation' xml:lang='en'>Star</span><span ttm:role='x-roman'>hoshi</span></p></div></body></tt>"
        let line = try TTMLDecoder().decode(Data(xml.utf8)).groups[0].main
        XCTAssertEqual(line.text,"星"); XCTAssertEqual(line.words[0].ruby[0].text,"ほし"); XCTAssertEqual(line.translations[0].text,"Star"); XCTAssertEqual(line.romanizations[0].text,"hoshi")
    }
}
