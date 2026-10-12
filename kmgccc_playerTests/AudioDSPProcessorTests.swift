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

    private func volumeContext(
        decibels: Double?,
        scalar: Double = 0.5
    ) -> DSPEqualLoudnessContext {
        DSPEqualLoudnessContext(
            volume: .available(OutputDeviceVolumeReading(
                deviceUID: "test-output", deviceName: "Test", scalar: scalar,
                decibelsBelowMaximum: decibels, isMuted: false, isWritable: true
            ))
        )
    }

    private func calibratedNode(_ calibration: EqualLoudnessCalibration) -> DSPNodeConfiguration {
        var node = DSPNodeConfiguration.equalLoudness()
        node.setEqualLoudnessCalibration(calibration)
        return node
    }

    func testCalibrationBelongsToItsNodeOnly() throws {
        let calibration = EqualLoudnessCalibration(
            deviceUID: "test-output", deviceName: "Test", axis: .decibels,
            points: [
                EqualLoudnessCalibrationPoint(coordinate: -20, bassDB: 0, trebleDB: 0),
                EqualLoudnessCalibrationPoint(coordinate: -30, bassDB: 8, trebleDB: 4),
            ]
        )
        let calibrated = calibratedNode(calibration)
        XCTAssertEqual(calibrated.equalLoudnessCalibration(forDeviceUID: "test-output")?.points, calibration.points)
        let context = volumeContext(decibels: -30)
        XCTAssertEqual(DSPEqualLoudnessMath.gains(node: calibrated, context: context).bassDB, 8, accuracy: 1e-8)
        // A fresh node in another preset follows the default curve.
        let fresh = DSPNodeConfiguration.equalLoudness()
        XCTAssertNil(context.usableCalibration(in: fresh))
        XCTAssertEqual(DSPEqualLoudnessMath.gains(node: fresh, context: context).bassDB, 6, accuracy: 1e-8)

        var removed = calibrated
        removed.setEqualLoudnessCalibration(nil, removingDeviceUID: "test-output")
        XCTAssertNil(removed.parameters["calibrations"])
        let roundTrip = try JSONDecoder().decode(DSPNodeConfiguration.self, from: JSONEncoder().encode(calibrated))
        XCTAssertEqual(roundTrip.equalLoudnessCalibrations.first?.points, calibration.points)
    }

    func testDefaultEqualLoudnessCurveFollowsSystemVolumeOnly() {
        let node = DSPNodeConfiguration.equalLoudness()
        let atReference = DSPEqualLoudnessMath.gains(node: node, context: volumeContext(decibels: -10))
        XCTAssertEqual(atReference, .zero)
        XCTAssertEqual(DSPEqualLoudnessMath.gains(node: node, context: volumeContext(decibels: 0)), .zero)

        let quieter = DSPEqualLoudnessMath.gains(node: node, context: volumeContext(decibels: -20))
        XCTAssertEqual(quieter.bassDB, 3, accuracy: 1e-8)
        XCTAssertEqual(quieter.trebleDB, 1.5, accuracy: 1e-8)

        let muchQuieter = DSPEqualLoudnessMath.gains(node: node, context: volumeContext(decibels: -40))
        XCTAssertEqual(muchQuieter.bassDB, 6, accuracy: 1e-8)
        XCTAssertEqual(muchQuieter.trebleDB, 3, accuracy: 1e-8)

        // A device without a readable volume never falls back to App volume.
        XCTAssertEqual(DSPEqualLoudnessMath.gains(node: node, context: .inactive), .zero)

        // A percentage-only device uses the 40·log10 slider estimate.
        let percent = DSPEqualLoudnessMath.gains(node: node, context: volumeContext(decibels: nil, scalar: 0.1))
        XCTAssertEqual(percent.bassDB, 6, accuracy: 1e-8)

        var preview = volumeContext(decibels: 0)
        preview.override = DSPEqualLoudnessGains(bassDB: 20, trebleDB: 2)
        XCTAssertEqual(DSPEqualLoudnessMath.gains(node: node, context: preview),
                       DSPEqualLoudnessGains(bassDB: 12, trebleDB: 2))
    }

    func testCalibratedCurveIsMonotoneHeldAtEndsAndPassesThroughPoints() throws {
        let calibration = EqualLoudnessCalibration(
            deviceUID: "test-output", deviceName: "Test", axis: .decibels,
            points: [
                EqualLoudnessCalibrationPoint(coordinate: -6, bassDB: 0, trebleDB: 0),
                EqualLoudnessCalibrationPoint(coordinate: -14, bassDB: 4, trebleDB: 1),
                EqualLoudnessCalibrationPoint(coordinate: -22, bassDB: 7, trebleDB: 2),
                EqualLoudnessCalibrationPoint(coordinate: -34, bassDB: 9, trebleDB: 3),
            ]
        )
        let node = calibratedNode(calibration)
        func gains(_ db: Double) -> DSPEqualLoudnessGains {
            DSPEqualLoudnessMath.gains(node: node, context: volumeContext(decibels: db))
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

    func testCalibrationAllowsCutsAboveTheReference() {
        let calibration = EqualLoudnessCalibration(
            deviceUID: "test-output", deviceName: "Test", axis: .decibels,
            points: [
                EqualLoudnessCalibrationPoint(coordinate: -20, bassDB: 0, trebleDB: 0),
                EqualLoudnessCalibrationPoint(coordinate: -28, bassDB: 4, trebleDB: 2),
                EqualLoudnessCalibrationPoint(coordinate: -34, bassDB: 7, trebleDB: 3),
                EqualLoudnessCalibrationPoint(coordinate: -10, bassDB: -2, trebleDB: -1),
            ]
        )
        let node = calibratedNode(calibration)
        let louder = DSPEqualLoudnessMath.gains(
            node: node, context: volumeContext(decibels: -10)
        )
        XCTAssertEqual(louder.bassDB, -2, accuracy: 1e-8)
        let bands = DSPEqualLoudnessMath.bands(
            node: node, context: volumeContext(decibels: -10)
        )
        XCTAssertEqual(bands?.first?.enabled, true)
        XCTAssertLessThan(
            DSPEqualLoudnessMath.responseDB(
                node: node, context: volumeContext(decibels: -10),
                at: 20, sampleRate: 48_000
            ),
            -1.5
        )
    }

    func testEqualLoudnessParameterEditPreservesUnknownJSONFields() throws {
        var node = DSPNodeConfiguration.equalLoudness()
        node.parameters["futureParameter"] = .object(["preserve": .bool(true)])
        var parameters = try XCTUnwrap(node.equalLoudnessParameters)
        parameters.strength = 0.5
        node.equalLoudnessParameters = parameters

        XCTAssertEqual(node.parameters["futureParameter"], .object(["preserve": .bool(true)]))
        XCTAssertEqual(node.equalLoudnessParameters?.strength, 0.5)
    }

    func testEqualLoudnessResponseAndAutomaticHeadroomUseTheActiveReference() throws {
        let node = DSPNodeConfiguration.equalLoudness()
        let context = volumeContext(decibels: -40)
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
