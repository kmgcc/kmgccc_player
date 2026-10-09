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
    private var lastDecodedChunk: (start: AVAudioFramePosition, pcm: CanonicalPCM)?
    /// Physically decoded past currentPosition, but not consumed by nextChunk.
    private var readAheadPCM: CanonicalPCM?
    private var dspReadAheadEnabled = false

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

        let start = currentPosition
        var prefix: CanonicalPCM?
        if let cached = readAheadPCM {
            let count = min(Int(frames), cached.frames)
            prefix = cached.slice(frameOffset: 0, frameCount: count)
            readAheadPCM = count < cached.frames
                ? cached.slice(frameOffset: count, frameCount: cached.frames - count) : nil
        }
        let prefixCount = prefix?.frames ?? 0
        let decoded = prefixCount < Int(frames)
            ? try decode(frames: frames - AVAudioFrameCount(prefixCount)) : nil
        let canonical: CanonicalPCM
        if let prefix, let decoded {
            var data = prefix.data
            data.append(contentsOf: decoded.data)
            canonical = CanonicalPCM(frames: prefix.frames + decoded.frames,
                channelCount: sourceChannelCount, sampleRate: sourceSampleRate, data: data)
        } else if let prefix {
            canonical = prefix
        } else if let decoded {
            canonical = decoded
        } else { return nil }
        currentPosition += AVAudioFramePosition(canonical.frames)
        lastDecodedChunk = dspReadAheadEnabled ? (start, canonical) : nil
        return canonical
    }

    private func decode(frames: AVAudioFrameCount) throws -> CanonicalPCM {
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
        guard canonical.frames > 0 else {
            throw RendererPipelineError.sourceError(underlying: NSError(
                domain: "AVFilePCMProvider", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "the decoder ended before the declared source range",
                ]
            ))
        }
        return canonical
    }

    func peekChunk(
        at position: AVAudioFramePosition,
        maxFrames: AVAudioFrameCount,
        restoringTo restorePosition: AVAudioFramePosition
    ) throws -> CanonicalPCM? {
        dspReadAheadEnabled = true
        let start = max(0, min(position, rangeLength))
        let count = Int(min(Int64(maxFrames), rangeLength - start))
        guard count > 0 else { return nil }
        var data = [Float]()
        data.reserveCapacity(count * sourceChannelCount)
        var cursor = start
        if let last = lastDecodedChunk,
           cursor >= last.start, cursor < last.start + AVAudioFramePosition(last.pcm.frames) {
            let offset = Int(cursor - last.start)
            let prefixCount = min(count, last.pcm.frames - offset)
            data.append(contentsOf: last.pcm.data[
                (offset * sourceChannelCount)..<((offset + prefixCount) * sourceChannelCount)
            ])
            cursor += AVAudioFramePosition(prefixCount)
        }
        let received = data.count / sourceChannelCount
        if received == count {
            return CanonicalPCM(frames: count, channelCount: sourceChannelCount,
                                sampleRate: sourceSampleRate, data: data)
        }
        let cachedFrames = readAheadPCM?.frames ?? 0
        if cursor >= currentPosition,
           cursor <= currentPosition + AVAudioFramePosition(cachedFrames),
           Int(cursor - currentPosition) + count - received <= RendererDSPLookahead.maximumFrames {
            let offset = Int(cursor - currentPosition)
            let needed = offset + count - received
            while (readAheadPCM?.frames ?? 0) < needed {
                let existingCount = readAheadPCM?.frames ?? 0
                let extra = try decode(frames: AVAudioFrameCount(needed - existingCount))
                var aheadData = readAheadPCM?.data ?? []
                aheadData.append(contentsOf: extra.data)
                readAheadPCM = CanonicalPCM(frames: existingCount + extra.frames,
                    channelCount: sourceChannelCount, sampleRate: sourceSampleRate, data: aheadData)
            }
            guard let ahead = readAheadPCM else { return nil }
            data.append(contentsOf: ahead.data[
                (offset * sourceChannelCount)..<((offset + count - received) * sourceChannelCount)
            ])
            return CanonicalPCM(frames: count, channelCount: sourceChannelCount,
                                sampleRate: sourceSampleRate, data: data)
        }
        // Random replay is uncommon and cannot use the most recent decode
        // window. Preserve both the physical file cursor and unconsumed prefix.
        let savedPosition = currentPosition
        let savedPhysicalPosition = file.framePosition
        let savedLast = lastDecodedChunk
        let savedAhead = readAheadPCM
        defer {
            file.framePosition = savedPhysicalPosition
            currentPosition = savedPosition
            lastDecodedChunk = savedLast
            readAheadPCM = savedAhead
        }
        try seek(to: start)
        return try nextChunk(maxFrames: AVAudioFrameCount(count))
    }

    func seek(to position: AVAudioFramePosition) throws {
        let clamped = max(0, min(position, rangeLength))
        // AVAudioFile exposes seek via the settable framePosition property.
        file.framePosition = rangeStart + clamped
        currentPosition = clamped
        lastDecodedChunk = nil
        readAheadPCM = nil
    }

    func setDSPReadAheadEnabled(_ enabled: Bool) {
        guard dspReadAheadEnabled != enabled else { return }
        dspReadAheadEnabled = enabled
        if !enabled {
            if readAheadPCM != nil { file.framePosition = rangeStart + currentPosition }
            lastDecodedChunk = nil
            readAheadPCM = nil
        }
    }
}
