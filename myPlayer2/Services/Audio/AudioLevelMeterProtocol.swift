//
//  AudioLevelMeterProtocol.swift
//  myPlayer2
//
//  TrueMusic - Audio Level Meter Protocol
//  Provides normalized audio level for LED visualization.
//

import Foundation

/// Protocol for audio level metering.
/// Returns a single normalized level value for LED visualization.
///
/// Design Decision: Using single normalized value (Option A) because:
/// 1. The LED display maps to overall loudness, not frequency bands
/// 2. Simpler to implement with AVAudioEngine's tap
/// 3. UI maps the 0.0-1.0 value to 9 LEDs × 6 brightness levels internally
@MainActor
protocol AudioLevelMeterProtocol: AnyObject {

    /// Normalized audio level (0.0 to 1.0).
    /// UI will map this to LED visualization (9 LEDs × 6 brightness levels = 54 total steps).
    var normalizedLevel: Float { get }

    /// Start monitoring audio levels.
    func start()

    /// Stop monitoring audio levels.
    func stop()
}
