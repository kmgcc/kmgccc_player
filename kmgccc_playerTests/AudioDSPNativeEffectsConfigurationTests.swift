import Foundation
import PlayerAutomationProtocol
import XCTest
@testable import kmgccc_player

@MainActor
final class AudioDSPNativeEffectsConfigurationTests: XCTestCase {
    func testAutomationQualityAndRoutingEditsAreOrderedAndAtomic() throws {
        let tube = DSPNodeConfiguration.tube()
        let bass = DSPNodeConfiguration.classicBass()
        var current = AudioDSPConfiguration.defaultFlat
        current.nodes.append(contentsOf: [tube, bass])
        let handler = AutomationDSPHandler(appSession: nil)
        let operations: [AutomationJSONValue] = [
            .object(["op": .string("setQuality"), "nodeID": .string(tube.nodeID.uuidString),
                     "value": .string("oversampling4x")]),
            .object(["op": .string("setChannelPolicy"), "nodeID": .string(bass.nodeID.uuidString),
                     "value": .string("frontPair")]),
        ]
        let parameters = try AutomationParameters(AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array(operations)])))
        let candidate = try handler.candidateConfiguration(parameters, current: current)
        XCTAssertEqual(candidate.nodes.first { $0.nodeID == tube.nodeID }?.quality, "oversampling4x")
        XCTAssertEqual(candidate.nodes.first { $0.nodeID == bass.nodeID }?.channelPolicy, "frontPair")
        XCTAssertEqual(Array(current.nodes.suffix(2)), [tube, bass])

        let invalid = operations + [.object([
            "op": .string("setQuality"), "nodeID": .string(UUID().uuidString),
            "value": .string("oversampling4x"),
        ])]
        let invalidParameters = try AutomationParameters(AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array(invalid)])))
        XCTAssertThrowsError(try handler.candidateConfiguration(invalidParameters, current: current))
        XCTAssertEqual(Array(current.nodes.suffix(2)), [tube, bass])

        let malformedRequest = AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array([
                .object(["op": .string("setQuality"), "nodeID": .string(tube.nodeID.uuidString),
                         "value": .number(4)]),
            ])]))
        let malformed = try AutomationParameters(malformedRequest)
        XCTAssertThrowsError(try handler.candidateConfiguration(malformed, current: current))
    }

    func testAutomationEditsTheFixedEqualLoudnessStage() throws {
        var current = AudioDSPConfiguration.defaultFlat
        current.equalLoudness.calibration = EqualLoudnessCalibration(
            deviceKey: "route", deviceName: "Route", axis: .decibels,
            points: [EqualLoudnessCalibrationPoint(coordinate: -20, bassDB: 0, trebleDB: 0)]
        )
        let handler = AutomationDSPHandler(appSession: nil)
        let parameters = try AutomationParameters(AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array([
                .object(["op": .string("setEqualLoudness"), "value": .object([
                    "enabled": .boolean(true),
                    "parameters": .object(["strength": .number(0.5)]),
                    "calibration": .null,
                ])]),
            ])])))
        let candidate = try handler.candidateConfiguration(parameters, current: current)
        XCTAssertTrue(candidate.equalLoudness.enabled)
        XCTAssertEqual(candidate.equalLoudness.parameters.strength, 0.5)
        XCTAssertEqual(candidate.equalLoudness.parameters.bassFrequencyHz, current.equalLoudness.parameters.bassFrequencyHz)
        XCTAssertNil(candidate.equalLoudness.calibration)
        XCTAssertEqual(candidate.nodes, current.nodes)

        let unknown = try AutomationParameters(AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array([
                .object(["op": .string("setEqualLoudness"), "value": .object([
                    "parameters": .object(["calibrations": .array([])]),
                ])]),
            ])])))
        XCTAssertThrowsError(try handler.candidateConfiguration(unknown, current: current))
    }

    func testAutomationSetsHeadroomCeilingAndLimiter() throws {
        let current = AudioDSPConfiguration.defaultFlat
        let handler = AutomationDSPHandler(appSession: nil)
        let parameters = try AutomationParameters(AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array([
                .object(["op": .string("setHeadroom"), "value": .object([
                    "mode": .string("automatic"), "maximumAttenuationDB": .number(3),
                ])]),
                .object(["op": .string("setLimiter"), "value": .object(["enabled": .boolean(false)])]),
                .object(["op": .string("setLimiter"), "value": .object(["releaseMilliseconds": .number(400)])]),
            ])])))
        let candidate = try handler.candidateConfiguration(parameters, current: current)
        XCTAssertEqual(candidate.headroom, DSPHeadroomConfiguration(mode: .automatic, maximumAttenuationDB: 3))
        XCTAssertEqual(candidate.limiter, DSPLimiterConfiguration(enabled: false, releaseMilliseconds: 400))
        XCTAssertTrue(current.limiter.enabled)

        let legacy = try AutomationParameters(AutomationRequest(method: AutomationMethod.dspPatch,
            params: .object(["operations": .array([
                .object(["op": .string("setHeadroom"), "value": .object([
                    "mode": .string("automatic"), "marginDB": .number(2),
                ])]),
            ])])))
        XCTAssertThrowsError(try handler.candidateConfiguration(legacy, current: current))
    }

    func testAutomationDefaultsMatchAppFactories() throws {
        for node in Self.allNativeNodes() {
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

        let bass = DSPNodeConfiguration.classicBass()
        XCTAssertEqual(bass.channelPolicy, "fullRange")
        XCTAssertEqual(bass.quality, "standard")
        XCTAssertEqual(bass.effectParameters(DSPClassicBassParameters.self), DSPClassicBassParameters())

        let tube = DSPNodeConfiguration.tube()
        XCTAssertEqual(tube.channelPolicy, "fullRange")
        XCTAssertEqual(tube.quality, "oversampling2x")
        XCTAssertEqual(tube.tubeParameters, DSPTubeParameters())

        // Every effect is audible as added: no strength or mix defaults to 0.
        XCTAssertGreaterThan(DSPClassicBassParameters().intensity, 0)
        XCTAssertGreaterThan(DSPHybridBassParameters().intensity, 0)
        XCTAssertNotEqual(DSPStereoWidthParameters().width, 1)
        XCTAssertGreaterThan(DSPTubeParameters().mix, 0)
        XCTAssertGreaterThan(DSPTubeParameters().hifiAmount, 0)
        XCTAssertGreaterThan(DSPReverbParameters().mix, 0)
        XCTAssertGreaterThan(DSPSpatialAudioParameters().mix, 0)
        XCTAssertEqual(DSPSpatialAudioParameters().room, .none)
        XCTAssertTrue(DSPCompressorParameters().bands.allSatisfy { $0.ratio > 1 })
    }

    func testSavedSpatialRoomChoiceSurvivesTheNewDefault() throws {
        var parameters = DSPSpatialAudioParameters()
        parameters.room = .studio
        parameters.distanceM = 3.5
        parameters.mix = 0.6
        let node = DSPNodeConfiguration.effect(parameters)
        let decoded = try JSONDecoder().decode(DSPNodeConfiguration.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(decoded.effectParameters(DSPSpatialAudioParameters.self), parameters)
    }

    func testSpatialAutomationDefaultsMatchTheNativeFactory() throws {
        let descriptor = try XCTUnwrap(AutomationDSPToolCatalog.builtInNodeSchemas.first { value in
            guard case .object(let fields) = value else { return false }
            return fields["typeID"] == .string("spatialAudio")
        })
        guard case .object(let fields) = descriptor, let defaults = fields["parameterDefaults"] else {
            XCTFail("Missing spatial audio defaults")
            return
        }
        let json = try JSONDecoder().decode([String: DSPJSONValue].self, from: JSONEncoder().encode(defaults))
        XCTAssertEqual(DSPSpatialAudioParameters(json: json), DSPSpatialAudioParameters())
        XCTAssertEqual(fields["declaredLatencyFramesWhenActive"], .null)
        XCTAssertEqual(fields["convolutionBlockLatencyFrames"], .number(256))
    }

    func testParameterSettersPreserveRecursiveUnknownJSON() throws {
        var node = DSPNodeConfiguration.classicBass()
        let unknown = DSPJSONValue.object([
            "curve": .array([.integer(3), .bool(false), .number(120.0)]),
            "metadata": .object(["name": .string("future")]),
        ])
        node.parameters["futureParameter"] = unknown
        var parameters = try XCTUnwrap(node.effectParameters(DSPClassicBassParameters.self))
        parameters.intensity = 0.8
        node.setEffectParameters(parameters)

        XCTAssertEqual(node.parameters["futureParameter"], unknown)
        let decoded = try JSONDecoder().decode(DSPNodeConfiguration.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(decoded, node)
        XCTAssertEqual(decoded.effectParameters(DSPClassicBassParameters.self)?.intensity, 0.8)
    }

    func testNativeDefaultsAndTypeSpecificPoliciesValidate() async throws {
        let (controller, root) = await makeController()
        defer { try? FileManager.default.removeItem(at: root) }

        var configuration = AudioDSPConfiguration.defaultFlat
        configuration.nodes.append(contentsOf: Self.allNativeNodes())
        XCTAssertEqual(try controller.validate(configuration), configuration)

        XCTAssertFalse(DSPNodeConfiguration.supportedChannelPolicies(forTypeID: DSPNodeConfiguration.parametricEQTypeID)
            .contains("frontPair"))
        XCTAssertTrue(DSPNodeConfiguration.supportedChannelPolicies(forTypeID: DSPNodeConfiguration.classicBassTypeID)
            .contains("frontPair"))
        XCTAssertEqual(DSPNodeConfiguration.supportedChannelPolicies(forTypeID: DSPNodeConfiguration.crossfeedTypeID),
                       ["frontPair"])
    }

    func testEveryNativeParameterSetRoundTripsThroughJSON() throws {
        func roundTrip<P: DSPEffectParameterSet>(_ value: P, file: StaticString = #filePath, line: UInt = #line) throws {
            var json: [String: DSPJSONValue] = [:]
            value.write(to: &json)
            XCTAssertEqual(Set(json.keys), P.supportedParameterKeys, file: file, line: line)
            XCTAssertEqual(P(json: json), value, file: file, line: line)
            XCTAssertTrue(value.validationIssues.isEmpty, "\(value.validationIssues)", file: file, line: line)
        }
        try roundTrip(DSPClassicBassParameters())
        try roundTrip(DSPHybridBassParameters())
        try roundTrip(DSPStereoWidthParameters())
        try roundTrip(DSPCrossfeedParameters())
        try roundTrip(DSPSpatialAudioParameters())
        try roundTrip(DSPReverbParameters())
        try roundTrip(DSPTubeParameters())
        try roundTrip(DSPCompressorParameters())
        try roundTrip(DSPCompressorParameters(style: .night))
        for space in DSPReverbSpace.allCases { try roundTrip(DSPReverbParameters(space: space)) }
        for strength in DSPCrossfeedStrength.allCases { try roundTrip(DSPCrossfeedParameters(strength: strength)) }
    }

    func testBassControlsSaveIndependentlyForEachTargetAndRoundTrip() throws {
        var classic = DSPClassicBassParameters()
        classic.bassGainDB = 9
        classic.intensity = 2
        classic.switchTarget(to: .speakers)
        XCTAssertEqual(classic.bassGainDB, 3)
        XCTAssertEqual(classic.intensity, 0.5)
        classic.bassGainDB = 0
        classic.intensity = 1.5
        classic.switchTarget(to: .automatic)
        XCTAssertEqual(classic.bassGainDB, 9)
        XCTAssertEqual(classic.intensity, 2)
        XCTAssertTrue(classic.validationIssues.isEmpty)

        var hybrid = DSPHybridBassParameters()
        hybrid.bassGainDB = 9
        hybrid.intensity = 2
        hybrid.switchTarget(to: .headphones)
        XCTAssertEqual(hybrid.bassGainDB, 3)
        XCTAssertEqual(hybrid.intensity, 0.5)
        hybrid.bassGainDB = 0
        hybrid.intensity = 1.5
        hybrid.switchTarget(to: .automatic)
        XCTAssertEqual(hybrid.bassGainDB, 9)
        XCTAssertEqual(hybrid.intensity, 2)
        XCTAssertTrue(hybrid.validationIssues.isEmpty)

        var classicJSON: [String: DSPJSONValue] = [:]
        classic.write(to: &classicJSON)
        XCTAssertEqual(DSPClassicBassParameters(json: classicJSON), classic)
        var hybridJSON: [String: DSPJSONValue] = [:]
        hybrid.write(to: &hybridJSON)
        XCTAssertEqual(DSPHybridBassParameters(json: hybridJSON), hybrid)
        let classicSaved = try XCTUnwrap(classic.targetSettings["speakers"])
        let hybridSaved = try XCTUnwrap(hybrid.targetSettings["headphones"])
        XCTAssertEqual(try JSONDecoder().decode(DSPClassicBassParameters.TargetSettings.self,
            from: JSONEncoder().encode(classicSaved)), classicSaved)
        XCTAssertEqual(try JSONDecoder().decode(DSPHybridBassParameters.TargetSettings.self,
            from: JSONEncoder().encode(hybridSaved)), hybridSaved)
    }

    func testBassGainIsRequiredAndExpandedRangesHaveExplicitLimits() {
        var classic = DSPClassicBassParameters()
        var hybrid = DSPHybridBassParameters()
        var classicJSON: [String: DSPJSONValue] = [:]
        classic.write(to: &classicJSON)
        classicJSON.removeValue(forKey: "bassGainDB")
        XCTAssertNil(DSPClassicBassParameters(json: classicJSON))
        var hybridJSON: [String: DSPJSONValue] = [:]
        hybrid.write(to: &hybridJSON)
        hybridJSON.removeValue(forKey: "bassGainDB")
        XCTAssertNil(DSPHybridBassParameters(json: hybridJSON))

        classic.bassGainDB = 9.1
        hybrid.bassGainDB = 9.1
        XCTAssertEqual(classic.validationIssues.map(\.key), ["bassGainDB"])
        XCTAssertEqual(hybrid.validationIssues.map(\.key), ["bassGainDB"])
        classic.bassGainDB = 9
        hybrid.bassGainDB = 9
        classic.intensity = 2.01
        hybrid.intensity = 2.01
        XCTAssertEqual(classic.validationIssues.map(\.key), ["intensity"])
        XCTAssertEqual(hybrid.validationIssues.map(\.key), ["intensity"])
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

    func testNativeParameterRangesAndFrequencyOrderAreValidated() async throws {
        let (controller, root) = await makeController()
        defer { try? FileManager.default.removeItem(at: root) }

        var width = AudioDSPConfiguration.defaultFlat
        var widthNode = DSPNodeConfiguration.stereoWidth()
        var widthParameters = try XCTUnwrap(widthNode.stereoWidthParameters)
        widthParameters.width = 3.01
        widthNode.stereoWidthParameters = widthParameters
        width.nodes.append(widthNode)
        assertInvalid(controller, width, pathSuffix: "parameters.width")

        var bass = AudioDSPConfiguration.defaultFlat
        var bassParameters = DSPClassicBassParameters()
        bassParameters.cutoffHz = 60
        bassParameters.floorHz = 50
        bass.nodes.append(.classicBass(parameters: bassParameters))
        assertInvalid(controller, bass, pathSuffix: "parameters.floorHz")

        var compressor = AudioDSPConfiguration.defaultFlat
        var compressorParameters = DSPCompressorParameters()
        compressorParameters.lowCrossoverHz = 900
        compressorParameters.highCrossoverHz = 1_500
        compressor.nodes.append(.effect(compressorParameters))
        assertInvalid(controller, compressor, pathSuffix: "parameters.highCrossoverHz")

        var spatial = AudioDSPConfiguration.defaultFlat
        var spatialParameters = DSPSpatialAudioParameters()
        spatialParameters.speakerAngleDeg = 60
        spatial.nodes.append(.effect(spatialParameters))
        assertInvalid(controller, spatial, pathSuffix: "parameters.speakerAngleDeg")

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
        var bass = DSPNodeConfiguration.classicBass()
        bass.quality = "oversampling2x"
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

    private static func allNativeNodes() -> [DSPNodeConfiguration] {
        [
            .classicBass(),
            .effect(DSPHybridBassParameters()),
            .stereoWidth(),
            .effect(DSPCrossfeedParameters()),
            .effect(DSPSpatialAudioParameters()),
            .effect(DSPReverbParameters()),
            .tube(),
            .effect(DSPCompressorParameters()),
        ]
    }

    private func makeController() async -> (AudioDSPController, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDSPNativeEffects-\(UUID().uuidString)", isDirectory: true)
        let controller = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await controller.ensureLoaded()
        return (controller, root)
    }
}
