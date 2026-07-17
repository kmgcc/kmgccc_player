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
    typealias FrameConsumer = @MainActor (_ led: LEDMeterMetrics, _ audio: AudioMetrics) -> Void

    private var _service: LEDMeterService?
    private var config: LEDMeterConfig
    private let mixerProvider: () -> AVAudioMixerNode
    private var externalPollTimer: Timer?
    private var externalPulse: UInt64 = 0
    private var externalIsPlaying: Bool = false
    private var externalPollSuspendWork: DispatchWorkItem?
    private var lastObservedPlaying: Bool = false
    private var frameConsumers: [UUID: FrameConsumer] = [:]
    private var serviceFrameConsumerID: UUID?
    private var visibilityLeaseID: UUID?

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
            let simLed = ExternalPlaybackSpectrumSimulator.shared.lastLedMetrics
            return LEDMeterMetrics(
                timestamp: simLed.timestamp,
                level: simLed.level,
                leds: adaptLEDValues(simLed.leds, toCount: config.ledCount)
            )
        }
        let serviceLed = _service?.metrics ?? LEDMeterMetrics.zero(count: config.ledCount)
        if serviceLed.leds.count == config.ledCount {
            return serviceLed
        } else {
            return LEDMeterMetrics(
                timestamp: serviceLed.timestamp,
                level: serviceLed.level,
                leds: adaptLEDValues(serviceLed.leds, toCount: config.ledCount)
            )
        }
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
                detachServiceFrameConsumer()
                _service?.stop()
                _service = nil
            } else {
                stopExternalPolling()
            }
            syncActiveState()
            syncFrameConsumerForwarder()
            publishFrameToConsumers()
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
    func getOrCreate() -> LEDMeterService? {
        if playbackSource.isExternal {
            return nil
        }
        if let service = _service {
            return service
        }
        let service = LEDMeterService(config: config)
        service.attachToMixer(mixerProvider())
        service.updatePlaybackState(isPlaying: lastObservedPlaying)
        _service = service
        if !frameConsumers.isEmpty {
            attachServiceFrameConsumer(to: service)
        }
        Log.debug("LEDMeterService lazily initialized - playbackSource isExternal: \(playbackSource.isExternal)", category: .audio)
        return service
    }

    /// Returns the existing service without creating it.
    var existingService: LEDMeterService? {
        _service
    }

    // MARK: - AudioLevelMeterProtocol

    func start() {
        // Playback intent alone is not visibility demand. A real view session or
        // frame consumer is required before the meter/FFT chain can run.
        syncActiveState()
    }

    func stop() {
        syncActiveState()
    }

    func updatePlaybackState(isPlaying: Bool) {
        lastObservedPlaying = isPlaying
        _service?.updatePlaybackState(isPlaying: isPlaying)
        externalIsPlaying = isPlaying
        // Idle-CPU (external mode): the 30Hz pulse only exists to re-read the
        // simulator's changing frames. While paused, the simulator idle-suspends
        // to a frozen frame, so stop the pulse after a short settle (lets the LED
        // show the fade-out first) and restart it on resume.
        guard playbackSource.isExternal else { return }
        if isPlaying {
            startExternalPolling()
        } else {
            scheduleExternalPollingSuspend()
        }
    }

    /// Force-drop nowPlaying-only heavy state without changing provider lifetime.
    ///
    /// Skin views and `NowPlayingHostView` call this to release the service
    /// when their own consumer disappears. If other consumers still hold a
    /// session (e.g. the LED settings preview), this is a no-op — they need
    /// the meter to keep sampling.
    func releaseNowPlayingResources() {
        guard !hasVisibleConsumers else { return }
        stopExternalPolling()
        detachServiceFrameConsumer()
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
        syncActiveState()
    }

    func releaseSession() {
        guard sessionCount > 0 else { return }
        sessionCount -= 1
        syncActiveState()
    }

    private func syncActiveState() {
        let shouldBeRunning = hasVisibleConsumers
        if shouldBeRunning {
            if visibilityLeaseID == nil {
                visibilityLeaseID = AudioVisualizationVisibilityRegistry.shared.acquire(.ledMeter)
            }
            if playbackSource.isExternal {
                startExternalPolling()
            } else {
                if let service = getOrCreate() {
                    service.start()
                    service.updatePlaybackState(isPlaying: lastObservedPlaying)
                }
            }
        } else {
            _service?.stop()
            stopExternalPolling()
            if let visibilityLeaseID {
                AudioVisualizationVisibilityRegistry.shared.release(visibilityLeaseID)
                self.visibilityLeaseID = nil
            }
        }
    }

    private var hasVisibleConsumers: Bool {
        sessionCount > 0 || !frameConsumers.isEmpty
    }

    /// Updates config on existing service or stores for future creation.
    func updateConfig(_ newConfig: LEDMeterConfig) {
        self.config = newConfig
        if let service = _service {
            service.updateConfig(newConfig)
        }
    }

    private func adaptLEDValues(_ src: [Float], toCount targetCount: Int) -> [Float] {
        let N = src.count
        guard N > 0 else { return [Float](repeating: 0, count: targetCount) }
        if N == targetCount { return src }
        
        var target = [Float](repeating: 0, count: targetCount)
        let srcCenter = Double(N - 1) / 2.0
        let targetCenter = Double(targetCount - 1) / 2.0
        
        for j in 0..<targetCount {
            let d: Double
            if targetCenter > 0 {
                d = abs(Double(j) - targetCenter) / targetCenter
            } else {
                d = 0
            }
            
            let srcIdx: Double
            if Double(j) < targetCenter {
                srcIdx = srcCenter - d * srcCenter
            } else {
                srcIdx = srcCenter + d * srcCenter
            }
            
            let idx0 = Int(floor(srcIdx))
            let idx1 = Int(ceil(srcIdx))
            let frac = Float(srcIdx - Double(idx0))
            
            let v0 = src[max(0, min(N - 1, idx0))]
            let v1 = src[max(0, min(N - 1, idx1))]
            target[j] = v0 + (v1 - v0) * frac
        }
        return target
    }

    // MARK: - Frame Consumers

    func addFrameConsumer(_ consumer: @escaping FrameConsumer) -> UUID {
        let id = UUID()
        frameConsumers[id] = consumer
        consumer(metrics, audioMetrics)
        syncActiveState()
        syncFrameConsumerForwarder()
        return id
    }

    func removeFrameConsumer(_ id: UUID) {
        frameConsumers.removeValue(forKey: id)
        syncFrameConsumerForwarder()
        syncActiveState()
    }

    private func syncFrameConsumerForwarder() {
        guard !frameConsumers.isEmpty else {
            detachServiceFrameConsumer()
            return
        }

        if playbackSource.isExternal {
            detachServiceFrameConsumer()
            startExternalPolling()
            return
        }

        if let service = getOrCreate() {
            attachServiceFrameConsumer(to: service)
        }
    }

    private func attachServiceFrameConsumer(to service: LEDMeterService) {
        guard serviceFrameConsumerID == nil else { return }
        serviceFrameConsumerID = service.addFrameConsumer { [weak self] led, audio in
            self?.publishFrameToConsumers(led: led, audio: audio)
        }
    }

    private func detachServiceFrameConsumer() {
        guard let id = serviceFrameConsumerID else { return }
        _service?.removeFrameConsumer(id)
        serviceFrameConsumerID = nil
    }

    private func publishFrameToConsumers(
        led: LEDMeterMetrics? = nil,
        audio: AudioMetrics? = nil
    ) {
        guard !frameConsumers.isEmpty else { return }
        var resolvedLED = led ?? metrics
        if resolvedLED.leds.count != config.ledCount {
            resolvedLED = LEDMeterMetrics(
                timestamp: resolvedLED.timestamp,
                level: resolvedLED.level,
                leds: adaptLEDValues(resolvedLED.leds, toCount: config.ledCount)
            )
        }
        let resolvedAudio = audio ?? audioMetrics
        for consumer in frameConsumers.values {
            consumer(resolvedLED, resolvedAudio)
        }
    }

    // MARK: - External Polling

    private func startExternalPolling() {
        externalPollSuspendWork?.cancel()
        externalPollSuspendWork = nil
        guard externalPollTimer == nil else { return }
        guard hasVisibleConsumers else { return }
        // While externally paused the simulator output is frozen, so there is
        // nothing new to re-read — skip the 30Hz pulse. The static frame is
        // still read once on the next SwiftUI evaluation.
        guard externalIsPlaying else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackSource.isExternal else { return }
                self.externalPulse &+= 1
                self.publishFrameToConsumers()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        externalPollTimer = timer
    }

    /// Stop the pulse a short while after pause so the LED can show the
    /// simulator's fade-out before the re-read loop goes idle.
    private func scheduleExternalPollingSuspend() {
        externalPollSuspendWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.playbackSource.isExternal, !self.externalIsPlaying else { return }
            self.stopExternalPolling()
        }
        externalPollSuspendWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func stopExternalPolling() {
        externalPollSuspendWork?.cancel()
        externalPollSuspendWork = nil
        externalPollTimer?.invalidate()
        externalPollTimer = nil
    }
}
