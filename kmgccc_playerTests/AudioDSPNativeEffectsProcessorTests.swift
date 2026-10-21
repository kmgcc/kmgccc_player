import AVFoundation
import XCTest
@testable import kmgccc_player

final class AudioDSPNativeEffectsProcessorTests: XCTestCase {
    func testStereoWidthRequiresAnExplicitFrontPairAndPreservesOtherChannels() {
        let monoFormat = DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 1,
            rawLayoutData: nil,
            channelLabels: [UInt32(kAudioChannelLabel_Mono)],
            layoutIsKnown: true
        )
        var widthParameters = DSPStereoWidthParameters(width: 0)
        widthParameters.loudnessMatchEnabled = false
        let widthNode = DSPNodeConfiguration.stereoWidth(parameters: widthParameters)
        let monoProcessor = processor(nodes: [widthNode], format: monoFormat)
        let monoInput = CanonicalPCM(
            frames: 2,
            channelCount: 1,
            sampleRate: 48_000,
            data: [0.25, -0.5]
        )
        XCTAssertTrue(monoProcessor.isBypassed)
        XCTAssertTrue(monoProcessor.diagnostics.contains { $0.code == "frontStereoPairUnavailable" })
        XCTAssertEqual(monoProcessor.process(monoInput).data, monoInput.data)

        let unknownFormat = DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            rawLayoutData: nil,
            channelLabels: nil,
            layoutIsKnown: false
        )
        let unknownProcessor = processor(nodes: [widthNode], format: unknownFormat)
        XCTAssertTrue(unknownProcessor.isBypassed)
        XCTAssertTrue(unknownProcessor.diagnostics.contains { $0.code == "frontStereoPairUnavailable" })

        let multichannelFormat = DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 3,
            rawLayoutData: nil,
            channelLabels: [
                UInt32(kAudioChannelLabel_Left),
                UInt32(kAudioChannelLabel_Right),
                UInt32(kAudioChannelLabel_Center),
            ],
            layoutIsKnown: true
        )
        let multichannelProcessor = processor(nodes: [widthNode], format: multichannelFormat)
        let multichannelInput = CanonicalPCM(
            frames: 2,
            channelCount: 3,
            sampleRate: 48_000,
            data: [1, 0, 0.25, -0.5, 0.5, -0.125]
        )
        let output = multichannelProcessor.process(multichannelInput)
        XCTAssertEqual(output.data[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(output.data[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(output.data[2], 0.25, accuracy: 1e-6)
        XCTAssertEqual(output.data[3], 0, accuracy: 1e-6)
        XCTAssertEqual(output.data[4], 0, accuracy: 1e-6)
        XCTAssertEqual(output.data[5], -0.125, accuracy: 1e-6)
        XCTAssertEqual(multichannelProcessor.processingLatencyFrames, 0)
    }

    func testZeroWetNativeEffectsAreExactBypassWithoutLatency() {
        var dryBass = DSPClassicBassParameters()
        dryBass.intensity = 0
        dryBass.retainsRealBass = true
        let bassOff = DSPNodeConfiguration.classicBass(parameters: dryBass)
        var dryHybrid = DSPHybridBassParameters()
        dryHybrid.intensity = 0
        dryHybrid.retainsRealBass = true
        let hybridOff = DSPNodeConfiguration.effect(dryHybrid)
        let tubeMixOff = DSPNodeConfiguration.tube(parameters: DSPTubeParameters(mode: .classic, mix: 0, inputTrimDB: 12))
        let hifiOff = DSPNodeConfiguration.tube(parameters: DSPTubeParameters(mode: .hifi, hifiAmount: 0))
        let identityWidth = DSPNodeConfiguration.stereoWidth(parameters: DSPStereoWidthParameters(width: 1))
        var dryReverb = DSPReverbParameters()
        dryReverb.mix = 0
        let reverbOff = DSPNodeConfiguration.effect(dryReverb)
        var drySpatial = DSPSpatialAudioParameters()
        drySpatial.mix = 0
        let spatialOff = DSPNodeConfiguration.effect(drySpatial)
        let input = CanonicalPCM(
            frames: 5,
            channelCount: 2,
            sampleRate: 48_000,
            data: [0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 1, -1, -0.125, 0.125]
        )

        for node in [bassOff, hybridOff, tubeMixOff, hifiOff, identityWidth, reverbOff, spatialOff] {
            let runtime = processor(nodes: [node], format: stereoFormat(sampleRate: 48_000))
            XCTAssertTrue(runtime.isBypassed, node.typeID)
            XCTAssertEqual(runtime.processingLatencyFrames, 0)
            XCTAssertEqual(runtime.peakGuarantee, "bypassed")
            XCTAssertEqual(runtime.process(input).data, input.data)
        }

        // A dry effect still honours its output trim, as a plain gain.
        let gain = Float(pow(10, -6.0 / 20))
        drySpatial.outputTrimDB = -6
        let spatialTrimmed = processor(nodes: [.effect(drySpatial)], format: stereoFormat(sampleRate: 48_000))
        XCTAssertEqual(spatialTrimmed.processingLatencyFrames, 0)
        for (output, sample) in zip(spatialTrimmed.process(input).data, input.data) {
            XCTAssertEqual(output, sample * gain, accuracy: 1e-6)
        }
    }

    func testPolyphaseLinearReferenceHasAnInteger64FrameDelayAtEveryQuality() throws {
        for factor in [2, 4] {
            let plan = try XCTUnwrap(DSPPolyphaseFIRPlan(factor: factor))
            var inputHistory = DSPMirroredFIRHistory(capacity: plan.historyCount)
            var reconstruction = DSPMirroredFIRHistory(capacity: plan.tapCount)
            var impulseResponse = [Double](repeating: 0, count: 384)

            for frame in impulseResponse.indices {
                inputHistory.push(frame == 0 ? 1 : 0)
                for phase in 0..<factor {
                    reconstruction.push(plan.interpolate(phase: phase, history: inputHistory))
                    if phase == 0 {
                        impulseResponse[frame] = plan.decimate(history: reconstruction)
                    }
                }
            }

            let signedArea = impulseResponse.reduce(0, +)
            let firstMoment = impulseResponse.enumerated().reduce(0.0) {
                $0 + Double($1.offset) * $1.element
            }
            XCTAssertEqual(signedArea, 1, accuracy: 0.01)
            XCTAssertEqual(firstMoment / signedArea, 64, accuracy: 0.15)
            let peakFrame = try XCTUnwrap(
                impulseResponse.indices.max { impulseResponse[$0] < impulseResponse[$1] }
            )
            XCTAssertEqual(peakFrame, 64)
        }
    }

    func testLatencyCompensationMapsAnImpulseToItsOriginalFrame() {
        let runtime = processor(
            nodes: [tubeNode(quality: "oversampling4x", bias: 0, removeDC: false)],
            format: stereoFormat(sampleRate: 48_000)
        )
        XCTAssertEqual(runtime.processingLatencyFrames, 64)
        XCTAssertEqual(runtime.peakGuarantee, "unavailable")

        let impulseFrame = 192
        var samples = [Float](repeating: 0, count: 512 * 2)
        samples[impulseFrame * 2] = 0.8
        samples[impulseFrame * 2 + 1] = 0.8
        let output = runtime.process(CanonicalPCM(
            frames: 512,
            channelCount: 2,
            sampleRate: 48_000,
            data: samples
        ))
        let peakFrame = (0..<output.frames).max {
            abs(output.data[$0 * 2]) < abs(output.data[$1 * 2])
        } ?? -1
        XCTAssertEqual(peakFrame, impulseFrame)
    }

    func testFullRangeTubeKeepsAnUnselectedLFESignalOnTheSameTimeMapping() {
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
        let runtime = processor(
            nodes: [tubeNode(quality: "oversampling2x", bias: 0, removeDC: false)],
            format: format
        )
        let impulseFrame = 128
        var data = [Float](repeating: 0, count: 384 * 4)
        data[impulseFrame * 4 + 3] = 0.8
        let output = runtime.process(CanonicalPCM(
            frames: 384,
            channelCount: 4,
            sampleRate: 48_000,
            data: data
        ))
        let lfePeak = (0..<output.frames).max {
            abs(output.data[$0 * 4 + 3]) < abs(output.data[$1 * 4 + 3])
        } ?? -1
        XCTAssertEqual(runtime.processingLatencyFrames, 64)
        XCTAssertEqual(lfePeak, impulseFrame)
        for frame in 0..<output.frames {
            XCTAssertEqual(output.data[frame * 4 + 3], data[frame * 4 + 3])
        }
    }

    func testFrontPairClassicBassLeavesOtherChannelsUntouched() {
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
        let node = DSPNodeConfiguration.classicBass(
            parameters: bassParameters(intensity: 0.7),
            channelPolicy: "frontPair"
        )
        let runtime = processor(nodes: [node], format: format)
        let inputData = (0..<256 * 4).map { Float(($0 % 31 - 15) / 32) }
        let input = CanonicalPCM(
            frames: 256,
            channelCount: 4,
            sampleRate: 48_000,
            data: inputData
        )
        let output = runtime.process(input)

        // Harmonic synthesis is zero-latency; only the front pair changes.
        XCTAssertEqual(runtime.processingLatencyFrames, 0)
        for frame in 0..<input.frames {
            XCTAssertEqual(output.data[frame * 4 + 2], inputData[frame * 4 + 2])
            XCTAssertEqual(output.data[frame * 4 + 3], inputData[frame * 4 + 3])
        }
    }

    func testChunkedProcessingMatchesWholeBufferWithRealLookaheadAndShortBlocks() {
        let nodes = [
            tubeNode(quality: "oversampling2x", bias: 0.2, removeDC: true),
            bassNode(intensity: 0.7),
        ]
        let format = stereoFormat(sampleRate: 48_000)
        let source = deterministicInput(frames: 1_537, sampleRate: 48_000)
        let whole = processor(nodes: nodes, format: format).process(source).data

        let chunkedProcessor = processor(nodes: nodes, format: format)
        XCTAssertEqual(chunkedProcessor.processingLatencyFrames, 64)
        var chunked: [Float] = []
        let blockSizes = [1, 17, 63, 9, 128, 3, 211, 64, 5, 257]
        var offset = 0
        var sizeIndex = 0
        while offset < source.frames {
            let count = min(blockSizes[sizeIndex % blockSizes.count], source.frames - offset)
            let end = offset + count
            let input = source.slice(frameOffset: offset, frameCount: count)
            let future = source.slice(
                frameOffset: end,
                frameCount: chunkedProcessor.processingLatencyFrames
            )
            chunked.append(contentsOf: chunkedProcessor.process(input, lookahead: future).data)
            offset = end
            sizeIndex += 1
        }

        XCTAssertEqual(chunked.count, whole.count)
        for index in whole.indices {
            XCTAssertEqual(chunked[index], whole[index], accuracy: 1e-6, "sample \(index)")
        }
    }

    /// A snapshot carries how far the chain had run ahead, so a processor
    /// restored from it continues exactly like the one it was taken from.
    func testRunAheadSnapshotRestoresIntoAFreshProcessor() throws {
        let nodes = [
            tubeNode(quality: "oversampling2x", bias: 0.2, removeDC: true),
            bassNode(intensity: 0.7),
            DSPNodeConfiguration.effect(DSPCompressorParameters()),
        ]
        let format = stereoFormat(sampleRate: 48_000)
        let source = deterministicInput(frames: 1_024, sampleRate: 48_000)
        let original = processor(nodes: nodes, format: format)
        let latency = original.processingLatencyFrames
        _ = original.process(source.slice(frameOffset: 0, frameCount: 400),
                             lookahead: source.slice(frameOffset: 400, frameCount: latency))
        let snapshot = try XCTUnwrap(original.stateSnapshot())
        let block = source.slice(frameOffset: 400, frameCount: 300)
        let future = source.slice(frameOffset: 700, frameCount: latency)
        let expected = original.process(block, lookahead: future)

        let restored = processor(nodes: nodes, format: format)
        XCTAssertTrue(restored.restoreState(snapshot))
        let output = restored.process(block, lookahead: future)
        XCTAssertEqual(output.data, expected.data)
    }

    /// Zero padding past a stream end drains on a copy. When the next source
    /// arrives late but gapless, the live chain continues from real audio.
    func testPaddedStreamEndLeavesTheLiveChainOnRealAudio() {
        let nodes = [tubeNode(quality: "oversampling4x", bias: 0.1, removeDC: true)]
        let format = stereoFormat(sampleRate: 48_000)
        let source = deterministicInput(frames: 1_200, sampleRate: 48_000)
        let continuous = processor(nodes: nodes, format: format).process(source)

        let runtime = processor(nodes: nodes, format: format)
        let latency = runtime.processingLatencyFrames
        _ = runtime.process(source.slice(frameOffset: 0, frameCount: 600))
        let output = runtime.process(source.slice(frameOffset: 600, frameCount: 600),
                                     lookahead: source.slice(frameOffset: 1_200, frameCount: latency))
        let expected = continuous.slice(frameOffset: 600, frameCount: 600)
        XCTAssertEqual(output.data.count, expected.data.count)
        for index in output.data.indices {
            XCTAssertEqual(output.data[index], expected.data[index], accuracy: 1e-6, "sample \(index)")
        }
    }

    func testEOFZeroLookaheadRetainsFinalImpulseTailAndResetReplaysDeterministically() {
        let nodes = [tubeNode(quality: "oversampling2x", bias: 0, removeDC: false)]
        let format = stereoFormat(sampleRate: 48_000)
        let runtime = processor(nodes: nodes, format: format)
        var samples = [Float](repeating: 0, count: 320 * 2)
        samples[(319 * 2)] = 0.8
        samples[(319 * 2) + 1] = 0.8
        let input = CanonicalPCM(
            frames: 320,
            channelCount: 2,
            sampleRate: 48_000,
            data: samples
        )
        let first = runtime.process(input)
        XCTAssertTrue(first.data.allSatisfy(\.isFinite))
        let peakFrame = (0..<first.frames).max {
            abs(first.data[$0 * 2]) < abs(first.data[$1 * 2])
        } ?? -1
        XCTAssertEqual(peakFrame, 319)

        runtime.reset()
        XCTAssertEqual(runtime.process(input).data, first.data)
    }

    func testRawWarmupMatchesTheSameFramesProcessedInOneContinuousRun() {
        let nodes = [
            tubeNode(quality: "oversampling2x", bias: 0.25, removeDC: true),
            bassNode(intensity: 0.6),
        ]
        let format = stereoFormat(sampleRate: 48_000)
        let source = deterministicInput(frames: 1_024, sampleRate: 48_000)
        let continuous = processor(nodes: nodes, format: format).process(source)
        let warmed = processor(nodes: nodes, format: format)
        let history = source.slice(frameOffset: 0, frameCount: 192)
        warmed.warm(with: [history])
        let suffix = source.slice(frameOffset: 192, frameCount: 320)
        let future = source.slice(frameOffset: 512, frameCount: warmed.processingLatencyFrames)
        let output = warmed.process(suffix, lookahead: future)
        let expected = continuous.slice(frameOffset: 192, frameCount: 320)

        XCTAssertEqual(output.data.count, expected.data.count)
        for index in output.data.indices {
            XCTAssertEqual(output.data[index], expected.data[index], accuracy: 1e-6)
        }
    }

    func testOversampledTubeReducesFoldedThirdHarmonicAndRemovesAsymmetricDC() {
        let sampleRate = 48_000.0
        let toneFrames = 9_600
        let tone = (0..<toneFrames).map { frame in
            Float(0.7 * sin(2 * Double.pi * 15_000 * Double(frame) / sampleRate))
        }
        let stereoTone = CanonicalPCM(
            frames: toneFrames,
            channelCount: 2,
            sampleRate: sampleRate,
            data: tone.flatMap { [$0, $0] }
        )
        // Match the tube's 20 dB of internal working headroom.
        let directDrive: Double = pow(10.0, (18.0 - 20.0) / 20.0)
        let direct: [Float] = tone.map { sample in
            let driven = Double(sample) * directDrive
            let shaped = tanh(driven) / directDrive
            return Float(shaped)
        }
        let directAlias = magnitude(
            direct,
            channelCount: 1,
            channel: 0,
            sampleRate: sampleRate,
            frequency: 3_000,
            frameRange: 1_024..<(toneFrames - 1_024)
        )

        for quality in ["oversampling2x", "oversampling4x"] {
            let output = processor(
                nodes: [tubeNode(quality: quality, bias: 0, removeDC: false)],
                format: stereoFormat(sampleRate: sampleRate)
            ).process(stereoTone)
            let firstChannel = stride(from: 0, to: output.data.count, by: 2).map { output.data[$0] }
            let alias = magnitude(
                firstChannel,
                channelCount: 1,
                channel: 0,
                sampleRate: sampleRate,
                frequency: 3_000,
                frameRange: 1_024..<(toneFrames - 1_024)
            )
            XCTAssertLessThan(alias, directAlias * 0.1)
        }

        let dcToneFrames = 24_000
        let dcTone = CanonicalPCM(
            frames: dcToneFrames,
            channelCount: 2,
            sampleRate: sampleRate,
            data: (0..<dcToneFrames).flatMap { frame in
                let sample = Float(0.45 * sin(2 * Double.pi * 400 * Double(frame) / sampleRate))
                return [sample, sample]
            }
        )
        let withDC = processor(
            nodes: [tubeNode(quality: "oversampling4x", bias: 0.4, removeDC: false)],
            format: stereoFormat(sampleRate: sampleRate)
        ).process(dcTone)
        let withoutDC = processor(
            nodes: [tubeNode(quality: "oversampling4x", bias: 0.4, removeDC: true)],
            format: stereoFormat(sampleRate: sampleRate)
        ).process(dcTone)
        let measuredRange = (dcToneFrames / 2)..<dcToneFrames
        let meanWithDC = mean(firstChannel(of: withDC), range: measuredRange)
        let meanWithoutDC = mean(firstChannel(of: withoutDC), range: measuredRange)
        XCTAssertGreaterThan(abs(meanWithDC), 0.005)
        XCTAssertLessThan(abs(meanWithoutDC), abs(meanWithDC) * 0.2)
    }

    func testClassicTubeKeepsHotToneBelowOnePercentDistortion() {
        for sampleRate in [44_100.0, 48_000.0] {
            let frames = Int(sampleRate / 5)
            let amplitude = pow(10.0, -1.0 / 20.0)
            let input = CanonicalPCM(
                frames: frames, channelCount: 2, sampleRate: sampleRate,
                data: (0..<frames).flatMap { frame -> [Float] in
                    let sample = Float(amplitude * sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
                    return [sample, sample]
                }
            )
            let analysis = Int(sampleRate / 20)..<Int(sampleRate * 0.15)
            for quality in ["oversampling2x", "oversampling4x"] {
                let runtime = processor(
                    nodes: [.tube(parameters: DSPTubeParameters(mode: .classic, driveDB: 6, bias: 0.15, mix: 0.5),
                                  quality: quality)],
                    format: stereoFormat(sampleRate: sampleRate)
                )
                let output = firstChannel(of: runtime.process(input))
                func component(_ frequency: Double) -> Double {
                    magnitude(output, channelCount: 1, channel: 0, sampleRate: sampleRate,
                              frequency: frequency, frameRange: analysis)
                }
                let fundamental = component(1_000)
                let harmonicPower = (2...19).reduce(0.0) { power, order in
                    let harmonic = component(Double(order) * 1_000)
                    return power + harmonic * harmonic
                }
                XCTAssertEqual(fundamental, amplitude, accuracy: amplitude * 0.02,
                               "working headroom must preserve the listening level")
                XCTAssertLessThan(sqrt(harmonicPower) / fundamental, 0.01,
                                  "a hot piano partial must not drive the reference tube into heavy distortion")
                XCTAssertGreaterThan(component(2_000) / fundamental, 0.002,
                                     "the tube must retain its asymmetric coloration")
            }
        }
    }

    func testHifiTubeKeepsHotToneHarmonicsSmallAndReservesHeadroom() {
        let sampleRate = 48_000.0
        let frames = 9_600
        let amplitude = pow(10.0, -1.0 / 20.0)
        for quality in ["oversampling2x", "oversampling4x"] {
            for frequency in [200.0, 1_000.0] {
                let input = CanonicalPCM(
                    frames: frames, channelCount: 2, sampleRate: sampleRate,
                    data: (0..<frames).flatMap { frame -> [Float] in
                        let sample = Float(amplitude * sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
                        return [sample, sample]
                    }
                )
                for inputTrimDB in [0.0, 12.0] {
                    let runtime = AudioDSPProcessor(
                        configuration: AudioDSPConfiguration(
                            enabled: true,
                            headroom: DSPHeadroomConfiguration(mode: .automatic, maximumAttenuationDB: 12),
                            nodes: [.tube(parameters: DSPTubeParameters(mode: .hifi, hifiAmount: 1,
                                                                       inputTrimDB: inputTrimDB), quality: quality)],
                            limiter: DSPLimiterConfiguration(enabled: false)
                        ),
                        format: stereoFormat(sampleRate: sampleRate)
                    )
                    let output = firstChannel(of: runtime.process(input))
                    XCTAssertTrue(output.allSatisfy(\.isFinite))
                    XCTAssertLessThanOrEqual(output.map { abs($0) }.max() ?? 0, 1,
                                             "the tube's own harmonic addition must fit its static allowance")
                    XCTAssertLessThan(runtime.headroomDB, 0)
                    XCTAssertEqual(runtime.peakGuarantee, "unavailable")
                    if inputTrimDB == 0 {
                        func component(_ order: Int) -> Double {
                            magnitude(output, channelCount: 1, channel: 0, sampleRate: sampleRate,
                                      frequency: frequency * Double(order), frameRange: 2_400..<7_200)
                        }
                        let fundamental = component(1)
                        let harmonicPower = (2...19).reduce(0.0) { power, order in
                            let harmonic = component(order)
                            return power + harmonic * harmonic
                        }
                        XCTAssertLessThan(sqrt(harmonicPower) / fundamental, 0.04,
                                          "maximum hi-fi amount must remain a small harmonic supplement")
                        XCTAssertEqual(fundamental, amplitude * pow(10, runtime.headroomDB / 20),
                                       accuracy: amplitude * 0.01, "the dry signal remains intact")
                    }
                }
            }
        }
    }

    /// Changing the chain input gain changes the level, never how hard the
    /// tube saturates: harmonic ratios stay put while the fundamental follows.
    func testTubeSaturationIsReferencedToProgramLevelNotChainInputGain() {
        let sampleRate = 48_000.0
        let frames = 9_600
        let amplitude = pow(10.0, -1.0 / 20.0)
        let tone = CanonicalPCM(
            frames: frames,
            channelCount: 2,
            sampleRate: sampleRate,
            data: (0..<frames).flatMap { frame -> [Float] in
                let sample = Float(amplitude * sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
                return [sample, sample]
            }
        )
        let analysis = 2_400..<frames
        func measure(inputTrimDB: Double, mode: DSPTubeMode) -> (fundamentalDB: Double, secondDB: Double, thirdDB: Double) {
            let runtime = AudioDSPProcessor(
                configuration: AudioDSPConfiguration(
                    enabled: true,
                    inputTrimDB: inputTrimDB,
                    headroom: DSPHeadroomConfiguration(mode: .off),
                    nodes: [.tube(parameters: DSPTubeParameters(mode: mode, mix: 1))],
                    limiter: DSPLimiterConfiguration(enabled: false)
                ),
                format: stereoFormat(sampleRate: sampleRate)
            )
            let channel = firstChannel(of: runtime.process(tone))
            func level(_ frequency: Double) -> Double {
                20 * log10(magnitude(channel, channelCount: 1, channel: 0, sampleRate: sampleRate,
                                     frequency: frequency, frameRange: analysis))
            }
            let fundamental = level(1_000)
            return (fundamental, level(2_000) - fundamental, level(3_000) - fundamental)
        }

        for mode in DSPTubeMode.allCases {
            let reference = measure(inputTrimDB: 0, mode: mode)
            XCTAssertGreaterThan(reference.secondDB, -60, "the default tube is audible")
            for trim in [-12.0, 6.0, 12.0] {
                let changed = measure(inputTrimDB: trim, mode: mode)
                XCTAssertEqual(changed.fundamentalDB - reference.fundamentalDB, trim, accuracy: 0.1)
                XCTAssertEqual(changed.secondDB, reference.secondDB, accuracy: 0.1)
                XCTAssertEqual(changed.thirdDB, reference.thirdDB, accuracy: 0.1)
            }
        }
    }

    /// Envelope normalization makes every harmonic track the bass level, so
    /// harmonic-to-fundamental ratios stay put from quiet to loud.
    func testClassicBassHarmonicRatiosAreIndependentOfLevel() {
        let reference = classicBassHarmonics(levelDB: -20, impactDB: -12)
        XCTAssertGreaterThan(reference.thirdDB, -50, "the default bass is audible")
        for level in [-40.0, -6.0] {
            let measured = classicBassHarmonics(levelDB: level, impactDB: -12)
            XCTAssertEqual(measured.secondDB, reference.secondDB, accuracy: 1.5, "level \(level)")
            XCTAssertEqual(measured.thirdDB, reference.thirdDB, accuracy: 1.5, "level \(level)")
        }
    }

    func testClassicBassImpactIncreasesHigherHarmonicLevel() {
        let gentle = classicBassHarmonics(levelDB: -20, impactDB: -18)
        let punchy = classicBassHarmonics(levelDB: -20, impactDB: -8)
        XCTAssertGreaterThan(punchy.thirdDB, gentle.thirdDB)
    }

    /// Second and third harmonic of a 50 Hz tone relative to the fundamental.
    private func classicBassHarmonics(levelDB: Double, impactDB: Double = -12) -> (secondDB: Double, thirdDB: Double) {
        let sampleRate = 48_000.0
        let frames = 48_000
        let amplitude = pow(10, levelDB / 20)
        let monoFormat = DSPAudioFormat(
            sampleRate: sampleRate,
            channelCount: 1,
            rawLayoutData: nil,
            channelLabels: [UInt32(kAudioChannelLabel_Mono)],
            layoutIsKnown: true
        )
        let input = CanonicalPCM(
            frames: frames,
            channelCount: 1,
            sampleRate: sampleRate,
            data: (0..<frames).map { Float(amplitude * sin(2 * Double.pi * 50 * Double($0) / sampleRate)) }
        )
        var params = bassParameters(intensity: 0.7)
        params.impactDB = impactDB
        let node = DSPNodeConfiguration.classicBass(parameters: params)
        let output = processor(nodes: [node], format: monoFormat).process(input)
        let analysis = 12_000..<frames
        func level(_ frequency: Double) -> Double {
            20 * log10(magnitude(output.data, channelCount: 1, channel: 0, sampleRate: sampleRate,
                                 frequency: frequency, frameRange: analysis))
        }
        let fundamental = level(50)
        return (level(100) - fundamental, level(150) - fundamental)
    }

    func testMixedNodeOrderIsFiniteAndDeterministicAtCommonAndHighSampleRates() {
        for sampleRate in [48_000.0, 96_000.0, 192_000.0] {
            let format = stereoFormat(sampleRate: sampleRate)
            let nodes = [
                tubeNode(quality: "oversampling4x", bias: 0.15, removeDC: true),
                DSPNodeConfiguration.stereoWidth(
                    parameters: DSPStereoWidthParameters(width: 1.4, outputTrimDB: -1)
                ),
                bassNode(intensity: 0.8),
                DSPNodeConfiguration.effect(DSPCrossfeedParameters()),
                DSPNodeConfiguration.effect(DSPReverbParameters(space: .plate)),
                DSPNodeConfiguration.effect(DSPCompressorParameters(style: .night)),
            ]
            let input = deterministicInput(frames: 512, sampleRate: sampleRate)
            let firstProcessor = processor(nodes: nodes, format: format)
            let secondProcessor = processor(nodes: nodes, format: format)
            let first = firstProcessor.process(input)
            let second = secondProcessor.process(input)

            XCTAssertEqual(firstProcessor.processingLatencyFrames, 64)
            XCTAssertTrue(first.data.allSatisfy(\.isFinite))
            XCTAssertEqual(first.data, second.data)
        }
    }

    func testMaximumNodeCountProducesTheDeclaredBoundedLatency() {
        let nodes = (0..<AudioDSPConfiguration.maximumNodeCount).map { _ in
            tubeNode(quality: "oversampling4x", bias: 0.1, removeDC: true)
        }
        let runtime = processor(nodes: nodes, format: stereoFormat(sampleRate: 48_000))
        XCTAssertEqual(runtime.processingLatencyFrames, 2_048)
        XCTAssertEqual(runtime.peakGuarantee, "unavailable")
    }

    private func processor(nodes: [DSPNodeConfiguration], format: DSPAudioFormat) -> AudioDSPProcessor {
        AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: nodes,
                limiter: DSPLimiterConfiguration(enabled: false)
            ),
            format: format
        )
    }

    private func stereoFormat(sampleRate: Double) -> DSPAudioFormat {
        DSPAudioFormat(
            sampleRate: sampleRate,
            channelCount: 2,
            rawLayoutData: nil,
            channelLabels: [
                UInt32(kAudioChannelLabel_Left),
                UInt32(kAudioChannelLabel_Right),
            ],
            layoutIsKnown: true
        )
    }

    private func tubeNode(
        quality: String,
        bias: Double,
        removeDC: Bool
    ) -> DSPNodeConfiguration {
        .tube(
            parameters: DSPTubeParameters(
                mode: .classic,
                driveDB: 18,
                bias: bias,
                mix: 1,
                inputTrimDB: 0,
                outputTrimDB: 0,
                dcRemovalEnabled: removeDC,
                dcBlockHz: 10
            ),
            channelPolicy: "fullRange",
            quality: quality
        )
    }

    /// Classic bass tuned for speakers, so results never depend on the route.
    private func bassParameters(
        intensity: Double,
        retainsRealBass: Bool = true
    ) -> DSPClassicBassParameters {
        var parameters = DSPClassicBassParameters()
        parameters.target = .speakers
        parameters.intensity = intensity
        parameters.retainsRealBass = retainsRealBass
        return parameters
    }

    private func bassNode(intensity: Double) -> DSPNodeConfiguration {
        .classicBass(parameters: bassParameters(intensity: intensity))
    }

    private func deterministicInput(frames: Int, sampleRate: Double) -> CanonicalPCM {
        var data = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let sample = Float(
                0.31 * sin(2 * Double.pi * 173 * Double(frame) / sampleRate)
                    + 0.13 * cos(2 * Double.pi * 3_711 * Double(frame) / sampleRate)
            )
            data[frame * 2] = sample
            data[frame * 2 + 1] = -sample * 0.73
        }
        return CanonicalPCM(frames: frames, channelCount: 2, sampleRate: sampleRate, data: data)
    }

    private func firstChannel(of pcm: CanonicalPCM) -> [Float] {
        stride(from: 0, to: pcm.data.count, by: pcm.channelCount).map { pcm.data[$0] }
    }

    private func mean(_ values: [Float], range: Range<Int>) -> Double {
        let samples = range.map { Double(values[$0]) }
        return samples.reduce(0, +) / Double(samples.count)
    }

    private func magnitude(
        _ values: [Float],
        channelCount: Int,
        channel: Int,
        sampleRate: Double,
        frequency: Double,
        frameRange: Range<Int>
    ) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for frame in frameRange {
            let value = Double(values[frame * channelCount + channel])
            let angle = 2 * Double.pi * frequency * Double(frame) / sampleRate
            real += value * cos(angle)
            imaginary -= value * sin(angle)
        }
        return 2 * hypot(real, imaginary) / Double(frameRange.count)
    }
}

/// Checks of the second-generation effect kernels against their published
/// designs or an independent reference.
final class AudioDSPEffectsV2KernelTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testStereoWidthNeverChangesTheMonoSum() throws {
        var parameters = DSPStereoWidthParameters()
        parameters.loudnessMatchEnabled = false
        var kernel = try XCTUnwrap(DSPStereoWidthKernel(leftChannel: 0, rightChannel: 1,
                                                        sampleRate: sampleRate, parameters: parameters))
        var noise = TestNoise(seed: 3)
        let input = (0..<9_600 * 2).map { _ in noise.next() * 0.3 }
        var output = input
        process(&kernel, &output, channels: 2, blockSize: 480)
        for frame in 0..<9_600 {
            XCTAssertEqual(output[frame * 2] + output[frame * 2 + 1], input[frame * 2] + input[frame * 2 + 1],
                           accuracy: 1e-12)
        }
        XCTAssertNotEqual(output, input, "the image widens")
    }

    /// Widening keeps the centre at unity: the loudness gain only ever lifts.
    func testStereoWidthNeverLowersTheMid() throws {
        var kernel = try XCTUnwrap(DSPStereoWidthKernel(leftChannel: 0, rightChannel: 1, sampleRate: sampleRate,
                                                        parameters: DSPStereoWidthParameters(width: 2)))
        var noise = TestNoise(seed: 9)
        // A mostly centred mix, so the guard lets the full width through.
        let input = (0..<48_000).flatMap { _ -> [Double] in
            let mid = noise.next() * 0.3
            let side = noise.next() * 0.09
            return [mid + side, mid - side]
        }
        var output = input
        process(&kernel, &output, channels: 2, blockSize: 480)
        XCTAssertNotEqual(output, input, "the image widens")
        // After the one-second settling the mid equals the input's.
        for frame in 24_000..<48_000 {
            XCTAssertEqual(output[frame * 2] + output[frame * 2 + 1], input[frame * 2] + input[frame * 2 + 1],
                           accuracy: 1e-9)
        }
    }

    /// Widening keeps the centre at unity, so the chain is not turned down
    /// to make room for it.
    func testWideningReservesNoAutomaticHeadroom() {
        let runtime = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .automatic),
                nodes: [.stereoWidth(parameters: DSPStereoWidthParameters(width: 3))]
            ),
            format: DSPAudioFormat(sampleRate: sampleRate, channelCount: 2, rawLayoutData: nil,
                                   channelLabels: [UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)],
                                   layoutIsKnown: true)
        )
        XCTAssertFalse(runtime.isBypassed)
        XCTAssertEqual(runtime.headroomDB, 0, accuracy: 1e-9)
    }

    /// The harmonic supplement must not turn the beat between bass notes
    /// into a loud pitch of its own.
    func testClassicBassSuppressesDifferenceTones() {
        var parameters = DSPClassicBassParameters()
        parameters.target = .headphones
        parameters.intensity = 1
        parameters.retainsRealBass = true
        let format = DSPAudioFormat(sampleRate: sampleRate, channelCount: 1, rawLayoutData: nil,
                                    channelLabels: [UInt32(kAudioChannelLabel_Mono)], layoutIsKnown: true)
        let runtime = AudioDSPProcessor(
            configuration: AudioDSPConfiguration(enabled: true, headroom: DSPHeadroomConfiguration(mode: .off),
                                                 nodes: [.effect(parameters)],
                                                 limiter: DSPLimiterConfiguration(enabled: false)),
            format: format)
        let frames = Int(sampleRate * 1.5)
        let input = CanonicalPCM(frames: frames, channelCount: 1, sampleRate: sampleRate, data: (0..<frames).map {
            let t = Double($0) / sampleRate
            return Float(0.2 * sin(2 * Double.pi * 40 * t) + 0.1 * sin(2 * Double.pi * 55 * t))
        })
        let output = runtime.process(input).data.map(Double.init)
        let analysis = Int(sampleRate / 2)..<frames
        func level(_ frequency: Double) -> Double {
            20 * log10(max(Self.magnitude(output, channels: 1, frequency: frequency, sampleRate: sampleRate,
                                          frames: analysis), 1e-12))
        }
        let third = level(120)
        XCTAssertGreaterThan(third, -50, "the low-order harmonic supplement remains present")
        XCTAssertLessThan(level(105) - third, -12)
        XCTAssertLessThan(level(180) - third, -12)
    }

    func testStereoWidthPassesAMonoSourceUnchanged() throws {
        var kernel = try XCTUnwrap(DSPStereoWidthKernel(leftChannel: 0, rightChannel: 1, sampleRate: sampleRate,
                                                        parameters: DSPStereoWidthParameters()))
        var noise = TestNoise(seed: 5)
        let input = (0..<4_800).flatMap { _ -> [Double] in
            let value = noise.next() * 0.3
            return [value, value]
        }
        var output = input
        process(&kernel, &output, channels: 2, blockSize: 512)
        for index in input.indices {
            XCTAssertEqual(output[index], input[index], accuracy: 1e-12)
        }
    }

    /// bs2b's design targets: at low frequencies the opposite ear hears the
    /// signal `feedDB` below the near ear and a centred source keeps unity
    /// gain; high frequencies stay with their own ear.
    func testCrossfeedMatchesTheBauerBs2bDesign() throws {
        for strength in DSPCrossfeedStrength.allCases {
            let parameters = DSPCrossfeedParameters(strength: strength)
            // 30 Hz completes whole cycles in the analysis window.
            let low = try crossfeedResponse(parameters, frequency: 30)
            XCTAssertEqual(low.oppositeDB, -parameters.feedDB, accuracy: 0.15, "\(strength)")
            XCTAssertEqual(low.centredDB, 0, accuracy: 0.15, "\(strength)")
            let high = try crossfeedResponse(parameters, frequency: 12_000)
            XCTAssertLessThan(high.oppositeDB, -20, "\(strength)")
        }
    }

    func testHRTFWindowRetainsLateEnergyAndInterauralTiming() {
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let count = Int(rate * 0.04)
            let start = Int(rate * 0.001)
            let leftArrival = Int(rate * 0.012)
            let rightArrival = Int(rate * 0.0125)
            var left = [Double](repeating: 0, count: count)
            var right = left
            left[leftArrival] = 1
            right[rightArrival] = 0.6
            // Negligible captured noise should not keep the whole 40 ms buffer.
            left[count - 1] = 1e-10
            let response = DSPSystemHRTF.Response(left: left, right: right)
                .windowed(from: start, minimumLength: Int(rate * 0.006), sampleRate: rate)
            XCTAssertEqual(response.left.count, response.right.count)
            XCTAssertLessThan(response.left.count, count - start)
            XCTAssertEqual(response.left[leftArrival - start], 1)
            XCTAssertEqual(response.right[rightArrival - start], 0.6)
            XCTAssertEqual(response.left.indices.max { abs(response.left[$0]) < abs(response.left[$1]) },
                           leftArrival - start)
            XCTAssertEqual(response.right.indices.max { abs(response.right[$0]) < abs(response.right[$1]) },
                           rightArrival - start)
        }
    }

    func testSpatialBlendAlignsDirectSoundWithoutBoostingTheCentre() throws {
        let delay = 96
        var response = [Double](repeating: 0, count: 128)
        response[delay] = 1
        let spectra = try XCTUnwrap(DSPConvolutionSpectra(responses: [response, [0], [0], response]))
        let engine = try XCTUnwrap(DSPConvolutionEngine(spectra: spectra, routes: [
            .init(input: 0, output: 0, path: 0), .init(input: 0, output: 1, path: 1),
            .init(input: 1, output: 0, path: 2), .init(input: 1, output: 1, path: 3),
        ], inputCount: 2, outputCount: 2))
        var parameters = DSPSpatialAudioParameters()
        parameters.mix = 0.5
        parameters.loudnessMatchEnabled = false
        var kernel = DSPSpatialAudioKernel(format: stereoFormat, leftChannel: 0,
            rightChannel: 1, engine: engine, parameters: parameters, distance: 2, directDelayFrames: delay)
        XCTAssertEqual(kernel.latencyFrames, engine.latencyFrames + delay)
        let frames = 1_024
        let impulse = 128
        var samples = [Double](repeating: 0, count: frames * 2)
        samples[impulse * 2] = 0.25
        samples[impulse * 2 + 1] = 0.25
        samples.withUnsafeMutableBufferPointer { kernel.process($0.baseAddress!, frames: frames, channels: 2) }
        for frame in 0..<frames {
            let expected = frame == impulse + kernel.latencyFrames ? 0.25 : 0
            XCTAssertEqual(samples[frame * 2], expected, accuracy: 1e-10)
            XCTAssertEqual(samples[frame * 2 + 1], expected, accuracy: 1e-10)
        }
    }

    func testSpatialBlendPreservesTheOppositeEarsDelay() throws {
        let nearDelay = 80
        let farDelay = 104
        var near = [Double](repeating: 0, count: 128)
        var far = near
        near[nearDelay] = 1
        far[farDelay] = 0.5
        let spectra = try XCTUnwrap(DSPConvolutionSpectra(responses: [near, far, far, near]))
        let engine = try XCTUnwrap(DSPConvolutionEngine(spectra: spectra, routes: [
            .init(input: 0, output: 0, path: 0), .init(input: 0, output: 1, path: 1),
            .init(input: 1, output: 0, path: 2), .init(input: 1, output: 1, path: 3),
        ], inputCount: 2, outputCount: 2))
        var parameters = DSPSpatialAudioParameters()
        parameters.mix = 0.5
        parameters.loudnessMatchEnabled = false
        var kernel = DSPSpatialAudioKernel(format: stereoFormat, leftChannel: 0,
            rightChannel: 1, engine: engine, parameters: parameters, distance: 2, directDelayFrames: nearDelay)
        let frames = 1_024
        let impulse = 128
        var samples = [Double](repeating: 0, count: frames * 2)
        samples[impulse * 2] = 0.4
        samples.withUnsafeMutableBufferPointer { kernel.process($0.baseAddress!, frames: frames, channels: 2) }
        let leftPeak = (0..<frames).max { abs(samples[$0 * 2]) < abs(samples[$1 * 2]) }
        let rightPeak = (0..<frames).max { abs(samples[$0 * 2 + 1]) < abs(samples[$1 * 2 + 1]) }
        XCTAssertEqual(leftPeak, impulse + engine.latencyFrames + nearDelay)
        XCTAssertEqual(rightPeak, impulse + engine.latencyFrames + farDelay)
        XCTAssertEqual(samples[(impulse + engine.latencyFrames + farDelay) * 2 + 1], 0.1, accuracy: 1e-10)
    }

    func testDefaultSpatialSoundHasNoRoomTail() throws {
        let clean = try XCTUnwrap(DSPRoomSynthesis.responses(parameters: DSPSpatialAudioParameters(),
                                                            sampleRate: sampleRate))
        var parameters = DSPSpatialAudioParameters()
        parameters.room = .studio
        let room = try XCTUnwrap(DSPRoomSynthesis.responses(parameters: parameters, sampleRate: sampleRate))
        let start = Int(sampleRate * 0.08)
        func lateEnergy(_ paths: [[Double]]) -> Double {
            paths.reduce(0) { total, path in
                total + path.dropFirst(start).reduce(0) { $0 + $1 * $1 }
            }
        }
        XCTAssertTrue(clean.paths.allSatisfy { $0.allSatisfy(\.isFinite) })
        XCTAssertEqual(lateEnergy(clean.paths), 0, accuracy: 1e-12)
        XCTAssertGreaterThan(lateEnergy(room.paths), 1e-8)
        XCTAssertGreaterThan(clean.directDelayFrames, 0)
    }

    func testSpatialCentreStaysOnTheProcessorsSourceTimeline() throws {
        var parameters = DSPSpatialAudioParameters()
        parameters.loudnessMatchEnabled = false
        let responses = try XCTUnwrap(DSPRoomSynthesis.responses(parameters: parameters, sampleRate: sampleRate))
        let runtime = processor(nodes: [.effect(parameters)])
        XCTAssertEqual(runtime.processingLatencyFrames,
                       DSPConvolutionSpectra.headBlockSize + responses.directDelayFrames)
        let frames = 2_048
        let impulse = 512
        var samples = [Float](repeating: 0, count: frames * 2)
        samples[impulse * 2] = 0.25
        samples[impulse * 2 + 1] = 0.25
        let output = runtime.process(CanonicalPCM(frames: frames, channelCount: 2,
                                                 sampleRate: sampleRate, data: samples))
        let peak = (0..<frames).max { left, right in
            func power(_ frame: Int) -> Float {
                let l = output.data[frame * 2], r = output.data[frame * 2 + 1]
                return l * l + r * r
            }
            return power(left) < power(right)
        }
        XCTAssertEqual(peak, impulse)
    }

    /// The virtual speakers sit in a quiet room: a centred source reaches
    /// both ears alike and the late tail stays well under the early sound.
    func testSpatialRoomIsBalancedAndLight() throws {
        var parameters = DSPSpatialAudioParameters()
        parameters.room = .studio
        let responses = try XCTUnwrap(DSPRoomSynthesis.responses(parameters: parameters, sampleRate: sampleRate))
        let paths = responses.paths
        XCTAssertEqual(paths.count, 4)
        XCTAssertTrue(paths.allSatisfy { $0.allSatisfy(\.isFinite) })
        let split = Int(sampleRate * 0.04)
        func energy(_ path: [Double], _ range: Range<Int>) -> Double {
            range.clamped(to: 0..<path.count).reduce(0) { $0 + path[$1] * path[$1] }
        }
        let leftCentre = zip(paths[0], paths[2]).map(+)
        let rightCentre = zip(paths[1], paths[3]).map(+)
        let leftEnergy = energy(leftCentre, 0..<leftCentre.count)
        let rightEnergy = energy(rightCentre, 0..<rightCentre.count)
        XCTAssertEqual(10 * log10(leftEnergy / rightEnergy), 0, accuracy: 1)
        let early = paths.reduce(0) { $0 + energy($1, 0..<split) }
        let late = paths.reduce(0) { $0 + energy($1, split..<$1.count) }
        XCTAssertLessThan(10 * log10(late / early), -7)
    }

    /// One band and the master stage on a steady tone follow the designed
    /// static curve: nothing below the threshold, 1/ratio of the excess above.
    func testCompressorFollowsItsStaticCurve() {
        var parameters = DSPCompressorParameters(style: .custom)
        parameters.bands = [
            DSPCompressorBand(thresholdDB: 0, ratio: 1),
            DSPCompressorBand(thresholdDB: 0, ratio: 1),
            DSPCompressorBand(thresholdDB: 0, ratio: 1),
            DSPCompressorBand(thresholdDB: -20, ratio: 4),
        ]
        parameters.kneeDB = 0
        parameters.loudnessMatchEnabled = false
        for (inputDB, expectedDB, tolerance) in [(-30.0, -30.0, 0.2), (-10.0, -17.5, 0.5)] {
            let amplitude = pow(10, inputDB / 20)
            let frames = 48_000
            let input = CanonicalPCM(
                frames: frames, channelCount: 2, sampleRate: sampleRate,
                data: (0..<frames).flatMap { frame -> [Float] in
                    let value = Float(amplitude * sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
                    return [value, value]
                }
            )
            let output = processor(nodes: [.effect(parameters)]).process(input)
            let levelDB = 20 * log10(Self.magnitude(output.data.map(Double.init), channels: 2, frequency: 1_000,
                                                    sampleRate: sampleRate, frames: 28_800..<frames))
            XCTAssertEqual(levelDB, expectedDB, accuracy: tolerance, "input \(inputDB) dBFS")
        }
    }

    /// The partitioned FFT convolution equals direct convolution, delayed by
    /// its head block.
    func testPartitionedConvolutionMatchesDirectConvolution() throws {
        var noise = TestNoise(seed: 11)
        let response = (0..<5_000).map { index in noise.next() * exp(-Double(index) / 1_500) }
        let spectra = try XCTUnwrap(DSPConvolutionSpectra(responses: [response]))
        let engine = try XCTUnwrap(DSPConvolutionEngine(
            spectra: spectra, routes: [DSPConvolutionEngine.Route(input: 0, output: 0, path: 0)],
            inputCount: 1, outputCount: 1))
        let frames = 12_000
        let input = (0..<frames).map { _ in noise.next() }
        var output = [Double](repeating: 0, count: frames)
        for frame in 0..<frames {
            var value = input[frame]
            var result = 0.0
            engine.process(inputs: &value, outputs: &result)
            output[frame] = result
        }

        let latency = engine.latencyFrames
        var maximumError = 0.0
        var maximumValue = 0.0
        for frame in 0..<(frames - latency) {
            var expected = 0.0
            for tap in 0...min(frame, response.count - 1) {
                expected += response[tap] * input[frame - tap]
            }
            maximumError = max(maximumError, abs(output[frame + latency] - expected))
            maximumValue = max(maximumValue, abs(expected))
        }
        XCTAssertLessThan(20 * log10(maximumError / maximumValue), -120)
    }

    func testEveryReverbSpaceStaysFiniteAndDecays() throws {
        for space in DSPReverbSpace.allCases {
            let design = DSPReverbDesign(parameters: DSPReverbParameters(space: space))
            var kernel = try XCTUnwrap(DSPReverbKernel(sampleRate: sampleRate, leftChannel: 0, rightChannel: 1,
                                                       design: design, mix: 1))
            var noise = TestNoise(seed: 13)
            let burst = Int(sampleRate)
            let frames = burst + Int(sampleRate * 4)
            var samples = (0..<frames * 2).map { index in index < burst * 2 ? noise.next() * 0.25 : 0 }
            process(&kernel, &samples, channels: 2, blockSize: 512)
            XCTAssertTrue(samples.allSatisfy(\.isFinite), "\(space)")

            func energy(_ range: Range<Int>) -> Double {
                range.reduce(0) { $0 + samples[$1 * 2] * samples[$1 * 2] + samples[$1 * 2 + 1] * samples[$1 * 2 + 1] }
            }
            let window = Int(sampleRate / 4)
            let early = energy(burst..<(burst + window))
            let late = energy((frames - window)..<frames)
            XCTAssertGreaterThan(early, 0, "\(space)")
            XCTAssertLessThan(10 * log10(max(late, 1e-30) / early), -40, "\(space)")
        }
    }

    func testHybridBassHasZeroLatencyAndScalesItsHarmonics() {
        func harmonicDB(intensity: Double) -> Double {
            var parameters = DSPHybridBassParameters()
            parameters.target = .speakers
            parameters.intensity = intensity
            parameters.retainsRealBass = true
            parameters.cutoffHz = 80
            parameters.impact = 0.5
            let format = DSPAudioFormat(sampleRate: sampleRate, channelCount: 1, rawLayoutData: nil,
                                        channelLabels: [UInt32(kAudioChannelLabel_Mono)], layoutIsKnown: true)
            let runtime = AudioDSPProcessor(
                configuration: AudioDSPConfiguration(enabled: true, headroom: DSPHeadroomConfiguration(mode: .off),
                                                     nodes: [.effect(parameters)],
                                                     limiter: DSPLimiterConfiguration(enabled: false)),
                format: format)
            XCTAssertEqual(runtime.processingLatencyFrames, 0)
            let frames = Int(sampleRate * 3)
            let amplitude = pow(10, -20.0 / 20)
            let input = CanonicalPCM(frames: frames, channelCount: 1, sampleRate: sampleRate,
                                     data: (0..<frames).map { Float(amplitude * sin(2 * Double.pi * 50 * Double($0) / sampleRate)) })
            let output = runtime.process(input).data.map(Double.init)
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            let analysis = Int(sampleRate)..<frames
            let fundamental = Self.magnitude(output, channels: 1, frequency: 50, sampleRate: sampleRate, frames: analysis)
            let third = Self.magnitude(output, channels: 1, frequency: 150, sampleRate: sampleRate, frames: analysis)
            return 20 * log10(max(third, 1e-12) / fundamental)
        }
        XCTAssertGreaterThan(harmonicDB(intensity: 1) - harmonicDB(intensity: 0.1), 10)
    }

    func testBassEffectsPreserveMidrangeLevelWithAutomaticHeadroom() {
        let frames = Int(sampleRate * 2)
        let analysis = Int(sampleRate)..<frames
        let input = bassTestSignal(frames: frames) { time in
            0.02 * sin(2 * Double.pi * 40 * time) + 0.08 * sin(2 * Double.pi * 1_000 * time)
        }
        for cutoff in [50.0, 140.0] {
            for intensity in [0.5, 1.0] {
                for node in bassTestNodes(intensity: intensity, cutoff: cutoff, retainsRealBass: true) {
                    let runtime = bassTestProcessor(node, automaticHeadroom: true, limiterEnabled: true)
                    XCTAssertEqual(runtime.headroomDB, 0, accuracy: 1e-9)
                    let output = runtime.process(input).data.map(Double.init)
                    let mid = Self.magnitude(output, channels: 1, frequency: 1_000,
                                             sampleRate: sampleRate, frames: analysis)
                    XCTAssertEqual(20 * log10(mid / 0.08), 0, accuracy: 0.05,
                                   "enabling bass must preserve the rest of the music")
                }
            }
        }
    }

    func testRetainingRealBassPreservesFundamental() {
        let frames = Int(sampleRate * 2)
        let analysis = Int(sampleRate)..<frames
        let input = bassTestSignal(frames: frames) { 0.05 * sin(2 * Double.pi * 50 * $0) }
        for node in bassTestNodes(intensity: 0.5, cutoff: 80, retainsRealBass: true) {
            let runtime = bassTestProcessor(node)
            XCTAssertEqual(runtime.processingLatencyFrames, 0)
            let output = runtime.process(input).data.map(Double.init)
            let fundamental = Self.magnitude(output, channels: 1, frequency: 50,
                                            sampleRate: sampleRate, frames: analysis)
            XCTAssertEqual(20 * log10(fundamental / 0.05), 0, accuracy: 0.2)
        }
    }

    func testExpandedVirtualAmountRaisesHarmonicsWithoutIncreasingTheFundamental() {
        let frames = Int(sampleRate * 3)
        let analysis = Int(sampleRate)..<frames
        let input = bassTestSignal(frames: frames) { 0.05 * sin(2 * Double.pi * 40 * $0) }
        var harmonics = [[Double](), [Double]()]
        for intensity in [0.2, 0.5, 1.0] {
            for (index, node) in bassTestNodes(intensity: intensity, cutoff: 80, retainsRealBass: true).enumerated() {
                let output = bassTestProcessor(node).process(input).data.map(Double.init)
                let fundamental = Self.magnitude(output, channels: 1, frequency: 40,
                                                sampleRate: sampleRate, frames: analysis)
                let harmonic = Self.magnitude(output, channels: 1, frequency: 80,
                                             sampleRate: sampleRate, frames: analysis)
                XCTAssertEqual(20 * log10(fundamental / 0.05), 0, accuracy: 0.05)
                harmonics[index].append(harmonic)
            }
        }
        for levels in harmonics {
            XCTAssertGreaterThan(levels[0], 1e-5)
            XCTAssertGreaterThan(levels[1], levels[0])
            XCTAssertGreaterThan(levels[2], levels[1])
        }
    }

    func testAddedBassPeakControlReducesBroadbandLimiterAttenuation() {
        let frames = Int(sampleRate * 2)
        let analysis = Int(sampleRate)..<frames
        let input = bassTestSignal(frames: frames) { time in
            0.58 * sin(2 * Double.pi * 1_000 * time) + 0.28 * sin(2 * Double.pi * 40 * time)
        }
        for node in bassTestNodes(intensity: 1.0, cutoff: 80, retainsRealBass: true) {
            let runtime = bassTestProcessor(node, automaticHeadroom: true, limiterEnabled: true, ceilingDB: -1)
            let output = runtime.process(input).data.map(Double.init)
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            XCTAssertLessThanOrEqual(output.map { abs($0) }.max() ?? 0, pow(10, -1.0 / 20) + 1e-4)
            let mid = Self.magnitude(output, channels: 1, frequency: 1_000,
                                     sampleRate: sampleRate, frames: analysis)
            let bass = Self.magnitude(output, channels: 1, frequency: 40,
                                      sampleRate: sampleRate, frames: analysis)
            XCTAssertGreaterThan(20 * log10(mid / 0.58), -1.5)
            XCTAssertGreaterThan(20 * log10(bass / 0.28), -1.0)
        }
    }

    func testVirtualBassProducesConsecutiveAudibleHarmonicsWithTheShelfOff() {
        let frames = Int(sampleRate * 3)
        let analysis = Int(sampleRate)..<frames
        let cases: [(frequency: Double, cutoff: Double)] = [
            (40, 60), (50, 70), (60, 80), (80, 120), (100, 140)
        ]
        for test in cases {
            let input = bassTestSignal(frames: frames) { 0.1 * sin(2 * Double.pi * test.frequency * $0) }
            for node in bassTestNodes(intensity: 1.0, cutoff: test.cutoff, retainsRealBass: true) {
                let output = bassTestProcessor(node).process(input).data.map(Double.init)
                let fundamental = windowedBassMagnitude(output, frequency: test.frequency, frames: analysis)
                XCTAssertEqual(20 * log10(fundamental / 0.1), 0, accuracy: 0.15)
                var consecutive = 0, longest = 0
                for order in 2...10 where Double(order) * test.frequency <= 600 {
                    let frequency = Double(order) * test.frequency
                    let amplitude = windowedBassMagnitude(output, frequency: frequency, frames: analysis)
                    consecutive = frequency >= 60 && amplitude > 0.005 ? consecutive + 1 : 0
                    longest = max(longest, consecutive)
                }
                XCTAssertGreaterThanOrEqual(longest, 2,
                    "\(node.typeID) at \(test.frequency) Hz needs consecutive pitch cues")
            }
        }
    }

    func testZeroBassStrengthPreservesAutomaticSpeakerTuningExactly() {
        let input = bassTestSignal(frames: 8_192) { time in
            0.1 * sin(2 * Double.pi * 40 * time) + 0.1 * sin(2 * Double.pi * 400 * time)
        }
        for node in bassTestNodes(intensity: 0, cutoff: 140, retainsRealBass: true) {
            let runtime = bassTestProcessor(node, automaticHeadroom: true, limiterEnabled: false)
            XCTAssertEqual(runtime.headroomDB, 0, accuracy: 1e-9)
            XCTAssertEqual(runtime.processingLatencyFrames, 0)
            XCTAssertEqual(runtime.process(input).data, input.data)
        }
    }

    func testHybridBassFiltersFrequenciesAboveCutoff() {
        let frames = Int(sampleRate * 3)
        let outside = bassTestSignal(frames: frames) { 0.1 * sin(2 * Double.pi * 120 * $0) }
        let outsideOutput = hybridBassProcessor(intensity: 1.0, cutoff: 50).process(outside).data.map(Double.init)
        let harmonic = windowedBassMagnitude(outsideOutput, frequency: 240, frames: Int(sampleRate)..<frames)
        XCTAssertLessThan(harmonic, 0.01, "frequencies well above cutoff must not generate loud harmonics")
    }

    func testHybridImpactControlsHarmonicDrive() {
        let frames = Int(sampleRate * 2)
        let analysis = Int(sampleRate)..<frames
        let input = bassTestSignal(frames: frames) { 0.1 * sin(2 * Double.pi * 50 * $0) }
        let lowImpact = hybridBassProcessor(impact: 0.1, intensity: 0.5, cutoff: 80).process(input).data.map(Double.init)
        let highImpact = hybridBassProcessor(impact: 0.9, intensity: 0.5, cutoff: 80).process(input).data.map(Double.init)
        let lowHarmonic = windowedBassMagnitude(lowImpact, frequency: 150, frames: analysis)
        let highHarmonic = windowedBassMagnitude(highImpact, frequency: 150, frames: analysis)
        XCTAssertGreaterThan(highHarmonic, lowHarmonic)
    }

    func testHybridBassEnhancesExistingHarmonicsInEveryPhase() {
        let fundamental = 43.7
        let frames = Int(sampleRate * 3)
        let analysis = Int(sampleRate)..<frames
        for phase in [0.0, Double.pi / 2, Double.pi, 3 * Double.pi / 2] {
            let input = bassTestSignal(frames: frames) { time in
                0.1 * sin(2 * Double.pi * fundamental * time)
                    + 0.002 * sin(4 * Double.pi * fundamental * time + phase)
            }
            let output = hybridBassProcessor(intensity: 0.8, cutoff: 80).process(input)
            let before = Self.magnitude(input.data.map(Double.init), channels: 1, frequency: 2 * fundamental,
                                        sampleRate: sampleRate, frames: analysis)
            let after = Self.magnitude(output.data.map(Double.init), channels: 1, frequency: 2 * fundamental,
                                       sampleRate: sampleRate, frames: analysis)
            XCTAssertGreaterThan(after, before * 1.5, "phase \(phase): enhancement must not cancel the existing harmonic")
        }
    }

    func testHybridBassKeepsAdjacentBassNotesFromDetuningItsHarmonics() {
        let fundamental = 43.7
        let neighbour = 57.3
        let frames = Int(sampleRate * 3)
        let input = bassTestSignal(frames: frames) { time in
            0.1 * sin(2 * Double.pi * fundamental * time) + 0.055 * sin(2 * Double.pi * neighbour * time)
        }
        let output = hybridBassProcessor(intensity: 0.8, cutoff: 80).process(input)
        let wet = zip(output.data, input.data).map { Double($0.0) - Double($0.1) }
        let analysis = Int(sampleRate)..<frames
        let harmonic = windowedBassMagnitude(wet, frequency: 2 * fundamental, frames: analysis)
        XCTAssertGreaterThan(harmonic, 0.001, "the harmonic supplement remains present")
    }

    func testHybridBassPreservesChunkingAndReset() {
        let input = bassTestSignal(frames: Int(sampleRate * 2)) { time in
            let frequency = time < 1 ? 43.7 : 57.3
            return 0.1 * sin(2 * Double.pi * frequency * time)
        }
        let wholeRuntime = hybridBassProcessor(intensity: 0.5, cutoff: 80)
        let expected = wholeRuntime.process(input).data
        let runtime = hybridBassProcessor(intensity: 0.5, cutoff: 80)
        let sizes = [37, 1024, 997, 4_096]
        var chunked: [Float] = []
        var offset = 0
        var index = 0
        while offset < input.frames {
            let count = min(sizes[index % sizes.count], input.frames - offset)
            chunked.append(contentsOf: runtime.process(input.slice(frameOffset: offset, frameCount: count)).data)
            offset += count
            index += 1
        }
        XCTAssertEqual(chunked, expected)
        runtime.reset()
        XCTAssertEqual(runtime.process(input).data, expected)
    }

    func testBassEffectsDecayAfterAShortBassBurst() {
        let frames = Int(sampleRate * 2)
        let input = bassTestSignal(frames: frames) { time in
            guard time >= 0.1, time < 0.3 else { return 0 }
            let window = pow(sin(Double.pi * (time - 0.1) / 0.2), 2)
            return 0.3 * window * sin(2 * Double.pi * 43.7 * time)
        }
        var classic = DSPClassicBassParameters()
        classic.target = .headphones
        classic.intensity = 0.5
        classic.cutoffHz = 80
        classic.retainsRealBass = true
        var expandedClassic = classic
        expandedClassic.intensity = 1.0

        let expandedHybrid: [AudioDSPProcessor] = [50.0, 140.0].map { cutoff in
            var parameters = DSPHybridBassParameters()
            parameters.target = .headphones
            parameters.intensity = 1.0
            parameters.cutoffHz = cutoff
            parameters.retainsRealBass = true
            return bassTestProcessor(.effect(parameters), limiterEnabled: true)
        }
        for runtime in [bassTestProcessor(.effect(classic)),
                        hybridBassProcessor(intensity: 0.5, cutoff: 50),
                        hybridBassProcessor(intensity: 0.5, cutoff: 140),
                        bassTestProcessor(.effect(expandedClassic), limiterEnabled: true)] + expandedHybrid {
            let output = runtime.process(input).data.map(Double.init)
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            XCTAssertLessThan(output.map { abs($0) }.max() ?? 0, 0.9)
            let active = Int(sampleRate * 0.1)..<Int(sampleRate * 0.6)
            let tail = Int(sampleRate * 0.65)..<Int(sampleRate * 1.15)
            let activePower = active.reduce(0.0) { $0 + output[$1] * output[$1] } / Double(active.count)
            let tailPower = tail.reduce(0.0) { $0 + output[$1] * output[$1] } / Double(tail.count)
            XCTAssertGreaterThan(activePower, 1e-4)
            XCTAssertLessThan(tailPower, activePower * 1e-4, "the burst must not leave bass noise in silence")
        }
    }

    private func bassTestSignal(frames: Int, sample: (Double) -> Double) -> CanonicalPCM {
        CanonicalPCM(frames: frames, channelCount: 1, sampleRate: sampleRate,
                     data: (0..<frames).map { Float(sample(Double($0) / sampleRate)) })
    }

    private func hybridBassProcessor(impact: Double = 0.5, intensity: Double = 0.5,
                                     cutoff: Double = 80, retainsRealBass: Bool = true) -> AudioDSPProcessor {
        var parameters = DSPHybridBassParameters()
        parameters.target = .headphones
        parameters.cutoffHz = cutoff
        parameters.intensity = intensity
        parameters.impact = impact
        parameters.retainsRealBass = retainsRealBass
        return bassTestProcessor(.effect(parameters))
    }

    private func bassTestNodes(intensity: Double, cutoff: Double, retainsRealBass: Bool = true) -> [DSPNodeConfiguration] {
        var classic = DSPClassicBassParameters()
        classic.target = .speakers
        classic.intensity = intensity
        classic.cutoffHz = cutoff
        classic.retainsRealBass = retainsRealBass
        var hybrid = DSPHybridBassParameters()
        hybrid.target = .speakers
        hybrid.intensity = intensity
        hybrid.cutoffHz = cutoff
        hybrid.retainsRealBass = retainsRealBass
        return [.effect(classic), .effect(hybrid)]
    }

    private func bassTestProcessor(_ node: DSPNodeConfiguration, automaticHeadroom: Bool = false,
                                   limiterEnabled: Bool = false, ceilingDB: Double = 0) -> AudioDSPProcessor {
        AudioDSPProcessor(
            configuration: AudioDSPConfiguration(enabled: true,
                                                 headroom: DSPHeadroomConfiguration(mode: automaticHeadroom ? .automatic : .off),
                                                 nodes: [node], limiter: DSPLimiterConfiguration(enabled: limiterEnabled, ceilingDB: ceilingDB)),
            format: DSPAudioFormat(sampleRate: sampleRate, channelCount: 1, rawLayoutData: nil,
                                   channelLabels: [UInt32(kAudioChannelLabel_Mono)], layoutIsKnown: true)
        )
    }

    /// Hann analysis separates a generated partial from leakage of the much
    /// louder, non-integer-cycle dry bass notes beside it.
    private func windowedBassMagnitude(_ values: [Double], frequency: Double, frames: Range<Int>) -> Double {
        var real = 0.0, imaginary = 0.0, weight = 0.0
        for (index, frame) in frames.enumerated() {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(frames.count))
            let angle = 2 * Double.pi * frequency * Double(frame) / sampleRate
            real += values[frame] * window * cos(angle)
            imaginary -= values[frame] * window * sin(angle)
            weight += window
        }
        return 2 * hypot(real, imaginary) / weight
    }

    // MARK: Helpers

    private struct TestNoise {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(Int64(bitPattern: (state >> 11) << 11)) / Double(Int64.max)
        }
    }

    private func process<K: DSPBlockKernel>(_ kernel: inout K, _ samples: inout [Double], channels: Int, blockSize: Int) {
        let frames = samples.count / channels
        samples.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            while offset < frames {
                let count = min(blockSize, frames - offset)
                kernel.process(buffer.baseAddress! + offset * channels, frames: count, channels: channels)
                offset += count
            }
        }
    }

    private func crossfeedResponse(_ parameters: DSPCrossfeedParameters,
                                   frequency: Double) throws -> (oppositeDB: Double, centredDB: Double) {
        let frames = Int(sampleRate)
        let analysis = (frames / 2)..<frames
        func run(left: Double, right: Double) throws -> [Double] {
            var kernel = try XCTUnwrap(DSPCrossfeedKernel(leftChannel: 0, rightChannel: 1,
                                                          sampleRate: sampleRate, parameters: parameters))
            var samples = (0..<frames).flatMap { frame -> [Double] in
                let value = 0.5 * sin(2 * Double.pi * frequency * Double(frame) / sampleRate)
                return [value * left, value * right]
            }
            process(&kernel, &samples, channels: 2, blockSize: 1_024)
            return samples
        }
        let oneSided = try run(left: 1, right: 0)
        let near = Self.magnitude(oneSided, channels: 2, frequency: frequency, sampleRate: sampleRate, frames: analysis)
        let rightChannel = stride(from: 1, to: oneSided.count, by: 2).map { oneSided[$0] }
        let far = Self.magnitude(rightChannel, channels: 1, frequency: frequency,
                                 sampleRate: sampleRate, frames: analysis)
        let centred = try run(left: 1, right: 1)
        let level = Self.magnitude(centred, channels: 2, frequency: frequency, sampleRate: sampleRate, frames: analysis)
        return (20 * log10(far / near), 20 * log10(level / 0.5))
    }

    private func processor(nodes: [DSPNodeConfiguration]) -> AudioDSPProcessor {
        AudioDSPProcessor(
            configuration: AudioDSPConfiguration(enabled: true, headroom: DSPHeadroomConfiguration(mode: .off),
                                                 nodes: nodes, limiter: DSPLimiterConfiguration(enabled: false)),
            format: stereoFormat
        )
    }

    private var stereoFormat: DSPAudioFormat {
        DSPAudioFormat(sampleRate: sampleRate, channelCount: 2, rawLayoutData: nil,
                       channelLabels: [UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)],
                       layoutIsKnown: true)
    }

    /// Amplitude of `frequency` in channel 0 of interleaved samples.
    private static func magnitude(_ values: [Double], channels: Int, frequency: Double,
                                  sampleRate: Double, frames: Range<Int>) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for frame in frames {
            let value = values[frame * channels]
            let angle = 2 * Double.pi * frequency * Double(frame) / sampleRate
            real += value * cos(angle)
            imaginary -= value * sin(angle)
        }
        return 2 * hypot(real, imaginary) / Double(frames.count)
    }
}
