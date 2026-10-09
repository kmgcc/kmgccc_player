import AVFoundation
import Foundation

nonisolated struct RendererDSPSourceRange {
    let source: RendererPCMProvider
    let format: DSPAudioFormat
    let presentationStartSeconds: Double
    let normalizationGain: Double
    let decodePosition: AVAudioFramePosition
    let decodedPCM: CanonicalPCM?
    let decodedStartFrame: AVAudioFramePosition

    init(source: RendererPCMProvider, format: DSPAudioFormat, presentationStartSeconds: Double,
         normalizationGain: Double, decodePosition: AVAudioFramePosition,
         decodedPCM: CanonicalPCM? = nil, decodedStartFrame: AVAudioFramePosition = 0) {
        self.source = source
        self.format = format
        self.presentationStartSeconds = presentationStartSeconds
        self.normalizationGain = normalizationGain
        self.decodePosition = decodePosition
        self.decodedPCM = decodedPCM
        self.decodedStartFrame = decodedStartFrame
    }
}

/// Only the bounded FIR computation window is read ahead. Its samples retain
/// each segment's fixed normalization gain and never change source PTS/counts.
nonisolated enum RendererDSPLookahead {
    static let maximumFrames = AudioDSPConfiguration.maximumNodeCount * 64 + 4 * 2048

    static func read(
        frameCount: Int,
        format: DSPAudioFormat,
        segmentIndex: Int,
        sourceFrame: AVAudioFramePosition,
        segmentCount: Int,
        segmentAt: (Int) -> RendererDSPSourceRange
    ) throws -> CanonicalPCM? {
        guard frameCount > 0 else { return nil }
        guard frameCount <= maximumFrames, format.channelCount > 0,
              format.sampleRate.isFinite, format.sampleRate > 0,
              segmentIndex >= 0, segmentIndex < segmentCount, sourceFrame >= 0 else {
            throw RendererPipelineError.sourceError(underlying: NSError(
                domain: "RendererDSPLookahead", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The DSP read-ahead range is invalid."]
            ))
        }
        var data = [Float]()
        data.reserveCapacity(frameCount * format.channelCount)
        var index = segmentIndex
        var position = sourceFrame
        var received = 0
        var expectedPTS: Double?
        while received < frameCount, index < segmentCount {
            let range = segmentAt(index)
            guard range.format == format else { break }
            if let expectedPTS,
               abs(range.presentationStartSeconds - expectedPTS) > 0.5 / format.sampleRate { break }
            guard position <= range.source.totalFrames else {
                throw RendererPipelineError.sourceError(underlying: NSError(
                    domain: "RendererDSPLookahead", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The DSP source range changed during read-ahead."]
                ))
            }
            while received < frameCount, position < range.source.totalFrames {
                let count = min(frameCount - received, Int(range.source.totalFrames - position))
                let available: CanonicalPCM?
                if let decoded = range.decodedPCM, position >= range.decodedStartFrame,
                   position < range.decodedStartFrame + AVAudioFramePosition(decoded.frames) {
                    let offset = Int(position - range.decodedStartFrame)
                    available = decoded.slice(frameOffset: offset, frameCount: min(count, decoded.frames - offset))
                } else {
                    available = try range.source.peekChunk(
                        at: position, maxFrames: AVAudioFrameCount(count), restoringTo: range.decodePosition
                    )
                }
                guard let pcm = available, pcm.frames > 0, pcm.frames <= count,
                   pcm.channelCount == format.channelCount,
                   abs(pcm.sampleRate - format.sampleRate) < 0.5,
                   pcm.data.count == pcm.frames * format.channelCount else {
                    throw RendererPipelineError.sourceError(underlying: NSError(
                        domain: "RendererDSPLookahead", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "The decoder ended before the complete DSP read-ahead range."]
                    ))
                }
                if range.normalizationGain == 1 {
                    data.append(contentsOf: pcm.data)
                } else {
                    data.append(contentsOf: pcm.data.map { Float(Double($0) * range.normalizationGain) })
                }
                received += pcm.frames
                position += AVAudioFramePosition(pcm.frames)
            }
            expectedPTS = range.presentationStartSeconds + Double(range.source.totalFrames) / format.sampleRate
            index += 1
            position = 0
        }
        // Only a real stream end, a time gap, or a format boundary is drained
        // with zeros. Decoder errors are propagated, never treated as EOF.
        data.append(contentsOf: repeatElement(Float(0), count: (frameCount - received) * format.channelCount))
        return CanonicalPCM(frames: frameCount, channelCount: format.channelCount,
                            sampleRate: format.sampleRate, data: data)
    }
}
