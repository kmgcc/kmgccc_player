import Foundation
import SwiftUI
import XCTest
@testable import kmgccc_player

@MainActor
final class SkinComponentCompletionTests: XCTestCase {
    func testStandaloneCapsulesMayFormMultiplePairsAcrossContainers() {
        let root = SkinSceneNode(id: "scene", content: .overlay(children: [
            SkinSceneNode(id: "left", content: .row(children: [
                .component("left-a", "native.actionsCapsule"),
                .component("left-b", "native.actionsCapsule"),
            ], spacing: 8)),
            SkinSceneNode(id: "right", content: .column(children: [
                .component("right-a", "native.volumeCapsule"),
                .component("right-b", "native.volumeCapsule"),
            ], spacing: 8)),
        ]))

        XCTAssertTrue(SkinSceneDocument(root: root).hasPairedStandaloneCapsulesInEveryLayout)
    }

    func testCapsulePairsAreCheckedForEachAdaptiveLayout() {
        let wide = SkinSceneNode(id: "wide", content: .overlay(children: [
            .component("wide-left", "native.actionsCapsule"),
            .component("wide-right", "native.volumeCapsule"),
            .component("wide-left-2", "native.actionsCapsule"),
            .component("wide-right-2", "native.volumeCapsule"),
        ]))
        let compact = SkinSceneNode(id: "compact", content: .row(children: [
            .component("compact-left", "native.actionsCapsule"),
            .component("compact-right", "native.volumeCapsule"),
        ], spacing: 8))
        let root = SkinSceneNode(id: "scene", content: .adaptive(
            minimumWidth: 720, wide: wide, compact: compact
        ))

        XCTAssertTrue(SkinSceneDocument(root: root).hasPairedStandaloneCapsulesInEveryLayout)
    }

    func testUnpairedCapsuleInOneAdaptiveLayoutFailsPairingCheck() {
        let wide = SkinSceneNode(id: "wide", content: .overlay(children: [
            .component("wide-left", "native.actionsCapsule"),
            .component("wide-right", "native.volumeCapsule"),
        ]))
        let compact = SkinSceneNode.component("compact-left", "native.actionsCapsule")
        let root = SkinSceneNode(id: "scene", content: .adaptive(
            minimumWidth: 720, wide: wide, compact: compact
        ))

        XCTAssertFalse(SkinSceneDocument(root: root).hasPairedStandaloneCapsulesInEveryLayout)
    }

    func testInvisibleCapsuleDoesNotPairWithVisibleCapsule() {
        let root = SkinSceneNode(id: "scene", content: .overlay(children: [
            .component("hidden-left", "native.actionsCapsule", layout: .init(opacity: 0)),
            .component("visible-right", "native.volumeCapsule"),
        ]))

        XCTAssertFalse(SkinSceneDocument(root: root).hasPairedStandaloneCapsulesInEveryLayout)
    }

    func testHitTestingDoesNotChangeWhetherVisibleCapsulesArePaired() {
        let root = SkinSceneNode(id: "scene", content: .overlay(children: [
            .component("left", "native.actionsCapsule", layout: .init(allowsHitTesting: false)),
            .component("right", "native.volumeCapsule"),
        ]))

        XCTAssertTrue(SkinSceneDocument(root: root).hasPairedStandaloneCapsulesInEveryLayout)
    }

    func testCompleteMiniPlayerNeedsNoStandaloneCapsulePair() {
        let root = SkinSceneNode.component("mini", "native.miniPlayer")

        XCTAssertTrue(SkinSceneDocument(root: root).hasPairedStandaloneCapsulesInEveryLayout)
    }

    func testHiddenJSONControlsDoNotAdvertiseActionsToHost() {
        let invisible = SkinSceneNode.component(
            "quick-panel", "native.quickPanel", layout: .init(opacity: 0)
        )
        let notHitTestable = SkinSceneNode.component(
            "fullscreen", "native.fullscreen", layout: .init(allowsHitTesting: false)
        )
        let zeroSized = SkinSceneNode.component(
            "lyrics", "native.lyricsToggle", layout: .init(width: 0, height: 32)
        )
        let custom = SkinSceneNode.component(
            "custom-controls", "author.controls", layout: .init(maximumWidth: 320)
        )

        XCTAssertFalse(invisible.shouldAdvertiseControls)
        XCTAssertFalse(notHitTestable.shouldAdvertiseControls)
        XCTAssertFalse(zeroSized.shouldAdvertiseControls)
        XCTAssertTrue(custom.shouldAdvertiseControls)
    }

    func testSelfDrawnControlDeclarationsMergeAcrossScene() {
        var declared = SkinSceneControlsKey.defaultValue
        SkinSceneControlsKey.reduce(value: &declared) { [.playPause, .previous] }
        SkinSceneControlsKey.reduce(value: &declared) { [.lyricsToggle, .fullscreen, .quickPanel] }

        XCTAssertEqual(declared, [.playPause, .previous, .lyricsToggle, .fullscreen, .quickPanel])
    }

    func testNativeSceneDocumentRoundTripsComposedAdaptiveTree() throws {
        let tree = SkinSceneNode(id: "scene", content: .adaptive(
            minimumWidth: 720,
            wide: SkinSceneNode(id: "wide", content: .column(children: [
                .component("cover", "native.artwork", values: ["cornerRadius": .number(16)]),
                .component("left", "native.actionsCapsule"),
                .component("lyrics", "native.lyrics", values: ["fontSize": .number(42)]),
                .component("right", "native.volumeCapsule"),
            ], spacing: 12)),
            compact: SkinSceneNode(id: "compact", content: .row(children: [
                .component("transport", "native.transport", values: ["spacing": .number(10)]),
                .component("artwork", "native.artwork"),
            ], spacing: 16))
        ))
        let original = SkinSceneDocument(root: tree)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SkinSceneDocument.self, from: encoded)

        XCTAssertEqual(decoded.root.id, "scene")
        XCTAssertEqual(decoded.componentTypes, original.componentTypes)
        XCTAssertEqual(decoded.simultaneousLyricsCount, 1)
        XCTAssertTrue(decoded.hasPairedStandaloneCapsulesInEveryLayout)
    }
}
