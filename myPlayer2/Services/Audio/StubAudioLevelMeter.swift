//
//  StubAudioLevelMeter.swift
//  myPlayer2
//
//  kmgccc_player - Stub Audio Level Meter
//  Generates fake level data for LED animation preview.
//

import Foundation

/// Stub implementation of AudioLevelMeterProtocol.
/// Generates sinusoidal/noise level for LED preview.
@Observable
@MainActor
final class StubAudioLevelMeter: AudioLevelMeterProtocol {

    // MARK: - Published State

    private(set) var normalizedLevel: Float = 0
    private(set) var audioMetrics: AudioMetrics = .zero

    // MARK: - Private

    private var timer: Timer?
    private var phase: Double = 0
    private var isRunning: Bool = false

    // MARK: - Protocol Implementation

    func start() {
        guard !isRunning else { return }
        isRunning = true

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateLevel()
            }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        normalizedLevel = 0
    }

    // MARK: - Level Generation

    private func updateLevel() {
        // Generate a smooth wave pattern with some noise
        phase += 0.15

        // Base sine wave
        let sineValue = sin(phase)

        // Add harmonics for more interesting pattern
        let harmonic = sin(phase * 2.3) * 0.3
        let harmonic2 = sin(phase * 0.7) * 0.2

        // Random noise component
        let noise = Float.random(in: -0.1...0.1)

        // Combine and normalize to 0-1
        let combined = Float(sineValue + harmonic + harmonic2) + noise
        normalizedLevel = (combined + 1.5) / 3.0  // Map roughly -1.5...1.5 to 0...1
        normalizedLevel = max(0, min(1, normalizedLevel))
    }

}
