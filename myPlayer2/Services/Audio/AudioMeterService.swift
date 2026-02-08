//
//  AudioMeterService.swift
//  myPlayer2
//
//  TrueMusic - Audio Meter Service (full metrics)
//  Provides RMS/Peak/dB, multi-band energy, smoothed values, and waveform samples.
//

import AVFoundation
import Accelerate
import Foundation
import SwiftUI

struct AudioMeterConfig: Sendable {
    var fftSize: Int = 1024
    var bandCount: Int = 8
    var waveformSamples: Int = 64
    var smoothing: Float = 0.25
    var updateRate: Double = 1.0 / 60.0
    // Raise floor to prevent noise
    var dbFloor: Float = -70
    var dbCeiling: Float = 0

    var sensitivity: Float = 1.0
}

/// Audio meter with full metrics for skins.
@Observable
@MainActor
final class AudioMeterService: AudioLevelMeterProtocol {

    private(set) var metrics: AudioMetrics = .zero

    var audioMetrics: AudioMetrics {
        metrics
    }

    var normalizedLevel: Float {
        metrics.smoothedLevel
    }

    var config: AudioMeterConfig {
        didSet {
            // Only rebuild if FFT properties change
            if config.fftSize != oldValue.fftSize || config.bandCount != oldValue.bandCount {
                processor.updateConfig(config)
            } else {
                processor.updateParameters(config)
            }
        }
    }

    private weak var mixerNode: AVAudioMixerNode?
    private var isInstalled = false
    private let processor: AudioMeterProcessor
    private var updateTimer: Timer?

    init(config: AudioMeterConfig = AudioMeterConfig()) {
        self.config = config
        self.processor = AudioMeterProcessor(config: config)
    }

    func attachToMixer(_ mixer: AVAudioMixerNode) {
        mixerNode = mixer
    }

    func start() {
        guard !isInstalled else { return }
        guard let mixer = mixerNode else {
            print("⚠️ AudioMeterService: No mixer attached")
            return
        }

        let format = mixer.outputFormat(forBus: 0)
        processor.sampleRate = Float(format.sampleRate)
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(config.fftSize)

        processor.reset()

        let processor = self.processor
        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) {
            [processor] buffer, _ in
            processor.process(buffer)
        }

        isInstalled = true
        startUpdateTimer()
    }

    func stop() {
        guard isInstalled else { return }
        mixerNode?.removeTap(onBus: 0)
        isInstalled = false
        stopUpdateTimer()

        Task { @MainActor in
            self.metrics = .zero
        }
    }

    private func startUpdateTimer() {
        stopUpdateTimer()

        // Timer runs on main loop but we want to sync settings
        updateTimer = Timer.scheduledTimer(withTimeInterval: config.updateRate, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }

                // Sync dynamic settings from AppSettings
                let settings = AppSettings.shared
                var currentConfig = self.config
                currentConfig.sensitivity = settings.ledSensitivity

                // Push to processor (thread-safe copy)
                // Note: processor is @unchecked Sendable, so this is safe
                self.processor.updateParameters(currentConfig)

                // Get snapshot
                let metrics = self.processor.snapshot()

                // Update observable property
                self.metrics = metrics
            }
        }

        if let timer = updateTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
}

// MARK: - Audio Processor

private final class AudioMeterProcessor: @unchecked Sendable {

    var sampleRate: Float = 44100

    private var config: AudioMeterConfig
    private var window: [Float]

    // vDSP FFT Setup
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length = 0

    private var smoothedBands: [Float]
    private var smoothedLevel: Float = 0
    private var lock = NSLock()

    // Noise Gate & Stabilization
    private var silenceCounter: Int = 0
    private let silenceThresholdFrames: Int = 10  // Frames to wait before forcing zero

    private var latestMetrics: AudioMetrics = .zero

    init(config: AudioMeterConfig) {
        self.config = config
        self.window = [Float](repeating: 0, count: config.fftSize)
        self.smoothedBands = [Float](repeating: 0, count: config.bandCount)
        rebuildFFT()
    }

    deinit {
        if let fftSetup = fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func updateConfig(_ config: AudioMeterConfig) {
        lock.lock()
        defer { lock.unlock() }
        self.config = config
        self.window = [Float](repeating: 0, count: config.fftSize)
        self.smoothedBands = [Float](repeating: 0, count: config.bandCount)
        rebuildFFT()
    }

    func updateParameters(_ config: AudioMeterConfig) {
        lock.lock()
        defer { lock.unlock() }
        // Update only dynamic params without rebuilding FFT
        self.config.sensitivity = config.sensitivity
        self.config.dbFloor = config.dbFloor
        self.config.dbCeiling = config.dbCeiling
        self.config.smoothing = config.smoothing
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        smoothedLevel = 0
        smoothedBands = [Float](repeating: 0, count: config.bandCount)
        latestMetrics = .zero
        silenceCounter = 0
    }

    func snapshot() -> AudioMetrics {
        lock.lock()
        defer { lock.unlock() }
        return latestMetrics
    }

    private func rebuildFFT() {
        vDSP_hann_window(&window, vDSP_Length(config.fftSize), Int32(vDSP_HANN_NORM))

        if let oldSetup = fftSetup {
            vDSP_destroy_fftsetup(oldSetup)
        }

        log2n = vDSP_Length(log2(Float(config.fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let samples = channelData[0]

        // Lock for config access
        lock.lock()
        let currentConfig = self.config
        lock.unlock()

        // 1. RMS/Peak Calculation with Noise Gate
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameLength))

        if rms < 0.000_01 {  // Approx -100dB
            handleSilence(currentConfig: currentConfig, rms: rms)
            return
        }

        // 2. Waveform (Time Domain)
        let waveform = downsampleWaveform(
            samples: samples, count: frameLength, target: currentConfig.waveformSamples)
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameLength))

        let db = 20 * log10(max(rms, 0.000_001))
        let peakDb = 20 * log10(max(peak, 0.000_001))

        // 3. FFT & Bands (normalized 0..1)
        let bandValues = computeFFTAndBands(
            samples: samples, count: frameLength, config: currentConfig)

        // 4. Level Normalization & Sensitivity
        let rmsNorm = normalizeDb(db, config: currentConfig)
        let peakNorm = normalizeDb(peakDb, config: currentConfig)
        let combined = min(1, max(0, rmsNorm * 0.7 + peakNorm * 0.3))

        let scaled = combined * currentConfig.sensitivity
        let compressed = 1 - exp(-scaled * 1.6)

        // 5. Smoothing & Output
        lock.lock()
        defer { lock.unlock() }

        silenceCounter = 0

        let attackCoeff: Float = 0.45
        let releaseCoeff: Float = 0.08

        if compressed > smoothedLevel {
            smoothedLevel += (compressed - smoothedLevel) * attackCoeff
        } else {
            smoothedLevel += (compressed - smoothedLevel) * releaseCoeff
        }

        if smoothedLevel < 0.02 {
            smoothedLevel = 0
        }

        let smoothing = max(0.05, min(1, currentConfig.smoothing))
        if smoothedBands.count != bandValues.count {
            smoothedBands = [Float](repeating: 0, count: bandValues.count)
        }
        for idx in bandValues.indices {
            smoothedBands[idx] += (bandValues[idx] - smoothedBands[idx]) * smoothing
        }

        let bassValue: Float
        if smoothedBands.isEmpty {
            bassValue = 0
        } else if smoothedBands.count == 1 {
            bassValue = smoothedBands[0]
        } else {
            bassValue = (smoothedBands[0] + smoothedBands[1]) * 0.5
        }

        latestMetrics = AudioMetrics(
            rms: rms,
            peak: peak,
            db: db,
            bands: bandValues,
            smoothedBands: smoothedBands,
            smoothedLevel: smoothedLevel,
            bassEnergy: bassValue,
            waveform: waveform,
            transientLevel: 0,
            midEnergy: 0
        )
    }

    // Separate function to handle valid "silence" to drift to zero smoothly but quickly
    private func handleSilence(currentConfig: AudioMeterConfig, rms: Float) {
        lock.lock()
        defer { lock.unlock() }

        silenceCounter += 1

        // If we have been silent for enough frames, hard reset
        if silenceCounter > silenceThresholdFrames {
            smoothedLevel = 0
            latestMetrics = AudioMetrics.zero
            return
        }

        // Otherwise, decay rapidly using a fixed release coeff
        let releaseCoeff: Float = 0.2

        smoothedLevel += (0 - smoothedLevel) * releaseCoeff
        if smoothedLevel < 0.01 { smoothedLevel = 0 }

        // We still return a valid metric struct, just with decaying values
        latestMetrics = AudioMetrics(
            rms: rms,
            peak: 0,
            db: -100,
            bands: [Float](repeating: 0, count: config.bandCount),  // Bands clear approx instantly
            smoothedBands: [Float](repeating: 0, count: config.bandCount),
            smoothedLevel: smoothedLevel,
            bassEnergy: 0,
            waveform: [],
            transientLevel: 0,
            midEnergy: 0
        )
    }

    private func downsampleWaveform(samples: UnsafePointer<Float>, count: Int, target: Int)
        -> [Float]
    {
        let targetCount = max(1, target)
        if count == 0 {
            return [Float](repeating: 0, count: targetCount)
        }
        let stride = max(1, count / targetCount)
        var result = [Float]()
        result.reserveCapacity(targetCount)
        var index = 0
        for _ in 0..<targetCount {
            let start = index
            let end = min(count, start + stride)
            if start >= end {
                result.append(0)
                continue
            }
            var sum: Float = 0
            for i in start..<end {
                sum += abs(samples[i])
            }
            let avg = sum / Float(end - start)
            result.append(min(1, avg * 2))
            index += stride
        }
        return result
    }

    private func computeFFTAndBands(
        samples: UnsafePointer<Float>, count: Int, config: AudioMeterConfig
    ) -> [Float] {
        guard let fftSetup = fftSetup else { return [] }
        let fftSize = config.fftSize
        let half = fftSize / 2

        // Prepare input
        var input = [Float](repeating: 0, count: fftSize)
        let copyCount = min(count, fftSize)
        input.withUnsafeMutableBufferPointer { bufferPtr in
            bufferPtr.baseAddress?.update(from: samples, count: copyCount)
        }

        // Window
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(fftSize))

        // FFT
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else {
                    return
                }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)

                input.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        ptrComplex in
                        vDSP_ctoz(ptrComplex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        // Magnitudes
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else {
                    return
                }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Bands
        let bandCount = max(1, config.bandCount)
        let binsPerBand = max(1, half / bandCount)

        var bands = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let start = band * binsPerBand
            let end = (band == bandCount - 1) ? half : min(half, start + binsPerBand)
            if start >= end {
                bands[band] = 0
                continue
            }
            var sum: Float = 0
            vDSP_sve(&magnitudes[start], 1, &sum, vDSP_Length(end - start))
            let avg = sum / Float(end - start)

            let db = 20 * log10(max(avg, 0.000_001))
            bands[band] = normalizeDb(db, config: config)
        }

        return bands
    }

    private func normalizeDb(_ db: Float, config: AudioMeterConfig) -> Float {
        let floor = config.dbFloor
        let ceil = config.dbCeiling
        guard ceil > floor else { return 0 }
        let normalized = (db - floor) / (ceil - floor)
        return min(1, max(0, normalized))
    }
}
