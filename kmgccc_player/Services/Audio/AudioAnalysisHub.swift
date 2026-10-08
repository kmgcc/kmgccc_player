//
//  AudioAnalysisHub.swift
//  myPlayer2
//
//  kmgccc_player - Audio Analysis Hub
//  Centralized renderer PCM and FFT processing.
//  Provides raw FFT magnitudes to consumers (LED Meter, Waveform, etc.).
//

import Accelerate
import Foundation

/// Raw FFT data provided to consumers.
nonisolated public struct AudioAnalysisData: Sendable {
    /// Latest unwindowed mono PCM analysis window, oldest sample first. This is
    /// a visualisation feed, not a lossless recording stream.
    public let pcmSamples: [Float]
    public let hostTime: Double
    public let magnitudes: [Float]  // Frequency domain (0...Nyquist)
    public let sampleRate: Float
    public let fftSize: Int
    // Pre-calculated metrics over the full FFT window (~46ms). Cheap; kept for
    // spectrum / dB consumers that want a stable averaged level.
    public let rms: Float
    public let peak: Float
    // Low-latency time-domain envelope over only the most recent `fastWindow`
    // samples (~12ms). LED / volume / bass-pulse consumers read these so a
    // transient lights up without waiting for the full 2048-sample average.
    public let fastRMS: Float
    public let fastPeak: Float
    public let fastWindow: Int
}

nonisolated public final class AudioAnalysisHub: @unchecked Sendable {

    private let processingQueue = DispatchQueue(
        label: "AudioAnalysisHub.processing",
        qos: .utility
    )
    private let processingQueueKey = DispatchSpecificKey<Void>()

    private let fftSize: Int = 2048
    // Window (in samples) for the low-latency time-domain envelope (fastRMS /
    // fastPeak). 512 @ 44.1kHz ≈ 11.6ms — short enough that a kick/snare
    // transient drives the LED meter almost immediately instead of being
    // diluted across the 46ms FFT window.
    private let fastEnvelopeWindow: Int = 512
    private nonisolated(unsafe) var window: [Float]
    private nonisolated(unsafe) var fftSetup: FFTSetup?
    private nonisolated(unsafe) var log2n: vDSP_Length = 0
    // Ring buffer for input samples
    private nonisolated(unsafe) var ringBuffer: [Float]
    private nonisolated(unsafe) var writeIndex: Int = 0
    private let ringLock = NSLock()

    // Processing state
    private nonisolated(unsafe) var fftInput: [Float]
    private nonisolated(unsafe) var fftReal: [Float]
    private nonisolated(unsafe) var fftImag: [Float]
    private nonisolated(unsafe) var fftMagnitudes: [Float]
    private nonisolated(unsafe) var sampleRate: Float = 44100

    // Consumers
    private nonisolated(unsafe) var consumers: [UUID: @Sendable (AudioAnalysisData) -> Void] = [:]
    private let consumerLock = NSLock()
#if DEBUG
    /// Read-only runtime acceptance telemetry; includes all App consumers.
    var skinDebugConsumerCount: Int {
        consumerLock.lock()
        defer { consumerLock.unlock() }
        return consumers.count
    }
#endif
    private nonisolated(unsafe) var timer: DispatchSourceTimer?
    private nonisolated(unsafe) var activeClients: Int = 0
    private nonisolated(unsafe) var droppedRendererBuffers: UInt64 = 0
    private nonisolated(unsafe) var skippedProcessReads: UInt64 = 0
    private nonisolated(unsafe) var processedFrames: UInt64 = 0
    private nonisolated(unsafe) var lastDiagnosticsDumpUptime: TimeInterval = 0
    private nonisolated(unsafe) var lastSampleBusWarningUptime: TimeInterval = 0
    private nonisolated(unsafe) var consecutiveDroppedDiagnosticWindows: Int = 0
    private nonisolated(unsafe) var consecutiveSkippedDiagnosticWindows: Int = 0
    private nonisolated(unsafe) var consecutiveNoProcessedFrameWindows: Int = 0

    // Serializes renderer feed enablement with PCM enqueueing and timer state.
    private let stateLock = NSLock()

    // Config
    nonisolated(unsafe) var targetHz: Int = 30

    // Idle-CPU gating: the FFT `process()` timer only runs while playback is
    // active (plus a short linger so meters can settle to silence). All fields
    // are mutated only under `stateLock`.
    private nonisolated(unsafe) var isPlaying = false
    private nonisolated(unsafe) var pauseLingerActive = false
    private nonisolated(unsafe) var pauseLingerGeneration: UInt64 = 0
    /// The active renderer timeline supplies PCM directly to this hub.
    private nonisolated(unsafe) var isRendererFeedEnabled = false
    private static let pauseLingerSeconds: TimeInterval = 0.45
    private static let sampleBusDiagnosticsInterval: TimeInterval = 2.0
    private static let sampleBusWarningThrottle: TimeInterval = 10.0
    private static let minorDroppedRendererBufferThreshold: UInt64 = 4
    private static let minorSkippedProcessReadThreshold: UInt64 = 10
    private static let sustainedDroppedRendererBufferThreshold: UInt64 = 12
    private static let sustainedDroppedRendererBufferWindows = 2
    private static let skippedProcessReadWindowThreshold: UInt64 = 20
    private static let skippedProcessReadWarningWindows = 3
    private static let skippedProcessReadBurstThreshold: UInt64 = 60
    private static let noProcessedFrameWarningWindows = 3

    public static let shared = AudioAnalysisHub()

    init() {
        self.window = [Float](repeating: 0, count: fftSize)
        self.ringBuffer = [Float](repeating: 0, count: fftSize * 4)
        self.fftInput = [Float](repeating: 0, count: fftSize)
        self.fftReal = [Float](repeating: 0, count: fftSize / 2)
        self.fftImag = [Float](repeating: 0, count: fftSize / 2)
        self.fftMagnitudes = [Float](repeating: 0, count: fftSize / 2)

        processingQueue.setSpecific(key: processingQueueKey, value: ())
        rebuildFFT()
    }

    deinit {
        timer?.cancel()
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func start() {
        stateLock.lock()
        activeClients += 1
        stateLock.unlock()
        updateTimerState()
    }

    func stop() {
        stateLock.lock()
        activeClients = max(0, activeClients - 1)
        let shouldPurge = !hasActiveSamplingDemandLocked()
        stateLock.unlock()
        updateTimerState()
        if shouldPurge {
            purgeInactiveState()
        }
    }

    // MARK: - Consumer API

    func addConsumer(_ callback: @escaping @Sendable (AudioAnalysisData) -> Void) -> UUID {
        let id = UUID()
        consumerLock.lock()
        consumers[id] = callback
        consumerLock.unlock()
        updateTimerState()
        return id
    }

    func removeConsumer(_ id: UUID) {
        consumerLock.lock()
        consumers.removeValue(forKey: id)
        consumerLock.unlock()
        updateTimerState()
    }

    // MARK: - Internal Processing

    /// Feed renderer-timed canonical PCM into the existing FFT/ring-buffer
    /// owner. RendererPlaybackPipeline schedules these calls against its output
    /// clock, so eagerly decoded buffers do not make visualizers run ahead by
    /// the renderer's entire prebuffer window.
    nonisolated func enqueueRendererPCM(_ pcm: CanonicalPCM) {
        guard pcm.frames > 0,
              pcm.channelCount > 0,
              pcm.data.count >= pcm.frames * pcm.channelCount else { return }

        stateLock.lock()
        guard isRendererFeedEnabled else {
            stateLock.unlock()
            return
        }

        // The renderer still schedules analysis callbacks when the visualizer
        // is disabled. Skip the copy when no consumer can observe the samples.
        consumerLock.lock()
        let hasConsumers = !consumers.isEmpty
        consumerLock.unlock()
        guard hasConsumers else {
            stateLock.unlock()
            return
        }

        guard ringLock.try() else {
            droppedRendererBuffers &+= 1
            stateLock.unlock()
            return
        }
        sampleRate = Float(pcm.sampleRate)

        let capacity = ringBuffer.count
        ringBuffer.withUnsafeMutableBufferPointer { destination in
            guard let destinationBase = destination.baseAddress else { return }
            pcm.data.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress else { return }

                if pcm.channelCount == 1 {
                    if pcm.frames > capacity {
                        let sourceOffset = pcm.frames - capacity
                        let finalWriteIndex = (writeIndex + pcm.frames) % capacity
                        let firstCount = min(capacity - finalWriteIndex, capacity)
                        destinationBase
                            .advanced(by: finalWriteIndex)
                            .update(
                                from: sourceBase.advanced(by: sourceOffset),
                                count: firstCount
                            )
                        if firstCount < capacity {
                            destinationBase.update(
                                from: sourceBase.advanced(by: sourceOffset + firstCount),
                                count: capacity - firstCount
                            )
                        }
                        writeIndex = finalWriteIndex
                        return
                    }

                    let firstCount = min(pcm.frames, capacity - writeIndex)
                    destinationBase
                        .advanced(by: writeIndex)
                        .update(from: sourceBase, count: firstCount)
                    if firstCount < pcm.frames {
                        destinationBase.update(
                            from: sourceBase.advanced(by: firstCount),
                            count: pcm.frames - firstCount
                        )
                    }
                    writeIndex = (writeIndex + pcm.frames) % capacity
                    return
                }

                if pcm.channelCount == 2 {
                    var sourcePointer = sourceBase
                    var destinationIndex = writeIndex
                    for _ in 0..<pcm.frames {
                        destination[destinationIndex] = (sourcePointer[0] + sourcePointer[1]) * 0.5
                        sourcePointer = sourcePointer.advanced(by: 2)
                        destinationIndex += 1
                        if destinationIndex >= capacity {
                            destinationIndex = 0
                        }
                    }
                    writeIndex = destinationIndex
                    return
                }

                var sourcePointer = sourceBase
                var destinationIndex = writeIndex
                for _ in 0..<pcm.frames {
                    let sample: Float
                    if pcm.channelCount >= 2 {
                        sample = (sourcePointer[0] + sourcePointer[1]) * 0.5
                    } else {
                        sample = sourcePointer.pointee
                    }
                    destination[destinationIndex] = sample
                    sourcePointer = sourcePointer.advanced(by: pcm.channelCount)
                    destinationIndex += 1
                    if destinationIndex >= capacity {
                        destinationIndex = 0
                    }
                }
                writeIndex = destinationIndex
            }
        }
        ringLock.unlock()
        stateLock.unlock()
    }

    private func resetBuffer() {
        ringLock.lock()
        writeIndex = 0
        ringBuffer.withUnsafeMutableBufferPointer { ptr in
            ptr.initialize(repeating: 0)
        }
        ringLock.unlock()
    }

    // MARK: - Playback-state gating

    /// Enables renderer PCM input and clears samples from the previous timeline.
    func enableRendererFeed() {
        stateLock.lock()
        isRendererFeedEnabled = false
        stateLock.unlock()
        syncOnProcessingQueue {
            resetBuffer()
        }
        stateLock.lock()
        isRendererFeedEnabled = true
        stateLock.unlock()
        updateTimerState()
    }

    /// Disables renderer input and clears the previous timeline's samples.
    func disableRendererFeed() {
        stateLock.lock()
        isRendererFeedEnabled = false
        stateLock.unlock()
        syncOnProcessingQueue {
            resetBuffer()
        }
        updateTimerState()
    }

    /// Drives whether the FFT `process()` timer runs. When playback pauses, the
    /// timer keeps running for a short linger (so meters fade to silence), then
    /// suspends — no FFT on silent buffers while paused. Resume restarts it
    /// immediately. Safe to call repeatedly and from any thread.
    func setPlaying(_ playing: Bool) {
        stateLock.lock()
        if playing {
            // Always re-evaluate the timer on a play signal, even when already
            // marked playing. `updateTimerState()` is idempotent — it starts the
            // timer only if it should run and isn't already — so a redundant
            // `setPlaying(true)` self-heals a chain whose timer was left stopped
            // by a teardown / feed-change / resume race.
            isPlaying = true
            pauseLingerActive = false
            pauseLingerGeneration &+= 1
            stateLock.unlock()
            updateTimerState()
        } else {
            if !isPlaying {
                stateLock.unlock()
                return
            }
            isPlaying = false
            pauseLingerActive = true
            pauseLingerGeneration &+= 1
            let generation = pauseLingerGeneration
            stateLock.unlock()
            updateTimerState()  // keep running through the linger window
            processingQueue.asyncAfter(deadline: .now() + Self.pauseLingerSeconds) { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                guard generation == self.pauseLingerGeneration, self.isPlaying == false else {
                    self.stateLock.unlock()
                    return
                }
                self.pauseLingerActive = false
                self.stateLock.unlock()
                self.updateTimerState()
            }
        }
    }

    /// Helper to check if any consumers or active clients exist.
    /// Caller MUST hold `stateLock`.
    private func hasActiveSamplingDemandLocked() -> Bool {
        consumerLock.lock()
        defer { consumerLock.unlock() }
        return !consumers.isEmpty || activeClients > 0
    }

    /// Starts/stops the process timer to match the desired run state. Acquires
    /// `stateLock`; never call while already holding it.
    private func updateTimerState() {
        stateLock.lock()
        let hasConsumers = hasActiveSamplingDemandLocked()
        let inputAvailable = isRendererFeedEnabled
        let shouldRun = inputAvailable && hasConsumers && (isPlaying || pauseLingerActive)
        if shouldRun {
            if timer == nil { startTimer() }
        } else if timer != nil {
            stopTimer()
        }
        stateLock.unlock()
    }

    private func startTimer() {
        stopTimer()
        let interval = 1.0 / Double(targetHz)
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.process()
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func purgeInactiveState() {
        // `stop()` can be called from the main actor (LEDMeterService) or from
        // another visualization queue. Cancelling the timer does not wait for a
        // `process()` invocation that is already running, so replacing FFT
        // storage here would race that invocation and can crash in libswiftCore.
        syncOnProcessingQueue {
            stateLock.lock()
            guard !hasActiveSamplingDemandLocked() else {
                stateLock.unlock()
                return
            }
            resetBuffer()
            fftInput = [Float](repeating: 0, count: fftSize)
            fftReal = [Float](repeating: 0, count: fftSize / 2)
            fftImag = [Float](repeating: 0, count: fftSize / 2)
            fftMagnitudes = [Float](repeating: 0, count: fftSize / 2)
            sampleRate = 44_100
            stateLock.unlock()
        }
    }

    private func syncOnProcessingQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: processingQueueKey) != nil {
            work()
        } else {
            processingQueue.sync(execute: work)
        }
    }

    nonisolated private func process() {
        // 1. Read latest window from ring buffer
        guard ringLock.try() else {
            skippedProcessReads &+= 1
            dumpDiagnosticsIfNeeded()
            return
        }
        let capacity = ringBuffer.count
        // Read backward from writeIndex
        var readIdx = writeIndex - fftSize
        if readIdx < 0 { readIdx += capacity }

        for i in 0..<fftSize {
            fftInput[i] = ringBuffer[readIdx]
            readIdx += 1
            if readIdx >= capacity { readIdx = 0 }
        }
        let currentSampleRate = sampleRate
        ringLock.unlock()  // Release lock ASAP

        let pcmSamples = fftInput

        // 1b. Remove DC offset BEFORE metrics and windowing. Decoded music usually
        // has negligible DC, but any residual offset would concentrate in bin 0
        // and leak into the Sub band (20-60Hz), spuriously energizing the lowest
        // capsule. vDSP mean + subtract over 2048 floats is a few microseconds.
        var dcMean: Float = 0
        vDSP_meanv(fftInput, 1, &dcMean, vDSP_Length(fftSize))
        if dcMean != 0 {
            var negDc = Float(-dcMean)
            vDSP_vsadd(fftInput, 1, &negDc, &fftInput, 1, vDSP_Length(fftSize))
        }

        // 2. Pre-calculate metrics (Time Domain).
        // Done BEFORE windowing so the envelope reflects the raw signal level.
        var rms: Float = 0
        vDSP_rmsqv(fftInput, 1, &rms, vDSP_Length(fftSize))
        var peak: Float = 0
        vDSP_maxmgv(fftInput, 1, &peak, vDSP_Length(fftSize))

        // 2b. Low-latency envelope over only the most recent samples. fftInput is
        // ordered oldest→newest (fftInput[fftSize-1] is the freshest sample), so
        // the tail slice is the newest ~12ms. Two vDSP passes over 512 floats is
        // a few microseconds — effectively free.
        let fastWindow = min(fastEnvelopeWindow, fftSize)
        var fastRMS: Float = rms
        var fastPeak: Float = peak
        fftInput.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let tail = base + (fftSize - fastWindow)
            vDSP_rmsqv(tail, 1, &fastRMS, vDSP_Length(fastWindow))
            vDSP_maxmgv(tail, 1, &fastPeak, vDSP_Length(fastWindow))
        }

        // 3. Windowing
        vDSP_vmul(fftInput, 1, window, 1, &fftInput, 1, vDSP_Length(fftSize))

        // 4. FFT
        guard let fftSetup else { return }
        fftReal.withUnsafeMutableBufferPointer { realPtr in
            fftImag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else {
                    return
                }

                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                fftInput.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2)
                    { ptrComplex in
                        vDSP_ctoz(ptrComplex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &fftMagnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // 5. Notify Consumers
        let data = AudioAnalysisData(
            pcmSamples: pcmSamples, hostTime: ProcessInfo.processInfo.systemUptime,
            magnitudes: fftMagnitudes,
            sampleRate: currentSampleRate,
            fftSize: fftSize,
            rms: rms,
            peak: peak,
            fastRMS: fastRMS,
            fastPeak: fastPeak,
            fastWindow: fastWindow
        )

        consumerLock.lock()
        let currentConsumers = Array(consumers.values)
        consumerLock.unlock()

        for consumer in currentConsumers {
            consumer(data)
        }

        processedFrames &+= 1
        dumpDiagnosticsIfNeeded()
    }

    private nonisolated func dumpDiagnosticsIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiagnosticsDumpUptime >= Self.sampleBusDiagnosticsInterval else { return }
        lastDiagnosticsDumpUptime = now

        stateLock.lock()
        let dropped = droppedRendererBuffers
        droppedRendererBuffers = 0
        stateLock.unlock()
        let skipped = skippedProcessReads
        let processed = processedFrames

        skippedProcessReads = 0
        processedFrames = 0

        let isActive = isPlaybackActiveForDiagnostics()
        updateSampleBusDiagnosticStreaks(
            dropped: dropped,
            skipped: skipped,
            processed: processed,
            isActive: isActive
        )

        guard dropped > 0 || skipped > 0 || (isActive && processed == 0) else { return }

        let operation = FirstUseHitchDiagnostics.currentOperationStack()
        let message = "[AudioDiagnostics] sampleBus droppedRendererBuffers=\(dropped) skippedProcessReads=\(skipped) processedFrames=\(processed) active=\(isActive) operation=\(operation)"
        let severity = sampleBusDiagnosticSeverity(
            dropped: dropped,
            skipped: skipped,
            processed: processed,
            isActive: isActive
        )

        switch severity {
        case .warning(let reason):
            guard now - lastSampleBusWarningUptime >= Self.sampleBusWarningThrottle else { return }
            lastSampleBusWarningUptime = now
            Log.warning("\(message) reason=\(reason)", category: .audio)
        case .debug:
            Log.sampleBusDebug(message)
        case .silent:
            return
        }
    }

    private enum SampleBusDiagnosticSeverity {
        case silent
        case debug
        case warning(reason: String)
    }

    private nonisolated func isPlaybackActiveForDiagnostics() -> Bool {
        stateLock.lock()
        let hasConsumers = hasActiveSamplingDemandLocked()
        let inputAvailable = isRendererFeedEnabled
        let active = inputAvailable && hasConsumers && (isPlaying || pauseLingerActive)
        stateLock.unlock()
        return active
    }

    private nonisolated func updateSampleBusDiagnosticStreaks(
        dropped: UInt64,
        skipped: UInt64,
        processed: UInt64,
        isActive: Bool
    ) {
        if dropped >= Self.sustainedDroppedRendererBufferThreshold {
            consecutiveDroppedDiagnosticWindows += 1
        } else {
            consecutiveDroppedDiagnosticWindows = 0
        }

        if skipped >= Self.skippedProcessReadWindowThreshold {
            consecutiveSkippedDiagnosticWindows += 1
        } else {
            consecutiveSkippedDiagnosticWindows = 0
        }

        if isActive && processed == 0 {
            consecutiveNoProcessedFrameWindows += 1
        } else {
            consecutiveNoProcessedFrameWindows = 0
        }
    }

    private nonisolated func sampleBusDiagnosticSeverity(
        dropped: UInt64,
        skipped: UInt64,
        processed: UInt64,
        isActive: Bool
    ) -> SampleBusDiagnosticSeverity {
        if isActive,
           processed == 0,
           consecutiveNoProcessedFrameWindows >= Self.noProcessedFrameWarningWindows
        {
            return .warning(reason: "noProcessedFrames")
        }

        if consecutiveDroppedDiagnosticWindows >= Self.sustainedDroppedRendererBufferWindows {
            return .warning(reason: "sustainedDroppedRendererBuffers")
        }

        if skipped >= Self.skippedProcessReadBurstThreshold
            || consecutiveSkippedDiagnosticWindows >= Self.skippedProcessReadWarningWindows
        {
            return .warning(reason: "repeatedSkippedProcessReads")
        }

        if dropped < Self.minorDroppedRendererBufferThreshold
            && skipped < Self.minorSkippedProcessReadThreshold
        {
            return .silent
        }

        return .debug
    }

    private nonisolated func rebuildFFT() {
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }
}
