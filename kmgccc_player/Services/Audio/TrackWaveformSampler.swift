//
//  TrackWaveformSampler.swift
//  myPlayer2
//
//  Coarse level overview of an audio file for range pickers. It reads a
//  short window at evenly spaced positions instead of decoding the whole
//  file, so an overview of a full song costs a fraction of a second.
//

import AVFoundation
import Foundation

nonisolated enum TrackWaveformSampler {
    private static let windowFrames: AVAudioFrameCount = 4_096

    /// Levels in 0...1, one per bin, scaled to the loudest bin. Empty when
    /// the file cannot be read.
    static func levels(url: URL, binCount: Int) async -> [Float] {
        await Task.detached(priority: .userInitiated) {
            sample(url: url, binCount: max(1, binCount))
        }.value
    }

    private static func sample(url: URL, binCount: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: windowFrames)
        else { return [] }
        let channels = Int(file.processingFormat.channelCount)
        var levels = [Float](repeating: 0, count: binCount)
        for bin in 0..<binCount {
            if Task.isCancelled { return [] }
            let center = Double(file.length) * (Double(bin) + 0.5) / Double(binCount)
            file.framePosition = max(0, AVAudioFramePosition(center) - AVAudioFramePosition(windowFrames / 2))
            guard (try? file.read(into: buffer, frameCount: windowFrames)) != nil,
                  buffer.frameLength > 0,
                  let data = buffer.floatChannelData else { continue }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for channel in 0..<channels {
                let samples = data[channel]
                for index in 0..<frames { sum += samples[index] * samples[index] }
            }
            levels[bin] = (sum / Float(frames * max(1, channels))).squareRoot()
        }
        guard let peak = levels.max(), peak > 0 else { return levels }
        // A gentle curve keeps quiet passages visible next to loud ones.
        return levels.map { ($0 / peak).squareRoot() }
    }
}
