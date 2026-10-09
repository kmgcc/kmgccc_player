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
        let bassMixOff = DSPNodeConfiguration.virtualBass(
            parameters: DSPVirtualBassParameters(amount: 0.8, mix: 0, outputTrimDB: 6)
        )
        let bassAmountOff = DSPNodeConfiguration.virtualBass(
            parameters: DSPVirtualBassParameters(amount: 0, mix: 1, outputTrimDB: -6)
        )
        let tubeMixOff = DSPNodeConfiguration.tube(
            parameters: DSPTubeParameters(mix: 0, inputTrimDB: 12, outputTrimDB: 6)
        )
        let identityWidth = DSPNodeConfiguration.stereoWidth()
        let input = CanonicalPCM(
            frames: 5,
            channelCount: 2,
            sampleRate: 48_000,
            data: [0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 1, -1, -0.125, 0.125]
        )

        for node in [bassMixOff, bassAmountOff, tubeMixOff, identityWidth] {
            let runtime = processor(nodes: [node], format: stereoFormat(sampleRate: 48_000))
            XCTAssertTrue(runtime.isBypassed)
            XCTAssertEqual(runtime.processingLatencyFrames, 0)
            XCTAssertEqual(runtime.peakGuarantee, "bypassed")
            XCTAssertEqual(runtime.process(input).data, input.data)
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

    func testFrontPairVirtualBassLeavesOtherChannelsAsExactDelayedDry() {
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
        let node = DSPNodeConfiguration.virtualBass(
            parameters: DSPVirtualBassParameters(amount: 0.7, mix: 0.8),
            channelPolicy: "frontPair",
            quality: "oversampling2x"
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

        XCTAssertEqual(runtime.processingLatencyFrames, 64)
        for frame in 0..<input.frames {
            XCTAssertEqual(output.data[frame * 4 + 2], inputData[frame * 4 + 2])
            XCTAssertEqual(output.data[frame * 4 + 3], inputData[frame * 4 + 3])
        }
    }

    func testChunkedProcessingMatchesWholeBufferWithRealLookaheadAndShortBlocks() {
        let nodes = [
            tubeNode(quality: "oversampling2x", bias: 0.2, removeDC: true),
            bassNode(quality: "oversampling4x", amount: 0.7, mix: 0.65),
        ]
        let format = stereoFormat(sampleRate: 48_000)
        let source = deterministicInput(frames: 1_537, sampleRate: 48_000)
        let whole = processor(nodes: nodes, format: format).process(source).data

        let chunkedProcessor = processor(nodes: nodes, format: format)
        XCTAssertEqual(chunkedProcessor.processingLatencyFrames, 128)
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
            bassNode(quality: "oversampling4x", amount: 0.6, mix: 0.8),
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

    func testVirtualBassSelectsEvenOrOddHarmonicContent() {
        let sampleRate = 48_000.0
        let frames = 12_000
        let monoFormat = DSPAudioFormat(
            sampleRate: sampleRate,
            channelCount: 1,
            rawLayoutData: nil,
            channelLabels: [UInt32(kAudioChannelLabel_Mono)],
            layoutIsKnown: true
        )
        let monoInput = CanonicalPCM(
            frames: frames,
            channelCount: 1,
            sampleRate: sampleRate,
            data: (0..<frames).map { frame in
                Float(0.7 * sin(2 * Double.pi * 80 * Double(frame) / sampleRate))
            }
        )
        let even = processor(
            nodes: [bassNode(quality: "oversampling4x", amount: 0.8, mix: 1, harmonics: 0)],
            format: monoFormat
        ).process(monoInput)
        let odd = processor(
            nodes: [bassNode(quality: "oversampling4x", amount: 0.8, mix: 1, harmonics: 1)],
            format: monoFormat
        ).process(monoInput)
        let analysisFrames = 1_000..<(frames - 1_000)
        let evenSecond = magnitude(
            even.data,
            channelCount: 1,
            channel: 0,
            sampleRate: sampleRate,
            frequency: 160,
            frameRange: analysisFrames
        )
        let oddSecond = magnitude(
            odd.data,
            channelCount: 1,
            channel: 0,
            sampleRate: sampleRate,
            frequency: 160,
            frameRange: analysisFrames
        )
        let evenThird = magnitude(
            even.data,
            channelCount: 1,
            channel: 0,
            sampleRate: sampleRate,
            frequency: 240,
            frameRange: analysisFrames
        )
        let oddThird = magnitude(
            odd.data,
            channelCount: 1,
            channel: 0,
            sampleRate: sampleRate,
            frequency: 240,
            frameRange: analysisFrames
        )

        XCTAssertGreaterThan(evenSecond, oddSecond * 2)
        XCTAssertGreaterThan(oddThird, evenThird * 2)
    }

    func testMixedNodeOrderIsFiniteAndDeterministicAtCommonAndHighSampleRates() {
        for sampleRate in [48_000.0, 96_000.0, 192_000.0] {
            let format = stereoFormat(sampleRate: sampleRate)
            let nodes = [
                tubeNode(quality: "oversampling4x", bias: 0.15, removeDC: true),
                DSPNodeConfiguration.stereoWidth(
                    parameters: DSPStereoWidthParameters(width: 1.4, outputTrimDB: -1)
                ),
                bassNode(quality: "oversampling2x", amount: 0.8, mix: 0.6),
            ]
            let input = deterministicInput(frames: 512, sampleRate: sampleRate)
            let firstProcessor = processor(nodes: nodes, format: format)
            let secondProcessor = processor(nodes: nodes, format: format)
            let first = firstProcessor.process(input)
            let second = secondProcessor.process(input)

            XCTAssertEqual(firstProcessor.processingLatencyFrames, 128)
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
                nodes: nodes
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

    private func bassNode(
        quality: String,
        amount: Double,
        mix: Double,
        harmonics: Double = 0.5
    ) -> DSPNodeConfiguration {
        .virtualBass(
            parameters: DSPVirtualBassParameters(
                lowFrequencyHz: 40,
                highFrequencyHz: 120,
                amount: amount,
                driveDB: 12,
                harmonics: harmonics,
                mix: mix,
                outputTrimDB: 0
            ),
            channelPolicy: "fullRange",
            quality: quality
        )
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
