import Foundation
import PlayerAutomationProtocol
import XCTest
@testable import kmgccc_player

@MainActor
final class AudioDSPNativeEffectsConfigurationTests: XCTestCase {
    func testAutomationQualityAndRoutingEditsAreOrderedAndAtomic() throws {
        let node = DSPNodeConfiguration.virtualBass()
        var current = AudioDSPConfiguration.defaultFlat
        current.nodes.append(node)
        let handler = AutomationDSPHandler(appSession: nil)
        let operations: [AutomationJSONValue] = [
            .object(["op": .string("setQuality"), "nodeID": .string(node.nodeID.uuidString),
                     "value": .string("oversampling4x")]),
            .object(["op": .string("setChannelPolicy"), "nodeID": .string(node.nodeID.uuidString),
                     "value": .string("frontPair")]),
        ]
        let parameters = try AutomationParameters(AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array(operations)])))
        let candidate = try handler.candidateConfiguration(parameters, current: current)
        XCTAssertEqual(candidate.nodes.last?.quality, "oversampling4x")
        XCTAssertEqual(candidate.nodes.last?.channelPolicy, "frontPair")
        XCTAssertEqual(current.nodes.last, node)

        let invalid = operations + [.object([
            "op": .string("setQuality"), "nodeID": .string(UUID().uuidString),
            "value": .string("oversampling4x"),
        ])]
        let invalidParameters = try AutomationParameters(AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array(invalid)])))
        XCTAssertThrowsError(try handler.candidateConfiguration(invalidParameters, current: current))
        XCTAssertEqual(current.nodes.last, node)

        let malformedRequest = AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array([
                .object(["op": .string("setQuality"), "nodeID": .string(node.nodeID.uuidString),
                         "value": .number(4)]),
            ])]))
        let malformed = try AutomationParameters(malformedRequest)
        XCTAssertThrowsError(try handler.candidateConfiguration(malformed, current: current))
    }

    func testAutomationDefaultsMatchAppFactories() throws {
        let nodes: [DSPNodeConfiguration] = [.stereoWidth(), .virtualBass(), .tube()]
        for node in nodes {
            let schema = try XCTUnwrap(AutomationDSPToolCatalog.builtInNodeSchemas.first { raw in
                guard case .object(let fields) = raw else { return false }
                return fields["typeID"] == .string(node.typeID)
            })
            guard case .object(let fields) = schema else { return XCTFail("Missing node schema") }
            let defaults = try XCTUnwrap(fields["parameterDefaults"])
            let decoded = try JSONDecoder().decode([String: DSPJSONValue].self,
                from: AutomationWireCoding.encoder().encode(defaults))
            XCTAssertEqual(decoded, node.parameters)
            XCTAssertEqual(fields["defaultQuality"], .string(node.quality))
            XCTAssertEqual(fields["defaultChannelPolicy"], .string(node.channelPolicy))
        }
    }

    func testNativeFactoriesUseContractDefaults() {
        let width = DSPNodeConfiguration.stereoWidth()
        XCTAssertEqual(width.typeID, DSPNodeConfiguration.stereoWidthTypeID)
        XCTAssertEqual(width.algorithmVersion, 1)
        XCTAssertEqual(width.channelPolicy, "frontPair")
        XCTAssertEqual(width.quality, "standard")
        XCTAssertEqual(width.stereoWidthParameters, DSPStereoWidthParameters())

        let bass = DSPNodeConfiguration.virtualBass()
        XCTAssertEqual(bass.channelPolicy, "fullRange")
        XCTAssertEqual(bass.quality, "oversampling2x")
        XCTAssertEqual(bass.virtualBassParameters, DSPVirtualBassParameters())

        let tube = DSPNodeConfiguration.tube()
        XCTAssertEqual(tube.channelPolicy, "fullRange")
        XCTAssertEqual(tube.quality, "oversampling2x")
        XCTAssertEqual(tube.tubeParameters, DSPTubeParameters())
    }

    func testParameterSettersPreserveRecursiveUnknownJSON() throws {
        var node = DSPNodeConfiguration.virtualBass()
        let unknown = DSPJSONValue.object([
            "curve": .array([.integer(3), .bool(false), .number(120.0)]),
            "metadata": .object(["name": .string("future")]),
        ])
        node.parameters["futureParameter"] = unknown
        var parameters = try XCTUnwrap(node.virtualBassParameters)
        parameters.amount = 0.8
        node.virtualBassParameters = parameters

        XCTAssertEqual(node.parameters["futureParameter"], unknown)
        let decoded = try JSONDecoder().decode(DSPNodeConfiguration.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(decoded, node)
        XCTAssertEqual(decoded.virtualBassParameters?.amount, 0.8)
    }

    func testNativeDefaultsAndTypeSpecificPoliciesValidate() async throws {
        let (controller, root) = await makeController()
        defer { try? FileManager.default.removeItem(at: root) }

        var configuration = AudioDSPConfiguration.defaultFlat
        configuration.nodes.append(contentsOf: [
            .stereoWidth(),
            .virtualBass(),
            .tube(),
        ])
        XCTAssertEqual(try controller.validate(configuration), configuration)

        XCTAssertFalse(DSPNodeConfiguration.supportedChannelPolicies(forTypeID: DSPNodeConfiguration.parametricEQTypeID)
            .contains("frontPair"))
        XCTAssertTrue(DSPNodeConfiguration.supportedChannelPolicies(forTypeID: DSPNodeConfiguration.virtualBassTypeID)
            .contains("frontPair"))
    }

    func testEnabledNativeNodesRejectUnknownParametersAndDisabledNodesPreserveThem() async throws {
        let (controller, root) = await makeController()
        defer { try? FileManager.default.removeItem(at: root) }

        var configuration = AudioDSPConfiguration.defaultFlat
        var node = DSPNodeConfiguration.tube()
        node.parameters["futureParameter"] = .object(["raw": .number(4.25)])
        configuration.nodes.append(node)

        XCTAssertThrowsError(try controller.validate(configuration)) { error in
            let validation = error as? DSPConfigurationValidationError
            XCTAssertTrue(validation?.diagnostics.contains {
                $0.code == "dsp.unsupportedParameter" && $0.fieldPath?.hasSuffix("futureParameter") == true
            } == true)
        }

        configuration.nodes[1].enabled = false
        XCTAssertEqual(try controller.validate(configuration), configuration)
    }

    func testNativeParameterRangesAndVirtualBassFrequencyOrderAreValidated() async throws {
        let (controller, root) = await makeController()
        defer { try? FileManager.default.removeItem(at: root) }

        var width = AudioDSPConfiguration.defaultFlat
        var widthNode = DSPNodeConfiguration.stereoWidth()
        var widthParameters = try XCTUnwrap(widthNode.stereoWidthParameters)
        widthParameters.width = 2.01
        widthNode.stereoWidthParameters = widthParameters
        width.nodes.append(widthNode)
        assertInvalid(controller, width, pathSuffix: "parameters.width")

        var bass = AudioDSPConfiguration.defaultFlat
        var bassNode = DSPNodeConfiguration.virtualBass()
        var bassParameters = try XCTUnwrap(bassNode.virtualBassParameters)
        bassParameters.lowFrequencyHz = 100
        bassParameters.highFrequencyHz = 100
        bassNode.virtualBassParameters = bassParameters
        bass.nodes.append(bassNode)
        assertInvalid(controller, bass, pathSuffix: "parameters.highFrequencyHz")

        var tube = AudioDSPConfiguration.defaultFlat
        var tubeNode = DSPNodeConfiguration.tube()
        var tubeParameters = try XCTUnwrap(tubeNode.tubeParameters)
        tubeParameters.bias = 0.51
        tubeNode.tubeParameters = tubeParameters
        tube.nodes.append(tubeNode)
        assertInvalid(controller, tube, pathSuffix: "parameters.bias")
    }

    func testQualityAndChannelPoliciesAreValidatedPerNodeType() async throws {
        let (controller, root) = await makeController()
        defer { try? FileManager.default.removeItem(at: root) }

        var configuration = AudioDSPConfiguration.defaultFlat
        var equalizer = configuration.nodes[0]
        equalizer.channelPolicy = "frontPair"
        configuration.nodes[0] = equalizer
        assertInvalid(controller, configuration, pathSuffix: "channelPolicy")

        configuration = AudioDSPConfiguration.defaultFlat
        var bass = DSPNodeConfiguration.virtualBass()
        bass.quality = "standard"
        configuration.nodes.append(bass)
        assertInvalid(controller, configuration, pathSuffix: "quality")

        configuration = AudioDSPConfiguration.defaultFlat
        var stereoWidth = DSPNodeConfiguration.stereoWidth()
        stereoWidth.channelPolicy = "fullRange"
        configuration.nodes.append(stereoWidth)
        assertInvalid(controller, configuration, pathSuffix: "channelPolicy")
    }

    func testApplyEventCarriesNativeLatencyAndPeakFieldsAndLegacyPayloadsDecode() throws {
        let event = DSPApplyEvent(
            requestID: UUID(),
            revisionString: "revision",
            state: .audible,
            processingLatencyFrames: 192,
            mediaMappingLatencyFrames: 0,
            peakGuarantee: "unavailable"
        )
        let status = event.status
        XCTAssertEqual(status.processingLatencyFrames, 192)
        XCTAssertEqual(status.mediaMappingLatencyFrames, 0)
        XCTAssertEqual(status.peakGuarantee, "unavailable")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var legacyStatusObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(status)) as? [String: Any]
        )
        legacyStatusObject.removeValue(forKey: "processingLatencyFrames")
        legacyStatusObject.removeValue(forKey: "mediaMappingLatencyFrames")
        legacyStatusObject.removeValue(forKey: "peakGuarantee")
        let legacyStatusData = try JSONSerialization.data(withJSONObject: legacyStatusObject)
        let legacyStatus = try decoder.decode(DSPApplyStatus.self, from: legacyStatusData)
        XCTAssertNil(legacyStatus.processingLatencyFrames)
        XCTAssertNil(legacyStatus.mediaMappingLatencyFrames)
        XCTAssertNil(legacyStatus.peakGuarantee)

        var legacyEventObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any]
        )
        legacyEventObject.removeValue(forKey: "processingLatencyFrames")
        legacyEventObject.removeValue(forKey: "mediaMappingLatencyFrames")
        legacyEventObject.removeValue(forKey: "peakGuarantee")
        let legacyEventData = try JSONSerialization.data(withJSONObject: legacyEventObject)
        let legacyEvent = try decoder.decode(DSPApplyEvent.self, from: legacyEventData)
        XCTAssertNil(legacyEvent.processingLatencyFrames)
        XCTAssertNil(legacyEvent.mediaMappingLatencyFrames)
        XCTAssertNil(legacyEvent.peakGuarantee)
    }

    func testClearErrorsPreservesAppliedLatencyAndPeakFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDSPStatus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        controller.bindPlayback { _, _, _ in }
        let requestID = try XCTUnwrap(controller.status.requestID)
        let revision = controller.revisionString

        controller.receive(DSPApplyEvent(
            requestID: requestID,
            revisionString: revision,
            state: .failed,
            processingLatencyFrames: 192,
            mediaMappingLatencyFrames: 0,
            peakGuarantee: "estimatedLinearResponse",
            diagnostics: [DSPDiagnostic(code: "dsp.testFailure", message: "Test failure.")]
        ))
        XCTAssertNotNil(controller.lastError)

        controller.clearErrors()

        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.status.diagnostics.isEmpty)
        XCTAssertEqual(controller.status.processingLatencyFrames, 192)
        XCTAssertEqual(controller.status.mediaMappingLatencyFrames, 0)
        XCTAssertEqual(controller.status.peakGuarantee, "estimatedLinearResponse")
    }

    private func assertInvalid(
        _ controller: AudioDSPController,
        _ configuration: AudioDSPConfiguration,
        pathSuffix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try controller.validate(configuration), file: file, line: line) { error in
            let validation = error as? DSPConfigurationValidationError
            XCTAssertTrue(validation?.diagnostics.contains {
                ($0.code == "dsp.invalidParameter" || $0.code == "dsp.unsupportedParameter")
                    && $0.fieldPath?.hasSuffix(pathSuffix) == true
            } == true, "Expected a diagnostic ending in \(pathSuffix).", file: file, line: line)
        }
    }

    private func makeController() async -> (AudioDSPController, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDSPNativeEffects-\(UUID().uuidString)", isDirectory: true)
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        return (controller, root)
    }
}
