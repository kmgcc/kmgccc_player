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
    var sensitivity: Float = 1.0
    var speed: Float = 1.0
    var targetHz: Int = 30
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
    private var runGeneration: UInt64 = 0

    private let hub = AudioAnalysisHub.shared

    private(set) var metrics: LEDMeterMetrics
    private(set) var audioMetrics: AudioMetrics = AudioMetrics.zero

    var normalizedLevel: Float {
        metrics.level
    }

    init(config: LEDMeterConfig? = nil) {
        let resolvedConfig = config ?? LEDMeterConfig()
        self.config = resolvedConfig
        self.metrics = LEDMeterMetrics.zero(count: resolvedConfig.ledCount)
        self.processor = LEDMeterProcessor(config: resolvedConfig)
    }

    func attachToMixer(_ mixer: AVAudioMixerNode) {
        hub.attachToMixer(mixer)
    }

    func start() {
        guard !isInstalled else { return }
        runGeneration &+= 1
        let generation = runGeneration

        hub.targetHz = config.targetHz
        hub.start()

        let processor = self.processor
        consumerID = hub.addConsumer { [weak self, processor] data in
            let result = processor.process(data: data)
            Task { @MainActor in
                guard let self else { return }
                guard self.isInstalled, self.runGeneration == generation else { return }
                self.metrics = result.led
                self.audioMetrics = result.audio
            }
        }

        isInstalled = true
    }

    func stop() {
        guard isInstalled else { return }
        runGeneration &+= 1

        if let id = consumerID {
            hub.removeConsumer(id)
            consumerID = nil
        }
        hub.stop()

        isInstalled = false
        processor.reset()
        metrics = LEDMeterMetrics.zero(count: config.ledCount)
        audioMetrics = AudioMetrics.zero
    }

    func updatePlaybackState(isPlaying: Bool) {
        // Local meter ignores external playback state
    }

    func updateConfig(_ newConfig: LEDMeterConfig) {
        config = newConfig
        processor.updateConfig(newConfig)
        if metrics.leds.count != newConfig.ledCount {
            metrics = LEDMeterMetrics.zero(count: newConfig.ledCount)
        }
        hub.targetHz = newConfig.targetHz
    }
}

// MARK: - Processor

final class LEDMeterProcessor: @unchecked Sendable {

    let fftSize: Int = 2048
    private let bandCount: Int = 8
    private let dbFloor: Float = -60
    private let dbCeil: Float = -6.0
    private let baseAttack: Double = 0.015
    private let baseRelease: Double = 0.08

    private var config: LEDMeterConfig

    static var lastPrintTime: TimeInterval = 0
    private var window: [Float]
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length = 0
    private var ringBuffer: LEDRingBuffer
    private var env: Float = 0
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

        var rms: Float = 0
        vDSP_rmsqv(fftInput, 1, &rms, vDSP_Length(fftSize))
        var peak: Float = 0
        vDSP_maxmgv(fftInput, 1, &peak, vDSP_Length(fftSize))

        vDSP_vmul(fftInput, 1, window, 1, &fftInput, 1, vDSP_Length(fftSize))

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
        sampleRate = data.sampleRate
        return analyze(magnitudes: data.magnitudes, rms: data.rms, peak: data.peak)
    }

    private func analyze(magnitudes: [Float], rms: Float, peak: Float) -> (
        led: LEDMeterMetrics, audio: AudioMetrics
    ) {
        let currentConfig = withConfig()
        let rmsDb = 20.0 * log10f(max(rms, 1e-6))

        let binHz = sampleRate / Float(fftSize)
        let nyquistBins = max(1, magnitudes.count)
        let cutoffBin = min(Int(currentConfig.cutoffHz / binHz), nyquistBins)

        let bin20 = min(max(1, Int(ceil(20.0 / binHz))), cutoffBin)
        let bin60 = min(max(1, Int(ceil(60.0 / binHz))), cutoffBin)
        let bin200 = min(max(1, Int(ceil(200.0 / binHz))), cutoffBin)
        let bin3000 = min(max(1, Int(ceil(3000.0 / binHz))), nyquistBins)

        var bandPowerWeighted: Float = 0
        magnitudes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            if bin20 > 1 {
                var p: Float = 0
                vDSP_sve(base.advanced(by: 1), 1, &p, vDSP_Length(bin20 - 1))
                bandPowerWeighted += p
            }
            if bin60 > bin20 {
                var p: Float = 0
                vDSP_sve(base.advanced(by: bin20), 1, &p, vDSP_Length(bin60 - bin20))
                bandPowerWeighted += p
            }
            if bin200 > bin60 {
                var p: Float = 0
                vDSP_sve(base.advanced(by: bin60), 1, &p, vDSP_Length(bin200 - bin60))
                bandPowerWeighted += p
            }
            if cutoffBin > bin200 {
                var p: Float = 0
                vDSP_sve(base.advanced(by: bin200), 1, &p, vDSP_Length(cutoffBin - bin200))
                bandPowerWeighted += p
            }
        }

        let bandRMS = sqrt(bandPowerWeighted) / Float(fftSize)
        let db = 20 * log10(bandRMS + 1e-7)

        // ── Perceptual volume mapping ──
        // 1. Linear position in dB range
        var t = (db - dbFloor) / (dbCeil - dbFloor)

        // 2. Soft-knee S-curve:
        //    low: gentle lift   mid: linear-ish   high: soft compression
        let mapped: Float
        if t <= 0 {
            mapped = 0
        } else if t < 0.35 {
            mapped = 0.35 * pow(t / 0.35, 1.7)
        } else if t < 0.75 {
            let midProgress = (t - 0.35) / 0.40
            mapped = 0.35 + midProgress * 0.45
        } else {
            let highProgress = (t - 0.75) / 0.25
            mapped = 0.80 + (1.0 - exp(-highProgress * 3.5)) * 0.12 / (1.0 - exp(-3.5))
        }

        // 3. Sensitivity multiplier with soft limit (never hard-clamp to 1.0)
        var levelAdj = mapped * currentConfig.sensitivity
        if levelAdj > 0.9 {
            levelAdj = 0.9 + (levelAdj - 0.9) * 0.3
        }
        levelAdj = min(levelAdj, 0.98)

        // 4. Smooth noise gate (smoothstep)
        let gateStart: Float = -42
        let gateEnd: Float = -54
        let gateRaw = clamp((rmsDb - gateEnd) / (gateStart - gateEnd))
        let noiseGate = gateRaw * gateRaw * (3.0 - 2.0 * gateRaw)
        let gatedLevel = levelAdj * noiseGate

        // 5. Envelope smoothing
        let dt = 1.0 / Double(currentConfig.targetHz)
        let speed = max(0.1, Double(currentConfig.speed))
        let attackTime = baseAttack / speed
        let releaseTime = baseRelease / speed
        let aAtt = 1 - exp(-dt / attackTime)
        let aRel = 1 - exp(-dt / releaseTime)

        if gatedLevel > env {
            env += Float(aAtt) * (gatedLevel - env)
        } else {
            env += Float(aRel) * (gatedLevel - env)
        }
        env = clamp(env)

        // 6. LED quantization
        let ledCount = max(1, currentConfig.ledCount)
        let levels = max(3, currentConfig.levels)
        let step = 1.0 / Float(levels - 1)
        let x = env * Float(ledCount)

        var leds = [Float](repeating: 0, count: ledCount)
        let order = centerOutOrder(count: ledCount)

        for i in 0..<ledCount {
            let cont = clamp(x - Float(i))
            let softened = pow(cont, 1.6)
            let quant = round(softened / step) * step
            if i < order.count {
                leds[order[i]] = clamp(quant)
            }
        }

        let now = Date().timeIntervalSinceReferenceDate
        let ledMetrics = LEDMeterMetrics(timestamp: now, level: env, leds: leds)

        // AudioMetrics (bands for skins)
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

        // Mid-band dB for downstream consumers (not used for gating anymore)
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

        let audio = AudioMetrics(
            rms: rms,
            peak: peak,
            db: rmsDb,
            bands: bands,
            smoothedBands: smoothedBands,
            smoothedLevel: env,
            bassEnergy: bassEnergy,
            waveform: downsampleWaveform(samples: fftInput, target: 64),
            transientLevel: 0,
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
