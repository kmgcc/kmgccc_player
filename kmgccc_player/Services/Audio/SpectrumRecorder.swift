//
//  SpectrumRecorder.swift
//  kmgccc_player
//
//  Development tool: records renderer-timed spectrum output from a local audio file.
//  Set KMGCCC_SPECTRUM_SOURCE and KMGCCC_SPECTRUM_OUTPUT before running.
//

import AVFoundation
import Foundation

@MainActor
final class SpectrumRecorder {
    static let shared = SpectrumRecorder()
    private init() {}

    private var activeCapture: CaptureRun?

    func run() {
        cancel()

        let environment = ProcessInfo.processInfo.environment
        guard
            let sourcePath = environment["KMGCCC_SPECTRUM_SOURCE"], !sourcePath.isEmpty,
            let outputPath = environment["KMGCCC_SPECTRUM_OUTPUT"], !outputPath.isEmpty
        else {
            Log.warning(
                "[SpectrumRecorder] Set KMGCCC_SPECTRUM_SOURCE and KMGCCC_SPECTRUM_OUTPUT",
                category: .audio
            )
            return
        }

        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: sourcePath)) else {
            Log.error("[SpectrumRecorder] Failed to load audio file", category: .audio)
            return
        }

        let startTime: Double = 15.0
        let requestedDuration: Double = 20.0
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(startTime * sampleRate)
        guard sampleRate > 0, startFrame < file.length else {
            Log.error(
                "[SpectrumRecorder] Source file ends before the 15 second capture start",
                category: .audio
            )
            return
        }

        let requestedFrames = AVAudioFramePosition(requestedDuration * sampleRate)
        let frameCount = AVAudioFrameCount(min(file.length - startFrame, requestedFrames))
        let provider = AVFilePCMProvider(
            file: file,
            startingFrame: startFrame,
            frameCount: frameCount
        )
        let capture = CaptureRun(
            provider: provider,
            duration: Double(frameCount) / sampleRate
        )
        activeCapture = capture
        capture.start { [weak self, weak capture] result in
            guard let self, let capture,
                  self.activeCapture === capture else { return }
            self.activeCapture = nil

            switch result {
            case .completed(let frames):
                self.exportCapturedFrames(frames, outputPath: outputPath)
            case .failed(let message):
                Log.error("[SpectrumRecorder] Capture failed: \(message)", category: .audio)
            case .timedOut(let frameCount):
                Log.error(
                    "[SpectrumRecorder] Capture timed out at \(frameCount) frames",
                    category: .audio
                )
            case .cancelled:
                break
            }
        }
    }

    func cancel() {
        activeCapture?.cancel()
        activeCapture = nil
    }

    private func exportCapturedFrames(_ frames: CaptureFrames, outputPath: String) {
        let expectedFrames = 20 * 30
        let wave = Array(frames.wave.prefix(expectedFrames))
        let led = Array(frames.led.prefix(expectedFrames))
        let audio = Array(frames.audio.prefix(expectedFrames))
        Log.info(
            "[SpectrumRecorder] Captured \(frames.wave.count) raw frames, exporting \(wave.count)",
            category: .audio
        )
        export(waveFrames: wave, ledFrames: led, audioFrames: audio, outputPath: outputPath)
    }

    nonisolated private struct CaptureFrames: Sendable {
        let wave: [[Float]]
        let led: [LEDMeterMetrics]
        let audio: [AudioMetrics]
    }

    nonisolated private enum CaptureResult: Sendable {
        case completed(CaptureFrames)
        case failed(String)
        case timedOut(Int)
        case cancelled
    }

    /// Uses the production renderer timing and analysis algorithms while keeping
    /// development PCM out of the live app's shared analysis hub.
    nonisolated private final class CaptureRun: @unchecked Sendable {
        private let provider: AVFilePCMProvider
        private let duration: Double
        private let pipeline = RendererPlaybackPipeline()
        private let hub = AudioAnalysisHub()
        private let spectrumProcessor = SpectrumProcessor()
        private let ledProcessor = LEDMeterProcessor(config: LEDMeterConfig())
        private let lock = NSLock()
        private var waveFrames: [[Float]] = []
        private var ledFrames: [LEDMeterMetrics] = []
        private var audioFrames: [AudioMetrics] = []
        private var isFinished = false
        @MainActor private var sourceExhausted = false
        @MainActor private var consumerID: UUID?
        @MainActor private var timeoutTimer: Timer?
        @MainActor private var lastProgress: Double = 0
        @MainActor private var completion: (@MainActor (CaptureResult) -> Void)?

        init(provider: AVFilePCMProvider, duration: Double) {
            self.provider = provider
            self.duration = duration
            ledProcessor.prepare(sampleRate: Float(provider.sourceSampleRate))
        }

        @MainActor
        func start(completion: @escaping @MainActor (CaptureResult) -> Void) {
            self.completion = completion
            hub.targetHz = 30
            consumerID = hub.addConsumer { [weak self] data in
                self?.record(data)
            }
            hub.start()
            hub.enableRendererFeed()
            hub.setPlaying(true)
            pipeline.setVolume(0)

            let timeout = max(5, duration + 8)
            timeoutTimer = Timer.scheduledTimer(
                withTimeInterval: timeout,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finish(.timedOut)
                }
            }

            pipeline.onAnalysisPCM = { [weak hub] pcm in
                hub?.enqueueRendererPCM(pcm)
            }
            pipeline.onProgress = { [weak self] seconds in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastProgress = seconds
                    self.finishIfPlaybackReachedEOF()
                }
            }
            pipeline.onFailure = { [weak self] _, error in
                let message = String(describing: error)
                Task { @MainActor [weak self] in
                    self?.finish(.failed(message))
                }
            }
            pipeline.onSegmentExhausted = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sourceExhausted = true
                    self.finishIfPlaybackReachedEOF()
                }
            }
            pipeline.load(
                source: provider,
                presentationStartSeconds: 0,
                clockTimeSeconds: 0,
                autoplay: true
            )
        }

        @MainActor
        func cancel() {
            finish(.cancelled)
        }

        private func record(_ data: AudioAnalysisData) {
            let wave = spectrumProcessor.process(
                magnitudes: data.magnitudes,
                fftSize: data.fftSize,
                sampleRate: data.sampleRate,
                rms: data.rms,
                peak: data.peak,
                playerVolume: 1.0,
                scheduling: (produced: 0, displayed: 0, coalesced: 0, pending: 0, frameAgeMs: 0),
                dt: 1.0 / 30.0
            )
            let (led, audio) = ledProcessor.process(data: data)
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            waveFrames.append(wave)
            ledFrames.append(led)
            audioFrames.append(audio)
            lock.unlock()
        }

        @MainActor
        private func finishIfPlaybackReachedEOF() {
            guard sourceExhausted, lastProgress >= duration else { return }
            finish(.completed)
        }

        @MainActor
        private func finish(_ end: CaptureEnd) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            let frames = CaptureFrames(wave: waveFrames, led: ledFrames, audio: audioFrames)
            let progress = lastProgress
            lock.unlock()

            timeoutTimer?.invalidate()
            timeoutTimer = nil
            pipeline.onProgress = nil
            pipeline.onFailure = nil
            pipeline.onSegmentExhausted = nil

            hub.setPlaying(false)
            hub.disableRendererFeed()
            if let consumerID {
                hub.removeConsumer(consumerID)
                self.consumerID = nil
                hub.stop()
            }

            let result: CaptureResult
            switch end {
            case .completed:
                result = .completed(frames)
            case .failed(let message):
                result = .failed(message)
            case .timedOut:
                result = .timedOut(frames.wave.count)
            case .cancelled:
                result = .cancelled
            }
            let pipelineToStop = pipeline
            pipelineToStop.stop { [pipelineToStop, self] in
                // Retain both run state and pipeline until their serialized flush has run.
                _ = pipelineToStop
                Task { @MainActor [self] in
                    // The stop barrier has finished every queue-side PCM callback.
                    pipelineToStop.onAnalysisPCM = nil
                    Log.info(
                        "[SpectrumRecorder] end=\(end.description) progress=\(String(format: "%.2f", progress)) frames=\(frames.wave.count)",
                        category: .audio
                    )
                    self.completion?(result)
                    self.completion = nil
                }
            }
        }
    }

    nonisolated private enum CaptureEnd: Sendable {
        case completed
        case failed(String)
        case timedOut
        case cancelled

        var description: String {
            switch self {
            case .completed: return "completed"
            case .failed(let message): return "failed:\(message)"
            case .timedOut: return "timedOut"
            case .cancelled: return "cancelled"
            }
        }
    }

    private func export(
        waveFrames: [[Float]],
        ledFrames: [LEDMeterMetrics],
        audioFrames: [AudioMetrics],
        outputPath: String
    ) {
        let frameCount = waveFrames.count
        let waveBandCount = 9
        let audioBandCount = 8
        let waveformLength = 64
        guard frameCount > 0, !ledFrames.isEmpty, !audioFrames.isEmpty else {
            Log.warning("[SpectrumRecorder] No frames to export", category: .audio)
            return
        }
        let ledCount = ledFrames[0].leds.count

        var lines: [String] = []
        lines.append("//")
        lines.append("//  SpectrumFrames.swift")
        lines.append("//  kmgccc_player")
        lines.append("//")
        lines.append("//  Auto-generated from real app spectrum chain playback.")
        lines.append("//  Source: local audio sample [15s-35s]")
        lines.append("//  Regenerate with KMGCCC_SPECTRUM_SOURCE and KMGCCC_SPECTRUM_OUTPUT")
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
            try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
            Log.info("[SpectrumRecorder] Exported to \(outputPath)", category: .audio)
        } catch {
            Log.error("[SpectrumRecorder] Export failed: \(error)", category: .audio)
        }
    }
}
