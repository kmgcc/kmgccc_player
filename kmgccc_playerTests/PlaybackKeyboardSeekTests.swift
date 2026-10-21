import AppKit
import XCTest
@testable import kmgccc_player

@MainActor
final class PlaybackKeyboardSeekTests: XCTestCase {
    func testPlaybackArrowsMoveTheTextCaretIncludingKeyRepeats() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        editor.string = "1.25"
        window.contentView = editor
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 2, length: 0))

        let left = try keyEvent(123, characters: "\u{F702}", window: window)
        XCTAssertTrue(AppDelegate.routePlaybackKeyToTextInput(left, in: window))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
        let right = try keyEvent(124, characters: "\u{F703}", window: window, isARepeat: true)
        XCTAssertTrue(AppDelegate.routePlaybackKeyToTextInput(right, in: window))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))

        let space = try keyEvent(49, characters: " ", window: window)
        XCTAssertTrue(AppDelegate.routePlaybackKeyToTextInput(space, in: window))
        XCTAssertEqual(editor.string, "1. 25")
        XCTAssertTrue(AppDelegate.routePlaybackKeyToTextInput(
            try keyEvent(123, characters: "\u{F702}", window: window, modifiers: .command), in: window))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertTrue(AppDelegate.routePlaybackKeyToTextInput(
            try keyEvent(124, characters: "\u{F703}", window: window, modifiers: .shift), in: window))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 1))

        window.makeFirstResponder(nil)
        XCTAssertFalse(AppDelegate.routePlaybackKeyToTextInput(left, in: window))
    }

    private func keyEvent(
        _ keyCode: UInt16,
        characters: String,
        window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: isARepeat, keyCode: keyCode))
    }

    func testRapidSameDirectionTapsAccelerateToThirtySeconds() {
        var acceleration = PlaybackSeekAcceleration()
        let times = stride(from: 0.0, through: 1.0, by: 0.2)
        let steps = times.map {
            acceleration.nextStep(direction: .forward, at: $0)
        }

        XCTAssertEqual(steps.map(\.seconds), [3, 6, 10, 15, 20, 30])
        XCTAssertFalse(steps[0].continuesFromPreviousTarget)
        XCTAssertTrue(steps.dropFirst().allSatisfy(\.continuesFromPreviousTarget))
    }

    func testDirectionChangeOrSlowTapRestartsAtThreeSeconds() {
        var acceleration = PlaybackSeekAcceleration()

        _ = acceleration.nextStep(direction: .forward, at: 10)
        let changedDirection = acceleration.nextStep(direction: .backward, at: 10.2)
        let slowTap = acceleration.nextStep(direction: .backward, at: 11)

        XCTAssertEqual(changedDirection.seconds, 3)
        XCTAssertFalse(changedDirection.continuesFromPreviousTarget)
        XCTAssertEqual(slowTap.seconds, 3)
        XCTAssertFalse(slowTap.continuesFromPreviousTarget)
    }
}
