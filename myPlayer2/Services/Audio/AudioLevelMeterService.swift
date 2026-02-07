//
//  AudioLevelMeterService.swift
//  myPlayer2
//
//  TrueMusic - Real Audio Level Meter Service
//  Uses AVAudioEngine tap with RMS/peak energy detection.
//
//  Algorithm:
//  - RMS + peak mix for responsiveness
//  - Fixed attack/release smoothing
//  - Adjustable sensitivity only
//

import AVFoundation
import Accelerate
import Foundation

/// Real audio level meter with RMS/peak energy detection.
@Observable
@MainActor
final class AudioLevelMeterService: AudioLevelMeterProtocol {

    // MARK: - Published State

    /// Normalized level (0.0 to 1.0) for UI binding.
    private(set) var normalizedLevel: Float = 0

    /// Audio metrics (stub for this simpler service)
    var audioMetrics: AudioMetrics { .zero }

    // MARK: - Settings (adjustable via Settings UI)

    /// Overall sensitivity (0.5 to 2.0, default 1.0)
    var sensitivity: Float {
        get { AppSettings.shared.ledSensitivity }
        set { AppSettings.shared.ledSensitivity = newValue }
    }

    // MARK: - Engine Reference

    private weak var mixerNode: AVAudioMixerNode?
    private var isInstalled = false

    // MARK: - Internal State

    private let processor = AudioProcessor()

    // MARK: - Timer for UI updates

    private var updateTimer: Timer?
    private var smoothedLevel: Float = 0

    // MARK: - Initialization

    init() {
        print("📊 AudioLevelMeterService initialized (RMS/peak mix)")
    }

    // MARK: - Configuration

    /// Attach to an AVAudioEngine's mixer node for level metering.
    func attachToMixer(_ mixer: AVAudioMixerNode) {
        print("📊 Attaching level meter to mixer")
        self.mixerNode = mixer
    }

    // MARK: - Control

    func start() {
        guard !isInstalled else { return }
        guard let mixer = mixerNode else {
            print("⚠️ Level meter: No mixer attached")
            return
        }

        // Install tap on mixer output
        let format = mixer.outputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = 1024

        // Reset processor state
        processor.reset()

        // Capture processor strongly (it's a class instance), safe because it's @unchecked Sendable
        let processor = self.processor
        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, time in
            processor.process(buffer)
        }

        isInstalled = true

        // Start UI update timer (30 fps)
        startUpdateTimer()

        print("📊 Level meter started")
    }

    func stop() {
        guard isInstalled else { return }

        mixerNode?.removeTap(onBus: 0)
        isInstalled = false

        stopUpdateTimer()

        // Animate level back to zero
        Task { @MainActor in
            self.normalizedLevel = 0
            self.smoothedLevel = 0
            self.processor.rawLevel = 0
        }

        print("📊 Level meter stopped")
    }

    // MARK: - UI Update Timer

    private func startUpdateTimer() {
        stopUpdateTimer()

        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            self?.updateSmoothedLevel()
        }

        if let timer = updateTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func updateSmoothedLevel() {
        let target = processor.rawLevel

        // Calculate attack and release based on response speed
        let attackCoeff: Float = 0.45
        let releaseCoeff: Float = 0.08

        // Apply attack/release smoothing
        if target > smoothedLevel {
            // Attack (rising) - fast
            smoothedLevel += (target - smoothedLevel) * attackCoeff
        } else {
            // Release (falling) - slower
            smoothedLevel += (target - smoothedLevel) * releaseCoeff
        }

        if smoothedLevel < 0.02 { smoothedLevel = 0 }

        normalizedLevel = max(0, min(1, smoothedLevel))
    }
}

// MARK: - Audio Processor

/// Non-isolated audio processor to handle real-time audio buffers.
/// Marked @unchecked Sendable because we accept the data race on rawLevel (write background, read main).
/// In a production app, use OSAllocatedUnfairLock or Atomics.
private final class AudioProcessor: @unchecked Sendable {

    // Accessed from background audio thread (write) and main thread (read)
    // Protected by "benign race" assumption for visualization only, or use atomic if required.
    var rawLevel: Float = 0

    func reset() {
        rawLevel = 0
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        // Use first channel
        let samples = channelData[0]

        // RMS + Peak mix for responsiveness
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameLength))

        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameLength))

        let rmsDb = 20 * log10(max(rms, 0.000_001))
        let peakDb = 20 * log10(max(peak, 0.000_001))

        let rmsNorm = normalizeDb(rmsDb)
        let peakNorm = normalizeDb(peakDb)
        let combined = min(1, max(0, rmsNorm * 0.7 + peakNorm * 0.3))

        let scaled = combined * AppSettings.shared.ledSensitivity
        let compressed = 1 - exp(-scaled * 1.6)

        let gated = compressed < 0.02 ? 0 : compressed
        rawLevel = min(1.0, max(0.0, gated))
    }

    private func normalizeDb(_ db: Float) -> Float {
        let floor: Float = -70
        let ceil: Float = 0
        let normalized = (db - floor) / (ceil - floor)
        return min(1, max(0, normalized))
    }
}
