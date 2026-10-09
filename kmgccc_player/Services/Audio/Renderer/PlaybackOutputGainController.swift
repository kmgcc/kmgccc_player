import Foundation

nonisolated struct AudioTransportTransitionState: Codable, Equatable, Sendable {
    var desiredTransport: String
    var actualPlaying: Bool
    var phase: String
    var envelopeGain: Double
}

/// Owned exclusively by the renderer queue. The high frequency timer exists
/// only while a transport transition is active.
nonisolated final class PlaybackOutputGainController: @unchecked Sendable {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private(set) var envelope = 1.0
    private var masterGain = 1.0
    private var actualPlaying = false
    private(set) var desiredPlaying = false
    private var phase = "idle"
    private var lastPublicationTime = 0.0
    private var transitionStartTime: Double?
    var writeGain: ((Float) -> Void)?
    var publish: ((AudioTransportTransitionState) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }
    deinit { timer?.cancel() }

    var outputGain: Float { Float(masterGain * envelope) }

    func restore(write: (Float) -> Void) { write(outputGain) }

    func setMaster(_ value: Double) {
        masterGain = value.isFinite ? min(1, max(0, value)) : 0
        writeGain?(outputGain)
    }

    func reset(playing: Bool, envelope value: Double? = nil, publish shouldPublish: Bool = true) {
        cancel()
        actualPlaying = playing
        desiredPlaying = playing
        envelope = value ?? (playing ? 1 : 0)
        phase = "idle"
        writeGain?(outputGain)
        if shouldPublish { publishState() }
    }

    func transition(
        playing: Bool,
        configuration: AudioFadeConfiguration,
        startWhen: @escaping @Sendable () -> Bool = { true },
        completion: @escaping @Sendable () -> Void
    ) {
        cancel()
        desiredPlaying = playing
        // A paused timebase starts before fade-in; pause commits after fade-out.
        if playing { actualPlaying = true }
        let target = playing ? 1.0 : 0.0
        let duration = configuration.enabled
            ? (playing ? configuration.playFadeMs : configuration.pauseFadeMs) / 1000 : 0
        guard duration > 0, abs(envelope - target) > 1e-12 else {
            envelope = target
            actualPlaying = playing
            phase = "idle"
            writeGain?(outputGain)
            completion()
            publishState()
            return
        }
        let token = generation
        let start = envelope
        let floorDB = configuration.floorDB
        transitionStartTime = startWhen() ? ProcessInfo.processInfo.systemUptime : nil
        phase = transitionStartTime == nil ? "waitingForAudio" : (playing ? "fadingIn" : "fadingOut")
        publishState()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            if self.transitionStartTime == nil {
                guard startWhen() else { return }
                self.transitionStartTime = ProcessInfo.processInfo.systemUptime
                self.phase = playing ? "fadingIn" : "fadingOut"
                self.publishState()
            }
            guard let startTime = self.transitionStartTime else { return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - startTime) / duration)
            self.envelope = Self.envelopeGain(start: start, target: target, progress: progress, floorDB: floorDB)
            self.writeGain?(self.outputGain)
            if progress >= 1 {
                self.cancel()
                self.actualPlaying = playing
                self.phase = "idle"
                completion()
            }
            if progress >= 1 || ProcessInfo.processInfo.systemUptime - self.lastPublicationTime >= 0.05 {
                self.publishState()
            }
        }
        timer = source
        source.resume()
    }

    static func envelopeGain(start: Double, target: Double, progress: Double, floorDB: Double) -> Double {
        if progress <= 0 { return start }
        if progress >= 1 { return target }
        let u = min(1, max(0, progress))
        let smooth = u * u * (3 - 2 * u)
        let startDB = start > 0 ? max(floorDB, 20 * log10(start)) : floorDB
        let targetDB = target > 0 ? max(floorDB, 20 * log10(target)) : floorDB
        return pow(10, (startDB + (targetDB - startDB) * smooth) / 20)
    }

    private func cancel() {
        generation = UUID()
        transitionStartTime = nil
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func publishState() {
        lastPublicationTime = ProcessInfo.processInfo.systemUptime
        publish?(AudioTransportTransitionState(
            desiredTransport: desiredPlaying ? "playing" : "paused",
            actualPlaying: actualPlaying, phase: phase, envelopeGain: envelope
        ))
    }
}
