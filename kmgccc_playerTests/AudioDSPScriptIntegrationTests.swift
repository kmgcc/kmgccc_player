import AVFoundation
import Foundation
import PlayerAutomationProtocol
import XCTest
@testable import kmgccc_player

@MainActor
final class AudioDSPScriptIntegrationTests: XCTestCase {
    private let format = DSPAudioFormat(sampleRate: 48_000, channelCount: 2,
        rawLayoutData: nil, channelLabels: [UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)],
        layoutIsKnown: true)

    func testScriptCodeValuesAndUnknownDisabledDataRoundTrip() throws {
        var node = DSPNodeConfiguration.script(enabled: false)
        var parameters = try XCTUnwrap(node.scriptParameters)
        parameters.values["gainDB"] = -3
        node.parameters["future"] = .object(["nested": .array([.null, .string("preserve")])])
        node.scriptParameters = parameters
        let decoded = try JSONDecoder().decode(DSPNodeConfiguration.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(decoded, node)
        XCTAssertEqual(decoded.scriptParameters, parameters)
        XCTAssertEqual(DSPNodeConfiguration.supportedChannelPolicies(forTypeID: node.typeID), ["fullRange", "allChannels"])
    }

    func testDefaultScriptIsSampleIdenticalAndIndependentInstancesHaveIndependentState() {
        let input = pcm([0.25, -0.5, 0.125, 0.75])
        let flat = processor(nodes: [.script()])
        XCTAssertEqual(flat.processingLatencyFrames, 0)
        XCTAssertEqual(flat.process(input).data, input.data)

        let node = DSPNodeConfiguration.script(parameters: DSPScriptNodeParameters(source: """
        state level = 0;
        process { level = level + 0.1; output = input + level; }
        """))
        let first = processor(nodes: [node])
        let second = processor(nodes: [node])
        let silent = pcm([0, 0])
        XCTAssertEqual(first.process(silent).data[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(first.process(silent).data[0], 0.2, accuracy: 1e-6)
        XCTAssertEqual(second.process(silent).data[0], 0.1, accuracy: 1e-6)
    }

    func testDeclaredLatencyIsCompensatedButIntentionalDelayIsPreserved() {
        let input = pcm([1, 1] + Array(repeating: Float(0), count: 198))
        let declared = processor(nodes: [.script(parameters: DSPScriptNodeParameters(source:
            "latency 64; process { output = delay(input, 64); }"))])
        let intentional = processor(nodes: [.script(parameters: DSPScriptNodeParameters(source:
            "process { output = delay(input, 64); }"))])
        XCTAssertEqual(declared.processingLatencyFrames, 64)
        XCTAssertEqual(declared.process(input).data, input.data)
        XCTAssertEqual(intentional.processingLatencyFrames, 0)
        let delayed = intentional.process(input)
        XCTAssertEqual(delayed.frames, input.frames)
        XCTAssertEqual(delayed.data[0], 0)
        XCTAssertEqual(delayed.data[128], 1)
        XCTAssertGreaterThanOrEqual(RendererDSPLookahead.maximumFrames, 4 * 2048 + 32 * 64)
    }

    func testRuntimeFaultIsAttachedToNodeAndLaterEffectsContinue() {
        let script = DSPNodeConfiguration.script(parameters: DSPScriptNodeParameters(source:
            "process { output = sqrt(input); }"))
        let width = DSPNodeConfiguration.stereoWidth(parameters: DSPStereoWidthParameters(width: 0))
        let runtime = processor(nodes: [script, width])
        let input = pcm(Array(repeating: [Float(-0.5), Float(0.25)], count: 256).flatMap { $0 })
        let output = runtime.process(input)
        XCTAssertTrue(output.data.allSatisfy(\.isFinite))
        XCTAssertEqual(output.frames, input.frames)
        XCTAssertEqual(output.data[output.data.count - 1], -0.125, accuracy: 1e-6)
        XCTAssertEqual(output.data[output.data.count - 2], -0.125, accuracy: 1e-6)
        XCTAssertTrue(runtime.diagnostics.contains {
            $0.nodeID == script.nodeID && $0.fieldPath?.hasSuffix(".runtime") == true && $0.line != nil
        })
    }

    func testDownstreamTrimOverflowReturnsWholeSourceTimeBlockAndLatchesBypass() {
        let input = pcm([0.25, -0.5, 0.125, 0.75])
        let script = DSPNodeConfiguration.script(parameters: DSPScriptNodeParameters(source:
            "latency 2; process { output = delay(input * 1e38, 2); }"))
        let runtime = AudioDSPProcessor(configuration: AudioDSPConfiguration(enabled: true,
            outputTrimDB: 24, headroom: DSPHeadroomConfiguration(mode: .off), nodes: [script]), format: format)
        XCTAssertEqual(runtime.process(input).data, input.data)
        XCTAssertEqual(runtime.process(input).data, input.data)
        XCTAssertTrue(runtime.diagnostics.contains { $0.code == "dsp.nonFiniteChainOutput" })
        runtime.reset()
        XCTAssertFalse(runtime.diagnostics.contains { $0.code == "dsp.nonFiniteChainOutput" })
    }

    func testRendererBudgetIncludesCombinedLatencyPreview() {
        let assignments = (0..<100).map { "let value\($0) = input;" }.joined(separator: "\n")
        let source = "latency 2048; process { \(assignments) output = delay(input, 2048); }"
        let first = DSPNodeConfiguration.script(parameters: DSPScriptNodeParameters(source: source))
        let second = DSPNodeConfiguration.script(parameters: DSPScriptNodeParameters(source: source))
        let runtime = processor(nodes: [first, second])
        XCTAssertEqual(runtime.processingLatencyFrames, 2048)
        XCTAssertTrue(runtime.diagnostics.contains {
            $0.code == "dsp.scriptBudgetExceeded" && $0.nodeID == second.nodeID
        })
        XCTAssertEqual(DSPScriptCompiler.estimatedRendererOperationsPerSecond(
            baseOperationsPerSecond: 1_000_000, latencyFrames: 4096), 3_000_000)
    }

    func testJobRetryMetadataDoesNotStoreSourceAndDecodesLegacyRecords() throws {
        let id = UUID()
        let spec = LibraryOperationRetrySpec.dspScriptTest(nodeID: id, revision: "draft-1",
            sampleRate: 48_000, channelCount: 2, usesDraft: true)
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(LibraryOperationRetrySpec.self, from: data)
        XCTAssertEqual(decoded, spec)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(fields["source"])
        XCTAssertNil(fields["values"])
        let legacy = try JSONDecoder().decode(LibraryOperationRetrySpec.self,
            from: Data("{\"kind\":\"loudnessAnalyze\",\"trackIDs\":[]}".utf8))
        XCTAssertNil(legacy.scriptNodeID)
        XCTAssertNil(legacy.scriptRevision)
    }

    func testFixtureWireParametersAreBoundedAndPCMIsNotRetryable() throws {
        let tone: AutomationJSONValue = .array([.object(["kind": .string("sine"),
            "frequencyHz": .number(400), "durationSeconds": .number(0.1), "amplitude": .number(0.5)])])
        let synthetic = try AutomationDSPScriptFixtures.parse(tone, format: format)
        XCTAssertEqual(synthetic.fixtures.count, 1)
        XCTAssertEqual(synthetic.retryConfiguration, tone)
        let custom: AutomationJSONValue = .array([.object(["kind": .string("custom"),
            "samples": .array([.number(0.25), .number(-0.25)])])])
        let pcm = try AutomationDSPScriptFixtures.parse(custom, format: format)
        XCTAssertNil(pcm.retryConfiguration)
        XCTAssertThrowsError(try AutomationDSPScriptFixtures.parse(.array([]), format: format))
        XCTAssertThrowsError(try AutomationDSPScriptFixtures.parse(.array([.object([
            "kind": .string("sine"), "frequencyHz": .number(48_000)
        ])]), format: format))
        XCTAssertThrowsError(try AutomationDSPScriptFixtures.parse(.array([.object([
            "kind": .string("custom"), "samples": .array([.number(0)]), "filePath": .string("unused")
        ])]), format: format))
    }

    func testDiagnosticPositionsDecodeLegacyAndKeepSeparateLocations() throws {
        let legacy = try JSONDecoder().decode(DSPDiagnostic.self,
            from: Data("{\"code\":\"old\",\"message\":\"old\",\"retryable\":false}".utf8))
        XCTAssertNil(legacy.line)
        XCTAssertNil(legacy.column)
        let first = DSPDiagnostic(code: "syntax", message: "bad", line: 1, column: 2)
        let second = DSPDiagnostic(code: "syntax", message: "bad", line: 2, column: 2)
        XCTAssertNotEqual(first.id, second.id)
    }

    private func processor(nodes: [DSPNodeConfiguration]) -> AudioDSPProcessor {
        AudioDSPProcessor(configuration: AudioDSPConfiguration(enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .off), nodes: nodes), format: format)
    }
    private func pcm(_ samples: [Float]) -> CanonicalPCM {
        CanonicalPCM(frames: samples.count / 2, channelCount: 2, sampleRate: format.sampleRate, data: samples)
    }
}
