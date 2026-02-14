//
//  LEDMeterService.swift
//  myPlayer2
//
//  kmgccc_player - LED Meter Service (low-frequency weighted)
//  Computes low-frequency energy with FFT and publishes quantized LED levels.
//

import AVFoundation
import Accelerate
import Foundation
import Observation
import SwiftUI

struct LEDMeterConfig: Sendable {
    var ledCount: Int = 11
    var levels: Int = 7
    var cutoffHz: Float = 1200
    var preGain: Float = 1.0
    var sensitivity: Float = 1.0
    var speed: Float = 1.0
    var targetHz: Int = 60
    var transientThreshold: Float = 1.5
    var transientIntensity: Float = 2.5
    var transientCutoffHz: Float = 60.0
    var useActivityGate: Bool = false
    // Reserved fields for audio metrics extensions.
    var lowSensitivity: Float = 1.0
    /// Low-band pre-boost in dB (applies before mapping to 0...1).
    var lowPreBoostDb: Float = 0.0
    var lowAttack: Float = 0.09
    var lowRelease: Float = 0.28
    var kickAttack: Float = 0.05
    var kickRelease: Float = 0.22
    /// 0=off, 1=mild, 2=strong
    var quietSuppressionMode: Int = 2

}

struct LEDMeterMetrics: Sendable {
    var timestamp: TimeInterval
    var level: Float
    var leds: [Float]

    static func zero(count: Int) -> LEDMeterMetrics {
        LEDMeterMetrics(timestamp: 0, level: 0, leds: [Float](repeating: 0, count: count))
    }
}

@Observable
@MainActor
final class LEDMeterService: AudioLevelMeterProtocol {

    private let processor: LEDMeterProcessor
    private var config: LEDMeterConfig
    private var consumerID: UUID?
    private var isInstalled = false

    // Hub reference (singleton)
    private let hub = AudioAnalysisHub.shared

    private(set) var metrics: LEDMeterMetrics
    private(set) var audioMetrics: AudioMetrics = AudioMetrics.zero

    var normalizedLevel: Float {
        metrics.level
    }

    init(config: LEDMeterConfig = LEDMeterConfig()) {
        self.config = config
        self.metrics = LEDMeterMetrics.zero(count: config.ledCount)
        self.processor = LEDMeterProcessor(config: config)
    }

    func attachToMixer(_ mixer: AVAudioMixerNode) {
        // Just forward to Hub
        hub.attachToMixer(mixer)
    }

    func start() {
        guard !isInstalled else { return }

        // Start Hub
        hub.start()

        let processor = self.processor
        // Subscribe to analysis data
        consumerID = hub.addConsumer { [weak self, processor] data in
            // Run processing on a background task
            let result = processor.process(data: data)

            Task { @MainActor in
                guard let self else { return }
                self.metrics = result.led
                self.audioMetrics = result.audio
            }
        }

        isInstalled = true
    }

    func stop() {
        guard isInstalled else { return }

        if let id = consumerID {
            hub.removeConsumer(id)
        }
        hub.stop()  // Note: Single hub stop logic might be tricky if multiple consumers. Hub should probably count refs or just run.
        // For now, assuming this is the primary controller of capture.
        // Ideally Hub manages its own lifecycle or refcounting.
        // As per user request "AudioAnalysisHub (tap + FFT magnitude)", we'll let this service control start/stop for now as it's the main driver.

        isInstalled = false
        metrics = LEDMeterMetrics.zero(count: config.ledCount)
        audioMetrics = AudioMetrics.zero
    }

    func updateConfig(_ newConfig: LEDMeterConfig) {
        config = newConfig
        processor.updateConfig(newConfig)
        if metrics.leds.count != newConfig.ledCount {
            metrics = LEDMeterMetrics.zero(count: newConfig.ledCount)
        }
        // Hub targetHz could be updated too if we wanted to sync it
        hub.targetHz = newConfig.targetHz
    }

    // Removed old audio consumer logic as Hub handles raw data distribution if needed,
    // but legacy consumers expected PCM buffer.
    // If other parts of app use addAudioConsumer, they must be moved to Hub or we must bridge.
    // Additional per-consumer routing can be added here if needed.

    // Keeping method signature for protocol but warning/no-op or proxying to Hub?
    // The protocol AudioLevelMeterProtocol doesn't enforce addAudioConsumer.
    // Only internal usage. We will remove it from here.
}

// MARK: - Processor

private final class LEDMeterProcessor: @unchecked Sendable {

    let fftSize: Int = 2048
    private let bandCount: Int = 8
    private let dbFloor: Float = -60
    private let dbCeil: Float = 0.0
    private let gamma: Float = 0.95
    private let baseAttack: Double = 0.02
    private let baseRelease: Double = 0.12

    private var config: LEDMeterConfig

    static var lastPrintTime: TimeInterval = 0
    private var window: [Float]
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length = 0
    private var ringBuffer: LEDRingBuffer
    private var env: Float = 0
    private var avgDb: Float = -60
    private var avgBassDb: Float = -60
    private var smoothedBands: [Float]
    private var lastLed: LEDMeterMetrics
    private var lastAudio: AudioMetrics = AudioMetrics.zero
    private var sampleRate: Float = 44100

    private var fftInput: [Float]
    private var fftReal: [Float]
    private var fftImag: [Float]
    private var fftMagnitudes: [Float]

    private let configLock = NSLock()

    init(config: LEDMeterConfig) {
        self.config = config
        self.window = [Float](repeating: 0, count: fftSize)
        self.ringBuffer = LEDRingBuffer(capacity: fftSize * 4)
        self.smoothedBands = [Float](repeating: 0, count: bandCount)
        self.lastLed = LEDMeterMetrics.zero(count: config.ledCount)

        self.fftInput = [Float](repeating: 0, count: fftSize)
        self.fftReal = [Float](repeating: 0, count: fftSize / 2)
        self.fftImag = [Float](repeating: 0, count: fftSize / 2)
        self.fftMagnitudes = [Float](repeating: 0, count: fftSize / 2)

        rebuildFFT()
    }

    func prepare(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    func reset() {
        env = 0
        avgDb = -60
        avgBassDb = -60
        smoothedBands = [Float](repeating: 0, count: bandCount)
        ringBuffer.reset()
    }

    func updateConfig(_ newConfig: LEDMeterConfig) {
        configLock.lock()
        config = newConfig
        if lastLed.leds.count != newConfig.ledCount {
            lastLed = LEDMeterMetrics.zero(count: newConfig.ledCount)
        }
        configLock.unlock()
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        ringBuffer.write(samples: channelData[0], count: frameLength)
    }

    func process() -> (led: LEDMeterMetrics, audio: AudioMetrics) {
        let currentConfig = withConfig()
        _ = max(1, currentConfig.targetHz)

        guard ringBuffer.readLatest(into: &fftInput) else {
            return (lastLed, lastAudio)
        }

        // Time-domain metrics (before windowing)
        var rms: Float = 0
        vDSP_rmsqv(fftInput, 1, &rms, vDSP_Length(fftSize))
        var peak: Float = 0
        vDSP_maxmgv(fftInput, 1, &peak, vDSP_Length(fftSize))

        // Hann window
        vDSP_vmul(fftInput, 1, window, 1, &fftInput, 1, vDSP_Length(fftSize))

        // FFT (real)
        guard let fftSetup else {
            return (lastLed, lastAudio)
        }
        fftReal.withUnsafeMutableBufferPointer { realPtr in
            fftImag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else {
                    return
                }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                fftInput.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2)
                    {
                        ptrComplex in
                        vDSP_ctoz(ptrComplex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &fftMagnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        return analyze(magnitudes: fftMagnitudes, rms: rms, peak: peak)
    }

    func process(data: AudioAnalysisData) -> (led: LEDMeterMetrics, audio: AudioMetrics) {
        // When using Hub data, we have pre-computed info
        sampleRate = data.sampleRate
        return analyze(magnitudes: data.magnitudes, rms: data.rms, peak: data.peak)
    }

    private func analyze(magnitudes: [Float], rms: Float, peak: Float) -> (
        led: LEDMeterMetrics, audio: AudioMetrics
    ) {
        let currentConfig = withConfig()
        _ = max(1, currentConfig.targetHz)
        let rmsDb = 20.0 * log10f(max(rms, 1e-6))

        // Ensure magnitudes buffer is accessible as reference
        // (magnitudes passed in might be a copy, but we just need to read it)
        // To keep logic identical, we use 'magnitudes' array.

        // Low-frequency weighted energy (Skip DC)
        let binHz = sampleRate / Float(fftSize)
        let nyquistBins = max(1, magnitudes.count)
        let cutoffBin = min(Int(currentConfig.cutoffHz / binHz), nyquistBins)

        // Define frequency bands (bin indices)
        let bin20 = min(max(1, Int(ceil(20.0 / binHz))), cutoffBin)
        let bin60 = min(max(1, Int(ceil(60.0 / binHz))), cutoffBin)
        _ = min(max(1, Int(ceil(100.0 / binHz))), cutoffBin)
        let bin200 = min(max(1, Int(ceil(200.0 / binHz))), cutoffBin)
        let binTransient = min(
            max(1, Int(ceil(currentConfig.transientCutoffHz / binHz))), cutoffBin)
        let bin3000 = min(max(1, Int(ceil(3000.0 / binHz))), nyquistBins)

        // Weights
        let wSubBass: Float = 1.0
        let wBass: Float = 1.0
        let wRest: Float = 1.0

        var bandPowerWeighted: Float = 0

        magnitudes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }

            // 0. <20Hz: bin 1 ..< bin20 (if any)
            if bin20 > 1 {
                var p: Float = 0
                vDSP_sve(base.advanced(by: 1), 1, &p, vDSP_Length(bin20 - 1))
                bandPowerWeighted += p
            }

            // 1. Sub-Bass: bin20 ..< bin60
            if bin60 > bin20 {
                var p: Float = 0
                vDSP_sve(base.advanced(by: bin20), 1, &p, vDSP_Length(bin60 - bin20))
                bandPowerWeighted += p * wSubBass
            }

            // 2. Bass: bin60 ..< bin200
            if bin200 > bin60 {
                var p: Float = 0
                vDSP_sve(base.advanced(by: bin60), 1, &p, vDSP_Length(bin200 - bin60))
                bandPowerWeighted += p * wBass
            }

            // 3. Rest: bin200 ..< cutoffBin
            if cutoffBin > bin200 {
                var p: Float = 0
                vDSP_sve(base.advanced(by: bin200), 1, &p, vDSP_Length(cutoffBin - bin200))
                bandPowerWeighted += p * wRest
            }
        }

        // bandRMS = sqrt(weighted_sum(|X|^2)) / N
        let bandRMS = sqrt(bandPowerWeighted) / Float(fftSize)
        let db = 20 * log10(bandRMS + 1e-7)

        // Transient Detection / Dynamic Emphasis
        // Focus transient detection on sub-bass frequencies (<= 60Hz) for deep kick isolation
        var subBassPower: Float = 0
        magnitudes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_sve(base.advanced(by: 1), 1, &subBassPower, vDSP_Length(binTransient - 1))
        }
        let bassRMS = sqrt(subBassPower) / Float(fftSize)
        let bassDb = 20 * log10(bassRMS + 1e-7)

        let bassDiff = bassDb - avgBassDb
        if bassDiff > 0 {
            avgBassDb += bassDiff * 0.005  // Use Float literal implicitly or explicitly
        } else {
            avgBassDb += bassDiff * 0.02
        }

        // Standard overall volume tracking for context
        let diff = db - avgDb
        if diff > 0 {
            avgDb += diff * 0.05
        } else {
            avgDb += diff * 0.2
        }

        // Calculate transient based on bass deviations
        let transientRaw = max(0, bassDb - avgBassDb - currentConfig.transientThreshold)

        // Context scaling: if the overall song volume is low, suppress transients.
        // Context scaling: if the overall song volume is low, suppress transients.
        // If it's high (at climax), allow them to be very prominent.
        let volumeFactor = clamp((db - dbFloor) / (dbCeil - dbFloor))
        let boostSensitivity = powf(volumeFactor, 2.5 as Float) * 4.0 as Float  // Relaxed curve to allow punch at medium volumes

        // Soft noise gate: smoothly fade out transients in quiet passages.
        let gateStart: Float = -30
        let gateEnd: Float = -48
        let noiseGate = clamp((rmsDb - gateEnd) / (gateStart - gateEnd))
        let transient = transientRaw * boostSensitivity * noiseGate
        let boost = transient * currentConfig.transientIntensity  // Base boost factor
        let boostedDb = db + boost

        // Mapping (Use boostedDb)
        let t = clamp((boostedDb - dbFloor) / (dbCeil - dbFloor))

        let levelRaw = clamp(t * currentConfig.preGain)
        var levelAdj = clamp(powf(levelRaw, gamma) * currentConfig.sensitivity)

        // Mid-range energy for quiet-passage detection (200Hz - 3000Hz)
        var midPower: Float = 0
        magnitudes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let len = max(0, bin3000 - bin200)
            if len > 0 {
                vDSP_sve(base.advanced(by: bin200), 1, &midPower, vDSP_Length(len))
            }
        }
        let midRMS = sqrt(midPower) / Float(fftSize)
        let midDb = 20 * log10(midRMS + 1e-7)

        // Activity Gate: Based on Mid-range energy (200Hz - 3000Hz)
        if currentConfig.useActivityGate {
            let gateStart: Float = -45
            let gateEnd: Float = -55
            let gateLinear = clamp((midDb - gateEnd) / (gateStart - gateEnd))
            levelAdj *= pow(gateLinear, 2.0)
        }

        // Envelope smoothing
        let dt = 1.0 / Double(currentConfig.targetHz)
        let speed = max(0.1, Double(currentConfig.speed))
        let attackTime = baseAttack / speed
        let releaseTime = baseRelease / speed
        let aAtt = 1 - exp(-dt / attackTime)
        let aRel = 1 - exp(-dt / releaseTime)

        if levelAdj > env {
            env += Float(aAtt) * (levelAdj - env)
        } else {
            env += Float(aRel) * (levelAdj - env)
        }

        env = clamp(env)

        // LED quantization
        let ledCount = max(1, currentConfig.ledCount)
        let levels = max(3, currentConfig.levels)
        let step = 1.0 / Float(levels - 1)
        // Ensure x covers full range: 0 to ledCount
        let x = env * Float(ledCount)

        var leds = [Float](repeating: 0, count: ledCount)
        let order = centerOutOrder(count: ledCount)

        for i in 0..<ledCount {
            // i=0 is center, i=count-1 is edge
            // x represents magnitude. If x > i, the i-th LED (from center) lights up.
            let cont = clamp(x - Float(i))
            let softened = pow(cont, 1.6)
            let quant = round(softened / step) * step

            if i < order.count {
                leds[order[i]] = clamp(quant)
            }
        }

        let now = Date().timeIntervalSinceReferenceDate
        let ledMetrics = LEDMeterMetrics(timestamp: now, level: env, leds: leds)

        // Audio metrics for skins
        let bands = computeBands(power: fftMagnitudes, bandCount: bandCount)
        let smoothing: Float = 0.25
        if smoothedBands.count != bands.count {
            smoothedBands = [Float](repeating: 0, count: bands.count)
        }
        for idx in bands.indices {
            smoothedBands[idx] += (bands[idx] - smoothedBands[idx]) * smoothing
        }

        let bassEnergy: Float
        if smoothedBands.isEmpty {
            bassEnergy = 0
        } else if smoothedBands.count == 1 {
            bassEnergy = smoothedBands[0]
        } else {
            bassEnergy = (smoothedBands[0] + smoothedBands[1]) * 0.5
        }

        let audio = AudioMetrics(
            rms: rms,
            peak: peak,
            db: rmsDb,
            bands: bands,
            smoothedBands: smoothedBands,
            smoothedLevel: env,
            bassEnergy: bassEnergy,
            waveform: downsampleWaveform(samples: fftInput, target: 64),
            transientLevel: transient,
            midEnergy: midDb,
            lowBandDb: db,
            lowBandLoudness: 0,
            kickPulse: 0
        )

        lastLed = ledMetrics
        lastAudio = audio

        return (ledMetrics, audio)
    }

    private func rebuildFFT() {
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    private func withConfig() -> LEDMeterConfig {
        configLock.lock()
        let current = config
        configLock.unlock()
        return current
    }

    private func computeBands(power: [Float], bandCount: Int) -> [Float] {
        let half = power.count
        let bands = max(1, bandCount)
        let binsPerBand = max(1, half / bands)
        var result = [Float](repeating: 0, count: bands)
        power.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for band in 0..<bands {
                let start = band * binsPerBand
                let end = (band == bands - 1) ? half : min(half, start + binsPerBand)
                if start >= end { continue }
                var sum: Float = 0
                vDSP_sve(base.advanced(by: start), 1, &sum, vDSP_Length(end - start))
                let avg = sum / Float(end - start)
                let db = 10 * log10(avg + 1e-12)
                result[band] = clamp((db - dbFloor) / (dbCeil - dbFloor))
            }
        }
        return result
    }

    private func downsampleWaveform(samples: [Float], target: Int) -> [Float] {
        let targetCount = max(1, target)
        let count = samples.count
        if count == 0 {
            return [Float](repeating: 0, count: targetCount)
        }
        let stride = max(1, count / targetCount)
        var result: [Float] = []
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

    private func centerOutOrder(count: Int) -> [Int] {
        let center = count / 2
        var order = [Int]()
        order.reserveCapacity(count)
        order.append(center)
        for offset in 1...count {
            let left = center - offset
            let right = center + offset
            if left >= 0 { order.append(left) }
            if right < count { order.append(right) }
            if order.count >= count { break }
        }
        return order
    }

    private func clamp(_ value: Float, _ minValue: Float = 0, _ maxValue: Float = 1) -> Float {
        min(maxValue, max(minValue, value))
    }
}

private final class LEDRingBuffer {
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var filledOnce: Bool = false
    private let lock = NSLock()

    init(capacity: Int) {
        buffer = [Float](repeating: 0, count: max(1, capacity))
    }

    func reset() {
        lock.lock()
        writeIndex = 0
        filledOnce = false
        for idx in buffer.indices {
            buffer[idx] = 0
        }
        lock.unlock()
    }

    func write(samples: UnsafePointer<Float>, count: Int) {
        lock.lock()
        let capacity = buffer.count
        for i in 0..<count {
            buffer[writeIndex] = samples[i]
            writeIndex += 1
            if writeIndex >= capacity {
                writeIndex = 0
                filledOnce = true
            }
        }
        lock.unlock()
    }

    func readLatest(into output: inout [Float]) -> Bool {
        lock.lock()
        let capacity = buffer.count
        let needed = output.count
        let hasData = filledOnce || writeIndex >= needed
        if !hasData {
            lock.unlock()
            return false
        }

        let start = (writeIndex - needed + capacity) % capacity
        for i in 0..<needed {
            output[i] = buffer[(start + i) % capacity]
        }
        lock.unlock()
        return true
    }
}
