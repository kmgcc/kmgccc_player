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

    func testChannelScopeWidensToEveryChannelWithoutAChannelMap() {
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
        var requestedFullRange = DSPNodeConfiguration.parametricEQ(bands: bands)
        requestedFullRange.channelPolicy = "fullRange"

        let processor = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: [requestedFullRange]
            ),
            format: unknownFormat
        )

        XCTAssertFalse(processor.isBypassed)
        XCTAssertFalse(processor.diagnostics.contains { $0.code == "unknownChannelLayout" })
        XCTAssertNotEqual(processor.process(input).data, input.data)
    }

    func testChannelScopeFollowsTheSourceInsteadOfAStoredChoice() {
        let stereo = DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            rawLayoutData: nil,
            channelLabels: [
                UInt32(kAudioChannelLabel_Left),
                UInt32(kAudioChannelLabel_Right),
            ],
            layoutIsKnown: true
        )
        let mono = DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 1,
            rawLayoutData: nil,
            channelLabels: [UInt32(kAudioChannelLabel_Mono)],
            layoutIsKnown: true
        )
        let surround = DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 6,
            rawLayoutData: nil,
            channelLabels: [
                UInt32(kAudioChannelLabel_Left),
                UInt32(kAudioChannelLabel_Right),
                UInt32(kAudioChannelLabel_Center),
                UInt32(kAudioChannelLabel_LFEScreen),
                UInt32(kAudioChannelLabel_LeftSurround),
                UInt32(kAudioChannelLabel_RightSurround),
            ],
            layoutIsKnown: true
        )
        let unidentified = DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 6,
            rawLayoutData: nil,
            channelLabels: nil,
            layoutIsKnown: false
        )
        func resolved(_ typeID: String, _ requested: String, _ format: DSPAudioFormat) -> String {
            DSPNodeConfiguration.effectiveChannelPolicy(
                forTypeID: typeID,
                requested: requested,
                format: format
            )
        }
        let equalizer = DSPNodeConfiguration.parametricEQTypeID

        XCTAssertEqual(resolved(equalizer, "fullRange", stereo), "fullRange")
        XCTAssertEqual(resolved(equalizer, "fullRange", surround), "fullRange")
        XCTAssertEqual(resolved(equalizer, "fullRange", unidentified), "allChannels")

        let virtualBass = DSPNodeConfiguration.virtualBassTypeID
        XCTAssertEqual(resolved(virtualBass, "fullRange", stereo), "fullRange")
        XCTAssertEqual(resolved(virtualBass, "fullRange", mono), "fullRange")
        XCTAssertEqual(resolved(virtualBass, "fullRange", surround), "frontPair")
        XCTAssertEqual(resolved(virtualBass, "frontPair", mono), "fullRange")

        XCTAssertEqual(
            resolved(DSPNodeConfiguration.stereoWidthTypeID, "allChannels", surround),
            "frontPair"
        )
    }

    func testAutomaticHeadroomIsBoundedInsteadOfCancellingExtremeGain() {
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
        // Eight stacked +18 dB stages exceed the compensation budget. The cut
        // stops at the bound and the residual peak is reported, instead of
        // attenuating the whole chain into silence.
        XCTAssertEqual(
            processor.headroomDB,
            -AudioDSPProcessor.maximumAutomaticHeadroomDB,
            accuracy: 1e-8
        )
        XCTAssertTrue(processor.diagnostics.contains { $0.code == "headroomLimited" })
        XCTAssertFalse(processor.isBypassed)

        // A chain inside the budget still receives its full compensation.
        var moderateBands = DSPParametricEQBand.defaultBands
        moderateBands[4] = DSPParametricEQBand(
            enabled: true,
            type: .bell,
            frequencyHz: 1_000,
            gainDB: 6
        )
        let moderate = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .automatic, marginDB: 0),
                nodes: [.parametricEQ(bands: moderateBands)]
            ),
            format: DSPAudioFormat(
                sampleRate: 48_000,
                channelCount: 1,
                rawLayoutData: nil,
                channelLabels: [UInt32(kAudioChannelLabel_Mono)],
                layoutIsKnown: true
            )
        )
        XCTAssertGreaterThan(moderate.headroomDB, -6.5)
        XCTAssertLessThan(moderate.headroomDB, -5.9)
        XCTAssertFalse(moderate.diagnostics.contains { $0.code == "headroomLimited" })
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
