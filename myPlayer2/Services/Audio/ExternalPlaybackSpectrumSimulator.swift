//
//  ExternalPlaybackSpectrumSimulator.swift
//  myPlayer2
//
//  kmgccc_player - External Playback Spectrum Simulator
//  Plays back pre-recorded app-chain spectrum frames from real audio (15s-35s of Tabata Wod).
//  Lifetime is NOT bound to any view, service, or provider.
//

import Foundation

/// Spectrum source for Apple Music / external playback.
/// Consumes offline-recorded app-chain spectrum frames and loops them at runtime.
/// Thread-safe snapshot for main-thread consumers.
nonisolated final class ExternalPlaybackSpectrumSimulator: @unchecked Sendable {

    static let shared = ExternalPlaybackSpectrumSimulator()

    private struct Constants {
        static let updateHz: Double = 30
        static let defaultLedCount = 11
    }

    // MARK: - Frame data (recorded from real app spectrum chain)

    private let fps = SpectrumFrameData.fps
    private let frameCount = SpectrumFrameData.frameCount
    private let waveBandCount = SpectrumFrameData.waveBandCount
    private let audioBandCount = SpectrumFrameData.audioBandCount
    private let waveformLength = SpectrumFrameData.waveformLength
    private let ledCount = SpectrumFrameData.ledCount

    // MARK: - Thread-safe snapshot

    private let lock = NSLock()
    private var _lastWave: [Float] = Array(repeating: 0, count: 9)
    private var _lastAudioMetrics: AudioMetrics = .zero
    private var _lastLedMetrics: LEDMeterMetrics = LEDMeterMetrics.zero(count: SpectrumFrameData.ledCount)

    var lastWave: [Float] {
        lock.lock(); defer { lock.unlock() }
        return _lastWave
    }

    var lastAudioMetrics: AudioMetrics {
        lock.lock(); defer { lock.unlock() }
        return _lastAudioMetrics
    }

    var lastLedMetrics: LEDMeterMetrics {
        lock.lock(); defer { lock.unlock() }
        return _lastLedMetrics
    }

    // MARK: - Runtime state

    private let queue = DispatchQueue(label: "ExternalPlaybackSpectrumSimulator", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var isPlaying = false

    private var time: Double = 0
    private var pauseDecay: Float = 1.0

    // MARK: - Lifecycle

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            self.startTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            self.time = 0
            self.pauseDecay = 1.0

            self.lock.lock()
            self._lastWave = Array(repeating: 0, count: self.waveBandCount)
            self._lastAudioMetrics = .zero
            self._lastLedMetrics = LEDMeterMetrics.zero(count: self.ledCount)
            self.lock.unlock()
        }
    }

    func setPlaying(_ playing: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isPlaying = playing
        }
    }

    // MARK: - Timer

    private func startTimer() {
        let interval = 1.0 / Constants.updateHz
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    // MARK: - Tick

    private func tick() {
        guard isRunning else { return }

        let dt = Float(1.0 / Constants.updateHz)

        if isPlaying {
            time += Double(dt)
            pauseDecay = 1.0
        } else {
            pauseDecay *= 0.88
        }

        let wave = sampleWave(at: time).map { $0 * pauseDecay }
        let audio = sampleAudio(at: time, decay: pauseDecay)
        let led = sampleLED(at: time, decay: pauseDecay)

        lock.lock()
        _lastWave = wave
        _lastAudioMetrics = audio
        _lastLedMetrics = led
        lock.unlock()
    }

    // MARK: - Frame sampling with linear interpolation

    private func sampleWave(at time: Double) -> [Float] {
        let totalDuration = Double(frameCount) / fps
        let loopedTime = time.truncatingRemainder(dividingBy: totalDuration)
        let rawIndex = loopedTime * fps
        let i0 = Int(rawIndex) % frameCount
        let i1 = (i0 + 1) % frameCount
        let frac = Float(rawIndex - Double(i0))

        var result = [Float](repeating: 0, count: waveBandCount)
        for b in 0..<waveBandCount {
            let v0 = SpectrumFrameData.waveFrames[i0 * waveBandCount + b]
            let v1 = SpectrumFrameData.waveFrames[i1 * waveBandCount + b]
            result[b] = v0 + (v1 - v0) * frac
        }
        return result
    }

    private func sampleLED(at time: Double, decay: Float) -> LEDMeterMetrics {
        let totalDuration = Double(frameCount) / fps
        let loopedTime = time.truncatingRemainder(dividingBy: totalDuration)
        let rawIndex = loopedTime * fps
        let i0 = Int(rawIndex) % frameCount
        let i1 = (i0 + 1) % frameCount
        let frac = Float(rawIndex - Double(i0))

        let level0 = SpectrumFrameData.ledLevels[i0]
        let level1 = SpectrumFrameData.ledLevels[i1]
        let level = (level0 + (level1 - level0) * frac) * decay

        var leds = [Float](repeating: 0, count: ledCount)
        for i in 0..<ledCount {
            let v0 = SpectrumFrameData.ledLeds[i0 * ledCount + i]
            let v1 = SpectrumFrameData.ledLeds[i1 * ledCount + i]
            leds[i] = (v0 + (v1 - v0) * frac) * decay
        }

        return LEDMeterMetrics(
            timestamp: Date().timeIntervalSinceReferenceDate,
            level: level,
            leds: leds
        )
    }

    private func sampleAudio(at time: Double, decay: Float) -> AudioMetrics {
        let totalDuration = Double(frameCount) / fps
        let loopedTime = time.truncatingRemainder(dividingBy: totalDuration)
        let rawIndex = loopedTime * fps
        let i0 = Int(rawIndex) % frameCount
        let i1 = (i0 + 1) % frameCount
        let frac = Float(rawIndex - Double(i0))

        let lerpScalar = { (arr: [Float]) -> Float in
            let v0 = arr[i0]
            let v1 = arr[i1]
            return v0 + (v1 - v0) * frac
        }

        let lerpArray = { (arr: [Float], count: Int) -> [Float] in
            var result = [Float](repeating: 0, count: count)
            for idx in 0..<count {
                let v0 = arr[i0 * count + idx]
                let v1 = arr[i1 * count + idx]
                result[idx] = v0 + (v1 - v0) * frac
            }
            return result
        }

        let smoothedLevel = lerpScalar(SpectrumFrameData.audioSmoothedLevel) * decay
        let rms = lerpScalar(SpectrumFrameData.audioRMS) * decay
        let peak = lerpScalar(SpectrumFrameData.audioPeak) * decay
        let bassEnergy = lerpScalar(SpectrumFrameData.audioBassEnergy) * decay
        let transientLevel = lerpScalar(SpectrumFrameData.audioTransientLevel) * decay
        let kickPulse = lerpScalar(SpectrumFrameData.audioKickPulse) * decay
        let lowBandLoudness = lerpScalar(SpectrumFrameData.audioLowBandLoudness) * decay

        // dB fields remain on log scale; not multiplied by decay
        let db = lerpScalar(SpectrumFrameData.audioDb)
        let midEnergy = lerpScalar(SpectrumFrameData.audioMidEnergy)
        let lowBandDb = lerpScalar(SpectrumFrameData.audioLowBandDb)

        let bands = lerpArray(SpectrumFrameData.audioBands, audioBandCount).map { $0 * decay }
        let smoothedBands = lerpArray(SpectrumFrameData.audioSmoothedBands, audioBandCount).map { $0 * decay }
        let waveform = lerpArray(SpectrumFrameData.audioWaveform, waveformLength).map { $0 * decay }

        return AudioMetrics(
            rms: rms,
            peak: peak,
            db: db,
            bands: bands,
            smoothedBands: smoothedBands,
            smoothedLevel: smoothedLevel,
            bassEnergy: bassEnergy,
            waveform: waveform,
            transientLevel: transientLevel,
            midEnergy: midEnergy,
            lowBandDb: lowBandDb,
            lowBandLoudness: lowBandLoudness,
            kickPulse: kickPulse
        )
    }
}
