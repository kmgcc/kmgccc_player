//
//  AudioVisualizationService.swift
//  myPlayer2
//
//  kmgccc_player - 9-Band Audio Visualizer Service
//  Provides smoothed, cubic-eased 9-band spectrum for skins.
//  Subscribes to AudioAnalysisHub for FFT data.
//

import Accelerate
import Foundation
import Observation

@Observable
@MainActor
final class AudioVisualizationService {

    // MARK: - Published State

    /// 9-band smoothed energetic levels (0...1)
    private(set) var wave9: [Float] = Array(repeating: 0, count: 9)

    // MARK: - Internals

    private let processor = SpectrumProcessor()
    private var consumerId: UUID?
    private let hub = AudioAnalysisHub.shared

    // State Tracking
    private var isPlaying: Bool = false
    private var pauseStartTime: TimeInterval?

    // The "live" data directly from processor
    private var liveWave: [Float] = Array(repeating: 0, count: 9)

    // Scaling and Blending
    private var poseBlend: Float = 0.0  // 0.0 = Live, 1.0 = Idle Pose
    private let idlePattern: [Float] = [0.37, 0.20, 0.40, 0.20, 0.65, 0.20, 0.40, 0.20, 0.37]

    // Timers & Blending
    private var silenceTimer: Timer?
    private var lastDataTime: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0

    static let shared = AudioVisualizationService()
    private var activeRefs = 0

    private init() {}

    func updatePlaybackState(isPlaying: Bool) {
        self.isPlaying = isPlaying
        if isPlaying {
            pauseStartTime = nil
        } else if pauseStartTime == nil {
            pauseStartTime = Date().timeIntervalSinceReferenceDate
        }
    }

    func start() {
        activeRefs += 1
        guard activeRefs == 1 else { return }

        lastUpdateTime = Date().timeIntervalSinceReferenceDate
        hub.start()

        stopTimer()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let now = Date().timeIntervalSinceReferenceDate
                if now - self.lastDataTime > 0.12 {
                    // Feed empty to processor to let it decay naturally to 0 (for the 2s pause window)
                    let decayed = self.processor.process(
                        magnitudes: [], fftSize: 1024, sampleRate: 44100)
                    self.blendAndUpdate(newLiveLevels: decayed)
                } else {
                    // Just tick the blending logic
                    self.blendAndUpdate(newLiveLevels: nil)
                }
            }
        }

        consumerId = hub.addConsumer { [weak self] data in
            guard let self else { return }
            let levels = self.processor.process(
                magnitudes: data.magnitudes, fftSize: data.fftSize, sampleRate: data.sampleRate)

            Task { @MainActor in
                self.lastDataTime = Date().timeIntervalSinceReferenceDate
                self.blendAndUpdate(newLiveLevels: levels)
            }
        }
    }

    private func blendAndUpdate(newLiveLevels: [Float]?) {
        let now = Date().timeIntervalSinceReferenceDate
        let dt = Float(max(0.001, min(0.1, now - lastUpdateTime)))
        lastUpdateTime = now

        // 1. Update Live Wave if new data arrives
        if let newLive = newLiveLevels {
            liveWave = newLive
        }

        // 2. Idle Pose Trigger Logic (2 seconds threshold)
        var targetBlend: Float = 0.0
        if !isPlaying, let start = pauseStartTime, now - start >= 0.05 {
            targetBlend = 1.0
        }

        // 3. Pose Blend Smoothing (Fast transitions)
        // Transitions: 0 -> 1 (In) approx 0.3s, 1 -> 0 (Out) approx 0.2s
        let tau: Float = targetBlend > poseBlend ? 0.10 : 0.10
        let factor = 1.0 - exp(-dt / tau)
        poseBlend += (targetBlend - poseBlend) * factor

        // 4. Final Output Construction (LERP)
        for i in 0..<9 {
            let live = liveWave[i]
            let pose = idlePattern[i]
            wave9[i] = live + (pose - live) * poseBlend
        }
    }

    func stop() {
        activeRefs -= 1
        if activeRefs < 0 { activeRefs = 0 }

        guard activeRefs == 0 else { return }

        if let id = consumerId {
            hub.removeConsumer(id)
        }
        consumerId = nil
        hub.stop()
        stopTimer()
        wave9 = Array(repeating: 0, count: 9)
        liveWave = Array(repeating: 0, count: 9)
        poseBlend = 0.0
        pauseStartTime = nil
    }

    private func stopTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
}

// MARK: - Spectrum Processing

private final class SpectrumProcessor: @unchecked Sendable {

    struct Constants {
        // 1. Upstream Gains & Headroom
        static let inputGainDb: Float = -75.0  // Added to initial dB to shift everything down
        static let minDb: Float = -85.0
        static let maxDb: Float = -15.0  // Raised from -25 to increase headroom (less sensitive)

        static let tiltAmount: Float = 0.28  // Spectral tilt to dampen highs before balancer

        // 2. Balancers [inMin, inMax] for 9 bands
        // User requested ranges to prevent middle bands from pegging
        // Lower sensitivity for Mid bands (2..7)
        static let balancers: [(min: Float, max: Float)] = [
            (0.20, 0.73),  // 0: Sub (20-60Hz)
            (0.44, 0.85),  // 1: Bass (60-140Hz)
            (0.35, 0.88),  // 2: Low-Mid (140-260Hz)
            (0.24, 0.80),  // 3: Mid (260-420Hz)
            (0.08, 0.600),  // 4: Low-Treble (420-650Hz)
            (0.06, 0.580),  // 5: Mid-Treble (650-1000Hz)
            (0.01, 0.400),  // 6: High-Treble (1000-3500Hz)
            (0.00, 0.280),  // 7: High+ (3500-12000Hz)
            (0.00, 0.07),  // 8: Air (12000-20000Hz) - Very High Sensitivity
        ]

        // 3. Dynamics (Soft-Knee & Smoothing)
        static let lowBoost: Float = 1.28  // Boost sensitivity for low-level signals
        static let knee: Float = 0.68 // Knee point for transition to compression
        static let hard: Float = 0.33  // Compression strength for high-level signals
        static let cubicPower: Float = 3.0
        static let attack: Float = 0.35
        static let release: Float = 0.45
        // 4. Per-band Small Gates
        static let bandGates: [Float] = [
            0.01, 0.01, 0.01, 0.008, 0.008, 0.005, 0.005, 0.003, 0.003,
        ]
    }

    private let bandCount: Int = 9
    private var smoothedBands: [Float]

    init() {
        self.smoothedBands = [Float](repeating: 0, count: bandCount)
    }

    func reset() {
        for i in 0..<bandCount {
            smoothedBands[i] = 0
        }
    }

    func process(magnitudes: [Float], fftSize: Int, sampleRate: Float) -> [Float] {
        // 1. Per-bin Preprocessing (dB -> Scaled -> Tilt)
        let scaledBins = processBins(magnitudes: magnitudes)

        // 2. Per-band Energy Calculation (Average of scaledBins)
        let bandEnergy = computeBandsFromScaledBins(
            scaledBins: scaledBins, fftSize: fftSize, sampleRate: sampleRate)

        var result = [Float](repeating: 0, count: bandCount)

        // 3. Per-band Balancer + Soft-Knee + Smoothing
        for i in 0..<bandCount {
            let energy = bandEnergy[i]
            let bal = Constants.balancers[i]

            // Map energy to normalized range (unclamped)
            let x = max(0.0, (energy - bal.min) / (bal.max - bal.min))

            // Soft-Knee Dynamic Curve
            let y: Float
            if x <= Constants.knee {
                // Low-level: Power curve boost to increase sensitivity
                y = pow(x / Constants.knee, 0.7) * (Constants.knee * Constants.lowBoost)
            } else {
                // High-level: Exponential compression to prevent harsh clipping
                let t = x - Constants.knee
                y = Constants.knee + (1.0 - exp(-t / Constants.hard)) * (1.0 - Constants.knee)
            }

            var amplitude = min(1.0, max(0.0, y))

            // Cubic Expansion (Applied before smoothing)
            amplitude = pow(amplitude, Constants.cubicPower)

            // Gate check
            if amplitude < Constants.bandGates[i] { amplitude = 0 }

            // 4. Envelope Smoothing (Attack/Release)
            var current = smoothedBands[i]
            if amplitude > current {
                current += (amplitude - current) * Constants.attack
            } else {
                current += (amplitude - current) * Constants.release
            }
            smoothedBands[i] = current

            result[i] = current
        }

        return result
    }

    private func processBins(magnitudes: [Float]) -> [Float] {
        guard !magnitudes.isEmpty else { return [] }
        let count = magnitudes.count
        var scaledBins = [Float](repeating: 0, count: count)

        for i in 0..<count {
            // amp = sqrt(mag) if mag is |z|^2
            let mag = magnitudes[i]
            let db = 20 * log10(sqrt(mag) + 1e-7) + Constants.inputGainDb

            // Normalize to 0...1
            var scaled = (db - Constants.minDb) / (Constants.maxDb - Constants.minDb)
            scaled = min(1.0, max(0.0, scaled))

            // Spectral Tilt (simulating apple-audio-visualization logic)
            // tilt amount increases with frequency
            let progress = Float(i) / Float(count)
            let tilt = (0.4 + progress * 0.6) * Constants.tiltAmount
            scaled -= tilt

            scaledBins[i] = max(0.0, scaled)
        }
        return scaledBins
    }

    private func computeBandsFromScaledBins(scaledBins: [Float], fftSize: Int, sampleRate: Float)
        -> [Float]
    {
        guard !scaledBins.isEmpty else { return [Float](repeating: 0, count: bandCount) }

        let edges: [Float] = [20, 60, 140, 260, 420, 650, 1000, 3500, 12000, 20000]
        var bandEnergy = [Float](repeating: 0, count: bandCount)

        let binHz = sampleRate / Float(fftSize)
        let maxBin = scaledBins.count - 1

        for i in 0..<bandCount {
            let startHz = edges[i]
            let endHz = edges[i + 1]

            let startBin = min(maxBin, max(0, Int(startHz / binHz)))
            let endBin = min(maxBin, max(startBin + 1, Int(endHz / binHz)))

            if startBin >= endBin {
                bandEnergy[i] = 0
                continue
            }

            var sum: Float = 0
            for b in startBin..<endBin {
                sum += scaledBins[b]
            }
            bandEnergy[i] = sum / Float(endBin - startBin)
        }

        return bandEnergy
    }
}
