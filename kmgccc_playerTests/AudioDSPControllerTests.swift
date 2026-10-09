import Foundation
import XCTest
@testable import kmgccc_player

@MainActor
final class AudioDSPControllerTests: XCTestCase {
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
        try await Task.sleep(for: .milliseconds(300))
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
        XCTAssertEqual(controller.configuration, savedConfiguration)
        XCTAssertFalse(controller.isModified)
        try await controller.deletePreset(id: saved.presetID, expectedPresetRevision: saved.revisionString)
        XCTAssertEqual(controller.configuration, savedConfiguration)
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDSPTests-\(UUID().uuidString)", isDirectory: true)
    }
}
