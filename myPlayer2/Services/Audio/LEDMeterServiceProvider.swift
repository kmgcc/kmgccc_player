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
/// In external playback mode, reads from the app-level simulator singleton.
@Observable
@MainActor
final class LEDMeterServiceProvider: AudioLevelMeterProtocol {

    private var _service: LEDMeterService?
    private let config: LEDMeterConfig
    private let mixerProvider: () -> AVAudioMixerNode
    private var externalPollTimer: Timer?
    private var externalPulse: UInt64 = 0

    /// Active sampling sessions. The provider keeps the underlying meter alive
    /// while at least one session is held (Now Playing scene, fullscreen,
    /// settings preview, …). On the last release the service is stopped but
    /// kept around for fast re-acquire — Now Playing's hard release goes
    /// through `releaseNowPlayingResources()`.
    private var sessionCount: Int = 0

    /// Metrics from the real service or the external simulator.
    var metrics: LEDMeterMetrics {
        if playbackSource.isExternal {
            _ = externalPulse
            return ExternalPlaybackSpectrumSimulator.shared.lastLedMetrics
        }
        return _service?.metrics ?? LEDMeterMetrics.zero(count: config.ledCount)
    }

    /// Audio metrics from the real service or the external simulator.
    var audioMetrics: AudioMetrics {
        if playbackSource.isExternal {
            _ = externalPulse
            return ExternalPlaybackSpectrumSimulator.shared.lastAudioMetrics
        }
        return _service?.audioMetrics ?? .zero
    }

    /// Normalized level from the real service or the external simulator.
    var normalizedLevel: Float {
        if playbackSource.isExternal {
            _ = externalPulse
            return ExternalPlaybackSpectrumSimulator.shared.lastAudioMetrics.smoothedLevel
        }
        return _service?.normalizedLevel ?? 0
    }

    /// Playback source used to decide between real meter and simulated meter.
    var playbackSource: PlaybackSource = .local {
        didSet {
            guard oldValue != playbackSource else { return }
            if playbackSource.isExternal {
                startExternalPolling()
            } else {
                stopExternalPolling()
            }
        }
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

    func start() {
        if playbackSource.isExternal {
            startExternalPolling()
        } else {
            _service?.start()
        }
    }

    func stop() {
        stopExternalPolling()
        _service?.stop()
    }

    func updatePlaybackState(isPlaying: Bool) {
        _service?.updatePlaybackState(isPlaying: isPlaying)
    }

    /// Force-drop nowPlaying-only heavy state without changing provider lifetime.
    ///
    /// Skin views and `NowPlayingHostView` call this to release the service
    /// when their own consumer disappears. If other consumers still hold a
    /// session (e.g. the LED settings preview), this is a no-op — they need
    /// the meter to keep sampling.
    func releaseNowPlayingResources() {
        guard sessionCount == 0 else { return }
        stopExternalPolling()
        _service?.stop()
        _service = nil
    }

    /// Reference-counted sampling session.
    /// Any view that needs the LED meter to be live (Now Playing, Fullscreen,
    /// Settings preview…) calls `acquireSession()` on appear and
    /// `releaseSession()` on disappear. The service stays running until the
    /// last session is released.
    func acquireSession() {
        sessionCount += 1
        let service = getOrCreate()
        service.start()
        if playbackSource.isExternal {
            startExternalPolling()
        }
    }

    func releaseSession() {
        guard sessionCount > 0 else { return }
        sessionCount -= 1
        guard sessionCount == 0 else { return }
        _service?.stop()
        stopExternalPolling()
    }

    /// Updates config on existing service or stores for future creation.
    func updateConfig(_ newConfig: LEDMeterConfig) {
        if let service = _service {
            service.updateConfig(newConfig)
        }
    }

    // MARK: - External Polling

    private func startExternalPolling() {
        guard externalPollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackSource.isExternal else { return }
                self.externalPulse &+= 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        externalPollTimer = timer
    }

    private func stopExternalPolling() {
        externalPollTimer?.invalidate()
        externalPollTimer = nil
    }
}
