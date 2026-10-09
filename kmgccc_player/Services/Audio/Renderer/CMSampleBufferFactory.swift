//
//  CMSampleBufferFactory.swift
//  myPlayer2
//
//  PCM -> CMSampleBuffer packaging layer for the AVSampleBufferAudioRenderer
//  output path.
//
//  Responsibilities (from the migration plan phase 2):
//  - Convert decoded PCM (any ASBD: float/int, interleaved/non-interleaved,
//    mono/stereo/multichannel, any sample rate) into a canonical interleaved
//    Float32 buffer.
//  - Package that buffer as a CMSampleBuffer with a continuous presentation
//    timestamp and a correct CMAudioFormatDescription.
//  - Avoid per-chunk allocations in the hot path: the interleaved scratch
//    buffer is reused, and the format description is cached per format.
//
//  Memory ownership: each produced CMSampleBuffer owns its CMBlockBuffer;
//  callers (the renderer queue) keep them alive only until enqueue returns.
//

import AVFoundation
import CoreMedia
import Foundation

/// Canonical decoded PCM used across the renderer pipeline: interleaved Float32.
/// Value type (Sendable) so it can cross queue boundaries safely. Explicitly
/// nonisolated so its properties remain usable from any execution context.
nonisolated struct CanonicalPCM: Sendable {
    let frames: Int
    let channelCount: Int
    let sampleRate: Double
    /// Interleaved Float32, length frames * channelCount.
    let data: [Float]

    var seconds: Double { Double(frames) / sampleRate }

    /// Returns a sub-slice of this PCM buffer starting at `frameOffset` for `frameCount` frames.
    /// If the requested range exceeds bounds, it is clamped to available frames.
    func slice(frameOffset: Int, frameCount: Int) -> CanonicalPCM {
        guard frameOffset >= 0, frameCount > 0, frameOffset < frames else {
            return CanonicalPCM(frames: 0, channelCount: channelCount, sampleRate: sampleRate, data: [])
        }
        let clampedCount = min(frameCount, frames - frameOffset)
        let sampleStart = frameOffset * channelCount
        let sampleEnd = sampleStart + clampedCount * channelCount
        let sliceData = Array(data[sampleStart..<sampleEnd])
        return CanonicalPCM(
            frames: clampedCount,
            channelCount: channelCount,
            sampleRate: sampleRate,
            data: sliceData
        )
    }
}

enum CMSampleBufferFactory {

    /// Copy the source format's real Core Audio layout into a small Sendable
    /// value. A missing or unidentified layout remains explicitly unknown.
    nonisolated static func dspAudioFormat(from format: AVAudioFormat) -> DSPAudioFormat {
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            return DSPAudioFormat(
                sampleRate: sampleRate,
                channelCount: channelCount,
                rawLayoutData: nil,
                channelLabels: nil,
                layoutIsKnown: false
            )
        }
        guard let channelLayout = format.channelLayout else {
            if channelCount == 1 || channelCount == 2 {
                return conventionalMonoStereoFormat(
                    sampleRate: sampleRate,
                    channelCount: channelCount
                )
            }
            return DSPAudioFormat(
                sampleRate: sampleRate,
                channelCount: channelCount,
                rawLayoutData: nil,
                channelLabels: nil,
                layoutIsKnown: false
            )
        }

        let nativeLayout = channelLayout.layout
        let nativeValue = nativeLayout.pointee
        let descriptionCount = Int(nativeValue.mNumberChannelDescriptions)
        let descriptionOffset = MemoryLayout<AudioChannelLayout>.size
            - MemoryLayout<AudioChannelDescription>.size
        let layoutByteCount = descriptionOffset
            + descriptionCount * MemoryLayout<AudioChannelDescription>.size
        let rawLayout = Data(bytes: UnsafeRawPointer(nativeLayout), count: layoutByteCount)
        let labels = channelLabels(
            from: nativeLayout,
            channelCount: channelCount
        )
        let unknownLabels: Set<UInt32> = [
            UInt32(kAudioChannelLabel_Unknown),
            UInt32(kAudioChannelLabel_Unused),
            UInt32(kAudioChannelLabel_Discrete),
        ]
        let isKnown = labels?.count == channelCount
            && labels?.allSatisfy { label in
                !unknownLabels.contains(label)
                    && !(label >= UInt32(kAudioChannelLabel_Discrete_0)
                        && label <= UInt32(kAudioChannelLabel_Discrete_0) + 0xFFFF)
            } == true

        return DSPAudioFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            rawLayoutData: rawLayout,
            channelLabels: labels,
            layoutIsKnown: isKnown
        )
    }

    private nonisolated static func conventionalMonoStereoFormat(
        sampleRate: Double,
        channelCount: Int
    ) -> DSPAudioFormat {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelCount == 1
            ? kAudioChannelLayoutTag_Mono
            : kAudioChannelLayoutTag_Stereo
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        layout.mNumberChannelDescriptions = 0
        let headerByteCount = MemoryLayout<AudioChannelLayout>.size
            - MemoryLayout<AudioChannelDescription>.size
        let raw = withUnsafeBytes(of: &layout) { bytes in
            Data(bytes.prefix(headerByteCount))
        }
        let labels: [UInt32] = channelCount == 1
            ? [UInt32(kAudioChannelLabel_Mono)]
            : [UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)]
        return DSPAudioFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            rawLayoutData: raw,
            channelLabels: labels,
            layoutIsKnown: true
        )
    }

    /// Create a CMAudioFormatDescription for interleaved Float32 PCM while
    /// preserving the source's actual channel layout. A nil/unknown layout is
    /// represented without a guessed tag.
    nonisolated static func formatDescription(
        sourceFormat: DSPAudioFormat
    ) -> CMAudioFormatDescription? {
        makeFormatDescription(sourceFormat: sourceFormat)
    }

    /// Compatibility helper for callers that have only a count. Count alone
    /// cannot establish speaker identities, so the resulting description has
    /// no inferred multichannel layout.
    nonisolated static func formatDescription(
        channelCount: Int,
        sampleRate: Double
    ) -> CMAudioFormatDescription? {
        formatDescription(sourceFormat: DSPAudioFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            rawLayoutData: nil,
            channelLabels: nil,
            layoutIsKnown: false
        ))
    }

    private nonisolated static func makeFormatDescription(
        sourceFormat: DSPAudioFormat
    ) -> CMAudioFormatDescription? {
        let channelCount = sourceFormat.channelCount
        let sampleRate = sourceFormat.sampleRate
        guard channelCount > 0, sampleRate.isFinite, sampleRate > 0 else { return nil }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * 4),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * 4),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        if let rawLayoutData = sourceFormat.rawLayoutData,
           rawLayoutData.count >= MemoryLayout<AudioChannelLayout>.size
                - MemoryLayout<AudioChannelDescription>.size {
            let status = rawLayoutData.withUnsafeBytes { rawLayout in
                guard let layout = rawLayout.baseAddress?.assumingMemoryBound(to: AudioChannelLayout.self) else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                return CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: rawLayoutData.count,
                    layout: layout,
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &formatDesc
                )
            }
            return status == noErr ? formatDesc : nil
        }

        let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
        return status == noErr ? formatDesc : nil
    }

    private nonisolated static func channelLabels(
        from layout: UnsafePointer<AudioChannelLayout>,
        channelCount: Int
    ) -> [UInt32]? {
        let value = layout.pointee
        if value.mNumberChannelDescriptions > 0 {
            let descriptionOffset = MemoryLayout<AudioChannelLayout>.size
                - MemoryLayout<AudioChannelDescription>.size
            let descriptions = UnsafeRawPointer(layout)
                .advanced(by: descriptionOffset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            let labels = (0..<Int(value.mNumberChannelDescriptions)).map {
                descriptions[$0].mChannelLabel
            }
            return labels.count == channelCount ? labels : nil
        }

        switch value.mChannelLayoutTag {
        case kAudioChannelLayoutTag_UseChannelBitmap:
            var bitmap = value.mChannelBitmap
            return withUnsafePointer(to: &bitmap) { pointer in
                resolvedChannelLabels(
                    property: kAudioFormatProperty_ChannelLayoutForBitmap,
                    inputSize: UInt32(MemoryLayout<AudioChannelBitmap>.size),
                    inputSpecifier: UnsafeRawPointer(pointer),
                    channelCount: channelCount
                )
            }
        case kAudioChannelLayoutTag_Unknown, kAudioChannelLayoutTag_UseChannelDescriptions:
            return nil
        default:
            var tag = value.mChannelLayoutTag
            return withUnsafePointer(to: &tag) { pointer in
                resolvedChannelLabels(
                    property: kAudioFormatProperty_ChannelLayoutForTag,
                    inputSize: UInt32(MemoryLayout<AudioChannelLayoutTag>.size),
                    inputSpecifier: UnsafeRawPointer(pointer),
                    channelCount: channelCount
                )
            }
        }
    }

    private nonisolated static func resolvedChannelLabels(
        property: AudioFormatPropertyID,
        inputSize: UInt32,
        inputSpecifier: UnsafeRawPointer,
        channelCount: Int
    ) -> [UInt32]? {
        var outputSize: UInt32 = 0
        guard AudioFormatGetPropertyInfo(
            property,
            inputSize,
            inputSpecifier,
            &outputSize
        ) == noErr,
        outputSize >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }

        var output = [UInt8](repeating: 0, count: Int(outputSize))
        let status = output.withUnsafeMutableBytes { outputBytes in
            AudioFormatGetProperty(
                property,
                inputSize,
                inputSpecifier,
                &outputSize,
                outputBytes.baseAddress!
            )
        }
        guard status == noErr else { return nil }
        return output.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            let layout = baseAddress.assumingMemoryBound(to: AudioChannelLayout.self)
            guard layout.pointee.mNumberChannelDescriptions == UInt32(channelCount) else {
                return nil
            }
            let descriptionOffset = MemoryLayout<AudioChannelLayout>.size
                - MemoryLayout<AudioChannelDescription>.size
            let descriptions = baseAddress
                .advanced(by: descriptionOffset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            return (0..<channelCount).map { descriptions[$0].mChannelLabel }
        }
    }

    // MARK: - Conversion

    /// Convert an AVAudioPCMBuffer (any common format) to canonical interleaved
    /// Float32. Returns nil only for unsupported formats (non-PCM, etc.).
    nonisolated static func canonicalize(
        _ source: AVAudioPCMBuffer,
        channelCount: Int,
        sampleRate: Double
    ) -> CanonicalPCM? {
        let frames = Int(source.frameLength)
        guard frames > 0, let channels = source.floatChannelData else { return nil }

        var interleaved = [Float](repeating: 0, count: frames * channelCount)

        if source.format.isInterleaved {
            // Float32 interleaved already: direct copy.
            channels[0].withMemoryRebound(to: Float.self, capacity: frames * channelCount) { src in
                interleaved.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src, count: frames * channelCount)
                }
            }
        } else {
            // Non-interleaved: planar to interleaved. Keep the common stereo
            // path contiguous and pointer-based. The old channel-major loop
            // performed strided Array writes plus bounds/iterator work for
            // every decoded sample (the dominant audio-only CPU hotspot).
            interleaved.withUnsafeMutableBufferPointer { destination in
                guard var dst = destination.baseAddress else { return }

                switch channelCount {
                case 1:
                    dst.update(from: channels[0], count: frames)
                case 2:
                    var left = channels[0]
                    var right = channels[1]
                    for _ in 0..<frames {
                        dst[0] = left.pointee
                        dst[1] = right.pointee
                        dst = dst.advanced(by: 2)
                        left = left.advanced(by: 1)
                        right = right.advanced(by: 1)
                    }
                default:
                    var channelPointers = (0..<channelCount).map { channels[$0] }
                    for _ in 0..<frames {
                        for channel in 0..<channelCount {
                            dst[channel] = channelPointers[channel].pointee
                            channelPointers[channel] = channelPointers[channel].advanced(by: 1)
                        }
                        dst = dst.advanced(by: channelCount)
                    }
                }
            }
        }

        return CanonicalPCM(
            frames: frames,
            channelCount: channelCount,
            sampleRate: sampleRate,
            data: interleaved
        )
    }

    // MARK: - CMSampleBuffer creation

    /// Package canonical PCM as a CMSampleBuffer with a presentation timestamp.
    ///
    /// - Parameters:
    ///   - pcm: canonical interleaved Float32 audio.
    ///   - formatDescription: cached format description matching `pcm`.
    ///   - presentationTime: PTS of the first frame (continuous across chunks).
    nonisolated static func makeSampleBuffer(
        from pcm: CanonicalPCM,
        formatDescription: CMAudioFormatDescription,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        let frames = pcm.frames
        let channels = pcm.channelCount
        let bytesPerFrame = channels * 4
        let byteCount = frames * bytesPerFrame
        guard byteCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = pcm.data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        // CMSampleTimingInfo.duration is the duration of ONE sample (per the
        // CMSampleBufferCreateReady docs: a single struct applies to all
        // samples, each having this duration). So a 44.1kHz buffer uses
        // duration = 1/44100s; total buffer duration = frames * duration.
        let oneSampleDuration = CMTime(value: 1, timescale: CMTimeScale(sampleRate: pcm.sampleRate))
        var timing = CMSampleTimingInfo(
            duration: oneSampleDuration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        // sampleSizeArray holds the size of ONE sample (one PCM frame). With
        // sampleSizeEntryCount == 1 the single entry applies to all samples
        // (see CMSampleBufferCreate docs: uncompressed interleaved audio uses
        // {8} for stereo Float32). Passing the total byteCount would declare
        // each frame to be `frames*bytesPerFrame` bytes.
        var sampleSize = [channels * 4]
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return createStatus == noErr ? sampleBuffer : nil
    }

    /// Convenience: CMTime for a media frame position at a sample rate.
    nonisolated static func time(frames: Int64, sampleRate: Double) -> CMTime {
        CMTime(value: frames, timescale: CMTimeScale(sampleRate.rounded()))
    }
}

extension CMTimeScale {
    nonisolated init(sampleRate: Double) {
        self.init(Int32(sampleRate.rounded()))
    }
}
