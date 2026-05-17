//
//  AudioAnalysisHub.swift
//  myPlayer2
//
//  kmgccc_player - Audio Analysis Hub
//  Centralized audio tap and FFT processing.
//  Provides raw FFT magnitudes to consumers (LED Meter, Waveform, etc.).
//

import AVFoundation
import Accelerate
import Foundation

/// Raw FFT data provided to consumers.
/// Raw FFT data provided to consumers.
nonisolated public struct AudioAnalysisData: Sendable {
    public let magnitudes: [Float]  // Frequency domain (0...Nyquist)
    public let sampleRate: Float
    public let fftSize: Int
    // Optional: Pre-calculated metrics if cheap (RMS, Peak)
    public let rms: Float
    public let peak: Float
}

nonisolated public final class AudioAnalysisHub: @unchecked Sendable {

    private let processingQueue = DispatchQueue(
        label: "AudioAnalysisHub.processing",
        qos: .utility
    )

    private let fftSize: Int = 2048
    private nonisolated(unsafe) var window: [Float]
    private nonisolated(unsafe) var fftSetup: FFTSetup?
    private nonisolated(unsafe) var log2n: vDSP_Length = 0
    private nonisolated(unsafe) var isInstalled = false
    private nonisolated(unsafe) weak var mixerNode: AVAudioMixerNode?

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
    private nonisolated(unsafe) var consumers: [UUID: (AudioAnalysisData) -> Void] = [:]
    private let consumerLock = NSLock()
    private nonisolated(unsafe) var timer: DispatchSourceTimer?
    private nonisolated(unsafe) var activeClients: Int = 0
    private nonisolated(unsafe) var droppedTapBuffers: UInt64 = 0
    private nonisolated(unsafe) var skippedProcessReads: UInt64 = 0
    private nonisolated(unsafe) var processedFrames: UInt64 = 0
    private nonisolated(unsafe) var lastDiagnosticsDumpUptime: TimeInterval = 0

    // Serializes start / stop / attachToMixer so the AVAudioMixerNode never
    // sees two concurrent installTap calls (which trip the
    // `nullptr == Tap()` precondition assert).
    private let stateLock = NSLock()

    // Config
    nonisolated(unsafe) var targetHz: Int = 30

    public static let shared = AudioAnalysisHub()

    private init() {
        self.window = [Float](repeating: 0, count: fftSize)
        self.ringBuffer = [Float](repeating: 0, count: fftSize * 4)
        self.fftInput = [Float](repeating: 0, count: fftSize)
        self.fftReal = [Float](repeating: 0, count: fftSize / 2)
        self.fftImag = [Float](repeating: 0, count: fftSize / 2)
        self.fftMagnitudes = [Float](repeating: 0, count: fftSize / 2)

        rebuildFFT()
    }

    func attachToMixer(_ mixer: AVAudioMixerNode) {
        stateLock.lock()
        mixerNode = mixer
        stateLock.unlock()
    }

    func start() {
        stateLock.lock()
        activeClients += 1
        if isInstalled {
            stateLock.unlock()
            return
        }
        guard let mixer = mixerNode else {
            activeClients = max(0, activeClients - 1)
            stateLock.unlock()
            print("⚠️ AudioAnalysisHub: No mixer attached")
            return
        }

        let format = mixer.outputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(fftSize)

        installTapLocked(on: mixer, format: format, bufferSize: bufferSize)
        isInstalled = true
        stateLock.unlock()

        startTimer()
    }

    func stop() {
        stateLock.lock()
        activeClients = max(0, activeClients - 1)
        if activeClients > 0 {
            stateLock.unlock()
            return
        }
        guard isInstalled else {
            stateLock.unlock()
            purgeInactiveState(preservingMixerAttachment: true)
            return
        }
        mixerNode?.removeTap(onBus: 0)
        isInstalled = false
        stateLock.unlock()

        stopTimer()
        purgeInactiveState(preservingMixerAttachment: true)
    }

    func prepareForEngineConfigurationChange() {
        stateLock.lock()
        guard isInstalled else {
            stateLock.unlock()
            return
        }

        mixerNode?.removeTap(onBus: 0)
        isInstalled = false
        stateLock.unlock()
        resetBuffer()
    }

    func restoreAfterEngineConfigurationChange() {
        stateLock.lock()
        guard activeClients > 0 else {
            stateLock.unlock()
            return
        }
        guard isInstalled == false else {
            stateLock.unlock()
            return
        }
        guard let mixer = mixerNode else {
            stateLock.unlock()
            print("⚠️ AudioAnalysisHub: No mixer attached after engine configuration change")
            return
        }

        let format = mixer.outputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(fftSize)
        installTapLocked(on: mixer, format: format, bufferSize: bufferSize)
        isInstalled = true
        stateLock.unlock()

        startTimer()
    }

    func reinstallTapIfActive() {
        stateLock.lock()
        guard activeClients > 0 else {
            stateLock.unlock()
            return
        }
        guard let mixer = mixerNode else {
            stateLock.unlock()
            print("⚠️ AudioAnalysisHub: No mixer attached for tap reinstall")
            return
        }

        if isInstalled {
            mixer.removeTap(onBus: 0)
            isInstalled = false
        }

        let format = mixer.outputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(fftSize)
        installTapLocked(on: mixer, format: format, bufferSize: bufferSize)
        isInstalled = true
        stateLock.unlock()

        startTimer()
    }

    // MARK: - Consumer API

    func addConsumer(_ callback: @escaping (AudioAnalysisData) -> Void) -> UUID {
        let id = UUID()
        consumerLock.lock()
        consumers[id] = callback
        consumerLock.unlock()
        return id
    }

    func removeConsumer(_ id: UUID) {
        consumerLock.lock()
        consumers.removeValue(forKey: id)
        consumerLock.unlock()
    }

    // MARK: - Internal Processing

    nonisolated private func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        guard ringLock.try() else {
            droppedTapBuffers &+= 1
            return
        }
        let samples = channelData[0]
        let capacity = ringBuffer.count
        for i in 0..<frameLength {
            ringBuffer[writeIndex] = samples[i]
            writeIndex += 1
            if writeIndex >= capacity {
                writeIndex = 0
            }
        }
        ringLock.unlock()
    }

    private func resetBuffer() {
        ringLock.lock()
        writeIndex = 0
        ringBuffer.withUnsafeMutableBufferPointer { ptr in
            ptr.initialize(repeating: 0)
        }
        ringLock.unlock()
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

    private func installTapLocked(
        on mixer: AVAudioMixerNode,
        format: AVAudioFormat,
        bufferSize: AVAudioFrameCount
    ) {
        self.sampleRate = Float(format.sampleRate)
        resetBuffer()

        // installTap/removeTap are serialized by stateLock so LEDMeterService,
        // AudioVisualizationService, and device-change recovery cannot double
        // install the shared mixer tap.
        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) {
            [weak self] buffer, _ in
            self?.enqueue(buffer)
        }
    }

    private func purgeInactiveState(preservingMixerAttachment: Bool) {
        consumerLock.lock()
        consumers.removeAll()
        consumerLock.unlock()

        resetBuffer()
        fftInput = [Float](repeating: 0, count: fftSize)
        fftReal = [Float](repeating: 0, count: fftSize / 2)
        fftImag = [Float](repeating: 0, count: fftSize / 2)
        fftMagnitudes = [Float](repeating: 0, count: fftSize / 2)
        sampleRate = 44_100
        if preservingMixerAttachment == false {
            mixerNode = nil
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
        ringLock.unlock()  // Release lock ASAP

        // 2. Pre-calculate metrics (Time Domain)
        var rms: Float = 0
        vDSP_rmsqv(fftInput, 1, &rms, vDSP_Length(fftSize))
        var peak: Float = 0
        vDSP_maxmgv(fftInput, 1, &peak, vDSP_Length(fftSize))

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
            magnitudes: fftMagnitudes,
            sampleRate: sampleRate,
            fftSize: fftSize,
            rms: rms,
            peak: peak
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
        guard now - lastDiagnosticsDumpUptime >= 2.0 else { return }
        lastDiagnosticsDumpUptime = now

        let dropped = droppedTapBuffers
        let skipped = skippedProcessReads
        let processed = processedFrames
        guard dropped > 0 || skipped > 0 else { return }

        droppedTapBuffers = 0
        skippedProcessReads = 0
        processedFrames = 0

        Log.warning(
            "[AudioDiagnostics] sampleBus droppedTapBuffers=\(dropped) skippedProcessReads=\(skipped) processedFrames=\(processed) operation=\(FirstUseHitchDiagnostics.currentMainOperationDescription() ?? "none")",
            category: .audio
        )
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
