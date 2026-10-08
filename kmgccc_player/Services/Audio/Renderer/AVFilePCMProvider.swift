//
//  AVFilePCMProvider.swift
//  myPlayer2
//
//  RendererPCMProvider backed by AVAudioFile: serves PCM chunks in media
//  order and supports random seek. Mirrors how the existing playback service
//  reads files, so the renderer path reuses the same decode behavior.
//
//  Concurrency: all methods are called only from the pipeline's serial queue.
//  AVAudioFile is not thread-safe, but confinement makes this sound; the
//  @unchecked Sendable marker records that contract.
//

import AVFoundation
import Foundation

/// Provides canonical PCM from an AVAudioFile for the renderer pipeline.
/// `nonisolated`: all methods are called only from the pipeline's serial queue.
nonisolated final class AVFilePCMProvider: RendererPCMProvider, @unchecked Sendable {

    private let file: AVAudioFile
    private let processingFormat: AVAudioFormat
    private let dspFormat: DSPAudioFormat
    private let rangeStart: AVAudioFramePosition
    private let rangeLength: AVAudioFramePosition
    private var currentPosition: AVAudioFramePosition = 0
    private var decodeBuffer: AVAudioPCMBuffer?

    init(
        file: AVAudioFile,
        startingFrame: AVAudioFramePosition = 0,
        frameCount: AVAudioFrameCount? = nil
    ) {
        self.file = file
        self.processingFormat = file.processingFormat
        let processingDSPFormat = CMSampleBufferFactory.dspAudioFormat(from: file.processingFormat)
        let fileDSPFormat = CMSampleBufferFactory.dspAudioFormat(from: file.fileFormat)
        if file.processingFormat.channelLayout == nil,
           file.fileFormat.channelLayout != nil,
           fileDSPFormat.channelCount == Int(file.processingFormat.channelCount),
           let sourceLayout = fileDSPFormat.rawLayoutData {
            // Keep the file's declared channel identity when AVAudioFile's
            // processing format omitted it. The PCM is still decoded at the
            // processing rate, but its channels retain the source ordering.
            self.dspFormat = DSPAudioFormat(
                sampleRate: file.processingFormat.sampleRate,
                channelCount: Int(file.processingFormat.channelCount),
                rawLayoutData: sourceLayout,
                channelLabels: fileDSPFormat.channelLabels,
                layoutIsKnown: fileDSPFormat.layoutIsKnown
            )
        } else {
            self.dspFormat = processingDSPFormat
        }
        let clampedStart = max(0, min(startingFrame, file.length))
        let available = max(0, file.length - clampedStart)
        let requested = frameCount.map(AVAudioFramePosition.init) ?? available
        self.rangeStart = clampedStart
        self.rangeLength = max(0, min(requested, available))
    }

    var sourceChannelCount: Int {
        Int(processingFormat.channelCount)
    }

    var sourceSampleRate: Double {
        processingFormat.sampleRate
    }

    var sourceDSPFormat: DSPAudioFormat {
        dspFormat
    }

    var totalFrames: AVAudioFramePosition {
        rangeLength
    }

    func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM? {
        guard currentPosition < rangeLength else { return nil }

        let remaining = rangeLength - currentPosition
        let frames = AVAudioFrameCount(min(Int64(maxFrames), remaining))
        guard frames > 0 else { return nil }

        let buffer: AVAudioPCMBuffer
        if let decodeBuffer, decodeBuffer.frameCapacity >= frames {
            buffer = decodeBuffer
        } else {
            guard let allocated = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: frames
            ) else {
                throw RendererPipelineError.sourceError(
                    underlying: NSError(domain: "AVFilePCMProvider", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "failed to allocate PCM buffer",
                    ])
                )
            }
            decodeBuffer = allocated
            buffer = allocated
        }
        try file.read(into: buffer, frameCount: frames)

        guard let canonical = CMSampleBufferFactory.canonicalize(
            buffer,
            channelCount: sourceChannelCount,
            sampleRate: sourceSampleRate
        ) else {
            throw RendererPipelineError.sourceError(
                underlying: NSError(domain: "AVFilePCMProvider", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "unsupported PCM format",
                ])
            )
        }
        currentPosition += AVAudioFramePosition(canonical.frames)
        return canonical
    }

    func seek(to position: AVAudioFramePosition) throws {
        let clamped = max(0, min(position, rangeLength))
        // AVAudioFile exposes seek via the settable framePosition property.
        file.framePosition = rangeStart + clamped
        currentPosition = clamped
    }
}
