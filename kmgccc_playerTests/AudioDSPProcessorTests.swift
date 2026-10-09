import AVFoundation
import XCTest
@testable import kmgccc_player

final class AudioDSPProcessorTests: XCTestCase {
    func testConsecutiveBlocksDoNotMutateEarlierOutput() {
        var bands = DSPParametricEQBand.defaultBands
        bands[4] = DSPParametricEQBand(enabled: true, type: .bell, frequencyHz: 1_000, gainDB: 6)
        let processor = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: [.parametricEQ(bands: bands)]
            ),
            format: DSPAudioFormat(
                sampleRate: 48_000,
                channelCount: 2,
                rawLayoutData: nil,
                channelLabels: [UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)],
                layoutIsKnown: true
            )
        )
        let firstInput = CanonicalPCM(frames: 256, channelCount: 2, sampleRate: 48_000,
                                      data: (0..<512).map { Float(sin(Double($0) * 0.03)) })
        let secondInput = CanonicalPCM(frames: 256, channelCount: 2, sampleRate: 48_000,
                                       data: (0..<512).map { Float(cos(Double($0) * 0.07)) })
        let firstOutput = processor.process(firstInput)
        let firstSnapshot = firstOutput.data
        _ = processor.process(secondInput)
        XCTAssertEqual(firstOutput.data, firstSnapshot)
    }

    func testAllSixRBJFilterKindsProduceStableDoubleCoefficients() throws {
        for type in DSPFilterType.allCases {
            let band = DSPParametricEQBand(
                enabled: true,
                type: type,
                frequencyHz: 1_000,
                gainDB: type.usesGain ? 6 : 0,
                q: type.usesSlope ? 0.71 : 0.71
            )
            let coefficients = try XCTUnwrap(
                DSPParametricEQMath.coefficients(for: band, sampleRate: 48_000)
            )
            XCTAssertTrue(coefficients.isStable, "\(type.rawValue) must remain stable")
            XCTAssertTrue(coefficients.b0.isFinite)
            XCTAssertTrue(coefficients.a2.isFinite)
        }
    }

    func testZeroGainBellAndShelvesAreExactIdentity() throws {
        for type in [DSPFilterType.bell, .lowShelf, .highShelf] {
            let coefficients = try XCTUnwrap(
                DSPParametricEQMath.coefficients(
                    for: DSPParametricEQBand(
                        enabled: true,
                        type: type,
                        frequencyHz: 1_000,
                        gainDB: 0
                    ),
                    sampleRate: 48_000
                )
            )
            XCTAssertEqual(coefficients, .identity)
        }
    }

    func testCurveResponseMatchesThePreparedBandCoefficients() throws {
        let band = DSPParametricEQBand(
            enabled: true,
            type: .bell,
            frequencyHz: 1_000,
            gainDB: 6,
            q: 1.2
        )
        let configuration = AudioDSPConfiguration(
            enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .off),
            nodes: [.parametricEQ(bands: [band] + Array(DSPParametricEQBand.defaultBands.dropFirst()))]
        )
        let coefficients = try XCTUnwrap(
            DSPParametricEQMath.coefficients(for: band, sampleRate: 48_000)
        )
        XCTAssertEqual(
            DSPParametricEQMath.responseDB(
                configuration: configuration,
                at: 1_000,
                sampleRate: 48_000
            ),
            coefficients.responseDB(at: 1_000, sampleRate: 48_000),
            accuracy: 1e-8
        )
    }

    func testIndependentChannelStateAndFullRangeLFEBypass() throws {
        var bands = DSPParametricEQBand.defaultBands
        bands[1] = DSPParametricEQBand(
            enabled: true,
            type: .bell,
            frequencyHz: 1_000,
            gainDB: 6
        )
        let configuration = AudioDSPConfiguration(
            enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .off),
            nodes: [.parametricEQ(bands: bands)]
        )
        let format = DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 4,
            rawLayoutData: nil,
            channelLabels: [
                UInt32(kAudioChannelLabel_Left),
                UInt32(kAudioChannelLabel_Right),
                UInt32(kAudioChannelLabel_Center),
                UInt32(kAudioChannelLabel_LFEScreen),
            ],
            layoutIsKnown: true
        )
        var samples = [Float](repeating: 0, count: 128 * 4)
        samples[0] = 1
        samples[3] = 0.375
        let input = CanonicalPCM(frames: 128, channelCount: 4, sampleRate: 48_000, data: samples)
        let output = AudioDSPProcessor(configuration: configuration, format: format).process(input)

        XCTAssertTrue(output.data.enumerated().allSatisfy { index, value in
            index % 4 != 1 || value == 0
        }, "an impulse in channel 0 must not seed channel 1 filter state")
        for frame in 0..<input.frames {
            XCTAssertEqual(output.data[frame * 4 + 3], input.data[frame * 4 + 3])
        }
        XCTAssertNotEqual(output.data[0], input.data[0])
    }

    func testUnknownFullRangeLayoutBypassesWithDiagnosticButAllChannelsIsExplicit() throws {
        var bands = DSPParametricEQBand.defaultBands
        bands[1] = DSPParametricEQBand(
            enabled: true,
            type: .bell,
            frequencyHz: 1_000,
            gainDB: 6
        )
        let unknownFormat = DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 6,
            rawLayoutData: nil,
            channelLabels: nil,
            layoutIsKnown: false
        )
        let input = CanonicalPCM(
            frames: 64,
            channelCount: 6,
            sampleRate: 48_000,
            data: (0..<384).map { $0.isMultiple(of: 6) ? 1 : 0 }
        )
        let fullRange = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: [.parametricEQ(bands: bands)]
            ),
            format: unknownFormat
        )
        XCTAssertTrue(fullRange.isBypassed)
        XCTAssertTrue(fullRange.diagnostics.contains { $0.code == "unknownChannelLayout" })
        XCTAssertEqual(fullRange.process(input).data, input.data)

        var allChannelsNode = DSPNodeConfiguration.parametricEQ(bands: bands)
        allChannelsNode.channelPolicy = "allChannels"
        let allChannels = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: [allChannelsNode]
            ),
            format: unknownFormat
        )
        XCTAssertFalse(allChannels.isBypassed)
        XCTAssertNotEqual(allChannels.process(input).data, input.data)
    }

    func testAutomaticHeadroomHonorsCombinedGainAbove120DB() {
        var bands = DSPParametricEQBand.defaultBands
        bands[4] = DSPParametricEQBand(
            enabled: true,
            type: .bell,
            frequencyHz: 1_000,
            gainDB: 18
        )
        let nodes = (0..<8).map { _ in DSPNodeConfiguration.parametricEQ(bands: bands) }
        let processor = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .automatic, marginDB: 2),
                nodes: nodes
            ),
            format: DSPAudioFormat(
                sampleRate: 48_000,
                channelCount: 1,
                rawLayoutData: nil,
                channelLabels: [UInt32(kAudioChannelLabel_Mono)],
                layoutIsKnown: true
            )
        )
        XCTAssertLessThan(processor.headroomDB, -120)

        let sampleRate = 48_000.0
        let frames = 9_600
        let tone = (0..<frames).map { frame in
            Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
        }
        let output = processor.process(CanonicalPCM(
            frames: frames,
            channelCount: 1,
            sampleRate: sampleRate,
            data: tone
        ))
        let tail = output.data.suffix(4_800)
        let rms = sqrt(tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(tail.count))
        XCTAssertLessThan(rms, 0.65)
        XCTAssertGreaterThan(rms, 0.45)
    }

    func testAutomaticHeadroomMeasuresShelfPlatformsAcrossTheSourceBand() {
        var lowShelfBands = DSPParametricEQBand.defaultBands
        lowShelfBands[0] = DSPParametricEQBand(
            enabled: true,
            type: .lowShelf,
            frequencyHz: 20,
            gainDB: 18,
            q: 0.71
        )
        let lowShelf = AudioDSPConfiguration(
            enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .automatic),
            nodes: [.parametricEQ(bands: lowShelfBands)]
        )

        var highShelfBands = DSPParametricEQBand.defaultBands
        highShelfBands[8] = DSPParametricEQBand(
            enabled: true,
            type: .highShelf,
            frequencyHz: 20_000,
            gainDB: 18,
            q: 0.71
        )
        let highShelf = AudioDSPConfiguration(
            enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .automatic),
            nodes: [.parametricEQ(bands: highShelfBands)]
        )

        XCTAssertGreaterThan(
            DSPParametricEQMath.estimatedPeakResponseDB(configuration: lowShelf, sampleRate: 48_000),
            17.9
        )
        XCTAssertGreaterThan(
            DSPParametricEQMath.estimatedPeakResponseDB(configuration: highShelf, sampleRate: 192_000),
            17.9
        )
    }

    func testAutomaticHeadroomUsesMaximumChannelPathForMixedPolicies() {
        var cutBands = DSPParametricEQBand.defaultBands
        cutBands[4] = DSPParametricEQBand(
            enabled: true,
            type: .bell,
            frequencyHz: 1_000,
            gainDB: -12
        )
        var boostBands = DSPParametricEQBand.defaultBands
        boostBands[4] = DSPParametricEQBand(
            enabled: true,
            type: .bell,
            frequencyHz: 1_000,
            gainDB: 12
        )
        var fullRangeNode = DSPNodeConfiguration.parametricEQ(bands: cutBands)
        fullRangeNode.channelPolicy = "fullRange"
        var allChannelsNode = DSPNodeConfiguration.parametricEQ(bands: boostBands)
        allChannelsNode.channelPolicy = "allChannels"

        let processor = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .automatic),
                nodes: [fullRangeNode, allChannelsNode]
            ),
            format: DSPAudioFormat(
                sampleRate: 48_000,
                channelCount: 3,
                rawLayoutData: nil,
                channelLabels: [
                    UInt32(kAudioChannelLabel_Left),
                    UInt32(kAudioChannelLabel_Right),
                    UInt32(kAudioChannelLabel_LFEScreen),
                ],
                layoutIsKnown: true
            )
        )

        XCTAssertLessThan(processor.headroomDB, -11.9)
    }

    func testZeroConfigurationBypassPreservesInputSamplesExactly() {
        let input = CanonicalPCM(
            frames: 4,
            channelCount: 2,
            sampleRate: 48_000,
            data: [0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 1, -1]
        )
        let processor = AudioDSPProcessor(
            configuration: .defaultFlat,
            format: DSPAudioFormat(
                sampleRate: 48_000,
                channelCount: 2,
                rawLayoutData: nil,
                channelLabels: nil,
                layoutIsKnown: false
            )
        )
        XCTAssertTrue(processor.isBypassed)
        XCTAssertEqual(processor.process(input).data, input.data)
    }

    func testEqualLoudnessIsFlatAtAndAboveReferenceAndBoundedBelowIt() {
        let node = DSPNodeConfiguration.equalLoudness()
        let reference = DSPEqualLoudnessContext(
            appGain: pow(10, -6 / 20),
            deviceUID: "test-output",
            referenceDB: -6
        )
        let atReference = DSPEqualLoudnessMath.gains(node: node, context: reference)
        XCTAssertEqual(atReference.bassDB, 0, accuracy: 1e-8)
        XCTAssertEqual(atReference.trebleDB, 0, accuracy: 1e-8)

        let aboveReference = DSPEqualLoudnessMath.gains(
            node: node,
            context: DSPEqualLoudnessContext(appGain: 1, deviceUID: "test-output", referenceDB: -6)
        )
        XCTAssertEqual(aboveReference, .zero)

        let quieter = DSPEqualLoudnessMath.gains(
            node: node,
            context: DSPEqualLoudnessContext(
                appGain: pow(10, -16 / 20),
                deviceUID: "test-output",
                referenceDB: -6
            )
        )
        XCTAssertEqual(quieter.bassDB, 3, accuracy: 1e-8)
        XCTAssertEqual(quieter.trebleDB, 1.5, accuracy: 1e-8)

        let muchQuieter = DSPEqualLoudnessMath.gains(
            node: node,
            context: DSPEqualLoudnessContext(
                appGain: pow(10, -40 / 20),
                deviceUID: "test-output",
                referenceDB: -6
            )
        )
        XCTAssertEqual(muchQuieter.bassDB, 6, accuracy: 1e-8)
        XCTAssertEqual(muchQuieter.trebleDB, 3, accuracy: 1e-8)
        XCTAssertGreaterThanOrEqual(muchQuieter.bassDB, quieter.bassDB)
        XCTAssertGreaterThanOrEqual(muchQuieter.trebleDB, quieter.trebleDB)

        let muted = DSPEqualLoudnessMath.gains(
            node: node,
            context: DSPEqualLoudnessContext(appGain: 0, deviceUID: "test-output", referenceDB: 0)
        )
        XCTAssertEqual(muted, .zero)

        let relativeDefault = DSPEqualLoudnessMath.gains(
            node: node,
            context: DSPEqualLoudnessContext(appGain: 0.1)
        )
        XCTAssertEqual(relativeDefault.bassDB, 6, accuracy: 1e-8)
        XCTAssertEqual(relativeDefault.trebleDB, 3, accuracy: 1e-8)
    }

    func testEqualLoudnessParameterEditPreservesUnknownJSONFields() throws {
        var node = DSPNodeConfiguration.equalLoudness()
        node.parameters["futureParameter"] = .object(["preserve": .bool(true)])
        var parameters = try XCTUnwrap(node.equalLoudnessParameters)
        parameters.maxBassGainDB = 8
        node.equalLoudnessParameters = parameters

        XCTAssertEqual(node.parameters["futureParameter"], .object(["preserve": .bool(true)]))
        XCTAssertEqual(node.equalLoudnessParameters?.maxBassGainDB, 8)
    }

    func testEqualLoudnessResponseAndAutomaticHeadroomUseTheActiveReference() throws {
        let node = DSPNodeConfiguration.equalLoudness()
        let context = DSPEqualLoudnessContext(appGain: 0.1, deviceUID: "test-output", referenceDB: 0)
        let configuration = AudioDSPConfiguration(
            enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .automatic, marginDB: 0),
            nodes: [node]
        )
        let lowFrequencyResponse = DSPEqualLoudnessMath.responseDB(
            node: node,
            context: context,
            at: 20,
            sampleRate: 48_000
        )
        XCTAssertGreaterThan(lowFrequencyResponse, 5.5)

        let processor = AudioDSPProcessor(
            configuration: configuration,
            format: DSPAudioFormat(
                sampleRate: 48_000,
                channelCount: 2,
                rawLayoutData: nil,
                channelLabels: [UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)],
                layoutIsKnown: true
            ),
            context: context
        )
        XCTAssertFalse(processor.isBypassed)
        XCTAssertLessThan(processor.headroomDB, -5.5)

        var parameters = try XCTUnwrap(node.equalLoudnessParameters)
        parameters.headroomMode = .off
        var excludedNode = node
        excludedNode.equalLoudnessParameters = parameters
        let noNodeHeadroom = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .automatic, marginDB: 0),
                nodes: [excludedNode]
            ),
            format: DSPAudioFormat(
                sampleRate: 48_000,
                channelCount: 2,
                rawLayoutData: nil,
                channelLabels: [UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)],
                layoutIsKnown: true
            ),
            context: context
        )
        XCTAssertEqual(noNodeHeadroom.headroomDB, 0, accuracy: 1e-8)
    }
}
