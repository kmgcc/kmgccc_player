import XCTest
@testable import kmgccc_player

@MainActor
final class SidebarSetBarConfigurationTests: XCTestCase {
    func testDefaultContainsOnlySettingsAndFullscreenInOneGroup() {
        XCTAssertEqual(SidebarSetBarConfiguration.defaultValue.items.map(\.kind), [.settings, .fullscreen])
    }

    func testSeparatorsDoNotConsumeTheFourButtonCapacity() {
        let configuration = SidebarSetBarConfiguration(items: [
            SidebarSetBarItem(kind: .settings),
            SidebarSetBarItem(kind: .separator),
            SidebarSetBarItem(kind: .appearance),
            SidebarSetBarItem(kind: .separator),
            SidebarSetBarItem(kind: .fullscreen),
            SidebarSetBarItem(kind: .separator),
            SidebarSetBarItem(kind: .hdr),
        ])

        XCTAssertEqual(configuration.buttonCount, 4)
        XCTAssertEqual(configuration.items.count, 7)
        XCTAssertEqual(configuration.inserting(SidebarSetBarItem(kind: .motionArtwork), at: 0), configuration)
    }

    func testMovingAButtonAtCapacityPreservesItsIdentityAndDropPosition() {
        let configuration = SidebarSetBarConfiguration(items: [
            SidebarSetBarItem(kind: .settings),
            SidebarSetBarItem(kind: .appearance),
            SidebarSetBarItem(kind: .fullscreen),
            SidebarSetBarItem(kind: .hdr),
        ])
        let firstID = configuration.items[0].id
        let movedToEnd = configuration.moving(firstID, to: 4)

        XCTAssertEqual(movedToEnd.items.map(\.id), Array(configuration.items.dropFirst().map(\.id)) + [firstID])
        XCTAssertEqual(movedToEnd.moving(firstID, to: 0), configuration)
    }

    func testButtonsAreUniqueAndAvailableOnlyInOneArea() {
        let settings = SidebarSetBarItem(kind: .settings)
        let configuration = SidebarSetBarConfiguration(items: [
            settings, SidebarSetBarItem(kind: .settings), SidebarSetBarItem(kind: .fullscreen),
        ])
        XCTAssertEqual(configuration.items.map(\.kind), [.settings, .fullscreen])
        XCTAssertEqual(configuration.items.first?.id, settings.id)
        XCTAssertFalse(configuration.availableKinds.contains(.settings))
        XCTAssertFalse(configuration.availableKinds.contains(.fullscreen))
        XCTAssertTrue(configuration.availableKinds.contains(.separator))
        XCTAssertTrue(configuration.availableKinds.contains(.lyrics))
        for kind in [
            SidebarSetBarItemKind.volumeTarget,
            .soundEffects,
            .externalPlayback,
            .backgroundPreparation,
            .latencyCompensation,
        ] {
            XCTAssertTrue(configuration.availableKinds.contains(kind))
        }
        XCTAssertTrue(configuration.removing(settings.id).availableKinds.contains(.settings))
        XCTAssertEqual(configuration.inserting(SidebarSetBarItem(kind: .settings), at: 0), configuration)
    }

    func testReadingEarlierLayoutsDiscardsDuplicateButtons() throws {
        let data = try JSONEncoder().encode(["items": [
            SidebarSetBarItem(kind: .settings),
            SidebarSetBarItem(kind: .separator),
            SidebarSetBarItem(kind: .settings),
            SidebarSetBarItem(kind: .fullscreen),
        ]])
        let decoded = try JSONDecoder().decode(SidebarSetBarConfiguration.self, from: data)
        XCTAssertEqual(decoded.items.map(\.kind), [.settings, .separator, .fullscreen])
    }

    func testRemovingASeparatorJoinsItsNeighborsWithoutRemovingButtons() {
        let separator = SidebarSetBarItem(kind: .separator)
        let configuration = SidebarSetBarConfiguration(items: [
            SidebarSetBarItem(kind: .settings), separator, SidebarSetBarItem(kind: .fullscreen),
        ])

        XCTAssertEqual(configuration.removing(separator.id).items.map(\.kind), [.settings, .fullscreen])
    }

    func testRemovingButtonsDiscardsOrphanedAndAdjacentSeparators() {
        let configuration = SidebarSetBarConfiguration(items: [
            SidebarSetBarItem(kind: .settings),
            SidebarSetBarItem(kind: .separator),
            SidebarSetBarItem(kind: .appearance),
            SidebarSetBarItem(kind: .separator),
            SidebarSetBarItem(kind: .fullscreen),
        ])
        let removedMiddle = configuration.removing(configuration.items[2].id)
        XCTAssertEqual(removedMiddle.items.map(\.kind), [.settings, .separator, .fullscreen])
        let removedFirst = removedMiddle.removing(configuration.items[0].id)
        XCTAssertEqual(removedFirst.items.map(\.kind), [.fullscreen])
        XCTAssertTrue(removedFirst.removing(configuration.items[4].id).items.isEmpty)
    }

    func testRoundTripPreservesEmptyLayoutAndItemIdentities() throws {
        let configurations = [
            SidebarSetBarConfiguration(items: []),
            SidebarSetBarConfiguration(items: [
                SidebarSetBarItem(kind: .fullscreen),
                SidebarSetBarItem(kind: .separator),
                SidebarSetBarItem(kind: .settings),
            ]),
        ]
        for configuration in configurations {
            let data = try JSONEncoder().encode(configuration)
            XCTAssertEqual(try JSONDecoder().decode(SidebarSetBarConfiguration.self, from: data), configuration)
        }
    }
}
