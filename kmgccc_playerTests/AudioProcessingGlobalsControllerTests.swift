import Foundation
import XCTest
@testable import kmgccc_player

@MainActor
final class AudioProcessingGlobalsControllerTests: XCTestCase {
    func testDryRunDoesNotPersistOrDispatchAndApplyPersistsJSON() throws {
        let (defaults, suiteName, storageKey) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AudioProcessingGlobalsController(
            userDefaults: defaults,
            storageKey: storageKey
        )
        var appliedRevisions = [String]()
        controller.bindPlayback { _, revision, _ in appliedRevisions.append(revision) }
        XCTAssertEqual(appliedRevisions.count, 1)

        var candidate = controller.configuration
        candidate.fade.enabled = true
        let startingRevision = controller.revisionString
        XCTAssertEqual(
            try controller.apply(candidate, expectedRevision: startingRevision, dryRun: true),
            startingRevision
        )
        XCTAssertEqual(controller.configuration.fade.enabled, false)
        XCTAssertNil(defaults.data(forKey: storageKey))
        XCTAssertEqual(appliedRevisions.count, 1)

        let appliedRevision = try controller.apply(candidate, expectedRevision: startingRevision)
        XCTAssertNotEqual(appliedRevision, startingRevision)
        XCTAssertEqual(controller.configuration, candidate)
        XCTAssertEqual(appliedRevisions.count, 2)
        let data = try XCTUnwrap(defaults.data(forKey: storageKey))
        XCTAssertEqual(try JSONDecoder().decode(AudioProcessingGlobals.self, from: data), candidate)

        let reloaded = AudioProcessingGlobalsController(userDefaults: defaults, storageKey: storageKey)
        XCTAssertEqual(reloaded.configuration, candidate)
    }

    func testReferenceIsStoredPerDeviceAndIgnoredForExternalPlayback() throws {
        let (defaults, suiteName, storageKey) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AudioProcessingGlobalsController(
            userDefaults: defaults,
            storageKey: storageKey
        )
        controller.publishRuntimeState(AudioProcessingRuntimeState(
            outputDeviceUID: "device-A",
            appGain: 0.5
        ))
        _ = try controller.useCurrentVolumeAsReference()
        let expectedReferenceDB = 20 * log10(0.5)
        XCTAssertEqual(controller.deviceReference(for: "device-A")!, expectedReferenceDB, accuracy: 1e-8)
        XCTAssertEqual(controller.equalLoudnessContext.referenceDB!, expectedReferenceDB, accuracy: 1e-8)

        controller.setSourceIsLocal(false)
        controller.publishRuntimeState(AudioProcessingRuntimeState(
            outputDeviceUID: "stale-device",
            appGain: 0.25
        ))
        XCTAssertNil(controller.runtimeState.outputDeviceUID)
        XCTAssertEqual(controller.configuration.deviceReferences["device-A"], expectedReferenceDB)

        controller.detachPlayback()
        XCTAssertNil(controller.applyConfiguration)
        XCTAssertNil(controller.runtimeState.transport)
    }

    func testApplyRejectsInvalidRangesWithoutChangingConfiguration() throws {
        let (defaults, suiteName, storageKey) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AudioProcessingGlobalsController(
            userDefaults: defaults,
            storageKey: storageKey
        )
        var invalid = controller.configuration
        invalid.loudness.maxBoostDB = 24.1
        XCTAssertThrowsError(try controller.apply(invalid))
        XCTAssertEqual(controller.configuration, AudioProcessingGlobals())
        XCTAssertNil(defaults.data(forKey: storageKey))
    }

    private func makeDefaults() -> (UserDefaults, String, String) {
        let suiteName = "AudioProcessingGlobalsControllerTests.\(UUID().uuidString)"
        let storageKey = "audio.processing-globals.test"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName, storageKey)
    }
}
