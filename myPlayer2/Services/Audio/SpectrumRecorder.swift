//
//  SpectrumRecorder.swift
//  myPlayer2
//
//  Development tool: records real app spectrum output from a local audio file.
//  Run with KMGCCC_RECORD_SPECTRUM=1 to regenerate SpectrumFrames.swift.
//

import AVFoundation
import Foundation

final class SpectrumRecorder {
    static let shared = SpectrumRecorder()
    private init() {}

    func run() {
        _run()
    }

    private func _run() {
        let fileURL = URL(fileURLWithPath: "/Users/kmg/Music/网易云音乐/new/Tabata Songs - Tabata Wod.mp3")
        let startTime: Double = 15.0
        let duration: Double = 20.0

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)

        guard let file = try? AVAudioFile(forReading: fileURL) else {
            print("[Recorder] Failed to load audio file")
            return
        }

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(startTime * sampleRate)
        let frameCount = AVAudioFrameCount(duration * sampleRate)

        let hub = AudioAnalysisHub.shared
        hub.attachToMixer(engine.mainMixerNode)

        let spectrumProcessor = SpectrumProcessor()
        let ledConfig = LEDMeterConfig()
        let ledProcessor = LEDMeterProcessor(config: ledConfig)
        ledProcessor.prepare(sampleRate: Float(sampleRate))

        var waveFrames: [[Float]] = []
        var ledFrames: [LEDMeterMetrics] = []
        var audioFrames: [AudioMetrics] = []
        let lock = NSLock()

        let consumerId = hub.addConsumer { data in
            let wave = spectrumProcessor.process(
                magnitudes: data.magnitudes,
                fftSize: data.fftSize,
                sampleRate: data.sampleRate
            )
            let (led, audio) = ledProcessor.process(data: data)
            lock.lock()
            waveFrames.append(wave)
            ledFrames.append(led)
            audioFrames.append(audio)
            lock.unlock()
        }

        hub.start()

        do {
            try engine.start()
        } catch {
            print("[Recorder] Failed to start engine: \(error)")
            hub.removeConsumer(consumerId)
            hub.stop()
            return
        }

        playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
        playerNode.play()

        Thread.sleep(forTimeInterval: duration + 1.5)

        playerNode.stop()
        engine.stop()
        hub.stop()
        hub.removeConsumer(consumerId)

        let expectedFrames = Int(duration * 30)
        let trimmedWave = Array(waveFrames.prefix(expectedFrames))
        let trimmedLed = Array(ledFrames.prefix(expectedFrames))
        let trimmedAudio = Array(audioFrames.prefix(expectedFrames))

        print("[Recorder] Captured \(waveFrames.count) raw frames, using \(trimmedWave.count)")

        self.export(
            waveFrames: trimmedWave,
            ledFrames: trimmedLed,
            audioFrames: trimmedAudio
        )
    }

    private func export(
        waveFrames: [[Float]],
        ledFrames: [LEDMeterMetrics],
        audioFrames: [AudioMetrics]
    ) {
        let dstPath = "/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Models/SpectrumFrames.swift"

        let frameCount = waveFrames.count
        let waveBandCount = 9
        let audioBandCount = 8
        let waveformLength = 64
        guard frameCount > 0, !ledFrames.isEmpty, !audioFrames.isEmpty else {
            print("[Recorder] No frames to export")
            return
        }
        let ledCount = ledFrames[0].leds.count

        var lines: [String] = []
        lines.append("//")
        lines.append("//  SpectrumFrames.swift")
        lines.append("//  myPlayer2")
        lines.append("//")
        lines.append("//  Auto-generated from real app spectrum chain playback.")
        lines.append("//  Source: Tabata Songs - Tabata Wod.mp3 [15s-35s]")
        lines.append("//  Regenerate: KMGCCC_RECORD_SPECTRUM=1 <app_binary>")
        lines.append("//")
        lines.append("")
        lines.append("nonisolated struct SpectrumFrameData {")
        lines.append("    static let fps: Double = 30.0")
        lines.append("    static let frameCount: Int = \(frameCount)")
        lines.append("    static let waveBandCount: Int = \(waveBandCount)")
        lines.append("    static let audioBandCount: Int = \(audioBandCount)")
        lines.append("    static let waveformLength: Int = \(waveformLength)")
        lines.append("    static let ledCount: Int = \(ledCount)")
        lines.append("")

        // Wave frames
        lines.append("    static let waveFrames: [Float] = [")
        for (i, frame) in waveFrames.enumerated() {
            let vals = frame.map { String(format: "%.6f", $0) }.joined(separator: ", ")
            let suffix = (i == waveFrames.count - 1) ? "" : ","
            lines.append("        \(vals)\(suffix)")
        }
        lines.append("    ]")
        lines.append("")

        // LED levels
        lines.append("    static let ledLevels: [Float] = [")
        for (i, frame) in ledFrames.enumerated() {
            let val = String(format: "%.6f", frame.level)
            let suffix = (i == ledFrames.count - 1) ? "" : ","
            lines.append("        \(val)\(suffix)")
        }
        lines.append("    ]")
        lines.append("")

        // LED arrays
        lines.append("    static let ledLeds: [Float] = [")
        for (i, frame) in ledFrames.enumerated() {
            let vals = frame.leds.map { String(format: "%.6f", $0) }.joined(separator: ", ")
            let suffix = (i == ledFrames.count - 1) ? "" : ","
            lines.append("        \(vals)\(suffix)")
        }
        lines.append("    ]")
        lines.append("")

        // AudioMetrics scalar fields
        let scalarFields: [(name: String, values: [Float])] = [
            ("audioRMS", audioFrames.map { $0.rms }),
            ("audioPeak", audioFrames.map { $0.peak }),
            ("audioDb", audioFrames.map { $0.db }),
            ("audioSmoothedLevel", audioFrames.map { $0.smoothedLevel }),
            ("audioBassEnergy", audioFrames.map { $0.bassEnergy }),
            ("audioTransientLevel", audioFrames.map { $0.transientLevel }),
            ("audioMidEnergy", audioFrames.map { $0.midEnergy }),
            ("audioLowBandDb", audioFrames.map { $0.lowBandDb }),
            ("audioLowBandLoudness", audioFrames.map { $0.lowBandLoudness }),
            ("audioKickPulse", audioFrames.map { $0.kickPulse }),
        ]

        for field in scalarFields {
            lines.append("    static let \(field.name): [Float] = [")
            for (i, val) in field.values.enumerated() {
                let s = String(format: "%.6f", val)
                let suffix = (i == field.values.count - 1) ? "" : ","
                lines.append("        \(s)\(suffix)")
            }
            lines.append("    ]")
            lines.append("")
        }

        // Audio bands
        lines.append("    static let audioBands: [Float] = [")
        for (i, frame) in audioFrames.enumerated() {
            let vals = frame.bands.map { String(format: "%.6f", $0) }.joined(separator: ", ")
            let suffix = (i == audioFrames.count - 1) ? "" : ","
            lines.append("        \(vals)\(suffix)")
        }
        lines.append("    ]")
        lines.append("")

        // Audio smoothed bands
        lines.append("    static let audioSmoothedBands: [Float] = [")
        for (i, frame) in audioFrames.enumerated() {
            let vals = frame.smoothedBands.map { String(format: "%.6f", $0) }.joined(separator: ", ")
            let suffix = (i == audioFrames.count - 1) ? "" : ","
            lines.append("        \(vals)\(suffix)")
        }
        lines.append("    ]")
        lines.append("")

        // Audio waveform
        lines.append("    static let audioWaveform: [Float] = [")
        for (i, frame) in audioFrames.enumerated() {
            let vals = frame.waveform.map { String(format: "%.6f", $0) }.joined(separator: ", ")
            let suffix = (i == audioFrames.count - 1) ? "" : ","
            lines.append("        \(vals)\(suffix)")
        }
        lines.append("    ]")
        lines.append("}")

        let content = lines.joined(separator: "\n") + "\n"

        do {
            try content.write(toFile: dstPath, atomically: true, encoding: .utf8)
            print("[Recorder] Exported to \(dstPath)")
        } catch {
            print("[Recorder] Export failed: \(error)")
        }
    }
}
