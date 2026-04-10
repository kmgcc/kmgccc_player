//
//  LEDMeterServiceProvider.swift
//  myPlayer2
//
//  kmgccc_player - LED Meter Service Provider (Lazy Initialization)
//  Wraps LEDMeterService to enable delayed creation while maintaining protocol compatibility.
//

import AVFoundation
import Foundation
import Observation

/// Provider that wraps LEDMeterService with lazy initialization.
/// Implements AudioLevelMeterProtocol with no-op defaults until the real service is created.
@Observable
@MainActor
final class LEDMeterServiceProvider: AudioLevelMeterProtocol {

    private var _service: LEDMeterService?
    private let config: LEDMeterConfig
    private let mixerProvider: () -> AVAudioMixerNode

    /// Metrics from the real service, or zero if not yet created
    var metrics: LEDMeterMetrics {
        _service?.metrics ?? LEDMeterMetrics.zero(count: config.ledCount)
    }

    /// Audio metrics from the real service, or zero if not yet created
    var audioMetrics: AudioMetrics {
        _service?.audioMetrics ?? .zero
    }

    /// Normalized level from the real service, or 0 if not yet created
    var normalizedLevel: Float {
        _service?.normalizedLevel ?? 0
    }

    /// Creates a provider that will lazily instantiate LEDMeterService when needed.
    /// - Parameters:
    ///   - config: Configuration for the LED meter
    ///   - mixerProvider: Closure that provides the mixer node when service is created
    init(config: LEDMeterConfig, mixerProvider: @escaping () -> AVAudioMixerNode) {
        self.config = config
        self.mixerProvider = mixerProvider
    }

    /// Gets the existing service or creates it if needed.
    /// Use this when you need the actual LEDMeterService instance (e.g., for environment injection).
    func getOrCreate() -> LEDMeterService {
        if let service = _service {
            return service
        }
        let service = LEDMeterService(config: config)
        service.attachToMixer(mixerProvider())
        _service = service
        Log.debug("LEDMeterService lazily initialized", category: .audio)
        return service
    }

    /// Returns the existing service without creating it.
    var existingService: LEDMeterService? {
        _service
    }

    // MARK: - AudioLevelMeterProtocol

    /// No-op if service not created. Real service handles actual start.
    func start() {
        _service?.start()
    }

    /// No-op if service not created.
    func stop() {
        _service?.stop()
    }

    /// Force-drop nowPlaying-only heavy state without changing provider lifetime.
    func releaseNowPlayingResources() {
        _service?.stop()
        _service = nil
    }

    /// Updates config on existing service or stores for future creation.
    func updateConfig(_ newConfig: LEDMeterConfig) {
        if let service = _service {
            service.updateConfig(newConfig)
        }
    }
}
