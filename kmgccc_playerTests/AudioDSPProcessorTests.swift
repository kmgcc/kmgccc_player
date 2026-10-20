import AVFoundation
import XCTest
@testable import kmgccc_player

final class AudioDSPProcessorTests: XCTestCase {
    func testNativeDryEffectsHaveKnownZeroLoadAndWetEffectsRemainMeasurable() throws {
        var dryBass = DSPClassicBassParameters()
        dryBass.intensity = 0
        dryBass.retainsRealBass = true
        let bass = DSPNodeConfiguration.classicBass(parameters: dryBass)
        let tube = DSPNodeConfiguration.tube(parameters: DSPTubeParameters(mode: .classic, mix: 0))
        let format = DSPAudioFormat(sampleRate: 48_000, channelCount: 2, rawLayoutData: nil,
            channelLabels: [UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)], layoutIsKnown: true)
        var configuration = AudioDSPConfiguration(enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .off), nodes: [bass, tube])
        let dry = AudioDSPProcessor(configuration: configuration, format: format)
        XCTAssertTrue(dry.isBypassed)
        XCTAssertEqual(Set(dry.idleProcessingNodeIDs), [bass.nodeID, tube.nodeID])
        let accumulator = DSPProcessingLoadAccumulator(nodeIDs: dry.processingNodeIDs)
        for time in [UInt64(0), 500_000_000] {
            XCTAssertTrue(accumulator.beginBlock(frames: 6000, sampleRate: 48_000))
            accumulator.finishBlock(nanoseconds: 1000, at: time, succeeded: true)
        }
        let snapshot = try XCTUnwrap(accumulator.takeSnapshotIfDue(requestID: nil, revision: "dry", format: format,
            idleNodeIDs: dry.idleProcessingNodeIDs))
        XCTAssertEqual(snapshot.nodes[bass.nodeID]?.averageRatio, 0)
        XCTAssertEqual(snapshot.nodes[tube.nodeID]?.averageRatio, 0)
        configuration.nodes[0].setEffectParameters(DSPClassicBassParameters())
        configuration.nodes[1].tubeParameters = DSPTubeParameters(mode: .classic, mix: 0.6)
        let wet = AudioDSPProcessor(configuration: configuration, format: format)
        XCTAssertFalse(wet.isBypassed)
        XCTAssertTrue(wet.processingNodeIDs.contains(bass.nodeID))
        XCTAssertTrue(wet.processingNodeIDs.contains(tube.nodeID))
        XCTAssertTrue(wet.idleProcessingNodeIDs.isEmpty)
        var unknownLayout = format
        unknownLayout.channelLabels = nil
        unknownLayout.layoutIsKnown = false
        let unsupported = AudioDSPProcessor(configuration: AudioDSPConfiguration(enabled: true, nodes: [bass]),
            format: unknownLayout)
        XCTAssertTrue(unsupported.idleProcessingNodeIDs.isEmpty)
        XCTAssertTrue(unsupported.diagnostics.contains { $0.code == "stereoLayoutUnsupported" })
    }

    func testLoadMeasurementPreservesPCMAndRecursiveLookaheadState() {
        let node = DSPNodeConfiguration.tube(parameters: DSPTubeParameters(mix: 0.7))
        let configuration = AudioDSPConfiguration(enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .off), nodes: [node])
        let format = DSPAudioFormat(sampleRate: 48_000, channelCount: 2,
            rawLayoutData: nil, channelLabels: nil, layoutIsKnown: false)
        let measured = AudioDSPProcessor(configuration: configuration, format: format)
        let reference = AudioDSPProcessor(configuration: configuration, format: format)
        let measurement = DSPProcessingLoadAccumulator(nodeIDs: measured.processingNodeIDs)
        XCTAssertGreaterThan(measured.processingLatencyFrames, 0)
        for block in 0..<12 {
            let input = CanonicalPCM(frames: 2048, channelCount: 2, sampleRate: 48_000,
                data: (0..<4096).map { Float(sin(Double($0 + block * 4096) * 0.03) * 0.2) })
            let future = CanonicalPCM(frames: measured.processingLatencyFrames, channelCount: 2, sampleRate: 48_000,
                data: Array(repeating: 0.1, count: measured.processingLatencyFrames * 2))
            XCTAssertEqual(measured.process(input, lookahead: future, loadMeasurement: measurement).data,
                reference.process(input, lookahead: future).data)
        }
    }

    func testBypassedProcessorNeverProducesLoadSamples() {
        let format = DSPAudioFormat(sampleRate: 48_000, channelCount: 2,
            rawLayoutData: nil, channelLabels: nil, layoutIsKnown: false)
        let processor = AudioDSPProcessor(configuration: .defaultFlat, format: format)
        let measurement = DSPProcessingLoadAccumulator(nodeIDs: processor.processingNodeIDs)
        let input = CanonicalPCM(frames: 2048, channelCount: 2, sampleRate: 48_000,
            data: Array(repeating: 0.2, count: 4096))
        XCTAssertTrue(processor.isBypassed)
        for _ in 0..<32 { XCTAssertEqual(processor.process(input, loadMeasurement: measurement).data, input.data) }
        XCTAssertNil(measurement.takeSnapshotIfDue(requestID: nil, revision: "bypass", format: format))
    }

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
        // The channel-linked limiter would scale the LFE with the impulse.
        let configuration = AudioDSPConfiguration(
            enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .off),
            nodes: [.parametricEQ(bands: bands)],
            limiter: DSPLimiterConfiguration(enabled: false)
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

        for bass in [DSPNodeConfiguration.classicBassTypeID, DSPNodeConfiguration.hybridBassTypeID] {
            XCTAssertEqual(resolved(bass, "fullRange", stereo), "fullRange")
            XCTAssertEqual(resolved(bass, "fullRange", mono), "fullRange")
            XCTAssertEqual(resolved(bass, "fullRange", surround), "frontPair")
            XCTAssertEqual(resolved(bass, "frontPair", mono), "fullRange")
        }

        XCTAssertEqual(
            resolved(DSPNodeConfiguration.stereoWidthTypeID, "allChannels", surround),
            "frontPair"
        )
    }

    private let monoFormat = DSPAudioFormat(
        sampleRate: 48_000,
        channelCount: 1,
        rawLayoutData: nil,
        channelLabels: [UInt32(kAudioChannelLabel_Mono)],
        layoutIsKnown: true
    )

    private func bellBoost(_ gainDB: Double) -> DSPNodeConfiguration {
        var bands = DSPParametricEQBand.defaultBands
        bands[4] = DSPParametricEQBand(enabled: true, type: .bell, frequencyHz: 1_000, gainDB: gainDB)
        return .parametricEQ(bands: bands)
    }

    func testAutomaticHeadroomStopsAtTheMaximumAttenuation() {
        // Eight stacked +18 dB stages ask for far more than any cut allowed.
        let nodes = (0..<8).map { _ in bellBoost(18) }
        let defaultCap = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(enabled: true, nodes: nodes),
            format: monoFormat
        )
        XCTAssertEqual(defaultCap.headroomDB, -DSPHeadroomConfiguration.defaultMaximumAttenuationDB, accuracy: 1e-8)
        XCTAssertFalse(defaultCap.isBypassed)

        let widerCap = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .automatic, maximumAttenuationDB: 12),
                nodes: nodes
            ),
            format: monoFormat
        )
        XCTAssertEqual(widerCap.headroomDB, -12, accuracy: 1e-8)

        // A boost inside the cap receives its full compensation, no margin.
        let moderate = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .automatic, maximumAttenuationDB: 12),
                nodes: [bellBoost(6)]
            ),
            format: monoFormat
        )
        XCTAssertGreaterThan(moderate.headroomDB, -6.5)
        XCTAssertLessThan(moderate.headroomDB, -5.9)
    }

    func testAutomaticHeadroomLeavesTheListenersGainsAlone() {
        func headroom(inputTrimDB: Double = 0, outputTrimDB: Double = 0) -> Double {
            AudioDSPProcessor(
                configuration: AudioDSPConfiguration(
                    enabled: true,
                    inputTrimDB: inputTrimDB,
                    outputTrimDB: outputTrimDB,
                    headroom: DSPHeadroomConfiguration(mode: .automatic, maximumAttenuationDB: 12),
                    nodes: [bellBoost(6)]
                ),
                format: monoFormat
            ).headroomDB
        }
        let reference = headroom()
        // Raised gains are the chosen level and are never cancelled.
        XCTAssertEqual(headroom(outputTrimDB: 6), reference, accuracy: 1e-8)
        XCTAssertEqual(headroom(inputTrimDB: 6), reference, accuracy: 1e-8)
        // A lowered input already leaves room.
        XCTAssertEqual(headroom(inputTrimDB: -4), reference + 4, accuracy: 1e-8)
        // Gains alone never ask for a cut.
        let trimOnly = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(enabled: true, outputTrimDB: 6, nodes: []),
            format: monoFormat
        )
        XCTAssertEqual(trimOnly.headroomDB, 0, accuracy: 1e-8)
    }

    func testLimiterHoldsTheFinalOutputUnderTheCeiling() {
        let processor = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                outputTrimDB: 6,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: [bellBoost(12)]
            ),
            format: monoFormat
        )
        XCTAssertEqual(processor.processingLatencyFrames, DSPPeakLimiterKernel.lookaheadFrames(sampleRate: 48_000))
        XCTAssertEqual(processor.peakGuarantee, "samplePeakLimited")
        let ceiling = pow(10, DSPLimiterConfiguration.defaultCeilingDB / 20)
        var peak = 0.0
        for block in 0..<8 {
            let input = CanonicalPCM(frames: 2048, channelCount: 1, sampleRate: 48_000,
                data: (0..<2048).map { Float(0.9 * sin(2 * Double.pi * 1_000 * Double($0 + block * 2048) / 48_000)) })
            let output = processor.process(input)
            peak = max(peak, output.data.map { Double(abs($0)) }.max() ?? 0)
        }
        XCTAssertLessThanOrEqual(peak, ceiling + 1e-6)
        XCTAssertGreaterThan(peak, ceiling * 0.9)
    }

    func testLimiterLeavesSignalsUnderTheCeilingUntouched() {
        func processor(limiter: Bool) -> AudioDSPProcessor {
            AudioDSPProcessor(
                configuration: AudioDSPConfiguration(
                    enabled: true,
                    inputTrimDB: -3,
                    headroom: DSPHeadroomConfiguration(mode: .off),
                    nodes: [],
                    limiter: DSPLimiterConfiguration(enabled: limiter)
                ),
                format: monoFormat
            )
        }
        let limited = processor(limiter: true)
        let reference = processor(limiter: false)
        let latency = limited.processingLatencyFrames
        let source = (0..<4096).map { Float(0.5 * sin(Double($0) * 0.05)) }
        for block in 0..<2 {
            let input = CanonicalPCM(frames: 2048, channelCount: 1, sampleRate: 48_000,
                data: Array(source[(block * 2048)..<((block + 1) * 2048)]))
            let futureStart = (block + 1) * 2048
            let future = CanonicalPCM(frames: latency, channelCount: 1, sampleRate: 48_000,
                data: futureStart < source.count
                    ? Array(source[futureStart..<(futureStart + latency)])
                    : Array(repeating: 0, count: latency))
            let expected = reference.process(input).data
            let actual = limited.process(input, lookahead: future).data
            for index in expected.indices {
                XCTAssertEqual(actual[index], expected[index], accuracy: 1e-7)
            }
        }
    }

    func testLimiterHoldsSustainedBassInsteadOfTrackingEachCycle() {
        // A 50 Hz tone 6 dB over the ceiling: a gain that recovered between
        // waveform peaks would make each half-cycle peak differ.
        let processor = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                inputTrimDB: 6,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: []
            ),
            format: monoFormat
        )
        let frames = 48_000
        let source = (0..<frames).map { Float(0.9 * sin(2 * Double.pi * 50 * Double($0) / 48_000)) }
        let output = processor.process(CanonicalPCM(frames: frames, channelCount: 1, sampleRate: 48_000, data: source))
        let halfCycle = 480
        let settled = output.data[(frames / 2)..<(frames - processor.processingLatencyFrames)]
        var cyclePeaks: [Double] = []
        var start = settled.startIndex
        while start + halfCycle <= settled.endIndex {
            cyclePeaks.append(settled[start..<(start + halfCycle)].map { Double(abs($0)) }.max() ?? 0)
            start += halfCycle
        }
        let ceiling = pow(10, DSPLimiterConfiguration.defaultCeilingDB / 20)
        XCTAssertLessThanOrEqual(cyclePeaks.max() ?? 1, ceiling + 1e-6)
        XCTAssertGreaterThan(20 * log10((cyclePeaks.min() ?? 0) / ceiling), -0.1)
    }

    func testLimiterFollowsItsCeilingAndPersistsItsSettings() throws {
        let ceiling = -3.0
        let processor = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                inputTrimDB: 6,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: [],
                limiter: DSPLimiterConfiguration(ceilingDB: ceiling)
            ),
            format: monoFormat
        )
        let input = CanonicalPCM(frames: 4_800, channelCount: 1, sampleRate: 48_000,
            data: (0..<4_800).map { Float(0.9 * sin(Double($0) * 0.1)) })
        let peak = processor.process(input).data.map { Double(abs($0)) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, pow(10, ceiling / 20) + 1e-6)

        let limiter = DSPLimiterConfiguration(enabled: false, ceilingDB: -2.5)
        XCTAssertEqual(try JSONDecoder().decode(DSPLimiterConfiguration.self, from: JSONEncoder().encode(limiter)), limiter)
        let switchOnly = try JSONDecoder().decode(DSPLimiterConfiguration.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertEqual(switchOnly, DSPLimiterConfiguration())
    }

    func testPresetsWithoutLimiterOrMaximumAttenuationTakeTheDefaults() throws {
        var configuration = AudioDSPConfiguration(enabled: true)
        configuration.limiter.enabled = false
        configuration.headroom.maximumAttenuationDB = 9
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        )
        XCTAssertEqual(try JSONDecoder().decode(
            AudioDSPConfiguration.self, from: JSONSerialization.data(withJSONObject: object)
        ), configuration)

        object.removeValue(forKey: "limiter")
        object["headroom"] = ["mode": "automatic", "marginDB": 2] as [String: Any]
        let legacy = try JSONDecoder().decode(
            AudioDSPConfiguration.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(legacy.limiter.enabled)
        XCTAssertEqual(legacy.headroom.maximumAttenuationDB, DSPHeadroomConfiguration.defaultMaximumAttenuationDB)
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
                headroom: DSPHeadroomConfiguration(mode: .automatic, maximumAttenuationDB: 12),
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

    private func volumeContext(
        decibels: Double?,
        scalar: Double = 0.5
    ) -> DSPEqualLoudnessContext {
        DSPEqualLoudnessContext(
            volume: .available(OutputDeviceVolumeReading(
                deviceUID: "test-output", deviceName: "Test", scalar: scalar,
                decibelsBelowMaximum: decibels, isMuted: false, isWritable: true
            )),
            deviceKey: "test-output"
        )
    }

    private let enabledStage = DSPEqualLoudnessStage(enabled: true)

    private func calibratedStage(_ calibration: EqualLoudnessCalibration) -> DSPEqualLoudnessStage {
        DSPEqualLoudnessStage(enabled: true, calibration: calibration)
    }

    func testCalibrationAppliesOnlyOnTheRouteItWasRecordedOn() throws {
        let calibration = EqualLoudnessCalibration(
            deviceKey: "test-output", deviceName: "Test", axis: .decibels,
            points: [
                EqualLoudnessCalibrationPoint(coordinate: -20, bassDB: 0, trebleDB: 0),
                EqualLoudnessCalibrationPoint(coordinate: -30, bassDB: 8, trebleDB: 4),
            ]
        )
        let calibrated = calibratedStage(calibration)
        let context = volumeContext(decibels: -30)
        XCTAssertEqual(DSPEqualLoudnessMath.gains(stage: calibrated, context: context).bassDB, 8, accuracy: 1e-8)
        // An uncalibrated stage follows the default curve.
        XCTAssertNil(context.usableCalibration(in: enabledStage))
        XCTAssertEqual(DSPEqualLoudnessMath.gains(stage: enabledStage, context: context).bassDB, 6, accuracy: 1e-8)
        // The same device behind another data source is another route.
        var otherSource = context
        otherSource.deviceKey = "test-output#hdpn"
        XCTAssertNil(otherSource.usableCalibration(in: calibrated))
        XCTAssertEqual(DSPEqualLoudnessMath.gains(stage: calibrated, context: otherSource).bassDB, 6, accuracy: 1e-8)

        let roundTrip = try JSONDecoder().decode(DSPEqualLoudnessStage.self, from: JSONEncoder().encode(calibrated))
        XCTAssertEqual(roundTrip, calibrated)
    }

    func testEqualLoudnessIsAFixedStageAfterTheNodes() throws {
        var configuration = AudioDSPConfiguration(enabled: true, nodes: [.parametricEQ(), .tube()])
        configuration.equalLoudness.enabled = true
        XCTAssertEqual(configuration.processingNodes.map(\.typeID), [
            DSPNodeConfiguration.parametricEQTypeID, DSPNodeConfiguration.tubeTypeID,
            DSPNodeConfiguration.equalLoudnessTypeID,
        ])
        XCTAssertEqual(configuration.processingNodes.last?.nodeID, DSPEqualLoudnessStage.nodeID)
        // Switching the stage is a value change, not a new chain topology.
        var disabled = configuration
        disabled.equalLoudness.enabled = false
        XCTAssertTrue(configuration.hasSameStructure(as: disabled))

        let document = DSPPresetDocument(name: "Test", configuration: configuration)
        let decoded = try JSONDecoder().decode(DSPPresetDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    func testDefaultEqualLoudnessCurveFollowsSystemVolumeOnly() {
        let node = enabledStage
        let atReference = DSPEqualLoudnessMath.gains(stage: node, context: volumeContext(decibels: -10))
        XCTAssertEqual(atReference, .zero)
        XCTAssertEqual(DSPEqualLoudnessMath.gains(stage: node, context: volumeContext(decibels: 0)), .zero)

        let quieter = DSPEqualLoudnessMath.gains(stage: node, context: volumeContext(decibels: -20))
        XCTAssertEqual(quieter.bassDB, 3, accuracy: 1e-8)
        XCTAssertEqual(quieter.trebleDB, 1.5, accuracy: 1e-8)

        let muchQuieter = DSPEqualLoudnessMath.gains(stage: node, context: volumeContext(decibels: -40))
        XCTAssertEqual(muchQuieter.bassDB, 6, accuracy: 1e-8)
        XCTAssertEqual(muchQuieter.trebleDB, 3, accuracy: 1e-8)

        // A device without a readable volume never falls back to App volume.
        XCTAssertEqual(DSPEqualLoudnessMath.gains(stage: node, context: .inactive), .zero)

        // A percentage-only device uses the 40·log10 slider estimate.
        let percent = DSPEqualLoudnessMath.gains(stage: node, context: volumeContext(decibels: nil, scalar: 0.1))
        XCTAssertEqual(percent.bassDB, 6, accuracy: 1e-8)

        var preview = volumeContext(decibels: 0)
        preview.override = DSPEqualLoudnessGains(bassDB: 20, trebleDB: 2)
        XCTAssertEqual(DSPEqualLoudnessMath.gains(stage: node, context: preview),
                       DSPEqualLoudnessGains(bassDB: 12, trebleDB: 2))
    }

    func testCalibratedCurveIsMonotoneHeldAtEndsAndPassesThroughPoints() throws {
        let calibration = EqualLoudnessCalibration(
            deviceKey: "test-output", deviceName: "Test", axis: .decibels,
            points: [
                EqualLoudnessCalibrationPoint(coordinate: -6, bassDB: 0, trebleDB: 0),
                EqualLoudnessCalibrationPoint(coordinate: -14, bassDB: 4, trebleDB: 1),
                EqualLoudnessCalibrationPoint(coordinate: -22, bassDB: 7, trebleDB: 2),
                EqualLoudnessCalibrationPoint(coordinate: -34, bassDB: 9, trebleDB: 3),
            ]
        )
        let node = calibratedStage(calibration)
        func gains(_ db: Double) -> DSPEqualLoudnessGains {
            DSPEqualLoudnessMath.gains(stage: node, context: volumeContext(decibels: db))
        }
        XCTAssertEqual(gains(-14).bassDB, 4, accuracy: 1e-8)
        XCTAssertEqual(gains(-2).bassDB, 0, accuracy: 1e-8)
        XCTAssertEqual(gains(-50).bassDB, 9, accuracy: 1e-8)
        var previous = gains(0).bassDB
        for db in stride(from: -1.0, through: -40, by: -1) {
            let value = gains(db).bassDB
            XCTAssertGreaterThanOrEqual(value + 1e-9, previous)
            previous = value
        }

        // An inconsistent answer is pooled, not followed into a dip.
        XCTAssertEqual(EqualLoudnessCurve.nonIncreasing([3, 5, 2]), [4, 4, 2])
        let marks = EqualLoudnessCalibrationGuide.marks(recorded: [])
        let snapped = EqualLoudnessCalibrationGuide.snapped(0.32, marks: marks, heldMark: nil)
        XCTAssertEqual(try XCTUnwrap(snapped.mark), 5.0 / 16, accuracy: 1e-12)
        XCTAssertEqual(EqualLoudnessCalibrationGuide.snapped(0.34, marks: marks, heldMark: 5.0 / 16).value, 5.0 / 16)
        XCTAssertNil(EqualLoudnessCalibrationGuide.snapped(0.35, marks: marks, heldMark: 5.0 / 16).mark)
    }

    func testCalibrationGuideStartsAtReferenceThenQuieterThenLouder() {
        typealias Guide = EqualLoudnessCalibrationGuide
        XCTAssertEqual(Guide.suggestedScalar(step: 0, recorded: []), 5.0 / 16, accuracy: 1e-12)
        XCTAssertEqual(Guide.suggestedScalar(step: 1, recorded: [5.0 / 16]), 3.0 / 16, accuracy: 1e-12)
        XCTAssertEqual(Guide.suggestedScalar(step: 3, recorded: [5.0 / 16, 3.0 / 16, 2.0 / 16]), 8.0 / 16, accuracy: 1e-12)

        // A reference moved down pushes the quieter suggestions below it.
        XCTAssertEqual(Guide.suggestedScalar(step: 1, recorded: [4.0 / 16]), 2.0 / 16, accuracy: 1e-12)
        XCTAssertEqual(Guide.suggestedScalar(step: 2, recorded: [4.0 / 16, 2.0 / 16]), 1.0 / 16, accuracy: 1e-12)
        // A reference moved up pushes the louder suggestion above it.
        XCTAssertEqual(Guide.suggestedScalar(step: 3, recorded: [7.0 / 16, 5.0 / 16, 3.0 / 16]), 10.0 / 16, accuracy: 1e-12)

        func reading(_ db: Double) -> OutputDeviceVolumeReading {
            OutputDeviceVolumeReading(deviceUID: "d", deviceName: "D", scalar: 0.3,
                                      decibelsBelowMaximum: db, isMuted: false, isWritable: true)
        }
        XCTAssertNil(Guide.blocker(step: 0, reading: reading(-20), recordedCoordinates: []))
        XCTAssertNotNil(Guide.blocker(step: 1, reading: reading(-21), recordedCoordinates: [-20]))
        XCTAssertNil(Guide.blocker(step: 1, reading: reading(-24), recordedCoordinates: [-20]))
        XCTAssertNotNil(Guide.blocker(step: 3, reading: reading(-19), recordedCoordinates: [-20, -26, -32]))
        XCTAssertNil(Guide.blocker(step: 3, reading: reading(-12), recordedCoordinates: [-20, -26, -32]))
    }

    func testCalibrationVolumeRampIsGradualAndReachesTheTarget() {
        typealias Guide = EqualLoudnessCalibrationGuide
        let start = 2.0 / 16, target = 8.0 / 16
        let values = (0...80).map { Guide.rampScalar(from: start, to: target, progress: Double($0) / 80) }
        XCTAssertEqual(values.first, start)
        XCTAssertEqual(values.last, target)
        XCTAssertEqual(values[40], sqrt(start * target), accuracy: 1e-12)
        for index in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[index], values[index - 1])
            XCTAssertLessThan(values[index] - values[index - 1], 0.02)
        }
        XCTAssertEqual(Guide.rampScalar(from: 0, to: target, progress: 0), 0)
        XCTAssertTrue(Guide.rampScalar(from: 0, to: target, progress: 0.5).isFinite)
    }

    func testCalibrationAllowsCutsAboveTheReference() {
        let calibration = EqualLoudnessCalibration(
            deviceKey: "test-output", deviceName: "Test", axis: .decibels,
            points: [
                EqualLoudnessCalibrationPoint(coordinate: -20, bassDB: 0, trebleDB: 0),
                EqualLoudnessCalibrationPoint(coordinate: -28, bassDB: 4, trebleDB: 2),
                EqualLoudnessCalibrationPoint(coordinate: -34, bassDB: 7, trebleDB: 3),
                EqualLoudnessCalibrationPoint(coordinate: -10, bassDB: -2, trebleDB: -1),
            ]
        )
        let node = calibratedStage(calibration)
        let louder = DSPEqualLoudnessMath.gains(
            stage: node, context: volumeContext(decibels: -10)
        )
        XCTAssertEqual(louder.bassDB, -2, accuracy: 1e-8)
        let bands = DSPEqualLoudnessMath.bands(
            stage: node, context: volumeContext(decibels: -10)
        )
        XCTAssertEqual(bands?.first?.enabled, true)
        XCTAssertLessThan(
            DSPEqualLoudnessMath.responseDB(
                stage: node, context: volumeContext(decibels: -10),
                at: 20, sampleRate: 48_000
            ),
            -1.5
        )
    }

    func testEqualLoudnessResponseAndAutomaticHeadroomUseTheActiveReference() throws {
        let node = enabledStage
        let context = volumeContext(decibels: -40)
        let configuration = AudioDSPConfiguration(
            enabled: true,
            headroom: DSPHeadroomConfiguration(mode: .automatic),
            nodes: [],
            equalLoudness: node
        )
        let lowFrequencyResponse = DSPEqualLoudnessMath.responseDB(
            stage: node,
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

        let noNodeHeadroom = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: [],
                equalLoudness: node
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

final class DSPProcessingLoadAccumulatorTests: XCTestCase {
    private var format: DSPAudioFormat {
        DSPAudioFormat(sampleRate: 48_000, channelCount: 2,
            rawLayoutData: nil, channelLabels: nil, layoutIsKnown: false)
    }

    func testLookaheadCostUsesSourceDurationOnceAndReportsAtMostTwicePerSecond() throws {
        let id = UUID()
        let accumulator = DSPProcessingLoadAccumulator(nodeIDs: [id])
        for sample in 0..<5 {
            XCTAssertTrue(accumulator.beginBlock(frames: 6000, sampleRate: 48_000))
            accumulator.recordNode(at: 0, nanoseconds: 1_000_000)
            accumulator.recordNode(at: 0, nanoseconds: 2_000_000) // required preview
            accumulator.finishBlock(nanoseconds: 4_000_000, at: UInt64(sample) * 125_000_000, succeeded: true)
            if sample < 4 {
                XCTAssertNil(accumulator.takeSnapshotIfDue(requestID: nil, revision: "test", format: format))
            }
        }
        let snapshot = try XCTUnwrap(accumulator.takeSnapshotIfDue(requestID: nil, revision: "test", format: format))
        XCTAssertEqual(snapshot.sampleCount, 5)
        XCTAssertEqual(try XCTUnwrap(snapshot.nodes[id]).averageRatio, 0.024, accuracy: 1e-12)
        XCTAssertEqual(snapshot.chain.averageRatio, 0.032, accuracy: 1e-12)
        XCTAssertNil(accumulator.takeSnapshotIfDue(requestID: nil, revision: "test", format: format))
    }

    func testSampleCadenceTracksAudioDurationAtDifferentSampleRates() {
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let accumulator = DSPProcessingLoadAccumulator(nodeIDs: [])
            var count = 0
            let blocks = Int(rate / 2048)
            for _ in 0..<blocks {
                if accumulator.beginBlock(frames: 2048, sampleRate: rate) { count += 1 }
            }
            XCTAssertGreaterThan(count, 5)
            XCTAssertLessThanOrEqual(count, 8)
        }
    }

    func testFailedBlocksAreExcludedAndAveragesAreWeightedByAudioDuration() throws {
        let id = UUID()
        let accumulator = DSPProcessingLoadAccumulator(nodeIDs: [id])
        XCTAssertTrue(accumulator.beginBlock(frames: 6000, sampleRate: 48_000))
        accumulator.recordNode(at: 0, nanoseconds: 999_000_000)
        accumulator.finishBlock(nanoseconds: 999_000_000, at: 0, succeeded: false)
        for (frames, cost, time) in [(6000, UInt64(1_000_000), UInt64(100_000_000)),
                                      (12000, UInt64(4_000_000), UInt64(600_000_000))] {
            XCTAssertTrue(accumulator.beginBlock(frames: frames, sampleRate: 48_000))
            accumulator.recordNode(at: 0, nanoseconds: cost)
            accumulator.finishBlock(nanoseconds: cost + 1_000_000, at: time, succeeded: true)
        }
        let snapshot = try XCTUnwrap(accumulator.takeSnapshotIfDue(requestID: nil, revision: "test", format: format))
        let load = try XCTUnwrap(snapshot.nodes[id])
        XCTAssertEqual(snapshot.sampleCount, 2)
        XCTAssertEqual(load.averageRatio, 0.005 / 0.375, accuracy: 1e-12)
        XCTAssertEqual(load.sampledPeakRatio, 0.016, accuracy: 1e-12)
    }

    func testAverageSmoothsWhileRecentSamplePeakRemainsVisible() throws {
        let accumulator = DSPProcessingLoadAccumulator(nodeIDs: [])
        for time in [UInt64(0), 500_000_000] {
            XCTAssertTrue(accumulator.beginBlock(frames: 6000, sampleRate: 48_000))
            accumulator.finishBlock(nanoseconds: 25_000_000, at: time, succeeded: true)
        }
        let first = try XCTUnwrap(accumulator.takeSnapshotIfDue(requestID: nil, revision: "test", format: format))
        XCTAssertEqual(first.chain.averageRatio, 0.2, accuracy: 1e-12)
        XCTAssertTrue(accumulator.beginBlock(frames: 6000, sampleRate: 48_000))
        accumulator.finishBlock(nanoseconds: 12_500_000, at: 1_000_000_000, succeeded: true)
        let second = try XCTUnwrap(accumulator.takeSnapshotIfDue(requestID: nil, revision: "test", format: format))
        XCTAssertGreaterThan(second.chain.averageRatio, 0.1)
        XCTAssertLessThan(second.chain.averageRatio, 0.2)
        XCTAssertEqual(second.chain.sampledPeakRatio, 0.1, accuracy: 1e-12)
    }

    func testColorBudgetUsesAbsoluteLoadAndDoesNotClampReportedOverruns() {
        let low = DSPProcessingLoad(averageRatio: 0.01, sampledPeakRatio: 0.02)
        let high = DSPProcessingLoad(averageRatio: 1.2, sampledPeakRatio: 1.4)
        XCTAssertLessThan(low.colorPosition(isChain: false), 1.0 / 3)
        XCTAssertEqual(high.colorPosition(isChain: false), 1)
        XCTAssertEqual(high.colorPosition(isChain: true), 1)
        XCTAssertEqual(high.averageRatio, 1.2)
    }

    func testFaultedNodeHasNoCardValueWhileChainStillIncludesItsProcessingCost() throws {
        let faulted = UUID(), active = UUID()
        let accumulator = DSPProcessingLoadAccumulator(nodeIDs: [faulted, active])
        for time in [UInt64(0), 500_000_000] {
            XCTAssertTrue(accumulator.beginBlock(frames: 6000, sampleRate: 48_000))
            accumulator.recordNode(at: 0, nanoseconds: 3_000_000)
            accumulator.recordNode(at: 1, nanoseconds: 1_000_000)
            accumulator.finishBlock(nanoseconds: 5_000_000, at: time, succeeded: true)
        }
        let snapshot = try XCTUnwrap(accumulator.takeSnapshotIfDue(requestID: nil, revision: "test", format: format,
            excludedNodeIDs: [faulted]))
        XCTAssertNil(snapshot.nodes[faulted])
        XCTAssertEqual(try XCTUnwrap(snapshot.nodes[active]).averageRatio, 0.008, accuracy: 1e-12)
        XCTAssertEqual(snapshot.chain.averageRatio, 0.04, accuracy: 1e-12)
    }
}
