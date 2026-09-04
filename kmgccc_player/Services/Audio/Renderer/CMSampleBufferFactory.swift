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

    /// Create a CMAudioFormatDescription for interleaved Float32 PCM.
    ///
    /// Deliberately uncached: format descriptions are created once per track
    /// (or per format change), and Swift 6's isolation rules make a global
    /// cached dictionary with Hashable keys awkward to keep nonisolated.
    nonisolated static func formatDescription(channelCount: Int, sampleRate: Double) -> CMAudioFormatDescription? {
        makeFormatDescription(channelCount: channelCount, sampleRate: sampleRate)
    }

    private nonisolated static func makeFormatDescription(
        channelCount: Int,
        sampleRate: Double
    ) -> CMAudioFormatDescription? {
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

        // Standard pre-defined channel layout tag (Stereo/Mono). Verified
        // against the working reference implementation (mpv ao_avfoundation,
        // which is what IINA uses and which enables system spatial audio on
        // the same hardware where our layout-less description was rejected
        // with "playback configuration is not [eligible]"): the format
        // description must carry a STANDARD layout tag — a missing layout or
        // a custom (UseChannelDescriptions) layout both land on the
        // non-spatializable path (mpv PR #11955).
        let layoutTag: AudioChannelLayoutTag? = switch channelCount {
        case 1: nil // Preserve the verified demo's mono description.
        case 2: kAudioChannelLayoutTag_Stereo
        case 3: kAudioChannelLayoutTag_MPEG_3_0_A
        case 4: kAudioChannelLayoutTag_Quadraphonic
        case 5: kAudioChannelLayoutTag_MPEG_5_0_A
        case 6: kAudioChannelLayoutTag_MPEG_5_1_A
        case 8: kAudioChannelLayoutTag_MPEG_7_1_A
        default: nil
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = layoutTag ?? kAudioChannelLayoutTag_UseChannelDescriptions

        var formatDesc: CMAudioFormatDescription?
        let status: OSStatus
        if layoutTag == nil {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
        } else {
            status = withUnsafePointer(to: &layout) { layoutPtr in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: MemoryLayout<AudioChannelLayout>.size,
                    layout: layoutPtr,
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &formatDesc
                )
            }
        }
        return status == noErr ? formatDesc : nil
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
