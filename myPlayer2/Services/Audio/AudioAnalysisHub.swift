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
public struct AudioAnalysisData: Sendable {
    public let magnitudes: [Float]  // Frequency domain (0...Nyquist)
    public let sampleRate: Float
    public let fftSize: Int
    // Optional: Pre-calculated metrics if cheap (RMS, Peak)
    public let rms: Float
    public let peak: Float
}

public final class AudioAnalysisHub: @unchecked Sendable {

    private let processingQueue = DispatchQueue(
        label: "AudioAnalysisHub.processing",
        qos: .userInitiated
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

    // Config
    nonisolated(unsafe) var targetHz: Int = 60

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
        mixerNode = mixer
    }

    func start() {
        activeClients += 1
        guard !isInstalled else { return }
        guard let mixer = mixerNode else {
            print("⚠️ AudioAnalysisHub: No mixer attached")
            activeClients = max(0, activeClients - 1)
            return
        }

        let format = mixer.outputFormat(forBus: 0)
        self.sampleRate = Float(format.sampleRate)
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(fftSize)

        resetBuffer()

        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) {
            [weak self] buffer, _ in
            self?.enqueue(buffer)
        }

        isInstalled = true
        startTimer()
    }

    func stop() {
        activeClients = max(0, activeClients - 1)
        guard activeClients == 0 else { return }
        guard isInstalled else { return }
        mixerNode?.removeTap(onBus: 0)
        isInstalled = false
        stopTimer()
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

        ringLock.lock()
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

    nonisolated private func process() {
        // 1. Read latest window from ring buffer
        ringLock.lock()
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
