import Foundation
import XCTest
@testable import kmgccc_player

@MainActor
final class AudioDSPControllerTests: XCTestCase {
    func testDefaultPresetStartsDisabledAndAnEditCreatesAPersistentIndependentCopy() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()
        XCTAssertEqual(controller.selectedPresetID, DSPPresetDocument.defaultPresetID)
        XCTAssertEqual(controller.configuration, AudioDSPConfiguration.defaultEffects)
        XCTAssertFalse(controller.configuration.enabled)
        XCTAssertFalse(controller.isModified)

        controller.updateConfiguration(commit: true) { $0.enabled = true }
        let editedID = try XCTUnwrap(controller.selectedPresetID)
        XCTAssertFalse(DSPPresetDocument.isBuiltIn(editedID))
        await controller.flushPendingPersistence()
        let builtIn = try await store.preset(id: DSPPresetDocument.defaultPresetID)
        XCTAssertEqual(builtIn, DSPPresetDocument.defaultEffects)
        do {
            _ = try await store.save(builtIn)
            XCTFail("The default preset must remain immutable")
        } catch let error as DSPPresetStoreError {
            XCTAssertEqual(error, .immutableBuiltIn)
        }

        let restored = AudioDSPController(store: store)
        await restored.ensureLoaded()
        XCTAssertEqual(restored.selectedPresetID, editedID)
        XCTAssertEqual(restored.configuration, controller.configuration)
        XCTAssertFalse(restored.isModified)
    }

    func testCalibrationPreviewEnablesProcessingAndCancellationRestoresBothSwitches() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dsp = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await dsp.ensureLoaded()
        let controller = EqualLoudnessController()
        let calibration = EqualLoudnessCalibration(
            deviceKey: "test-output", deviceName: "Test", axis: .percent,
            points: [EqualLoudnessCalibrationPoint(coordinate: 20, bassDB: 4, trebleDB: 2)]
        )
        for chainEnabled in [false, true] {
            for stageEnabled in [false, true] {
                dsp.updateConfiguration(commit: true) {
                    $0.enabled = chainEnabled
                    $0.equalLoudness.enabled = stageEnabled
                    $0.equalLoudness.calibration = calibration
                }
                controller.beginCalibration(using: dsp)
                // Re-entering a step must retain the original switch snapshot.
                controller.beginCalibration(using: dsp)
                let preview = DSPEqualLoudnessGains(bassDB: 5, trebleDB: 2.5)
                controller.setPreview(preview)
                XCTAssertEqual(DSPEqualLoudnessMath.chainGains(configuration: dsp.configuration,
                                                              context: controller.context), preview)
                controller.endCalibration(using: dsp)
                XCTAssertEqual(dsp.configuration.enabled, chainEnabled)
                XCTAssertEqual(dsp.configuration.equalLoudness.enabled, stageEnabled)
                XCTAssertEqual(dsp.configuration.equalLoudness.calibration, calibration)
                XCTAssertNil(controller.previewGains)
            }
        }
        await dsp.flushPendingPersistence()
    }

    func testSavingCalibrationKeepsCompensationEnabledAfterDialogCloses() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dsp = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await dsp.ensureLoaded()
        dsp.updateConfiguration(commit: true) {
            $0.enabled = false
            $0.equalLoudness.enabled = false
        }
        let controller = EqualLoudnessController()
        controller.beginCalibration(using: dsp)
        let calibration = EqualLoudnessCalibration(
            deviceKey: "test-output", deviceName: "Test", axis: .percent,
            points: [
                EqualLoudnessCalibrationPoint(coordinate: 12.5, bassDB: 7, trebleDB: 3),
                EqualLoudnessCalibrationPoint(coordinate: 31.25, bassDB: 0, trebleDB: 0),
                EqualLoudnessCalibrationPoint(coordinate: 50, bassDB: -2, trebleDB: -1),
            ]
        )
        dsp.updateConfiguration(commit: true) { $0.equalLoudness.calibration = calibration }
        controller.endCalibration(using: dsp, keepingEnabled: true)
        controller.endCalibration(using: dsp) // onDisappear after the completed screen
        XCTAssertTrue(dsp.configuration.enabled)
        XCTAssertTrue(dsp.configuration.equalLoudness.enabled)
        XCTAssertNil(controller.previewGains)
        let context = DSPEqualLoudnessContext(
            volume: .available(OutputDeviceVolumeReading(
                deviceUID: "test-output", deviceName: "Test", scalar: 0.125,
                decibelsBelowMaximum: nil, isMuted: false, isWritable: true
            )), deviceKey: "test-output"
        )
        XCTAssertEqual(DSPEqualLoudnessMath.chainGains(configuration: dsp.configuration, context: context),
                       DSPEqualLoudnessGains(bassDB: 7, trebleDB: 3))
        await dsp.flushPendingPersistence()
    }

    func testLoadMonitoringKeepsMultipleWindowsAndRejectsRetiredVisibilityGeneration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        controller.updateConfiguration(commit: true) { $0.enabled = true }
        var requests: [(Bool, UUID)] = []
        var appliedID: UUID?
        let binding = controller.bindPlayback(monitorLoad: { enabled, generation in
            requests.append((enabled, generation))
        }) { _, _, id in appliedID = id }
        let first = UUID(), second = UUID()
        controller.setProcessingLoadVisible(true, observerID: first)
        let generation = try XCTUnwrap(requests.last).1
        controller.setProcessingLoadVisible(true, observerID: second)
        controller.setProcessingLoadVisible(false, observerID: first)
        XCTAssertEqual(requests.map { $0.0 }, [false, true])
        let snapshot = processingLoadSnapshot(controller: controller, requestID: try XCTUnwrap(appliedID))
        controller.receiveProcessingLoad(DSPProcessingLoadUpdate(monitoringGeneration: generation, snapshot: snapshot), bindingID: binding)
        XCTAssertNotNil(controller.processingLoad.snapshot)
        controller.setProcessingLoadVisible(false, observerID: second)
        XCTAssertEqual(requests.map { $0.0 }, [false, true, false])
        XCTAssertEqual(controller.processingLoad.snapshot?.chain.averageRatio, 0.1)
        controller.setProcessingLoadVisible(true, observerID: first)
        controller.receiveProcessingLoad(DSPProcessingLoadUpdate(monitoringGeneration: generation, snapshot: snapshot), bindingID: binding)
        XCTAssertEqual(controller.processingLoad.snapshot?.chain.averageRatio, 0.1)
        controller.setProcessingLoadVisible(false, observerID: first)
        await controller.flushPendingPersistence()
    }

    func testLoadMeasurementsRejectOldConfigurationsAndRetiredPlaybackBindings() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        controller.updateConfiguration(commit: true) { $0.enabled = true }
        var generation = UUID()
        var appliedID: UUID?
        let observer = UUID()
        let oldBinding = controller.bindPlayback(monitorLoad: { _, value in generation = value }) { _, _, id in appliedID = id }
        controller.setProcessingLoadVisible(true, observerID: observer)
        let old = processingLoadSnapshot(controller: controller, requestID: try XCTUnwrap(appliedID))
        controller.receiveProcessingLoad(DSPProcessingLoadUpdate(monitoringGeneration: generation, snapshot: old), bindingID: oldBinding)
        XCTAssertNotNil(controller.processingLoad.snapshot)
        controller.updateConfiguration(commit: true) { $0.inputTrimDB = 1 }
        XCTAssertEqual(controller.processingLoad.snapshot?.chain.averageRatio, 0.1)
        controller.receiveProcessingLoad(DSPProcessingLoadUpdate(monitoringGeneration: generation, snapshot: old), bindingID: oldBinding)
        XCTAssertEqual(controller.processingLoad.snapshot?.chain.averageRatio, 0.1)
        let newBinding = controller.bindPlayback(monitorLoad: { _, value in generation = value }) { _, _, id in appliedID = id }
        let current = processingLoadSnapshot(controller: controller, requestID: try XCTUnwrap(appliedID))
        let update = DSPProcessingLoadUpdate(monitoringGeneration: generation, snapshot: current)
        controller.receiveProcessingLoad(update, bindingID: oldBinding)
        XCTAssertNil(controller.processingLoad.snapshot)
        controller.receiveProcessingLoad(update, bindingID: newBinding)
        XCTAssertNotNil(controller.processingLoad.snapshot)
        controller.setSourceIsLocal(false)
        XCTAssertNil(controller.processingLoad.snapshot)
        controller.receiveProcessingLoad(update, bindingID: newBinding)
        XCTAssertNil(controller.processingLoad.snapshot)
        controller.detachPlayback()
        controller.setProcessingLoadVisible(false, observerID: observer)
        await controller.flushPendingPersistence()
    }

    func testLoadPresentationRetainsLastResultUntilReplacedOrExplicitlyCleared() {
        let presentation = DSPProcessingLoadPresentation()
        presentation.update(DSPProcessingLoadSnapshot(requestID: nil, revision: "test",
            format: DSPAudioFormat(sampleRate: 48_000, channelCount: 2,
                rawLayoutData: nil, channelLabels: nil, layoutIsKnown: false),
            nodes: [:], chain: DSPProcessingLoad(averageRatio: 0.1, sampledPeakRatio: 0.2), sampleCount: 4))
        XCTAssertNotNil(presentation.snapshot)
        presentation.update(nil)
        XCTAssertEqual(presentation.snapshot?.chain.averageRatio, 0.1)
        presentation.update(DSPProcessingLoadSnapshot(requestID: nil, revision: "fresh",
            format: DSPAudioFormat(sampleRate: 48_000, channelCount: 2,
                rawLayoutData: nil, channelLabels: nil, layoutIsKnown: false),
            nodes: [:], chain: DSPProcessingLoad(averageRatio: 0.3, sampledPeakRatio: 0.4), sampleCount: 4))
        XCTAssertEqual(presentation.snapshot?.chain.averageRatio, 0.3)
        presentation.clear()
        XCTAssertNil(presentation.snapshot)
    }

    func testLoadPresentationKeepsTemporarilyInactiveNodesAndDropsRemovedNodes() {
        let presentation = DSPProcessingLoadPresentation()
        let active = UUID(), inactive = UUID(), removed = UUID()
        let format = DSPAudioFormat(sampleRate: 48_000, channelCount: 2,
            rawLayoutData: nil, channelLabels: nil, layoutIsKnown: false)
        let initial = DSPProcessingLoad(averageRatio: 0.1, sampledPeakRatio: 0.2)
        presentation.update(DSPProcessingLoadSnapshot(requestID: nil, revision: "old", format: format,
            nodes: [active: initial, inactive: initial, removed: initial], chain: initial, sampleCount: 2))
        let fresh = DSPProcessingLoad(averageRatio: 0.3, sampledPeakRatio: 0.4)
        presentation.update(DSPProcessingLoadSnapshot(requestID: nil, revision: "new", format: format,
            nodes: [active: fresh], chain: fresh, sampleCount: 2), retainingNodeIDs: [active, inactive])
        XCTAssertEqual(presentation.snapshot?.nodes[active], fresh)
        XCTAssertEqual(presentation.snapshot?.nodes[inactive], initial)
        XCTAssertNil(presentation.snapshot?.nodes[removed])
        XCTAssertEqual(presentation.snapshot?.chain, fresh)
    }

    private func processingLoadSnapshot(controller: AudioDSPController, requestID: UUID) -> DSPProcessingLoadSnapshot {
        DSPProcessingLoadSnapshot(requestID: requestID, revision: controller.revisionString,
            format: DSPAudioFormat(sampleRate: 48_000, channelCount: 2,
                rawLayoutData: nil, channelLabels: nil, layoutIsKnown: false),
            nodes: [:], chain: DSPProcessingLoad(averageRatio: 0.1, sampledPeakRatio: 0.2), sampleCount: 4)
    }

    func testRepeatedUnchangedUIEditsKeepRevisionAndCommitPendingValue() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        var appliedValues: [Double] = []
        controller.bindPlayback { configuration, _, _ in
            appliedValues.append(configuration.inputTrimDB)
        }
        controller.commitPendingApply()
        appliedValues.removeAll()

        controller.updateConfiguration { $0.inputTrimDB = -3 }
        let revision = controller.revisionString
        for _ in 0..<50 {
            controller.updateConfiguration { $0.inputTrimDB = -3 }
        }
        XCTAssertEqual(controller.revisionString, revision)
        XCTAssertTrue(appliedValues.isEmpty)

        controller.updateConfiguration(commit: true) { $0.inputTrimDB = -3 }
        XCTAssertEqual(controller.revisionString, revision)
        XCTAssertEqual(appliedValues, [-3])
    }

    func testUndoAndRedoStepThroughSettingsEditsWithADragAsOneStep() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.attachUndoManager(undo)
        let original = controller.configuration.inputTrimDB

        undo.beginUndoGrouping()
        controller.updateConfiguration(commit: true) { $0.inputTrimDB = 1 }
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        for value in stride(from: 1.5, through: 4, by: 0.5) {
            controller.updateConfiguration { $0.inputTrimDB = value }
        }
        controller.commitPendingApply()
        undo.endUndoGrouping()
        let editedPresetID = controller.selectedPresetID

        undo.undo()
        XCTAssertEqual(controller.configuration.inputTrimDB, 1)
        undo.undo()
        XCTAssertEqual(controller.configuration.inputTrimDB, original)
        XCTAssertFalse(undo.canUndo)
        // Undoing into Flat's values keeps editing the copy the first edit made.
        XCTAssertEqual(controller.selectedPresetID, editedPresetID)

        undo.redo()
        XCTAssertEqual(controller.configuration.inputTrimDB, 1)
        undo.redo()
        XCTAssertEqual(controller.configuration.inputTrimDB, 4)
        XCTAssertFalse(undo.canRedo)
        await controller.flushPendingPersistence()
    }

    func testChangesOutsideTheHistoryAndLeavingThePageClearIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.attachUndoManager(undo)

        undo.beginUndoGrouping()
        controller.updateConfiguration(commit: true) { $0.inputTrimDB = 2 }
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        var external = controller.configuration
        external.outputTrimDB = -2
        _ = try controller.apply(external)
        XCTAssertFalse(undo.canUndo)

        undo.beginUndoGrouping()
        controller.updateConfiguration(commit: true) { $0.inputTrimDB = 3 }
        undo.endUndoGrouping()
        _ = try controller.selectPreset(id: DSPPresetDocument.flatPresetID)
        XCTAssertFalse(undo.canUndo)

        undo.beginUndoGrouping()
        controller.updateConfiguration(commit: true) { $0.inputTrimDB = 5 }
        undo.endUndoGrouping()
        controller.detachUndoManager(undo)
        XCTAssertFalse(undo.canUndo)
        await controller.flushPendingPersistence()
    }

    func testRecursiveUnknownParametersSurvivePresetRoundTrip() async throws {
        let unknownParameters: [String: DSPJSONValue] = [
            "future": .object([
                "mode": .string("wide"),
                "values": .array([.integer(3), .bool(false), .null, .number(120.0)]),
                "largeInteger": .integer(9_007_199_254_740_993),
            ]),
        ]
        var configuration = AudioDSPConfiguration.defaultFlat
        configuration.nodes.append(DSPNodeConfiguration(
            typeID: "future.effect",
            enabled: false,
            parameters: unknownParameters
        ))
        let document = DSPPresetDocument(name: "Future", configuration: configuration)
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(DSPPresetDocument.self, from: encoded)

        XCTAssertEqual(decoded, document)
    }

    func testFlatWorkingDraftReloadDoesNotAppearModified() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        try await store.saveWorkingDraft(DSPWorkingDraftDocument(
            revisionString: "flat-working-draft",
            selectedPresetID: DSPPresetDocument.flatPresetID,
            configuration: .defaultFlat
        ))

        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()

        XCTAssertEqual(controller.configuration, AudioDSPConfiguration.defaultFlat)
        XCTAssertFalse(controller.isModified)
    }

    func testPresetSaveReloadKeepsNumericJSONAndModifiedStateStable() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        var configuration = AudioDSPConfiguration.defaultFlat
        configuration.nodes.append(DSPNodeConfiguration(
            typeID: "future.metadata",
            enabled: false,
            quality: "future-quality",
            parameters: [
                "integralDouble": .number(120.0),
                "largeInteger": .integer(9_007_199_254_740_993),
                "largestUnsigned": .unsignedInteger(UInt64.max),
            ]
        ))
        let saved = try await store.save(DSPPresetDocument(name: "Numeric JSON", configuration: configuration))
        let loaded = try await store.preset(id: saved.presetID)

        XCTAssertEqual(loaded.configuration, configuration)
        XCTAssertNotEqual(
            DSPJSONValue.number(9_007_199_254_740_992),
            DSPJSONValue.integer(9_007_199_254_740_993)
        )

        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()
        _ = try controller.selectPreset(id: saved.presetID)
        XCTAssertFalse(controller.isModified)
        await controller.flushPendingPersistence()
        XCTAssertFalse(controller.isModified)
        let afterSelection = try await store.preset(id: saved.presetID)
        XCTAssertEqual(afterSelection, saved, "Selection must not rewrite the preset or its revision.")
        await controller.reloadPresets()
        XCTAssertFalse(controller.isModified)
    }

    func testEnabledUnknownNodeFailsValidationAndDisabledNodeIsPreserved() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()
        var configuration = AudioDSPConfiguration.defaultFlat
        let unknownNode = DSPNodeConfiguration(
            typeID: "future.effect",
            enabled: false,
            parameters: ["opaque": .object(["value": .number(1.25)])]
        )
        configuration.nodes.append(unknownNode)

        XCTAssertEqual(try controller.validate(configuration), configuration)

        configuration.nodes[1].enabled = true
        XCTAssertThrowsError(try controller.validate(configuration)) { error in
            let validationError = error as? DSPConfigurationValidationError
            XCTAssertEqual(validationError?.diagnostics.first?.code, "dsp.unsupportedNode")
            XCTAssertEqual(validationError?.diagnostics.first?.nodeID, unknownNode.nodeID)
        }
    }

    func testInvalidApplyDoesNotChangeConfigurationOrRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()
        let originalConfiguration = controller.configuration
        let originalRevision = controller.revisionString
        var invalid = originalConfiguration
        invalid.outputTrimDB = 25

        XCTAssertThrowsError(try controller.apply(invalid))
        XCTAssertEqual(controller.configuration, originalConfiguration)
        XCTAssertEqual(controller.revisionString, originalRevision)
    }

    func testReadyEventClearsAudibleRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()

        controller.bindPlayback { _, _, _ in }
        let requestID = try XCTUnwrap(controller.status.requestID)
        let revision = controller.revisionString
        controller.receive(DSPApplyEvent(
            requestID: requestID,
            revisionString: revision,
            state: .audible,
            format: nil,
            scheduledPTS: nil,
            audiblePTS: nil,
            headroomDB: nil,
            warnings: [],
            diagnostics: [],
            rebuffered: false
        ))
        XCTAssertEqual(controller.audibleRevision, revision)

        controller.receive(DSPApplyEvent(
            requestID: requestID,
            revisionString: revision,
            state: .ready,
            format: nil,
            scheduledPTS: nil,
            audiblePTS: nil,
            headroomDB: nil,
            warnings: [],
            diagnostics: [],
            rebuffered: false
        ))
        XCTAssertNil(controller.audibleRevision)
    }

    func testClearErrorsLeavesConfigurationAndRevisionUnchanged() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        controller.report(error: DSPPresetStoreError.invalidName)
        let originalConfiguration = controller.configuration
        let originalRevision = controller.revisionString

        controller.clearErrors()

        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.diagnostics.isEmpty)
        XCTAssertEqual(controller.configuration, originalConfiguration)
        XCTAssertEqual(controller.revisionString, originalRevision)
    }

    func testPresetRevisionConflictLeavesSavedDocumentUntouched() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        let original = try await store.save(DSPPresetDocument(
            name: "Night",
            configuration: .defaultFlat
        ))

        var replacement = original
        replacement.name = "Changed"
        do {
            _ = try await store.save(replacement, expectedRevision: "stale-revision")
            XCTFail("Expected a preset revision conflict.")
        } catch let error as DSPPresetStoreError {
            XCTAssertEqual(error, .revisionConflict)
        }

        let loaded = try await store.preset(id: original.presetID)
        XCTAssertEqual(loaded.name, "Night")
        XCTAssertEqual(loaded.revisionString, original.revisionString)
    }

    func testCompletePresetSelectionAndDeletionKeepWorkingSound() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        var savedConfiguration = controller.configuration
        savedConfiguration.enabled = true
        savedConfiguration.inputTrimDB = -4
        savedConfiguration.outputTrimDB = 2
        savedConfiguration.nodes.append(DSPNodeConfiguration(typeID: "future.code", enabled: false,
            quality: "future-quality", parameters: ["source": .string("gain = 0.5;")]))
        _ = try controller.apply(savedConfiguration)
        let saved = try await controller.savePreset(name: "Complete")
        var changed = savedConfiguration
        changed.nodes.reverse()
        changed.outputTrimDB = -3
        _ = try controller.apply(changed)
        XCTAssertTrue(controller.isModified)
        _ = try controller.selectPreset(id: saved.presetID, expectedPresetRevision: saved.revisionString)
        XCTAssertEqual(controller.configuration, changed)
        await controller.flushPendingPersistence()
        XCTAssertFalse(controller.isModified)
        let persisted = try XCTUnwrap(controller.presets.first(where: { $0.presetID == saved.presetID }))
        try await controller.deletePreset(id: saved.presetID, expectedPresetRevision: persisted.revisionString)
        XCTAssertEqual(controller.configuration, changed)
        XCTAssertNil(controller.selectedPresetID)
        XCTAssertTrue(controller.isModified)
    }

    func testFlatIdentityIsStableAndEmptyImportNameIsRejectedInPreview() async throws {
        XCTAssertEqual(AudioDSPConfiguration.defaultFlat, AudioDSPConfiguration.defaultFlat)
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        XCTAssertFalse(controller.isModified)
        let preview = try controller.importPreview(document: DSPPresetDocument(name: "  ", configuration: .defaultFlat))
        XCTAssertFalse(preview.isCompatible)
        XCTAssertEqual(preview.diagnostics.first?.fieldPath, "name")
    }

    func testEditingKnownBandRetainsUnknownBandParameters() throws {
        var node = DSPNodeConfiguration.parametricEQ()
        guard case .array(var values)? = node.parameters["bands"],
              case .object(var first) = values[0] else { return XCTFail("Missing bands") }
        first["futureParameter"] = .object(["source": .string("keep")])
        values[0] = .object(first)
        node.parameters["bands"] = .array(values)
        var bands = try XCTUnwrap(node.parametricEQBands)
        bands[1].frequencyHz = 150
        node.parametricEQBands = bands
        guard case .array(let result)? = node.parameters["bands"],
              case .object(let retained) = result[0] else { return XCTFail("Missing retained band") }
        XCTAssertEqual(retained["futureParameter"], first["futureParameter"])
    }

    func testIncompatiblePresetCanBePreservedAndCopiedWithoutApplying() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        let before = controller.configuration
        let beforeRevision = controller.revisionString
        let beforeSelection = controller.selectedPresetID
        var future = AudioDSPConfiguration.defaultFlat
        future.nodes.append(DSPNodeConfiguration(typeID: "future.script", enabled: true,
            quality: "future", parameters: ["source": .string("gain = 0.5;")]))
        let preview = try controller.importPreview(document: DSPPresetDocument(name: "Future", configuration: future))
        XCTAssertFalse(preview.isCompatible)
        XCTAssertTrue(preview.canImport)
        let saved = try await controller.importPreset(preview)
        XCTAssertEqual(saved.configuration, future)
        XCTAssertThrowsError(try controller.selectPreset(id: saved.presetID))
        let copy = try await controller.duplicatePreset(id: saved.presetID, name: "Copy",
            expectedPresetRevision: saved.revisionString)
        XCTAssertEqual(copy.configuration, future)
        XCTAssertNotEqual(copy.presetID, saved.presetID)
        XCTAssertEqual(controller.configuration, before)
        XCTAssertEqual(controller.revisionString, beforeRevision)
        XCTAssertEqual(controller.selectedPresetID, beforeSelection)
    }

    func testFutureEQVersionDoesNotUseCurrentBandDecoderDuringImport() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        let futureNode = DSPNodeConfiguration(typeID: "peq9", algorithmVersion: 2,
            parameters: ["futureBands": .string("opaque")])
        let preview = try controller.importPreview(document: DSPPresetDocument(name: "Future EQ",
            configuration: AudioDSPConfiguration(nodes: [futureNode])))
        XCTAssertTrue(preview.canImport)
        XCTAssertFalse(preview.isCompatible)
        var invalid = preview.document
        invalid.configuration.inputTrimDB = 100
        XCTAssertFalse(try controller.importPreview(document: invalid).canImport)
    }

    func testUnknownEnabledEQParametersArePreservedButCannotBeApplied() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        let originalConfiguration = controller.configuration
        let originalRevision = controller.revisionString
        let originalSelection = controller.selectedPresetID

        var node = DSPNodeConfiguration.parametricEQ()
        guard case .array(var bandValues)? = node.parameters["bands"],
              case .object(var activeBand) = bandValues[1] else {
            return XCTFail("Expected the nine-band EQ parameters.")
        }
        activeBand["enabled"] = .bool(true)
        activeBand["futureTilt"] = .object(["shape": .string("asymmetric")])
        bandValues[1] = .object(activeBand)
        node.parameters["bands"] = .array(bandValues)
        node.parameters["futureMode"] = .string("wide")
        var configuration = AudioDSPConfiguration.defaultFlat
        configuration.nodes = [node]

        let preview = try controller.importPreview(document: DSPPresetDocument(
            name: "Future parameters",
            configuration: configuration
        ))
        XCTAssertFalse(preview.isCompatible)
        XCTAssertTrue(preview.canImport)
        XCTAssertTrue(preview.diagnostics.contains { $0.code == "dsp.unsupportedParameter" })
        XCTAssertFalse(preview.diagnostics.contains { $0.code == "dsp.invalidParameter" })

        let saved = try await controller.importPreset(preview)
        XCTAssertEqual(saved.configuration, configuration)
        XCTAssertThrowsError(try controller.selectPreset(id: saved.presetID)) { error in
            let validation = error as? DSPConfigurationValidationError
            XCTAssertTrue(validation?.diagnostics.contains { $0.code == "dsp.unsupportedParameter" } == true)
        }
        XCTAssertEqual(controller.configuration, originalConfiguration)
        XCTAssertEqual(controller.revisionString, originalRevision)
        XCTAssertEqual(controller.selectedPresetID, originalSelection)
    }

    func testUnknownMetadataOnDisabledBandRemainsApplicable() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        var node = DSPNodeConfiguration.parametricEQ()
        guard case .array(var bandValues)? = node.parameters["bands"],
              case .object(var disabledBand) = bandValues[0] else {
            return XCTFail("Expected the nine-band EQ parameters.")
        }
        disabledBand["futureTilt"] = .number(0.8)
        bandValues[0] = .object(disabledBand)
        node.parameters["bands"] = .array(bandValues)
        var configuration = AudioDSPConfiguration.defaultFlat
        configuration.nodes = [node]

        let preview = try controller.importPreview(document: DSPPresetDocument(
            name: "Disabled band metadata",
            configuration: configuration
        ))
        XCTAssertTrue(preview.isCompatible)
        XCTAssertTrue(preview.canImport)
        XCTAssertEqual(try controller.validate(configuration), configuration)
        XCTAssertEqual(
            try XCTUnwrap(preview.document.configuration.nodes.first).parameters["bands"],
            DSPJSONValue.array(bandValues)
        )
    }

    func testRequestStatusHistoryDistinguishesUnknownSupersededAndAudibleRequests() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        controller.bindPlayback { _, _, _ in }
        let firstRequestID = try XCTUnwrap(controller.status.requestID)
        let firstRevision = controller.status.revisionString

        controller.bindPlayback { _, _, _ in }
        let secondRequestID = try XCTUnwrap(controller.status.requestID)
        XCTAssertNotEqual(firstRequestID, secondRequestID)
        XCTAssertEqual(controller.requestStatus(id: firstRequestID)?.state, .superseded)
        XCTAssertNil(controller.requestStatus(id: UUID()))

        let currentStatus = controller.status
        controller.receive(DSPApplyEvent(
            requestID: firstRequestID,
            revisionString: firstRevision,
            state: .audible,
            format: nil,
            scheduledPTS: nil,
            audiblePTS: nil,
            headroomDB: nil,
            warnings: [],
            diagnostics: [],
            rebuffered: false
        ))
        XCTAssertEqual(controller.requestStatus(id: firstRequestID)?.state, .audible)
        XCTAssertEqual(controller.status, currentStatus)

        controller.receive(DSPApplyEvent(
            requestID: firstRequestID,
            revisionString: firstRevision,
            state: .superseded,
            format: nil,
            scheduledPTS: nil,
            audiblePTS: nil,
            headroomDB: nil,
            warnings: [],
            diagnostics: [],
            rebuffered: false
        ))
        XCTAssertEqual(controller.requestStatus(id: firstRequestID)?.state, .audible)
    }

    func testContinuousEditsSaveBeforeTheDragEnds() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()
        let preset = try await controller.createPreset(name: "Live")
        var observedSavedEdit = false

        for index in 1...18 {
            controller.updateConfiguration { $0.inputTrimDB = -Double(index) / 2 }
            try await Task.sleep(for: .milliseconds(20))
            let saved = try await store.preset(id: preset.presetID)
            if index < 18, saved.configuration.inputTrimDB < 0 {
                observedSavedEdit = true
            }
        }

        XCTAssertTrue(observedSavedEdit, "Continuous input must not postpone every disk write until release.")
        controller.commitPendingApply()
        await controller.flushPendingPersistence()
        let saved = try await store.preset(id: preset.presetID)
        XCTAssertEqual(saved.configuration, controller.configuration)
        XCTAssertFalse(controller.isModified)
    }

    func testImmediatePresetSwitchRetainsEditsToThePreviousPreset() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()
        let first = try await controller.createPreset(name: "First")
        let second = try await controller.createPreset(name: "Second")

        _ = try controller.selectPreset(id: first.presetID)
        controller.updateConfiguration { $0.outputTrimDB = -6 }
        _ = try controller.selectPreset(id: second.presetID)
        await controller.flushPendingPersistence()

        let persistedFirst = try await store.preset(id: first.presetID)
        let persistedSecond = try await store.preset(id: second.presetID)
        XCTAssertEqual(persistedFirst.configuration.outputTrimDB, -6)
        XCTAssertEqual(persistedSecond.configuration.outputTrimDB, 0)
        _ = try controller.selectPreset(id: first.presetID)
        XCTAssertEqual(controller.configuration.outputTrimDB, -6)
        await controller.flushPendingPersistence()
    }

    func testCopyUsesCurrentEditsAndSubsequentChangesStayInTheCopy() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()
        let original = try await controller.createPreset(name: "Original")
        controller.updateConfiguration {
            $0.inputTrimDB = -4
            $0.nodes.append(DSPNodeConfiguration(typeID: "future.effect", enabled: false,
                parameters: ["opaque": .string("preserve me")]))
        }
        let snapshot = controller.configuration
        var applyCount = 0
        controller.bindPlayback { _, _, _ in applyCount += 1 }
        controller.commitPendingApply()
        applyCount = 0

        let copy = try await controller.copyCurrentPreset(name: "Copy")
        XCTAssertNotEqual(copy.presetID, original.presetID)
        XCTAssertEqual(copy.configuration, snapshot)
        XCTAssertEqual(controller.selectedPresetID, copy.presetID)
        XCTAssertEqual(applyCount, 0, "Copying identical parameters must not rebuild the audio chain.")
        controller.updateConfiguration { $0.inputTrimDB = -9 }
        await controller.flushPendingPersistence()

        let persistedOriginal = try await store.preset(id: original.presetID)
        let persistedCopy = try await store.preset(id: copy.presetID)
        XCTAssertEqual(persistedOriginal.configuration, snapshot)
        XCTAssertEqual(persistedCopy.configuration.inputTrimDB, -9)
    }

    func testFlatEditCreatesAnEditablePresetAndRestoresAfterReload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()
        _ = try controller.selectPreset(id: DSPPresetDocument.flatPresetID)
        controller.updateConfiguration { $0.inputTrimDB = -3 }
        let editedID = try XCTUnwrap(controller.selectedPresetID)
        XCTAssertNotEqual(editedID, DSPPresetDocument.flatPresetID)
        await controller.flushPendingPersistence()

        let flat = try await store.preset(id: DSPPresetDocument.flatPresetID)
        XCTAssertEqual(flat.configuration, .defaultFlat)
        let restored = AudioDSPController(store: store)
        await restored.ensureLoaded()
        XCTAssertEqual(restored.selectedPresetID, editedID)
        XCTAssertEqual(restored.configuration, controller.configuration)
        XCTAssertFalse(restored.isModified)
    }

    func testNewPresetStartsWithAnEmptyChainAndPreservesEnablement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        controller.updateConfiguration { $0.enabled = true; $0.inputTrimDB = -4 }
        let saved = try await controller.createPreset(name: "Empty")

        XCTAssertEqual(controller.selectedPresetID, saved.presetID)
        XCTAssertTrue(controller.configuration.enabled)
        XCTAssertTrue(controller.configuration.nodes.isEmpty)
        XCTAssertEqual(controller.configuration.inputTrimDB, 0)
        XCTAssertEqual(controller.configuration.outputTrimDB, 0)
        await controller.flushPendingPersistence()
    }

    func testAutosavePreservesRenamingAndDoesNotRecreateDeletedPreset() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DSPPresetStore(rootURL: root)
        let controller = AudioDSPController(store: store)
        await controller.ensureLoaded()
        let original = try await controller.createPreset(name: "Original")
        controller.updateConfiguration { $0.inputTrimDB = -3 }
        _ = try await controller.renamePreset(id: original.presetID, name: "Renamed",
            expectedPresetRevision: original.revisionString)
        controller.updateConfiguration { $0.outputTrimDB = -2 }
        await controller.flushPendingPersistence()
        let renamed = try await store.preset(id: original.presetID)
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(renamed.configuration.inputTrimDB, -3)
        XCTAssertEqual(renamed.configuration.outputTrimDB, -2)

        try await store.delete(id: renamed.presetID, expectedRevision: renamed.revisionString)
        let obsoleteEdit = try await store.saveEditedPreset(renamed)
        XCTAssertNil(obsoleteEdit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(renamed.presetID.uuidString).json").path))
    }

    func testDevicesCanShareFlatAndReturnIndependentlyToTheDefaultChain() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = deviceDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DSPPresetStore(rootURL: root)
        let dsp = AudioDSPController(store: store)
        let list = TestDeviceList([testDevice("first"), testDevice("second")])
        let devices = AudioDSPDeviceController(dsp: dsp, userDefaults: defaults, deviceProvider: list.provider)
        await devices.ensureLoaded()
        for uid in ["first", "second"] {
            devices.receiveOutputDeviceUID(uid)
            try await devices.selectPresetForCurrentDevice(DSPPresetDocument.flatPresetID)
            XCTAssertEqual(dsp.configuration, .defaultFlat)
        }
        XCTAssertEqual(devices.profiles["first"]?.presetID, DSPPresetDocument.flatPresetID)
        XCTAssertEqual(devices.profiles["second"]?.presetID, DSPPresetDocument.flatPresetID)
        XCTAssertNil(devices.presetOwner(DSPPresetDocument.flatPresetID, excluding: devices.currentDevice))
        devices.receiveOutputDeviceUID("first")
        try await devices.selectPresetForCurrentDevice(DSPPresetDocument.defaultPresetID)
        XCTAssertNil(devices.profiles["first"])
        XCTAssertEqual(devices.profiles["second"]?.presetID, DSPPresetDocument.flatPresetID)
        XCTAssertEqual(dsp.configuration, .defaultEffects)
        await dsp.flushPendingPersistence()

        let restoredDSP = AudioDSPController(store: store)
        let restoredDevices = AudioDSPDeviceController(dsp: restoredDSP, userDefaults: defaults, deviceProvider: list.provider)
        await restoredDevices.ensureLoaded()
        restoredDevices.receiveOutputDeviceUID("second")
        XCTAssertEqual(restoredDSP.configuration, .defaultFlat)
        restoredDevices.receiveOutputDeviceUID("first")
        XCTAssertEqual(restoredDSP.configuration, .defaultEffects)
        await restoredDSP.flushPendingPersistence()
    }

    func testEachDeviceRemembersItsOwnPresetAndOtherwiseUsesTheDefaultChain() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = deviceDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DSPPresetStore(rootURL: root)
        let dsp = AudioDSPController(store: store)
        await dsp.ensureLoaded()
        let headphonesSound = try await dsp.savePreset(name: "Headphones", configuration: AudioDSPConfiguration(enabled: true, inputTrimDB: -2))
        let speakerSound = try await dsp.savePreset(name: "Speakers", configuration: AudioDSPConfiguration(enabled: true, inputTrimDB: -8))
        let list = TestDeviceList([testDevice("headphones"), testDevice("speakers")])
        let devices = AudioDSPDeviceController(dsp: dsp, userDefaults: defaults, deviceProvider: list.provider)
        await devices.ensureLoaded()

        devices.receiveOutputDeviceUID("headphones")
        XCTAssertEqual(dsp.selectedPresetID, DSPPresetDocument.defaultPresetID)
        try await devices.selectPresetForCurrentDevice(headphonesSound.presetID)
        dsp.updateConfiguration(commit: true) { $0.inputTrimDB = -3 }
        devices.receiveOutputDeviceUID("headphones") // Repeated report / unchanged wake.
        XCTAssertEqual(dsp.selectedPresetID, headphonesSound.presetID)

        devices.receiveOutputDeviceUID("speakers")
        XCTAssertEqual(dsp.selectedPresetID, DSPPresetDocument.defaultPresetID)
        XCTAssertFalse(dsp.configuration.enabled)
        // A selection made by hand is remembered for the device.
        try await devices.selectPresetForCurrentDevice(speakerSound.presetID)

        devices.receiveOutputDeviceUID("headphones")
        XCTAssertEqual(dsp.selectedPresetID, headphonesSound.presetID)
        XCTAssertEqual(dsp.configuration.inputTrimDB, -3)
        devices.receiveOutputDeviceUID("speakers")
        XCTAssertEqual(dsp.selectedPresetID, speakerSound.presetID)
        XCTAssertEqual(devices.profiles["headphones"]?.presetID, headphonesSound.presetID)
        XCTAssertEqual(devices.profiles["speakers"]?.presetID, speakerSound.presetID)
        await dsp.flushPendingPersistence()
        let saved = try await store.preset(id: headphonesSound.presetID)
        XCTAssertEqual(saved.configuration.inputTrimDB, -3)
    }

    func testAnotherDevicesPresetIsCopiedNeverShared() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = deviceDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dsp = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await dsp.ensureLoaded()
        let calibration = EqualLoudnessCalibration(
            deviceKey: "first", deviceName: "first", axis: .decibels,
            points: [EqualLoudnessCalibrationPoint(coordinate: -20, bassDB: 0, trebleDB: 0)]
        )
        var configuration = AudioDSPConfiguration(enabled: true, inputTrimDB: -4)
        configuration.equalLoudness = DSPEqualLoudnessStage(enabled: true, calibration: calibration)
        let preset = try await dsp.savePreset(name: "Exclusive", configuration: configuration)
        let list = TestDeviceList([testDevice("first"), testDevice("second")])
        let devices = AudioDSPDeviceController(dsp: dsp, userDefaults: defaults, deviceProvider: list.provider)
        await devices.ensureLoaded()
        devices.receiveOutputDeviceUID("first")
        try await devices.selectPresetForCurrentDevice(preset.presetID)

        devices.receiveOutputDeviceUID("second")
        XCTAssertEqual(devices.presetOwner(preset.presetID, excluding: devices.currentDevice)?.deviceKey, "first")
        do {
            try await devices.selectPresetForCurrentDevice(preset.presetID)
            XCTFail("A preset cannot belong to two devices")
        } catch is DSPConfigurationValidationError { }
        XCTAssertEqual(dsp.selectedPresetID, DSPPresetDocument.defaultPresetID)

        try await devices.selectPresetForCurrentDevice(preset.presetID, copyIfOwned: true)
        let copyID = try XCTUnwrap(dsp.selectedPresetID)
        XCTAssertNotEqual(copyID, preset.presetID)
        XCTAssertEqual(devices.profiles["second"]?.presetID, copyID)
        XCTAssertEqual(devices.profiles["first"]?.presetID, preset.presetID)
        XCTAssertEqual(dsp.configuration.inputTrimDB, -4)
        XCTAssertTrue(dsp.configuration.equalLoudness.enabled)
        XCTAssertNil(dsp.configuration.equalLoudness.calibration)
        await dsp.flushPendingPersistence()
    }

    func testDeletingTheCurrentDevicesPresetReturnsItToTheDefaultChain() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = deviceDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dsp = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await dsp.ensureLoaded()
        let bound = try await dsp.savePreset(name: "Bound", configuration: AudioDSPConfiguration(enabled: true, inputTrimDB: -4))
        let list = TestDeviceList([testDevice("current")])
        let devices = AudioDSPDeviceController(dsp: dsp, userDefaults: defaults, deviceProvider: list.provider)
        await devices.ensureLoaded()
        devices.receiveOutputDeviceUID("current")
        try await devices.selectPresetForCurrentDevice(bound.presetID)
        XCTAssertEqual(dsp.configuration.inputTrimDB, -4)
        try await dsp.deletePreset(id: bound.presetID)
        XCTAssertNil(devices.profiles["current"])
        XCTAssertEqual(dsp.selectedPresetID, DSPPresetDocument.defaultPresetID)
        XCTAssertFalse(dsp.configuration.enabled)
        await dsp.flushPendingPersistence()
    }

    func testStartupReappliesTheRememberedPresetAndUnknownRouteKeepsTheSound() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = deviceDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DSPPresetStore(rootURL: root)
        let dsp = AudioDSPController(store: store)
        await dsp.ensureLoaded()
        let bound = try await dsp.savePreset(name: "Bound", configuration: AudioDSPConfiguration(enabled: true))
        let list = TestDeviceList([testDevice("airpods")])
        let devices = AudioDSPDeviceController(dsp: dsp, userDefaults: defaults, deviceProvider: list.provider)
        await devices.ensureLoaded()
        devices.receiveOutputDeviceUID("airpods")
        try await devices.selectPresetForCurrentDevice(bound.presetID)
        devices.receiveOutputDeviceUID(nil)
        XCTAssertNil(devices.currentDevice)
        XCTAssertEqual(dsp.selectedPresetID, bound.presetID)
        // Choosing flat by hand on an unknown route is not remembered anywhere.
        _ = try dsp.selectPreset(id: DSPPresetDocument.flatPresetID)
        XCTAssertEqual(devices.profiles["airpods"]?.presetID, bound.presetID)
        await dsp.flushPendingPersistence()

        let restoredDSP = AudioDSPController(store: store)
        await restoredDSP.ensureLoaded()
        XCTAssertEqual(restoredDSP.selectedPresetID, DSPPresetDocument.flatPresetID)
        let restoredDevices = AudioDSPDeviceController(dsp: restoredDSP, userDefaults: defaults, deviceProvider: list.provider)
        restoredDevices.receiveOutputDeviceUID("airpods")
        await restoredDevices.ensureLoaded()
        XCTAssertEqual(restoredDSP.selectedPresetID, bound.presetID)
        XCTAssertTrue(restoredDSP.configuration.enabled)
        await restoredDSP.flushPendingPersistence()
    }

    func testEditingFlatGivesTheDeviceItsOwnPreset() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = deviceDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dsp = AudioDSPController(store: DSPPresetStore(rootURL: root))
        let list = TestDeviceList([testDevice("headphones"), testDevice("speakers")])
        let devices = AudioDSPDeviceController(dsp: dsp, userDefaults: defaults, deviceProvider: list.provider)
        await devices.ensureLoaded()
        devices.receiveOutputDeviceUID("headphones")
        try await devices.selectPresetForCurrentDevice(DSPPresetDocument.flatPresetID)
        XCTAssertEqual(dsp.selectedPresetID, DSPPresetDocument.flatPresetID)
        dsp.updateConfiguration(commit: true) { $0.inputTrimDB = -5 }
        let ownID = try XCTUnwrap(devices.profiles["headphones"]?.presetID)
        XCTAssertNotEqual(ownID, DSPPresetDocument.flatPresetID)
        XCTAssertEqual(dsp.selectedPresetID, ownID)

        devices.receiveOutputDeviceUID("speakers")
        XCTAssertEqual(dsp.selectedPresetID, DSPPresetDocument.defaultPresetID)
        XCTAssertNil(devices.profiles["speakers"])
        devices.receiveOutputDeviceUID("headphones")
        XCTAssertEqual(dsp.selectedPresetID, ownID)
        XCTAssertEqual(dsp.configuration.inputTrimDB, -5)
        await dsp.flushPendingPersistence()
    }

    func testDataSourceSeparatesRoutesThatShareOneDevice() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = deviceDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dsp = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await dsp.ensureLoaded()
        let jackSound = try await dsp.savePreset(name: "Jack", configuration: AudioDSPConfiguration(enabled: true, inputTrimDB: -6))
        let speaker = testDevice("builtin", dataSource: 0x6973_706B) // 'ispk'
        let jack = testDevice("builtin", dataSource: 0x6864_706E) // 'hdpn'
        XCTAssertEqual(speaker.id, "builtin#ispk")
        XCTAssertEqual(jack.id, "builtin#hdpn")
        let list = TestDeviceList([jack])
        let devices = AudioDSPDeviceController(dsp: dsp, userDefaults: defaults, deviceProvider: list.provider)
        await devices.ensureLoaded()
        let renderer = NSObject()
        devices.attachOutputRoute(owner: renderer, refresh: {})
        devices.receiveOutputDeviceUID("builtin", ownerID: ObjectIdentifier(renderer))
        try await devices.selectPresetForCurrentDevice(jackSound.presetID)

        // Unplugging the headphones keeps the UID and changes the source.
        list.devices = [speaker]
        devices.refreshDevices()
        XCTAssertEqual(devices.currentDevice?.id, speaker.id)
        XCTAssertEqual(dsp.selectedPresetID, DSPPresetDocument.defaultPresetID)
        list.devices = [jack]
        devices.refreshDevices()
        XCTAssertEqual(dsp.selectedPresetID, jackSound.presetID)
        XCTAssertEqual(devices.profiles.keys.sorted(), [jack.id])
        await dsp.flushPendingPersistence()
    }

    private func deviceDefaults() -> (UserDefaults, String) {
        let suite = "AudioDSPDeviceTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testRetiredRouteOwnerCannotChangeDeviceOrDetachNewRenderer() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = deviceDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dsp = AudioDSPController(store: DSPPresetStore(rootURL: root))
        let list = TestDeviceList([testDevice("previous"), testDevice("current"), testDevice("next")])
        let devices = AudioDSPDeviceController(dsp: dsp, userDefaults: defaults, deviceProvider: list.provider)
        await devices.ensureLoaded()
        let previous = NSObject()
        let current = NSObject()
        devices.attachOutputRoute(owner: previous, refresh: {})
        devices.receiveOutputDeviceUID("previous", ownerID: ObjectIdentifier(previous))
        devices.attachOutputRoute(owner: current, refresh: {})
        devices.receiveOutputDeviceUID("current", ownerID: ObjectIdentifier(current))
        devices.detachOutputRoute(owner: previous)
        devices.receiveOutputDeviceUID("previous", ownerID: ObjectIdentifier(previous))
        XCTAssertEqual(devices.currentDevice?.uid, "current")
        devices.receiveOutputDeviceUID("next", ownerID: ObjectIdentifier(current))
        XCTAssertEqual(devices.currentDevice?.uid, "next")
        await dsp.flushPendingPersistence()
    }

    private func testDevice(_ uid: String, dataSource: UInt32? = nil) -> DSPOutputDevice {
        DSPOutputDevice(
            key: DSPOutputDeviceKey(uid: uid, dataSource: dataSource),
            deviceID: 0, name: uid, transportType: 0
        )
    }

    /// Stands in for Core Audio's device list.
    @MainActor
    private final class TestDeviceList {
        var devices: [DSPOutputDevice]
        init(_ devices: [DSPOutputDevice]) { self.devices = devices }
        var provider: () -> [DSPOutputDevice] { { [unowned self] in self.devices } }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDSPTests-\(UUID().uuidString)", isDirectory: true)
    }
}
