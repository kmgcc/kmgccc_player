import Foundation
import AVFoundation
import Accelerate
import AudioToolbox

nonisolated struct MotionAudioAligner {
    struct Match: Sendable { let offset: Double; let score: Float; let alternateScore: Float }
    struct Samples { let data: [Float]; let start: Double }
    static let sampleRate = 8_000.0

    static func isMusicVideo(songDuration: Double, videoDuration: Double) -> Bool {
        songDuration.isFinite && songDuration >= 30 && videoDuration.isFinite && videoDuration >= 60
            && abs(videoDuration - songDuration) <= max(20, songDuration * 0.2)
    }

    /// The offsets are accepted only when independent sections agree. No match
    /// means the artwork retains its existing playback behavior.
    static func alignment(song: URL, video: URL, songDuration: Double,
                          checkpoint: @Sendable () async throws -> Void = {}) async throws -> Double? {
        guard songDuration >= 30 else { return nil }
        let span = 15.0
        let positions = [0.2, 0.5, 0.8].map { min(max(0, songDuration * $0), songDuration - span) }
        var accepted: [Double] = []
        for position in positions {
            try await checkpoint()
            try Task.checkCancellation()
            let start = max(0, position - 30)
            let a = try await read(song, start: position, duration: span)
            try await checkpoint()
            let b = try await read(video, start: start, duration: span + 60)
            try await checkpoint()
            guard let match = match(a, b), match.score >= 0.8,
                  match.score - match.alternateScore >= 0.08 else { continue }
            accepted.append(match.offset)
        }
        guard accepted.count >= 2 else { return nil }
        accepted.sort()
        guard let first = accepted.first, let last = accepted.last, last - first <= 0.04 else { return nil }
        return accepted[accepted.count / 2]
    }

    static func read(_ url: URL, start: Double, duration: Double) async throws -> Samples {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw NSError(domain: "MotionAudio", code: 1) }
        let descriptions = try await track.load(.formatDescriptions)
        guard let desc = descriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { throw NSError(domain: "MotionAudio", code: 5) }
        let inputRate = asbd.pointee.mSampleRate
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: inputRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NSError(domain: "MotionAudio", code: 2) }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), duration: CMTime(seconds: duration, preferredTimescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "MotionAudio", code: 3) }
        var result: [Float] = []; var actualStart: Double?
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if actualStart == nil { actualStart = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw NSError(domain: "MotionAudio", code: Int(status)) }
            result.append(contentsOf: samples)
        }
        guard reader.status != .failed else { throw reader.error ?? NSError(domain: "MotionAudio", code: 4) }
        guard !result.isEmpty else { throw NSError(domain: "MotionAudio", code: 8) }
        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(result.count)),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(result.count) * sampleRate / inputRate + 256)) else { throw NSError(domain: "MotionAudio", code: 6) }
        input.frameLength = AVAudioFrameCount(result.count)
        result.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: result.count) }
        var supplied = false
        var conversionError: NSError?
        let state = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard state != .error else { throw conversionError ?? NSError(domain: "MotionAudio", code: 7) }
        return Samples(data: Array(UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: Int(outputBuffer.frameLength))), start: actualStart ?? start)
    }

    static func match(_ song: Samples, _ video: Samples) -> Match? {
        let n = song.data.count, m = video.data.count
        guard n > 0, m >= n else { return nil }
        var a = song.data
        var mean: Float = 0; vDSP_meanv(a, 1, &mean, vDSP_Length(n)); var negative = -mean
        vDSP_vsadd(a, 1, &negative, &a, 1, vDSP_Length(n))
        var songEnergy: Float = 0; vDSP_svesq(a, 1, &songEnergy, vDSP_Length(n))
        guard songEnergy > 0.001 else { return nil }
        var length = 1; while length < m + n - 1 { length *= 2 }
        let log2n = vDSP_Length(length.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var ar = [Float](repeating: 0, count: length), ai = ar, br = ar, bi = ar
        for i in 0..<n { ar[i] = a[n - 1 - i] }
        br.replaceSubrange(0..<m, with: video.data)
        ar.withUnsafeMutableBufferPointer { arp in ai.withUnsafeMutableBufferPointer { aip in
            br.withUnsafeMutableBufferPointer { brp in bi.withUnsafeMutableBufferPointer { bip in
                var aa = DSPSplitComplex(realp: arp.baseAddress!, imagp: aip.baseAddress!)
                var bb = DSPSplitComplex(realp: brp.baseAddress!, imagp: bip.baseAddress!)
                vDSP_fft_zip(setup, &aa, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_fft_zip(setup, &bb, 1, log2n, FFTDirection(FFT_FORWARD))
                for i in 0..<length {
                    let x = arp[i] * brp[i] - aip[i] * bip[i]
                    let y = arp[i] * bip[i] + aip[i] * brp[i]
                    arp[i] = x; aip[i] = y
                }
                vDSP_fft_zip(setup, &aa, 1, log2n, FFTDirection(FFT_INVERSE))
            }}
        }}
        var energies = [Double](repeating: 0, count: m + 1)
        for i in 0..<m { let x = Double(video.data[i]); energies[i+1] = energies[i] + x*x }
        var scores = [Float](repeating: 0, count: m-n+1)
        let minimumEnergy = (energies[m] / Double(m)) * Double(n) * 0.0025
        var best = 0; var bestScore: Float = 0
        for i in scores.indices {
            let e = energies[i+n] - energies[i]
            guard e > minimumEnergy, e > 0.001 else { continue }
            let score = ar[i+n-1] / Float(length) / sqrt(Float(e) * songEnergy)
            scores[i] = abs(score)
            if scores[i] > bestScore { bestScore = scores[i]; best = i }
        }
        var alternate: Float = 0
        for i in scores.indices where abs(i-best) > Int(sampleRate) { alternate = max(alternate,scores[i]) }
        return Match(offset: video.start + Double(best)/sampleRate - song.start, score: bestScore, alternateScore: alternate)
    }
}
