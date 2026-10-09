import AVFoundation
import AudioToolbox
import XCTest
@testable import kmgccc_player

final class AudioLoudnessTests: XCTestCase {
    func testAACDecodedCropAvoidsDoubleTrimming() {
        let metadata = AACGaplessInfo(isAAC: true, formatID: kAudioFormatMPEG4AAC,
            primingFrames: 2_112, paddingFrames: 512, validFrames: 48_000, source: "packetTable")
        let full = AACDecodedFrameRange.resolve(metadata: metadata, decodedFrames: 50_624, enabled: true)
        XCTAssertEqual(full.startingFrame, 2_112)
        XCTAssertEqual(full.frameCount, 48_000)
        let paddingOnly = AACDecodedFrameRange.resolve(metadata: metadata, decodedFrames: 48_512, enabled: true)
        XCTAssertEqual(paddingOnly.startingFrame, 0)
        XCTAssertEqual(paddingOnly.frameCount, 48_000)
        XCTAssertFalse(AACDecodedFrameRange.resolve(metadata: metadata, decodedFrames: 48_000, enabled: true).isTrimmed)
        XCTAssertFalse(AACDecodedFrameRange.resolve(metadata: metadata, decodedFrames: 50_624, enabled: false).isTrimmed)
        XCTAssertEqual(AACDecodedFrameRange.resolve(metadata: metadata, decodedFrames: 80_000, enabled: true).reason, "inconsistentMetadata")
    }

    func testStreamingMeasurementReportsLoudnessAndAllSamplePeaks() {
        let measurement = analyzeMonoSine(
            frequency: 997,
            amplitude: 0.1,
            duration: 2,
            label: UInt32(kAudioChannelLabel_Mono)
        )

        XCTAssertEqual(measurement.status, .available)
        XCTAssertNotNil(measurement.integratedLUFS)
        XCTAssertEqual(measurement.samplePeakDBFS ?? .infinity, -20, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(measurement.truePeakDBTP ?? -.infinity, measurement.samplePeakDBFS ?? .infinity)
        XCTAssertEqual(measurement.analysisFrameRange, "provided-decoded-frames-v2")
        XCTAssertTrue(measurement.diagnostics.contains { $0.code == "audio.loudnessTruePeakFixturePending" })
    }

    func testShortAndSilentInputsDoNotProduceArtificialLoudness() {
        let short = analyzeMonoSine(
            frequency: 997,
            amplitude: 0.5,
            duration: 0.2,
            label: UInt32(kAudioChannelLabel_Mono)
        )
        XCTAssertEqual(short.status, .tooShort)
        XCTAssertNil(short.integratedLUFS)

        let silence = analyzeMonoSine(
            frequency: 997,
            amplitude: 0,
            duration: 1,
            label: UInt32(kAudioChannelLabel_Mono)
        )
        XCTAssertEqual(silence.status, .silence)
        XCTAssertNil(silence.integratedLUFS)
        XCTAssertNil(silence.samplePeakDBFS)
    }

    func testUnknownAndHeightLayoutsRemainUnavailableButKeepPeakMeasurement() {
        let unknown = analyzeMonoSine(
            frequency: 997,
            amplitude: 0.25,
            duration: 1,
            label: UInt32(kAudioChannelLabel_Unknown),
            layoutIsKnown: false
        )
        XCTAssertEqual(unknown.status, .unsupportedLayout)
        XCTAssertNil(unknown.integratedLUFS)
        XCTAssertNotNil(unknown.samplePeakDBFS)

        let height = analyzeMonoSine(
            frequency: 997,
            amplitude: 0.25,
            duration: 1,
            label: UInt32(kAudioChannelLabel_TopBackLeft)
        )
        XCTAssertEqual(height.status, .unsupportedLayout)
        XCTAssertNil(height.integratedLUFS)
    }

    func testLFEIsExcludedFromIntegratedLoudnessButStillConstrainsPeak() {
        let lfeOnly = analyzeMonoSine(
            frequency: 80,
            amplitude: 0.8,
            duration: 1,
            label: UInt32(kAudioChannelLabel_LFEScreen)
        )

        XCTAssertEqual(lfeOnly.status, .silence)
        XCTAssertNil(lfeOnly.integratedLUFS)
        XCTAssertEqual(lfeOnly.samplePeakDBFS ?? -.infinity, 20 * log10(0.8), accuracy: 0.02)
        XCTAssertNotNil(lfeOnly.truePeakDBTP)
    }

    func testRearSurroundUsesSurroundWeightAndWideUsesFrontWeight() {
        let front = analyzeMonoSine(
            frequency: 997,
            amplitude: 0.1,
            duration: 2,
            label: UInt32(kAudioChannelLabel_Left)
        )
        let rear = analyzeMonoSine(
            frequency: 997,
            amplitude: 0.1,
            duration: 2,
            label: UInt32(kAudioChannelLabel_RearSurroundLeft)
        )
        let wide = analyzeMonoSine(
            frequency: 997,
            amplitude: 0.1,
            duration: 2,
            label: UInt32(kAudioChannelLabel_LeftWide)
        )

        XCTAssertEqual((rear.integratedLUFS ?? 0) - (front.integratedLUFS ?? 0), 10 * log10(1.41), accuracy: 0.12)
        XCTAssertEqual(wide.integratedLUFS ?? 0, front.integratedLUFS ?? .infinity, accuracy: 0.01)
    }

    func testHistogramGatingAndAlbumAggregationUseLinearEnergy() throws {
        var quiet = LoudnessEnergyHistogram()
        var loud = LoudnessEnergyHistogram()
        let quietEnergy = 10.0.pow((-40 + 0.691) / 10)
        let loudEnergy = 10.0.pow((-20 + 0.691) / 10)
        for _ in 0..<20 {
            XCTAssertTrue(quiet.add(linearEnergy: quietEnergy))
            XCTAssertTrue(loud.add(linearEnergy: loudEnergy))
        }
        let quietLUFS = try XCTUnwrap(LoudnessAnalyzer.integratedLUFS(from: quiet))
        let loudLUFS = try XCTUnwrap(LoudnessAnalyzer.integratedLUFS(from: loud))

        let decision = LoudnessGainSelector.albumGain(
            configuration: AudioLoudnessConfiguration(
                enabled: true,
                mode: "album",
                targetLUFS: -18,
                maxBoostDB: 12,
                maxAttenuationDB: 24,
                truePeakCeilingDBTP: 20
            ),
            measurements: [
                measurement(lufs: quietLUFS, histogram: quiet, truePeak: -8),
                measurement(lufs: loudLUFS, histogram: loud, truePeak: -3),
            ]
        )
        var combined = quiet
        XCTAssertTrue(combined.merge(loud))
        let pooledLUFS = try XCTUnwrap(LoudnessAnalyzer.integratedLUFS(from: combined))

        XCTAssertEqual(decision.source, "measured.album")
        XCTAssertEqual(decision.gainDB, -18 - pooledLUFS, accuracy: 0.02)
        XCTAssertGreaterThan(abs(pooledLUFS - (quietLUFS + loudLUFS) / 2), 5)
    }

    func testPeakCeilingTakesPriorityOverRequestedBoost() {
        let histogram = oneEnergyHistogram(lufs: -40)
        let decision = LoudnessGainSelector.trackGain(
            configuration: AudioLoudnessConfiguration(
                enabled: true,
                targetLUFS: -18,
                maxBoostDB: 12,
                maxAttenuationDB: 24,
                truePeakCeilingDBTP: -1
            ),
            measurement: measurement(lufs: -40, histogram: histogram, truePeak: 5)
        )

        XCTAssertEqual(decision.gainDB, -6, accuracy: 0.001)
        XCTAssertEqual(decision.peakBasis, "truePeak")
        XCTAssertTrue(decision.diagnostics.contains { $0.code == "audio.loudnessPeakLimited" })
    }

    func testLegacyReplayGainAndUnknownOpusR128AreRetainedButNotApplied() {
        let replayGain = LoudnessMetadataParser.parse(
            tags: [
                LoudnessMetadataTag(key: "REPLAYGAIN_TRACK_GAIN", value: "+6.00 dB"),
                LoudnessMetadataTag(key: "REPLAYGAIN_REFERENCE_LOUDNESS", value: "89 dB"),
            ],
            containerHint: "flac"
        )
        XCTAssertEqual(replayGain.replayGainTrackDB, 6)
        XCTAssertEqual(replayGain.replayGainReferenceDB, 89)
        XCTAssertFalse(replayGain.replayGainIsReliable)
        XCTAssertNil(replayGain.replayGainReferenceLUFS)
        XCTAssertTrue(replayGain.diagnostics.contains { $0.code == "audio.loudnessReplayGainConversionUnverified" })

        let replayGainDecision = LoudnessGainSelector.trackGain(
            configuration: AudioLoudnessConfiguration(enabled: true),
            measurement: nil,
            metadata: replayGain
        )
        XCTAssertEqual(replayGainDecision.gainDB, 0)

        let opus = LoudnessMetadataParser.parse(
            tags: [
                LoudnessMetadataTag(key: "org.xiph.vorbis-comment/R128_TRACK_GAIN", value: "-256"),
                LoudnessMetadataTag(key: "OPUSHEAD_OUTPUT_GAIN_Q78", value: "256"),
            ],
            containerHint: "opus"
        )
        XCTAssertEqual(opus.r128TrackGainDB, -1)
        XCTAssertEqual(opus.opusOutputGainDB, 1)
        XCTAssertFalse(opus.r128IsReliable)
        XCTAssertTrue(opus.diagnostics.contains { $0.code == "audio.loudnessOpusGainBaselineUnknown" })
    }

    func testVerifiedFLACR128Q78ConvertsFromMinus23LUFS() {
        let metadata = LoudnessMetadataParser.parse(
            tags: [LoudnessMetadataTag(key: "R128_TRACK_GAIN", value: "-256")],
            containerHint: "flac"
        )
        let decision = LoudnessGainSelector.trackGain(
            configuration: AudioLoudnessConfiguration(
                enabled: true,
                targetLUFS: -23,
                maxBoostDB: 12,
                maxAttenuationDB: 24,
                truePeakCeilingDBTP: 12
            ),
            measurement: nil,
            metadata: metadata
        )

        XCTAssertTrue(metadata.r128IsReliable)
        XCTAssertEqual(decision.gainDB, -1, accuracy: 0.001)
        XCTAssertEqual(decision.source, "metadata.r128")
    }

    private func analyzeMonoSine(
        frequency: Double,
        amplitude: Float,
        duration: Double,
        label: UInt32,
        layoutIsKnown: Bool = true,
        phase: Double = 0
    ) -> LoudnessMeasurement {
        let sampleRate = 48_000.0
        let channelFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let analysisFormat = DSPAudioFormat(
            sampleRate: sampleRate,
            channelCount: 1,
            rawLayoutData: nil,
            channelLabels: [label],
            layoutIsKnown: layoutIsKnown
        )
        let analyzer = LoudnessAnalyzer(format: analysisFormat)
        let buffer = AVAudioPCMBuffer(pcmFormat: channelFormat, frameCapacity: 4_096)!
        let channelData = buffer.floatChannelData!
        let totalFrames = Int(sampleRate * duration)
        var offset = 0
        while offset < totalFrames {
            let count = min(Int(buffer.frameCapacity), totalFrames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                let time = Double(offset + frame) / sampleRate
                channelData[0][frame] = amplitude * Float(sin(2 * Double.pi * frequency * time + phase))
            }
            analyzer.append(channelData: UnsafePointer(channelData), frameCount: count)
            offset += count
        }
        return analyzer.finish()
    }

    private func measurement(
        lufs: Double,
        histogram: LoudnessEnergyHistogram,
        truePeak: Double
    ) -> LoudnessMeasurement {
        LoudnessMeasurement(
            status: .available,
            format: DSPAudioFormat(
                sampleRate: 48_000,
                channelCount: 1,
                rawLayoutData: nil,
                channelLabels: [UInt32(kAudioChannelLabel_Mono)],
                layoutIsKnown: true
            ),
            validStartFrame: 0,
            validEndFrame: 48_000,
            analyzerVersion: LoudnessMeasurement.currentAnalyzerVersion,
            decoderRuleVersion: LoudnessMeasurement.currentDecoderRuleVersion,
            trimPolicyVersion: LoudnessMeasurement.currentTrimPolicyVersion,
            analysisFrameRange: "provided-decoded-frames-v2",
            playbackAACGaplessTrimEnabled: false,
            integratedLUFS: lufs,
            samplePeakDBFS: truePeak,
            truePeakDBTP: truePeak,
            gatedBlockEnergyHistogram: histogram,
            gatedBlockCount: histogram.blockCount,
            blockFrames: 19_200,
            blockStepFrames: 4_800,
            confidence: 0.6,
            diagnostics: []
        )
    }

    private func oneEnergyHistogram(lufs: Double) -> LoudnessEnergyHistogram {
        var histogram = LoudnessEnergyHistogram()
        let energy = 10.0.pow((lufs + 0.691) / 10)
        for _ in 0..<10 { _ = histogram.add(linearEnergy: energy) }
        return histogram
    }
}

private extension Double {
    func pow(_ exponent: Double) -> Double {
        Foundation.pow(self, exponent)
    }
}
