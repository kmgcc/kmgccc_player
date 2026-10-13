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
        let widthNode = DSPNodeConfiguration.stereoWidth(
            parameters: DSPStereoWidthParameters(width: 0)
        )
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
        dryBass.tightenDryBass = .off
        let bassOff = DSPNodeConfiguration.classicBass(parameters: dryBass)
        let tubeMixOff = DSPNodeConfiguration.tube(parameters: DSPTubeParameters(mix: 0, inputTrimDB: 12))
        let hifiOff = DSPNodeConfiguration.tube(parameters: DSPTubeParameters(mode: .hifi, hifiAmount: 0))
        let identityWidth = DSPNodeConfiguration.stereoWidth(parameters: DSPStereoWidthParameters(width: 1))
        var dryReverb = DSPReverbParameters()
        dryReverb.mix = 0
        let reverbOff = DSPNodeConfiguration.effect(dryReverb)
        let input = CanonicalPCM(
            frames: 5,
            channelCount: 2,
            sampleRate: 48_000,
            data: [0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 1, -1, -0.125, 0.125]
        )

        for node in [bassOff, tubeMixOff, hifiOff, identityWidth, reverbOff] {
            let runtime = processor(nodes: [node], format: stereoFormat(sampleRate: 48_000))
            XCTAssertTrue(runtime.isBypassed, node.typeID)
            XCTAssertEqual(runtime.processingLatencyFrames, 0)
            XCTAssertEqual(runtime.peakGuarantee, "bypassed")
            XCTAssertEqual(runtime.process(input).data, input.data)
        }

        // A dry effect still honours its output trim, as a plain gain.
        dryBass.outputTrimDB = -6
        let trimmed = processor(nodes: [.classicBass(parameters: dryBass)], format: stereoFormat(sampleRate: 48_000))
        XCTAssertEqual(trimmed.processingLatencyFrames, 0)
        let gain = Float(pow(10, -6.0 / 20))
        for (output, sample) in zip(trimmed.process(input).data, input.data) {
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
        let directDrive: Double = pow(10.0, 18.0 / 20.0)
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

    /// Raising the chain input gain changes the level, never how hard the
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
        func measure(inputTrimDB: Double) -> (fundamentalDB: Double, secondDB: Double, thirdDB: Double) {
            let runtime = AudioDSPProcessor(
                configuration: AudioDSPConfiguration(
                    enabled: true,
                    inputTrimDB: inputTrimDB,
                    headroom: DSPHeadroomConfiguration(mode: .off),
                    nodes: [.tube(parameters: DSPTubeParameters(mix: 1))],
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

        let reference = measure(inputTrimDB: 0)
        XCTAssertGreaterThan(reference.secondDB, -60, "the default tube is audible")
        for trim in [6.0, 12.0] {
            let raised = measure(inputTrimDB: trim)
            XCTAssertEqual(raised.fundamentalDB - reference.fundamentalDB, trim, accuracy: 0.1)
            XCTAssertEqual(raised.secondDB, reference.secondDB, accuracy: 0.1)
            XCTAssertEqual(raised.thirdDB, reference.thirdDB, accuracy: 0.1)
        }
    }

    /// Envelope normalization makes every harmonic track the bass level, so
    /// harmonic-to-fundamental ratios stay put from quiet to loud.
    func testClassicBassHarmonicRatiosAreIndependentOfLevel() {
        let reference = classicBassHarmonics(levelDB: -20, character: .round)
        XCTAssertGreaterThan(reference.thirdDB, -50, "the default bass is audible")
        for level in [-40.0, -6.0] {
            let measured = classicBassHarmonics(levelDB: level, character: .round)
            XCTAssertEqual(measured.secondDB, reference.secondDB, accuracy: 1, "level \(level)")
            XCTAssertEqual(measured.thirdDB, reference.thirdDB, accuracy: 1, "level \(level)")
        }
    }

    func testClassicBassTightCharacterLeansOnHigherHarmonics() {
        let round = classicBassHarmonics(levelDB: -20, character: .round)
        let tight = classicBassHarmonics(levelDB: -20, character: .tight)
        XCTAssertGreaterThan(tight.thirdDB - tight.secondDB, round.thirdDB - round.secondDB + 3)
    }

    /// Second and third harmonic of a 50 Hz tone relative to the fundamental.
    private func classicBassHarmonics(levelDB: Double, character: DSPBassCharacter) -> (secondDB: Double, thirdDB: Double) {
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
        let node = DSPNodeConfiguration.classicBass(
            parameters: bassParameters(intensity: 0.7, character: character, tighten: .off)
        )
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
        character: DSPBassCharacter = .round,
        tighten: DSPSwitchSetting = .automatic
    ) -> DSPClassicBassParameters {
        var parameters = DSPClassicBassParameters()
        parameters.target = .speakers
        parameters.intensity = intensity
        parameters.character = character
        parameters.tightenDryBass = tighten
        return parameters
    }

    private func bassNode(intensity: Double, character: DSPBassCharacter = .round) -> DSPNodeConfiguration {
        .classicBass(parameters: bassParameters(intensity: intensity, character: character))
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

    /// The virtual speakers sit in a quiet room: a centred source reaches
    /// both ears alike and the late tail stays well under the early sound.
    func testSpatialRoomIsBalancedAndLight() throws {
        let responses = try XCTUnwrap(DSPRoomSynthesis.responses(parameters: DSPSpatialAudioParameters(),
                                                                 sampleRate: sampleRate))
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

    func testHybridBassDeclaresItsLatencyAndScalesItsHarmonics() {
        let latency = DSPHybridBassEngine.latencyFrames(sampleRate: sampleRate)
        XCTAssertGreaterThan(latency, Int(0.15 * sampleRate))
        XCTAssertLessThan(latency, Int(0.3 * sampleRate))

        func harmonicDB(intensity: Double) -> Double {
            var parameters = DSPHybridBassParameters()
            parameters.target = .speakers
            parameters.intensity = intensity
            parameters.tightenDryBass = .off
            let format = DSPAudioFormat(sampleRate: sampleRate, channelCount: 1, rawLayoutData: nil,
                                        channelLabels: [UInt32(kAudioChannelLabel_Mono)], layoutIsKnown: true)
            let runtime = AudioDSPProcessor(
                configuration: AudioDSPConfiguration(enabled: true, headroom: DSPHeadroomConfiguration(mode: .off),
                                                     nodes: [.effect(parameters)],
                                                     limiter: DSPLimiterConfiguration(enabled: false)),
                format: format)
            XCTAssertEqual(runtime.processingLatencyFrames, latency)
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
        XCTAssertGreaterThan(harmonicDB(intensity: 1) - harmonicDB(intensity: 0.05), 15)
    }

    // MARK: Helpers

    private struct TestNoise {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(Int64(bitPattern: state >> 11 << 11)) / Double(Int64.max)
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
            format: DSPAudioFormat(sampleRate: sampleRate, channelCount: 2, rawLayoutData: nil,
                                   channelLabels: [UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)],
                                   layoutIsKnown: true)
        )
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
