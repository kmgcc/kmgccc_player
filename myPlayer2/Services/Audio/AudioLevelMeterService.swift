//
//  AudioLevelMeterService.swift
//  myPlayer2
//
//  TrueMusic - Real Audio Level Meter Service
//  Uses AVAudioEngine tap with low-frequency weighted energy detection.
//
//  Algorithm:
//  - Simple low-pass filter for bass extraction (< 600Hz)
//  - Low frequency weighted heavily for "punch" detection
//  - Fast attack, slow release envelope for natural response
//  - Adjustable sensitivity and low-frequency weight
//

import AVFoundation
import Accelerate
import Foundation

/// Real audio level meter with low-frequency weighted energy detection.
@Observable
@MainActor
final class AudioLevelMeterService: AudioLevelMeterProtocol {

    // MARK: - Published State

    /// Normalized level (0.0 to 1.0) for UI binding.
    private(set) var normalizedLevel: Float = 0

    // MARK: - Settings (adjustable via Settings UI)

    /// Overall sensitivity (0.5 to 2.0, default 1.0)
    var sensitivity: Float {
        get { AppSettings.shared.ledSensitivity }
        set { AppSettings.shared.ledSensitivity = newValue }
    }

    /// Low frequency weight (0.0 to 1.0, default 0.7)
    /// Higher = more emphasis on bass/kick
    var lowFrequencyWeight: Float {
        get { AppSettings.shared.ledLowFrequencyWeight }
        set { AppSettings.shared.ledLowFrequencyWeight = newValue }
    }

    /// Response speed (0.0 to 1.0, default 0.5)
    /// Higher = faster attack and release
    var responseSpeed: Float {
        get { AppSettings.shared.ledResponseSpeed }
        set { AppSettings.shared.ledResponseSpeed = newValue }
    }

    // MARK: - Engine Reference

    private weak var mixerNode: AVAudioMixerNode?
    private var isInstalled = false

    // MARK: - Low-pass filter state

    private var lpfState: Float = 0  // Single-pole low-pass filter state
    private var sampleRate: Float = 44100

    // MARK: - Internal State

    private var smoothedLevel: Float = 0
    private var rawLevel: Float = 0

    // MARK: - Timer for UI updates

    private var updateTimer: Timer?

    // MARK: - Initialization

    init() {
        print("📊 AudioLevelMeterService initialized (low-freq weighted)")
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
        sampleRate = Float(format.sampleRate)
        let bufferSize: AVAudioFrameCount = 1024

        // Reset filter state
        lpfState = 0

        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) {
            [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }

        isInstalled = true

        // Start UI update timer (30 fps)
        startUpdateTimer()

        print("📊 Level meter started (sample rate: \(sampleRate)Hz)")
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
            self.rawLevel = 0
        }

        print("📊 Level meter stopped")
    }

    // MARK: - Audio Processing (Background Thread)

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        // Use first channel
        let samples = channelData[0]

        // Calculate full-band RMS
        var fullSum: Float = 0
        vDSP_svesq(samples, 1, &fullSum, vDSP_Length(frameLength))
        let fullRms = sqrt(fullSum / Float(frameLength))

        // Simple single-pole low-pass filter for bass extraction
        // Cutoff ~600Hz: alpha = 2 * pi * fc / (2 * pi * fc + sr)
        let cutoffHz: Float = 600
        let alpha = (2 * Float.pi * cutoffHz) / (2 * Float.pi * cutoffHz + sampleRate)

        // Apply low-pass filter and calculate low-band RMS
        var lowSum: Float = 0
        var lpfStateLocal = lpfState

        for i in 0..<frameLength {
            lpfStateLocal = lpfStateLocal + alpha * (samples[i] - lpfStateLocal)
            lowSum += lpfStateLocal * lpfStateLocal
        }

        lpfState = lpfStateLocal
        let lowRms = sqrt(lowSum / Float(frameLength))

        // Convert to dB and normalize
        let lowDb = 20 * log10(max(lowRms, 0.0001))
        let fullDb = 20 * log10(max(fullRms, 0.0001))

        // Normalize: -40dB to 0dB → 0 to 1 (tighter range for more dynamics)
        let lowNorm = (lowDb + 40) / 40
        let fullNorm = (fullDb + 40) / 40

        // Mix low and full energy based on weight
        let weight = lowFrequencyWeight
        let mixedEnergy = max(0, lowNorm) * weight + max(0, fullNorm) * (1.0 - weight)

        // Apply sensitivity
        let amplified = mixedEnergy * sensitivity

        // Apply soft compression to prevent constant saturation
        let compressed = tanh(amplified * 1.5) / tanh(1.5)

        // Store raw level
        rawLevel = min(1.0, max(0.0, compressed))
    }

    // MARK: - UI Update Timer

    private func startUpdateTimer() {
        stopUpdateTimer()

        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.updateSmoothedLevel()
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

    private func updateSmoothedLevel() {
        let target = rawLevel

        // Calculate attack and release based on response speed
        // responseSpeed 0.0 = slow, 1.0 = fast
        let speed = responseSpeed
        let attackCoeff = 0.2 + speed * 0.5  // 0.2 to 0.7
        let releaseCoeff = 0.05 + speed * 0.15  // 0.05 to 0.2

        // Apply attack/release smoothing
        if target > smoothedLevel {
            // Attack (rising) - fast
            smoothedLevel += (target - smoothedLevel) * attackCoeff
        } else {
            // Release (falling) - slower
            smoothedLevel += (target - smoothedLevel) * releaseCoeff
        }

        // Clamp and publish
        normalizedLevel = max(0, min(1, smoothedLevel))
    }
}
